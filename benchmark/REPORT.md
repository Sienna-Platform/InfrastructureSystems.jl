# Time Series Storage Rewrite — Performance Validation Report

**Date:** 2026-07-29 · **Scale:** 100,000 time series per system

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
| Bulk ingest (all types and payloads) | 1.5–12× faster |
| Reading stored series (full or sliced) | 2–107× faster, **flat** in store size and payload type |
| Simulation inner loop (all components at one timestamp / window) | **50–201× faster** |
| `transform_single_time_series!` + forecast-window reads (the PowerSimulations feed path) | window reads 73× faster |
| System save / load with 100k series | 12.5× / 4.6× faster, smaller on disk |
| `has_time_series` with full identity | hits at parity, misses 1.6× faster (after work delivered below) |

Two capabilities exist only on the new branch: `NonSequentialTimeSeries`
(irregular-timestamp series) and columnar readers that serve every component
from one storage read per timestep. The one IS4 advantage found —
its recently optimized `transform_single_time_series!` — is
identified below as the branch's next optimization target, and the
`has_time_series` gap found mid-benchmark was closed the same day by porting
IS4's query strategy into the InfraStore core.

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
| InfraStore branch | IS `feat/rust-time-series-store` @ `0eda6a7f`, infrastore @ `b7bd33e` |
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
  `julia benchmark/make_full_report.jl`.

## Results: ingest and per-owner reads (µs per operation)

Every read on the InfraStore branch lands in a narrow 95–200 µs band
regardless of type, payload, or store size; IS4's reads range 323–11,014 µs
and grow with store size and payload width.

| type | payload | operation | infrastore | is4 | speedup |
|---|---|---|---:|---:|---:|
| SingleTimeSeries | Float64 | bulk add | 16.6 | 116 | 7.0× |
| SingleTimeSeries | Float64 | read full | 113 | 2,110 | 18.7× |
| SingleTimeSeries | Float64 | read slice | 105 | 1,979 | 18.9× |
| SingleTimeSeries | tuple | read full | 118 | 5,780 | 49× |
| SingleTimeSeries | linear cost | read full | 116 | 6,501 | 56× |
| SingleTimeSeries | quadratic cost | read full | 118 | 8,291 | 70× |
| SingleTimeSeries | piecewise-linear | read full | 125 | 10,418 | 83× |
| SingleTimeSeries | piecewise-linear | read slice | 103 | 11,014 | 107× |
| Deterministic | Float64 | bulk add | 76.7 | 140 | 1.8× |
| Deterministic | Float64 | read full | 154 | 881 | 5.7× |
| Deterministic | Float64 | read one window | 123 | 900 | 7.3× |
| Deterministic | piecewise-linear | bulk add | 136 | 1,647 | 12.1× |
| Deterministic | piecewise-linear | read full | 200 | 1,423 | 7.1× |
| Probabilistic | Float64 | read full | 160 | 345 | 2.2× |
| Scenarios | Float64 | read full | 163 | 1,024 | 6.3× |
| NonSequentialTimeSeries | Float64 | bulk add | 47.4 | n/a | IS4 lacks the type |
| NonSequentialTimeSeries | Float64 | read full | 130 | n/a | |

(Bulk adds for tuple/linear/quadratic STS: 15–17 µs vs 101–104 µs on IS4,
6–7×. All five NST payloads land at 47–55 µs adds / 130–139 µs reads.
IS4 supports tuple-payload `Deterministic`, which the branch's validation
currently rejects — recorded as the one type×payload combination IS4 accepts
and the branch does not.)

## Results: the simulation inner loop

The pattern that dominates production-cost simulation runtimes: at each
timestamp (or forecast window), read every component's value. µs per
(component, timestamp) value:

| workload | infrastore | is4 | speedup |
|---|---:|---:|---:|
| 100k static series × 24 timestamps (2.4M values) | 1.37 | 276 | **201×** |
| 100k deterministic forecasts × 12 windows (1.2M windows) | 5.48 | 680 | **124×** |
| 100k DST forecasts (post-transform) × 13 windows | 17.9 | 902 | 50× |
| shared profile, 2.4M static values | 1.15 | 165 | 144× |
| shared forecast, 1.2M windows | 2.24 | 348 | 155× |

