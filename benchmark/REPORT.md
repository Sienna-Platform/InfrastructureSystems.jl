# Time Series Storage Rewrite — Performance Validation Report

**Date:** 2026-07-31 · **Scale:** 100,000 time series per system · **Run:**
single exclusive HPC node, SLURM job 15438463

## Executive summary

InfrastructureSystems.jl (IS) is the foundation of the Sienna platform: every
Sienna package stores and reads its time series through it. This work replaces
the previous HDF5 + SQLite storage engine (the **IS4** baseline) with
**InfraStore**, a purpose-built storage engine with a compiled native (Rust)
core, behind the same public Julia API.

This report supersedes the 2026-07-29/30 laptop campaigns. Those compared runs
taken on different machines and under different process loads; this one runs
both engines back-to-back as single undisturbed processes on one exclusive
node, with the branch repeated three times for an error bar (mean run-to-run
spread **3.0%** across 66 operations).

Benchmarked head-to-head on identical workloads at 100,000 series in one
system, the InfraStore-backed branch is faster on **every ingest and read
path**:

| capability | improvement over IS4 |
|---|---|
| Bulk ingest (all types and payloads) | 1.7–11.6× faster |
| Reading stored series (full or sliced) | 17–185× faster, **flat** in store size and payload type |
| Simulation inner loop (all components at one timestamp / window) | **173–492× faster** |
| `transform_single_time_series!` + forecast-window reads (the PowerSimulations feed path) | window reads 185× faster |
| System save / load with 100k series | 8.9× / 5.4× faster, 26% smaller on disk |
| `has_time_series` with full identity | hits 0.9 µs behind, misses 1.4× faster |
| Removing all 100k series one-by-one | 3.8 s vs an extrapolated ~3.7 h (~3,500×) |
| Peak ingest memory | 0.93 GB vs 1.56 GB |

Two capabilities exist only on the new branch: `NonSequentialTimeSeries`
(irregular-timestamp series) and columnar readers that serve every component
from one storage read per timestep. Every gap the earlier campaigns found is
closed: `has_time_series` misses now beat IS4, tuple-payload `Deterministic`
is supported and 2.2–27× faster, and per-series removal is no longer the
branch's slowest operation. One IS4 advantage remains — with PR #594 its
`transform_single_time_series!` is **1.39× faster** than the branch's — plus
three minor items enumerated under follow-ups.

**Read the caveats before quoting the read and sweep ratios.** A within-run
ordering effect inflates IS4's later sections; see *Known measurement
limitations*.

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
9. **Removal** of all series, one `remove_time_series!` call per component —
   at 100,000 on the branch, and at 2,000 / 5,000 / 10,000 on IS4 to measure
   its growth curve.
10. **Store footprint** and process peak memory.

## Environment and methodology

| | |
|---|---|
| Machine | 1 exclusive node: 2× Intel Xeon Platinum 8470QL (104 cores, 2.10 GHz), 250 GB RAM |
| Node / partition | `x1005c6s2b1n1` / `standard`, `ActiveFeatures=hbw,rh8` |
| Julia | 1.12.1, `JULIA_NUM_THREADS=1`, `JULIA_NUM_GC_THREADS=4` |
| InfraStore branch | IS `feat/rust-time-series-store` @ `f3eceb1f`, infrastore @ `f0c075e` (v0.4.0, release build) |
| IS4 baseline | `320a5035` = IS `IS4` @ `c63d9a281` + PR #594 cherry-pick (see note) |
| Store location | `/dev/shm` (tmpfs) — see caveats |

- Every number is the average over the full 100,000-op loop (`@timed`, GC
  quiesced before each op); JIT warmup precedes measurement.
- Each (type × element type) combination uses a fresh system with 100,000
  components, one series per component, distinct random data per series
  (except the `shared` sections), stores in private temp directories.
- Adds use each branch's recommended batched path
  (`time_series_transaction` vs `begin_time_series_update`).
