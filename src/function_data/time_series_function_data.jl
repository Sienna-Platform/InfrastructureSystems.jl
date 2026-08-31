"""
    TimeSeriesFunctionData{T <: StaticFunctionData, U <: TimeSeriesData{T}} <: FunctionData

A parametric `FunctionData` variant whose numerical data lives in a time series rather than
inline. `T` is the static [`FunctionData`](@ref) subtype the time series elements correspond
to and `U` is the time series type holding them — same shape as a `T`, but instead of the
numbers it holds a [`TimeSeriesKey`](@ref) naming where they are.

`U` is bounded by `TimeSeriesData{T}`, so the two parameters cannot disagree: a
`TimeSeriesFunctionData{PiecewiseLinearData}` can only wrap a key naming a series of
`PiecewiseLinearData`. Write the one-parameter form — `U` is inferred from the key.

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
@kwdef struct TimeSeriesFunctionData{T <: StaticFunctionData, U <: TimeSeriesData{T}} <:
              FunctionData
    time_series_key::TimeSeriesKey{U}
end

# `U` follows from the key, so the one-parameter spelling every alias and call
# site already uses keeps working. The bound `U <: TimeSeriesData{T}` then does
# the checking: a key naming a series of some other element type cannot be
# wrapped as this `T`, which a two-field struct could only have discovered on
# read.
TimeSeriesFunctionData{T}(key::TimeSeriesKey{U}) where {T, U} =
    TimeSeriesFunctionData{T, U}(key)

# `@kwdef` generates its keyword constructor for the fully-applied type only, so
# the one-parameter spelling needs its own — deserialization reaches the struct
# by keyword.
TimeSeriesFunctionData{T}(; time_series_key::TimeSeriesKey{U}) where {T, U} =
    TimeSeriesFunctionData{T, U}(time_series_key)

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

"Fallback: throw a clear `ArgumentError` when `get_time_series_key` is called on non-TS-backed function data."
get_time_series_key(fd::FunctionData) = throw(
    ArgumentError(
        "$(nameof(typeof(fd))) is not time-series-backed; get_time_series_key is undefined",
    ),
)

"""
    is_time_series_backed(fd::FunctionData) -> Bool

Return `true` if `fd` is a `TimeSeriesFunctionData` whose numerical values come
from a time series, `false` otherwise.
"""
is_time_series_backed(::FunctionData) = false
is_time_series_backed(::TimeSeriesFunctionData) = true

"""
    get_underlying_function_data_type(::Type{<:TimeSeriesFunctionData{T}}) -> Type{T}

Return the concrete `FunctionData` type that the time series elements correspond to.
"""
get_underlying_function_data_type(::Type{<:TimeSeriesFunctionData{T}}) where {T} = T

"The time series type holding the values — the `U` of `TimeSeriesFunctionData{T, U}`."
get_time_series_type(::Type{<:TimeSeriesFunctionData{T, U}}) where {T, U} = U
get_time_series_type(fd::TimeSeriesFunctionData) = get_time_series_type(typeof(fd))

# Instance convenience
get_underlying_function_data_type(fd::TimeSeriesFunctionData) =
    get_underlying_function_data_type(typeof(fd))

# Display
function Base.show(io::IO, ::MIME"text/plain", fd::TimeSeriesFunctionData)
    ts_key = get_time_series_key(fd)
    underlying = get_underlying_function_data_type(fd)
    print(
        io,
        "TimeSeriesFunctionData{$underlying} backed by the time series at ",
        "association_id=$(get_association_id(ts_key)) of $underlying",
    )
end
