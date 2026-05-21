using PkgCacheInspector
using MethodAnalysis
using Test
using Pkg

@show Base.JLOptions().code_coverage   # coverage must be off to write .so pkgimages

Pkg.precompile()

module EmptyPkg end

@testset "PkgCacheInspector.jl" begin
    info = info_cachefile("Colors", verbose = :all)
    @test isa(info, PkgCacheInfo)
    str = sprint(show, info)
    @test occursin("relocations", str) && occursin("new specializations", str) && occursin("targets", str)
    @test occursin("file size", str)
    @test occursin("internal methods", str)
    @test occursin("specializations of internal methods", str)

    mis = methodinstances(info)
    @test eltype(mis) === Core.MethodInstance
    @test length(mis) > 100

    # Empty pkgimages do not cause issues
    info = PkgCacheInfo("EmptyPkg.so", [EmptyPkg])
    str = sprint(show, info)
    @test occursin(r"modules: .*EmptyPkg\]", str)
    @test occursin(r"file size: +0 \(0 bytes\)", str)
end
