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
- `src/generated/` — auto-generated (**never edit**); `src/descriptors/structs.json` is its source.
- `src/Optimization/` — **abstract types only** (~185 lines): container/key abstracts, formulation
  abstracts, construct stages, enums. The concrete results/container machinery was removed in IS4;
  the consumer defining concretes in this line is **InfrastructureOptimizationModels (IOM)**.

## Units Layer (RelativeUnits)

IS provides unit-system *plumbing* only — SU/DU/NU acquire domain meaning in PowerSystems.jl.
IS itself performs no domain conversions; only the plumbing and `convert_cost_coefficient`
math are testable here. IS exports the markers and `RelativeQuantity` only — there is **no
unit-string vocabulary in IS**; that vocabulary lives in `SiennaSchemas/Core/units.json` for
the data pipeline.

```
RelativeUnits submodule (src/relative_units.jl)
  AbstractUnitSystem ⊃ {AbstractRelativeUnit ⊃ {DeviceBaseUnit, SystemBaseUnit}, NaturalUnit}
  const singletons DU, SU, NU
  RelativeQuantity{T<:Number, U<:AbstractRelativeUnit} <: Number  (built via `0.6 * DU`)
  convert_cost_coefficient + 9-method _cost_coeff_ratio dispatch table (+ erroring catch-all)
  traits: _strip_units (domain packages MUST extend for their quantity types), display_units_arg
```

Guard rails (all dispatch-based, erroring `ArgumentError`s):
- Re-tagging a tagged value (`(0.6DU) * SU`) throws — no silent nesting.
- Cross-unit `+`, `-`, `==`, `<`, `<=`, `isless`, `isapprox` throw — convert explicitly first.
- Tagged-vs-untagged `==`/`+`/`-` (`0.6DU == 0.5`) throw.
- `Base.hash` is defined consistently with the cross-payload `==` (Dict/Set safe for same-unit keys).
- Note: `isequal` falls back to the throwing `==`, so *mixed-unit* Dict keys can throw on
  hash collision — define a non-throwing `isequal` if that's ever needed.

`CostCurve{T,U}` / `FuelCurve{T,U}` carry `U <: AbstractUnitSystem` as a type parameter
(replacing the old `power_units::UnitSystem` runtime field). Serialized under the
`"power_units"` key as the marker type name (e.g. `"SystemBaseUnit"`); `_unit_system_instance`
decodes that name back to the singleton. IS4 is a breaking release: the legacy IS3
`UnitSystem` enum is **no longer accepted** anywhere in the cost-curve API — not as a
constructor argument, not as a serialized value-name (`"SYSTEM_BASE"`). Downstream packages
(PowerSystemCaseBuilder, PowerSystems) must pass `SystemBaseUnit()`/`DeviceBaseUnit()`/
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
    (TimeSeriesIncrementalCurve carries initial_input / input_at_zero as
     Union{Nothing, Float64, TimeSeriesKey} fields — do NOT "fix" the union for boxing)

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
  already carries its own unit tag (a `RelativeQuantity` or domain quantity); `set_value`
  strips it internally. This asymmetry is intentional: getters need to know the target unit
  system (e.g. `SU`, `DU`, `MW`) at call time, while setters rely on the value itself to
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

Not to be confused with the `RelativeUnits` system markers (`SU`/`DU`/`NU`) — a per-unit
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
`TimeSeriesContext` is the block's API surface: call `add_time_series!(txn, owner, ts)` on it
and the adds are buffered and written as one bulk call — that batching is what buys
block-sized array writes and feature-set dedup, which a transaction does not provide. The
block is also an InfraStore transaction: if it throws, everything it did is rolled back,
**including removals**, which are irreversible outside one (the store frees an array once
its last reference goes; inside a transaction that free is deferred to the commit).

`add_time_series!` on the `SystemData` or manager means "no batch": the operation goes
straight to the store, which is atomic on its own. There is no `context` kwarg — the batch
is selected by dispatch on the first argument. A transaction opened on a `SystemData`
carries its owner validation (`owner_validator`); one opened on a bare manager does not.
Read paths take no context and allocate nothing — a `TimeSeriesContext` owns an FFI
`AddBatch` handle, so constructing one per read would be a real cost in per-timestep loops.
The batch itself is created lazily on the first stage. Inside a block, reads (and
removals/transforms) still see the block's buffered additions: the manager records the
innermost open context in `active_context`, and `get_data_store(mgr)` flushes it before
handing the store out. Code that must *not* flush (the batch commit itself, the
per-stage forecast-parameter check) reaches `mgr.data_store` directly.

Constraints: blocks nest innermost-first (SQLite savepoints are a stack), and an open block
holds the store's write lock so gather data *before* opening one.

The batch auto-flushes at `AUTO_FLUSH_THRESHOLD` (10,000) staged additions or
`AUTO_FLUSH_BYTES` (256 MiB) of staged array data, whichever first, so arbitrarily large
blocks hold bounded memory. The count keeps HDF5 chunks near the store's 1 MiB cap (chunk
width = batch width); the byte limit is the real memory bound for long arrays. Auto-flushed
work still rolls back with the block.

Removed in IS4 — do not reintroduce: `begin_time_series_update` (snapshot-diff rollback),
`open_time_series_store!` and its `mode` argument (named an HDF5 handle that no longer
exists; the arg was never read — renamed to `time_series_transaction`),
`bulk_add_time_series!` and `TimeSeriesAssociation` (a six-line loop over the context), and
`ADD_TIME_SERIES_BATCH_SIZE` (silently ignored).

## Core Abstractions

- `InfrastructureSystemsComponent`
- `InfrastructureSystemsType`
- `InfrastructureSystemsContainer`
- `SystemData`
- `TimeSeriesData{T}` (see Time Series Type Hierarchy)
- `ValueCurve` (static and `TimeSeries*` curves)
- `ProductionVariableCostCurve` (`CostCurve{T,U}`, `FuelCurve{T,U}`)
- `FunctionData` (`StaticFunctionData`, `TimeSeriesFunctionData`)
- `RelativeUnits.AbstractUnitSystem` (`DU`, `SU`, `NU` singletons)
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
