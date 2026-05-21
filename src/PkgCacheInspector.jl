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
    These are methods that extend functions owned by other modules.

    !!! note
        On Julia 1.13 through Julia 1.14.0-DEV (prior to the upstream fix that restores
        `extext_methods` to the inspector svec), this list is always empty: the underlying
        `TypeMapEntry` array is populated by the loader but discarded before it reaches
        external callers. The information is therefore unavailable to PkgCacheInspector on
        those releases.
    """
    external_methods::Vector{Any}
    """
    The list of method specializations for methods defined within the package's own modules.
    These are specializations that were added during precompilation but belong to the package's own methods.
    """
    internal_method_specializations::Vector{Any}
    """
    The list of novel specializations of external methods that were created during package precompilation.
    E.g., `get(::Dict{String,Float16}, ::String, ::Nothing)`: `Base` owns the method and all the types in
    this specialization, but might not have precompiled it until it was needed by a package.
    """
    new_specializations::Vector{Any}
    """
    Methods that gained new GC roots during precompilation, paired flat as
    `[method, roots, method, roots, …]`. This includes both internal and external methods.
    These roots are an internal detail of how type-inferred code is compressed for serialization.
    """
    new_method_roots::Vector{Any}
    """
    Reserved for backward compatibility; currently always empty. The previous semantics (an
    `external_targets` lookup table) no longer reflect what `jl_restore_incremental` returns.
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
    """
    Methods defined by this package image as extracted directly from the `internal_methods`
    array returned by the loader (Julia ≥ 1.13). Empty on Julia 1.12 where the loader does not
    surface this list; in that case `count_internal_methods` falls back to walking the global
    method table.
    """
    internal_methods::Vector{Any}
    """
    Verbose output mode for displaying method information.
    """
    verbose::Symbol
end
PkgCacheInfo(cachefile::AbstractString, modules) = PkgCacheInfo(cachefile, modules, [], [], [], [], [], [], 0, PkgCacheSizes(), [], [], :none)

"""
    _unpack_restored_sv(sv) -> NamedTuple

Unpack the SimpleVector returned by `jl_restore_incremental`/`jl_restore_package_image_from_file`
(with `completeinfo=true`), normalizing across Julia versions.

Four layouts are supported:

- Julia 1.11 (8-elem): `(restored, init_order, extext_methods, new_ext_cis,
  method_roots_list, ext_targets, edges, cachesizes_sv)`. `ext_targets` is unused here.
- Julia 1.12 (7-elem): `(restored, init_order, edges, ext_edges, extext_methods,
  method_roots_list, cachesizes_sv)`.
- Julia 1.13 .. 1.14.0-DEV pre-fix (5-elem): `(restored, init_order, internal_methods,
  method_roots_list, cachesizes_sv)` where `internal_methods` mixes `Method` and `CodeInstance`.
  On these releases the `extext_methods` (TypeMapEntries) and `new_ext_cis` arrays are
  populated inside the loader but **dropped** before being returned, so `extext_entries` is
  always empty here. See the JuliaLang/julia source `staticdata.c` for the fix.
- Post-fix master (7-elem): `(restored, init_order, internal_methods, extext_methods,
  new_ext_cis, method_roots_list, cachesizes_sv)`. Distinguished from the 1.12 7-elem
  layout by `VERSION` (the layouts are not type-distinguishable when their arrays are
  empty).
"""
function _unpack_restored_sv(sv)
    n = length(sv)
    modules = sv[1]
    init_order = sv[2]
    code_instances = Core.CodeInstance[]
    extext_entries = Core.TypeMapEntry[]
    internal_methods = Method[]
    if n == 8
        # Julia 1.11 layout: extext_methods, new_ext_cis, method_roots, ext_targets, edges, cachesizes
        for x in sv[3]; isa(x, Core.TypeMapEntry) && push!(extext_entries, x); end
        for x in sv[4]; isa(x, Core.CodeInstance) && push!(code_instances, x); end
        for x in sv[7]; isa(x, Core.CodeInstance) && push!(code_instances, x); end
        method_roots_list = sv[5]
        cachesizes_raw = sv[8]
    elseif n == 7 && VERSION < v"1.13-"
        # Julia 1.12 layout: edges, ext_edges, extext_methods
        for x in sv[3]; isa(x, Core.CodeInstance) && push!(code_instances, x); end
        for x in sv[4]; isa(x, Core.CodeInstance) && push!(code_instances, x); end
        for x in sv[5]; isa(x, Core.TypeMapEntry) && push!(extext_entries, x); end
        method_roots_list = sv[6]
        cachesizes_raw = sv[7]
    elseif n == 7
        # Post-fix master layout: internal_methods, extext_methods, new_ext_cis
        for x in sv[3]
            if isa(x, Core.CodeInstance)
                push!(code_instances, x)
            elseif isa(x, Method)
                push!(internal_methods, x)
            end
        end
        for x in sv[4]; isa(x, Core.TypeMapEntry) && push!(extext_entries, x); end
        for x in sv[5]; isa(x, Core.CodeInstance) && push!(code_instances, x); end
        method_roots_list = sv[6]
        cachesizes_raw = sv[7]
    elseif n == 5
        # Julia 1.13 .. 1.14.0-DEV pre-fix layout (buggy: extext_entries is unavailable).
        for x in sv[3]
            if isa(x, Core.CodeInstance)
                push!(code_instances, x)
            elseif isa(x, Method)
                push!(internal_methods, x)
            elseif isa(x, Core.TypeMapEntry)
                push!(extext_entries, x)
            end
        end
        method_roots_list = sv[4]
        cachesizes_raw = sv[5]
    else
        error("Unexpected SimpleVector layout (length $n) returned by Julia $(VERSION); ",
              "PkgCacheInspector needs updating.")
    end
    return (; modules, init_order, code_instances, extext_entries, internal_methods,
              method_roots_list, cachesizes_raw)
