"""
The transaction object for time series work.

A `TimeSeriesContext` is a handle on one open store transaction, plus the one thing
the store cannot do for the caller: the **forecast window parameters** seen so far,
so forecasts added in the block are checked for compatibility against each other as
well as against the store, with one catalog query per `(resolution, interval)` group
rather than one per add.

It holds no add buffer. Additions go straight to the store, one call each, and the
store is what batches them: inside an open transaction its HDF5 backend accumulates
the packed arrays into a pending block per pool and writes the block whole at the
outermost commit. A run of `add_time_series!` calls in a block therefore produces the
same one dataset per pool that a single bulk write would — IS staging them a second
time on this side would buy nothing and cost the deferral of every key.

Atomicity belongs to the store. A context from [`time_series_transaction`](@ref)
opens an InfraStore transaction and commits or rolls it back on exit, so undoing a
failed block is one call. Removals roll back too, which they cannot outside a
transaction: the store defers freeing an array until the outermost commit, so the
bytes are still there if the catalog rewinds.

Reads inside a block see what the block has written — the store serves a pending
array out of its buffer. IS keeps no in-memory association index; the store is the
single source of truth.

The context is the block's API surface: `add_time_series!` dispatches on it as the
first argument, the Julia shape of calling methods on the yielded transaction
object. An `add_time_series!` call that targets the system or manager instead runs
on its own — it goes straight to the store, which is already atomic for a single
operation. Read paths never allocate a context at all.
"""
mutable struct TimeSeriesContext{M <: AbstractTimeSeriesManager, V}
    mgr::M
    """
    Scratch for the one-item buffer each add marshals through. Not a staging
    area — it is drained by every add — but an `InfraStore.AddBatch` owns an FFI
    handle and registers a finalizer, so allocating one per add puts 10k
    finalizers in front of the GC over a bulk ingest. Created on the first add,
    so a block that only reads never makes one.
    """
    batch::Union{Nothing, InfraStore.AddBatch}
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
end

# A block opened on a bare manager has no system to check the owner against.
no_owner_validation(::TimeSeriesOwners) = nothing

TimeSeriesContext(mgr::AbstractTimeSeriesManager, owner_validator = no_owner_validation) =
    TimeSeriesContext(mgr, nothing, new_params_cache(), false, false, owner_validator)

# The scratch buffer, made on first use so a read-only block never allocates an
# FFI batch handle.
function _scratch_batch!(context::TimeSeriesContext)
    isnothing(context.batch) && (context.batch = InfraStore.AddBatch())
    return context.batch
end

function _throw_if_closed(context::TimeSeriesContext)
    context.closed && throw(
        ArgumentError(
            "This time series context is closed. A context is valid only inside the " *
            "time_series_transaction block that created it; open a new one.",
        ),
    )
    return
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

"""
Commit the transaction and close `context`.
"""
function commit!(context::TimeSeriesContext)
    try
        context.transactional &&
            InfraStore.commit_transaction!(get_data_store(context.mgr).inner)
    finally
        context.closed = true
    end
    return
end

"""
Abandon this block, undoing everything it did.

Every addition reached the store as it was made, so nothing is dropped on this
side; rolling the store transaction back is what undoes them — along with
everything else the block wrote, **including removals**, which are reversible only
inside a transaction.

A failure in the rollback itself is logged rather than thrown: this runs while an
exception is already propagating, and the error that caused the unwind is the one
the caller needs to see.
"""
function discard!(context::TimeSeriesContext)
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
