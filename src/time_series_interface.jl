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

Does not apply a scaling factor multiplier.

# Arguments

  - `::Type{T}`: Concrete subtype of `TimeSeriesData` to return
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
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
    features...,
) where {T <: TimeSeriesData}
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "get_time_series" begin
        ts_metadata =
            get_time_series_metadata(T, owner, name; resolution = resolution, features...)
        start_time = _check_start_time(start_time, ts_metadata)
        rows = _get_rows(start_time, len, ts_metadata)
        columns = _get_columns(start_time, count, ts_metadata)
        storage = get_time_series_storage(owner)
        return deserialize_time_series(T, storage, ts_metadata, rows, columns)
    end
end

"""
Return the exact stored data in a time series, using a time series key.

This will load all forecast windows into memory by default. Be aware of how much data is stored.

Specify start_time and len if you only need a subset of data.

Does not apply a scaling factor multiplier.

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
)
    throw_if_does_not_support_time_series(owner)
    mgr = get_time_series_manager(owner)
    # This is true when the component or attribute is not part of a system.
    isnothing(mgr) && return ()
    storage = get_time_series_storage(owner)

    Channel() do channel
        for metadata in list_metadata(
            mgr,
            owner;
            time_series_type = type,
            name = name,
            resolution = resolution,
        )
            ts = deserialize_time_series(
                isnothing(type) ? time_series_metadata_to_data(metadata) : type,
                storage,
                metadata,
                UnitRange(1, length(metadata)),
                UnitRange(1, get_count(metadata)),
            )
            if !isnothing(filter_func) && !filter_func(ts)
                continue
            end
            put!(channel, ts)
        end
    end
end

function get_time_series_uuid(
    ::Type{T},
    component::InfrastructureSystemsComponent,
    name::AbstractString,
) where {T <: TimeSeriesData}
    metadata = get_time_series_metadata(T, component, name)
    return get_time_series_uuid(metadata)
end

function get_time_series_metadata(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(owner)
    return get_metadata(mgr, owner, T, name; resolution = resolution, features...)
end

"""
Return a `TimeSeries.TimeArray` from storage for the given time series parameters.

If the time series data are scaling factors, the returned data will be scaled by the scaling
factor multiplier by default.

This will load all forecast windows into memory by default. Be
aware of how much data is stored.

Specify `start_time` and `len` if you only need a subset of data.

# Arguments
  - `::Type{T}`: the type of time series (a concrete subtype of `TimeSeriesData`)
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If T is a subtype of [`Forecast`](@ref) then
    `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series_values`](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
)),
[`get_time_series_array` from a `ForecastCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
    ignore_scaling_factors = false,
))
"""
function get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}
    ts = get_time_series(
        T,
        owner,
        name;
        resolution = resolution,
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
        ignore_scaling_factors = ignore_scaling_factors,
    )
end

"""
Return a `TimeSeries.TimeArray` from storage, using a time series key.

If the time series data are scaling factors, the returned data will be scaled by the scaling
factor multiplier by default.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `key::TimeSeriesKey`: the time series key
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If the time series is a subtype of [`Forecast`](@ref)
    then `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`

See also: [`get_time_series_array` by name](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
)
    features = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in key.features)
    return get_time_series_array(
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        start_time = start_time,
        len = len,
        ignore_scaling_factors = ignore_scaling_factors,
        features...,
    )
end

"""
Return a `TimeSeries.TimeArray` for one forecast window from a cached [`Forecast`](@ref)
instance

If the time series data are scaling factors, the returned data will be scaled by the scaling
factor multiplier by default.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `forecast::Forecast`: a concrete subtype of [`Forecast`](@ref)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp of one of
    the forecast windows
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`

See also [`get_time_series_values`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array` from a `StaticTimeSeriesCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
))
"""
function get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
    ignore_scaling_factors = false,
)
    initial_time = isnothing(start_time) ? get_initial_timestamp(forecast) : start_time
    return _make_time_array(owner, forecast, initial_time, len, ignore_scaling_factors)
end

"""
Return a `TimeSeries.TimeArray` from a cached `StaticTimeSeries` instance.

