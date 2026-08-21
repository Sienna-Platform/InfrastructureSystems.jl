# A context flushes on its own when its buffer reaches either limit below, whichever
# comes first. Inside a transaction an early flush costs nothing in recoverability, so
# these only split the I/O, never the atomicity.
#
# The count limit keeps the store's layout healthy: each flush becomes one HDF5
# dataset whose chunk width equals the batch width, so 10,000 f64 series produce 80 KiB
# chunks — near the store's 1 MiB chunk cap. The byte limit is what actually bounds
# memory, which the count cannot do when individual arrays are long: the batch copies
# each array at stage time and keeps it until the flush, so the buffer holds at most
# ~AUTO_FLUSH_BYTES of array data no matter how large each series is.
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

Unlike the Python counterpart, there is no staged metadata overlay, because IS
keeps no in-memory association index — the store is the single source of truth. A
read inside a block flushes the buffer and then asks the store, which sees the
uncommitted rows through the same connection.

The context is the block's API surface: `add_time_series!` dispatches on it as the
first argument, the Julia shape of calling methods on the yielded transaction
object. An `add_time_series!` call that targets the system or manager instead runs
on its own — it goes straight to the store, which is already atomic for a single
operation. Read paths never allocate a context at all — a fresh context has an
empty buffer and nothing to commit, and these accessors run in per-timestep loops.
"""
mutable struct TimeSeriesContext
    # Typed on the abstract supertype: this file is included before the concrete
    # `TimeSeriesManager`, which needs `TimeSeriesContext` in its own signatures.
    mgr::AbstractTimeSeriesManager
    "Created on the first stage; a context that never adds never allocates one."
    batch::Union{Nothing, InfraStore.AddBatch}
    "Keys for the buffered additions, in stage order."
    keys::Vector{ConcreteTimeSeriesKey}
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
    opened on a bare manager has no system to check against.
    """
    owner_validator::Union{Nothing, Function}
    "Staged additions to buffer before flushing on its own."
    auto_flush_threshold::Int
    "Bytes of staged array data to buffer before flushing on its own."
    auto_flush_bytes::Int
    "Estimated array bytes currently buffered."
    staged_bytes::Int
end

function TimeSeriesContext(
    mgr::AbstractTimeSeriesManager,
    owner_validator::Union{Nothing, Function} = nothing;
    auto_flush_threshold::Int = AUTO_FLUSH_THRESHOLD,
    auto_flush_bytes::Int = AUTO_FLUSH_BYTES,
)
    auto_flush_threshold >= 1 ||
        throw(ArgumentError("auto_flush_threshold must be positive: $auto_flush_threshold"))
    auto_flush_bytes >= 1 ||
        throw(ArgumentError("auto_flush_bytes must be positive: $auto_flush_bytes"))
    return TimeSeriesContext(
        mgr,
        nothing,
        ConcreteTimeSeriesKey[],
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
has_staged_data(context::TimeSeriesContext) = !isempty(context.keys)

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
    InfraStore.begin_transaction!(context.mgr.data_store.inner)
    return
end

"""
Write buffered additions to the store in one bulk call. A no-op when nothing is
buffered.

Any operation needing the arrays physically present — a read, a reader build, a
removal — flushes first. Inside a
transactional context that is free of consequence: the write lands in the open
transaction and rolls back with it.
"""
function flush!(context::TimeSeriesContext)
    _throw_if_closed(context)
    isempty(context.keys) && return
    batch = context.batch
    # Reset before writing so a failed write cannot leave the entries buffered a
    # second time, and so the context stays usable for further additions.
    context.batch = nothing
    empty!(context.keys)
    empty!(context.params_cache)
    context.staged_bytes = 0
    _infrastore_commit_batch!(context.mgr, batch)
    return
end

"""
Flush buffered additions, commit the transaction, and close `context`.
"""
function commit!(context::TimeSeriesContext)
    try
        flush!(context)
        context.transactional &&
            InfraStore.commit_transaction!(context.mgr.data_store.inner)
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
    context.batch = nothing
    empty!(context.keys)
    empty!(context.params_cache)
    context.staged_bytes = 0
    context.closed = true
    context.transactional || return
    try
        InfraStore.rollback_transaction!(context.mgr.data_store.inner)
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
