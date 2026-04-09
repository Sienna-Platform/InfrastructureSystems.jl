const TIME_SERIES_CACHE_SIZE_BYTES = 1024 * 1024

abstract type TimeSeriesCache end

function Base.iterate(cache::TimeSeriesCache, state = nothing)
    if state === nothing
        reset!(cache)
    end

    ta = get_next_time_series_array!(cache)
    if ta === nothing
        reset!(cache)
        return nothing
    end

    # Unlike standard Julia iterators, state is maintained internally.
    return ta, 1
end

Base.length(c::TimeSeriesCache) = _get_num_iterations(c)

"""
Return the TimeSeries.TimeArray starting at timestamp.
Reads from storage if the data is not already in cache.

Timestamps must be read sequentially. Repeated reads are allowed. Random access may be added
in the future.

# Arguments

  - `cache::StaticTimeSeriesCache`: cached instance
  - `timestamp::Dates.DateTime`: starting timestamp for the time series array
"""
function get_time_series_array!(cache::TimeSeriesCache, timestamp::Dates.DateTime)
    _check_timestamp(cache, timestamp)
    next_time = get_next_time(cache)

    if timestamp > _get_last_cached_time(cache)
        @debug "get_time_series_array! update cache" _group = LOG_GROUP_TIME_SERIES timestamp next_time
        _update!(cache)
    else
        @debug "get_time_series_array! data is in cache" _group = LOG_GROUP_TIME_SERIES timestamp next_time
    end

    len = _get_length(cache)
    ta = get_time_series_array(
        _get_component(cache),
        _get_time_series(cache);
        start_time = timestamp,
        len = len,
        ignore_scaling_factors = _get_ignore_scaling_factors(cache),
    )
    if !isnothing(next_time) && timestamp == next_time
        _increment_next_time!(cache, len)
        _decrement_iterations_remaining!(cache)
        _set_last_timestamp_read!(cache, timestamp)
    end
    return ta
end

function _check_timestamp(cache::TimeSeriesCache, timestamp::Dates.DateTime)
    last_read = _get_last_timestamp_read(cache)
    next_time = get_next_time(cache)

    if last_read < _get_start_time(cache)
        if timestamp != next_time
            throw(InvalidValue("Invalid request. Valid timestamps are [$next_time]."))
        end
    elseif isnothing(next_time)
        if timestamp != last_read
            throw(InvalidValue("Invalid request. Valid timestamps are [$last_read]."))
        end
    elseif timestamp != next_time && timestamp != last_read
        throw(
            InvalidValue("Invalid request. Valid timestamps are [$last_read, $next_time]."),
        )
    end
end

"""
Return the next TimeSeries.TimeArray.

Returns `nothing` when all data has been read. Call [`reset!`](@ref) to restart.
Call [`get_next_time`](@ref) to check the start time.

Reads from storage if the data is not already in cache.

# Arguments

  - `cache::StaticTimeSeriesCache`: cached instance

# Examples
```julia
cache = ForecastCache(Deterministic, component, "max_active_power")
window1 = get_next_time_series_array!(cache)
window2 = get_next_time_series_array!(cache)
```
"""
function get_next_time_series_array!(cache::TimeSeriesCache)
    next_time = get_next_time(cache)
    if next_time === nothing
        return
    end

    return get_time_series_array!(cache, next_time)
end

"""
Return the timestamp for the next read with [`get_next_time_series_array!`](@ref).

Return `nothing` if all data has been read.
"""
function get_next_time(cache::TimeSeriesCache)
    if _get_iterations_remaining(cache) == 0
        return
    end

    return cache.common.next_time[]
end

"""
Reset parameters in order to start reading data from the beginning with
[`get_next_time_series_array!`](@ref)
"""
reset!(cache::TimeSeriesCache) = _reset!(cache.common)