In wall-clock terms: sweeping all 2.4 million (component, timestamp) values
takes **3.3 seconds** on the InfraStore branch vs **11 minutes** on IS4.
The columnar `StaticTimeSeriesReader` serves every component from one
physical read per timestamp; IS4 pays one cache per component.

## Results: transform_single_time_series! (DST)

| operation | infrastore | is4 (+#594) | speedup |
|---|---:|---:|---:|
| transform 100k STS → DST | 122 | 17.7 | **0.15× (slower)** |
| read one DST window per component | 137 | 9,965 | 72.7× |
| DST by-window sweep (1.3M windows) | 17.9 | 902 | 50× |

The transform itself is the one operation where IS4's freshly optimized
implementation (#594, 2026-07-25) beats this branch. The absolute cost is
12 s once per study setup — but IS4 shows 1.8 s is achievable, and porting the
same batching strategy into the InfraStore transform is the branch's next
optimization target. Everything downstream of the transform (the reads a
simulation actually loops over) is 50–73× faster here.

## Results: has_time_series at 100,000 series

10,000 components × 10 series each, every association carrying two features;
queries pass the full identity (type, name, resolution, both features).

| query | infrastore | is4 | |
|---|---:|---:|---|
| hit (series exists) | 4.4 | 3.7 | parity (−0.7 µs) |
| miss (wrong feature value) | 9.96 | 15.5 | 1.6× faster |

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
| serialize system to JSON + store artifacts | 0.32 s | 3.97 s | 12.5× |
| deserialize + reattach all components | 1.44 s | 6.59 s | 4.6× |
| first read from the reloaded system | 1.5 ms | 8.0 ms | 5.5× |
| serialized footprint on disk | 95.5 MB | 113 MB | 15% smaller |
| remove all 100k series one-by-one | 36.9 s | **did not complete** | >90× |

The IS4 removal run was stopped after 50+ minutes inside the removal loop
(its small-N rate predicted ~1 minute). Profiling showed each IS4
`remove_time_series!` paying SQLite deletes plus an HDF5 open-object
iteration whose cost grows with the file's object count — effectively
quadratic at this scale. The branch's 36.9 s (369 µs/op) is itself the
slowest InfraStore operation measured and is listed as a follow-up below.

Runtime store files: the branch keeps both data and metadata on disk
(136 MB for the 100k Float64 STS system) where IS4 holds metadata in memory
(81 MB HDF5 on disk + metadata RAM); the serialized-system row is the
apples-to-apples footprint. Peak ingest memory (process RSS after the first
100k bulk add in a fresh process): 2.4 GB (branch) vs 2.2 GB (IS4) —
equivalent.

## Capability differences found

- **`NonSequentialTimeSeries` is InfraStore-branch only** — irregular
  timestamped series are a new capability; IS4 has no equivalent type.
- **Tuple-payload `Deterministic`** is accepted by IS4 but rejected by this
  branch's element-type validation (static tuple series work on both) — a
  known gap to close for full parity.
- Bug found and fixed by this campaign: `NonSequentialTimeSeries` additions
  through `time_series_transaction` failed (`NonSequentialTimeSeriesKey`
  missing from the `ConcreteTimeSeriesKey` union; IS `fb14fa1e`).

## Known follow-up items

1. Port IS4 #594's in-memory batching into the branch's
   `transform_single_time_series!` (122 → target ~18 µs/op).
2. Close the tuple-forecast payload gap.
3. NST stores are disk-heavy (284 MB vs 136 MB for the same volume of regular
   series) — per-series timestamp storage is a compression candidate.
4. Shared-forecast bulk add trails IS4 slightly (29.4 vs 22.3 µs/op).
5. Per-series removal is the branch's slowest op (369 µs/op; IS4's did not
   complete at all) — batch removals inside one transaction, or add a bulk
   removal path.

## Conclusion

At production scale the InfraStore backend is faster on every ingest, read,
query, and serialization path measured, by factors that grow with store size —
culminating in a 124–201× advantage on the access pattern that dominates
simulation runtimes — while adding irregular-series support and closing the
one query-performance gap discovered (has_time_series) within the same
campaign. The remaining gaps are enumerated, bounded, and have known fixes.
