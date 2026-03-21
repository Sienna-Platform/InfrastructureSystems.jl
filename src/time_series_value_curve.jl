"""
    TimeSeriesInputOutputCurve{T <: TimeSeriesFunctionData} <: ValueCurve{T}

A time-series-backed input-output curve, directly relating the production quantity to the
cost: `y = f(x)`. Mirrors [`InputOutputCurve`](@ref) but the function data comes from a
time series referenced by a [`TimeSeriesKey`](@ref).
"""
@kwdef struct TimeSeriesInputOutputCurve{
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{QuadraticFunctionData},
        TimeSeriesFunctionData{PiecewiseLinearData},
    },
} <: ValueCurve{T}
    "The underlying `TimeSeriesFunctionData` representation of this `ValueCurve`"
    function_data::T
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, Float64} = nothing
end

TimeSeriesInputOutputCurve(function_data) =
    TimeSeriesInputOutputCurve(function_data, nothing)
TimeSeriesInputOutputCurve{T}(
    function_data,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{QuadraticFunctionData},
        TimeSeriesFunctionData{PiecewiseLinearData},
    },
} = TimeSeriesInputOutputCurve{T}(function_data, nothing)

"""
    TimeSeriesIncrementalCurve{T <: TimeSeriesFunctionData} <: ValueCurve{T}

A time-series-backed incremental (or 'marginal') curve, relating the production quantity to
the derivative of cost: `y = f'(x)`. Mirrors [`IncrementalCurve`](@ref) but the function
data comes from a time series referenced by a [`TimeSeriesKey`](@ref).

Structurally identical to [`TimeSeriesAverageRateCurve`](@ref); the separate type exists so
downstream packages can dispatch on incremental vs average-rate semantics when interpreting
retrieved time series data.
"""
@kwdef struct TimeSeriesIncrementalCurve{
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} <: ValueCurve{T}
    "The underlying `TimeSeriesFunctionData` representation of this `ValueCurve`"
    function_data::T
    "The initial input value, either a TimeSeriesKey or nothing"
    initial_input::Union{Nothing, TimeSeriesKey}
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, TimeSeriesKey} = nothing
end

TimeSeriesIncrementalCurve(function_data, initial_input) =
    TimeSeriesIncrementalCurve(function_data, initial_input, nothing)
TimeSeriesIncrementalCurve{T}(
    function_data,
    initial_input,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesIncrementalCurve{T}(function_data, initial_input, nothing)

"""
    TimeSeriesAverageRateCurve{T <: TimeSeriesFunctionData} <: ValueCurve{T}

A time-series-backed average rate curve, relating the production quantity to the average
cost rate from the origin: `y = f(x)/x`. Mirrors [`AverageRateCurve`](@ref) but the
function data comes from a time series referenced by a [`TimeSeriesKey`](@ref).

Structurally identical to [`TimeSeriesIncrementalCurve`](@ref); the separate type exists so
downstream packages can dispatch on incremental vs average-rate semantics when interpreting
retrieved time series data.
"""
@kwdef struct TimeSeriesAverageRateCurve{
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} <: ValueCurve{T}
    "The underlying `TimeSeriesFunctionData` representation of this `ValueCurve`"
    function_data::T
    "The initial input value, either a TimeSeriesKey or nothing"
    initial_input::Union{Nothing, TimeSeriesKey}
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, TimeSeriesKey} = nothing
end

TimeSeriesAverageRateCurve(function_data, initial_input) =
    TimeSeriesAverageRateCurve(function_data, initial_input, nothing)
TimeSeriesAverageRateCurve{T}(
    function_data,
    initial_input,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesAverageRateCurve{T}(function_data, initial_input, nothing)

# ACCESSOR EXTENSIONS
"Get the `initial_input` field of a time-series-backed `ValueCurve` (returns a `TimeSeriesKey` or `nothing`, unlike the static variant which returns `Float64`)"
get_initial_input(
    curve::Union{TimeSeriesIncrementalCurve, TimeSeriesAverageRateCurve},
) = curve.initial_input

# TIME-SERIES FORWARDING — delegates to the FunctionData level so adding new TS
# ValueCurve types does not require updating a Union here.
"Check if a `ValueCurve` is backed by time series data."
is_time_series_backed(curve::ValueCurve) =
    is_time_series_backed(get_function_data(curve))

"Get the `TimeSeriesKey` from the underlying function data of a time-series-backed `ValueCurve`."
get_time_series_key(curve::ValueCurve{<:TimeSeriesFunctionData}) =
    get_time_series_key(get_function_data(curve))

# GENERIC CONSTRUCTORS (Julia #35053 workaround)
TimeSeriesInputOutputCurve(
    function_data::T,
    input_at_zero,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{QuadraticFunctionData},
        TimeSeriesFunctionData{PiecewiseLinearData},
    },
} = TimeSeriesInputOutputCurve{T}(function_data, input_at_zero)

