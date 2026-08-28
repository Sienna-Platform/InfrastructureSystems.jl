# A flush becomes one HDF5 dataset whose chunk width equals the batch width, so this count
# keeps chunks near the store's 1 MiB cap; the byte limit is what bounds memory when
# individual arrays are long.
const AUTO_FLUSH_THRESHOLD = 10_000
const AUTO_FLUSH_BYTES = 256 * 1024 * 1024

"""
The transaction object for time series work.

A `TimeSeriesContext` owns one batch of work. It holds the two things the store
cannot do for the caller:

  - a **client-side add buffer** (an `InfraStore.AddBatch`), so many additions reach
    the store as one bulk call. That is what buys block-sized array writes and
    feature-set dedup; a store transaction deliberately does not provide it.
  - the **forecast window parameters** seen so far, so staged forecasts are checked
    for compatibility against each other as well as against the store, with one
    catalog query per `(resolution, interval)` group rather than one per add.

Atomicity belongs to the store. A context from [`time_series_transaction`](@ref)
opens an InfraStore transaction and commits or rolls it back on exit, so undoing a
failed block is one call. Because the write lands *inside* that transaction,
draining the buffer part-way through a block costs nothing in recoverability —
which is what lets any operation needing the arrays present simply flush.

Removals roll back too, which they cannot outside a transaction: the store defers
freeing an array until the outermost commit, so the bytes are still there if the
catalog rewinds.

There is no staged metadata overlay, because IS keeps no in-memory association index —
the store is the single source of truth. A read inside a block flushes the buffer and
then asks the store, which sees the uncommitted rows through the same connection.

The context is the block's API surface: `add_time_series!` dispatches on it as the
first argument, the Julia shape of calling methods on the yielded transaction
object. An `add_time_series!` call that targets the system or manager instead runs
on its own — it goes straight to the store, which is already atomic for a single
operation. Read paths never allocate a context at all — a fresh context has an
empty buffer and nothing to commit, and these accessors run in per-timestep loops.
"""
mutable struct TimeSeriesContext{M <: AbstractTimeSeriesManager, V}
    mgr::M
    "Created on the first stage; a context that never adds never allocates one."
    batch::Union{Nothing, InfraStore.AddBatch}
    """
    The buffered additions, in stage order, as everything their keys need bar the
    association id — which the store mints on insert, so a staged addition has none
    until [`flush!`](@ref) writes it.
    """
    staged::Vector{StagedKey}
    """
    Keys for the additions this block has written, in stage order, built from the ids
    the store minted for them. Only collected when `collect_keys` is set; a bulk
    ingest that never asks for its keys should not pay to retain one per series.
    """
    added::Vector{ConcreteTimeSeriesKey}
    "Whether to retain a key per written addition in `added`."
    collect_keys::Bool
    "Forecast window parameters per `(resolution, interval)` group."
    params_cache::Dict{
        Tuple{Dates.Period, Dates.Period},
        Union{Nothing, ForecastParameters},
    }
    "Whether a store transaction backs this context."
    transactional::Bool
    closed::Bool
    """
    Validates each add's owner against the layer that opened the block. A block
    opened on a `SystemData` checks that the owner is stored in that system; one
    opened on a bare manager has no system to check against and gets the no-op.
    """
    owner_validator::V
    "Staged additions to buffer before flushing on its own."
    auto_flush_threshold::Int
    "Bytes of staged array data to buffer before flushing on its own."
    auto_flush_bytes::Int
    "Estimated array bytes currently buffered."
    staged_bytes::Int
end

# A block opened on a bare manager has no system to check the owner against.
no_owner_validation(::TimeSeriesOwners) = nothing

function TimeSeriesContext(
    mgr::AbstractTimeSeriesManager,
    owner_validator = no_owner_validation;
    auto_flush_threshold::Int = AUTO_FLUSH_THRESHOLD,
    auto_flush_bytes::Int = AUTO_FLUSH_BYTES,
    collect_keys::Bool = false,
)
    auto_flush_threshold >= 1 ||
        throw(ArgumentError("auto_flush_threshold must be positive: $auto_flush_threshold"))
    auto_flush_bytes >= 1 ||
        throw(ArgumentError("auto_flush_bytes must be positive: $auto_flush_bytes"))
    return TimeSeriesContext(
        mgr,
        nothing,
        StagedKey[],
        ConcreteTimeSeriesKey[],
        collect_keys,
        Dict{Tuple{Dates.Period, Dates.Period}, Union{Nothing, ForecastParameters}}(),
        false,
        false,
        owner_validator,
        auto_flush_threshold,
        auto_flush_bytes,
        0,
    )
