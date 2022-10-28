module PkgCacheInspector

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

function Base.show(io::IO, szs::PkgCacheSizes)
    nd = 0
    nf = length(fieldnames(typeof(szs)))
    for i = 1:nf
        nd = max(nd, ndigits(getfield(szs, i)))
    end
    displaynames = [
        "system",
        "isbits",
        "symbols",
        "tags",
        "relocations",
        "gvars",
        "fptrs"
    ]
    l = maximum(length, displaynames)
    for i = 1:nf
        println(io, rpad(displaynames[i], l), ": ", lpad(string(getfield(szs, i)), nd))
    end
end

struct PkgCacheInfo
    modules::Vector{Any}
    init_order::Vector{Any}
    external_methods::Vector{Any}
    new_specializations::Vector{Any}
    new_method_roots::Vector{Any}
    external_targets::Vector{Any}
    edges::Vector{Any}
    cachesizes::PkgCacheSizes
end

function Base.show(io::IO, info::PkgCacheInfo)
    println(io, "modules: ", info.modules)
    !isempty(info.init_order) && println(io, "init order: ", info.init_order)
    !isempty(info.external_methods) && println(io, length(info.external_methods), " external methods")
    !isempty(info.new_specializations) && println(io, length(info.new_specializations), " new specializations of external methods")
    !isempty(info.new_method_roots) && println(io, length(info.new_method_roots) ÷ 2, " external methods with new roots")
    !isempty(info.external_targets) && println(io, length(info.external_targets) ÷ 3, " external targets")
    !isempty(info.edges) && println(io, length(info.edges) ÷ 2, " edges")
    show(io, info.cachesizes)
end

function info_cachefile(path::String, depmods::Vector{Any})
    sv = ccall(:jl_restore_incremental, Any, (Cstring, Any, Cint), path, depmods, true)
    if isa(sv, Exception)
        throw(sv)
    end
    return PkgCacheInfo(sv[1:7]..., PkgCacheSizes(sv[8]...))
end

function info_cachefile(pkg::PkgId, path::String)
    return @lock require_lock begin
        local depmodnames
        io = open(path, "r")
        try
            isvalid_cache_header(io) || return ArgumentError("Invalid header in cache file $path.")
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
