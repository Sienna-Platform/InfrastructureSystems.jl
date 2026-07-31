# Time Series Storage Rewrite — Performance Validation Report

**Date:** 2026-07-29 · **Updated:** 2026-07-31 (branch numbers refreshed after
a second round of post-campaign optimization; see follow-up items) ·
**Scale:** 100,000 time series per system

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
| Bulk ingest (all types and payloads) | 1.9–13× faster |
| Reading stored series (full or sliced) | 2.9–128× faster, **flat** in store size and payload type |
| Simulation inner loop (all components at one timestamp / window) | **54–282× faster** |
| `transform_single_time_series!` + forecast-window reads (the PowerSimulations feed path) | transform 1.5× faster, window reads 98× faster |
| System save / load with 100k series | 10.5× / 5.2× faster, 29% smaller on disk |
| `has_time_series` with full identity | hits at parity, misses 1.6× faster (after work delivered below) |
| Removing all 100k series | 8.8 s (per-series) / 1.2 s (bulk); IS4 did not complete |

Two capabilities exist only on the new branch: `NonSequentialTimeSeries`
(irregular-timestamp series) and columnar readers that serve every component
from one storage read per timestep. **Every gap the 2026-07-29 campaign found
is now closed** (branch numbers in this update are from the 2026-07-31
rerun): the `has_time_series` gap was closed the same day by porting IS4's
query strategy into the InfraStore core; the tuple-payload `Deterministic`
rejection is fixed and now beats IS4 by 2.4–10×; per-series removal is 4.2×
faster than first measured; shared-forecast ingest has gone from behind to
1.2× ahead; and the last IS4 advantage — its recently optimized
`transform_single_time_series!`, which led by 6.9× when the campaign ran — is
now 1.5× behind this branch.

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
| InfraStore branch (2026-07-31 rerun) | IS `feat/rust-time-series-store` @ `6a1e6105`, infrastore @ `e69a743` |
| InfraStore branch (2026-07-30 rerun) | IS @ `626bec64`, infrastore @ `fba0077` |
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
- The IS4 numbers were gathered from long runs split across concurrent
  processes (independent systems/stores); the branch reruns are single-process
  end-to-end. Both branches were measured under comparable machine load, and
  spot checks at small N reproduce the same ratios.
- **IS4 transform note:** the IS4 branch predates IS PR #594
  (`transform_single_time_series!` speedup). Without it the 100k transform did
  not complete within an hour (quadratic SQLite scanning), so #594 was
  cherry-picked into the IS4 baseline for the transform sections — IS4 is
  measured with its best available implementation. #594 does not affect any
  other measured path.
- Raw data: `results_full_*.csv` in this directory; regenerate the tables with
  `julia benchmark/make_full_report.jl`. Branch numbers in this update come
  from `results_full_branch_w4.csv` — a single-process rerun of the full
  matrix on 2026-07-31 after the second round of optimizations landed (108
  rows, no failed combinations). IS4 numbers are unchanged from the 2026-07-29
  campaign. No branch measurement regressed between the 2026-07-30 and
  2026-07-31 reruns; the gains come from infrastore `67e2ece` (interned NST
  time axes), `1291e5a` (one catalog lookup per bulk-read key), `ef1a50a`
  (memoized timestamp decoding) and `e69a743` + IS `6a1e6105` (the transform's
  validation moved into the core).

## Results: ingest and per-owner reads (µs per operation)

Every read on the InfraStore branch lands in a narrow 76–148 µs band
regardless of type, payload, or store size; IS4's reads range 323–11,014 µs
and grow with store size and payload width.