_get_component(c::TimeSeriesCache) = _get_component(c.common)
_get_last_cached_time(c::TimeSeriesCache) = c.common.last_cached_time[]
_get_length_available(c::TimeSeriesCache) = c.common.length_available[]
_set_length_available!(c::TimeSeriesCache, len) = c.common.length_available[] = len
_get_length_remaining(c::TimeSeriesCache) = c.common.length_remaining[]
_get_last_timestamp_read(c::TimeSeriesCache) = c.common.last_read_time[]
_set_last_timestamp_read!(c::TimeSeriesCache, val) = c.common.last_read_time[] = val
_get_start_time(c::TimeSeriesCache) = c.common.start_time
_decrement_length_remaining!(c::TimeSeriesCache, num) = c.common.length_remaining[] -= num
_get_name(c::TimeSeriesCache) = c.common.name
_get_num_iterations(c::TimeSeriesCache) = c.common.num_iterations
_get_ignore_scaling_factors(c::TimeSeriesCache) = c.common.ignore_scaling_factors
_get_type(c::TimeSeriesCache) = typeof(c.common.ts[])
_get_time_series(c::TimeSeriesCache) = c.common.ts[]
_set_time_series!(c::TimeSeriesCache, ts) = c.common.ts[] = ts
_get_iterations_remaining(c::TimeSeriesCache) = c.common.iterations_remaining[]
_decrement_iterations_remaining!(c::TimeSeriesCache) = c.common.iterations_remaining[] -= 1
_get_resolution(cache::TimeSeriesCache) = get_resolution(_get_time_series(cache))

struct TimeSeriesCacheKey
    component_uuid::Base.UUID
    time_series_type::Type{<:TimeSeriesData}
    name::String
end

struct TimeSeriesCacheCommon{T <: TimeSeriesData, U <: InfrastructureSystemsComponent}
    ts::Base.RefValue{T}
    component::U
    name::String
    start_time::Dates.DateTime
    next_time::Base.RefValue{Dates.DateTime}
    last_cached_time::Base.RefValue{Dates.DateTime}
    last_read_time::Base.RefValue{Dates.DateTime}
    "Total length"
    len::Int
    "Cached data available to read"
    length_available::Base.RefValue{Int}
    "Length remaining to be read on disk"
    length_remaining::Base.RefValue{Int}
    "Total iterations to traverse all data"
    num_iterations::Int
    iterations_remaining::Base.RefValue{Int}
    ignore_scaling_factors::Bool

    function TimeSeriesCacheCommon(;
        ts,
        component,
        name,
        next_time,
        len,
        num_iterations,
        ignore_scaling_factors,
    )
        return new{typeof(ts), typeof(component)}(
            Ref(ts),
            component,
            name,
            next_time,
            Ref(next_time),
            Ref(next_time - Dates.Minute(1)),
            Ref(next_time - Dates.Minute(1)),
            len,
            Ref(0),
            Ref(len),
            num_iterations,
            Ref(num_iterations),
            ignore_scaling_factors,
        )
    end
end

_get_component(c::TimeSeriesCacheCommon) = c.component

function _reset!(common::TimeSeriesCacheCommon)
    common.next_time[] = common.start_time
    common.last_cached_time[] = common.start_time - Dates.Minute(1)
    common.last_read_time[] = common.last_cached_time[]
    common.length_available[] = common.len
    common.length_remaining[] = common.len
    common.iterations_remaining[] = common.num_iterations
    return
end

struct ForecastCache{T <: TimeSeriesData, U <: InfrastructureSystemsComponent} <:
       TimeSeriesCache
    common::TimeSeriesCacheCommon{T, U}
    in_memory_count::Int
    horizon_count::Int
    interval::Union{Nothing, Dates.Period}
end

