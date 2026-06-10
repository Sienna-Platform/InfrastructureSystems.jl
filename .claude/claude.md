# InfrastructureSystems.jl

**Package role:** Utility foundation library
**Julia compat:** ^1.10

## Overview

Foundational library for performance-critical simulation packages. For general Sienna coding practices, conventions, and performance guidelines, see [.claude/Sienna.md](.claude/Sienna.md).

This document covers InfrastructureSystems-specific aspects.

> **Maintenance note:** Update this file whenever files, directories, or architectural
> patterns change so it stays accurate.

## File Structure

### `src/`

Key files:
- `InfrastructureSystems.jl` — main module; the only place exports are allowed (see Export policy)
- `system_data.jl` — SystemData implementation
- `time_series_interface.jl` — time series public API (accessors take a `units` kwarg; see Units layer)
- `component.jl` — base component types
- `value_curve.jl` — `ValueCurve{T<:FunctionData}` and static curve types (`InputOutputCurve`, `IncrementalCurve`, `AverageRateCurve`)
- `time_series_value_curve.jl` — time-series-backed value curves + `build_static_curve` per-timestep resolution
- `cost_aliases.jl` — user-facing curve aliases (`LinearCurve`, `PiecewiseIncrementalCurve`, …) and their `TimeSeries*` counterparts
- `production_variable_cost_curve.jl` — `CostCurve{T,U}` / `FuelCurve{T,U}` (units in the type parameter)
- `relative_units.jl` — `RelativeUnits` submodule: unit-system markers and `RelativeQuantity`
- `outputs.jl` — abstract `Outputs` interface (not-implemented stubs for downstream packages)
- `serialization.jl` — JSON-based serialization (stdlib-adjacent `JSON`; JSON3/StructTypes were removed)

Subdirectories:
- `function_data/` — `FunctionData` hierarchy, time-series-backed function data, convexity/validity checks
- `utils/` — utility functions including `generate_structs.jl`
- `generated/` — auto-generated struct files (**DO NOT EDIT directly**)
- `descriptors/` — JSON descriptors for struct generation (`structs.json`)
- `Optimization/` — abstract types only (~185 lines): container/key abstract types
  (`VariableType`, `ConstraintType`, `ParameterType`, …), formulation abstract types,
  construct stages, and enums. The concrete results/container machinery was removed in
  IS4; consumers (PowerSimulations/IOM) define their own concrete types on these parents.
- `Simulation/` — simulation utilities

## Units Layer (RelativeUnits)

IS provides unit-system *plumbing* only — SU/DU/NU acquire domain meaning in PowerSystems.jl.
IS itself performs no domain conversions; only the plumbing and `convert_cost_coefficient`
math are testable here.

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
no-silent-units-drop guarantee.

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

## Consumed By

- PowerSystems.jl
- PowerSimulations.jl
- PowerSimulationsDynamics.jl
- PowerNetworkMatrices.jl

## Core Abstractions

- `InfrastructureSystemsComponent`
- `InfrastructureSystemsType`
- `InfrastructureSystemsContainer`
- `SystemData`
- `TimeSeriesData`
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

## Common Tasks

| Task | Command |
|------|---------|
| Run tests | `julia --project=test test/runtests.jl` |
| Run one testset | `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("<name>")'` |
| Compile check | `julia --project -e 'using InfrastructureSystems'` |
| Build docs | `julia --project=docs docs/make.jl` |
| Format code | `julia -e 'include("scripts/formatter/formatter_code.jl")'` |
| Check format | `git diff --exit-code` |
| Instantiate test env | `julia --project=test -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'` |
| Generate structs | `julia bin/generate_structs.jl src/descriptors/structs.json src/generated/` |

## AI Agent Guidance

**IMPORTANT:** Review [.claude/Sienna.md](.claude/Sienna.md) for general Sienna coding practices, performance requirements, and conventions.

### InfrastructureSystems-Specific Priorities

1. **Auto-generated files** — Never edit files in `src/generated/` directly. Modify `src/descriptors/structs.json` instead and run the generation command.
2. **Performance is critical** — This is a foundational library. Apply performance best practices rigorously in hot paths.
3. **Type stability** — Use `@code_warntype` to verify performance-critical functions.
4. **No `isa`/`<:` branching in function logic** — use multiple dispatch (function barriers for heterogeneous input). Sanctioned exceptions: `serialize`/`deserialize` bodies (cold path, heterogeneous JSON) and exception inspection inside `catch` blocks.
5. **Avoid kwargs as much as possible** — Since InfrastructureSystems is a utility library consumed by other applications, avoid using `kwargs...` especially in functions that may be called in hot loops. Use explicit keyword arguments instead for better performance and type stability or avoid keyword arguments all together.
6. **Public API documentation** — Add docstrings to all public interface elements using `DocStringExtensions.TYPEDSIGNATURES`.
7. **Formatter** — Run `julia -e 'include("scripts/formatter/formatter_code.jl")'` on all changes.
8. **Actionable errors** — Prefer erroring dispatch methods (`ArgumentError` naming the offending types/units) over letting calls fall into Base promotion machinery or bare `MethodError`s.

### When Modifying Code

- Read existing code patterns before making changes
- Maintain consistency with existing style
- Prefer failing fast with clear errors over silent failures
- Consider impact on downstream packages (PowerSystems.jl, PowerSimulations.jl, etc.)