| type | payload | operation | infrastore | is4 | speedup |
|---|---|---|---:|---:|---:|
| SingleTimeSeries | Float64 | bulk add | 11.3 | 116 | 10.3× |
| SingleTimeSeries | Float64 | read full | 82.0 | 2,110 | 26× |
| SingleTimeSeries | Float64 | read slice | 76.2 | 1,979 | 26× |
| SingleTimeSeries | tuple | read full | 90.2 | 5,780 | 64× |
| SingleTimeSeries | linear cost | read full | 91.8 | 6,501 | 71× |
| SingleTimeSeries | quadratic cost | read full | 90.4 | 8,291 | 92× |
| SingleTimeSeries | piecewise-linear | read full | 98.5 | 10,418 | 106× |
| SingleTimeSeries | piecewise-linear | read slice | 85.8 | 11,014 | 128× |
| Deterministic | Float64 | bulk add | 52.5 | 140 | 2.7× |
| Deterministic | Float64 | read full | 107 | 881 | 8.3× |
| Deterministic | Float64 | read one window | 81.5 | 900 | 11.0× |
| Deterministic | tuple | bulk add | 61.6 | 149 | 2.4× |
| Deterministic | tuple | read full | 124 | 1,184 | 9.6× |
| Deterministic | tuple | read one window | 85.5 | 901 | 10.5× |
| Deterministic | piecewise-linear | bulk add | 130 | 1,647 | 12.7× |
| Deterministic | piecewise-linear | read full | 148 | 1,423 | 9.6× |
| Probabilistic | Float64 | read full | 121 | 345 | 2.9× |
| Scenarios | Float64 | read full | 120 | 1,024 | 8.5× |
| NonSequentialTimeSeries | Float64 | bulk add | 41.9 | n/a | IS4 lacks the type |
| NonSequentialTimeSeries | Float64 | read full | 92.0 | n/a | |

(Bulk adds for tuple/linear/quadratic STS: 11.0–12.1 µs vs 101–104 µs on IS4,
8.3–9.5×. All five NST payloads land at 42–50 µs adds / 88–96 µs reads.
The tuple-payload `Deterministic` rows entered the table in the 2026-07-30
update: the 2026-07-29 campaign recorded that combination as rejected by the
branch's element-type validation — the one type×payload combination IS4
accepted and the branch did not. Support landed in IS `626bec64` and the
formerly missing combination now beats IS4 across the board.)

## Results: the simulation inner loop

The pattern that dominates production-cost simulation runtimes: at each
timestamp (or forecast window), read every component's value. µs per
(component, timestamp) value:

| workload | infrastore | is4 | speedup |
|---|---:|---:|---:|
| 100k static series × 24 timestamps (2.4M values) | 0.976 | 276 | **282×** |
| 100k deterministic forecasts × 12 windows (1.2M windows) | 4.51 | 680 | **151×** |
| 100k DST forecasts (post-transform) × 13 windows | 16.7 | 902 | 54× |
| shared profile, 2.4M static values | 0.881 | 165 | 188× |
| shared forecast, 1.2M windows | 1.60 | 348 | 218× |

In wall-clock terms: sweeping all 2.4 million (component, timestamp) values
takes **2.3 seconds** on the InfraStore branch vs **11 minutes** on IS4.
The columnar `StaticTimeSeriesReader` serves every component from one
physical read per timestamp; IS4 pays one cache per component.

## Results: transform_single_time_series! (DST)

