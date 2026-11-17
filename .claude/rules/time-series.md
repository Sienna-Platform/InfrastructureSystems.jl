---
paths:
  - "src/*time_series*.jl"
  - "src/deterministic*.jl"
  - "src/forecasts.jl"
  - "src/probabilistic.jl"
  - "src/scenarios.jl"
  - "src/infrastore.jl"
  - "src/store.jl"
  - "src/system_data.jl"
---

## Time Series Type Hierarchy

The whole hierarchy is parameterized on the value element type `T`, so callers dispatch on
the payload instead of querying it:

```
TimeSeriesData{T}
├─ StaticTimeSeries{T} ⊃ SingleTimeSeries{T, N}, NonSequentialTimeSeries{T, N}
└─ Forecast{T} ⊃ Probabilistic{T, N}, Scenarios{T, N},
   └─ AbstractDeterministic{T} ⊃ Deterministic{T, N}, DeterministicSingleTimeSeries{T, N}
```

`DeterministicSingleTimeSeries` is a **fieldless query marker**: the DST is
derived in-store by `transform_single_time_series!`, reads materialize a `Deterministic`,
and no instance is ever constructed. The type exists only for query/removal filters,
`TimeSeriesKey.time_series_type`, and the transform API — do not reintroduce data-bearing
fields or an instance `add_time_series!` path.

### transform_single_time_series! validation lives in Rust

**All** of the transform's eligibility validation is in the InfraStore core — horizon fit
and divisibility, interval divisibility and length, per-resolution grid uniformity, and
conflicts with forecasts already stored. The store answers them from its distinct
static grids (`GROUP BY resolution`), so the cost is O(distinct resolutions), not
O(series). `_check_transform_single_time_series` and
`_check_single_time_series_transformed_parameters` are **deleted** — do not reintroduce a
Julia-side pre-check.

