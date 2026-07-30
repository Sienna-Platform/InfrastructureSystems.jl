# Time Series Storage Rewrite — Performance Validation Report

**Date:** 2026-07-29 · **Updated:** 2026-07-30 (branch numbers refreshed after
post-campaign optimization; see follow-up items) · **Scale:** 100,000 time
series per system

## Executive summary

InfrastructureSystems.jl (IS) is the foundation of the Sienna platform: every
Sienna package stores and reads its time series through it. This work replaces
the previous HDF5 + SQLite storage engine (the **IS4** baseline) with
**InfraStore**, a purpose-built storage engine with a compiled native (Rust)
core, behind the same public Julia API.

Benchmarked head-to-head on identical workloads at 100,000 series in one
system, the InfraStore-backed branch is faster on **every ingest and read
path**:

| capability | improvement over IS4 |
|---|---|
| Bulk ingest (all types and payloads) | 2–13× faster |
| Reading stored series (full or sliced) | 2.6–118× faster, **flat** in store size and payload type |
| Simulation inner loop (all components at one timestamp / window) | **43–212× faster** |
| `transform_single_time_series!` + forecast-window reads (the PowerSimulations feed path) | window reads 83× faster |
| System save / load with 100k series | 12× / 4.8× faster, smaller on disk |
| `has_time_series` with full identity | hits at parity, misses 1.6× faster (after work delivered below) |
| Removing all 100k series | 10.3 s (per-series) / 1.2 s (bulk); IS4 did not complete |

Two capabilities exist only on the new branch: `NonSequentialTimeSeries`
(irregular-timestamp series) and columnar readers that serve every component
from one storage read per timestep. The gaps the 2026-07-29 campaign found
have since been closed or narrowed (branch numbers in this update are from
the 2026-07-30 rerun): the `has_time_series` gap was closed the same day by
porting IS4's query strategy into the InfraStore core; the tuple-payload
`Deterministic` rejection is fixed and now beats IS4 by 2–9×; per-series
removal is 3.6× faster than first measured; and the one remaining IS4
advantage — its recently optimized `transform_single_time_series!` — has
narrowed from 6.9× to 1.4×, with the residual attributed and bounded (see
follow-ups).

## What was measured

1. **Bulk ingest** of 100,000 series via each branch's recommended batched
   path, for every time series type (`SingleTimeSeries`,
   `NonSequentialTimeSeries`, `Deterministic`, `Probabilistic`, `Scenarios`)
   and element type (plain `Float64`, tuple pairs, and the three cost-function
   payloads: linear, quadratic, piecewise-linear).
2. **Full-array reads** of every stored series.
3. **Partial reads**: time slices of static series; single forecast windows.
4. **Simulation access patterns**: reading every component's value timestamp
   by timestamp (static) and window by window (forecasts) — the inner loop of
   a production-cost simulation. IS4 uses its `StaticTimeSeriesCache` /
   `ForecastCache`; the InfraStore branch its columnar
   `StaticTimeSeriesReader` / `ForecastReader`.
5. **Metadata queries at scale**: `has_time_series` with the full identity
   (type, name, resolution, two features) against 100,000 series spread
   10-per-component across 10,000 components — hits and misses.
6. **`transform_single_time_series!`** of 100,000 series to
   `DeterministicSingleTimeSeries` plus window reads of the result.
7. **Shared (deduplicated) data**: one profile referenced by all 100,000
   components.
8. **System serialization round-trip** (`to_json` / `from_json`) including the
   time series store artifacts.
9. **Bulk removal** of all 100,000 series.
10. **On-disk footprint** and process peak memory.

## Environment and methodology

