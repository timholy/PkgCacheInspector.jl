module PkgCacheInspector

using Printf

export info_cachefile, PkgCacheSizes, PkgCacheInfo

using Base: PkgId, require_lock, assert_havelock, isvalid_cache_header, parse_cache_header, isvalid_file_crc,
            _tryrequire_from_serialized, find_all_in_cache_path, locate_package, stale_cachefile
using Core: SimpleVector

struct PkgCacheSizes
    sysdata::Int
    isbitsdata::Int
    symboldata::Int
    tagslist::Int
    reloclist::Int
    gvarlist::Int
    fptrlist::Int
end

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
            rpad(cache_displaynames[i] * ": ", cache_displaynames_l+2),
            lpad(string(nb), nd),
            " (",
            @sprintf("% 6.2f", 100*nb/ntot),
            "%)")
    end
end

struct PkgCacheInfo
    cachefile::String
    modules::Vector{Any}
    init_order::Vector{Any}
    external_methods::Vector{Any}
    new_specializations::Vector{Any}
    new_method_roots::Vector{Any}
    external_targets::Vector{Any}
    edges::Vector{Any}
    filesize::Int
    cachesizes::PkgCacheSizes
end

function Base.show(io::IO, info::PkgCacheInfo)
    nspecs = count_module_specializations(info.new_specializations)
    nspecs = sort(collect(nspecs); by=last, rev=true)
    nspecs_tot = sum(last, nspecs)

    println(io, "Contents of ", info.cachefile, ':')
    println(io, "  modules: ", info.modules)
    !isempty(info.init_order) && println(io, "  init order: ", info.init_order)
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
    !isempty(info.external_targets) && println(io, "  ", length(info.external_targets) ÷ 3, " external targets")
    !isempty(info.edges) && println(io, "  ", length(info.edges) ÷ 2, " edges")
    println(io, "  ", rpad("file size: ", cache_displaynames_l+2), info.filesize, " (", Base.format_bytes(info.filesize),")")
    show(IOContext(io, :indent => 2), info.cachesizes)
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

function info_cachefile(path::String, depmods::Vector{Any}, isocache::Bool=false)
    if isocache
        sv = ccall(:jl_restore_package_image_from_file, Any, (Cstring, Any, Cint), path, depmods, true)
    else
        sv = ccall(:jl_restore_incremental, Any, (Cstring, Any, Cint), path, depmods, true)
    end
    if isa(sv, Exception)
        throw(sv)
    end
    return PkgCacheInfo(path, sv[1:7]..., filesize(path), PkgCacheSizes(sv[8]...))
end

function info_cachefile(pkg::PkgId, path::String)
    return @lock require_lock begin
        local depmodnames
        io = open(path, "r")
        try
            # isvalid_cache_header returns checksum id or zero
            isvalid_cache_header(io) == 0 && return ArgumentError("Invalid header in cache file $path.")
            depmodnames = parse_cache_header(io)[3]
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
                return dep
            end
            depmods[i] = dep
        end
        # then load the file
        if isdefined(Base, :ocachefile_from_cachefile)
            return info_cachefile(Base.ocachefile_from_cachefile(path), depmods, true)
        end
        info_cachefile(path, depmods)
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

info_cachefile(pkgname::AbstractString) = info_cachefile(Base.identify_package(pkgname))

end
