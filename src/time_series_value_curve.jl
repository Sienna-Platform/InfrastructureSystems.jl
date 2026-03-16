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
