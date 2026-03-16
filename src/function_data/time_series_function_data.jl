"""
    TimeSeriesFunctionData{T <: FunctionData} <: FunctionData

A parametric `FunctionData` variant whose numerical data lives in a time series rather than
inline. The type parameter `T` specifies the static [`FunctionData`](@ref) subtype that the
time series elements correspond to — same shape, but instead of holding numbers directly, it
holds a [`TimeSeriesKey`](@ref) that points to a time series of `T` values.

Use these when cost function parameters change at each simulation timestep (e.g.,
time-varying market offers).

Use [`is_time_series_backed`](@ref) to check at runtime, and [`get_time_series_key`](@ref)
to retrieve the key.

# Convenience aliases
- `TimeSeriesLinearFunctionData` = `TimeSeriesFunctionData{LinearFunctionData}`
- `TimeSeriesQuadraticFunctionData` = `TimeSeriesFunctionData{QuadraticFunctionData}`
- `TimeSeriesPiecewiseLinearData` = `TimeSeriesFunctionData{PiecewiseLinearData}`
- `TimeSeriesPiecewiseStepData` = `TimeSeriesFunctionData{PiecewiseStepData}`
"""
@kwdef struct TimeSeriesFunctionData{T <: FunctionData} <: FunctionData
    time_series_key::TimeSeriesKey
end

"Time-series-backed variant of [`LinearFunctionData`](@ref)."
const TimeSeriesLinearFunctionData = TimeSeriesFunctionData{LinearFunctionData}

"Time-series-backed variant of [`QuadraticFunctionData`](@ref)."
const TimeSeriesQuadraticFunctionData = TimeSeriesFunctionData{QuadraticFunctionData}

"Time-series-backed variant of [`PiecewiseLinearData`](@ref)."
const TimeSeriesPiecewiseLinearData = TimeSeriesFunctionData{PiecewiseLinearData}

"Time-series-backed variant of [`PiecewiseStepData`](@ref)."
const TimeSeriesPiecewiseStepData = TimeSeriesFunctionData{PiecewiseStepData}

"""
    get_time_series_key(fd::TimeSeriesFunctionData) -> TimeSeriesKey

Return the `TimeSeriesKey` that references the underlying time series data.
"""
get_time_series_key(fd::TimeSeriesFunctionData) = fd.time_series_key

"""
    is_time_series_backed(fd::FunctionData) -> Bool

Return `true` if `fd` is a `TimeSeriesFunctionData` whose numerical values come
from a time series, `false` otherwise.
"""
is_time_series_backed(::FunctionData) = false
is_time_series_backed(::TimeSeriesFunctionData) = true

"""
    get_underlying_function_data_type(::Type{TimeSeriesFunctionData{T}}) -> Type{T}

Return the concrete `FunctionData` type that the time series elements correspond to.
"""
get_underlying_function_data_type(::Type{TimeSeriesFunctionData{T}}) where {T} = T

# Instance convenience
get_underlying_function_data_type(fd::TimeSeriesFunctionData) =
    get_underlying_function_data_type(typeof(fd))

# Display
function Base.show(io::IO, ::MIME"text/plain", fd::TimeSeriesFunctionData)
    ts_key = get_time_series_key(fd)
    underlying = get_underlying_function_data_type(fd)
    print(
        io,
        "TimeSeriesFunctionData{$underlying} backed by time series \"$(get_name(ts_key))\" ",
        "of $underlying",
    )
end
