# InfrastructureSystems.jl

```@meta
CurrentModule = InfrastructureSystems
```

## Overview

`InfrastructureSystems.jl` is a [`Julia`](http://www.julialang.org) package that provides
data management services and common utility software for modeling packages. This package is
meant for module development.

## About

`InfrastructureSystems.jl` is underlying infrastructure for the National Laboratory of the
Rockies' [Sienna](https://sienna-platform.github.io/Sienna/) modeling packages. It is used
across the Sienna applications:

- **Sienna\\Data:**
  [PowerSystems.jl](https://sienna-platform.github.io/PowerSystems.jl/stable/),
  [PowerSystemCaseBuilder.jl](https://sienna-platform.github.io/PowerSystemCaseBuilder.jl/stable/)
- **Sienna\\Ops:**
  [PowerSimulations.jl](https://sienna-platform.github.io/PowerSimulations.jl/stable/),
  [StorageSystemsSimulations.jl](https://sienna-platform.github.io/StorageSystemsSimulations.jl/stable/),
  [HydroPowerSimulations.jl](https://sienna-platform.github.io/HydroPowerSimulations.jl/stable/),
  [SiennaPRASInterface.jl](https://sienna-platform.github.io/SiennaPRASInterface.jl/stable/),
  [PowerAnalytics.jl](https://sienna-platform.github.io/PowerAnalytics.jl/stable/),
  [PowerGraphics.jl](https://sienna-platform.github.io/PowerGraphics.jl/stable/)
- **Sienna\\Net:**
  [PowerFlows.jl](https://sienna-platform.github.io/PowerFlows.jl/stable/),
  [PowerNetworkMatrices.jl](https://sienna-platform.github.io/PowerNetworkMatrices.jl/stable/)
- **Sienna\\Dyn:**
  [PowerSimulationsDynamics.jl](https://sienna-platform.github.io/PowerSimulationsDynamics.jl/stable/)
- **Sienna\\Invest:**
  [PowerSystemsInvestmentsPortfolios.jl](https://sienna-platform.github.io/PowerSystemsInvestmentsPortfolios.jl/stable/),
  [PowerSystemsInvestments.jl](https://sienna-platform.github.io/PowerSystemsInvestments.jl/stable/)

It is built to be re-usable for the development of modeling packages in other infrastructure
domains, not only power systems.

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

InfrastructureSystems has been developed as part of the Sienna ecosystem at the U.S. Department of Energy's National Laboratory of the Rockies
([NLR](https://www.nlr.gov/), formerly NREL)
