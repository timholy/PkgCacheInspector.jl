module MethodAnalysisExt

using PkgCacheInspector, MethodAnalysis

function MethodAnalysis.methodinstances(info::PkgCacheInfo)
    mis = Set{Core.MethodInstance}()
    for mod in info.modules
        for mi in methodinstances_owned_by(mod)
            push!(mis, mi)
        end
    end
    for m in info.external_methods
        visit(m) do item
            if item isa Core.MethodInstance
                push!(mis, item)
                return false
            end
            return true
        end
    end
    for ci in info.new_specializations
        push!(mis, ci.def)
    end
    return mis
end

function PkgCacheInspector.count_internal_specializations(info::PkgCacheInfo)
    spec_counts = Dict{Module,Int}()

    # Get all method instances from the cache
    all_mis = methodinstances(info)

    # Count method instances by their defining module
    for mi in all_mis
        if isa(mi, Core.MethodInstance) && isa(mi.def, Method)
            method_module = mi.def.module
            if method_module in info.modules
                spec_counts[method_module] = get(spec_counts, method_module, 0) + 1
            end
        end
    end

    return spec_counts
end

end
