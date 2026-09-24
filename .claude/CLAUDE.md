# InfrastructureSystems.jl (IS) — IS4 branch

**Package role:** Utility foundation library — Layer 0 of the psy6 stack.
**Julia compat:** ^1.10. Version stays 3.6.0 until release (this *is* the 4.0 line; never bump — bumps have reappeared spontaneously mid-session, revert them).

## Overview

Foundational library for performance-critical simulation packages: SystemData, component containers, time series (HDF5/in-memory + SQLite metadata), serialization, struct codegen, and the `RelativeUnits` layer. General Sienna practices: the `sienna-psy6` skill. Workspace wiring: the psy6 workspace root `CLAUDE.md`.

## Downstream blast radius

**Every psy6 package sits on IS**: PowerSystems, PowerNetworkMatrices, PowerFlows, PowerFlowFileParser, InfrastructureOptimizationModels, PowerOperationsModels, PowerSystemCaseBuilder. Any signature/behavior change ripples platform-wide; time-series, serialization, and units changes are the highest-risk classes — extend serialization round-trip tests when touching them. After an IS change, smoke the stack:

```sh
julia --project=<psy6-workspace-root> -e 'using PowerSystems, PowerNetworkMatrices, PowerFlows, PowerOperationsModels, PowerSystemCaseBuilder'
```

