# Complete Basic Requirements Checklist

Sienna packages should follow the [Diataxis](https://diataxis.fr/)
framework, be strictly compiled with [`Documenter.jl`](https://documenter.juliadocs.org/stable/)
v1.0 or greater, and be automatically formatted with
[`JuliaFormatter.jl`](https://domluna.github.io/JuliaFormatter.jl/stable/).

## For New Packages

The [`SiennaTemplate.jl`](https://github.com/Sienna-Platform/SiennaTemplate.jl) Git repo has the
required environments and formatting and documentation code. Start from this template.

## For Existing Packages

Existing Sienna packages will need to be updated with these requirements, but these will
only need to be addressed once:

 1. Organize the top-level documentation to follow the [Diataxis](https://diataxis.fr/)
    framework (plus a welcome page/section). This might be a significant undertaking. See:
    
      + How to [Write a How-to Guide](@ref)
      + How to [Write a Tutorial](@ref)
      + How to [Organize APIs and Write Docstrings](@ref)

 2. Update the Project.toml file in the `docs/` folder to replace `compat` requirements of
    `Documenter = "0.27"` with `Documenter = "1.0"`
 3. Update the `docs/make.jl` file to call
    [`Documenter.makedocs`](https://documenter.juliadocs.org/stable/lib/public/#Documenter.makedocs)
    *without* the `warnonly` `kwarg` (i.e., all errors caught by `makedocs` must be resolved before
    merging). [See an example here](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/768438a40c46767560891ec493cf87ed232a2b2b/docs/make.jl#L47).
    
      + See How-to [Troubleshoot Common Errors](@ref) if this results in a host of errors.
 4. Update the `scripts/formatter/formatter_code.jl` to format the markdown .md files in the
    `docs/` folder, calling `format`() with the `kwarg` `format_markdown = true`. See
    [these](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/768438a40c46767560891ec493cf87ed232a2b2b/scripts/formatter/formatter_code.jl#L13)
    [three](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/768438a40c46767560891ec493cf87ed232a2b2b/scripts/formatter/formatter_code.jl#L8)
    [links](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/768438a40c46767560891ec493cf87ed232a2b2b/scripts/formatter/formatter_code.jl#L23)
    for examples of the updated lines.
