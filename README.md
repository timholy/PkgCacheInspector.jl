# PkgCacheInspector

[![Build Status](https://github.com/timholy/PkgCacheInspector.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/timholy/PkgCacheInspector.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/timholy/PkgCacheInspector.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/timholy/PkgCacheInspector.jl)

This package provides insight about what's stored in Julia's package precompile files.
This works only on Julia 1.9 and above, as it targets the new pkgimg format.

Here's a quick demo:

```julia
julia> using PkgCacheInspector

julia> info_cachefile("Colors")
Contents of /Users/user/.julia/compiled/v1.9/Colors/NKjaT_1DCqx.ji:
  modules: Any[Colors]
  68 external methods
  1759 new specializations of external methods (Base 50.1%, ColorTypes 29.8%, Base.Broadcast 11.3%, ...)
  361 external methods with new roots
  5115 external targets
  3796 edges
  file size:   4922032 (4.694 MiB)
  Segment sizes (bytes):
  system:      1971024 ( 46.65%)
  isbits:      1998959 ( 47.31%)
  symbols:       13360 (  0.32%)
  tags:          28804 (  0.68%)
  relocations:  213041 (  5.04%)
  gvars:             0 (  0.00%)
  fptrs:             0 (  0.00%)
```

At the top of the display, you can see a summary of the numbers of various items:

- external methods: methods added by the package to functions owned by Julia or other packages
- new specializations of external methods: freshly-compiled specializations of methods that are not internal to this package
- external methods with new roots: the number of external methods that had their `roots` table extended
- external targets: the number of external specializations that the compiled code in this package depends on
- edges: a list of internal dependencies among compiled specializations in the package

The table of numbers at the end reports the sizes of various segments of the cache file.

The display is just a summary; you can extract the full lists from the return value of `info_cachefile`.
