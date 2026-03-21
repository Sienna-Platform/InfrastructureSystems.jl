# Cost aliases: a simplified interface to the portion of the parametric
# `ValueCurve{FunctionData}` design that the user is likely to interact with. Each alias
# consists of a simple name for a particular `ValueCurve{FunctionData}` type, a constructor
# and methods to interact with it without having to think about `FunctionData`, and
# overridden printing behavior to complete the illusion. Everything here (aside from the
# overridden printing) is properly speaking mere syntactic sugar for the underlying
# `ValueCurve{FunctionData}` design. One could imagine similar convenience constructors and
# methods being defined for all the `ValueCurve{FunctionData}` types, not just the ones we
# have here nicely packaged and presented to the user.

# Default `is_cost_alias` is defined in value_curve.jl so it's available to
# time_series_value_curve.jl show methods (included before this file).

"""
    LinearCurve(proportional_term::Float64)
    LinearCurve(proportional_term::Float64, constant_term::Float64)

A linear curve: `f(x) = m·x + b`.

# Arguments
- `proportional_term::Float64`: slope
- `constant_term::Float64`: intercept, defaults to `0.0`

# Example
```julia
curve = LinearCurve(50.0, 100.0)
```
"""
const LinearCurve = InputOutputCurve{LinearFunctionData}

is_cost_alias(::Union{LinearCurve, Type{LinearCurve}}) = true

InputOutputCurve{LinearFunctionData}(proportional_term::Real) =
    InputOutputCurve(LinearFunctionData(proportional_term))

InputOutputCurve{LinearFunctionData}(proportional_term::Real, constant_term::Real) =
    InputOutputCurve(LinearFunctionData(proportional_term, constant_term))

"Get the proportional term (i.e., slope) of the `LinearCurve`"
get_proportional_term(vc::LinearCurve) = get_proportional_term(get_function_data(vc))

"Get the constant term (i.e., intercept) of the `LinearCurve`"
get_constant_term(vc::LinearCurve) = get_constant_term(get_function_data(vc))

Base.show(io::IO, vc::LinearCurve) =
    if isnothing(get_input_at_zero(vc))
        print(io, "$(typeof(vc))($(get_proportional_term(vc)), $(get_constant_term(vc)))")
    else
        Base.show_default(io, vc)
    end

"""
    QuadraticCurve(quadratic_term::Float64, proportional_term::Float64, constant_term::Float64)

A quadratic curve: `f(x) = q·x² + m·x + b`.

# Arguments
- `quadratic_term::Float64`: quadratic coefficient (≥ 0 for a convex function)
- `proportional_term::Float64`: linear coefficient
- `constant_term::Float64`: constant term

# Example
```julia
curve = QuadraticCurve(0.002, 25.0, 150.0)
```
"""
const QuadraticCurve = InputOutputCurve{QuadraticFunctionData}

is_cost_alias(::Union{QuadraticCurve, Type{QuadraticCurve}}) = true

InputOutputCurve{QuadraticFunctionData}(quadratic_term, proportional_term, constant_term) =
    InputOutputCurve(
        QuadraticFunctionData(quadratic_term, proportional_term, constant_term),
    )

"Get the quadratic term of the `QuadraticCurve`"
get_quadratic_term(vc::QuadraticCurve) = get_quadratic_term(get_function_data(vc))

"Get the proportional (i.e., linear) term of the `QuadraticCurve`"
get_proportional_term(vc::QuadraticCurve) = get_proportional_term(get_function_data(vc))

"Get the constant term of the `QuadraticCurve`"
get_constant_term(vc::QuadraticCurve) = get_constant_term(get_function_data(vc))

Base.show(io::IO, vc::QuadraticCurve) =
    if isnothing(get_input_at_zero(vc))
        print(
            io,
            "$(typeof(vc))($(get_quadratic_term(vc)), $(get_proportional_term(vc)), $(get_constant_term(vc)))",
        )
    else
        Base.show_default(io, vc)
    end

