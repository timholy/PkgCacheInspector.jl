module PkgCacheInspector

using Base: PkgId, require_lock, assert_havelock, isvalid_cache_header, parse_cache_header, isvalid_file_crc,
            _tryrequire_from_serialized, find_all_in_cache_path, locate_package, stale_cachefile

function extract_from_serialized(path::String, depmods::Vector{Any})
    sv = ccall(:jl_return_package_image_components_from_stream, Any, (Cstring, Any), path, depmods)
    if isa(sv, Exception)
        throw(sv)
    end
    return sv::SimpleVector
end

function extract_from_serialized(pkg::PkgId, path::String)
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
        extract_from_serialized(path, depmods)
    end
end

# extract_from_serialized(pkg::PkgId, env=nothing) = extract_from_serialized(pkg, locate_package(pkg, env))

function extract_from_serialized(pkg::PkgId)
    cachefiles = find_all_in_cache_path(pkg)
    isempty(cachefiles) && error(pkg, " has not yet been precompiled for julia ", Base.VERSION)
    pkgpath = locate_package(pkg)
    idx = findfirst(cachefiles) do cf
        stale_cachefile(pkgpath, cf) !== true
    end
    idx === nothing && error("all cache files for ", pkg, " are stale, please precompile")
    return extract_from_serialized(pkg, cachefiles[idx])
end
extract_from_serialized(pkgname::AbstractString) = extract_from_serialized(Base.identify_package(pkgname))

end