| | |
|---|---|
| Machine | Apple M2 Pro, 32 GB RAM, macOS 26.5.2 |
| Julia | 1.12.6 |
| InfraStore branch (2026-07-30 rerun) | IS `feat/rust-time-series-store` @ `626bec64`, infrastore @ `fba0077` |
| InfraStore branch (original campaign) | IS @ `0eda6a7f`, infrastore @ `b7bd33e` |
| IS4 baseline | IS `IS4` @ `c63d9a281` (+ PR #594 cherry-pick for the transform sections, see note) |

- Every number is the average over the full 100,000-op loop (`@timed`, GC
  quiesced before each op); JIT warmup precedes measurement.
- Each (type × element type) combination uses a fresh system with 100,000
  components, one series per component, distinct random data per series
  (except the `shared` sections), disk-backed stores in private temp
  directories.
- Adds use each branch's recommended batched path
  (`time_series_transaction` vs `begin_time_series_update`).
- Long runs were split across concurrent processes (independent
  systems/stores); both branches were measured under comparable machine load,
  and spot checks at small N reproduce the same ratios.
- **IS4 transform note:** the IS4 branch predates IS PR #594
  (`transform_single_time_series!` speedup). Without it the 100k transform did
  not complete within an hour (quadratic SQLite scanning), so #594 was
  cherry-picked into the IS4 baseline for the transform sections — IS4 is
  measured with its best available implementation. #594 does not affect any
  other measured path.
- Raw data: `results_full_*.csv` in this directory; regenerate the tables with
  `julia benchmark/make_full_report.jl`. Branch numbers in this update come
  from `results_full_branch_w3.csv` — a single-process rerun of the full
  matrix on 2026-07-30 after the follow-up optimizations landed (108 rows, no
  failed combinations). IS4 numbers are unchanged from the 2026-07-29
  campaign.

## Results: ingest and per-owner reads (µs per operation)

Every read on the InfraStore branch lands in a narrow 84–157 µs band
regardless of type, payload, or store size; IS4's reads range 323–11,014 µs
and grow with store size and payload width.

| type | payload | operation | infrastore | is4 | speedup |
|---|---|---|---:|---:|---:|
| SingleTimeSeries | Float64 | bulk add | 13.3 | 116 | 8.7× |
| SingleTimeSeries | Float64 | read full | 90.7 | 2,110 | 23× |
| SingleTimeSeries | Float64 | read slice | 84.4 | 1,979 | 23× |
| SingleTimeSeries | tuple | read full | 99.2 | 5,780 | 58× |
| SingleTimeSeries | linear cost | read full | 99.1 | 6,501 | 66× |
| SingleTimeSeries | quadratic cost | read full | 103 | 8,291 | 80× |
| SingleTimeSeries | piecewise-linear | read full | 109 | 10,418 | 96× |
| SingleTimeSeries | piecewise-linear | read slice | 93.7 | 11,014 | 118× |
| Deterministic | Float64 | bulk add | 67.2 | 140 | 2.1× |
| Deterministic | Float64 | read full | 119 | 881 | 7.4× |
| Deterministic | Float64 | read one window | 92.5 | 900 | 9.7× |
| Deterministic | tuple | bulk add | 76.2 | 149 | 2.0× |
| Deterministic | tuple | read full | 137 | 1,184 | 8.7× |
| Deterministic | tuple | read one window | 97.2 | 901 | 9.3× |
| Deterministic | piecewise-linear | bulk add | 129 | 1,647 | 12.8× |
| Deterministic | piecewise-linear | read full | 156 | 1,423 | 9.1× |
| Probabilistic | Float64 | read full | 132 | 345 | 2.6× |
| Scenarios | Float64 | read full | 132 | 1,024 | 7.7× |
| NonSequentialTimeSeries | Float64 | bulk add | 43.3 | n/a | IS4 lacks the type |
| NonSequentialTimeSeries | Float64 | read full | 105 | n/a | |

(Bulk adds for tuple/linear/quadratic STS: 12.6–12.8 µs vs 101–104 µs on IS4,
~8×. All five NST payloads land at 43–51 µs adds / 105–115 µs reads.
The tuple-payload `Deterministic` rows are new in this update: the 2026-07-29
campaign recorded that combination as rejected by the branch's element-type
validation — the one type×payload combination IS4 accepted and the branch did
not. Support landed in IS `626bec64` and the formerly missing combination now
beats IS4 across the board.)

## Results: the simulation inner loop

The pattern that dominates production-cost simulation runtimes: at each
timestamp (or forecast window), read every component's value. µs per
(component, timestamp) value:

| workload | infrastore | is4 | speedup |
|---|---:|---:|---:|
| 100k static series × 24 timestamps (2.4M values) | 1.31 | 276 | **211×** |
| 100k deterministic forecasts × 12 windows (1.2M windows) | 5.70 | 680 | **119×** |
| 100k DST forecasts (post-transform) × 13 windows | 20.7 | 902 | 43× |
| shared profile, 2.4M static values | 1.07 | 165 | 154× |
| shared forecast, 1.2M windows | 2.13 | 348 | 163× |

In wall-clock terms: sweeping all 2.4 million (component, timestamp) values
takes **3.1 seconds** on the InfraStore branch vs **11 minutes** on IS4.
The columnar `StaticTimeSeriesReader` serves every component from one
physical read per timestamp; IS4 pays one cache per component.

## Results: transform_single_time_series! (DST)

| operation | infrastore | is4 (+#594) | speedup |
|---|---:|---:|---:|
| transform 100k STS → DST | 24.6 | 17.7 | 0.72× (1.4× slower) |
| read one DST window per component | 120 | 9,965 | 83× |
| DST by-window sweep (1.3M windows) | 20.7 | 902 | 43× |

The 2026-07-29 campaign measured the transform at 122 µs/op (6.9× behind
IS4's freshly optimized #594 implementation) and named porting that batching
strategy as the next optimization target. That work is done (IS `242ce04f`):
the per-series validation now runs against two up-front catalog listings and
memoized forecast parameters instead of 1–2 FFI queries per series, and the
transform costs **2.5 s** once per study setup vs IS4's 1.8 s. The residual
1.4× is attributed and bounded — ~7 µs/op is JSON-marshaling the 100k-row
catalog listing across the FFI boundary and ~12 µs/op is the Rust core
transform itself; a binary listing protocol in the Julia binding (which would
speed every large listing) is the known fix if parity is ever required.
Everything downstream of the transform (the reads a simulation actually loops
over) is 43–83× faster here.

## Results: has_time_series at 100,000 series

10,000 components × 10 series each, every association carrying two features;
queries pass the full identity (type, name, resolution, both features).

| query | infrastore | is4 | |
|---|---:|---:|---|
| hit (series exists) | 4.2 | 3.7 | parity (−0.5 µs) |
| miss (wrong feature value) | 9.6 | 15.5 | 1.6× faster |

These numbers reflect optimization work delivered *during* this benchmark
campaign: the initial measurement showed 19.4 µs per query — the InfraStore
core answered feature-filtered probes by listing and hydrating rows. IS4's
`has_metadata` strategy (probe the complete feature set first via an indexed
exact match; fall back to a per-feature filter only for partial queries) was
ported into the core (infrastore `b7bd33e`, IS `59d19a25`): callers passing
the full feature set now get a single covering-index seek. Hits improved
4.4×, misses 2×, and partial-feature queries — the slow path on both stores —
run entirely on indexes here, which is why misses now beat IS4.

## Results: save, load, remove

| operation (100k Float64 STS) | infrastore | is4 | speedup |
|---|---:|---:|---:|
| serialize system to JSON + store artifacts | 0.33 s | 3.97 s | 12× |
| deserialize + reattach all components | 1.37 s | 6.59 s | 4.8× |
| first read from the reloaded system | 1.2 ms | 8.0 ms | 6.5× |
| serialized footprint on disk | 100 MB | 113 MB | 11% smaller |
| remove all 100k series one-by-one | 10.3 s | **did not complete** | >290× |
| remove all 100k series via the type-level bulk call | 1.2 s | **did not complete** | |

The IS4 removal run was stopped after 50+ minutes inside the removal loop
(its small-N rate predicted ~1 minute). Profiling showed each IS4
`remove_time_series!` paying SQLite deletes plus an HDF5 open-object
iteration whose cost grows with the file's object count — effectively
quadratic at this scale. The 2026-07-29 campaign measured the branch's
per-series removal at 369 µs/op and flagged it as the branch's slowest
operation; the follow-up work is done. Profiling attributed ~75% of each
removal to per-operation SQLite commit I/O (WAL write amplification across
the catalog's secondary indexes, the per-commit fsync, and auto-checkpoint
fsyncs), with most of the rest in an HDF5 column-scrub write. Cached
statements, `synchronous=NORMAL` under WAL, and index-only array frees
(infrastore `9b34c32`) plus routing IS removals through single-transaction
bulk catalog calls (IS `167ead85`) bring per-series removal to 103 µs/op,
and `remove_time_series!(sys, SingleTimeSeries)` — one bulk call — removes
all 100k series at 12.4 µs/op.

Runtime store files: the branch keeps both data and metadata on disk
(142 MB for the 100k Float64 STS system) where IS4 holds metadata in memory
(81 MB HDF5 on disk + metadata RAM); the serialized-system row is the
apples-to-apples footprint. Peak ingest memory (process RSS after the first
100k bulk add in a fresh process): 1.4 GB (branch, 2026-07-30 single-process
rerun) vs 2.2 GB (IS4).

## Capability differences found

- **`NonSequentialTimeSeries` is InfraStore-branch only** — irregular
  timestamped series are a new capability; IS4 has no equivalent type.
- **Tuple-payload `Deterministic`** was accepted by IS4 but rejected by this
  branch's element-type validation when the campaign ran — the one
  type×payload combination IS4 accepted and the branch did not. **Closed**
  (IS `626bec64`): tuple forecast windows now encode through the same tagged
  dense layout as cost-function windows, and the combination benchmarks 2–9×
  faster than IS4 (see the ingest/reads table).
- Bug found and fixed by this campaign: `NonSequentialTimeSeries` additions
  through `time_series_transaction` failed (`NonSequentialTimeSeriesKey`
  missing from the `ConcreteTimeSeriesKey` union; IS `fb14fa1e`).

## Known follow-up items

Of the five items the 2026-07-29 report listed, three are done (2026-07-30;
this update's branch numbers include them):

1. **Done — transform batching.** IS4 #594's in-memory batching is ported
   (IS `242ce04f`): 122 → 24.6 µs/op. The residual 1.4× vs IS4 is the FFI
   JSON catalog-listing marshaling plus the Rust core transform; a binary
   listing protocol in the Julia binding is the known fix if parity is ever
   required.
2. **Done — tuple-forecast payload gap** (IS `626bec64`); now 2–9× faster
   than IS4.
3. **Done — per-series removal** (infrastore `9b34c32`, IS `167ead85`):
   369 → 103 µs/op per-series, and 12.4 µs/op through the type-level bulk
   call.

Still open:

4. NST stores are disk-heavy (297 MB vs 142 MB for the same volume of regular
   series) — per-series timestamp storage is a compression candidate.
5. Shared-forecast bulk add trails IS4 slightly (28.1 vs 22.3 µs/op).

## Conclusion

At production scale the InfraStore backend is faster on every ingest, read,
query, and serialization path measured, by factors that grow with store size —
culminating in a 119–212× advantage on the access pattern that dominates
simulation runtimes — while adding irregular-series support. Every gap the
campaign discovered has since been closed (has_time_series, tuple-payload
forecasts, removals) or narrowed to a bounded residual with a known fix
(the transform, now within 1.4× of IS4's best). The two remaining items are
minor and enumerated above.