If the time series data are scaling factors, the returned data will be scaled by the scaling
factor multiplier by default.

# Arguments
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `time_series::StaticTimeSeries`: subtype of `StaticTimeSeries` (e.g., `SingleTimeSeries`)
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: the first timestamp to retrieve.
    If nothing, use the `initial_timestamp` of the time series.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number
    of timestamps). If nothing, use the entire length
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`

See also: [`get_time_series_values`](@ref get_time_series_values(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing, ignore_scaling_factors = false)),
[`get_time_series_timestamps`](@ref get_time_series_timestamps(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing,)),
[`StaticTimeSeriesCache`](@ref),
[`get_time_series_array` by name from storage](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_array` from a `ForecastCache`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
    ignore_scaling_factors = false,
))
"""
function get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
)
    if start_time === nothing
        start_time = get_initial_timestamp(time_series)
    end

    if len === nothing
        len = length(time_series)
    end

    return _make_time_array(owner, time_series, start_time, len, ignore_scaling_factors)
end

"""
Return a vector of timestamps from storage for the given time series parameters.

# Arguments
  - `::Type{T}`: the type of time series (a concrete subtype of `TimeSeriesData`)
  - `owner::TimeSeriesOwners`: Component or attribute containing the time series
  - `name::AbstractString`: name of time series
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Required if resolution is needed
     to uniquely identify the time series.
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
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values`](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
)), [`get_time_series_values`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
)), [`get_time_series_values`](@ref get_time_series_values(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing, ignore_scaling_factors = false)),
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
  - `start_time::Union{Nothing, Dates.DateTime} = nothing`: If nothing, use the
    `initial_timestamp` of the time series. If T is a subtype of [`Forecast`](@ref) then
    `start_time` must be the first timestamp of a window.
  - `len::Union{Nothing, Int} = nothing`: Length of time-series to retrieve (i.e. number of
    timestamps). If nothing, use the entire length.
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`
  - `features...`: User-defined tags that differentiate multiple time series arrays for the
    same component attribute, such as different arrays for different scenarios or years

