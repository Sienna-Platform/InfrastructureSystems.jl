# Adds can be batched through `begin_time_series_update` to amortize store flushes.
const ADD_TIME_SERIES_BATCH_SIZE = 100

mutable struct TimeSeriesManager <: AbstractTimeSeriesManager
    data_store::Store
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
        # The Castore store unifies data + metadata. On-disk artifacts live at
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
            Store(;
                in_memory = in_memory,
                path = path,
                compression = compression,
            )
    end
    return TimeSeriesManager(data_store, read_only)
end

# (owner_id::Int, owner_type::String, owner_category::String) for the Castore FFI.
# The owner is identified by its integer id; `owner_category` is the String tag
# ("Component" / "SupplementalAttribute"), converted to a `Castore.OwnerCategory`
# enum via `castore_category` at the call sites that need it.
function _castore_owner_args(owner::TimeSeriesOwners)
    return (
        get_id(owner),
        string(nameof(typeof(owner))),
        get_owner_category(owner),
    )
end

function _castore_features(features)
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
    before = Set(castore_row_identity(r) for r in Castore.list_keys(store.inner))
    try
        open_store!(store, "r+") do
            func()
        end
        flush!(store)
    catch
        # Roll back: remove associations added during this update so the store is
        # left consistent with its pre-update state.
        for row in Castore.list_keys(store.inner)
            castore_row_identity(row) in before && continue
            try
                castore_remove_row!(store, row)
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
    _throw_if_read_only(mgr)
    assocs = collect(associations)
    # A DeterministicSingleTimeSeries is derived in-store from its underlying
    # SingleTimeSeries, so it cannot be staged onto a batch; route such batches
    # through the per-add path (with its diff-based rollback).
    if any(a -> _castore_needs_transform(a.time_series), assocs)
        ts_keys = TimeSeriesKey[]
        begin_time_series_update(mgr) do
            for association in assocs
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

    # Fast path: stage everything onto one `AddBatch` and commit once — a single
    # metadata transaction, and the backend packs the arrays into batch-sized
    # datasets written whole-chunk (no per-add read-modify-write). The commit is
    # all-or-nothing, so no catalog snapshot is needed for rollback.
    batch = Castore.AddBatch()
    params_cache = Dict{Tuple{Dates.Period, Dates.Period}, Any}()
    ts_keys = Vector{TimeSeriesKey}(undef, length(assocs))
    for (i, association) in enumerate(assocs)
        ts_keys[i] = _castore_stage!(
            batch,
            mgr,
            params_cache,
            association.owner,
            association.time_series;
            association.features...,
        )
    end
    try
        Castore.add_time_series_bulk!(mgr.data_store.inner, batch)
    catch e
        if e isa Castore.DuplicateAssociationError ||
           e isa Castore.DuplicateTimeSeriesError
            throw(
                ArgumentError(
                    "Time series data with duplicate attributes are already stored"),
            )
        end
        rethrow()
    end
    flush!(mgr.data_store)
    return ts_keys
end

function add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    _throw_if_read_only(mgr)
    return castore_add_time_series!(mgr, owner, time_series; features...)
end

function clear_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    clear_time_series!(mgr.data_store)
    return
end

function clear_time_series!(mgr::TimeSeriesManager, component::TimeSeriesOwners)
    _throw_if_read_only(mgr)
    owner_id, _, owner_category = _castore_owner_args(component)
    castore_clear_owner!(mgr.data_store, owner_id, castore_category(owner_category))
    @debug "Cleared time_series in $(summary(component))." _group =
        LOG_GROUP_TIME_SERIES
    return
end

get_time_series_key(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners,
    time_series_type::Type{<:TimeSeriesData},
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = castore_get_time_series_key(
    component,
    time_series_type,
    name;
    resolution = resolution,
    interval = interval,
    features...,
)

list_time_series_keys(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = castore_owner_list_keys(
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
    owner_id, _, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    # Subset (partial) feature/resolution matching: remove every stored series of
    # type `time_series_type` that contains at least the requested features.
    for key in castore_owner_list_keys(owner;
        time_series_type = time_series_type, name = name, resolution = resolution,
        interval = interval, features...)
        mt = get_time_series_type(key)
        res = get_resolution(key)
        feats = _castore_features((Symbol(k) => v for (k, v) in get_features(key)))
        if mt <: SingleTimeSeries
            # A DeterministicSingleTimeSeries shares the underlying SingleTimeSeries
            # array, so the base series cannot be removed if doing so would orphan a
            # DST — i.e. a DST references the array and this is its last backing
            # SingleTimeSeries. Other components sharing the array make removal safe.
            hash =
                get_time_series_metadata(store, owner_id, category, name;
                    resolution = res, features = feats).data_hash
            c = castore_array_sts_dst_counts(store, hash)
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
            # Pin this key's own interval: a name can carry several forecasts differing
            # only by interval, so removing by (type, name, resolution) alone would be
            # ambiguous.
            remove_typed!(store, owner_id, category, name, castore_ts_code(mt);
                resolution = res, interval = get_interval(key), features = feats)
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