TimeSeriesIncrementalCurve(
    function_data::T,
    initial_input,
    input_at_zero,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesIncrementalCurve{T}(function_data, initial_input, input_at_zero)

TimeSeriesAverageRateCurve(
    function_data::T,
    initial_input,
    input_at_zero,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesAverageRateCurve{T}(function_data, initial_input, input_at_zero)

# ============================================================================
# RESOLVE TO STATIC CURVE
# Resolves a time-series-backed ValueCurve at a single timestep. Could be
# extended to return a Vector of static curves over a time interval (e.g. for
# forecast windows) by accepting a `len` parameter.
# ============================================================================

"""
Resolve a scalar `TimeSeriesKey` to the `Float64` value at the given timestep,
or pass through `nothing`.
"""
function _resolve_scalar_key(
    owner::TimeSeriesOwners,
    key::Nothing,
    start_time::Dates.DateTime,
)
    return nothing
end

function _resolve_scalar_key(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
    start_time::Dates.DateTime,
)
    vals = get_time_series_values(owner, key; start_time = start_time, len = 1)
    return vals[1]::Float64
end

"""
    build_static_curve(
        curve::TimeSeriesInputOutputCurve,
        owner::TimeSeriesOwners,
        start_time::Dates.DateTime,
    ) -> InputOutputCurve

Resolve a time-series-backed `ValueCurve` at a specific timestep, returning the
corresponding static `ValueCurve` with all time series references replaced by their
values at `start_time`.
"""
function build_static_curve(
    curve::TimeSeriesInputOutputCurve{TimeSeriesFunctionData{T}},
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
) where {T <: StaticFunctionData}
    fd_key = get_time_series_key(curve)
    fd_vals = get_time_series_values(owner, fd_key; start_time = start_time, len = 1)
    return InputOutputCurve(fd_vals[1]::T, get_input_at_zero(curve))
end

"""
    build_static_curve(
        curve::TimeSeriesIncrementalCurve,
        owner::TimeSeriesOwners,
        start_time::Dates.DateTime,
    ) -> IncrementalCurve

Resolve a time-series-backed `IncrementalCurve` at a specific timestep.
"""
function build_static_curve(
    curve::TimeSeriesIncrementalCurve{TimeSeriesFunctionData{T}},
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
) where {T <: StaticFunctionData}
    fd_key = get_time_series_key(curve)
    fd_vals = get_time_series_values(owner, fd_key; start_time = start_time, len = 1)
    initial_input =
        _resolve_scalar_key(owner, get_initial_input(curve), start_time)
    input_at_zero =
        _resolve_scalar_key(owner, get_input_at_zero(curve), start_time)
    return IncrementalCurve(fd_vals[1]::T, initial_input, input_at_zero)
end

"""
    build_static_curve(
        curve::TimeSeriesAverageRateCurve,
        owner::TimeSeriesOwners,
        start_time::Dates.DateTime,
    ) -> AverageRateCurve

Resolve a time-series-backed `AverageRateCurve` at a specific timestep.
"""
function build_static_curve(
    curve::TimeSeriesAverageRateCurve{TimeSeriesFunctionData{T}},
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
) where {T <: StaticFunctionData}
    fd_key = get_time_series_key(curve)
    fd_vals = get_time_series_values(owner, fd_key; start_time = start_time, len = 1)
    initial_input =
        _resolve_scalar_key(owner, get_initial_input(curve), start_time)
    input_at_zero =
        _resolve_scalar_key(owner, get_input_at_zero(curve), start_time)
    return AverageRateCurve(fd_vals[1]::T, initial_input, input_at_zero)
end
