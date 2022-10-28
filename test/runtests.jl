using PkgCacheInspector
using Test

@testset "PkgCacheInspector.jl" begin
    info = info_cachefile("Colors")
    @test isa(info, PkgCacheInfo)
    str = sprint(show, info)
    @test occursin("relocations", str) && occursin("new specializations", str) && occursin("targets", str)
end
