using PkgCacheInspector
using MethodAnalysis
using Test
using Pkg

@show Base.JLOptions().code_coverage   # coverage must be off to write .so pkgimages

Pkg.precompile("Colors")

module EmptyPkg end

# Test-only constructors for an "empty" PkgCacheInfo (no associated cachefile).
empty_cachesizes() = PkgCacheSizes(0, 0, 0, 0, 0, 0, 0)
function empty_info(cachefile::AbstractString, modules)
    PkgCacheInfo(cachefile, Vector{Module}(modules), [], Method[],
                 Core.CodeInstance[], Core.CodeInstance[], [], [],
                 0, empty_cachesizes(), [], Method[], :none)
end

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

    # Repeated info_cachefile on the same package returns the cached result with a warning
    # (loading the same pkgimage twice in one session segfaults the runtime).
    info_again = @test_logs (:warn, r"already called"i) info_cachefile("Colors", verbose = :none)
    @test isa(info_again, PkgCacheInfo)
    @test info_again.cachefile == info.cachefile
    @test info_again.verbose === :none

    # Empty pkgimages do not cause issues
    info = empty_info("EmptyPkg.so", [EmptyPkg])
    str = sprint(show, info)
    @test occursin(r"modules: .*EmptyPkg\]", str)
    @test occursin(r"file size: +0 \(0 bytes\)", str)
end
