# InfrastructureSystems.jl

```@meta
CurrentModule = InfrastructureSystems
```

## Overview

`InfrastructureSystems.jl` is a [`Julia`](http://www.julialang.org) package that provides
data management services and common utility software for the packages in
NLR's [Sienna Initiative](https://github.com/Sienna-Platform). This package is meant
for module development. It is used primarily by
[PowerSystems.jl](https://github.com/Sienna-Platform/PowerSystems.jl) and
[PowerSimulations.jl](https://github.com/Sienna-Platform/PowerSimulations.jl) but is
written to be extensible for other kinds of infrastructure models.

This document describes how to integrate it with other packages.

### Installation

The latest stable release of `InfrastructureSystems.jl` can be installed using the Julia
package manager with

```julia
] add InfrastructureSystems
```

For the current development version, "checkout" this package with

```julia
] add InfrastructureSystems#main
```

### Usage

`InfrastructureSystems.jl` does not export any method or struct by design. For detailed
use of `InfrastructureSystems.jl` visit the [API](@ref API_ref) section of the documentation.

`InfrastructureSystems.jl` provides several utilities for the development of packages, the
documentation includes several guides for developers

```@contents
Pages = [
        "dev_guide/components_and_container.md",
        "dev_guide/auto_generation.md",
        "dev_guide/time_series.md",
        "dev_guide/recorder.md",
        "dev_guide/tests.md",
        "dev_guide/logging.md"
]
Depth = 1
```

* * *

InfrastructureSystems has been developed as part of the Scalable Integrated Infrastructure Planning
(SIIP) initiative at the U.S. Department of Energy's National Laboratory of the Rockies
([NLR](https://www.nlr.gov/), formerly NREL)
