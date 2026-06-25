using PkgCacheInspector
using PkgCacheInspector: extending_external_methods
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

    # extending_external_methods returns a subset of external_methods, filtered to those
    # whose function-type module is outside the worklist.
    colors_info = info_cachefile("Colors", verbose = :none)
    eem = extending_external_methods(colors_info)
    @test eem isa Vector{Method}
    @test issubset(Set(eem), Set(colors_info.external_methods))
    worklist = Set(colors_info.modules)
    @test all(m -> !(Base.unwrap_unionall(m.sig).parameters[1] isa DataType &&
                     Base.unwrap_unionall(m.sig).parameters[1].name.module in worklist), eem)
    @test isempty(extending_external_methods(empty_info("EmptyPkg.so", [EmptyPkg])))
end
