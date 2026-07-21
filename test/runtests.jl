using PkgCacheInspector
using PkgCacheInspector: extending_external_methods
using MethodAnalysis
using Test
using Pkg

@show Base.JLOptions().code_coverage   # coverage must be off to write .so pkgimages

Pkg.precompile("Colors")

module EmptyPkg end

module MethodOwnerFixture
struct LocalCtor
    value::Int
end
LocalCtor(; value=1) = LocalCtor(value)
local_kw(x; increment=1) = x + increment
Base.show(io::IO, value::LocalCtor) = print(io, value.value)
end

# Test-only constructors for an "empty" PkgCacheInfo (no associated cachefile).
empty_cachesizes() = PkgCacheSizes(0, 0, 0, 0, 0, 0, 0)
function empty_info(cachefile::AbstractString, modules; external_methods=Method[])
    PkgCacheInfo(cachefile, Vector{Module}(modules), [], external_methods,
                 Core.CodeInstance[], Core.CodeInstance[], [], [],
                 0, empty_cachesizes(), [], Method[], :none)
end

@testset "PkgCacheInspector.jl" begin
    # Current Julia master returns a 6-element complete-info loader tuple.
    raw_sizes = (1, 2, 3, 4, 5, 6, 7)
    parts = PkgCacheInspector._unpack_restored_sv((
        Module[EmptyPkg], Any[], Any[], Any[], Any[], raw_sizes,
    ))
    @test parts.modules == Module[EmptyPkg]
    @test parts.method_roots_list == Any[]
    @test parts.cachesizes_raw === raw_sizes

    info = info_cachefile("Colors", verbose = :all)
    @test isa(info, PkgCacheInfo)
    str = sprint(show, info)
    @test occursin("relocations", str) && occursin("new specializations", str) && occursin("targets", str)
    @test occursin("file size", str)
    @test occursin("Internal methods", str)
    @test occursin("specializations of internal methods", str)

    # Colorbars: the method-summary bar and the segment-sizes bar are both full width,
    # and the summary bar's legend lists nonzero categories with counts.
    bar = Regex("\\[■{$(PkgCacheInspector._BAR_WIDTH)}\\]")
    @test length(collect(eachmatch(bar, str))) == 2
    @test occursin(r"■ internal methods \d+", str)
    @test occursin(r"■ external methods \d+", str)

    # _bar_widths fills the bar exactly and keeps every nonzero segment visible.
    @test sum(PkgCacheInspector._bar_widths([1, 10000, 0, 3])) == PkgCacheInspector._BAR_WIDTH
    @test PkgCacheInspector._bar_widths([1, 10000, 0, 3])[[1, 3, 4]] == [1, 0, 1]
    @test PkgCacheInspector._bar_widths([0, 0]) == [0, 0]

    mis = methodinstances(info)
    @test eltype(mis) === Core.MethodInstance
    @test length(mis) > 100

    # Repeated info_cachefile on the same package returns the cached result with a warning
    # (loading the same pkgimage twice in one session segfaults the runtime).
    info_again = @test_logs (:warn, r"already called"i) info_cachefile("Colors", verbose = :none)
    @test isa(info_again, PkgCacheInfo)
    @test info_again.cachefile == info.cachefile
    @test info_again.verbose === :none
    @test occursin(r"\d+ internal methods", sprint(show, info_again))

    # AbstractString paths forward `verbose` as a keyword.
    missing_path = SubString(joinpath(tempdir(), "PkgCacheInspector-definitely-missing.ji"), 1)
    @test_throws SystemError info_cachefile(Base.PkgId("Missing"), missing_path; verbose=:all)

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
    @test all(m -> PkgCacheInspector._extension_owner_module(m) ∉ worklist, eem)
    @test isempty(extending_external_methods(empty_info("EmptyPkg.so", [EmptyPkg])))

    # Constructors and keyword wrappers for package-owned functions are internal;
    # an actual extension of Base.show is external.
    ctor_method = which(MethodOwnerFixture.LocalCtor, (Int,))
    kw_method = which(
        Core.kwcall,
        (NamedTuple{(:increment,), Tuple{Int}}, typeof(MethodOwnerFixture.local_kw), Int),
    )
    show_method = which(show, (IO, MethodOwnerFixture.LocalCtor))
    owner_info = empty_info(
        "MethodOwnerFixture.so",
        [MethodOwnerFixture];
        external_methods=Method[ctor_method, kw_method, show_method],
    )
    @test PkgCacheInspector._extension_owner_module(ctor_method) === MethodOwnerFixture
    @test PkgCacheInspector._extension_owner_module(kw_method) === MethodOwnerFixture
    @test PkgCacheInspector._extension_owner_module(show_method) === Base
    @test extending_external_methods(owner_info) == Method[show_method]
end
