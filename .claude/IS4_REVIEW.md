# IS4 Branch Review — Implementation Handoff

> One-shot task file for a Claude Code implementation session. Reference this file
> explicitly in your prompt. DELETE it in the final cleanup commit once every card
> is done or explicitly deferred to Section 6.

## 0. Read this first

- **Review basis:** commit `1c69410` (branch `claude/youthful-bell-xxgcvp` == `IS4`),
  reviewed 2026-06-10 against `origin/main` (merge-base `316779b`). 62 files,
  +2,657/−2,873 lines.
- **VERIFY BEFORE APPLYING:** if `git log --oneline -3` shows HEAD has moved past
  `1c69410`, re-verify each card's file:line against current code before editing.
  Line numbers are hints; the problem statements are the contract.
- You have no other context from the review session. Everything you need is in this
  file plus `.claude/Sienna.md` and `.claude/claude.md` — **read both before any edit**.
- Work on branch `claude/youthful-bell-xxgcvp`. Never force-push. Never commit to main.
- Findings marked **[verified]** were reproduced at review time with the exact
  command shown in Evidence; re-run it before and after your fix.

## 1. Global guardrails (non-negotiable)

All rules in `.claude/Sienna.md` apply. The ones this work most often trips:

- **No `isa`/`<:` branching in function logic** — use multiple dispatch.
  *Sanctioned exception:* bodies of `serialize`/`deserialize` methods (cold path,
  heterogeneous JSON input). Do not "fix" existing `isa` there.
- Concrete struct fields; `const` globals; actionable errors over silent failures;
  `@assert_op` over `@assert`; exports only in `src/InfrastructureSystems.jl`;
  `TYPEDSIGNATURES` docstrings on public API.
- **Never edit `src/generated/*`.** Change `src/descriptors/structs.json` and run
  `julia bin/generate_structs.jl src/descriptors/structs.json src/generated/`.
- Always `julia --project=<env>`, never bare `julia`.
- **Downstream impact:** PowerSystems.jl, PowerSimulations.jl, PowerSystemCaseBuilder
  consume this package. Cards tagged **[DOWNSTREAM]** change public behavior:
  implement only the IS side and append the required downstream follow-up to
  Section 6.

Commands:

```sh
# one-time env setup — REQUIRED, otherwise tests run against the REGISTRY copy of IS:
julia --project=test -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'

# full suite (ReTest + Aqua; ~4-5 min warm):
julia --project=test test/runtests.jl

# formatter — run before every commit (it may update its own scripts/formatter env; expected):
julia -e 'include("scripts/formatter/formatter_code.jl")'
```

If the package registry is unreachable (HTTP 403), prefix commands with
`JULIA_PKG_SERVER=` to fall back to git-based resolution.

Test philosophy (Sienna.md): test custom logic, not tautologies. Every fix lands with
the narrowest regression test that would have caught it. One commit per batch minimum:
fix → formatter → affected tests → commit; full suite at the end of Batches B and D.

## 2. State of the branch (verified 2026-06-10 at 1c69410)

- **Full test suite: 8,518 pass, 0 fail** (~270 s). Aqua all green: no method
  ambiguities, no unbound type params, no undefined exports, no piracy, no stale
  deps, compat bounds OK.
- **Security review: no new vulnerabilities.** Deserialization type reconstruction
  is unchanged in attack power vs main; new string mappings are closed-set with
  error-on-unknown; SQL remains parameterized.
- `grep JSON3|StructTypes|DataFramesMeta src/` → zero hits (migration complete in
  src). Zero dangling references to deleted Optimization types.
- Serialization round-trips **[verified]**: CostCurve/FuelCurve preserve all three
  unit systems (NU/SU/DU); legacy enum strings ("SYSTEM_BASE" etc.) decode correctly.