"""
    PiecewisePointCurve(points::Vector{Tuple{Float64, Float64}})

A piecewise linear curve defined by **(x, y) value points**.

The curve linearly interpolates between them. The y-values are **absolute values**, not
per-segment rates. If your data instead gives per-segment rates between breakpoints, use
[`PiecewiseIncrementalCurve`](@ref).

# Arguments
- `points`: vector of `(x, y)` pairs in ascending x order

# Example
```julia
curve = PiecewisePointCurve([(100.0, 400.0), (200.0, 900.0), (300.0, 1500.0)])
```
"""
const PiecewisePointCurve = InputOutputCurve{PiecewiseLinearData}

is_cost_alias(::Union{PiecewisePointCurve, Type{PiecewisePointCurve}}) = true

InputOutputCurve{PiecewiseLinearData}(points::Vector) =
    InputOutputCurve(PiecewiseLinearData(points))

"Get the points that define the `PiecewisePointCurve`"
get_points(vc::PiecewisePointCurve) = get_points(get_function_data(vc))

"Get the x-coordinates of the points that define the `PiecewisePointCurve`"
get_x_coords(vc::PiecewisePointCurve) = get_x_coords(get_function_data(vc))

"Get the y-coordinates of the points that define the `PiecewisePointCurve`"
get_y_coords(vc::PiecewisePointCurve) = get_y_coords(get_function_data(vc))

"Calculate the slopes of the line segments defined by the `PiecewisePointCurve`"
get_slopes(vc::PiecewisePointCurve) = get_slopes(get_function_data(vc))

# Here we manually circumvent the @NamedTuple{x::Float64, y::Float64} type annotation, but we keep things looking like named tuples
Base.show(io::IO, vc::PiecewisePointCurve) =
    if isnothing(get_input_at_zero(vc))
        print(io, "$(typeof(vc))([$(join(get_points(vc), ", "))])")
    else
        Base.show_default(io, vc)
    end

"""
    PiecewiseIncrementalCurve(initial_input, x_coords, slopes)
    PiecewiseIncrementalCurve(input_at_zero, initial_input, x_coords, slopes)

A piecewise step curve where each segment has a constant rate. Commonly used to represent
incremental or marginal rates. The y-values are **per-segment rates**, not absolute values.
If your data gives absolute values at each point, use [`PiecewisePointCurve`](@ref) instead.

# Arguments
- `input_at_zero`: (optional) value at zero input, stored separately from the curve.
- `initial_input`: **value at `x_coords[1]`**, anchors the curve. Set to `nothing` if
  only the shape matters.
- `x_coords`: `n` breakpoints in ascending order
- `slopes`: `n-1` rates between consecutive breakpoints

# Example
```julia
curve = PiecewiseIncrementalCurve(500.0, [100.0, 150.0, 200.0], [30.0, 35.0])
```
"""
const PiecewiseIncrementalCurve = IncrementalCurve{PiecewiseStepData}

is_cost_alias(::Union{PiecewiseIncrementalCurve, Type{PiecewiseIncrementalCurve}}) = true

IncrementalCurve{PiecewiseStepData}(initial_input, x_coords::Vector, slopes::Vector) =
    IncrementalCurve(PiecewiseStepData(x_coords, slopes), initial_input)

IncrementalCurve{PiecewiseStepData}(
    input_at_zero,
    initial_input,
    x_coords::Vector,
    slopes::Vector,
) =
    IncrementalCurve(PiecewiseStepData(x_coords, slopes), initial_input, input_at_zero)

"Get the x-coordinates that define the `PiecewiseIncrementalCurve`"
get_x_coords(vc::PiecewiseIncrementalCurve) = get_x_coords(get_function_data(vc))

"Fetch the slopes that define the `PiecewiseIncrementalCurve`"
get_slopes(vc::PiecewiseIncrementalCurve) = get_y_coords(get_function_data(vc))

Base.show(io::IO, vc::PiecewiseIncrementalCurve) =
    print(
        io,
        if isnothing(get_input_at_zero(vc))
            "$(typeof(vc))($(get_initial_input(vc)), $(get_x_coords(vc)), $(get_slopes(vc)))"
        else
            "$(typeof(vc))($(get_input_at_zero(vc)), $(get_initial_input(vc)), $(get_x_coords(vc)), $(get_slopes(vc)))"
        end,
    )