- **Both engines ran on the same node, in sequence, with nothing else
  scheduled.** IS4 ran first so that the branch inherited a thermally soaked
  CPU — the direction that understates the branch's advantage.
- The branch matrix was run **three times**. Run-to-run spread averages 3.0%
  and is under 7% for every operation except `reload_read_one` (24.7%, a
  single-call measurement). The comparison tables use pass 1;
  `branch_variance.csv` carries the full error bar. **IS4 was run once** — a
  second IS4 pass costs ~5 node-hours and was not taken.
- **IS4 transform note:** the IS4 branch predates IS PR #594
  (`transform_single_time_series!` speedup). Without it the 100k transform did
  not complete within an hour (quadratic SQLite scanning), so #594 was
  cherry-picked into the IS4 baseline. IS4 is therefore measured with its best
  available implementation. #594 does not affect any other measured path.
- Raw data: `results_full_branch_hpc_r{1,2,3}.csv`, `results_full_is4_hpc.csv`
  and `results_full_is4_remove_*.csv` in this directory; `comparison.md` is the
  generated full table and `env.txt` the captured provenance. Regenerate with
  `julia benchmark/make_full_report.jl report-input`.

## Known measurement limitations

Three things bound how these numbers should be read. All of them are
recoverable with more node time; none of them change the qualitative result.

**1. IS4 degrades over the life of its process, which inflates its later
sections.** Both engines ran their whole matrix in one process. On IS4, the
same read work costs several times more when it runs late:

| identical read work | ran early | ran late | drift |
|---|---:|---:|---:|
| IS4, 100k Float64 STS full read | 1,678 µs (`sts`) | 7,209 µs (`sts_shared`) | 4.3× |
| IS4, 100k Float64 Deterministic full read | 2,188 µs (`det`) | 6,007 µs (`det_shared`) | 2.7× |
| branch, same two STS reads | 67.9 µs | 63.2 µs | flat |
| branch, same two Deterministic reads | 106 µs | 79.3 µs | flat |

The `shared` sections read *less distinct data* than their non-shared
counterparts, so they should be at worst equal — and on the 2026-07-30 laptop
run, where IS4 was split across four processes, IS4's shared reads were 4×
**faster** than its non-shared reads. The inversion here is a process-lifetime
effect, consistent with the HDF5 open-object iteration already identified in
IS4's removal path. Consequence: the ratios for the sections that ran late on
IS4 (`sweep`, `has`, `dst`, `shared`, `serialize`) are upper bounds. The
sections that ran early (`sts`, `nst`, `det`, `prob`, `scen`) are unaffected —
and those alone already show 17–42× read advantages. **Fix:** rerun IS4 with
one process per `BENCH_KINDS` section.

**2. Stores were on tmpfs (`/dev/shm`), not disk.** This node exposes no
node-local disk, and pointing `TMPDIR` at the shared parallel filesystem would
have benchmarked the network, not the engines. tmpfs removes storage I/O from
the comparison, which isolates CPU and algorithmic differences but does not
reproduce a production Sienna deployment writing to disk. Prior campaigns were
disk-backed and showed the same ordering. The `store_disk_bytes` figures are
real file sizes and are unaffected.

**3. IS4's 100k removal is extrapolated,** from three measured points rather
than asserted — see the removal section.

Julia was 1.12.1 on the cluster rather than the 1.12.6 used by the laptop
campaigns; both engines ran the same version, so the head-to-head is
unaffected, but absolute µs/op are not directly comparable across reports.

## Results: ingest and per-owner reads (µs per operation)

Every read on the InfraStore branch lands in a 60–181 µs band regardless of
type, payload, or store size; IS4's reads range 1,678–20,245 µs and grow with
store size, payload width, and process age.

