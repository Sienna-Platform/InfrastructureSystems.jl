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

A constant-marginal-rate cost curve: `cost(x) = m·x + b`.

The simplest cost representation. Use when marginal cost doesn't change with output level.
If cost increases with output, use [`QuadraticCurve`](@ref) or
[`PiecewiseIncrementalCurve`](@ref) instead.

# Arguments
- `proportional_term::Float64`: marginal rate (e.g., \$/MWh)
- `constant_term::Float64`: no-load cost (e.g., \$/h), defaults to `0.0`

# Example
```julia
curve = LinearCurve(50.0, 100.0)  # \$50/MWh marginal rate, \$100/h no-load cost
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

A smooth quadratic cost curve: `cost(x) = q·x² + m·x + b`.

Use when you have a polynomial fit to heat rate data with a smooth, increasing marginal
cost. For non-smooth piecewise costs (e.g., market bid stacks), use
[`PiecewiseIncrementalCurve`](@ref) instead.

# Arguments
- `quadratic_term::Float64`: quadratic coefficient (≥ 0 for a convex, physical cost curve)
- `proportional_term::Float64`: linear coefficient
- `constant_term::Float64`: constant (no-load) term

# Example
```julia
curve = QuadraticCurve(0.002, 25.0, 150.0)  # slightly increasing marginal cost, \$150/h no-load
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

A piecewise linear cost curve defined by **absolute (production, total-cost) points**.

Each point is `(MW, \$/h)`. The curve linearly interpolates between them. The y-values are
**total costs**, not marginal rates. If your data instead gives marginal rates between
breakpoints (e.g., a bid stack), use [`PiecewiseIncrementalCurve`](@ref).

**Optimization formulation:** uses the **lambda (convex combination)** formulation — one
λ variable per breakpoint, `P = Σ λᵢ·Pᵢ`, `C = Σ λᵢ·Cᵢ`. For non-convex cost curves
(marginal rate decreases at some breakpoint) an SOS2 binary constraint is automatically
added, making the problem a MILP. Use [`PiecewiseIncrementalCurve`](@ref) if you want
the delta formulation, which avoids SOS2 entirely.

# Arguments
- `points`: vector of `(production, total_cost)` pairs in ascending production order

# Example
```julia
# 100 MW → \$400/h, 200 MW → \$900/h, 300 MW → \$1500/h
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

A piecewise marginal-rate curve: each segment has a constant \$/MWh rate.

**This is the standard format for generator bid stacks and market offers.** The y-values
are marginal rates (slopes), not total costs. If your data gives total cost at each output
level, use [`PiecewisePointCurve`](@ref) instead.

**Optimization formulation:** uses the **delta (block-offer)** formulation — one δ variable
per segment, `P = Σ δₖ + offset`, `C = Σ δₖ · slopeₖ`, with per-segment width bounds
`δₖ ≤ Pₖ₊₁ - Pₖ`. The segment bounds enforce ordering without SOS2, so **non-convex
curves (decreasing slopes) do not require binary variables**. This is why market offer
stacks always use this format rather than [`PiecewisePointCurve`](@ref).

# Arguments
- `input_at_zero`: (optional) cost at zero production — separate from the curve, use when
  the generator has a cost even at zero output (e.g., spinning reserve)
- `initial_input`: **total cost at `x_coords[1]`** (the minimum production point), anchors
  the curve. Set to `nothing` if only the shape matters (e.g., dispatch without costing).
- `x_coords`: `n` production breakpoints in ascending order (e.g., MW)
- `slopes`: `n-1` marginal rates between consecutive breakpoints (e.g., \$/MWh)

# Example
```julia
# \$30/MWh from 100→150 MW, \$35/MWh from 150→200 MW; total cost at 100 MW = \$500/h
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

A piecewise average-rate curve: each segment gives average cost per unit output.

Use when your data source gives **average** heat rates or costs (total fuel / total output)
at each production level, not incremental/marginal rates. Less common than
[`PiecewiseIncrementalCurve`](@ref) for market bids; more common for fuel efficiency tables.

# Arguments
- `initial_input`: **total cost at `x_coords[1]`** (the minimum production point)
- `x_coords`: `n` production breakpoints in ascending order (e.g., MW)
- `y_coords`: `n-1` average rates per segment (e.g., MBTU/MWh — total fuel / total output)
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
