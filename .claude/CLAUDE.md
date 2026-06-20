# InfrastructureSystems.jl — Claude Guide

Platform-wide Sienna conventions (performance, type stability, formatter, environments, code style) live in `.claude/Sienna.md` — read it too. This file is repo-specific and does not restate them.

## Purpose & foundational role

IS is the **foundational utility library of the Sienna stack** — almost every other Sienna package depends on it and imports its core machinery rather than reimplementing it. It provides the shared, performance-critical building blocks for infrastructure data models: component containers, the time-series subsystem, serialization, system-data management, the `@assert_op` macro, struct auto-generation, logging/recorder utilities, and the abstract optimization-container types. It is *domain-agnostic* (no power-systems concepts live here — those are in PowerSystems.jl).

Consumed by: PowerSystems.jl, PowerSimulations.jl, PowerSimulationsDynamics.jl, PowerNetworkMatrices.jl, PowerFlows.jl, PowerSystemCaseBuilder.jl, and the IOM/POM packages. **Changes here ripple platform-wide** — assume any signature/behavior change can break downstream packages, and weigh that before changing public surface.

- `version` is `3.6.0`. **Do not bump it** during dev work (even breaking-change work). A local version ahead of the registry breaks cross-package `Pkg.develop`/test resolution for the whole stack; release versions are set at publish time. If a bump reappears in the working tree, revert it. Same rule applies to other Sienna packages worked on alongside IS.
- Julia compat: `julia = "^1.10"` (Project.toml). The README's "1.6 or higher" line is stale prose — trust Project.toml.
- Default branch is **`main`**, not `master`. The harness may report `master` at session start — that is wrong here; `git ls-remote origin` shows only `main`. Use `main` for all PRs/diffs/base refs.

## Architecture & `src/` layout

Top-level `src/` files (flat, included from `src/InfrastructureSystems.jl` — respect include order when adding types/constants):

- `InfrastructureSystems.jl` — main module, includes, and the (small) export list.
- **Component model:** `component.jl`, `components.jl`, `component_container.jl`, `component_uuids.jl`, `containers.jl`, `internal.jl` — abstract types `InfrastructureSystemsComponent`, `InfrastructureSystemsType`, `InfrastructureSystemsContainer` and the storage backing `SystemData`.
- **System data:** `system_data.jl` — `SystemData`, the central container tying components, time series, supplemental attributes, and subsystems together. Also `subsystems.jl`, `supplemental_attribute_*.jl`, `geographic_supplemental_attribute.jl`, `validation.jl`.
- **Time series:** the largest subsystem. `abstract_time_series.jl`, `static_time_series.jl`, `forecasts.jl`, `deterministic*.jl`, `probabilistic.jl`, `scenarios.jl`, `single_time_series.jl`, `time_series_interface.jl` (public API), `time_series_manager.jl`, `time_series_metadata_store.jl` (SQLite-backed), `time_series_storage.jl` + `hdf5_time_series_storage.jl` / `in_memory_time_series_storage.jl`, `time_series_cache.jl`, `time_series_parser.jl`, `time_series_formats.jl`, `time_series_parameters.jl`, `time_series_structs.jl`, `time_series_utils.jl`.
- **Component selection:** `component_selector.jl` — `ComponentSelector` (lazy, named, partitioned subsets of components; `make_selector`, `get_groups`, `rebuild_selector`).
- **Cost / function curves:** `value_curve.jl`, `production_variable_cost_curve.jl`, `cost_aliases.jl`, and `function_data/` (`function_data.jl`, `convexity_checks.jl`, `make_convex.jl`) — `FunctionData`, `ValueCurve`, `ProductionVariableCostCurve` (`CostCurve`/`FuelCurve`), and curve aliases.
- `serialization.jl` — JSON3/StructTypes serialization infrastructure used stack-wide.
- `units.jl` — only time-period conversion helpers here; there is **no** `UnitSystem` enum in IS (that lives in PowerSystems).
- `common.jl`, `definitions.jl`, `iterators.jl`, `random_seed.jl`, `results.jl`, `deprecated.jl`.

Subdirectories:

- `generated/` — **auto-generated struct files. DO NOT EDIT.** Currently the time-series metadata structs (`DeterministicMetadata`, `ProbabilisticMetadata`, `ScenariosMetadata`, `SingleTimeSeriesMetadata`) plus `includes.jl`.
- `descriptors/structs.json` — JSON descriptor that drives struct generation.
- `utils/` — `assert_op.jl` (the `@assert_op` macro), `generate_structs.jl` / `generate_struct_files.jl` (Mustache-based generator), `logging.jl`, `recorder_events.jl`, `timers.jl`, `print*.jl` (PrettyTables display), `sqlite.jl`, `flatten_iterator_wrapper.jl`, `lazy_dict_from_iterator.jl`, `stdout_redirector.jl`, `test.jl`.
- `Optimization/` — submodule `InfrastructureSystems.Optimization` (`module Optimization`). Abstract optimization-container plumbing shared by PowerSimulations and the IOM/POM stack: `optimization_container_keys.jl`, `optimization_container_types.jl`, `optimization_container_metadata.jl`, `abstract_model_store*.jl`, `model_internal.jl`, `optimization_problem_results*.jl`, `optimizer_stats.jl`, `enums.jl`. It defines the *abstractions*; concrete solver logic lives downstream.
- `Simulation/` — submodule `InfrastructureSystems.Simulation` (enums + simulation utilities).

## Public API & exports

**IS is deliberately selective about exports.** The main module exports almost nothing — only the cost-curve aliases (`LinearCurve`, `QuadraticCurve`, `PiecewisePointCurve`, `PiecewiseIncrementalCurve`, `PiecewiseAverageCurve`). Everything else is reached via qualified access (`IS.SystemData`, `IS.@assert_op`, `IS.make_selector`, `IS.Optimization.…`). Downstream packages import the names they need explicitly and frequently re-export them. **Do not add new exports** to widen the surface without a clear reason — prefer keeping symbols qualified.

Public API for docstring purposes still means the full documented interface (not just exports). Document public elements with `DocStringExtensions.TYPEDSIGNATURES` (use `TYPEDFIELDS` sparingly). Public API docs: `docs/src/api/public.md` (`@autodocs`, `Public=true, Private=false`); internals in `docs/src/api/internals.md`. Fix Documenter `missing_docs` by registering the docstring, never by `warnonly`.

## Verified commands

- **Run tests:** `julia --project=test test/runtests.jl`
  - Test framework is **ReTest** (not the classic `Test`-only runner). `runtests.jl` calls `run_tests()` in `test/InfrastructureSystemsTests.jl`, which wraps `retest(args...; kwargs...)`. Pass ReTest filter args/regexes through to select testsets. The harness also installs a `MultiLogger` and asserts zero `Error`-level log events.
  - Suite includes Aqua checks (`test_unbound_args`, `test_undefined_exports`, `test_ambiguities`, `test_stale_deps`, `test_deps_compat`) — keep deps clean and exports defined.
  - Test deps live in `test/Project.toml`. Instantiate: `julia --project=test -e 'using Pkg; Pkg.instantiate()'`.
- **Build docs:** `julia --project=docs docs/make.jl`
- **Format (run after every change, before reporting done):** `julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'`. The script self-activates `scripts/formatter`, instantiates, and formats `src/`, `test/`, `docs/src/` (`.jl` + `.md`).
- **Generate structs:** `julia bin/generate_structs.jl src/descriptors/structs.json src/generated/` (workflow: edit `structs.json` → run generator → generated files get docstrings + constructors).

## Conventions, invariants & gotchas

- **Never edit `src/generated/`.** Edit `src/descriptors/structs.json` and regenerate. Auto-generated struct drift is a known failure mode — regenerate, don't hand-patch.
- **Avoid `kwargs...` in hot paths.** As a utility library called in downstream inner loops, IS prefers explicit keyword args (or none) for type stability; splatting kwargs through hot code is an anti-pattern here specifically.
- **Performance is non-negotiable** — this sits under everything. Apply Sienna.md's type-stability rules rigorously; verify hot paths with `@code_warntype`. No `isa`/`<:` runtime branching, no abstract field types or untyped containers, prefer views/in-place ops.
- **Fail fast** with actionable errors; prefer `@assert_op` (defined here in `utils/assert_op.jl`) over `@assert` for operator assertions. Avoid silent `nothing`-skip guards that mask malformed data.
- **Cache lookups:** use the lazy closure form `get!(dict, key) do … end`, never 3-arg `get!` with an expensive default (evaluated eagerly, defeats the cache).
- The time-series subsystem spans HDF5 storage, an SQLite metadata store, and in-memory storage with a cache layer — changes touching time-series alignment, storage backends, or metadata serialization are high-risk and exercised by serialization round-trip tests; prefer adding/extending those over data-holder tautology tests.
- Git: leave changes **unstaged** (user reviews via plain `git diff`); use `git add -N` for new files. Never `git commit` unless explicitly asked.