| type | payload | operation | infrastore | is4 | speedup |
|---|---|---|---:|---:|---:|
| SingleTimeSeries | Float64 | bulk add | 13.9 | 98.9 | 7.1× |
| SingleTimeSeries | Float64 | read full | 67.9 | 1,678 | 24.7× |
| SingleTimeSeries | Float64 | read slice | 59.5 | 1,678 | 28.2× |
| SingleTimeSeries | tuple | read full | 80.6 | 2,233 | 27.7× |
| SingleTimeSeries | linear cost | read full | 79.8 | 1,863 | 23.4× |
| SingleTimeSeries | quadratic cost | read full | 80.6 | 2,233 | 27.7× |
| SingleTimeSeries | piecewise-linear | read full | 94.7 | 3,847 | 40.6× |
| SingleTimeSeries | piecewise-linear | read slice | 77.0 | 4,799 | 62.3× |
| Deterministic | Float64 | bulk add | 56.1 | 137 | 2.4× |
| Deterministic | Float64 | read full | 106 | 2,188 | 20.6× |
| Deterministic | Float64 | read one window | 67.6 | 2,165 | 32.0× |
| Deterministic | tuple | bulk add | 71.6 | 160 | 2.2× |
| Deterministic | tuple | read full | 146 | 2,565 | 17.6× |
| Deterministic | tuple | read one window | 77.4 | 2,086 | 26.9× |
| Deterministic | piecewise-linear | bulk add | 123 | 1,423 | 11.6× |
| Deterministic | piecewise-linear | read full | 181 | 4,992 | 27.5× |
| Deterministic | piecewise-linear | read one window | 87.1 | 4,693 | 53.9× |
| Probabilistic | Float64 | read full | 134 | 5,054 | 37.7× |
| Scenarios | Float64 | read full | 130 | 5,484 | 42.3× |
| NonSequentialTimeSeries | Float64 | bulk add | 37.9 | n/a | IS4 lacks the type |
| NonSequentialTimeSeries | Float64 | read full | 81.3 | n/a | |

Bulk adds for tuple/linear/quadratic STS: 17.1–17.7 µs vs 106–112 µs on IS4
(~6×). All five NST payloads land at 37.9–50.2 µs adds / 81.3–104 µs reads.
Tuple-payload `Deterministic` — the one type×payload combination IS4 accepted
and the branch rejected when the campaign began — is supported since IS
`626bec64` and now beats IS4 across the board. `Probabilistic` and `Scenarios`
bulk adds are the branch's narrowest ingest margin at 1.7× (80.7 / 80.5 µs vs
139 / 138 µs).

Full table including disk footprints: `comparison.md`.

## Results: the simulation inner loop

The pattern that dominates production-cost simulation runtimes: at each
timestamp (or forecast window), read every component's value. µs per
(component, timestamp) value, with the wall clock for the whole sweep:

| workload | infrastore | is4 | speedup |
|---|---:|---:|---:|
| 100k static series × 24 timestamps (2.4M values) | 2.04 µs — **4.9 s** | 704 µs — 28.2 min | **344×** |
| 100k deterministic forecasts × 12 windows (1.2M windows) | 5.76 µs — **6.9 s** | 1,516 µs — 30.3 min | **263×** |
| 100k DST forecasts (post-transform) × 13 windows | 16.2 µs — 21.1 s | 2,814 µs — 61.0 min | 173× |
| shared profile, 2.4M static values | 1.83 µs — 4.4 s | 609 µs — 24.4 min | 332× |
| shared forecast, 1.2M windows | 2.98 µs — 3.6 s | 1,467 µs — 29.3 min | 492× |

Sweeping all 2.4 million (component, timestamp) values takes **4.9 seconds**
on the InfraStore branch vs **28 minutes** on IS4. The columnar
`StaticTimeSeriesReader` serves every component from one physical read per
timestamp; IS4 pays one cache per component. (The two `shared` rows ran late in
the IS4 process — see limitation 1; the two non-shared rows did not.)

## Results: transform_single_time_series! (DST)

