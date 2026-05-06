# Compile and View Documentation Locally

## Pre-Step a: Update Docs Environment (First Time)

The first time you compile documentation for a package, make sure the `docs/` environment
(i.e., `docs/Manifest.toml`, not the main `Manifest.toml` in the root of the repository)
is pointing to your local version of the package, so it compiles your local changes.

From a terminal at the root of the repository (i.e., `PowerSystems.jl`), run:

```
julia --project=docs
using Pkg
Pkg.develop(path = ".")
```

## Pre-Step b: Auto-Generate Structs (If Needed)

Most documentation changes are made directly to markdown (.md) files, but if you changed one
of Sienna's .json descriptor files, you must first
[follow the instructions here](@ref "Auto-Generation of Component Structs") to auto-generate
the structs from the .json to have your changes propagated into the markdown files used for
documentation.

**Example**: You updated `PowerSystems.jl`'
[`power_system_structs.json`](https://github.com/Sienna-Platform/PowerSystems.jl/blob/main/src/descriptors/power_system_structs.json)
file.

From a terminal at the root of the repository (i.e., `PowerSystems.jl`), run:

```
julia --project=.
using InfrastructureSystems
InfrastructureSystems.generate_structs(
    "./src/descriptors/power_system_structs.json",
    "./src/models/generated",
)
```

## Pre-Step c: Run the Formatter (Before Submitting a Pull Request)

To automatically format the documentation to conform with the [style guide](@ref style_guide),
run in a terminal at the root of the repository:

```
julia scripts/formatter/formatter_code.jl
```

Resolve any errors and re-run until error-free. See how to [Troubleshoot Common Errors](@ref)
for help.

This is not a necessary step to compile, but needs to be done at least once to pass pull
request checks.

## Step 1: Compile

To compile, run in a terminal at the root of the repository:

```
julia --project=docs docs/make.jl 
```

Resolve any errors and re-run until error-free. See how to [Troubleshoot Common Errors](@ref)
for help.

## Step 2: View

Click on the newly-created `index.html` file (e.g.,
`SomeSiennaPackage/docs/build/index.html`) to view your locally compiled documentation in a
browser.

Visually verify formatting and that code blocks compile as expected.