Units-layer architecture (so you don't re-derive it):

```
RelativeUnits submodule (src/relative_units.jl)
  AbstractUnitSystem ⊃ {AbstractRelativeUnit ⊃ {DeviceBaseUnit, SystemBaseUnit}, NaturalUnit}
  const singletons DU, SU, NU; RelativeQuantity{T<:Number, U<:AbstractRelativeUnit} <: Number
  convert_cost_coefficient + 9-method _cost_coeff_ratio dispatch table
  traits: _strip_units (extensible by domain pkgs), display_units_arg
CostCurve{T,U} / FuelCurve{T,U} (src/production_variable_cost_curve.jl)
  U <: AbstractUnitSystem replaces the old power_units::UnitSystem runtime field;
  serialized under "power_units" key; legacy enum accepted via _unit_system_instance
Codegen (src/utils/generate_structs.jl): needs_conversion fields emit
  get_X(value, units) (strips units) + get_X_unitful(value, units) + display_units_arg
  methods; the get_value/set_value generics are implemented by domain packages
Time series accessors (src/time_series_interface.jl): 9 sites take `units = SU`,
  threaded to _make_time_array which calls multiplier(owner, units)
IS itself performs no domain conversions: SU/DU/NU only acquire meaning in
PowerSystems.jl. Only the plumbing and convert_cost_coefficient math are testable here.
```

## 3. Task cards — execute in batch order

Card format: Problem → Evidence → Recommended change → Acceptance → Risk notes.

### Batch A — relative_units.jl core (pure, no downstream coordination)

---

**IS4-RU-001 / P2 — `(x * DU) * SU` silently builds a nested RelativeQuantity**

- **File:** `src/relative_units.jl:75-76`
- **Problem:** `Base.:*(a::Number, b::AbstractRelativeUnit)` constructs
  `RelativeQuantity(a, b)` with `T <: Number` unconstrained, and
  `RelativeQuantity <: Number`, so re-tagging an already-tagged value nests
  silently instead of erroring. Downstream code that accidentally multiplies a
  tagged value by a unit marker gets a corrupt-but-functional wrapper that
  `_strip_units` only partially unwraps (one layer).
- **Evidence [verified]:** `typeof((0.6 * IS.DU) * IS.DU)` →
  `RelativeQuantity{RelativeQuantity{Float64, DeviceBaseUnit}, DeviceBaseUnit}`.
- **Recommended change:** make double-tagging impossible: either add erroring
  methods `Base.:*(::RelativeQuantity, ::AbstractRelativeUnit)` (and the reverse
  order) with an actionable message, or constrain the inner constructor to reject
  `T <: RelativeQuantity`. Prefer the erroring methods (dispatch, no runtime check).
- **Acceptance:** `(0.6DU) * SU` and `SU * (0.6DU)` throw an `ArgumentError`
  naming both units; new regression test in `test/test_relative_units.jl`.
- **Risk notes:** none — currently produced values are meaningless.

---

**IS4-RU-002 / P2 — Cross-unit operations die with a cryptic promotion error; `_cost_coeff_ratio` has no catch-all**

- **File:** `src/relative_units.jl:79-106` and `:169-177`
- **Problem:** `0.6DU == 0.6SU`, `0.6DU + 0.6SU`, and `RelativeQuantity == Float64`
  all fall into Base's promotion machinery and throw a generic
  `ErrorException("promotion of types ... failed")` — violating the Sienna
  "fail fast with actionable errors" principle for the most likely user mistakes.
  Separately, `_cost_coeff_ratio` covers exactly the 3×3 unit matrix with no
  fallback method: a future `AbstractUnitSystem` subtype (or downstream extension)
  would hit a bare `MethodError`.
- **Evidence [verified]:** `0.6*IS.DU == 0.6*IS.SU` →
  `ErrorException: promotion of types RelativeQuantity{Float64,...} ...`.
- **Recommended change:** (a) add explicit erroring methods for cross-unit
  `+`, `-`, `==`, `<`, `<=`, `isless`, `isapprox` (one `@eval` loop is fine) with a
  message like "cannot compare/combine quantities in different unit bases (DU vs
  SU); convert explicitly first"; (b) add
  `_cost_coeff_ratio(from::AbstractUnitSystem, to::AbstractUnitSystem, _, _) =
  throw(ArgumentError("unsupported unit-system conversion: $from → $to"))`.
- **Acceptance:** cross-unit ops throw `ArgumentError` mentioning both units;
  `convert_cost_coefficient` with a hypothetical new subtype throws the actionable
  error; existing same-unit behavior unchanged.
