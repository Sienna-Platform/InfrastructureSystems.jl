# Using Local Test Data with PowerSystemCaseBuilder

By default, [`PowerSystemCaseBuilder`](https://github.com/Sienna-Platform/PowerSystemCaseBuilder.jl) fetches test data from Julia's official artifact system. When developing or modifying test data, you may need to use a local copy of the test data instead. This guide explains how to configure [`PowerSystemCaseBuilder`](https://github.com/Sienna-Platform/PowerSystemCaseBuilder.jl) to use local test data.

## Steps to Use Local Test Data

### 1. Clone the Required Repositories

Clone both [`PowerSystemCaseBuilder.jl`](https://github.com/Sienna-Platform/PowerSystemCaseBuilder.jl) and [`PowerSystemsTestData`](https://github.com/Sienna-Platform/PowerSystemsTestData):

```bash
git clone https://github.com/Sienna-Platform/PowerSystemCaseBuilder.jl.git
git clone https://github.com/Sienna-Platform/PowerSystemsTestData.git
```

Alternatively, if you're working within a Julia environment, you can use `dev` to clone [`PowerSystemCaseBuilder.jl`](https://github.com/Sienna-Platform/PowerSystemCaseBuilder.jl):

```julia
using Pkg
Pkg.develop("PowerSystemCaseBuilder")
```

(This won't work on [`PowerSystemsTestData`](https://github.com/Sienna-Platform/PowerSystemsTestData), because it isn't a Julia package.)

### 2. Modify the Data Directory Path

Open `PowerSystemCaseBuilder.jl/src/definitions.jl` and locate the `DATA_DIR` constant:

```julia
const DATA_DIR = joinpath(LazyArtifacts.artifact"CaseData", "PowerSystemsTestData-4.0.2")
```

Change it to point to your local [`PowerSystemsTestData`](https://github.com/Sienna-Platform/PowerSystemsTestData) directory:

```julia
const DATA_DIR = "/path/to/your/PowerSystemsTestData"
```

### 3. Clear Cached Systems After Modifying Test Data

After making changes to [`PowerSystemsTestData`](https://github.com/Sienna-Platform/PowerSystemsTestData), Julia may still use cached versions of the systems that don't reflect your modifications. You have two options to ensure your changes take effect:

**Option A: Clear all cached systems**

```julia
using PowerSystemCaseBuilder
PowerSystemCaseBuilder.clear_all_serialized_systems()
```

**Option B: Force rebuild on demand**

Pass the `force_build = true` keyword argument when calling [`build_system`](@extref PowerSystemCaseBuilder.build_system):

```julia
sys = build_system(SomeSystemCategory, "system_name"; force_build = true)
```

This approach is useful when you only want to rebuild specific systems rather than clearing the entire cache.
