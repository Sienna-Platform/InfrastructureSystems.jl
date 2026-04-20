# Useful Links

  - [Diataxis](https://diataxis.fr/): Reference for the new
    documentation framework Sienna is striving to follow (not specific to Julia)

  - Julia's guidance on [Writing Documentation](@extref)
  - [`Documenter.jl`](https://documenter.juliadocs.org/stable/): Julia's documentation
    package, the [Syntax](https://documenter.juliadocs.org/stable/man/syntax/) and
    [Showcase](https://documenter.juliadocs.org/stable/showcase/) pages are
    especially useful
    
      + [`DocumenterInterLinks.jl`](http://juliadocs.org/DocumenterInterLinks.jl/stable/): A helper
        package for making hyperlinks between packages using
        [`Documenter.jl`](https://documenter.juliadocs.org/stable/)'s [`@extref` link](@extref)
        syntax, without hardcoded urls that can get out of date
      + [`DocStringExtensions.jl`](https://docstringextensions.juliadocs.org/stable/): Another helper
        package to automate docstrings formatting, including signatures and arguments lists
  - [`SiennaTemplate.jl` Git repository](https://github.com/Sienna-Platform/SiennaTemplate.jl): A
    template for new Sienna packages that includes the required documentation framework.