"""
Construct ForecastCache to automatically control caching of forecast data.
Maintains some count of forecast windows in memory based on `cache_size_bytes`.

Call Base.iterate or [`get_next_time_series_array!`](@ref) to retrieve data. Each iteration
will return a TimeSeries.TimeArray covering one forecast window of length `horizon_count`.

# Arguments

  - `::Type{T}`: subtype of Forecast
  - `component::InfrastructureSystemsComponent`: component
  - `name::AbstractString`: forecast name
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: forecast start time
  - `horizon_count::Union{Nothing, Int} = nothing`: forecast horizon count
  - `cache_size_bytes = TIME_SERIES_CACHE_SIZE_BYTES`: maximum size of data to keep in memory
  - `ignore_scaling_factors = false`: controls whether to ignore `scaling_factor_multiplier`
    in the time series instance
"""
function ForecastCache(
    ::Type{T},
    component::InfrastructureSystemsComponent,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    horizon_count::Union{Nothing, Int} = nothing,
    cache_size_bytes = TIME_SERIES_CACHE_SIZE_BYTES,
    ignore_scaling_factors = false,
    interval::Union{Nothing, Dates.Period} = nothing,
) where {T <: Forecast}
    ts_metadata = get_time_series_metadata(T, component, name; interval = interval)
    initial_timestamp = get_initial_timestamp(ts_metadata)
    if start_time === nothing
        start_time = initial_timestamp
    end
    if isnothing(horizon_count)
        horizon_count = get_horizon_count(ts_metadata)
    end

    # Get one instance to assess data size.
    ts = get_time_series(
        T,
        component,
        name;
        start_time = start_time,
        len = get_horizon_count(ts_metadata),
        interval = interval,
    )
    vals = get_time_series_values(
        component,
        ts;
        start_time = start_time,
        len = get_horizon_count(ts_metadata),
    )
    row_size = _get_row_size(vals)

    count = get_count(ts_metadata)
    if start_time != initial_timestamp
        count -=
            Dates.Millisecond(start_time - initial_timestamp) ÷
            Dates.Millisecond(get_interval(ts_metadata))
    end

    window_size = row_size * horizon_count
    in_memory_count = minimum((cache_size_bytes ÷ window_size, count))
    @debug "ForecastCache" _group = LOG_GROUP_TIME_SERIES row_size window_size in_memory_count

    return ForecastCache(
        TimeSeriesCacheCommon(;
            ts = ts,
            component = component,
            name = name,
            next_time = start_time,
            len = count,
            num_iterations = count,
            ignore_scaling_factors = ignore_scaling_factors,
        ),
        in_memory_count,
        horizon_count,
        interval,
    )
end

function _get_count(cache::ForecastCache)
    return minimum((cache.in_memory_count, _get_length_remaining(cache)))
end

_get_length(c::ForecastCache) = c.horizon_count

function _update!(cache::ForecastCache)
    if _get_length_remaining(cache) == 0
        throw(ArgumentError("Exceeded time series range"))
    end

    count = _get_count(cache)
    next_time = get_next_time(cache)
    len = _get_length(cache)
    ts = get_time_series(
        _get_type(cache),
        _get_component(cache),
        _get_name(cache);
        start_time = next_time,
        len = len,
        count = count,
        interval = cache.interval,
    )
    _set_length_available!(cache, len)
    _set_time_series!(cache, ts)
    _set_last_cached_time!(cache, next_time)
    _decrement_length_remaining!(cache, count)
    return
end

function _increment_next_time!(cache::ForecastCache, len)
    cache.common.next_time[] += get_interval(_get_time_series(cache))
    return
end

function _set_last_cached_time!(cache::ForecastCache, next_time)
    interval = get_interval(_get_time_series(cache))
    cache.common.last_cached_time[] = next_time + (cache.in_memory_count - 1) * interval
    return
end

struct StaticTimeSeriesCache{T <: TimeSeriesData, U <: InfrastructureSystemsComponent} <:
       TimeSeriesCache
    common::TimeSeriesCacheCommon{T, U}
    in_memory_rows::Int
end