- **Risk notes:** `test/test_relative_units.jl:21-26` pins the current
  `ErrorException` — update those assertions to the new error type/message.

---

**IS4-RU-003 / P2 — Custom `==` without a matching `hash`: Dict/Set keys break**

- **File:** `src/relative_units.jl:94-95` (no `Base.hash` method in file)
- **Problem:** `==` compares `.value` across different numeric types `T`
  (`RelativeQuantity(1.0, DU) == RelativeQuantity(1, DU)` is `true`), but `hash`
  falls back to the default structural hash, which differs for `Float64` vs `Int`
  payloads. Equal keys with unequal hashes corrupt `Dict`/`Set`/`unique` semantics.
- **Evidence [verified]:** `q1 == q2` → `true`; `hash(q1) == hash(q2)` → `false`
  (for the values above).
- **Recommended change:** define
  `Base.hash(q::RelativeQuantity{T, U}, h::UInt) where {T, U} = hash(q.value, hash(U, h))`
  (hash the unit *type*, not instance, so it's consistent across `T`).
- **Acceptance:** equal RelativeQuantities hash equal across payload types; new
  regression test (`Dict` round-trip with Float64/Int keys).
- **Risk notes:** none.

### Batch B — cost curves & serialization robustness

---

**IS4-PVC-001 / P1 — `get_time_series_key` MethodError for FuelCurve with static value_curve + time-series fuel_cost**

- **File:** `src/production_variable_cost_curve.jl:56-59`
- **Problem:** `is_time_series_backed(fc)` returns `true` when only `fuel_cost`
  is a `TimeSeriesKey` (lines 259-261), but `get_time_series_key` only has a
  method for curves whose *value_curve* is time-series-backed. The natural
  downstream pattern `is_time_series_backed(c) && get_time_series_key(c)` hits a
  bare `MethodError` for the static-curve + TS-fuel-cost combination the branch
  itself introduced.
- **Evidence:** method signature at :57 requires
  `ProductionVariableCostCurve{<:ValueCurve{<:TimeSeriesFunctionData}}`; no other
  method exists (verified by dispatch analysis; combination constructible via
  `FuelCurve(LinearCurve(5.0), NaturalUnit(), <TimeSeriesKey>)`).
- **Recommended change:** add a `get_time_series_key(cost::FuelCurve)` method
  (or appropriately constrained methods) that returns the value-curve key when the
  value curve is TS-backed, the `fuel_cost` key when only the fuel cost is
  TS-backed, and throws an actionable `ArgumentError` telling the caller to use
  `get_time_series_key(get_value_curve(c))` / `get_fuel_cost(c)` when **both** are
  TS-backed (ambiguous). Use dispatch, not `isa` chains, where practical.
- **Acceptance:** for every combination where `is_time_series_backed(c) == true`,
  `get_time_series_key(c)` either returns a key or throws the documented
  `ArgumentError` — never a `MethodError`. Extend the 2×2 grid test at
  `test/test_cost_functions.jl:363-391` to call `get_time_series_key` on all four.
- **Risk notes:** [DOWNSTREAM] PSI consumes this accessor — document the
  both-backed precedence in the docstring.

---

**IS4-FD-001 / P2 — `is_valid_data` MethodError for time-series-backed curves**

- **File:** `src/function_data/convexity_checks.jl:168-176`
- **Problem:** `is_valid_data(curve::InputOutputCurve)` etc. delegate to the
  underlying `FunctionData`, but no method exists for `TimeSeriesFunctionData`,
  so validating a `TimeSeriesInputOutputCurve` (or a CostCurve wrapping one) is a
  bare `MethodError` instead of the deliberate `ArgumentError` pattern used by
  `is_convex`/`is_concave` for the same situation
  (`src/production_variable_cost_curve.jl:39-55`).
- **Recommended change:** mirror the existing pattern: add
  `is_valid_data(::TimeSeriesFunctionData; kwargs...)` (and/or the ValueCurve-level
  method) throwing `ArgumentError("validity is not defined for time-series-backed
  data; validate the resolved static curve per timestep instead")` — or return
  `true` if the team prefers permissive validation; pick ONE and document it.
- **Acceptance:** `is_valid_data` on every TimeSeries* curve/alias throws the
  documented `ArgumentError` (or returns the documented value); regression test
  added next to the existing `is_valid_data` tests.
- **Risk notes:** check whether PowerSystems calls `is_valid_data` during
  `add_component!` validation of cost curves — if so this is effectively P1.

---

**IS4-PVC-002 / P2 — `zero(::CostCurve)` / `zero(::FuelCurve)` silently drop the unit-system parameter**

- **File:** `src/production_variable_cost_curve.jl:128` and `:240`
- **Problem:** `Base.zero(::Union{CostCurve, Type{CostCurve}})` always returns a
  `NaturalUnit` curve, so `zero(c)` for a `CostCurve{T, SystemBaseUnit}` changes
  the unit system — surprising for any generic code using `zero(x)` as the
  additive identity of `typeof(x)`.
- **Evidence [verified]:** `IS.get_power_units(zero(IS.CostCurve(IS.LinearCurve(5.0),
  IS.SystemBaseUnit())))` → `NU`.
- **Recommended change:** split methods: keep
  `zero(::Type{CostCurve}) = CostCurve(zero(ValueCurve))` (NU default), add
  `zero(c::CostCurve{T, U}) where {T, U} = CostCurve(zero(ValueCurve), U())`
  (same for FuelCurve, preserving fuel_cost-shaped zero).
- **Acceptance:** `get_power_units(zero(c)) == get_power_units(c)` for all three
  unit systems, both curve types; regression test in test_cost_functions.jl.
- **Risk notes:** check `zero(CostCurve)` *type* form call sites (tests pin it) —
  type-form behavior is unchanged.

---

**IS4-PVC-003 / P2 — FuelCurve deserialize: garbage `fuel_cost` throws a context-free MethodError**

- **File:** `src/production_variable_cost_curve.jl:319-324`
- **Problem:** the `else` branch does `Float64(fuel_cost_raw)`; for a malformed
  file where `fuel_cost` is a String/array, this throws
  `MethodError(Float64, ...)` with no mention of the field, type, or file —
  against the fail-fast-with-context principle for a user-facing deserialization
  entry point.
- **Recommended change:** wrap: if `fuel_cost_raw` is not a `Real` (and not a
  Dict), throw `ArgumentError("FuelCurve fuel_cost must be a number or serialized
  TimeSeriesKey, got $(typeof(fuel_cost_raw))")`. The `isa` here is inside a
  `deserialize` body — sanctioned.
- **Acceptance:** deserializing a FuelCurve dict with `"fuel_cost" => "oops"`
  throws the actionable ArgumentError; round-trip tests still pass.
- **Risk notes:** none.

---

**IS4-TST-003 / P3 — Pin verified serialization behavior with regression tests**

- **Files:** `test/test_cost_functions.jl`, `test/test_relative_units.jl`
- **Problem:** behaviors verified manually during review have no test coverage:
  (a) CostCurve/FuelCurve serialize→deserialize round-trip for **SU and DU** (only
  NU-ish paths covered); (b) legacy enum-string decode
  (`_unit_system_instance("SYSTEM_BASE"|"DEVICE_BASE"|"NATURAL_UNITS")`);
  (c) the legacy *enum value* constructor shim
  (`CostCurve(vc, UnitSystem.SYSTEM_BASE)`).
- **Recommended change:** add a 3-unit-system × 2-curve-type round-trip testset and
  a legacy-decode testset. Cheap, locks in PSB compatibility.
- **Acceptance:** new testsets pass; deleting `_unit_system_instance(::String)`'s
  legacy arm makes them fail.

### Batch C — time series interface / multiplier contract

---

**IS4-TSI-001 / P1 — 2-arg `multiplier(owner, units)` breaks every legacy 1-arg scaling-factor multiplier with a bare MethodError [DECISION D1 REQUIRED]**

- **File:** `src/time_series_interface.jl:999` (`return ta .* multiplier(owner, units)`)
- **Problem:** any function stored as `scaling_factor_multiplier` that accepts
  only `(owner)` — i.e., every multiplier written against IS ≤3.x, including ones
  inside existing serialized systems — now fails at retrieval time with a raw
  `MethodError` carrying no migration guidance. IS's own test helpers had to be
  patched (`src/utils/test.jl:53-58`), which proves the break was known; downstream
  users get no equivalent help.
- **Evidence [verified]:**
  `IS.get_time_series_values(IS.SingleTimeSeries, c, "y")` with a 1-arg multiplier →
  `MethodError: no method matching legacy_mult(::TestComponent, ::SystemBaseUnit)`.
- **Decision D1 — pick ONE (default = i):**
  - (i) **Accept the break, make the error actionable** *(default)*: wrap the call
    site — catch `MethodError` for the multiplier specifically and rethrow
    `ArgumentError("scaling_factor_multiplier functions must accept (owner, units)
    as of IS 4.0; update $(nameof(multiplier)) — see the IS4 migration notes")`.
    try/catch is acceptable here: once per retrieval, and the call is already
    dynamic (`scaling_factor_multiplier::Union{Nothing, Function}` predates the
    branch). Add a changelog/migration entry.
  - (ii) `hasmethod`-based fallback to 1-arg — REJECTED by default: runtime
    introspection in the retrieval path contradicts Sienna conventions.
  - (iii) Status quo + changelog only — viable if the team decides all multiplier
    call sites are regenerated in lockstep (PSY6), but third-party multipliers
    still get the bare MethodError.
- **Acceptance (for i):** the 1-arg repro above produces the actionable
  ArgumentError; 2-arg multipliers unaffected (no overhead on success path);
  regression test with a 1-arg multiplier asserting the error message.
- **Risk notes:** [DOWNSTREAM] coordinate the migration note with PSY6 release
  notes; the units argument is only forwarded, IS does no conversion itself.

---

**IS4-TSI-002 / P2 — `units` kwarg is un-annotated, un-documented, and accepts garbage silently**

- **Files:** `src/time_series_interface.jl:308, 371, 439, 494, 789, 840, 905, 963, 983`
- **Problem:** all 9 accessor sites declare `units = SU` with no type annotation
  and no docstring mention. Invalid values flow down to `multiplier(owner, units)`
  — with multipliers that ignore the argument, `units = 42` silently "works";
  with real ones it MethodErrors deep in the stack.
- **Evidence [verified]:** `get_time_series_values(...; units = 42)` returned
  normally (multiplier ignored the argument).
- **Recommended change:** annotate every site `units::AbstractUnitSystem = SU`
  (domain packages passing Unitful units would need the annotation relaxed — they
  don't today: confirm with a downstream grep before tightening, else use a
  documented union or leave untyped but validate). Add an `# Arguments` entry to
  each docstring: "`units`: unit-system marker forwarded to the
  scaling-factor multiplier (default `SU`); IS performs no conversion itself."
- **Acceptance:** `units = 42` throws a MethodError/TypeError *at the accessor
  boundary*, not downstream; docstrings document the kwarg; suite green.
- **Risk notes:** [DOWNSTREAM] PSY plans to pass natural-unit markers (template
  docstrings mention `MW`); if those are Unitful objects rather than
  `AbstractUnitSystem` subtypes, the annotation must be
  `Union{AbstractUnitSystem, <domain type>}` on the PSY side instead — verify
  before annotating; if unverifiable, do the docstrings now and log the
  annotation as a Section 6 follow-up.

### Batch D — hygiene, codegen, exports, tests, release

---

**IS4-REL-001 / P1 — Project.toml still says `version = "3.6.0"` — the already-released version — on a breaking branch**

- **File:** `Project.toml:4`
- **Problem:** the branch removes public API (Optimization results machinery),
  changes the CostCurve/FuelCurve type surface, and changes the multiplier calling
  convention, yet carries the version of the latest *released* IS. Anyone dev-ing
  the branch gets confusing resolution behavior, and an accidental tag/release
  would be catastrophic for downstream compat bounds.
- **Recommended change:** bump to `4.0.0-DEV` now (or the team's preferred
  pre-release scheme, e.g. `4.0.0-alpha`); release as `4.0.0`.
- **Acceptance:** `Pkg.status` in the test env shows the pre-release version;
  Aqua "Compat bounds" stays green.
- **Risk notes:** coordinate with the PSY6/IOM compat entries that will reference
  `InfrastructureSystems = "4"`.

---

**IS4-TST-001 / P2 — `get_value(::TestSupplemental)` reads a field that does not exist**

- **File:** `src/utils/test.jl:90`
- **Problem:** `get_value(attr::TestSupplemental) = attr.attr_json` —
  `TestSupplemental` has fields `value` and `internal` only (lines 77-80). First
  call throws. Latent because nothing exercises it — which also means it's dead
  *and* broken. It additionally hangs an unrelated 1-arg method on the newly
  exported 4-arg units-interface generic `get_value`.
- **Recommended change:** fix to `attr.value`; add the one-line test that calls
  it; consider renaming the helper (e.g. `get_attr_value`) so the test fixture
  doesn't overload the units-interface generic with unrelated semantics — align
  with the D2 decision.
- **Acceptance:** calling it on a `TestSupplemental` returns the `value` field;
  test added.

---

**IS4-EXP-001 / P2 — `export get_value, set_value` contradicts the file's own no-export policy [DECISION D2 REQUIRED]**

- **File:** `src/InfrastructureSystems.jl:11-17` vs `:48-49`
- **Problem:** lines 48-49 still say "IS should not export any function since it
  can have name clashes with other packages. Do not add export statements." —
  yet line 17 exports the two most clash-prone names imaginable. Any package doing
  `using InfrastructureSystems` alongside another package exporting `get_value`
  (DataFrames ecosystem, etc.) gets name-resolution conflicts.
- **Decision D2 — pick ONE (default = a):**
  - (a) *(default)* Keep the export (PSY codegen relies on extending
    `IS.get_value`), rewrite the stale comment to state the actual policy and its
    single sanctioned exception, and add a docstring note that domain packages
    must extend, not own, these generics.
  - (b) Un-export (downstream uses qualified `IS.get_value` anyway via the
    template, which emits qualified calls — verify with PSY before choosing).
  - (c) Rename to `get_unit_value`/`set_unit_value` — clearest, but
    [DOWNSTREAM]-coordinated.
- **Acceptance:** comment and exports no longer contradict; decision recorded in
  the commit message; Aqua "Undefined exports" green.

---

**IS4-GEN-001 / P2 — needs_conversion codegen: `_unitful` export gap, zero IS-side coverage, undocumented setter asymmetry**

- **File:** `src/utils/generate_structs.jl:199-208` (export logic), template
  lines 66-89; `test/test_generate_structs.jl`
- **Problem:** three related defects in the units codegen path:
  1. The comment at :200-202 says excluded getters are "hand-written elsewhere —
     always export the public name", but line 205 gates the `_unitful` companion
     export on `include_getter`: with `exclude_getter=true && needs_conversion=true`
     the base name is exported and the hand-written `get_X_unitful` is silently
     not.
  2. No descriptor in `src/descriptors/structs.json` uses `needs_conversion`, so
     the entire generated-units-getter branch (template lines 66-73) is never
     compiled or tested inside IS — PSY6 is the first consumer to ever expand it.
  3. The generated setter (line 83) takes no `units` argument while the getter
     does; the contract (the value carries its own unit tag into `set_value`) is
     nowhere documented.
- **Recommended change:** (1) move the `_unitful` push out of the
  `include_getter` condition (gate on `needs_conversion` only); (2) add a test
  descriptor with `needs_conversion: true` to `test_generate_structs.jl`, with a
  mock `get_value`/`set_value` method pair, asserting the generated text contains
  both getters + `display_units_arg` methods and that the generated code parses;
  (3) document the setter contract in the template docstring or `.claude/claude.md`.
- **Acceptance:** generation test covers the needs_conversion branch; export list
  contains `get_X_unitful` when `exclude_getter` is set; suite green.
- **Risk notes:** regenerate nothing in `src/generated/` for this card — IS's own
  descriptors don't use the flag.

---

**IS4-PERF-001 / P2 — `build_static_curve` performs up to 3 storage reads per timestep [DOWNSTREAM]**

- **File:** `src/time_series_value_curve.jl:215-227` (+ `_resolve_scalar_key` :181)
- **Problem:** resolving a `TimeSeriesIncrementalCurve` with TS-backed
  `initial_input` and `input_at_zero` issues three separate
  `get_time_series_values(...; len = 1)` calls (function data + 2 scalar keys).
  Downstream (PSI) is expected to call this per component per timestep in
  simulation loops; against HDF5-backed storage that is 3 I/O round-trips per
  resolution. (The `Union{Nothing, TimeSeriesKey}` field boxing flagged in review
  is immaterial next to the I/O — do not "fix" the field types.)
- **Recommended change:** IS-side, this is a documentation + API-shape card, not
  an optimization: document in the build_static_curve docstring that per-timestep
  resolution issues one read per TS-backed field and that hot-loop consumers
  should resolve through a `TimeSeriesCache` or batch reads; log a Section 6
  follow-up for PSI to confirm its access pattern before IS adds a batched
  resolve API. Do NOT speculatively redesign now.
- **Acceptance:** docstring updated; Section 6 entry added.

---

**IS4-OUT-001 / P3 — Stub error says `write_output`, function is `write_outputs`**

- **File:** `src/outputs.jl:29-30`
- **Problem:** the not-implemented stub's message names a method that doesn't
  exist, sending implementers grepping for the wrong symbol.
- **Recommended change:** fix the string; while there, generate the ~7 identical
  stubs with a tiny loop/macro so name and message cannot drift (optional — only
  if it stays readable).
- **Acceptance:** message matches `nameof`; grep finds no other mismatch in the file.

---

**IS4-HYG-001 / P3 — DataFramesMeta is a dead test dependency**

- **Files:** `test/InfrastructureSystemsTests.jl:13`, `test/Project.toml:5`
- **Problem:** imported and declared but unused since the JSON3/DataFramesMeta
  purge (zero `@combine/@subset/@transform/@chain` hits in test/).
- **Recommended change:** delete the import and the dep entry.
- **Acceptance:** suite green; Aqua "Stale dependencies" green.

---

**IS4-SIMP-001 / P3 — Repeated `fuel_cost isa Real ? Float64(fuel_cost) : fuel_cost` ternary (×4)**

- **File:** `src/production_variable_cost_curve.jl:~195, ~206, ~217, ~230`
- **Recommended change:** one private helper
  (`_normalize_fuel_cost(x::Real) = Float64(x); _normalize_fuel_cost(x::TimeSeriesKey) = x`)
  — dispatch instead of the ternary, used by all four constructors. Cold path;
  do not over-engineer.
- **Acceptance:** constructors behave identically (existing tests pass).

---

**IS4-SIMP-002 / P3 — Five copy-paste TimeSeries* alias blocks in cost_aliases.jl**

- **File:** `src/cost_aliases.jl` (TS alias sections, ~:241-380)
- **Problem:** each TS alias repeats constructor + `is_cost_alias` +
  `simple_type_name` + `show` with only names changing; a sixth alias invites a
  missed registration (the names themselves are currently all correct — verified).
- **Recommended change:** fold into an `@eval for (alias, fd) in (...)` loop or a
  small macro, matching however the static aliases are organized. Only do this if
  the result is *more* readable; otherwise note-and-skip.
- **Acceptance:** identical methods exist after refactor (run
  `methods(IS.simple_type_name)` count before/after); show-output tests pass.

---

**IS4-SIMP-003 / P3 — `build_static_curve` ×3 duplicate the fetch-and-extract pattern**

- **File:** `src/time_series_value_curve.jl:202, 221, 244`
- **Recommended change:** extract the shared "fetch fd_key values at
  (start_time, len=1) and extract `[1]::T`" helper used by all three methods
  (the `_resolve_scalar_key` helper already exists for scalar fields — mirror it).
- **Acceptance:** all three TS curve types still resolve correctly
  (test_time_series_function_data.jl green).

---

**IS4-DOC-001 / P3 — Units docstring contract mismatches**

- **Files:** `src/relative_units.jl:180-191`, `src/utils/generate_structs.jl:67,69`
- **Problem:** `display_units_arg`'s docstring declares the return contract
  `Union{AbstractRelativeUnit, Missing}`, while the generated getter docstrings
  advertise units arguments "e.g. `SU`, `DU`, `MW`" — `MW` is a domain (Unitful)
  unit, not an `AbstractRelativeUnit`. Also `_strip_units`' fallback silently
  passes through any unknown wrapper type (by design — domain packages extend it);
  the generated `get_X` docstring promises "a bare number", which is only true if
  the domain package registered its method.
- **Recommended change:** reconcile: widen `display_units_arg`'s documented return
  to "a units argument accepted by the getter (e.g. `SU`) or `missing`"; add one
  sentence to `_strip_units`'s docstring stating the fallback contract and that
  domain packages MUST extend it for their quantity types.
- **Acceptance:** docs build clean; statements match behavior.

## 4. Decisions needed (do NOT implement without choosing; defaults stated)

- **D1** (IS4-TSI-001): multiplier 2-arg contract → default **(i)** actionable
  rethrow + migration note.
- **D2** (IS4-EXP-001): `get_value`/`set_value` export → default **(a)** keep
  export, fix the stale comment, document extension contract.
- **D3** (deferred): `display_units_arg` hardcoded to `SU` in the codegen template
  (`generate_structs.jl:71-72`) — per-field configurability requires a descriptor
  schema change that regenerates downstream PSY files. **Default: defer; file a
  tracking issue; do not change the schema in this pass.** [DOWNSTREAM]

## 5. Explicit do-NOT list

- Do NOT remove the legacy `UnitSystem` enum path
  (`_unit_system_instance(::UnitSystem)`, constructors at
  `production_variable_cost_curve.jl:292-295`) — PowerSystemCaseBuilder still
  passes enum values; the TODO at :282 is explicitly deferred.
- Do NOT add dependencies (no Unitful, no JET) or touch `Project.toml [deps]`.
- Do NOT "fix" `isa` usage inside `serialize`/`deserialize` bodies (sanctioned).
- Do NOT change `Union{Nothing, TimeSeriesKey}` field types chasing boxing
  (IS4-PERF-001 explains why).
- Do NOT edit `src/generated/*` directly, ever.
- Do NOT reformat files your edits don't touch.
- Do NOT remove or weaken the `units = SU` kwarg API (shape is settled; only
  annotate/document per IS4-TSI-002).

## 6. Downstream follow-ups ledger (append as you work)

- [ ] PSY6: migration note for the 2-arg `scaling_factor_multiplier` contract
      (pairs with D1).
- [ ] PSI: confirm `build_static_curve` per-timestep access pattern; decide on a
      batched/cached resolve API in IS (IS4-PERF-001).
- [ ] PSY6: confirm what object types will be passed as `units` to accessors
      before tightening the kwarg annotation (IS4-TSI-002).
- [ ] End-to-end units semantics (SU/DU/NU conversions) are only testable in PSY —
      this review verified IS-side plumbing and `convert_cost_coefficient` math only.
- [ ] Tracking issue for D3 (descriptor-driven `display_units_arg`).
- [ ] Pre-existing (NOT this branch, separate issue): `src/value_curve.jl:201`
      `AverageRateCurve(::InputOutputCurve{PiecewiseLinearData})` divides `p.y/p.x`
      with no x≠0 guard → silent `Inf` for curves with a point at x=0
      (`_validate_piecewise_x` checks ascending only).

## 7. Final cleanup checklist

- [ ] Every card above is done, or moved to Section 6 with a reason.
- [ ] Formatter run; `git status` clean except intended changes
      (`infrastructure-systems.log` from test runs is gitignored — never `git add -A`).
- [ ] Full suite green: `julia --project=test test/runtests.jl` (8,518+ tests).
- [ ] Version bump (IS4-REL-001) confirmed with maintainer.
- [ ] Delete this file (`.claude/IS4_REVIEW.md`).
- [ ] Commit and push to `claude/youthful-bell-xxgcvp`.
