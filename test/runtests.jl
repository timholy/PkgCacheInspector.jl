using PkgCacheInspector
using MethodAnalysis
using Test
using Pkg

Pkg.precompile()

@testset "PkgCacheInspector.jl" begin
    info = info_cachefile("Colors")
    @test isa(info, PkgCacheInfo)
    str = sprint(show, info)
    @test occursin("relocations", str) && occursin("new specializations", str) && occursin("targets", str)
    @test occursin("file size", str)

    mis = methodinstances(info)
    @test eltype(mis) === Core.MethodInstance
    @test length(mis) > 100
end
