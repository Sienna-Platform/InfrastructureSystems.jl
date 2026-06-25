# Adds can be batched through `begin_time_series_update` to amortize store flushes.
const ADD_TIME_SERIES_BATCH_SIZE = 100

mutable struct TimeSeriesManager <: InfrastructureSystemsType
    data_store::TimeSeriesStorage
    read_only::Bool
end

function TimeSeriesManager(;
    data_store = nothing,
    in_memory = false,
    read_only = false,
    directory = nothing,
    compression = CompressionSettings(),
)
    if isnothing(directory) && haskey(ENV, TIME_SERIES_DIRECTORY_ENV_VAR)
        directory = ENV[TIME_SERIES_DIRECTORY_ENV_VAR]
    end

    if isnothing(data_store)
        # The Rust store unifies data + metadata. On-disk artifacts live at
        # `<dir>/<uuid>_time_series.nc` (+ sidecar `.sqlite`).
        path = if in_memory
            nothing
        else
            # `directory` may be an explicit kwarg, the SIENNA_TIME_SERIES_DIRECTORY
            # env var, or `tempdir()`. Create it if missing (e.g. an HPC per-job
            # scratch path that doesn't exist yet).
            dir = isnothing(directory) ? tempdir() : directory
            mkpath(dir)
            joinpath(dir, string(UUIDs.uuid4()) * "_time_series.nc")
        end
        data_store =
            RustTimeSeriesStore(;
                in_memory = in_memory,
                path = path,
                compression = compression,
            )
    end
    return TimeSeriesManager(data_store, read_only)
end

# (owner_id::Int, owner_type::String, owner_category::String) for the Rust FFI.
# The owner is identified by its integer id; `owner_category` is the String tag
# ("Component" / "SupplementalAttribute"), converted to a `TSS.OwnerCategory`
# enum via `_tss_category` at the call sites that need it.
function _rust_owner_args(owner::TimeSeriesOwners)
    return (
        get_id(owner),
        string(nameof(typeof(owner))),
        _get_owner_category(owner),
    )
end

function _rust_features(features)
    out = Dict{String, Any}()
    for (k, v) in features
        v isa Union{Bool, Real, AbstractString} || throw(
            ArgumentError(
                "time series feature `$k` must be a Bool, Real, or String, got $(typeof(v))",
            ),
        )
        out[string(k)] = v
    end
    return out
end

"""
Begin an update of time series. Use this function when adding many time series arrays
in order to improve performance by amortizing store flushes across the batch.

If an error occurs during the update, time series added within it are rolled back.
"""
function begin_time_series_update(
    func::Function,
    mgr::TimeSeriesManager,
)
    store = mgr.data_store
    before = Set(_rust_row_identity(r) for r in TSS.list_keys(store.inner))
    try
        open_store!(store, "r+") do
            func()
        end
        flush!(store)
    catch
        # Roll back: remove associations added during this update so the store is
        # left consistent with its pre-update state.
        for row in TSS.list_keys(store.inner)
            _rust_row_identity(row) in before && continue
            try
                _rust_remove_row!(store, row)
            catch
                # Best-effort cleanup; ignore rows already gone.
            end
        end
        rethrow()
    end
    return
end

function bulk_add_time_series!(
    mgr::TimeSeriesManager,
    associations;
    kwargs...,
)
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
    return _rust_add_time_series!(mgr, owner, time_series; features...)
end

function clear_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    clear_time_series!(mgr.data_store)
    return
end

function clear_time_series!(mgr::TimeSeriesManager, component::TimeSeriesOwners)
    _throw_if_read_only(mgr)
    owner_id, _, owner_category = _rust_owner_args(component)
    _rust_clear_owner!(mgr.data_store, owner_id, _tss_category(owner_category))
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
) = _rust_get_metadata(
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
) = _rust_owner_list_metadata(
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
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    _throw_if_read_only(mgr)
    store = mgr.data_store
    owner_id, _, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    # Subset (partial) feature/resolution matching: remove every stored series of
    # type `time_series_type` that contains at least the requested features.
    for key in _rust_owner_list_metadata(owner;
        time_series_type = time_series_type, name = name, resolution = resolution,
        features...)
        mt = get_time_series_type(key)
        res = get_resolution(key)
        feats = _rust_features((Symbol(k) => v for (k, v) in get_features(key)))
        if mt <: SingleTimeSeries
            # A DeterministicSingleTimeSeries shares the underlying SingleTimeSeries
            # array, so the base series cannot be removed if doing so would orphan a
            # DST — i.e. a DST references the array and this is its last backing
            # SingleTimeSeries. Other components sharing the array make removal safe.
            hash =
                get_metadata(store, owner_id, category, name;
                    resolution = res, features = feats).data_hash
            c = _rust_array_sts_dst_counts(store, hash)
            if c.dst >= 1 && c.sts <= 1
                throw(
                    ArgumentError(
                        "Cannot remove SingleTimeSeries '$name' because it is attached to a " *
                        "DeterministicSingleTimeSeries."),
                )
            end
            remove_single!(
                store,
                owner_id,
                category,
                name;
                resolution = res,
                features = feats,
            )
        else
            remove_typed!(store, owner_id, category, name, _rust_ts_code(mt);
                resolution = res, features = feats)
        end
    end
    return
end

function remove_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
)
    _throw_if_read_only(mgr)
    feats = (Symbol(k) => v for (k, v) in get_features(key))
    remove_time_series!(
        mgr,
        get_time_series_type(key),
        owner,
        get_name(key);
        resolution = get_resolution(key),
        feats...,
    )
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
    # `read_only` can be changed during deserialization and is tested separately;
    # structural equality is the data store's count comparison.
    return compare_values(
        match_fn,
        x.data_store,
        y.data_store;
        compare_uuids = compare_uuids,
        exclude = exclude,
    )
end
