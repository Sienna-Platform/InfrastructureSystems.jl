"""
Return the TimeSeriesManager or nothing if the component/attribute does not support time
series.
"""
function get_time_series_manager(owner::TimeSeriesOwners)
    !supports_time_series(owner) && return nothing
    refs = get_internal(owner).shared_system_references
    isnothing(refs) && return nothing
    return refs.time_series_manager
end

function get_time_series_storage(owner::TimeSeriesOwners)
    mgr = get_time_series_manager(owner)
    if isnothing(mgr)
        return nothing
    end

    return mgr.data_store
end

"""
Return the exact stored data in a time series

This will load all forecast windows into memory by default. Be
aware of how much data is stored.

Specify `start_time` and `len` if you only need a subset of data.

# Arguments

  - `::Type{T}`: Concrete subtype of `TimeSeriesData` to return
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
  - `interval::Union{Nothing, Dates.Period} = nothing`: Required if multiple forecasts share
     the same resolution but differ by interval. Throws an error if omitted and ambiguous.
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If T is a subtype of Forecast then `start_time`
    must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length in the time dimension. If nothing, use the
    entire length.
  - `count::Union{Nothing, Int} = nothing`: Only applicable to subtypes of Forecast. Number
    of forecast windows starting at `start_time` to return. Defaults to all available.
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series_array`](@ref), [`get_time_series_values`](@ref),
[`get_time_series` by key](@ref get_time_series(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
))
"""
function get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "get_time_series" begin
        return _rust_get_time_series(
            T, owner, name;
            start_time = start_time, len = len, count = count,
            resolution = resolution, features...,
        )
    end
end

"""
Return the exact stored data in a time series, using a time series key.

This will load all forecast windows into memory by default. Be aware of how much data is stored.

Specify start_time and len if you only need a subset of data.

# Arguments

  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `key::TimeSeriesKey`: the time series' key
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If the time series is a subtype of Forecast
    then `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length in the time dimension. If nothing, use the
    entire length.
  - `count::Union{Nothing, Int} = nothing`: Only applicable to subtypes of Forecast. Number
    of forecast windows starting at `start_time` to return. Defaults to all available.
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series` by name](@ref get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData})
"""
function get_time_series(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
)
    features = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in key.features)
    return get_time_series(
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        start_time = start_time,
        len = len,
        count = count,
        features...,
    )
end