end

"""
    _split_code_instances(code_instances, modules) -> (internal, external)

Partition `code_instances` into those whose underlying method belongs to one of `modules`
(internal specializations) and those that don't (new specializations of external methods).
"""
function _split_code_instances(code_instances, modules)
    internal = Core.CodeInstance[]
    external = Core.CodeInstance[]
    for ci in code_instances
        mi = ci.def
        m = isa(mi, Core.MethodInstance) && isa(mi.def, Method) ? mi.def : nothing
        if m !== nothing && m.module in modules
            push!(internal, ci)
        else
            push!(external, ci)
        end
    end
    return internal, external
end

"""
    show_verbose_internal_methods(io::IO, info::PkgCacheInfo)

Display detailed information about internal methods when verbose mode is enabled.
"""
function show_verbose_internal_methods(io::IO, info::PkgCacheInfo)
    # Collect a *deduplicated* set of internal `Method`s. Prefer the exact list from
    # `info.internal_methods` (populated on Julia ≥ 1.13); fall back to walking each
    # module's bindings on older Julias. Walking via `names(mod; all=true)` and listing
    # `methods(getfield(mod, name))` per binding produces duplicates whenever multiple
    # gensym'd bindings (e.g. `var"#12#val"`) alias the same function — collecting into a
    # `Set{Method}` removes that double-counting.
    methods_by_module = Dict{Module, Set{Method}}()
    if !isempty(info.internal_methods)
        for m in info.internal_methods
            isa(m, Method) || continue
            push!(get!(Set{Method}, methods_by_module, m.module), m)
        end
    else
        for mod in info.modules
            for name in names(mod; all=true)
                isdefined(mod, name) || continue
                obj = getfield(mod, name)
                if isa(obj, Function) || (isa(obj, Type) && isa(obj, DataType))
                    for method in methods(obj)
                        method.module == mod || continue
                        push!(get!(Set{Method}, methods_by_module, mod), method)
                    end
                end
            end
        end
    end

    total_internal = sum(length, values(methods_by_module); init=0)
    total_internal == 0 && return

    println(io, "  Internal methods (", total_internal, " total):")
    sorted_modules = sort(collect(methods_by_module); by=x->length(x[2]), rev=true)
    for (mod, mset) in sorted_modules
        println(io, "    ", nameof(mod), ": ", length(mset), " methods")
        # Group by the function the Method belongs to (using `method.name`, the symbol of
        # the function being defined — independent of which binding aliases reference it).
        by_function = Dict{Symbol, Vector{Method}}()
        for m in mset
            push!(get!(Vector{Method}, by_function, m.name), m)
        end
        for fname in sort!(collect(keys(by_function)))
            ms = by_function[fname]
            println(io, "      ", fname, " (", length(ms), " methods)")
            method_lines = sort!([sprint(print, m) for m in ms])
            for line in method_lines
                println(io, "        ", line)
            end
        end
    end
