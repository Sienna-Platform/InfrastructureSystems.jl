"""
    mutable struct DeterministicSingleTimeSeries <: AbstractDeterministic
        single_time_series::SingleTimeSeries
        initial_timestamp::Dates.DateTime
        interval::Dates.Period
        count::Int
        horizon::Int
    end

A deterministic forecast that wraps a [`SingleTimeSeries`](@ref)

`DeterministicSingleTimeSeries` behaves exactly like a [`Deterministic`](@ref), but
instead of storing windows at each initial time it provides a view into the existing
`SingleTimeSeries` at incrementing offsets. This avoids large data duplications when 
there are the overlapping windows between forecasts. 

Can be used as a perfect forecast based on historical data when real forecast data
is unavailable. 

# Arguments

  - `single_time_series::SingleTimeSeries`: wrapped `SingleTimeSeries` object
  - `initial_timestamp::Dates.DateTime`: time series availability time
  - `interval::Dates.Period`: time step between forecast windows
  - `count::Int`: number of forecast windows
  - `horizon::Int`: length of this time series
"""
struct DeterministicSingleTimeSeries{T, N} <: AbstractDeterministic
    "wrapped SingleTimeSeries object"
    single_time_series::SingleTimeSeries{T, N}
    "time series availability time"
    initial_timestamp::Dates.DateTime
    "time step between forecast windows"
    interval::Dates.Period
    "number of forecast windows"
    count::Int
    "length of this time series"
    horizon::Dates.Period
end

# `{T, N}` is propagated from the wrapped SingleTimeSeries.
function DeterministicSingleTimeSeries(
    single_time_series::SingleTimeSeries{T, N},
    initial_timestamp::Dates.DateTime,
    interval::Dates.Period,
    count::Integer,
    horizon::Dates.Period,
) where {T, N}
    return DeterministicSingleTimeSeries{T, N}(
        single_time_series,
        initial_timestamp,
        interval,
        Int(count),
        horizon,
    )
end

function DeterministicSingleTimeSeries(;
    single_time_series,
    initial_timestamp,
    interval,
    count,
    horizon,
)
    return DeterministicSingleTimeSeries(
        single_time_series,
        initial_timestamp,
        interval,
        count,
        horizon,
    )
end

get_name(value::DeterministicSingleTimeSeries) = get_name(value.single_time_series)
"""
Get [`DeterministicSingleTimeSeries`](@ref) `single_time_series`.
"""
get_single_time_series(value::DeterministicSingleTimeSeries) = value.single_time_series
"""
Get [`DeterministicSingleTimeSeries`](@ref) `initial_timestamp`.
"""
get_initial_timestamp(value::DeterministicSingleTimeSeries) = value.initial_timestamp
"""
Get [`DeterministicSingleTimeSeries`](@ref) `interval`.
"""
get_interval(value::DeterministicSingleTimeSeries) = value.interval
"""
Get [`DeterministicSingleTimeSeries`](@ref) `count`.
"""
get_count(value::DeterministicSingleTimeSeries) = value.count
"""
Get [`DeterministicSingleTimeSeries`](@ref) `horizon`.
"""
get_horizon(value::DeterministicSingleTimeSeries) = value.horizon

eltype_data(ts::DeterministicSingleTimeSeries) = eltype_data(ts.single_time_series)

function get_array_for_hdf(forecast::DeterministicSingleTimeSeries)
    return get_array_for_hdf(forecast.single_time_series)
end

get_resolution(val::DeterministicSingleTimeSeries) = get_resolution(val.single_time_series)
get_horizon_count(val::DeterministicSingleTimeSeries) =
    get_horizon_count(get_horizon(val), get_resolution(val))

function get_window(
    forecast::DeterministicSingleTimeSeries,
    initial_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
)
    compute_time_array_index(
        get_initial_timestamp(forecast),
        initial_time,
        get_interval(forecast),
    )

    if isnothing(len)
        len = get_horizon_count(forecast)
    end

    ta = get_data(forecast.single_time_series)
    resolution = get_resolution(forecast)
    end_time = initial_time + (len - 1) * resolution
    timestamps = TimeSeries.timestamp(ta)
    for timestamp in (initial_time, end_time)
        @assert timestamp >= first(timestamps) && timestamp <= last(timestamps) "invalid " *
                                                                                "timestamp=$timestamp is not within $(first(timestamps)) - $(last(timestamps))"
    end

    return ta[initial_time:resolution:end_time]
end

"""
Iterate over the windows in a forecast

# Examples
```julia
for window in iterate_windows(forecast)
    @show values(maximum(window))
end
```
"""
function iterate_windows(forecast::DeterministicSingleTimeSeries)
    if get_count(forecast) == 1
        return (get_window(forecast, get_initial_timestamp(forecast)),)
    end

    initial_times =
        range(forecast.initial_timestamp; step = forecast.interval, length = forecast.count)
    return (get_window(forecast, it) for it in initial_times)
end