"""
    PiecewiseAverageCurve(initial_input, x_coords, y_coords)

A piecewise average-rate curve: each segment gives an average rate (total output / total
input). If your data gives incremental/marginal rates instead, use
[`PiecewiseIncrementalCurve`](@ref).

# Arguments
- `initial_input`: value at `x_coords[1]`, anchors the curve
- `x_coords`: `n` breakpoints in ascending order
- `y_coords`: `n-1` average rates per segment
"""
const PiecewiseAverageCurve = AverageRateCurve{PiecewiseStepData}

is_cost_alias(::Union{PiecewiseAverageCurve, Type{PiecewiseAverageCurve}}) = true

AverageRateCurve{PiecewiseStepData}(initial_input, x_coords::Vector, y_coords::Vector) =
    AverageRateCurve(PiecewiseStepData(x_coords, y_coords), initial_input)

"Get the x-coordinates that define the `PiecewiseAverageCurve`"
get_x_coords(vc::PiecewiseAverageCurve) = get_x_coords(get_function_data(vc))

"Get the average rates that define the `PiecewiseAverageCurve`"
get_average_rates(vc::PiecewiseAverageCurve) = get_y_coords(get_function_data(vc))

Base.show(io::IO, vc::PiecewiseAverageCurve) =
    if isnothing(get_input_at_zero(vc))
        print(
            io,
            "$(typeof(vc))($(get_initial_input(vc)), $(get_x_coords(vc)), $(get_average_rates(vc)))",
        )
    else
        Base.show_default(io, vc)
    end

# ── Time-series cost aliases ──────────────────────────────────────────────────
# Helper: format a TimeSeriesKey or Nothing for compact show output.
_ts_key_repr(key::TimeSeriesKey) = repr(get_name(key))
_ts_key_repr(::Nothing) = "nothing"

"""
    TimeSeriesLinearCurve

A time-series-backed linear input-output curve. Alias for
`TimeSeriesInputOutputCurve{TimeSeriesFunctionData{LinearFunctionData}}`.
"""
const TimeSeriesLinearCurve =
    TimeSeriesInputOutputCurve{TimeSeriesFunctionData{LinearFunctionData}}

is_cost_alias(::Union{TimeSeriesLinearCurve, Type{TimeSeriesLinearCurve}}) = true

TimeSeriesInputOutputCurve{TimeSeriesFunctionData{LinearFunctionData}}(
    key::TimeSeriesKey,
) = TimeSeriesInputOutputCurve(TimeSeriesFunctionData{LinearFunctionData}(key))

Base.show(io::IO, vc::TimeSeriesLinearCurve) =
    if isnothing(get_input_at_zero(vc))
        print(io, "$(typeof(vc))($(_ts_key_repr(get_time_series_key(vc))))")
    else
        Base.show_default(io, vc)
    end

"""
    TimeSeriesQuadraticCurve

A time-series-backed quadratic input-output curve. Alias for
`TimeSeriesInputOutputCurve{TimeSeriesFunctionData{QuadraticFunctionData}}`.
"""
const TimeSeriesQuadraticCurve =
    TimeSeriesInputOutputCurve{TimeSeriesFunctionData{QuadraticFunctionData}}

is_cost_alias(::Union{TimeSeriesQuadraticCurve, Type{TimeSeriesQuadraticCurve}}) = true

TimeSeriesInputOutputCurve{TimeSeriesFunctionData{QuadraticFunctionData}}(
    key::TimeSeriesKey,
) = TimeSeriesInputOutputCurve(TimeSeriesFunctionData{QuadraticFunctionData}(key))

Base.show(io::IO, vc::TimeSeriesQuadraticCurve) =
    if isnothing(get_input_at_zero(vc))
        print(io, "$(typeof(vc))($(_ts_key_repr(get_time_series_key(vc))))")
    else
        Base.show_default(io, vc)
    end

"""
    TimeSeriesPiecewisePointCurve

A time-series-backed piecewise linear input-output curve. Alias for
`TimeSeriesInputOutputCurve{TimeSeriesFunctionData{PiecewiseLinearData}}`.
"""
const TimeSeriesPiecewisePointCurve =
    TimeSeriesInputOutputCurve{TimeSeriesFunctionData{PiecewiseLinearData}}

is_cost_alias(
    ::Union{TimeSeriesPiecewisePointCurve, Type{TimeSeriesPiecewisePointCurve}},
) = true