end

"""
    show_verbose_external_methods(io::IO, info::PkgCacheInfo)

Display detailed information about external methods when verbose mode is enabled.
"""
function show_verbose_external_methods(io::IO, info::PkgCacheInfo)
    # Show truly external methods (extension methods defined for functions in other modules)
    if !isempty(info.external_methods)
        println(io, "  External methods (extending functions from other modules) (", length(info.external_methods), " total):")
        # Group unique method definitions by the module that owns the function being extended.
        # `method.module` is the defining (worklist) module — uninformative for extension methods,
        # which by definition all live in the worklist module. Use the function-owner module instead.
        external_method_defs = Set{Method}(m for m in info.external_methods if isa(m, Method))

        module_methods = Dict{Module, Vector{Method}}()
        for method in external_method_defs
            mod = _extension_owner_module(method)
            if !haskey(module_methods, mod)
                module_methods[mod] = Method[]
            end
            push!(module_methods[mod], method)
        end

        sorted_modules = sort(collect(module_methods); by=x->length(x[2]), rev=true)
        for (mod, methods) in sorted_modules
            println(io, "    ", nameof(mod), " (", length(methods), " methods):")
            # Capture method output in buffer and sort
            method_buffer = IOBuffer()
            method_io = IOContext(method_buffer, stdout)
            for method in methods
                println(method_io, "      ", method)
            end
            method_lines = split(String(take!(method_buffer)), '\n', keepempty=false)
            sort!(method_lines)
            for line in method_lines
                println(io, line)
            end
        end
    end



    if !isempty(info.new_specializations)
        println(io, "  New specializations of external methods (", length(info.new_specializations), " total):")
        # Group by module for better organization
        module_specs = Dict{Module, Vector{String}}()
        for spec in info.new_specializations
            if isa(spec, Core.CodeInstance) && isa(spec.def, Core.MethodInstance)
                mi = spec.def
                if isa(mi.def, Method)
                    method = mi.def
                    mod = method.module
                    # Only include truly external methods here
                    if mod ∉ info.modules
                        if !haskey(module_specs, mod)
                            module_specs[mod] = String[]
                        end
                        # Use Julia's compact method signature display
                        signature = sprint(Base.show_tuple_as_call, Symbol(""), mi.specTypes)
                        # Truncate if rtruncate is available to avoid wrapping
                        if isdefined(Base, :rtruncate)
                            terminal_width = Base.displaysize(io)[2]
                            indent_width = 8  # "      " prefix for each spec line
                            max_width = max(40, terminal_width - indent_width)
                            signature = Base.rtruncate(signature, max_width)
                        end
                        push!(module_specs[mod], signature)
                    end
                end
            end
        end

        sorted_modules = sort(collect(module_specs); by=x->length(x[2]), rev=true)
        for (mod, specs) in sorted_modules
            println(io, "    ", nameof(mod), " (", length(specs), " specializations):")
            # Sort the specializations
            sort!(specs)
            for spec in specs
                println(io, "      ", spec)
            end
        end
    end
end