"""
Returns an iterator of TimeSeriesData instances attached to the component or attribute.

Note that passing a filter function can be much slower than the other filtering parameters
because it reads time series data from media.

Call `collect` on the result to get an array.

# Arguments

  - `owner::TimeSeriesOwners`: component or attribute from which to get time_series
  - `filter_func = nothing`: Only return time_series for which this returns true.
  - `type::Union{Nothing, ::Type{<:TimeSeriesData}} = nothing`: Only return time_series with this type.
  - `name::Union{Nothing, AbstractString} = nothing`: Only return time_series matching this value.
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Only return time_series matching this value.

See also: [`get_time_series_multiple` from a `System`](@ref get_time_series_multiple(
    data::SystemData,
    filter_func = nothing;
    type = nothing,
    name = nothing,
))
"""
function get_time_series_multiple(
    owner::TimeSeriesOwners,
    filter_func = nothing;
    type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    name::Union{Nothing, AbstractString} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    throw_if_does_not_support_time_series(owner)
    mgr = get_time_series_manager(owner)
    # This is true when the component or attribute is not part of a system.
    isnothing(mgr) && return ()
    return _rust_get_time_series_multiple(
        owner,
        filter_func;
        type = type,
        name = name,
        resolution = resolution,
        interval = interval,
    )
end

"""
Return the [`TimeSeriesKey`](@ref) identifying the single time series of type `T`
attached to `owner` under `name` (and the given resolution/interval/features).

Pairs with [`get_time_series_keys`](@ref) (enumeration) and
[`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref) (retrieval).
"""
function get_time_series_key(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(owner)
    return get_metadata(
        mgr,
        owner,
        T,
        name;
        resolution = resolution,
        interval = interval,
        features...,
    )
end

"""
Return a `TimeSeries.TimeArray` from storage for the given time series parameters.

This will load all forecast windows into memory by default. Be
aware of how much data is stored.

Specify `start_time` and `len` if you only need a subset of data.

# Arguments
  - `::Type{T}`: the type of time series (a concrete subtype of `TimeSeriesData`)
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
  - `interval::Union{Nothing, Dates.Period} = nothing`: Required if multiple forecasts share
     the same resolution but differ by interval. Throws an error if omitted and ambiguous.
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If T is a subtype of [`Forecast`](@ref) then
    `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series_values`](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
features...,) where {T <: TimeSeriesData}),
[`get_time_series_timestamps`](@ref get_time_series_timestamps(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array` from a `StaticTimeSeriesCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)),
[`get_time_series_array` from a `ForecastCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
))
"""
function get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}
    ts = get_time_series(
        T,
        owner,
        name;
        resolution = resolution,
        interval = interval,
        start_time = start_time,
        len = len,
        count = 1,
        features...,
    )
    if start_time === nothing
        start_time = get_initial_timestamp(ts)
    end

    return get_time_series_array(
        owner,
        ts;
        start_time = start_time,
        len = len,
    )
end

"""
Return a `TimeSeries.TimeArray` from storage, using a time series key.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `key::TimeSeriesKey`: the time series key
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If the time series is a subtype of [`Forecast`](@ref)
    then `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.

See also: [`get_time_series_array` by name](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values`](@ref),
[`get_time_series_timestamps`](@ref)
"""
function get_time_series_array(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    features = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in key.features)
    return get_time_series_array(
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        start_time = start_time,
        len = len,
        features...,
    )
end

"""
Return a `TimeSeries.TimeArray` for one forecast window from a cached [`Forecast`](@ref)
instance

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `forecast::Forecast`: a concrete subtype of [`Forecast`](@ref)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp of one of
    the forecast windows
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.

See also [`get_time_series_values`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)), [`get_time_series_timestamps`](@ref get_time_series_timestamps(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)), [`ForecastCache`](@ref),
[`get_time_series_array` by name from storage](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array` from a `StaticTimeSeriesCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
)
    initial_time = isnothing(start_time) ? get_initial_timestamp(forecast) : start_time
    return make_time_array(forecast, initial_time; len = len)
end

"""
Return a `TimeSeries.TimeArray` from a cached `StaticTimeSeries` instance.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `time_series::StaticTimeSeries`: subtype of `StaticTimeSeries` (e.g., `SingleTimeSeries`)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp to retrieve.
    If nothing, use the `initial_timestamp` of the time series.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number
    of timestamps). If nothing, use the entire length

See also: [`get_time_series_values`](@ref get_time_series_values(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing)),
[`get_time_series_timestamps`](@ref get_time_series_timestamps(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing,)),
[`StaticTimeSeriesCache`](@ref),
[`get_time_series_array` by name from storage](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array` from a `ForecastCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
))
"""
function get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    if start_time === nothing
        start_time = get_initial_timestamp(time_series)
    end

    if len === nothing
        len = length(time_series)
    end

    return make_time_array(time_series, start_time; len = len)
end

"""
Return a vector of timestamps from storage for the given time series parameters.