TimeSeriesInputOutputCurve{TimeSeriesFunctionData{PiecewiseLinearData}}(
    key::TimeSeriesKey,
) = TimeSeriesInputOutputCurve(TimeSeriesFunctionData{PiecewiseLinearData}(key))

Base.show(io::IO, vc::TimeSeriesPiecewisePointCurve) =
    if isnothing(get_input_at_zero(vc))
        print(io, "$(typeof(vc))($(_ts_key_repr(get_time_series_key(vc))))")
    else
        Base.show_default(io, vc)
    end

"""
    TimeSeriesPiecewiseIncrementalCurve

A time-series-backed piecewise incremental curve. Alias for
`TimeSeriesIncrementalCurve{TimeSeriesFunctionData{PiecewiseStepData}}`.
"""
const TimeSeriesPiecewiseIncrementalCurve =
    TimeSeriesIncrementalCurve{TimeSeriesFunctionData{PiecewiseStepData}}

is_cost_alias(
    ::Union{
        TimeSeriesPiecewiseIncrementalCurve,
        Type{TimeSeriesPiecewiseIncrementalCurve},
    },
) = true

TimeSeriesIncrementalCurve{TimeSeriesFunctionData{PiecewiseStepData}}(
    key::TimeSeriesKey,
    initial_input::Union{Nothing, TimeSeriesKey},
) = TimeSeriesIncrementalCurve(
    TimeSeriesFunctionData{PiecewiseStepData}(key), initial_input,
)

TimeSeriesIncrementalCurve{TimeSeriesFunctionData{PiecewiseStepData}}(
    key::TimeSeriesKey,
    initial_input::Union{Nothing, TimeSeriesKey},
    input_at_zero::Union{Nothing, TimeSeriesKey},
) = TimeSeriesIncrementalCurve(
    TimeSeriesFunctionData{PiecewiseStepData}(key), initial_input, input_at_zero,
)

Base.show(io::IO, vc::TimeSeriesPiecewiseIncrementalCurve) =
    print(
        io,
        if isnothing(get_input_at_zero(vc))
            "$(typeof(vc))($(_ts_key_repr(get_time_series_key(vc))), $(_ts_key_repr(get_initial_input(vc))))"
        else
            "$(typeof(vc))($(_ts_key_repr(get_time_series_key(vc))), $(_ts_key_repr(get_initial_input(vc))), $(_ts_key_repr(get_input_at_zero(vc))))"
        end,
    )

"""
    TimeSeriesPiecewiseAverageCurve

A time-series-backed piecewise average rate curve. Alias for
`TimeSeriesAverageRateCurve{TimeSeriesFunctionData{PiecewiseStepData}}`.
"""
const TimeSeriesPiecewiseAverageCurve =
    TimeSeriesAverageRateCurve{TimeSeriesFunctionData{PiecewiseStepData}}

is_cost_alias(
    ::Union{
        TimeSeriesPiecewiseAverageCurve,
        Type{TimeSeriesPiecewiseAverageCurve},
    },
) = true

TimeSeriesAverageRateCurve{TimeSeriesFunctionData{PiecewiseStepData}}(
    key::TimeSeriesKey,
    initial_input::Union{Nothing, TimeSeriesKey},
) = TimeSeriesAverageRateCurve(
    TimeSeriesFunctionData{PiecewiseStepData}(key), initial_input,
)

TimeSeriesAverageRateCurve{TimeSeriesFunctionData{PiecewiseStepData}}(
    key::TimeSeriesKey,
    initial_input::Union{Nothing, TimeSeriesKey},
    input_at_zero::Union{Nothing, TimeSeriesKey},
) = TimeSeriesAverageRateCurve(
    TimeSeriesFunctionData{PiecewiseStepData}(key), initial_input, input_at_zero,
)

Base.show(io::IO, vc::TimeSeriesPiecewiseAverageCurve) =
    if isnothing(get_input_at_zero(vc))
        print(
            io,
            "$(typeof(vc))($(_ts_key_repr(get_time_series_key(vc))), $(_ts_key_repr(get_initial_input(vc))))",
        )
    else
        Base.show_default(io, vc)
    end