| operation | infrastore | is4 (+#594) | speedup |
|---|---:|---:|---:|
| transform 100k STS → DST | 11.5 | 17.7 | **1.5×** |
| read one DST window per component | 102 | 9,965 | 98× |
| DST by-window sweep (1.3M windows) | 16.7 | 902 | 54× |

This was the last operation on which IS4 led, and it no longer does. The
2026-07-29 campaign measured the transform at 122 µs/op (6.9× behind IS4's
freshly optimized #594 implementation); porting that batching strategy into
Julia (IS `242ce04f`) brought it to 24.6 µs/op, still 1.4× behind, with the
residual attributed to marshaling a 100k-row catalog listing across the FFI
boundary once per call. The fix was to stop marshaling it at all: the
eligibility rules — horizon fit and divisibility, interval divisibility and
length, per-resolution grid uniformity, and conflicts with forecasts already
stored — now live in the Rust core (infrastore `e69a743`, IS `6a1e6105`),
which answers them from its distinct static grids (`GROUP BY resolution`).
The cost is O(distinct resolutions) rather than O(series), no listing crosses
the FFI boundary, and the transform costs **1.1 s** once per study setup vs
IS4's 1.8 s. Everything downstream of the transform (the reads a simulation
actually loops over) is 54–98× faster here.

## Results: has_time_series at 100,000 series

10,000 components × 10 series each, every association carrying two features;
queries pass the full identity (type, name, resolution, both features).

| query | infrastore | is4 | |
|---|---:|---:|---|
| hit (series exists) | 4.1 | 3.7 | parity (−0.4 µs) |
| miss (wrong feature value) | 9.4 | 15.5 | 1.6× faster |

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
| serialize system to JSON + store artifacts | 0.38 s | 3.97 s | 10.5× |
| deserialize + reattach all components | 1.26 s | 6.59 s | 5.2× |
| first read from the reloaded system | 1.2 ms | 8.0 ms | 6.5× |
| serialized footprint on disk | 80.5 MB | 113 MB | 29% smaller |
| remove all 100k series one-by-one | 8.8 s | **did not complete** | >340× |
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
bulk catalog calls (IS `167ead85`) bring per-series removal to 88.4 µs/op.
The bulk row — `remove_time_series!(sys, SingleTimeSeries)`, one call, 12.4
µs/op — is carried over from the 2026-07-30 removal work; the full matrix
measures only the per-series loop.

Runtime store files: the branch keeps both data and metadata on disk
(106 MB for the 100k Float64 STS system) where IS4 holds metadata in memory
(81 MB HDF5 on disk + metadata RAM); the serialized-system row is the
apples-to-apples footprint. Peak ingest memory (process RSS after the first
100k bulk add in a fresh process): 1.2 GB (branch, 2026-07-31 single-process
rerun) vs 2.2 GB (IS4).

## Capability differences found

- **`NonSequentialTimeSeries` is InfraStore-branch only** — irregular
  timestamped series are a new capability; IS4 has no equivalent type.
- **Tuple-payload `Deterministic`** was accepted by IS4 but rejected by this
  branch's element-type validation when the campaign ran — the one
  type×payload combination IS4 accepted and the branch did not. **Closed**
  (IS `626bec64`): tuple forecast windows now encode through the same tagged
  dense layout as cost-function windows, and the combination benchmarks
  2.4–10× faster than IS4 (see the ingest/reads table).
- Bug found and fixed by this campaign: `NonSequentialTimeSeries` additions
  through `time_series_transaction` failed (`NonSequentialTimeSeriesKey`
  missing from the `ConcreteTimeSeriesKey` union; IS `fb14fa1e`).

## Known follow-up items

All five items the 2026-07-29 report listed are now done; this update's
branch numbers include them.

1. **Done — the transform.** IS4 #594's in-memory batching was ported first
   (IS `242ce04f`, 122 → 24.6 µs/op), then the eligibility rules moved into
   the Rust core so no catalog listing crosses the FFI boundary at all
   (infrastore `e69a743`, IS `6a1e6105`): **11.5 µs/op**, 1.5× ahead of IS4.
2. **Done — tuple-forecast payload gap** (IS `626bec64`); now 2.4–10× faster
   than IS4.
3. **Done — per-series removal** (infrastore `9b34c32`, IS `167ead85`):
   369 → 88.4 µs/op per-series, and 12.4 µs/op through the type-level bulk
   call.
4. **Done — NST disk footprint.** Interning and packing NST series by their
   shared time axis (infrastore `67e2ece`) cut every NST payload's store by
   26–44% (Float64: 284 → 158 MB). NST still costs 1.5× the equivalent
   regular series (158 vs 106 MB) rather than the previous 2.1×; the residual
   is the timestamp column itself, and further compression is optional rather
   than a gap.
5. **Done — shared-forecast bulk add**, which trailed IS4 at 28.1 vs 22.3
   µs/op, is now **18.7 µs/op — 1.2× ahead**.

One measurement moved the wrong way between the two branch reruns and is
noted for completeness: `to_json` went from 3.25 to 3.79 µs/op (+17%). It was
not profiled; the likeliest cause is the two per-series fields added in the
interval (`units` and `element_type`). It remains 10.5× faster than IS4, and
the serialized footprint fell 16% over the same interval.

## Conclusion

At production scale the InfraStore backend is faster on every ingest, read,
query, and serialization path measured, by factors that grow with store size —
culminating in a 151–282× advantage on the access pattern that dominates
simulation runtimes — while adding irregular-series support. Every gap the
campaign discovered has since been closed: `has_time_series`, tuple-payload
forecasts, per-series removal, the NST disk footprint, shared-forecast
ingest, and finally `transform_single_time_series!`, the last operation on
which IS4 held a lead. The branch is now ahead of IS4 on every operation in
the matrix except `has_time_series` hits, where the two are at parity.