# Arguments
  - `::Type{T}`: the type of time series (a concrete subtype of `TimeSeriesData`)
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
  - `interval::Union{Nothing, Dates.Period} = nothing`: Required if multiple forecasts share
     the same resolution but differ by interval. Throws an error if omitted and ambiguous.
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If T is a subtype of [`Forecast`](@ref) then
    `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series_array`](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values`](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
features...,) where {T <: TimeSeriesData}),
[`get_time_series_timestamps` from a `StaticTimeSeriesCache`](@ref get_time_series_timestamps(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)),
[`get_time_series_timestamps` from a `ForecastCache`](@ref get_time_series_timestamps(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_timestamps(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}
    return TimeSeries.timestamp(
        get_time_series_array(
            T,
            owner,
            name;
            resolution = resolution,
            interval = interval,
            start_time = start_time,
            len = len,
            features...,
        ),
    )
end

"""
Return a vector of timestamps from storage, using a time series key.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `key::TimeSeriesKey`: the time series key
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If the time series is a subtype of [`Forecast`](@ref)
    then `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.

See also: [`get_time_series_timestamps` by name](@ref get_time_series_timestamps(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array`](@ref),
[`get_time_series_values`](@ref)
"""
function get_time_series_timestamps(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    features = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in key.features)
    return get_time_series_timestamps(
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        start_time = start_time,
        len = len,
        features...,
    )
end

"""
Return a vector of timestamps from a cached Forecast instance.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `forecast::Forecast`: a concrete subtype of [`Forecast`](@ref)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp of one of
    the forecast windows
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.

See also: [`get_time_series_array`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
)), [`get_time_series_values`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)), [`ForecastCache`](@ref),
[`get_time_series_timestamps` by name from storage](@ref get_time_series_timestamps(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_timestamps` from a `StaticTimeSeriesCache`](@ref get_time_series_timestamps(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_timestamps(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    return TimeSeries.timestamp(
        get_time_series_array(owner, forecast; start_time = start_time, len = len),
    )
end

"""
Return a vector of timestamps from a cached StaticTimeSeries instance.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `time_series::StaticTimeSeries`: subtype of `StaticTimeSeries` (e.g., `SingleTimeSeries`)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp to retrieve.
    If nothing, use the `initial_timestamp` of the time series.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number
    of timestamps). If nothing, use the entire length

See also: [`get_time_series_array`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)), [`get_time_series_values`](@ref get_time_series_values(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing)),
[`StaticTimeSeriesCache`](@ref),
[`get_time_series_timestamps` by name from storage](@ref get_time_series_timestamps(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_timestamps` from a `ForecastCache`](@ref get_time_series_timestamps(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_timestamps(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    return TimeSeries.timestamp(
        get_time_series_array(owner, time_series; start_time = start_time, len = len),
    )
end

"""
Return an vector of timeseries data without timestamps from storage

If the data size is small and this will be called many times, consider using the version
that accepts a cached `TimeSeriesData` instance.

# Arguments
  - `::Type{T}`: type of the time series (a concrete subtype of `TimeSeriesData`)
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
  - `interval::Union{Nothing, Dates.Period} = nothing`: Required if multiple forecasts share
     the same resolution but differ by interval. Throws an error if omitted and ambiguous.
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If T is a subtype of [`Forecast`](@ref) then
    `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series_array`](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_timestamps`](@ref get_time_series_timestamps(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series`](@ref),
[`get_time_series_values` from a `StaticTimeSeriesCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)),
[`get_time_series_values` from a `ForecastCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}
    return TimeSeries.values(
        get_time_series_array(
            T,
            owner,
            name;
            resolution = resolution,
            interval = interval,
            start_time = start_time,
            len = len,
            features...,
        ),
    )
end

"""
Return a vector of time series data without timestamps from storage, using a time series key.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `key::TimeSeriesKey`: the time series key
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If the time series is a subtype of [`Forecast`](@ref)
    then `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.

See also: [`get_time_series_values` by name](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array`](@ref),
[`get_time_series_timestamps`](@ref)
"""
function get_time_series_values(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    features = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in key.features)
    return get_time_series_values(
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        start_time = start_time,
        len = len,
        features...,
    )
end

"""
Return an vector of timeseries data without timestamps for one forecast window from a
cached `Forecast` instance.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `forecast::Forecast`: a concrete subtype of [`Forecast`](@ref)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp of one of
    the forecast windows
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.

See also: [`get_time_series_array`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
)), [`get_time_series_timestamps`](@ref get_time_series_timestamps(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)), [`ForecastCache`](@ref),
[`get_time_series_values` by name from storage](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values` from a `StaticTimeSeriesCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Dates.DateTime, Nothing} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    return TimeSeries.values(
        get_time_series_array(
            owner,
            forecast;
            start_time = start_time,
            len = len,
        ),
    )
end

"""
Return an vector of timeseries data without timestamps from a cached `StaticTimeSeries` instance

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `time_series::StaticTimeSeries`: subtype of `StaticTimeSeries` (e.g., `SingleTimeSeries`)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp to retrieve.
    If nothing, use the `initial_timestamp` of the time series.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number
    of timestamps). If nothing, use the entire length

See also: [`get_time_series_array`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)), [`get_time_series_timestamps`](@ref get_time_series_timestamps(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing,)),
[`StaticTimeSeriesCache`](@ref),
[`get_time_series_values` by name from storage](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values` from a `ForecastCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
))
"""
function get_time_series_values(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    return TimeSeries.values(
        get_time_series_array(
            owner,
            time_series;
            start_time = start_time,
            len = len,
        ),
    )
end

"""
Return true if the component or supplemental attribute has time series data.
"""
function has_time_series(owner::TimeSeriesOwners; kwargs...)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) && return false
    kw = Dict(kwargs)
    name = pop!(kw, :name, nothing)
    T = pop!(kw, :time_series_type, TimeSeriesData)
    isnothing(name) && return _rust_has_any(owner; time_series_type = T)
    return _rust_has_time_series(
        T === TimeSeriesData ? SingleTimeSeries : T,
        owner,
        name;
        kw...,
    )
end

"""
Return true if the component or supplemental attribute has time series data of type T.
"""
function has_time_series(
    val::TimeSeriesOwners,
    ::Type{T},
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(val)
    isnothing(mgr) && return false
    return _rust_has_any(val; time_series_type = T)
end

function has_time_series(
    val::TimeSeriesOwners,
    ::Type{T},
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(val)
    isnothing(mgr) && return false
    return _rust_has_time_series(T, val, name; resolution = resolution, features...)
end

has_time_series(
    T::Type{<:TimeSeriesData},
    owner::TimeSeriesOwners,
) = has_time_series(owner, T)

has_time_series(
    T::Type{<:TimeSeriesData},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = has_time_series(
    owner,
    T,
    name;
    resolution = resolution,
    interval = interval,
    features...,
)

"""
Efficiently add all time_series in one component to another by copying the underlying
references.

# Arguments

  - `dst::TimeSeriesOwners`: Destination owner
  - `src::TimeSeriesOwners`: Source owner
  - `name_mapping::Dict = nothing`: Optionally map src names to different dst names. If
    provided and src has a `time_series` with a name not present in `name_mapping`, that
    `time_series` will not copied. If `name_mapping` is nothing then all `time_series` will
    be copied with src's names.
"""
function copy_time_series!(
    dst::TimeSeriesOwners,
    src::TimeSeriesOwners;
    name_mapping::Union{Nothing, Dict{Tuple{String, String}, String}} = nothing,
)
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "copy_time_series" begin
        _copy_time_series!(
            dst,
            src;
            name_mapping = name_mapping,
        )
    end
end

# Return a copy of `ts` carrying `new_name`. `SingleTimeSeries` is immutable, so it
# is rebuilt through its copy constructor (the content-addressed array is reused);
# the still-mutable forecast types are deep-copied and renamed in place.
_copy_time_series_with_name(ts::SingleTimeSeries, new_name) = SingleTimeSeries(ts, new_name)

function _copy_time_series_with_name(ts, new_name)
    ts = deepcopy(ts)
    set_name!(ts, new_name)
    return ts
end

function _copy_time_series!(
    dst::TimeSeriesOwners,
    src::TimeSeriesOwners;
    name_mapping::Union{Nothing, Dict{Tuple{String, String}, String}} = nothing,
)
    mgr = get_time_series_manager(dst)
    if isnothing(mgr)
        throw(
            ArgumentError(
                "$(summary(dst)) does not have time series storage. " *
                "It may not be attached to the system.",
            ),
        )
    end

    # The Rust store is content-addressed, so re-adding a reconstructed series to
    # `dst` only creates a new association row; the underlying array is shared.
    for ts_key in get_time_series_keys(src)
        name = get_name(ts_key)
        new_name = name
        if !isnothing(name_mapping)
            new_name = get(name_mapping, (get_name(src), name), nothing)
            if isnothing(new_name)
                @debug "Skip copying ts_key" _group = LOG_GROUP_TIME_SERIES name
                continue
            end
            @debug "Copy ts_key with" _group = LOG_GROUP_TIME_SERIES new_name
        end
        feats = Dict(Symbol(k) => v for (k, v) in get_features(ts_key))
        ts = get_time_series(
            get_time_series_type(ts_key),
            src,
            name;
            resolution = get_resolution(ts_key),
            feats...,
        )
        if new_name != name
            ts = _copy_time_series_with_name(ts, new_name)
        end
        add_time_series!(mgr, dst, ts; feats...)
    end
end

"""
Return the [`TimeSeriesKey`](@ref) for each time series attached to `owner`,
optionally filtered by type/name/resolution/interval/features. Each key can be
passed to [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
function get_time_series_keys(
    owner::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) && return TimeSeriesKey[]
    return list_metadata(
        mgr,
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        features...,
    )
end

"""
$(TYPEDSIGNATURES)
Return the content hash (64-character lowercase hex string) of the array that
`key` resolves to under `owner`.

The hash identifies the underlying *stored array*, not the logical time series:
two `(owner, key)` pairs return the same hash exactly when they share the same
stored array. That happens both when identical data is deduplicated and when a
`SingleTimeSeries` and a `DeterministicSingleTimeSeries` derived from it share
their array. Throws if no stored time series matches `key`.

To enumerate every group of time series that share data across a whole system,
use [`get_shared_time_series`](@ref).
"""
get_time_series_hash(owner::TimeSeriesOwners, key::TimeSeriesKey) =
    _rust_get_time_series_hash(owner, key)

function clear_time_series!(owner::TimeSeriesOwners)
    mgr = get_time_series_manager(owner)
    if !isnothing(mgr)
        clear_time_series!(mgr, owner)
    end
    return
end

"""
This function must be called when a component or attribute is removed from a system.
"""
function prepare_for_removal!(owner::TimeSeriesOwners)
    clear_time_series!(owner)
    set_shared_system_references!(owner, nothing)
    @debug "cleared all time series data from" _group = LOG_GROUP_SYSTEM summary(owner)
    return
end

set_shared_system_references!(
    owner::TimeSeriesOwners,
    refs::Union{Nothing, SharedSystemReferences},
) =
    set_shared_system_references!(get_internal(owner), refs)

get_shared_system_references(o::TimeSeriesOwners) = o.internal.shared_system_references

function throw_if_does_not_support_time_series(owner::TimeSeriesOwners)
    if !supports_time_series(owner)
        throw(ArgumentError("$(summary(owner)) does not support time series"))
    end
end

function get_forecast_window_count(
    initial_timestamp::Dates.DateTime,
    interval::Dates.Period,
    resolution::Dates.Period,
    len::Int,
    horizon_count::Int,
)
    if interval == Dates.Second(0)
        count = 1
    else
        last_timestamp = initial_timestamp + resolution * (len - 1)
        last_initial_time = last_timestamp - resolution * (horizon_count - 1)

        # Reduce last_initial_time to the nearest interval if necessary.
        diff =
            Dates.Millisecond(last_initial_time - initial_timestamp) %
            Dates.Millisecond(interval)
        last_initial_time -= diff
        count =
            Dates.Millisecond(last_initial_time - initial_timestamp) /
            Dates.Millisecond(interval) + 1
    end

    return count
end
