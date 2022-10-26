using PkgCacheInspector
using Documenter

DocMeta.setdocmeta!(PkgCacheInspector, :DocTestSetup, :(using PkgCacheInspector); recursive=true)

makedocs(;
    modules=[PkgCacheInspector],
    authors="Tim Holy <tim.holy@gmail.com> and contributors",
    repo="https://github.com/timholy/PkgCacheInspector.jl/blob/{commit}{path}#{line}",
    sitename="PkgCacheInspector.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://timholy.github.io/PkgCacheInspector.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/timholy/PkgCacheInspector.jl",
    devbranch="main",
)