end

"""
Whether `context` has additions buffered but not yet written.
"""
has_staged_data(context::TimeSeriesContext) = !isempty(context.staged)

function _throw_if_closed(context::TimeSeriesContext)
    context.closed && throw(
        ArgumentError(
            "This time series context is closed. A context is valid only inside the " *
            "time_series_transaction block that created it; open a new one.",
        ),
    )
    return
end

# The buffer, created on first use so a read-only or read-mostly context never
# allocates an FFI batch handle.
function _batch!(context::TimeSeriesContext)
    isnothing(context.batch) && (context.batch = InfraStore.AddBatch())
    return context.batch
end

"""
Open the store transaction backing `context`.

Called by [`time_series_transaction`](@ref). A context used for a single operation
skips this: that operation is already atomic, and taking the write lock for it
would be wasted work — and would fail outright on a read-only store.
"""
function begin_transaction!(context::TimeSeriesContext)
    _throw_if_closed(context)
    context.transactional = true
    InfraStore.begin_transaction!(get_data_store(context.mgr).inner)
    return
end

# A fresh vector rather than `empty!`: `flush!` holds the staged entries it is about
# to write, and emptying them in place would clear that reference too.
function _reset_buffer!(context::TimeSeriesContext)
    context.batch = nothing
    context.staged = StagedKey[]
    empty!(context.params_cache)
    context.staged_bytes = 0
    return
end

"""
Write buffered additions to the store in one bulk call. A no-op when nothing is
buffered.

Any operation needing the arrays physically present — a read, a reader build, a
removal — flushes first. Inside a transactional context that is free of consequence:
the write lands in the open transaction and rolls back with it.

This is also where a staged addition becomes a [`TimeSeriesKey`](@ref): the store
mints the association ids as it inserts, and hands them back in stage order, so the
keys are built here and nowhere earlier. See [`added_keys`](@ref).
"""
function flush!(context::TimeSeriesContext)
    _throw_if_closed(context)
    isempty(context.staged) && return
    batch = context.batch
    staged = context.staged
    # Reset before writing so a failed write cannot leave the entries buffered a
    # second time, and so the context stays usable for further additions.
    _reset_buffer!(context)
    added = _infrastore_commit_batch!(context.mgr, batch)
    context.collect_keys && append!(
        context.added,
        (build_key(entry, item.id) for (entry, item) in zip(staged, added)),
    )
    return
end

"""
The keys for every addition `context` has written so far, in stage order.

A staged addition has no key until the store writes it and mints its association id,
so this covers what has been flushed — everything, once the block has committed — and
is empty unless the context was opened with `collect_keys = true`. Call
[`flush!`](@ref) first to include additions still buffered.
"""
added_keys(context::TimeSeriesContext) = context.added

"""
Flush buffered additions, commit the transaction, and close `context`.
"""
function commit!(context::TimeSeriesContext)
    try
        flush!(context)
        context.transactional &&
            InfraStore.commit_transaction!(get_data_store(context.mgr).inner)
    finally
        context.closed = true
    end
    return
end

"""
Abandon this batch, undoing everything it did.

Buffered additions never reached the store, so they are dropped outright.
Everything the block did write — including removals, which are reversible only
inside a transaction — is undone by rolling the store transaction back.

A failure in the rollback itself is logged rather than thrown: this runs while an
exception is already propagating, and the error that caused the unwind is the one
the caller needs to see.
"""
function discard!(context::TimeSeriesContext)
    _reset_buffer!(context)
    # The rollback below unwrites the rows these name, ids included.
    empty!(context.added)
    context.closed = true
    context.transactional || return
    try
        InfraStore.rollback_transaction!(get_data_store(context.mgr).inner)
    catch e
        # `catch`-block exception inspection: InvalidParameterError is the
        # store's "no transaction is open" — the store already ended it (e.g. a
        # commit that became durable before `commit!` threw in later work), so
        # there is no partial work to warn about, and erroring here would turn a
        # correctly-propagated failure into a second, misleading one.
        if e isa InfraStore.InvalidParameterError
            @debug "No store transaction was open to roll back; it was already " *
                   "ended by the store" exception = e
        else
            @error "Rolling back the time series transaction failed; the store may " *
                   "retain partial work from this block" exception = e
        end
    end
    return
end
