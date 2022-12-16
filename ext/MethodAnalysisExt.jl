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

end