"""
Construct StaticTimeSeriesCache to automatically control caching of time series data.
Maintains rows of data in memory based on `cache_size_bytes`.

Call Base.iterate or [`get_time_series_array`](@ref) to retrieve data. Each iteration will
return a TimeSeries.TimeArray of size 1.

# Arguments

  - `::Type{T}`: subtype of StaticTimeSeries
  - `component::InfrastructureSystemsComponent`: component
  - `name::AbstractString`: time series name
  - `cache_size_bytes = TIME_SERIES_CACHE_SIZE_BYTES`: maximum size of data to keep in memory
  - `ignore_scaling_factors = false`: controls whether to ignore `scaling_factor_multiplier`
    in the time series instance
"""
function StaticTimeSeriesCache(
    ::Type{T},
    component::InfrastructureSystemsComponent,
    name::AbstractString;
    cache_size_bytes = TIME_SERIES_CACHE_SIZE_BYTES,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    ignore_scaling_factors = false,
) where {T <: StaticTimeSeries}
    ts_metadata = get_time_series_metadata(T, component, name)
    initial_timestamp = get_initial_timestamp(ts_metadata)
    if start_time === nothing
        start_time = initial_timestamp
    end

    total_length = length(ts_metadata)
    if start_time != initial_timestamp
        total_length -= (start_time - initial_timestamp) ÷ get_resolution(ts_metadata)
    end

    # Get an instance to assess data size.
    ts = get_time_series(T, component, name; start_time = start_time, len = 1)
    vals = get_time_series_values(component, ts; start_time = start_time, len = 1)
    row_size = _get_row_size(vals)

    if row_size > cache_size_bytes
        @warn "Increasing cache size to $row_size in order to accommodate" row_size
        cache_size_bytes = row_size
    end
    in_memory_rows = minimum((cache_size_bytes ÷ row_size, total_length))

    @debug "StaticTimeSeriesCache" _group = LOG_GROUP_TIME_SERIES total_length in_memory_rows
    return StaticTimeSeriesCache(
        TimeSeriesCacheCommon(;
            ts = ts,
            component = component,
            name = name,
            next_time = start_time,
            len = total_length,
            num_iterations = total_length,
            ignore_scaling_factors = ignore_scaling_factors,
        ),
        in_memory_rows,
    )
end

_get_count(c::StaticTimeSeriesCache) = nothing
_get_length(cache::StaticTimeSeriesCache) = 1

function _update!(cache::StaticTimeSeriesCache)
    if _get_length_remaining(cache) == 0
        throw(ArgumentError("Exceeded time series range"))
    end

    len = minimum((cache.in_memory_rows, _get_length_remaining(cache)))
    next_time = get_next_time(cache)
    ts = get_time_series(
        _get_type(cache),
        _get_component(cache),
        _get_name(cache);
        start_time = next_time,
        len = len,
    )
    _set_length_available!(cache, len)
    _set_time_series!(cache, ts)
    _set_last_cached_time!(cache, next_time, len)
    _decrement_length_remaining!(cache, len)
    return
end

function _set_last_cached_time!(cache::StaticTimeSeriesCache, next_time, len)
    cache.common.last_cached_time[] = next_time + (len - 1) * _get_resolution(cache)
    return
end

function _increment_next_time!(cache::StaticTimeSeriesCache, len)
    cache.common.next_time[] += len * get_resolution(_get_time_series(cache))
    return
end

function _get_row_size(vals)
    dims = ndims(vals)
    if dims == 1
        row_size = sizeof(vals[1])
    elseif dims == 2
        row_size = sizeof(vals[1, :])
    elseif dims == 3
        row_size = sizeof(vals[1, :, :])
    else
        error("dims=$dims is not supported")
    end

    return row_size
end

function make_time_series_cache(
    ::Type{T},
    component,
    name,
    initial_time,
    len::Int;
    ignore_scaling_factors = true,
) where {T <: StaticTimeSeries}
    return StaticTimeSeriesCache(
        T,
        component,
        name;
        start_time = initial_time,
        ignore_scaling_factors = ignore_scaling_factors,
    )
end

function make_time_series_cache(
    ::Type{T},
    component,
    name,
    initial_time,
    horizon_count::Int;
    ignore_scaling_factors = true,
    interval::Union{Nothing, Dates.Period} = nothing,
) where {T <: AbstractDeterministic}
    return ForecastCache(
        T,
        component,
        name;
        start_time = initial_time,
        horizon_count = horizon_count,
        ignore_scaling_factors = ignore_scaling_factors,
        interval = interval,
    )
end

function make_time_series_cache(
    ::Type{Probabilistic},
    component,
    name,
    initial_time,
    horizon_count::Int;
    ignore_scaling_factors = true,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    return ForecastCache(
        Probabilistic,
        component,
        name;
        start_time = initial_time,
        horizon_count = horizon_count,
        ignore_scaling_factors = ignore_scaling_factors,
        interval = interval,
    )
end
