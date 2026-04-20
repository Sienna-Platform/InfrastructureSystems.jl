# Clean Up General Formatting

These recommendations are to make navigating our documentation effortless for users, while
addressing common markdown formatting issues in the existing Sienna documentation:

## Format in back-ticks

All package names, types, functions, methods, and parameters, etc. should formatted in
back-ticks:

!!! tip "Do"
    
    ```
    `max_active_power`
    ```
    
    compiles as `max_active_power`

!!! warning "Don't"
    
    ```
    max_active_power
    ```
    
    compiles as max_active_power

## [Put hyperlinks everywhere](@id hyperlinks)

All types, function, and methods should have hyperlinks to the correct docstring, accounting
for multiple methods of the same name due to Julia's multiple dispatch.
[`Documenter.jl`](https://documenter.juliadocs.org/stable/) will link to the first
occurrance in documentation. If that's not the one you're referring to, copy the entire
signature with types into the hyperlink reference.

!!! tip "Do"
    
    ```
    [`get_time_series_values`](@ref)
    ```
    
    Or
    
    ```
    [`get_time_series_values` from a `ForecastCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast,
    start_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
    ))
    ```

!!! warning "Don't"
    
    ```
    `get_time_series_values`
    ```
    
    Or
    
    ```
    get_time_series_values
    ```

!!! tip "Do"
    
    Define hyperlinks to other packages with an `@extref` reference, rather than hard-coded
    references which might change, using
    [`DocumenterInterLinks.jl`](http://juliadocs.org/DocumenterInterLinks.jl/stable/):
    
    ```
    [`PowerSystems.System`](@extref)
    ```
    
    compiles as [`PowerSystems.System`](@extref). See [Declaring External Projects](@extref)
    for help setting up a connection to a new package for the first time.

## Add links to other Sienna packages

All other Sienna package names should have documentation (not Git repo) hyperlinks:

!!! tip "Do"
    
    ```[`PowerSystems.jl`](https://sienna-platform.github.io/PowerSystems.jl/stable/)```

!!! warning "Don't"
    
    ```
    `PowerSystems.jl`
    ```
    
    Or
    
    ```
    PSY
    ```
    
    Or
    
    ```
    [`PowerSystems.jl`](https://github.com/Sienna-Platform/PowerSystems.jl)
    ```