"""
    show_verbose_internal_method_specializations(io::IO, info::PkgCacheInfo)

Display detailed information about internal method specializations when verbose mode is enabled.
"""
function show_verbose_internal_method_specializations(io::IO, info::PkgCacheInfo)
    if !isempty(info.internal_method_specializations)
        println(io, "  Internal method specializations (", length(info.internal_method_specializations), " total):")
        # Group by module for better organization
        module_specs = Dict{Module, Vector{String}}()
        for ci in info.internal_method_specializations
            if isa(ci, Core.CodeInstance) && isa(ci.def, Core.MethodInstance)
                mi = ci.def
                if isa(mi.def, Method)
                    method = mi.def
                    mod = method.module
                    if !haskey(module_specs, mod)
                        module_specs[mod] = String[]
                    end
                    # Use Julia's compact method signature display
                    signature = sprint(Base.show_tuple_as_call, Symbol(""), mi.specTypes)
                    # Truncate if rtruncate is available to avoid wrapping
                    if isdefined(Base, :rtruncate)
                        terminal_width = Base.displaysize(io)[2]
                        indent_width = 8  # "      " prefix for each spec line
                        max_width = max(40, terminal_width - indent_width)
                        signature = Base.rtruncate(signature, max_width)
                    end
                    push!(module_specs[mod], signature)
                end
            end
        end

        sorted_modules = sort(collect(module_specs); by=x->length(x[2]), rev=true)
        for (mod, specs) in sorted_modules
            println(io, "    ", nameof(mod), " (", length(specs), " specializations):")
            # Sort the specializations
            sort!(specs)
            for spec in specs
                println(io, "      ", spec)
            end
        end
    end
end

function Base.show(io::IO, info::PkgCacheInfo)
    nspecs = count_module_specializations(info.new_specializations)
    nspecs = sort(collect(nspecs); by=last, rev=true)
    nspecs_tot = sum(last, nspecs; init=0)

    # Count internal methods and specializations
    internal_methods = count_internal_methods(info)
    total_internal = sum(values(internal_methods))

    # Count internal method specializations from the filtered list
    internal_method_spec_counts = Dict{Module,Int}()
    for ci in info.internal_method_specializations
        if isa(ci, Core.CodeInstance) && isa(ci.def, Core.MethodInstance)
            mi = ci.def
            if isa(mi.def, Method)
                method = mi.def
                mod = method.module
                internal_method_spec_counts[mod] = get(internal_method_spec_counts, mod, 0) + 1
            end
        end
    end
    internal_method_spec_sorted = sort(collect(internal_method_spec_counts); by=last, rev=true)
    total_internal_method_specs = sum(last, internal_method_spec_sorted; init=0)

    # Try to count internal specializations if MethodAnalysis is available (for compatibility)
    internal_specs = count_internal_specializations(info)
    if internal_specs !== nothing
        internal_specs_sorted = sort(collect(internal_specs); by=last, rev=true)
        total_internal_specs = sum(last, internal_specs_sorted; init=0)
    else
        # Use our filtered data as fallback
        internal_specs_sorted = internal_method_spec_sorted
        total_internal_specs = total_internal_method_specs
    end

    println(io, "Contents of ", info.cachefile, ':')
    println(io, "  modules: ", info.modules)
    !isempty(info.init_order) && println(io, "  init order: ", info.init_order)

    # Internal methods: always print a one-line summary; in verbose mode add the detail block.
    if total_internal > 0
        print(io, "  ", total_internal, " internal methods")
        if length(internal_methods) > 1
            print(io, " (")
            sorted_internal = sort(collect(internal_methods); by=last, rev=true)
            for i = 1:length(sorted_internal)
                mod, count = sorted_internal[i]
                print(io, i==1 ? "" : ", ", nameof(mod), " ", count)
            end
            print(io, ")")
        end
        println(io)
    end
    if info.verbose == :internal || info.verbose == :all
        show_verbose_internal_methods(io, info)
    end

    # Internal method specializations: summary line, plus detail in verbose mode.
    if total_internal_method_specs > 0
        print(io, "  ", total_internal_method_specs, " specializations of internal methods ")
        for i = 1:min(3, length(internal_method_spec_sorted))
            mod, count = internal_method_spec_sorted[i]
            pct = round(100*count/total_internal_method_specs; digits=1)
            print(io, i==1 ? "(" : ", ", nameof(mod), " ", pct, "%")
        end
        println(io, length(internal_method_spec_sorted) > 3 ? ", ...)" : ")")
    elseif internal_specs === nothing
        println(io, "  specializations of internal methods: (requires MethodAnalysis.jl)")
    elseif total_internal_specs > 0
        print(io, "  ", total_internal_specs, " specializations of internal methods ")
        for i = 1:min(3, length(internal_specs_sorted))
            mod, count = internal_specs_sorted[i]
            pct = round(100*count/total_internal_specs; digits=1)
            print(io, i==1 ? "(" : ", ", nameof(mod), " ", pct, "%")
        end
        println(io, length(internal_specs_sorted) > 3 ? ", ...)" : ")")
    end
    if info.verbose == :internal || info.verbose == :all
        show_verbose_internal_method_specializations(io, info)
        if internal_specs !== nothing && total_internal_specs != total_internal_method_specs
            println(io, "  MethodAnalysis internal specializations (", total_internal_specs, " total):")
            for (mod, count) in internal_specs_sorted
                println(io, "    ", nameof(mod), ": ", count, " specializations")
            end
        end
    end

    # External methods: summary lines, plus detail in verbose mode.
    !isempty(info.external_methods) && println(io, "  ", length(info.external_methods), " external methods")
    if !isempty(info.new_specializations)
        print(io, "  ", length(info.new_specializations), " new specializations of external methods ")
        for i = 1:min(3, length(nspecs))
            m, n = nspecs[i]
            print(io, i==1 ? "(" : ", ", m, " ", round(100*n/nspecs_tot; digits=1), "%")
        end
        println(io, length(nspecs) > 3 ? ", ...)" : ")")
    end
    if info.verbose == :external || info.verbose == :all
        show_verbose_external_methods(io, info)
    end

    !isempty(info.new_method_roots) && println(io, "  ", length(info.new_method_roots) ÷ 2, " methods with new roots")

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

