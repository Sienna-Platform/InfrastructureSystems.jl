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

`nothing` is a valid context everywhere one is accepted, and means "no batch": the
operation goes straight to the store, which is already atomic on its own. Read
paths pass `nothing` by default and allocate no context at all — a fresh context
has an empty buffer and nothing to commit, so the two are indistinguishable except
in cost, and these accessors run in per-timestep loops.
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
    params_cache::Dict{Tuple{Dates.Period, Dates.Period}, Any}
    "Whether a store transaction backs this context."
    transactional::Bool
    closed::Bool
end

function TimeSeriesContext(mgr::AbstractTimeSeriesManager)
    return TimeSeriesContext(
        mgr,
        nothing,
        ConcreteTimeSeriesKey[],
        Dict{Tuple{Dates.Period, Dates.Period}, Any}(),
        false,
        false,
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

# Verify the context belongs to this manager. Passing another system's context
# would stage work onto the wrong store.
function _throw_if_foreign(context::TimeSeriesContext, mgr::AbstractTimeSeriesManager)
    _throw_if_closed(context)
    context.mgr === mgr || throw(
        ArgumentError("This time series context belongs to a different system."),
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
removal, a `DeterministicSingleTimeSeries` transform — flushes first. Inside a
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
    context.closed = true
    context.transactional || return
    try
        InfraStore.rollback_transaction!(context.mgr.data_store.inner)
    catch e
        @error "Rolling back the time series transaction failed; the store may " *
               "retain partial work from this block" exception = e
    end
    return
end

# Flush whatever `context` has buffered, when a caller may or may not have one.
# The `nothing` method is why read paths cost nothing when no batch is open.
_flush_context(::Nothing) = nothing
_flush_context(context::TimeSeriesContext) = flush!(context)