See also: [`get_time_series_array`](@ref get_time_series_array(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
)),
[`get_time_series_values` from a `ForecastCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
))
"""
function get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}
    return TimeSeries.values(
        get_time_series_array(
            T,
            owner,
            name;
            resolution = resolution,
            start_time = start_time,
            len = len,
            ignore_scaling_factors = ignore_scaling_factors,
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
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`

See also: [`get_time_series_values` by name](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
)
    features = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in key.features)
    return get_time_series_values(
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        start_time = start_time,
        len = len,
        ignore_scaling_factors = ignore_scaling_factors,
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
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`

See also: [`get_time_series_array`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len = nothing,
    ignore_scaling_factors = false,
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
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values` from a `StaticTimeSeriesCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
))
"""
function get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Dates.DateTime, Nothing} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
)
    return TimeSeries.values(
        get_time_series_array(
            owner,
            forecast;
            start_time = start_time,
            len = len,
            ignore_scaling_factors = ignore_scaling_factors,
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
  - `ignore_scaling_factors = false`: If `true`, the time-series data will not be multiplied by the
    result of calling the stored `scaling_factor_multiplier` function on the `owner`

See also: [`get_time_series_array`](@ref get_time_series_array(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
)), [`get_time_series_timestamps`](@ref get_time_series_timestamps(owner::TimeSeriesOwners, time_series::StaticTimeSeries; start_time::Union{Nothing, Dates.DateTime} = nothing, len::Union{Nothing, Int} = nothing,)),
[`StaticTimeSeriesCache`](@ref),
[`get_time_series_values` by name from storage](@ref get_time_series_values(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
    features...,
) where {T <: TimeSeriesData}),
[`get_time_series_values` from a `ForecastCache`](@ref get_time_series_values(
    owner::TimeSeriesOwners,
    forecast::Forecast;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
))
"""
function get_time_series_values(
    owner::TimeSeriesOwners,
    time_series::StaticTimeSeries;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    ignore_scaling_factors = false,
)
    return TimeSeries.values(
        get_time_series_array(
            owner,
            time_series;
            start_time = start_time,
            len = len,
            ignore_scaling_factors = ignore_scaling_factors,
        ),
    )
end

function _make_time_array(owner, time_series, start_time, len, ignore_scaling_factors)
    ta = make_time_array(time_series, start_time; len = len)
    if ignore_scaling_factors
        return ta
    end

    multiplier = get_scaling_factor_multiplier(time_series)
    if multiplier === nothing
        return ta
    end

    return ta .* multiplier(owner)
end

"""
Return true if the component or supplemental attribute has time series data.
"""
function has_time_series(owner::TimeSeriesOwners; kwargs...)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) && return false
    return has_metadata(mgr.metadata_store, owner; kwargs...)
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
    return has_metadata(mgr.metadata_store, val; time_series_type = T)
end

function has_time_series(
    val::TimeSeriesOwners,
    ::Type{T},
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(val)
    isnothing(mgr) && return false
    return has_metadata(
        mgr.metadata_store,
        val;
        time_series_type = T,
        name = name,
        resolution = resolution,
        features...,
    )
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
    features...,
) = has_time_series(owner, T, name; resolution = resolution, features...)

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
  - `scaling_factor_multiplier_mapping::Dict = nothing`: Optionally map src multipliers to
    different dst multipliers.  If provided and src has a `time_series` with a multiplier
    not present in `scaling_factor_multiplier_mapping`, that `time_series` will not copied.
    If `scaling_factor_multiplier_mapping` is nothing then all `time_series` will be copied
    with src's multipliers.
"""
function copy_time_series!(
    dst::TimeSeriesOwners,
    src::TimeSeriesOwners;
    name_mapping::Union{Nothing, Dict{Tuple{String, String}, String}} = nothing,
    scaling_factor_multiplier_mapping::Union{Nothing, Dict{String, String}} = nothing,
)
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "copy_time_series" begin
        _copy_time_series!(
            dst,
            src;
            name_mapping = name_mapping,
            scaling_factor_multiplier_mapping = scaling_factor_multiplier_mapping,
        )
    end
end

function _copy_time_series!(
    dst::TimeSeriesOwners,
    src::TimeSeriesOwners;
    name_mapping::Union{Nothing, Dict{Tuple{String, String}, String}} = nothing,
    scaling_factor_multiplier_mapping::Union{Nothing, Dict{String, String}} = nothing,
)
    storage = get_time_series_storage(dst)
    if isnothing(storage)
        throw(
            ArgumentError(
                "$(summary(dst)) does not have time series storage. " *
                "It may not be attached to the system.",
            ),
        )
    end

    mgr = get_time_series_manager(dst)
    @assert !isnothing(mgr)

    for ts_metadata in get_time_series_metadata(src)
        name = get_name(ts_metadata)
        new_name = name
        if !isnothing(name_mapping)
            new_name = get(name_mapping, (get_name(src), name), nothing)
            if isnothing(new_name)
                @debug "Skip copying ts_metadata" _group = LOG_GROUP_TIME_SERIES name
                continue
            end
            @debug "Copy ts_metadata with" _group = LOG_GROUP_TIME_SERIES new_name
        end
        multiplier = get_scaling_factor_multiplier(ts_metadata)
        new_multiplier = multiplier
        if !isnothing(scaling_factor_multiplier_mapping)
            new_multiplier = get(scaling_factor_multiplier_mapping, multiplier, nothing)
            if isnothing(new_multiplier)
                @debug "Skip copying ts_metadata" _group = LOG_GROUP_TIME_SERIES multiplier
                continue
            end
            @debug "Copy ts_metadata with" _group = LOG_GROUP_TIME_SERIES new_multiplier
        end
        new_time_series = deepcopy(ts_metadata)
        assign_new_uuid_internal!(new_time_series)
        set_name!(new_time_series, new_name)
        set_scaling_factor_multiplier!(new_time_series, new_multiplier)
        add_metadata!(mgr.metadata_store, dst, new_time_series)
    end
end

"""
Return information about each time series array attached to the owner.
This information can be used to call
[`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
function get_time_series_keys(owner::TimeSeriesOwners)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) && return []
    return get_time_series_keys(mgr.metadata_store, owner)
