# This is used to add time series associations efficiently in SQLite.
# This strikes a balance in SQLite efficiency vs loading many time arrays into memory.
const ADD_TIME_SERIES_BATCH_SIZE = 100

mutable struct BulkUpdateTSCache
    forecast_params::Union{Nothing, ForecastParameters}
end

mutable struct TimeSeriesManager <: InfrastructureSystemsType
    data_store::TimeSeriesStorage
    metadata_store::TimeSeriesMetadataStore
    read_only::Bool
    bulk_update_cache::Union{Nothing, BulkUpdateTSCache}
end

function TimeSeriesManager(;
    data_store = nothing,
    metadata_store = nothing,
    in_memory = false,
    read_only = false,
    directory = nothing,
    compression = CompressionSettings(),
)
    if isnothing(directory) && haskey(ENV, TIME_SERIES_DIRECTORY_ENV_VAR)
        directory = ENV[TIME_SERIES_DIRECTORY_ENV_VAR]
    end

    if isnothing(metadata_store)
        metadata_store = TimeSeriesMetadataStore()
    end

    if isnothing(data_store)
        data_store = make_time_series_storage(;
            in_memory = in_memory,
            directory = directory,
            compression = compression,
        )
    end
    return TimeSeriesManager(data_store, metadata_store, read_only, nothing)
end

_get_forecast_params(ts::Forecast) = make_time_series_parameters(ts)
_get_forecast_params(::StaticTimeSeries) = nothing
_get_forecast_params!(::TimeSeriesManager, ::StaticTimeSeries) = nothing

function _get_forecast_params!(mgr::TimeSeriesManager, forecast::Forecast)
    # The time to read forecast parameters from the database can be slow, particularly when
    # large numbers of StaticTimeSeries are stored.
    # During a bulk update, cache it.
    if isnothing(mgr.bulk_update_cache)
        return get_forecast_parameters(mgr.metadata_store)
    end

    if isnothing(mgr.bulk_update_cache.forecast_params)
        mgr.bulk_update_cache.forecast_params = get_forecast_parameters(mgr.metadata_store)
        if isnothing(mgr.bulk_update_cache.forecast_params)
            mgr.bulk_update_cache.forecast_params = _get_forecast_params(forecast)
        end
    end

    return mgr.bulk_update_cache.forecast_params
end

"""
Begin an update of time series. Use this function when adding many time series arrays
in order to improve performance.

If an error occurs during the update, changes will be reverted.

Using this function to remove time series is currently not supported.
"""
function begin_time_series_update(
    func::Function,
    mgr::TimeSeriesManager,
)
    open_store!(mgr.data_store, "r+") do
        original_ts_uuids = Set(list_existing_time_series_uuids(mgr.metadata_store))
        mgr.bulk_update_cache = BulkUpdateTSCache(nothing)
        try
            SQLite.transaction(mgr.metadata_store.db) do
                func()
            end
            optimize_database!(mgr.metadata_store)
        catch
            # If an error occurs, we can easily remove new time series data to ensure
            # that the metadata database is consistent with the data.
            # We currently can't restore time series data that was deleted.
            new_ts_uuids = setdiff(
                Set(list_existing_time_series_uuids(mgr.metadata_store)),
                original_ts_uuids,
            )
            for uuid in new_ts_uuids
                remove_time_series!(mgr.data_store, uuid)
            end
            rethrow()
        finally
            mgr.bulk_update_cache = nothing
        end
    end
end

function bulk_add_time_series!(
    mgr::TimeSeriesManager,
    associations;
    kwargs...,
)
    # TODO: deprecate this function if team agrees
    ts_keys = TimeSeriesKey[]
    begin_time_series_update(mgr) do
        for association in associations
            key = add_time_series!(
                mgr,
                association.owner,
                association.time_series; association.features...,
            )
            push!(ts_keys, key)
        end
    end

    return ts_keys
end

