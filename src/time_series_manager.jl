"""
Manages a system's time series data.

Wraps the [`Store`](@ref) holding both the arrays and their catalog (owner
associations and metadata) and enforces read-only mode. Owned by a `SystemData`;
user code reaches it through the system-level time series API rather than
directly.
"""
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
            dir = if isnothing(directory)
                tempdir()
            else
                directory
            end
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

"""
The [`Store`](@ref) holding this manager's time series arrays and their catalog.
"""
get_data_store(mgr::TimeSeriesManager) = mgr.data_store

# (owner_id::Int, owner_type::String, owner_category::InfraStore.OwnerCategory)
# for the InfraStore binding. The owner is identified by its integer id.
function _infrastore_owner_args(owner::TimeSeriesOwners)
    return (
        get_id(owner),
        string(nameof(typeof(owner))),
        get_owner_category(owner),
    )
end

# The same identity without the type-name string, for the calls that never send it.
function _infrastore_owner_id_category(owner::TimeSeriesOwners)
    return (get_id(owner), get_owner_category(owner))
end

_feature_value(_, v::Union{Bool, Real, AbstractString}) = v

_feature_value(k, v) = throw(
    ArgumentError(
        "time series feature `$k` must be a Bool, Real, or String, got $(typeof(v))",
    ),
)

_infrastore_features(::Nothing) = nothing

function _infrastore_features(features::Dict)
    out = Dict{String, Any}()
    for (k, v) in features
        out[string(k)] = _feature_value(k, v)
    end
    return out
end

_key_features(::Nothing) = Dict{String, Any}()
_key_features(features::Dict) = Dict{String, Any}(features)

function _check_interval_supported(::Type{T}, interval) where {T <: TimeSeriesData}
    if T <: StaticTimeSeries && !isnothing(interval)
        throw(
            ArgumentError(
                "`interval` is not supported for $(nameof(T)); it is only valid for forecasts.",
            ),
        )
    end
    return
end

"""
Open a batch of time series work and run `func` on it, inside a store transaction.

Additions made through the yielded [`TimeSeriesContext`](@ref) are buffered and
written as one bulk call, so the store pays one catalog transaction for the block
instead of one per series. The block commits when `func` returns.

Buffered additions are not visible to reads through the manager or system until
the block commits. Call `flush!(txn)` first when a read inside the block must see
additions staged through `txn`; doing so creates a batching boundary but keeps the
writes inside the transaction.

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
    return _time_series_transaction(func, mgr, no_owner_validation; kwargs...)
end

function _time_series_transaction(
    func::Function,
    mgr::TimeSeriesManager,
    owner_validator::Function;
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
    features::Union{Nothing, Dict} = nothing,
)
    _throw_if_read_only(mgr)
    return infrastore_add_time_series!(mgr, owner, time_series; features = features)
end

"""
Add a time series through an open transaction, buffering it into the block's one
bulk write. If the block throws, the addition is rolled back with the rest of it.
"""
function add_time_series!(
    context::TimeSeriesContext,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features::Union{Nothing, Dict} = nothing,
)
    _throw_if_closed(context)
    context.owner_validator(owner)
    return _stage_on_context!(context, owner, time_series; features = features)
end

"""
Add the same time series to multiple components through an open transaction. Only
one copy of the array is stored.
"""
function add_time_series!(
    context::TimeSeriesContext,
    components,
    time_series::TimeSeriesData;
    features::Union{Nothing, Dict} = nothing,
)
    # Component information is not embedded into the key, so every component
    # produces the same one.
    peeled = Iterators.peel(components)
    isnothing(peeled) && throw(
        ArgumentError(
            "`components` is empty; there is nothing to associate " *
            "$(summary(time_series)) with",
        ),
    )
    first_component, rest = peeled
    key = add_time_series!(context, first_component, time_series; features = features)
    for component in rest
        add_time_series!(context, component, time_series; features = features)
    end
    return key
end

function _stage_on_context!(
    context::TimeSeriesContext,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features::Union{Nothing, Dict} = nothing,
)
    key, nbytes = _infrastore_stage!(
        _batch!(context),
        context.mgr,
        context.params_cache,
        owner,
        time_series;
        features = features,
    )
    push!(context.keys, key)
    # `nbytes` is the exact size of the encoded array the batch copied at stage
    # time (computed where the array is materialized — never derived by walking
    # the source objects, which costs more than the rest of the stage combined).
    context.staged_bytes += nbytes
    if length(context.keys) >= context.auto_flush_threshold ||
       context.staged_bytes >= context.auto_flush_bytes
        flush!(context)
    end
    return key
end

function clear_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    clear_time_series!(get_data_store(mgr))
    return
end

function compact_time_series!(mgr::TimeSeriesManager)
    _throw_if_read_only(mgr)
    return compact_time_series!(get_data_store(mgr))
end

function clear_time_series!(mgr::TimeSeriesManager, component::TimeSeriesOwners)
    _throw_if_read_only(mgr)
    owner_id, category = _infrastore_owner_id_category(component)
    # One owner-scoped clear (order-independent, so it is not blocked by the
    # core's SingleTimeSeries/DST removal guard).
    InfraStore.clear!(
        get_data_store(mgr).inner;
        owner_id = owner_id,
        owner_category = category,
    )
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
    features::Union{Nothing, Dict} = nothing,
) = infrastore_get_time_series_key(
    component,
    time_series_type,
    name;
    resolution = resolution,
    interval = interval,
    features = features,
)

list_time_series_keys(
    mgr::TimeSeriesManager,
    component::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features::Union{Nothing, Dict} = nothing,
) = infrastore_owner_list_keys(
    component;
    time_series_type = time_series_type,
    name = name,
    resolution = resolution,
    interval = interval,
    features = features,
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
    features::Union{Nothing, Dict} = nothing,
)
    _throw_if_read_only(mgr)
    store = get_data_store(mgr)
    owner_id, category = _infrastore_owner_id_category(owner)
    feats = _infrastore_features(features)
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
        # `catch`-block exception inspection: the DST-orphan guard can only fire for a
        # SingleTimeSeries removal. An InvalidParameterError raised for any other query
        # type — or for any other reason — must surface the store's own message.
        if e isa InfraStore.InvalidParameterError &&
           time_series_type <: SingleTimeSeries
            throw(
                ArgumentError(
                    "Cannot remove SingleTimeSeries '$name' because it is attached to a " *
                    "DeterministicSingleTimeSeries. Store reported: $(e.msg)"),
            )
        end
        rethrow()
    end
    return
end

"""
Remove exactly the time series that `key` identifies, and nothing else.

A key is a fully-resolved identity, so this takes the store's exact-key removal
path (whole-feature-set match) rather than the by-name subset filter: a sibling
series of the same type/name/resolution/interval whose features are a strict
superset of the key's is left in place.
"""
function remove_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
)
    _throw_if_read_only(mgr)
    infrastore_remove_time_series!(get_data_store(mgr), owner, key)
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
    compare_ids = false,
    exclude = Set{Symbol}(),
)
    # `read_only` can be changed during deserialization and is tested separately;
    # structural equality is the data store's count comparison.
    return compare_values(
        match_fn,
        get_data_store(x),
        get_data_store(y);
        compare_ids = compare_ids,
        exclude = exclude,
    )
end