(The psy5 line's PowerSimulations/PSID consume the *top-level* IS checkout on `main`, not this one.)

Two consumers now depend on things IS owns *because* they are shared, so a rename here is a rename
there: PowerSystems calls the `*_sienna_archive` trio and `serialize_arrays`/`deserialize_arrays` from
`src/openapi/file_io.jl`, and PowerSystemsInvestmentsPortfolios is the second archive consumer these
were factored out for.

## Source layout — the non-obvious parts

- `src/InfrastructureSystems.jl` — the **only** place exports are allowed (see Export policy).
- `src/serialization.jl` — JSON-based; JSON3/StructTypes were removed in IS4. Per-type
  deserialize methods narrow JSON's loose types back to declared field types — optional
  `DateTime` (`Union{Nothing, Dates.DateTime}`) and `Vector{String}` (JSON arrays parse to
  `Vector{Any}`).
- `src/geographic_supplemental_attribute.jl`, `src/data_source_supplemental_attribute.jl` —
  the two hand-written supplemental attributes (`GeographicInfo`, `DataSource`); neither is
  exported, and both are shared across components create-once/link-many via the association
  store rather than owned by one component.
- `src/sienna_archive.jl` — the **`.sn` archive container**, and only the container (see below).
- `src/generated/` — auto-generated (**never edit**); `src/descriptors/structs.json` is its source.
- `src/Optimization/` — **abstract types only** (~185 lines): container/key abstracts, formulation
  abstracts, construct stages, enums. The concrete results/container machinery was removed in IS4;
  the consumer defining concretes in this line is **InfrastructureOptimizationModels (IOM)**.

## The Sienna archive and the store's two halves

`src/sienna_archive.jl` owns the **`.sn`** container: a directory of files, zipped into one
file. It lives here rather than in a consumer because nothing about the container is specific to a
`System` — PowerSystems packs a system document plus its time-series sidecars, PowerSystemsInvestments-
Portfolios will pack whatever a portfolio needs, and reimplementing the rules per package is how two
archives end up disagreeing about what `.sn` means.

```julia
is_sienna_archive(path)                            # extension test a reader dispatches on
create_sienna_archive(fill!, path; force = false)  # fill! populates a staging dir; that becomes the archive
extract_sienna_archive(path)                       # -> directory holding the members
```

Four things to know before touching it:

- **`fill!` decides the contents, this file decides nothing about them.** Keep it that way; a member
  list belongs to the package that writes it.
- **Zip, because compression is a per-member choice.** Members are deflated except for the
  extensions in `NO_COMPRESS_EXTENSIONS` (`.h5`, `.hdf5`), which are stored as they are: an archive
  is mostly its HDF5 sidecar, and deflating it walks every byte to save almost nothing. A gzip'd tar
  is one stream over the concatenated members and compresses all of them or none, which is why the
  format changed.
- **The extension is enforced on write** because it is the whole read-side test. An archive named
  otherwise could not be found again, so a non-`.sn` path is a `DataFormatError`, not a warning.
- **`extract_sienna_archive`'s directory outlives the call.** `mktempdir()`'s default
  `cleanup = true` registers it for atexit deletion, which a caller that keeps reading from the
  extracted files needs — a store opened in place out of the archive, say. Do not wrap it in a
  `do` block.

`ZipArchives` and `Mmap` are dependencies for this and nothing else (`extract_sienna_archive` maps
the archive rather than reading it into memory, since a stored HDF5 member makes an archive as large
as the data it holds).

### Arrays with and without the catalog

An InfraStore artifact is an HDF5 file plus a `.sqlite` catalog, and `serialize` writes both. A writer
whose own document already carries the catalog's association rows does not need the second half:

- `serialize_arrays(store, path)` writes the array half alone. Atomic, unlike `serialize`.
- `deserialize_arrays(path)` opens such an artifact and mints an empty catalog for a document's rows.
- `import_time_series_association_rows!(store_or_data, json)` replays them — the counterpart of
  `import_supplemental_attribute_association_rows!`.

`open_deserialized_infrastore_store` detects a source with no `.sqlite` beside it and mints rather than
copying one that is not there. Such a source is copied out and given a fresh catalog **`read_only` or
not**: there is no catalog to open in place, and minting one into the caller's directory is exactly the
mutation `read_only` exists to prevent.

These wrap `Store::persist_arrays_to` and `Store::open_without_catalog`, which are **unreleased**
(NatLabRockies/infrastore#71). `[compat] InfraStore` is deliberately unbumped until they ship.

## Units Layer (RelativeUnits)

IS provides unit-system *plumbing* only — SU/CU/NU acquire domain meaning in PowerSystems.jl.
The rule for what goes here: it must apply equally well to a non-power network (gas pipelines,
say). IS performs no domain conversions and names no domain quantity; only the plumbing and
`convert_cost_coefficient` math are testable here. There is **no unit-string vocabulary in
IS**; that lives in `SiennaSchemas/Core/units.json` for the data pipeline.

Per-unit *values* are `Unitful.Quantity`s. `RelativeQuantity` and its arithmetic guards were
**deleted**: Unitful's dimension checking replaces them. Do not reintroduce a hand-rolled per-unit number type.

```
RelativeUnits submodule (src/relative_units.jl) — unit-system markers
  AbstractUnitSystem ⊃ {AbstractRelativeUnit ⊃ {ComponentBaseUnit, SystemBaseUnit}, NaturalUnit}
  const singletons CU, SU, NU     (a type parameter / dispatch target, e.g. CostCurve{T, U})
  `0.6 * CU` throws, naming the `0.6u"CU"` spelling
  convert_cost_coefficient; traits: _strip_units, display_units_arg, unitful_variant

PerUnit submodule (src/per_unit.jl) — Unitful side
  generic units u"CU", u"SU", each with its own dimension (no mixing, no uconvert to natural)
  resolve_per_unit(units, component_base, system_base): swaps the caller's generic CU/SU
    for a field's base units, keeping the residual (u"CU/hr" -> component_base/hr)
```

- **Domain packages own the base dimensions** (PowerSystems: component/system base power,
  component base voltage) and pass each field's base units to `resolve_per_unit`. That's what
  makes per-unit resistance + per-unit power a `DimensionError`. IS must not define them.
- `u"CU"` needs `PerUnit` bound in the calling module: Unitful's `@u_str` only searches unit
  modules the caller has by name. Use `using InfrastructureSystems: PerUnit`, or re-export it.
- `PerUnit`, not `RelativeUnits`, holds the Unitful `CU`/`SU` because `RelativeUnits.CU` is the
  marker; the two coexist under different modules.
- `resolve_per_unit` runs on every unit-aware getter and folds to a constant (tested). Its
  exponents come from a `@generated` function and the branch from `Val` dispatch; a runtime
  loop also folds, but via const-prop and at ~20% more compile time. Don't "simplify" it back.

`CostCurve{T,U}` / `FuelCurve{T,U}` carry `U <: AbstractUnitSystem` as a type parameter
(replacing the old `power_units::UnitSystem` runtime field). Serialized under the
`"power_units"` key as the marker type name (e.g. `"SystemBaseUnit"`); `_unit_system_instance`
decodes that name back to the singleton. IS4 is a breaking release: the legacy IS3
`UnitSystem` enum is **no longer accepted** anywhere in the cost-curve API — not as a
constructor argument, not as a serialized value-name (`"SYSTEM_BASE"`). Downstream packages
(PowerSystemCaseBuilder, PowerSystems) must pass `SystemBaseUnit()`/`ComponentBaseUnit()`/
`NaturalUnit()` instances. `zero(c)` preserves the unit parameter; `zero(CostCurve)`
(type form) defaults to NU.

### Time series accessors and the multiplier contract

The `get_time_series_array`/`get_time_series_values` accessor family takes
`units::Union{Nothing, AbstractUnitSystem} = default_units(owner)`, forwarded to the
scaling-factor multiplier; IS performs no conversion itself. `default_units(::Any)`
returns `nothing` (IS fallback); domain packages override it per owner type (e.g.
PowerSystems returns `SU` for `Component`s).

As of IS 4.0, `scaling_factor_multiplier` functions may be either **unit-aware**
(define a 2-arg method `(owner, ::AbstractUnitSystem)`) or **unit-agnostic** (define
only `(owner)` — user closures, pre-IS4 multipliers). `_apply_multiplier`
(in `_make_time_array`) resolves the arity per retrieval:
- It probes unit-awareness with `SU` (the 2-arg convention is `(owner, ::AbstractUnitSystem)`),
  using `requested = units === nothing ? SU : units`.
- **Prefers the 2-arg form** whenever the multiplier is unit-aware — including the default
  path, where `units === nothing` still routes a 2-arg-only multiplier through `(owner, SU)`.
- **Falls back to the 1-arg form only when no 2-arg method exists.**
- **Never silently drops units:** a unit-aware multiplier that lacks a method for the
  requested unit system raises an actionable `ArgumentError` rather than degrading to
  `(owner)`.

Do not remove or weaken the `units` kwarg API, the `default_units` trait, or the
no-silent-units-drop guarantee. (The IS/PSY units-gaps plan of 2026-07-04 is executed —
IS commits `a1fa162f` + `abae2e30`; only the full-suite verification gate remains.)

## Time-Varying Cost Curve Type Hierarchy

Static and time-series-backed curves share abstract parents so `CostCurve`/`FuelCurve`
accept either with zero code changes:

```
FunctionData
├─ StaticFunctionData            (scalar data)
│   ├─ LinearFunctionData, QuadraticFunctionData
│   └─ PiecewiseLinearData, PiecewiseStepData
└─ TimeSeriesFunctionData{T<:StaticFunctionData}   (wraps a TimeSeriesKey; data lives in
    the time series store)                          e.g. TimeSeriesFunctionData{PiecewiseStepData}

ValueCurve{T<:FunctionData}
├─ InputOutputCurve / IncrementalCurve / AverageRateCurve          (static)
└─ TimeSeriesInputOutputCurve / TimeSeriesIncrementalCurve /
   TimeSeriesAverageRateCurve   <: ValueCurve{<:TimeSeriesFunctionData}
    (TimeSeriesIncrementalCurve and TimeSeriesAverageRateCurve carry initial_input /
     input_at_zero as Union{Nothing, ConcreteTimeSeriesKey} fields — do NOT "fix" the
     union for boxing)

Cost aliases (cost_aliases.jl): LinearCurve, QuadraticCurve, PiecewisePointCurve,
PiecewiseIncrementalCurve, PiecewiseAverageCurve + TimeSeries* counterparts (all exported).
```

Key interface functions:
- `is_time_series_backed(x)` — uniform static-vs-TS check; propagates through
  `CostCurve`/`FuelCurve` → `ValueCurve` → `FunctionData`. Prefer this over `isa TimeSeriesKey`.
- `get_time_series_key(x)` — returns the underlying `TimeSeriesKey`. Defined for
  `ValueCurve`/`CostCurve` (and `FunctionData`); intentionally **NOT** defined for
  `FuelCurve` — its value curve and `fuel_cost` are independently TS-backed, so resolve
  explicitly via `get_time_series_key(get_value_curve(c))` or `get_fuel_cost(c)`.
  Non-TS-backed curves (and any `FuelCurve`) throw an `ArgumentError`, not a `MethodError`.
- `build_static_curve(owner, curve, start_time)` — resolves a TS curve to its static
  counterpart for one timestep. Issues one storage read per TS-backed field; hot-loop
  consumers should resolve through a `TimeSeriesCache` or batch reads.
- `is_convex`/`is_concave`/`is_valid_data` throw `ArgumentError` for TS-backed curves —
  validate the resolved static curve per timestep instead.

## Auto-Generation

Structs can be auto-generated from JSON descriptors using Mustache templates. Generated files are in `src/generated/` and should **NOT** be edited directly.

- **Descriptor file:** `src/descriptors/structs.json`
- **Generator:** `src/utils/generate_structs.jl`
- **Command:** `julia bin/generate_structs.jl src/descriptors/structs.json src/generated/`

### Workflow

1. Edit the JSON descriptor file to define/modify struct fields
2. Run the generation command
3. Generated files include docstrings and constructors automatically

### needs_conversion codegen contract

When a struct field has `needs_conversion: true` in its JSON descriptor, the code generator
produces two getter variants and one setter:

- `get_X(value, units)` — returns the field value as a bare number in the requested units
  (true only when the owning domain package has registered a `_strip_units` method for the
  returned quantity type).
- `get_X_unitful(value, units)` — returns the field value as a unit-bearing quantity.
- `set_X!(value, val)` — takes **no** `units` argument. The caller must supply a value that
  already carries its own unit tag (a `Unitful.Quantity`); `set_value`
  strips it internally. This asymmetry is intentional: getters need to know the target unit
  system (e.g. `SU`, `CU`, `MW`) at call time, while setters rely on the value itself to
  carry unit information.

An `exclude_getter` field means the public getter is hand-written elsewhere; the
generator emits a private `_get_X` for internal use and still exports the base name
`get_X` so the hand-written implementation is public. The `_unitful` companion is
exported ONLY for generated getters (`exclude_getter` absent/false) — it is deliberately
NOT exported for `exclude_getter` fields, since auto-exporting it could break
PowerSystems; coordinate with PSY before widening that export gate.

No descriptor inside IS uses `needs_conversion`; PowerSystems is the first consumer.
The branch is covered by a synthetic-descriptor test in `test/test_generate_structs.jl`.

## Export Policy

IS generally does NOT export functions, to avoid name clashes with downstream packages.
The sanctioned exceptions, all in `src/InfrastructureSystems.jl`:
- the units-interface generics `get_value`/`set_value` — declared in IS, methods
  implemented by domain packages, which must EXTEND (not own/redefine) them; the
  struct-generator template emits methods extending `IS.get_value`/`IS.set_value`;
- the cost aliases (`LinearCurve`, …, and `TimeSeries*` counterparts) — required for
  proper display.

Do not add other exports.

## Known audit items (2026-07-02) — treat as landmines, don't extend

- Supplemental-attribute removal rollback is a **shallow copy** (`supplemental_attribute_manager.jl:~29`) — partial-failure rollback can alias state.
- Component UUID index can desync from the name index (`component.jl` vs `system_data.jl` add/remove paths).
- `bulk_update_cache` can leak when an update errors mid-flight (`time_series_manager.jl:~89,109`).
- **Missing validation descriptor → validation silently passes** (`validation.jl:~74`) — a named silent-failure pattern; new validation code must error loudly instead.
- Containers expose `.data` and ~29 cross-file bare accesses exist — prefer accessor functions; do not add new direct reaches.

## Time Series Type Hierarchy

The whole hierarchy is parameterized on the value element type `T`, so callers dispatch on
the payload instead of querying it:

```
TimeSeriesData{T}
├─ StaticTimeSeries{T} ⊃ SingleTimeSeries{T, N}, NonSequentialTimeSeries{T, N}
└─ Forecast{T} ⊃ Probabilistic{T, N}, Scenarios{T, N},
   └─ AbstractDeterministic{T} ⊃ Deterministic{T, N}, DeterministicSingleTimeSeries{T, N}
```

`DeterministicSingleTimeSeries` is a **fieldless query marker** (as of IS4): the DST is
derived in-store by `transform_single_time_series!`, reads materialize a `Deterministic`,
and no instance is ever constructed. The type exists only for query/removal filters,
`TimeSeriesKey.time_series_type`, and the transform API — do not reintroduce data-bearing
fields or an instance `add_time_series!` path.

### transform_single_time_series! validation lives in Rust

**All** of the transform's eligibility validation is in the InfraStore core — horizon fit
and divisibility, interval divisibility and length, per-resolution grid uniformity, and
conflicts with forecasts already stored. IS used to re-run every one of these in Julia
over a listing of all 100k `SingleTimeSeries`; the store answers them from its distinct
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
  series differing only in their label are a duplicate, and `units` is in the store's
  `RESERVED_FEATURE_NAMES` so it cannot be smuggled in as a feature;
- carried over by every data-sharing constructor (`X(src, name)`, subset forms) and by a
  derived `DeterministicSingleTimeSeries`;
- IS neither interprets nor validates it — no units vocabulary in IS. `nothing` is left
  alone; "unknown" vs "dimensionless" is the caller's convention.

Not to be confused with the `RelativeUnits` system markers (`SU`/`CU`/`NU`) — a per-unit
normalization base, not a physical dimension. Note the accessor-side `units::AbstractUnitSystem`
kwarg documented under "Time series accessors" is **not present on this branch**
(`default_units` in `src/units.jl` has no callers here); when that line merges, the two
`units` spellings will collide by name and the accessor kwarg should be renamed, not this
field. The store column already existed, so no `DATA_FORMAT_VERSION` bump.

The same move was made in the Rust core: `units`, `ext`, and `element_type` are now fields
on the five `TimeSeriesData` variants and are **gone from `AddRequest`** — one shape across
IS.jl / InfraStore.jl / infrastore. Set them with the `with_units` / `with_ext` /
`with_element_type` builders on the series (or `set_descriptors` on the enum); the write
path reads them off the data, and `materialize_time_series` fills them back in from the
catalog row on every read. `Store::add_time_series` and `BulkAdd::add` lost their trailing
`units` parameter accordingly.

Bulk and per-key reads agree: `Store::bulk_read` populates the three from the catalog row
it already loads, the bulk-result FFI getters return them (`out_ext` / `out_element_type` /
`out_units`, all nullable), and `InfraStore.jl`'s `_bulk_*` decoders put them on the
reconstructed struct. The long-standing `ext`-drops-on-bulk-read gap is closed as part of
this; there is a parity test in InfraStore.jl's suite — don't reintroduce a read path that
skips them.

**infrasys (Python) is deliberately not done**: its `units` column already holds a
serialized `QuantityMetadata` blob derived from `pint.Quantity`; see
`infrasys/UNITS_FIELD_NOTE.md`.

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
what the buffering exists to avoid. IS had such a flush after every batch commit; removing it
is what made write-through viable (with it, write-through ran 7×–207× slower than the old
client-side buffer; without it, 2× on 24-step series and *faster* on 8760-step ones, same
bytes on disk). The outermost `commit_transaction` flushes the backend anyway.

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
`ADD_TIME_SERIES_BATCH_SIZE` (silently ignored), and — as of the write-through change — the
context's own add buffer: `flush!(txn)`, `has_staged_data`, `added_keys`, `collect_keys`,
`AUTO_FLUSH_THRESHOLD`/`auto_flush_threshold`, `AUTO_FLUSH_BYTES`/`auto_flush_bytes`,
`make_add_batch`, `commit_batch!` and `_staged_nbytes`/`_encoded_nbytes`.

## Core Abstractions

- `InfrastructureSystemsComponent`
- `InfrastructureSystemsType`
- `InfrastructureSystemsContainer`
- `SystemData`
- `TimeSeriesData{T}` (see Time Series Type Hierarchy)
- `ValueCurve` (static and `TimeSeries*` curves)
- `ProductionVariableCostCurve` (`CostCurve{T,U}`, `FuelCurve{T,U}`)
- `FunctionData` (`StaticFunctionData`, `TimeSeriesFunctionData`)
- `RelativeUnits.AbstractUnitSystem` (`CU`, `SU`, `NU` singletons)
- `ComponentSelector`
- `Outputs`

## Testing

- **Location:** `test/`
- **Runner:** ReTest-based — `test/runtests.jl` includes `test/InfrastructureSystemsTests.jl`
  and calls `run_tests()`. Loading the test module also runs Aqua.
- **One-time env setup (REQUIRED**, otherwise tests run against the registry copy of IS):
  `julia --project=test -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'`
- **Single testset** (regex on testset names):
  `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("<name>")'`
- If the package registry is unreachable (HTTP 403), prefix commands with `JULIA_PKG_SERVER=`.
- Full-suite baseline (2026-07-29): 8,771 passing, 1 broken.
- Requires `INFRASTORE_LIB` pointing at `libinfrastore_ffi` (see the InfraStore repo).

## AI Agent Guidance

Platform-wide practices, performance requirements, and conventions: invoke the `sienna-psy6` skill.

### InfrastructureSystems-Specific Priorities

1. **Auto-generated files** — Never edit files in `src/generated/` directly. Modify `src/descriptors/structs.json` instead and run the generation command.
2. **Performance is critical** — This is a foundational library. Apply performance best practices rigorously in hot paths.
3. **Type stability** — Use `@code_warntype` to verify performance-critical functions.
4. **No `isa`/`<:` branching in function logic** — use multiple dispatch (function barriers for heterogeneous input). Sanctioned exceptions: `serialize`/`deserialize` bodies (cold path, heterogeneous JSON) and exception inspection inside `catch` blocks.
5. **Avoid kwargs as much as possible** — IS is consumed in hot loops; use explicit keyword arguments or none.
6. **Public API documentation** — Add docstrings to all public interface elements using `DocStringExtensions.TYPEDSIGNATURES`.
7. **Formatter** — run it before reporting any task done.
8. **Actionable errors** — Prefer erroring dispatch methods (`ArgumentError` naming the offending types/units) over letting calls fall into Base promotion machinery or bare `MethodError`s.

### When Modifying Code

- Read existing code patterns before making changes
- Maintain consistency with existing style
- Prefer failing fast with clear errors over silent failures
- Consider downstream impact across the whole psy6 stack (see blast radius above)
