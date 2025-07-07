module PkgCacheInspector

using Printf
using DocStringExtensions

export info_cachefile, PkgCacheSizes, PkgCacheInfo

using Base: PkgId, require_lock, assert_havelock, isvalid_cache_header, parse_cache_header, isvalid_file_crc,
            _tryrequire_from_serialized, find_all_in_cache_path, locate_package, stale_cachefile
using Core: SimpleVector

"""
$(TYPEDEF)

Stores the sizes of different "sections" of the pkgimage. The main section is the package image itself.
However, reconstructing a pkgimage for use requires auxillary data, like the addresses of internal
pointers that need to be modified to account for the actual base address into which the
pkgimage was loaded. Each form of auxillary data gets stored in distinct sections.

$(FIELDS)
"""
struct PkgCacheSizes
    """
    Size of the image. This is the portion of the file that gets returns by `info_cachefile`.
    """
    sysdata::Int
    """
    Size of the `const` internal data section (storing things not visible from Julia, like datatype layouts).
    """
    isbitsdata::Int
    """
    Size of the symbol section, for Symbols stored in the image.
    """
    symboldata::Int
    """
    Size of the GC tags section, holding references to objects that require special re-initialization for GC.
    """
    tagslist::Int
    """
    Size of the relocation-list section, holding references to within-image pointers that need to be offset
    by the actual base pointer upon reloading.
    """
    reloclist::Int
    """
    Size of the "gvar" (global variable) list of LLVM-encoded objects.
    """
    gvarlist::Int
    """
    Size of the function-pointer list, referencing native code.
    """
    fptrlist::Int
end
PkgCacheSizes() = PkgCacheSizes(0, 0, 0, 0, 0, 0, 0)   # for testing

const cache_displaynames = [
        "system",
        "isbits",
        "symbols",
        "tags",
        "relocations",
        "gvars",
        "fptrs"
    ]
const cache_displaynames_l = maximum(length, cache_displaynames)

function Base.show(io::IO, szs::PkgCacheSizes)
    indent = get(io, :indent, 0)
    nd = ntot = 0
    nf = length(fieldnames(typeof(szs)))
    for i = 1:nf
        nb = getfield(szs, i)
        nd = max(nd, ndigits(nb))
        ntot += nb
    end
    println(io, " "^indent, "Segment sizes (bytes):")
    for i = 1:nf
        nb = getfield(szs, i)
        println(io,
            " "^indent,
            "  ",
            rpad(cache_displaynames[i] * ": ", cache_displaynames_l+2),
            lpad(string(nb), nd),
            " (",
            @sprintf("% 6.2f", 100*nb/ntot),
            "%)")
    end
end

"""
$(TYPEDEF)

Objects stored the pkgimage. The main contents are the modules themselves, but some additional objects
are stored external to the modules. It also contains the data used to perform invalidation-checks.

$(FIELDS)
"""
struct PkgCacheInfo
    """
    The filename of the cache.
    """
    cachefile::String
    """
    The list of modules stored in the package image. The final one is the "top" package module.
    """
    modules::Vector{Module}
    """
    The list of modules with an `__init__` function, in the order in which they should be called.
    """
    init_order::Vector{Any}
    """
    The list of methods added to external modules. E.g., `Base.push!(v::MyNewVector, x)`.
    """
    external_methods::Vector{Any}
    """
    The list of novel specializations of external methods that were created during package precompilation.
    E.g., `get(::Dict{String,Float16}, ::String, ::Nothing)`: `Base` owns the method and all the types in
    this specialization, but might not have precompiled it until it was needed by a package.
    """
    new_specializations::Vector{Any}
    """
    New GC roots added to external methods. These are an important but internal detail of how type-inferred code
    is compressed for serialization.
    """
    new_method_roots::Vector{Any}
    """
    A lookup table of `external_targets` dependencies: `[mi1, indxs1, mi2, indxs2...]` means that `mi1`
    (cached in this pkgimage) depends on `external_targets[idxs1]`; `mi2` depends on `external_targets[idxs2]`,
    and so on.
    """
    edges::Vector{Any}
    """
    The total size of the cache file.
    """
    filesize::Int
    """
    Sizes of the individual sections. See [`PkgCacheSizes`](@ref).
    """
    cachesizes::PkgCacheSizes
    """
    The image targets that were cloned into the pkgimage, if used.
    """
    image_targets::Vector{Any}
end
PkgCacheInfo(cachefile::AbstractString, modules) = PkgCacheInfo(cachefile, modules, [], [], [], [], [], 0, PkgCacheSizes(), [])