function add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    _throw_if_read_only(mgr)
    forecast_params = _get_forecast_params!(mgr, time_series)
    sts_params = StaticTimeSeriesParameters()
    throw_if_does_not_support_time_series(owner)
    check_time_series_data(time_series)
    metadata_type = time_series_data_to_metadata(typeof(time_series))
    metadata = metadata_type(time_series; features...)
    ts_key = make_time_series_key(metadata)
    check_params_compatibility(sts_params, forecast_params, time_series)

    if has_metadata(
        mgr.metadata_store,
        owner;
        time_series_type = typeof(time_series),
        name = get_name(metadata),
        resolution = get_resolution(metadata),
        interval = get_interval(metadata),
        features...,
    )
        throw(
            ArgumentError(
                "Time series data with duplicate attributes are already stored: " *
                "$(metadata)",
            ),
        )
    end

    if !has_metadata(mgr.metadata_store, get_uuid(time_series))
        serialize_time_series!(mgr.data_store, time_series)
    end

    add_metadata!(mgr.metadata_store, owner, metadata)
    return ts_key
end

function clear_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    clear_metadata!(mgr.metadata_store)
    clear_time_series!(mgr.data_store)
end

function clear_time_series!(mgr::TimeSeriesManager, component::TimeSeriesOwners)
    _throw_if_read_only(mgr)
    for metadata in list_metadata(mgr.metadata_store, component)
        remove_time_series!(mgr, component, metadata)
    end
    @debug "Cleared time_series in $(summary(component))." _group =
        LOG_GROUP_TIME_SERIES
    return
end

get_metadata(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners,
    time_series_type::Type{<:TimeSeriesData},
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = get_metadata(
    mgr.metadata_store,
    component,
    time_series_type,
    name;
    resolution = resolution,
    interval = interval,
    features...,
)

list_metadata(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = list_metadata(
    mgr.metadata_store,
    component;
    time_series_type = time_series_type,
    name = name,
    resolution = resolution,
    interval = interval,
    features...,
)

"""
Remove the time series data for a component.
"""
function remove_time_series!(
    mgr::TimeSeriesManager,
    time_series_type::Type{<:TimeSeriesData},
    owner::TimeSeriesOwners,
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    _throw_if_read_only(mgr)
    uuids = list_matching_time_series_uuids(
        mgr.metadata_store;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        features...,
    )
    remove_metadata!(
        mgr.metadata_store,
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        features...,
    )

    @debug "Removed time_series metadata in $(summary(component))." _group =
        LOG_GROUP_TIME_SERIES component time_series_type name features

    for uuid in uuids
        _remove_data_if_no_more_references(mgr, uuid)
    end

    return
end

function remove_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    metadata::TimeSeriesMetadata,
)
    _throw_if_read_only(mgr)
    remove_metadata!(mgr.metadata_store, owner, metadata)
    @debug "Removed time_series metadata in $(summary(owner)) $(summary(metadata))." _group =
        LOG_GROUP_TIME_SERIES
    _remove_data_if_no_more_references(mgr, get_time_series_uuid(metadata))
    return
end

function _remove_data_if_no_more_references(mgr::TimeSeriesManager, uuid::Base.UUID)
    if !has_metadata(mgr.metadata_store, uuid)
        remove_time_series!(mgr.data_store, uuid)
        @debug "Removed time_series data $uuid." _group = LOG_GROUP_TIME_SERIES
    end

    return
end

function _throw_if_read_only(mgr::TimeSeriesManager)
    if mgr.read_only
        throw(ArgumentError("Time series operation is not allowed in read-only mode."))
    end
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::TimeSeriesManager,
    y::TimeSeriesManager;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    match = true
    for name in fieldnames(TimeSeriesManager)
        val_x = getproperty(x, name)
        val_y = getproperty(y, name)
        if name == :data_store && typeof(val_x) != typeof(val_y)
            @warn "Cannot compare $(typeof(val_x)) and $(typeof(val_y))"
            # TODO 1.0: workaround for not being able to convert Hdf5TimeSeriesStorage to
            # InMemoryTimeSeriesStorage
            continue
        elseif name == :read_only
            # Skip this because users can change it during deserialization and we test it
            # separately.
            continue
        end

        if !compare_values(
            match_fn,
            val_x,
            val_y;
            compare_uuids = compare_uuids,
            exclude = exclude,
        )
            @error "TimeSeriesManager field = $name does not match" getproperty(x, name) getproperty(
                y,
                name,
            )
            match = false
        end
    end

    return match
end