end

function get_time_series_metadata(
    owner::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) && return []
    return list_metadata(
        mgr,
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        features...,
    )
end

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

"""
Return a time series from TimeSeriesFileMetadata.

# Arguments

  - `cache::TimeSeriesParsingCache`: cached data
  - `ts_file_metadata::TimeSeriesFileMetadata`: metadata
  - `resolution::{Nothing, Dates.Period}`: skip any time_series that don't match this resolution
"""
function make_time_series!(
    cache::TimeSeriesParsingCache,
    ts_file_metadata::TimeSeriesFileMetadata,
)
    info = add_time_series_info!(cache, ts_file_metadata)
    return ts_file_metadata.time_series_type(info)
end

function add_time_series_info!(
    cache::TimeSeriesParsingCache,
    metadata::TimeSeriesFileMetadata,
)
    time_series = _add_time_series_info!(cache, metadata)
    info = TimeSeriesParsedInfo(metadata, time_series)
    @debug "Added TimeSeriesParsedInfo" _group = LOG_GROUP_TIME_SERIES metadata
    return info
end

function _get_columns(start_time, count, ts_metadata::ForecastMetadata)
    offset = start_time - get_initial_timestamp(ts_metadata)
    interval = time_period_conversion(get_interval(ts_metadata))
    window_count = get_count(ts_metadata)
    if window_count > 1
        index = Int(offset / interval) + 1
    else
        index = 1
    end
    if count === nothing
        count = window_count - index + 1
    end

    if index + count - 1 > get_count(ts_metadata)
        throw(
            ArgumentError(
                "The requested start_time $start_time and count $count are invalid",
            ),
        )
    end
    return UnitRange(index, index + count - 1)
end

_get_columns(start_time, count, ts_metadata::StaticTimeSeriesMetadata) = UnitRange(1, 1)

function _get_rows(start_time, len, ts_metadata::StaticTimeSeriesMetadata)
    index = compute_time_array_index(
        get_initial_timestamp(ts_metadata),
        start_time,
        get_resolution(ts_metadata),
    )
    if len === nothing
        len = length(ts_metadata) - index + 1
    end
    if index + len - 1 > length(ts_metadata)
        throw(
            ArgumentError(
                "The requested index=$index len=$len exceeds the range $(length(ts_metadata))",
            ),
        )
    end

    return UnitRange(index, index + len - 1)
end

function _get_rows(start_time, len, ts_metadata::ForecastMetadata)
    if len === nothing
        len = get_horizon_count(ts_metadata)
    end

    return UnitRange(1, len)
end

function _check_start_time(start_time, metadata::StaticTimeSeriesMetadata)
    return _check_start_time_common(start_time, metadata)
end

function _check_start_time(start_time, metadata::ForecastMetadata)
    initial_time = get_initial_timestamp(metadata)
    actual_start_time = _check_start_time_common(start_time, metadata)
    if actual_start_time != initial_time
        # This will throw ArgumentError if start_time is not on a multiple of interval.
        compute_periods_between(initial_time, actual_start_time, get_interval(metadata))
    end
    return actual_start_time
end

function _check_start_time_common(start_time, metadata::TimeSeriesMetadata)
    if start_time === nothing
        return get_initial_timestamp(metadata)
    end

    if start_time < get_initial_timestamp(metadata)
        throw(
            ArgumentError(
                "start_time = $start_time is earlier than $(get_initial_timestamp(metadata))",
            ),
        )
    end

    last_time = _get_last_user_start_timestamp(metadata)
    if start_time > last_time
        throw(
            ArgumentError(
                "start_time = $start_time is greater than the last timestamp $last_time",
            ),
        )
    end

    return start_time
end

function _get_last_user_start_timestamp(metadata::StaticTimeSeriesMetadata)
    return get_initial_timestamp(metadata) +
           (get_length(metadata) - 1) * get_resolution(metadata)
end

function _get_last_user_start_timestamp(forecast::ForecastMetadata)
    return get_initial_timestamp(forecast) +
           (get_count(forecast) - 1) * get_interval(forecast)
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
