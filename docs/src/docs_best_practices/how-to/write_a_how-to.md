# Write a How-to Guide

A How-To guides a user trying to accomplish a certain task in their work, or address a
problem or series of linked problems.

## Prepare

  - If you have not read [Diataxis](https://diataxis.fr/), first read it in its entirety.
  - If you have read it, skim the pages on [How-to guides](https://diataxis.fr/how-to-guides/) and
    the [difference between a tutorial and how-to guide](https://diataxis.fr/tutorials-how-to/)
    to refresh your memory and refer back throughout the process.
  - Look at an example: this page, how to [Compile and View Documentation Locally](@ref), and
    how to [Troubleshoot Common Errors](@ref) are all examples.

## Follow the Do's and Don't's

The [Diataxis How-to's](https://diataxis.fr/how-to-guides/) page should be your main reference
as you write, but in addition, use these guidelines to
ensure we follow Diataxis and avoid common pitfalls from previous versions of Sienna
documentation:

```@contents
Pages = ["write_a_how-to.md"]
Depth = 3:3
```

### Omit the Unnecessary

!!! tip "Do"
    
    Jump the user right to a logical starting point in the code using `#hide` or
    [`@setup`](https://documenter.juliadocs.org/stable/man/syntax/#reference-at-setup)
    blocks.

!!! tip "Do"
    
    [Configure the logger](@ref log) or load/build a `System` that returns very
    few log statements. Use semi-colons at line ends to hide return statements if need be.

### Make it effortless to read

!!! tip "Do"
    
    Split code examples into ideally 1 (to 3) lines ONLY, with a short preface
    to explain what each line is doing, even if it's obvious to you.

### Move Docstring Material to the APIs

An issue with earlier versions of Sienna documentation was basic reference information
located in pages other than the APIs.
See how-to [Organize APIs and Write Docstrings](@ref) if needed to make that information
easier to find.

!!! tip "Do"
    
    Preface each call to a new function with a hyperlink to that function's
    docstring so the user can find more detail

!!! warning "Don't"
    
    Include digressive details about different keyword arguments or versions of
    a function.

### Minimize or Eliminate How-To Guides with a Single Step

A how-to guide has a *sequence* of steps -- if your guide only has a single step, ask
yourself if you are compensating for a lack of information in the API's.

!!! tip "Do"
    
    Move how-to guides with a single function to being Examples in that
    function's docstring. See [Writing Documentation](@extref Julia :doc:`manual/documentation`).

### Remove Other Reference Material

Particularly when editing existing pages, watch out for other
[Reference](https://diataxis.fr/reference/) material.

!!! tip "Do"
    
    Move tables and lists of information into Reference pages and link to them instead

### Follow the Guidelines on Cleaning Up General Formatting

!!! tip "Do"
    
    Follow How-to [Clean Up General Formatting](@ref).

### Look at the compiled .html!

!!! tip "Do"
    
      - [Compile](@ref "Compile and View Documentation Locally") the how-to guide regularly and
        look at it
      - Check all code examples gave the expected results without erroring
      - Check for length of the code examples and iteratively adjust to make it easy
        to read