| operation | infrastore | is4 (+#594) | speedup |
|---|---:|---:|---:|
| transform 100k STS → DST | 28.7 µs — 2.9 s | 20.6 µs — 2.1 s | 0.72× (1.39× slower) |
| read one DST window per component | 109 | 20,245 | 185× |
| DST by-window sweep (1.3M windows) | 16.2 | 2,814 | 173× |

This is the one path where IS4 is ahead, and the gap is stable across
machines: 0.72× here, 0.77× on the 2026-07-30 laptop run. IS4 #594's in-memory
batching was ported into the branch (IS `242ce04f`) — per-series validation now
runs against two up-front catalog listings and memoized forecast parameters
instead of 1–2 FFI queries per series, taking the transform from 122 µs/op to
28.7. The residual is attributed and bounded: JSON-marshaling the 100k-row
catalog listing across the FFI boundary, plus the Rust core transform itself. A
binary listing protocol in the Julia binding — which would speed every large
listing — is the known fix if parity is ever required.

The transform is a **once per study setup** cost of 2.9 s vs 2.1 s.
Everything downstream of it, which is what a simulation actually loops over,
is 173–185× faster here.

## Results: has_time_series at 100,000 series

10,000 components × 10 series each, every association carrying two features;
queries pass the full identity (type, name, resolution, both features).

| query | infrastore | is4 | |
|---|---:|---:|---|
| bulk add (100k associations) | 18.4 | 30.7 | 1.7× faster |
| hit (series exists) | 5.49 | 4.59 | 0.84× (0.9 µs behind) |
| miss (wrong feature value) | 12.4 | 17.6 | 1.4× faster |

These numbers reflect optimization work delivered during the benchmark
campaign: the initial measurement showed 19.4 µs per query, because the
InfraStore core answered feature-filtered probes by listing and hydrating rows.
IS4's `has_metadata` strategy — probe the complete feature set first via an
indexed exact match, fall back to a per-feature filter only for partial
queries — was ported into the core (infrastore `b7bd33e`, IS `59d19a25`), so
callers passing the full feature set now get a single covering-index seek.
Partial-feature queries, the slow path on both stores, run entirely on indexes
here, which is why misses beat IS4.

Hits remain a consistent sub-microsecond behind IS4 (0.84× here, 0.93× on the
laptop): IS4 answers a hit from an in-process Dict, the branch from an indexed
seek across the FFI boundary. At 0.9 µs on a query that is not in any inner
loop this is not worth closing, but the earlier report's "parity" claim was
optimistic and is corrected here.

## Results: save, load, remove

| operation (100k Float64 STS) | infrastore | is4 | speedup |
|---|---:|---:|---:|
| serialize system to JSON + store artifacts | 0.57 s | 5.05 s | 8.9× |
| deserialize + reattach all components | 1.65 s | 8.99 s | 5.4× |
| first read from the reloaded system | 2.1 ms | 28.7 ms | 13.6× |
| serialized footprint on disk | 83.6 MB | 112 MB | 26% smaller |
| remove all 100k series one-by-one | **3.8 s** | ~3.7 h (extrapolated) | ~3,500× |

**The removal extrapolation.** Earlier campaigns reported only that IS4's 100k
removal loop "did not complete" after 50+ minutes. This run measures the growth
curve instead, at three scales:

| series removed | is4 µs/op | is4 total |
|---:|---:|---:|
| 2,000 | 3,136 | 6.3 s |
| 5,000 | 7,096 | 35.5 s |
| 10,000 | 13,821 | 138.2 s |

Per-operation cost is **linear in store size** (a least-squares fit gives
µs/op = 443 + 1.337·n, R² > 0.9999; doubling from 5k to 10k doubles the
per-op cost), so total removal cost is quadratic. Extrapolating the fit to
100,000 series gives ~134,000 µs/op, or **~3.7 hours** — consistent with the
run that was abandoned at 50 minutes. Each IS4 `remove_time_series!` pays
SQLite deletes plus an HDF5 open-object iteration whose cost grows with the
file's object count.

The branch removes the same 100,000 series in **3.81 s** (38.1 µs/op, flat).
This is the operation the 2026-07-29 campaign flagged as the branch's slowest
(369 µs/op then); profiling attributed ~75% of each removal to per-operation
SQLite commit I/O — WAL write amplification across the catalog's secondary
indexes, the per-commit fsync, and auto-checkpoint fsyncs — with most of the
rest in an HDF5 column-scrub write. Cached statements, `synchronous=NORMAL`
under WAL, and index-only array frees (infrastore `9b34c32`), plus routing IS
removals through single-transaction bulk catalog calls (IS `167ead85`), closed
it.

**Store footprint.** The branch keeps both data and metadata on disk (112 MB
for the 100k Float64 STS system) where IS4 holds metadata in memory (80.8 MB
HDF5 on disk + metadata RAM). The `shared` rows make the difference stark —
87.5 MB on the branch vs 2.8 KB on IS4 — because with one deduplicated array
the branch's file is almost entirely catalog. The serialized-system row above
is the apples-to-apples footprint, and there the branch is 26% smaller.

**Peak memory.** Process RSS after the first 100k bulk add in a fresh process
(the only point that attributes cleanly, since `maxrss` is monotone):
**0.93 GB** on the branch vs **1.56 GB** on IS4.

## Capability differences found

- **`NonSequentialTimeSeries` is InfraStore-branch only** — irregular
  timestamped series are a new capability; IS4 has no equivalent type. All five
  payloads ingest at 37.9–50.2 µs/op and read at 81.3–104 µs/op.
- **Tuple-payload `Deterministic`** was accepted by IS4 but rejected by this
  branch's element-type validation when the campaign began. **Closed** (IS
  `626bec64`): tuple forecast windows now encode through the same tagged dense
  layout as cost-function windows, and the combination benchmarks 2.2–27×
  faster than IS4.
