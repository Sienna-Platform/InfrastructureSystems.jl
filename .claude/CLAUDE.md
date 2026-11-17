# InfrastructureSystems.jl (IS) — IS4 branch

**Package role:** Utility foundation library — Layer 0 of the psy6 stack.
**Julia compat:** ^1.10. Version stays 3.6.0 until release (this *is* the 4.0 line; never bump — bumps have reappeared spontaneously mid-session, revert them).

## Overview

Foundational library for performance-critical simulation packages: SystemData, component containers, time series (HDF5/in-memory + SQLite metadata), serialization, struct codegen, and the `RelativeUnits` layer.

## Downstream blast radius

**Every psy6 package sits on IS.** Any signature/behavior change ripples platform-wide; time-series, serialization, and units changes are the highest-risk classes — extend serialization round-trip tests when touching them. After an IS change, run the downstream suites in the blast-radius order of `.claude/Sienna.md`.

(The psy5 line's PowerSimulations/PSID consume the *top-level* IS checkout on `main`, not this one.)

IS owns the archive container and the array-only store writer *because* they are shared, so a rename
here is a rename there. PowerSystems calls `create_sienna_archive`/`extract_sienna_archive` from
`src/openapi/file_io.jl` and `serialize_arrays` from `src/openapi/export_document.jl`.
PowerSystemsInvestmentsPortfolios does not call them yet.

## Source layout — the non-obvious parts

- `src/serialization.jl` — JSON-based; JSON3/StructTypes were removed in IS4. Per-type
  deserialize methods narrow JSON's loose types back to declared field types — optional
  `DateTime` (`Union{Nothing, Dates.DateTime}`) and `Vector{String}` (JSON arrays parse to
  `Vector{Any}`).
- `src/geographic_supplemental_attribute.jl`, `src/data_source_supplemental_attribute.jl` —
  the two hand-written supplemental attributes (`GeographicInfo`, `DataSource`); neither is
  exported, and both are shared across components create-once/link-many via the association
  store rather than owned by one component.
- `src/sienna_archive.jl` — the Sienna archive container, and only the container (see below).
- `src/generated/` — auto-generated (**never edit**); `src/descriptors/structs.json` is its source.
- `src/Optimization/` — **abstract types only** (~185 lines): container/key abstracts, formulation
  abstracts, construct stages, enums. The concrete results/container machinery was removed in IS4;
  the consumer defining concretes in this line is **InfrastructureOptimizationModels (IOM)**.

The Sienna archive container and the array-only store writer: `.claude/rules/sienna-archive.md`
(loads when you read or edit `src/sienna_archive.jl` or `src/infrastore.jl`).

## Units Layer (RelativeUnits)

IS provides unit-system *plumbing* only — SU/CU/NU acquire domain meaning in PowerSystems.jl.
IS itself performs no domain conversions; only the plumbing and `convert_cost_coefficient`
math are testable here. IS names no domain quantity: it must work equally for, say, a gas network.

- Per-unit values are `Unitful.Quantity`s. `RelativeQuantity` is **deleted**; don't reintroduce it.
- `RelativeUnits`: the `CU`/`SU`/`NU` markers, now only a type parameter (`CostCurve{T,U}`) and export mode. `0.6 * CU` throws.
- `PerUnit`: generic `u"CU"`/`u"SU"`/`u"NU"` (own dimensions) and `resolve_per_unit(units, cu_base, su_base, natural)`, which swaps them for a field's units. Domains define the base dimensions. `u"CU"` needs `PerUnit` bound in the caller.
- `resolve_per_unit` folds at compile time via `@generated` + `Val` dispatch; don't turn it into a runtime loop.
- Display: `display_string` + domain hooks `display_base_label`/`display_value`.

`CostCurve{T,U}` / `FuelCurve{T,U}` carry `U <: AbstractUnitSystem` as a type parameter
(replacing the old `power_units::UnitSystem` runtime field). Serialized under the
`"power_units"` key as the marker type name (e.g. `"SystemBaseUnit"`); `_unit_system_instance`
decodes that name back to the singleton. IS4 is a breaking release: the legacy IS3
`UnitSystem` enum is **not accepted** anywhere in the cost-curve API — not as a
constructor argument, not as a serialized value-name (`"SYSTEM_BASE"`). Downstream packages
(PowerSystemCaseBuilder, PowerSystems) must pass `SystemBaseUnit()`/`ComponentBaseUnit()`/
`NaturalUnit()` instances. `zero(c)` preserves the unit parameter; `zero(CostCurve)`
(type form) defaults to NU.

## Time-Varying Cost Curve Type Hierarchy

Static and time-series-backed curves share abstract parents so `CostCurve`/`FuelCurve`
accept either with zero code changes:

```
FunctionData
├─ StaticFunctionData            (scalar data)
│   ├─ LinearFunctionData, QuadraticFunctionData
│   └─ PiecewiseLinearData, PiecewiseStepData
└─ TimeSeriesFunctionData{T<:StaticFunctionData, U}   (wraps a TimeSeriesKey; data lives in
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

Structs can be auto-generated from JSON descriptors using Mustache templates. Generated files are in `src/generated/` and must not be edited directly. Today it holds only its own `CLAUDE.md`; PowerSystems is the consumer of the generator.

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
  already carries its own unit tag; `set_value`
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

IS generally does not export functions, to avoid name clashes with downstream packages.
The sanctioned exceptions, all in `src/InfrastructureSystems.jl`:
- the units-interface generics `get_value`/`set_value` — declared in IS, methods
  implemented by domain packages, which must EXTEND (not own/redefine) them; the
  struct-generator template emits methods extending `IS.get_value`/`IS.set_value`;
- the cost aliases (`LinearCurve`, …, and `TimeSeries*` counterparts) — required for
  proper display.

Do not add other exports.

## Known landmines — do not extend

- Component UUID index can desync from the name index (`component.jl` vs `system_data.jl` add/remove paths).
- **Missing validation descriptor → validation silently passes** (`validation.jl:~74`) — a named silent-failure pattern; new validation code must error loudly instead.
- Containers expose `.data` — prefer accessor functions; do not add new direct reaches.

## Time series

The time series type hierarchy, the transform, and transactions: `.claude/rules/time-series.md`
(loads when you read or edit a time series source file).

## Testing

- **Location:** `test/`
- **Runner:** ReTest-based — `test/runtests.jl` includes `test/InfrastructureSystemsTests.jl`
  and calls `run_tests()`. Loading the test module also runs Aqua.
- **Env setup:** `test/Project.toml` path-pins this checkout; `Pkg.instantiate()` is the whole setup:
  `julia --project=test -e 'using Pkg; Pkg.instantiate()'`
- **Single testset** (regex on testset names):
  `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("<name>")'`
- If the package registry is unreachable (HTTP 403), prefix commands with `JULIA_PKG_SERVER=`.
- InfraStore comes from the registry at the `[compat] InfraStore` bound in `Project.toml`; read that bound before InfraStore work.

## AI Agent Guidance

The shared Sienna rules load from the import below; the `sienna-dev` skill holds the cross-package
context; the `sienna-dev` and `sienna-reviewer` subagents implement and review.

@Sienna.md

### InfrastructureSystems-Specific Priorities

1. **Auto-generated files** — Never edit files in `src/generated/` directly. Modify `src/descriptors/structs.json` instead and run the generation command.
2. **Performance is critical** — This is a foundational library. Apply performance best practices rigorously in hot paths.
3. **Type stability** — Use `@code_warntype` to verify performance-critical functions.
4. **No `isa`/`<:` branching in function logic** — use multiple dispatch (function barriers for heterogeneous input). Sanctioned exceptions: `serialize`/`deserialize` bodies (cold path, heterogeneous JSON) and exception inspection inside `catch` blocks.
5. **Avoid kwargs as much as possible.** IS is consumed in hot loops. When a keyword argument is needed, give it a concrete type annotation.
6. **Public API documentation** — Add docstrings to all public interface elements using `DocStringExtensions.TYPEDSIGNATURES`.
7. **Formatter** — run `julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'` before you report a task done.
8. **Actionable errors** — Prefer erroring dispatch methods (`ArgumentError` naming the offending types/units) over letting calls fall into Base promotion machinery or bare `MethodError`s.
