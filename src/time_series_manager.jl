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
        # The InfraStore store unifies data + metadata. On-disk artifacts live at
        # `<dir>/<uuid>_time_series.h5` (+ sidecar `.sqlite`).
        path = if in_memory
            nothing
        else
            # `directory` may be an explicit kwarg, the SIENNA_TIME_SERIES_DIRECTORY
            # env var, or `tempdir()`. Create it if missing (e.g. an HPC per-job
            # scratch path that doesn't exist yet).
            dir = isnothing(directory) ? tempdir() : directory
            mkpath(dir)
            joinpath(dir, string(UUIDs.uuid4()) * "_time_series.h5")
        end
        data_store =
            Store(;
                in_memory = in_memory,
                path = path,
                compression = compression,
                # A system's working store is scratch: the artifacts sit in a temp
                # directory and the system they back lives in memory, so a crash loses
                # both. Journaling the catalog on every commit would buy durability
                # nobody can consume; it is written out when the system is serialized.
                catalog = :memory,
            )
    end
    return TimeSeriesManager(data_store, read_only)
end

# (owner_id::Int, owner_type::String, owner_category::InfraStore.OwnerCategory)
# for the InfraStore binding. The owner is identified by its integer id.
function _infrastore_owner_args(owner::TimeSeriesOwners)
    return (
        get_id(owner),
        string(nameof(typeof(owner))),
        get_owner_category(owner),
    )
end

function _infrastore_features(features)
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
Open a batch of time series work and run `func` on it, inside a store transaction.

Additions made through the yielded [`TimeSeriesContext`](@ref) are buffered and
written as one bulk call, so the store pays one catalog transaction for the block
instead of one per series. The block commits when `func` returns.

If `func` throws, the transaction is rolled back and the whole block is undone —
buffered additions never reached the store, and everything that did, **including
removals**, is reversed. A removal is recoverable only in here; outside a block the
store frees the array as soon as its last reference goes.

Blocks nest innermost-first: an inner block must finish before the one enclosing
it.

A batch that grows past `auto_flush_threshold` staged additions or
`auto_flush_bytes` of staged array data — whichever comes first — is written out
mid-block, so an arbitrarily large block holds a bounded amount of data in memory.
Flushed work stays inside the transaction and rolls back with it.

```julia
time_series_transaction(mgr) do txn
    for (component, profile) in profiles
        add_time_series!(txn, component, profile)
    end
end
```
"""
function time_series_transaction(func::Function, mgr::TimeSeriesManager; kwargs...)
    return _time_series_transaction(func, mgr, nothing; kwargs...)
end

function _time_series_transaction(
    func::Function,
    mgr::TimeSeriesManager,
    owner_validator::Union{Nothing, Function};
    auto_flush_threshold::Int = AUTO_FLUSH_THRESHOLD,
    auto_flush_bytes::Int = AUTO_FLUSH_BYTES,
)
    _throw_if_read_only(mgr)
    context = TimeSeriesContext(
        mgr,
        owner_validator;
        auto_flush_threshold = auto_flush_threshold,
        auto_flush_bytes = auto_flush_bytes,
    )
    begin_transaction!(context)
    # `commit!` must stay inside the protected region: buffered additions are only
    # written (and validated by the store) at the final flush it performs, so a bad
    # add in a small block throws here rather than at `add_time_series!` time. If it
    # escaped the try, `discard!` would never run and the store transaction would be
    # left open holding the write lock.
    result = try
        r = func(context)
        commit!(context)
        r
    catch
        discard!(context)
        rethrow()
    end
    return result
end

"""
Add a time series directly to the store, outside any batch. A single add is atomic
on its own; to batch many adds, open [`time_series_transaction`](@ref) and call
`add_time_series!` on the yielded transaction instead.
"""
function add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    _throw_if_read_only(mgr)
    return infrastore_add_time_series!(mgr, owner, time_series; features...)
end

"""
Add a time series through an open transaction, buffering it into the block's one
bulk write. If the block throws, the addition is rolled back with the rest of it.
"""
function add_time_series!(
    context::TimeSeriesContext,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    _throw_if_closed(context)
    isnothing(context.owner_validator) || context.owner_validator(owner)
    return _stage_on_context!(context, owner, time_series; features...)
end

"""
Add the same time series to multiple components through an open transaction. Only
one copy of the array is stored.
"""
function add_time_series!(
    context::TimeSeriesContext,
    components,
    time_series::TimeSeriesData;
    features...,
)
    # Component information is not embedded into the key, so every component
    # produces the same one.
    key = nothing
    for component in components
        key = add_time_series!(context, component, time_series; features...)
    end
    return key
end

function _stage_on_context!(
    context::TimeSeriesContext,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    key, nbytes = _infrastore_stage!(
        _batch!(context),
        context.mgr,
        context.params_cache,
        owner,
        time_series;
        features...,
    )
    push!(context.keys, key)
    # `nbytes` is the exact size of the encoded array the batch copied at stage
    # time (computed where the array is materialized — never derived by walking
    # the source objects, which costs more than the rest of the stage combined).
    context.staged_bytes += nbytes
    # A batch that grows past either limit is written out so an arbitrarily large
    # block holds a bounded amount of data in memory. The write lands inside the
    # open transaction, so it rolls back with the block.
    if length(context.keys) >= context.auto_flush_threshold ||
       context.staged_bytes >= context.auto_flush_bytes
        flush!(context)
    end
    return key
end

function clear_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    clear_time_series!(mgr.data_store)
    return
end

function compact_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    return compact_time_series!(mgr.data_store)
end

function clear_time_series!(mgr::TimeSeriesManager, component::TimeSeriesOwners)
    _throw_if_read_only(mgr)
    owner_id, _, category = _infrastore_owner_args(component)
    # One owner-scoped clear (order-independent, so it is not blocked by the
    # core's SingleTimeSeries/DST removal guard).
    InfraStore.clear!(mgr.data_store.inner; owner_id = owner_id, owner_category = category)
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
) = infrastore_get_time_series_key(
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
) = infrastore_owner_list_keys(
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
    owner_id, _, category = _infrastore_owner_args(owner)
    feats = Dict{String, Any}(string(k) => v for (k, v) in features)
    # Subset (partial) feature/resolution matching: each bulk catalog call
    # removes every stored series of the query type that contains at least the
    # requested features, in one store transaction — no per-key listing or
    # per-key transactions. The core refuses to remove a SingleTimeSeries whose
    # array still backs a DeterministicSingleTimeSeries; surface that as the
    # IS-level error.
    try
        _infrastore_remove_by_filter!(
            store,
            time_series_type;
            owner_id = owner_id,
            owner_category = category,
            name = name,
            resolution = resolution,
            interval = interval,
            features = feats,
        )
    catch e
        if e isa InfraStore.InvalidParameterError
            throw(
                ArgumentError(
                    "Cannot remove SingleTimeSeries '$name' because it is attached to a " *
                    "DeterministicSingleTimeSeries."),
            )
        end
        rethrow()
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
