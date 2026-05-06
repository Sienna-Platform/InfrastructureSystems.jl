# Troubleshoot Common Errors

## [`Error: ## docstrings not included in the manual`](@id miss_doc)

**Problem**: Docstrings have been written, but have not been properly mapped to either a
public or internal API. There may be multiple issues to iterate through:

 1. Verify there is an Internal API .md file to catch doctrings for structs/functions that are
    not exported.
    [Example here](https://github.com/Sienna-Platform/SiennaTemplate.jl/blob/main/docs/src/reference/internal.md)

 2. Identify the `*.jl` file for one of your missing docstrings. Are other docstrings in that file
    visible in the compiled API .html?

      + **YES**: Check whether those other docstrings are listed in the Public API .md file in a
        [`@docs` block](@extref). Either:

          * Add the missing struct/function names to an appropriate `@docs` block in the
            API .md if it is manually organized. See below if this creates a
            [`no docs found`](@ref no_docs) error.
          * Preferrably, [switch to `@autodocs`](@ref use_autodocs) with the `*.jl` file
            as one of its `Pages` instead.

      + **No**: add a new [`@autodocs` block](@extref) in the Public API .md file with that
        `*.jl` file as one of its `Pages`.
 3. Are these docstrings from `InfrastructureSystems.jl`? Follow how-to
    [selectively export docstrings from `InfrastructureSystems.jl`](@ref docs_from_is).

## [`Error: no docs found for SomeFunction` or `[:docs_block]` error](@id no_docs)

No docstring has been written for `SomeFunction`.
Find the `*.jl` file containing `SomeFunction` and add a docstring.

## `Error: duplicate docs found`

> **Example**: `Error: duplicate docs found for 'PowerSimulations.SimulationProblemOutputs' in src\reference\PowerSimulations.md`

**Problem**: The same `.jl` file has been found more than once by `Documenter.jl`, which matches
based on the end of a file path.

 1. Determine which file the function is located in

    > **Example**: `simulation_problem_outputs.jl` for `PowerSimulations.SimulationProblemOutputs`

 2. Check whether that file is listed more than once in an `@autodocs` `Pages` list in the
    API markdown file (e.g., `PowerSimulations.md` or `public.md`). Remove duplicates.
 3. Also check for other files with the same partial ending in the `@autodocs` `Pages` lists
    in the API .md file. Specify more of that file path to distinguish it.

    > **Example**: Change `Pages = ["problem_outputs.jl"]` to `Pages = ["operation/problem_outputs.jl"]`

## `Parsing error for input` from `JuliaFormatter`

**Problem**: `JuliaFormatter` 1.0 gives an uninformative error message when it can't parse
something, with unhelpful line numbers. Common causes are something that is not proper Julia
syntax inside a `julia` markdown block:

````markdown
```julia
Whoops,
```
````

Or a single bracket in a markdown file:

```julia
] add PowerSystems
```

Workarounds:

  - Avoid the single bracket with alternatives:

```julia
using Pkg;
Pkg.add(["PowerSystems"]);
```

  - If you can't avoid it:

     1. Remove the text with single bracket (or other problem) temporarily
     2. Run the formatter once to format the rest of the file
     3. Add the text back in
     4. Add the `ignore` keyword argument with the file name to
        [`JuliaFormatter.format`](@extref `JuliaFormatter.format-Tuple{Any}`) in `scripts/formatter/formatter_code.jl`
        to skip the file in the future:

```julia
ignore = ["problem-file.md"]
```

You might need to iterate through multiple files.

## [How can I see the output even with errors?](@id ignore_errors)

Sometimes the easiest way to diagnose an error is to look at the generated webpage locally.

By setting `warnonly=true` in [`makedocs`](@extref Documenter.makedocs) at `make.jl`, you can
*temporarily* disable errors and build regardless. This makes it easy to track down
cross-reference errors by clicking a link and seeing what fails.

We do not allow `warnonly=true` to be used in production, so if used, this **must be removed** before a pull request is submitted.