# count_internal_specializations is defined in MethodAnalysisExt when MethodAnalysis is loaded
count_internal_specializations(::Any) = nothing

# For a method extending an externally-owned function, recover the module that owns the
# function. The first signature parameter is `Type{typeof(f)}` for normal calls, or the
# functor's own type for callable-object methods.
function _extension_owner_module(method::Method)
    sig = Base.unwrap_unionall(method.sig)
    isa(sig, DataType) || return method.module
    isempty(sig.parameters) && return method.module
    t1 = sig.parameters[1]
    if isa(t1, DataType) && t1.name === Type.body.name && !isempty(t1.parameters)
        ft = t1.parameters[1]
        isa(ft, DataType) && return ft.name.module
    elseif isa(t1, DataType)
        return t1.name.module
    end
    return method.module
end

# `Core.GlobalMethods` was renamed to `Core.methodtable` in Julia 1.12 (#59158).
# On Julia 1.11 neither exists publicly; the global walk fallback is simply unavailable
# there (count_internal_methods will rely on info.internal_methods when populated).
const _GLOBAL_METHODS = isdefined(Core, :methodtable) ? Core.methodtable :
                       isdefined(Core, :GlobalMethods) ? getfield(Core, :GlobalMethods) :
                       nothing

# Count the number of methods defined within each of the package's own modules.
# On Julia >= 1.13 the loader hands us the exact `Method` list for this pkgimage in
# `info.internal_methods`; use it for an accurate per-package count. On Julia 1.12 (and as a
# safety fallback) walk the global method table and filter by module — note this over-counts
# in long sessions because it includes methods registered before `info_cachefile` was called.
function count_internal_methods(info::PkgCacheInfo)
    method_counts = Dict{Module,Int}()
    if !isempty(info.internal_methods)
        for m in info.internal_methods
            isa(m, Method) || continue
            method_counts[m.module] = get(method_counts, m.module, 0) + 1
        end
        return method_counts
    end
    _GLOBAL_METHODS === nothing && return method_counts
    Base.visit(_GLOBAL_METHODS) do method
        if method.module in info.modules
            method_counts[method.module] = get(method_counts, method.module, 0) + 1
        end
    end
    return method_counts
end