function Base.show(io::IO, info::PkgCacheInfo)
    nspecs = count_module_specializations(info.new_specializations)
    nspecs = sort(collect(nspecs); by=last, rev=true)
    nspecs_tot = sum(last, nspecs; init=0)

    # Count internal methods
    internal_methods = count_internal_methods(info)
    total_internal = sum(values(internal_methods))
    
    println(io, "Contents of ", info.cachefile, ':')
    println(io, "  modules: ", info.modules)
    !isempty(info.init_order) && println(io, "  init order: ", info.init_order)
    
    # Show internal methods
    if total_internal > 0
        println(io, "  ", total_internal, " internal methods")
        if length(internal_methods) > 1
            print(io, "    (")
            sorted_internal = sort(collect(internal_methods); by=last, rev=true)
            for i = 1:length(sorted_internal)
                mod, count = sorted_internal[i]
                print(io, i==1 ? "" : ", ", nameof(mod), " ", count)
            end
            println(io, ")")
        end
    end
    
    !isempty(info.external_methods) && println(io, "  ", length(info.external_methods), " external methods")
    if !isempty(info.new_specializations)
        print(io, "  ", length(info.new_specializations), " new specializations of external methods ")
        for i = 1:min(3, length(nspecs))
            m, n = nspecs[i]
            print(io, i==1 ? "(" : ", ", m, " ", round(100*n/nspecs_tot; digits=1), "%")
        end
        println(io, length(nspecs) > 3 ? ", ...)" : ")")
    end
    !isempty(info.new_method_roots) && println(io, "  ", length(info.new_method_roots) ÷ 2, " external methods with new roots")
    !isempty(info.edges) && println(io, "  ", length(info.edges) ÷ 2, " edges")
    println(io, "  ", rpad("file size: ", cache_displaynames_l+2), info.filesize, " (", Base.format_bytes(info.filesize),")")
    show(IOContext(io, :indent => 2), info.cachesizes)
    println(io, "  Image targets: ")
    for t in info.image_targets
        println(io, "    ", t)
    end
end

moduleof(m::Method) = m.module
moduleof(m::Module) = m

function count_module_specializations(new_specializations)
    modcount = Dict{Module,Int}()
    for ci in new_specializations
        m = moduleof(ci.def.def)
        modcount[m] = get(modcount, m, 0) + 1
    end
    return modcount
end

"""
    count_internal_methods(info::PkgCacheInfo) → Dict{Module,Int}

Count the number of methods defined within each of the package's own modules.
These are methods that belong to the modules stored in the package image,
as opposed to external methods which extend functions from other modules.
"""
function count_internal_methods(info::PkgCacheInfo)
    method_counts = Dict{Module,Int}()
    for mod in info.modules
        count = 0
        # Count methods defined in this module
        for name in names(mod; all=true)
            if isdefined(mod, name)
                obj = getfield(mod, name)
                if isa(obj, Function)
                    for method in methods(obj)
                        if method.module == mod
                            count += 1
                        end
                    end
                elseif isa(obj, Type) && isa(obj, DataType)
                    # Count constructors
                    for method in methods(obj)
                        if method.module == mod
                            count += 1
                        end
                    end
                end
            end
        end
        method_counts[mod] = count
    end
    return method_counts
end

function info_cachefile(pkg::PkgId, path::String, depmods::Vector{Any}, image_targets::Vector{Any}, isocache::Bool=false)
    if isocache
        sv = ccall(:jl_restore_package_image_from_file, Any, (Cstring, Any, Cint, Cstring, Cint), path, depmods, true, pkg.name, false)
    else
        sv = ccall(:jl_restore_incremental, Any, (Cstring, Any, Cint, Cstring), path, depmods, true, pkg.name)
    end
    if isa(sv, Exception)
        throw(sv)
    end
    Base.register_restored_modules(sv, pkg, path)
    return PkgCacheInfo(path, sv[1:6]..., filesize(path), PkgCacheSizes(sv[7]...), image_targets)
end

function info_cachefile(pkg::PkgId, path::String)
    return @lock require_lock begin
        local depmodnames, image_targets
        io = open(path, "r")
        try
            # isvalid_cache_header returns checksum id or zero
            isvalid_cache_header(io) == 0 && return ArgumentError("Invalid header in cache file $path.")
            depmodnames, clone_targets = parse_cache_header(io, path)[[3,7]]
            image_targets = Any[Base.parse_image_targets(clone_targets)...]
            isvalid_file_crc(io) || return ArgumentError("Invalid checksum in cache file $path.")
        finally
            close(io)
        end
        ndeps = length(depmodnames)
        depmods = Vector{Any}(undef, ndeps)
        for i in 1:ndeps
            modkey, build_id = depmodnames[i]
            dep = _tryrequire_from_serialized(modkey, build_id)
            if !isa(dep, Module)
                throw(dep)
            end
            depmods[i] = dep
        end
        # then load the file
        if isdefined(Base, :ocachefile_from_cachefile)
            return info_cachefile(pkg, Base.ocachefile_from_cachefile(path), depmods, image_targets, true)
        end
        info_cachefile(pkg, path, depmods, image_targets)
    end
end

function info_cachefile(pkg::PkgId)
    cachefiles = find_all_in_cache_path(pkg)
    isempty(cachefiles) && error(pkg, " has not yet been precompiled for julia ", Base.VERSION)
    pkgpath = locate_package(pkg)
    idx = findfirst(cachefiles) do cf
        stale_cachefile(pkgpath, cf) !== true
    end
    idx === nothing && error("all cache files for ", pkg, " are stale, please precompile")
    return info_cachefile(pkg, cachefiles[idx])
end

"""
    info_cachefile(pkgname::AbstractString) → cf
    info_cachefile(pkgid::Base.PkgId) → cf
    info_cachefile(pkgid::Base.PkgId, ji_cachefilename) → cf

Return a snapshot `cf` of a package cache file. Displaying `cf` prints a summary of the contents,
but the fields of `cf` can be inspected to get further information (see [`PkgCacheInfo`](@ref)).

After calling `info_cachefile("MyPkg")` you can also execute `using MyPkg` to make the image loaded by
`info_cachefile` available for use. This can allow you to load `cf`s for multiple packages into the same session
for deeper analysis.

!!! warn
    Your session may be corrupted if you run `info_cachefile` for a package that had
    already been loaded into your session. Restarting with a clean session and using `info_cachefile`
    before otherwise loading the package is recommended.
"""
info_cachefile(pkgname::AbstractString) = info_cachefile(Base.identify_package(pkgname))

end