IS calls through `infrastore_transform_single_time_series!` (`src/infrastore.jl`), which
maps the core's `InvalidParameterError`/`IntegrityError` to `ConflictingInputsError` —
the type callers dispatch on. The returned `TransformOutcome` carries `sources` (0 ⇒ the
"nothing to transform" warning) and `interval_normalized` (⇒ the "only one forecast
window" warning); IS re-emits both warnings from it rather than deriving them.

Three rules turned out **not** to be storage invariants — the core has passing tests
asserting the opposite — so they are opt-in via `TransformPolicy`, which IS sets and
Python/CLI leave at `Default`:

| flag | why it is a client rule |
|---|---|
| `normalize_single_window` | the interval is part of the association identity; IS looks single-window views up by zero, other clients by the horizon |
| `require_uniform_forecast_grid` | the store is happy to hold forecasts on several grids; one-system-one-grid is an IS rule |
| `dry_run` | validate and report without writing — how `check_transform_single_time_series` answers without a trial-and-rollback |

The **irregular-period guard stays in Julia** (`transform_single_time_series!`,
`system_data.jl`): the core supports monthly transforms and has a test for it, so IS's ban
is an IS arithmetic limitation, not a store invariant. It is O(1) and costs nothing.

Now unused inside IS but deliberately kept (downstream may reach them):
`infrastore_list_keys_with_owner` and the 5-arg `get_forecast_window_count`.

`T` is the value element type (`Float64` or a domain type such as `LinearFunctionData`);
`N` is the array rank — per-window for forecasts, per-series for static — and is
deliberately NOT lifted to the abstract parents, since its meaning varies by subtype.

Every concrete type carries a `units::Union{Nothing, String}` field — a **user-declared**
label (`"MW"`), read with `get_units`, defaulting to `nothing`. It is distinct from
`element_type` (package-derived; a user never sets it) and from features (identity):

- set at construction, **immutable** — do not add a setter;
- **never** filterable: not on `TimeSeriesKey`, not a `get_time_series*` argument. Two
  series differing only in their label are a duplicate, and `units` is in InfraStore's
  `RESERVED_FEATURE_NAMES` so it cannot be smuggled in as a feature;
- carried over by every data-sharing constructor (`X(src, name)`, subset forms) and by a
  derived `DeterministicSingleTimeSeries`;
- IS neither interprets nor validates it — no units vocabulary in IS. `nothing` is left
  alone; "unknown" vs "dimensionless" is the caller's convention.

Not to be confused with the `RelativeUnits` system markers (`SU`/`CU`/`NU`) — a per-unit
normalization base, not a physical dimension. The time series accessors take no
`units::AbstractUnitSystem` argument. `default_units` (`src/units.jl`) is a trait that
PowerSystems extends; IS does not call it.

`get_unit_system` on a series is **derived**, not a field or constructor kwarg: `per_unit_of` set ⇒
`CU`, else `units` set ⇒ `NU`, else `nothing`. It is still written to the store
column / document; on read, a recorded value must match the derived one (`check_unit_system`,
`DataFormatError`). `SU` cannot be expressed on a series.

In InfraStore, `units`, `ext`, and `element_type` are fields on the series, written and read
through by the store on both per-key and bulk paths. Do not add a read path that skips them.

`Base.eltype(::TimeSeriesData{T}) = T` is the only accessor.
Prefer a signature constraint over a runtime check:

```julia
f(ts::TimeSeriesData{<:PiecewiseStepData}) = ...            # good — dispatch
f(ts::TimeSeriesData) = throw(TypeError(...eltype(ts)))     # explicit mismatch method
```

Because the abstract types are `UnionAll`s, plain `::TimeSeriesData` annotations,
`Type{<:TimeSeriesData}` and `where {T <: TimeSeriesData}` bounds all still work
unchanged. What does NOT work is subtyping without a parameter — `struct Foo <:
TimeSeriesData end` must become `<: TimeSeriesData{Float64}`.

## Time series batching and transactions

One primitive: `time_series_transaction(data) do txn ... end`. The yielded
`TimeSeriesContext` is the block's API surface: call `add_time_series!(txn, owner, ts)` on
it once per series. **IS buffers nothing.** Each add goes straight to the store as one call
and returns its `TimeSeriesKey`; the store is what batches. Inside an open transaction
InfraStore's HDF5 backend accumulates the packed arrays into a pending block per pool and
writes each block whole at the outermost commit, so a run of adds produces the same
one-dataset-per-pool file a bulk add would. The block is also an InfraStore transaction: if
it throws, everything it did is rolled back, **including removals**, which are irreversible
outside one (the store frees an array once its last reference goes; inside a transaction
that free is deferred to the commit).

`add_time_series!` on the `SystemData` or manager is the same call without the block: atomic
on its own, still returning its key. There is no `context` kwarg — the transaction is
selected by dispatch on the first argument. A transaction opened on a `SystemData` carries
its owner validation (`owner_validator`); one opened on a bare manager does not. The context
holds the manager, the forecast-parameters cache, the validator, and one **scratch**
`InfraStore.AddBatch` — scratch, not a buffer: every add drains it. It exists only because an
`AddBatch` owns an FFI handle and registers a finalizer, so allocating one per add puts 10k
finalizers in front of the GC over a bulk ingest; measured on the forecast rows that is worth
~10 points of the ingest cost. It is created on the first add, so read paths still allocate
nothing.

Reads inside a block see what the block has written — the store serves a pending array out
of its own buffer — so removals, transforms and reads of a series added earlier in the same
block just work. There is no flush to call and no staged-metadata overlay: IS keeps no
in-memory association index, and the store is the single source of truth.

Constraints: blocks nest innermost-first (SQLite savepoints are a stack), and an open block
holds the store's write lock so gather data *before* opening one.

**Never flush the store per add.** `Store::flush` checkpoints SQLite's WAL *and* calls
`materialize_pending`, which spills the backend's pending block a column at a time — exactly
what the buffering exists to avoid. The outermost `commit_transaction` flushes the backend.

A package writing a store with **no `SystemData` behind it** — an importer staging a
document's time series sidecar, a parser emitting a serialized system — uses
`add_time_series!(store, owner_id, owner_type, owner_category, ts)`, which names the owner by
id and type instead of by object and returns the row's `TimeSeriesKey`. Static series only: a
forecast's window parameters need a manager to validate them against the rest of the store,
so a forecast there is a named `ArgumentError`. PowerSystems' openapi test fixtures are the
consumer; keep an IS test on this path, because its only other exercise lives in another repo.

No `InfraStore.AddBatch` is built by hand anywhere any more. `make_add_batch` and
`commit_batch!` are **deleted** — they had no IS caller even before write-through, and the
batch they exposed is precisely the indirection the store now does itself. `serialize_single!`
/ `serialize_non_sequential!` survive as internal encoders for that path and the manager
stagers; they return nothing (the staged-byte accounting existed only to drive the deleted
auto-flush).

Removed in IS4 — do not reintroduce: `begin_time_series_update` (snapshot-diff rollback),
`open_time_series_store!` and its `mode` argument (named an HDF5 handle that no longer
exists; the arg was never read — renamed to `time_series_transaction`),
`bulk_add_time_series!` and `TimeSeriesAssociation` (a six-line loop over the context),
`ADD_TIME_SERIES_BATCH_SIZE` (silently ignored), and the context's own add buffer: `flush!(txn)`, `has_staged_data`, `added_keys`, `collect_keys`,
`AUTO_FLUSH_THRESHOLD`/`auto_flush_threshold`, `AUTO_FLUSH_BYTES`/`auto_flush_bytes`,
`make_add_batch`, `commit_batch!` and `_staged_nbytes`/`_encoded_nbytes`.