function info_cachefile(pkg::PkgId, path::String, depmods::Vector{Any}, image_targets::Vector{Any}, isocache::Bool=false, verbose::Symbol=:none)
    if isocache
        sv = ccall(:jl_restore_package_image_from_file, Any, (Cstring, Any, Cint, Cstring, Cint), path, depmods, true, pkg.name, false)
    else
        sv = ccall(:jl_restore_incremental, Any, (Cstring, Any, Cint, Cstring), path, depmods, true, pkg.name)
    end
    if isa(sv, Exception)
        throw(sv)
    end
    Base.register_restored_modules(sv, pkg, path)

    parts = _unpack_restored_sv(sv)
    # External method extensions: pkg-defined methods that extend functions in other modules.
    # On 1.12 these come from the dedicated `extext_methods` slot; on 1.13+ they are mixed
    # into the unified `internal_methods` array as TypeMapEntries. Either way, unwrap to Method.
    external_methods = Method[te.func for te in parts.extext_entries if isa(te.func, Method)]
    # Split CodeInstances by whether their owning method belongs to the package's modules.
    internal_method_specializations, new_specializations =
        _split_code_instances(parts.code_instances, parts.modules)

    info = PkgCacheInfo(path, parts.modules, parts.init_order,
                        external_methods, internal_method_specializations,
                        new_specializations, parts.method_roots_list,
                        Any[], filesize(path),
                        PkgCacheSizes(parts.cachesizes_raw...),
                        image_targets, parts.internal_methods, verbose)
    return info
end

function info_cachefile(pkg::PkgId, path::String, verbose::Symbol=:none)
    return @lock require_lock begin
        local depmodnames, image_targets
        io = open(path, "r")
        try
            # isvalid_cache_header returns checksum id or zero
            isvalid_cache_header(io) == 0 && return ArgumentError("Invalid header in cache file $path.")
            header = parse_cache_header(io, path)
            depmodnames = header[3]
            # Position of `clone_targets` differs between Julia versions; locate it by type.
            clone_targets = header[findfirst(x -> x isa Vector{UInt8}, header)::Int]
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
        # then load the file. Only use the ocache (native-code) path when the cache actually
        # has clone targets recorded; otherwise the `.so`/`.dylib` may not exist (notably on
        # Julia 1.11 when precompilation was performed without native code generation).
        if !isempty(image_targets) && isdefined(Base, :ocachefile_from_cachefile)
            return info_cachefile(pkg, Base.ocachefile_from_cachefile(path), depmods, image_targets, true, verbose)
        end
        info_cachefile(pkg, path, depmods, image_targets, false, verbose)
    end
end

function info_cachefile(pkg::PkgId, verbose::Symbol=:none)
    cachefiles = find_all_in_cache_path(pkg)
    isempty(cachefiles) && error(pkg, " has not yet been precompiled for julia ", Base.VERSION)
    # On Julia >= 1.13 use `PkgLoadSpec` so the cache's recorded syntax version is checked
    # against the manifest entry rather than the running `VERSION`.
    pkgspec = if isdefined(Base, :locate_package_load_spec)
        Base.locate_package_load_spec(pkg)
    else
        locate_package(pkg)
    end
    pkgspec === nothing && error("could not locate package ", pkg)
    idx = findfirst(cachefiles) do cf
        stale_cachefile(pkgspec, cf) !== true
    end
    idx === nothing && error("all cache files for ", pkg, " are stale, please precompile")
    return info_cachefile(pkg, cachefiles[idx], verbose)
end

"""
    info_cachefile(pkgname::AbstractString; verbose::Symbol=:none) → cf
    info_cachefile(pkgid::Base.PkgId; verbose::Symbol=:none) → cf
    info_cachefile(pkgid::Base.PkgId, ji_cachefilename; verbose::Symbol=:none) → cf

Return a snapshot `cf` of a package cache file. Displaying `cf` prints a summary of the contents,
but the fields of `cf` can be inspected to get further information (see [`PkgCacheInfo`](@ref)).

The `verbose` parameter controls the level of detail in the output:
- `:none` (default): Show summary information only
- `:internal`: Show detailed information about internal methods
- `:external`: Show detailed information about external methods and specializations
- `:all`: Show detailed information about both internal and external methods

After calling `info_cachefile("MyPkg")` you can also execute `using MyPkg` to make the image loaded by
`info_cachefile` available for use. This can allow you to load `cf`s for multiple packages into the same session
for deeper analysis.

!!! warn
    Your session may be corrupted if you run `info_cachefile` for a package that had
    already been loaded into your session. Restarting with a clean session and using `info_cachefile`
    before otherwise loading the package is recommended.
"""
info_cachefile(pkgname::AbstractString; verbose::Symbol=:none) = info_cachefile(Base.identify_package(pkgname), verbose)

end