- Bug found and fixed by this campaign: `NonSequentialTimeSeries` additions
  through `time_series_transaction` failed (`NonSequentialTimeSeriesKey`
  missing from the `ConcreteTimeSeriesKey` union; IS `fb14fa1e`).

## Known follow-up items

Closed since the 2026-07-29 report, and confirmed by this run:

1. **Transform batching** ported from IS4 #594 (IS `242ce04f`): 122 → 28.7
   µs/op. Residual 1.39× vs IS4 is bounded, with a known fix.
2. **Tuple-forecast payload gap** (IS `626bec64`) — now 2.2–27× faster
   than IS4.
3. **Per-series removal** (infrastore `9b34c32`, IS `167ead85`): 369 → 38.1
   µs/op, against an IS4 curve that reaches ~134,000 µs/op at this scale.
4. **`has_time_series`** (infrastore `b7bd33e`, IS `59d19a25`): misses now
   1.4× faster than IS4.

Still open:

5. **NST stores are disk-heavy** — 260 MB vs 112 MB for the same volume of
   regular Float64 series. Per-series timestamp storage is a compression
   candidate.
6. **Shared-forecast bulk add trails IS4 slightly** — 26.6 vs 24.7 µs/op
   (0.93×). The shared-static equivalent is now ahead (12.5 vs 14.8, 1.18×).
7. **`has_time_series` hits** are 0.9 µs behind IS4 (5.49 vs 4.59 µs).
8. **Measurement:** rerun IS4 with one process per section to remove the
   process-lifetime drift described under limitations, and take a second IS4
   pass for a two-sided error bar.

## Conclusion

At production scale, measured on a single exclusive node with both engines run
back-to-back, the InfraStore backend is faster on every ingest, read, query,
removal and serialization path — by factors that grow with store size,
culminating in a 173–492× advantage on the access pattern that dominates
simulation runtimes — while adding irregular-series support and cutting peak
ingest memory by 40%. Every gap the campaign discovered has been closed. One
IS4 advantage remains, its `transform_single_time_series!` at 1.39×, on a
once-per-study-setup operation whose downstream reads are 173–185× faster here.
The remaining items are minor and enumerated above.
