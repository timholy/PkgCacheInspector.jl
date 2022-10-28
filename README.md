# PkgCacheInspector

[![Build Status](https://github.com/timholy/PkgCacheInspector.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/timholy/PkgCacheInspector.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/timholy/PkgCacheInspector.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/timholy/PkgCacheInspector.jl)

This package provides insight about what's stored in Julia's package precompile files. Here's a quick demo:

```julia
julia> using PkgCacheInspector

julia> info_cachefile("Colors")
modules: Any[Colors]
68 external methods
1776 new specializations of external methods
371 external methods with new roots
5113 external targets
3796 edges
system:      2021616
isbits:      2048623
symbols:       13345
tags:          28990
relocations:  214509
gvars:          5048
fptrs:          3112
```

At the top of the display, you can see a summary of the numbers of various items:

- external methods: methods added by the package to functions owned by Julia or other packages
- new specializations of external methods: freshly-compiled specializations of methods that are not internal to this package
- external methods with new roots: the number of external methods that had their `roots` table extended
- external targets: the number of external specializations that the compiled code in this package depends on
- edges: a list of internal dependencies among compiled specializations in the package

The table of numbers at the end reports the sizes of various segments of the cache file.

The display is just a summary; you can extract the full lists from the return value of `info_cachefile`.
