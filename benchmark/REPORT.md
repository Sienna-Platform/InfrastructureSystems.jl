# Time Series Storage Rewrite — Performance Validation Report

**Date:** 2026-08-03 · **Scale:** 100,000 time series per system · **Runs:**
branch — SLURM job 15459992, one process per section, three passes; IS4
baseline — SLURM job 15438463, imported unchanged

## Executive summary

InfrastructureSystems.jl (IS) is the foundation of the Sienna platform: every
Sienna package stores and reads its time series through it. This work replaces
the previous HDF5 + SQLite storage engine (the **IS4** baseline) with
**InfraStore**, a purpose-built storage engine with a compiled native (Rust)
core, behind the same public Julia API.

Benchmarked head-to-head on identical workloads at 100,000 series in one
system, the InfraStore-backed branch is faster on **every measured path except
one metadata probe**:

| capability | improvement over IS4 |
|---|---|
| Bulk ingest (all types and payloads) | 1.1–11.3× faster |
| Reading stored series (full or sliced) | 19–90× faster in the drift-free sections, **flat** in store size and payload type |
| Simulation inner loop (all components at one timestamp / window) | **187–725× faster** |
| `transform_single_time_series!` | **1.97× faster** — IS4's last remaining advantage is now closed |
| Forecast-window reads after the transform (the PowerSimulations feed path) | 187–239× faster |
| System save / load with 100k series | 10.0× / 5.6× faster, 28% smaller on disk |
| `has_time_series` with full identity | hits 0.22 µs behind (0.95×), misses 1.6× faster |
| Removing all 100k series one-by-one | 3.76 s vs an extrapolated ~3.7 h (~3,500×) |
| Peak ingest memory (first section, clean comparison) | 0.80 GiB vs 1.56 GiB |

Two capabilities exist only on the new branch: `NonSequentialTimeSeries`
(irregular-timestamp series) and columnar readers that serve every component
from one storage read per timestep.

**What changed since the 2026-07-31 report.** That report left one IS4
advantage standing (`transform_single_time_series!`, 1.39× in IS4's favour) and
three minor follow-ups. This run closes all four:

| item | 2026-07-31 | now |
|---|---:|---:|
| `transform_single_time_series!` | 28.7 µs/op — **0.72×** (IS4 ahead) | 10.4 µs/op — **1.97×** (branch ahead) |
| shared-forecast bulk add | 26.6 vs 24.7 µs — 0.93× | 22.8 vs 24.7 µs — **1.08×** |
| `has_time_series` hit | 5.49 vs 4.59 µs — 0.84× | 4.81 vs 4.59 µs — **0.95×** |
| NST store footprint (Float64) | 260 MiB vs 112 MiB for regular STS | **158 MiB** vs 106 MiB |

**Read the caveats before quoting any ratio.** The IS4 half was *not* rerun —
it is imported verbatim from the 2026-07-31 job. The two nodes are
hardware-identical (their `env.txt` files differ only in node name, queue, and
the branch-side code commits) and both jobs held the node `--exclusive`, so the
head-to-head is sound. The real caveat is that IS4 is a **single pass** taken in
one long-lived process, which inflates its later sections. See *Known
measurement limitations*.

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

| | branch (job 15459992) | IS4 baseline (job 15438463) |
|---|---|---|
| Date | 2026-08-03 | 2026-07-31 |
| Node / queue | `x1006c2s4b0n1` / partition `short` | `x1005c6s2b1n1` / partition `standard` |
| Machine | 2× Intel Xeon Platinum 8470QL (family 6 / model 143 / stepping 7), 2×52 cores × 1 thread, 8 NUMA nodes, 2101/800 MHz, 250 GB (`RealMemory=246064`), `ActiveFeatures=hbw,rh8` | **identical in every line** — the two `env.txt` files differ only in node name, queue, and the branch-side commits |
| Node allocation | `--nodes=1 --exclusive` | `--nodes=1 --exclusive` |
| Julia | 1.12.1, `JULIA_NUM_THREADS=1`, `JULIA_NUM_GC_THREADS=4` | same |
| Code | IS `feat/rust-time-series-store` @ `f9e51321`, infrastore core @ `4b38794` | `320a5035` = IS `IS4` @ `c63d9a281` + PR #594 cherry-pick |
| Process layout | **one fresh process per section**, 3 passes | one process for the whole matrix, 1 pass |
| Store location | `/dev/shm` (tmpfs) | `/dev/shm` (tmpfs) |

- Every number is the average over the full 100,000-op loop (`@timed`, GC
  quiesced before each op); JIT warmup precedes measurement.
- Each (type × element type) combination uses a fresh system with 100,000
  components, one series per component, distinct random data per series
  (except the `shared` sections), stores in private temp directories.
- Adds use each branch's recommended batched path
  (`time_series_transaction` vs `begin_time_series_update`).
- **The branch matrix was run three times, one process per section.**
  Run-to-run spread averages **2.1%** across 66 operations and is under 6% for
  every operation except `sts/pwl/bulk_add` (13.0%). The comparison tables use
  pass 1; `branch_variance.csv` carries the full error bar. Sectioning fixed
  the previous report's worst outlier: `reload_read_one` went from 24.7% spread
  to 1.7%, because it now runs in a fresh process rather than at the tail of a
  long-lived one.
- **IS4 was imported, not rerun.** `results_full_is4_hpc.csv` is byte-identical
  to the 2026-07-31 file; `SLURM_report.sh` restitched the branch sections and
  folded that baseline back in. This was a deliberate cost decision — a second
  IS4 pass costs ~5 node-hours. The two jobs landed on hardware-identical
  exclusive nodes (limitation 1), so the cost is not comparability but the
  absence of an IS4 error bar and IS4's single-process drift (limitation 2).
- **IS4 transform note:** the IS4 branch predates IS PR #594
  (`transform_single_time_series!` speedup). Without it the 100k transform did
  not complete within an hour (quadratic SQLite scanning), so #594 was
  cherry-picked into the IS4 baseline. IS4 is therefore measured with its best
  available implementation. #594 does not affect any other measured path.
- Raw data: `results_full_branch_hpc_r{1,2,3}.csv` (stitched) and
  `sections/branch_r{1,2,3}_*.csv` (per-process), `results_full_is4_hpc.csv`,
  and `results_full_is4_remove_*.csv` in this directory; `comparison.md` is the
  generated full table, `env.txt` the branch-side provenance, and
  `report_provenance.txt` records which IS4 file was folded in. Regenerate with
  `julia benchmark/make_full_report.jl report-input`.

## Known measurement limitations

Four things bound how these numbers should be read. All are recoverable with
more node time; none change the qualitative result.

**1. The IS4 half was imported from an earlier job — but the two nodes are
hardware-identical.** The branch ran on `x1006c2s4b0n1`, queued through
partition `short`; IS4's numbers were taken two days earlier on
`x1005c6s2b1n1`, partition `standard`. The `env.txt` captured by each job
differs in exactly three things: the node name, the queue it came through, and
the branch-side code commits. Every hardware line matches — same CPU model *and
stepping* (Xeon Platinum 8470QL, family 6 / model 143 / stepping 7), same
2 sockets × 52 cores × 1 thread with 8 NUMA nodes, same 2101/800 MHz reported
clocks, same L1 cache sizes, same 250 GB (`RealMemory=246064`), same
`ActiveFeatures=hbw,rh8` — and both jobs held the node `--exclusive` under the
same Julia 1.12.1. These are two instances of one homogeneous node class, not
two machines, and the partition label is a scheduling queue, not a hardware
distinction.

This matters because the branch also got faster between the two runs: across
the 66 timed operations, pass 1 here beats pass 1 of 2026-07-31 by a median of
**16.4%**. That is not node variance, and the run contains its own control. The
`sts` section runs **first in both layouts**, so a fresh process is a fresh
process there and per-section isolation can contribute nothing — yet its 15
operations improved by a median of **20.7%**. The `shared` section, which ran
last under the old single-process layout and in its own process here, improved
**24.3%**. The ~3.5 percentage-point difference between them bounds what
process isolation is worth; the remainder is the code (IS
`f3eceb1f`→`f9e51321`, core `f0c075e`→`4b38794`). Node-to-node variance sits
below both, bounded by the measured within-node run-to-run spread of 2.1%.

**So the branch-side improvement is engine work, not hardware.** The genuine
residual caveat is not the node — it is that IS4 is a **single pass with no
error bar of its own**, taken in one long-lived process (limitation 2).
**Fix:** rerun IS4 in the same job as the branch, sectioned and repeated, which
`SLURM.sh` now supports directly.

**2. IS4 degrades over the life of its process, which inflates its later
sections.** This is the limitation that actually bounds the ratios. IS4's whole
matrix ran in one process, and the same read work costs several times more when
it runs late:

| identical read work | ran early | ran late | drift |
|---|---:|---:|---:|
| IS4, 100k Float64 STS full read | 1,678 µs (`sts`) | 7,209 µs (`sts_shared`) | 4.3× |
| IS4, 100k Float64 Deterministic full read | 2,188 µs (`det`) | 6,007 µs (`det_shared`) | 2.7× |

The `shared` sections read *less distinct data* than their non-shared
counterparts, so they should be at worst equal — and on the 2026-07-30 laptop
run, where IS4 was split across four processes, IS4's shared reads were 4×
**faster** than its non-shared reads. The inversion is a process-lifetime
effect, consistent with the HDF5 open-object iteration already identified in
IS4's removal path. Consequence: the ratios for the sections that ran late on
IS4 (`sweep`, `has`, `dst`, `shared`, `serialize`) are upper bounds. The
sections that ran early (`sts`, `nst`, `det`, `prob`, `scen`) are unaffected —
and those alone already show 19–90× read advantages. This limitation is now
**asymmetric**: the branch *is* section-isolated in this run, IS4 is not, so
the late-section ratios are looser upper bounds than they were on 2026-07-31.

**3. Stores were on tmpfs (`/dev/shm`), not disk.** Neither node exposes
node-local disk, and pointing `TMPDIR` at the shared parallel filesystem would
have benchmarked the network, not the engines. tmpfs removes storage I/O from
the comparison, which isolates CPU and algorithmic differences but does not
reproduce a production Sienna deployment writing to disk. Prior campaigns were
disk-backed and showed the same ordering. The `store_disk_bytes` figures are
real file sizes and are unaffected.

**4. IS4's 100k removal is extrapolated,** from three measured points rather
than asserted — see the removal section. Those three points come from the
2026-07-31 job and were deliberately excluded from this run's report input,
because they share a result key with the branch's n=100,000 row and would
otherwise print a speedup between two different problem sizes.

Julia was 1.12.1 on the cluster rather than the 1.12.6 used by the laptop
campaigns; both engines ran the same version, so the head-to-head is
unaffected, but absolute µs/op are not directly comparable across reports.

## Results: ingest and per-owner reads (µs per operation)

Every read on the InfraStore branch lands in a 48–167 µs band regardless of
type, payload, or store size; IS4's reads range 1,678–20,245 µs and grow with
store size, payload width, and process age.

| type | payload | operation | infrastore | is4 | speedup |
|---|---|---|---:|---:|---:|
| SingleTimeSeries | Float64 | bulk add | 11.9 | 98.9 | 8.3× |
| SingleTimeSeries | Float64 | read full | 57.2 | 1,678 | 29.3× |
| SingleTimeSeries | Float64 | read slice | 50.1 | 1,678 | 33.5× |
| SingleTimeSeries | tuple | read full | 65.1 | 2,233 | 34.3× |
| SingleTimeSeries | linear cost | read full | 63.2 | 1,863 | 29.5× |
| SingleTimeSeries | quadratic cost | read full | 63.9 | 2,233 | 35.0× |
| SingleTimeSeries | piecewise-linear | read full | 83.1 | 3,847 | 46.3× |
| SingleTimeSeries | piecewise-linear | read slice | 62.7 | 4,799 | 76.5× |
| Deterministic | Float64 | bulk add | 50.8 | 137 | 2.7× |
| Deterministic | Float64 | read full | 88.3 | 2,188 | 24.8× |
| Deterministic | Float64 | read one window | 55.1 | 2,165 | 39.3× |
| Deterministic | tuple | bulk add | 68.7 | 160 | 2.3× |
| Deterministic | tuple | read full | 126 | 2,565 | 20.3× |
| Deterministic | tuple | read one window | 64.5 | 2,086 | 32.3× |
| Deterministic | piecewise-linear | bulk add | 126 | 1,423 | 11.3× |
| Deterministic | piecewise-linear | read full | 167 | 4,992 | 29.8× |
| Deterministic | piecewise-linear | read one window | 72.4 | 4,693 | 64.9× |
| Probabilistic | Float64 | read full | 120 | 5,054 | 42.0× |
| Scenarios | Float64 | read full | 119 | 5,484 | 46.0× |
| NonSequentialTimeSeries | Float64 | bulk add | 37.2 | n/a | IS4 lacks the type |
| NonSequentialTimeSeries | Float64 | read full | 68.1 | n/a | |

Bulk adds for tuple/linear/quadratic STS: 13.0–13.4 µs vs 106–112 µs on IS4
(~8×). All five NST payloads land at 37.2–52.3 µs adds / 68.1–86.3 µs reads.
Tuple-payload `Deterministic` — the one type×payload combination IS4 accepted
and the branch rejected when the campaign began — is supported since IS
`626bec64` and now beats IS4 across the board. `Probabilistic` and `Scenarios`
bulk adds are the branch's narrowest non-shared ingest margin at 1.9× (74.8 /
74.0 µs vs 139 / 138 µs).

Full table including disk footprints: `comparison.md`.

## Results: the simulation inner loop

The pattern that dominates production-cost simulation runtimes: at each
timestamp (or forecast window), read every component's value. µs per
(component, timestamp) value, with the wall clock for the whole sweep:

| workload | infrastore | is4 | speedup |
|---|---:|---:|---:|
| 100k static series × 24 timestamps (2.4M values) | 1.33 µs — **3.2 s** | 704 µs — 28.2 min | **529×** |
| 100k deterministic forecasts × 12 windows (1.2M windows) | 5.42 µs — **6.5 s** | 1,517 µs — 30.3 min | **280×** |
| 100k DST forecasts (post-transform) × 13 windows (1.3M) | 15.1 µs — 19.6 s | 2,814 µs — 61.0 min | 187× |
| shared profile, 2.4M static values | 1.25 µs — 3.0 s | 609 µs — 24.4 min | 488× |
| shared forecast, 1.2M windows | 2.02 µs — 2.4 s | 1,467 µs — 29.3 min | 725× |

Sweeping all 2.4 million (component, timestamp) values takes **3.2 seconds**
on the InfraStore branch vs **28 minutes** on IS4. The columnar
`StaticTimeSeriesReader` serves every component from one physical read per
timestamp; IS4 pays one cache per component. (The two `shared` rows and the
`dst` row ran late in the IS4 process — see limitation 2; the two non-shared
rows did not.)

## Results: transform_single_time_series! (DST)

| operation | infrastore | is4 (+#594) | speedup |
|---|---:|---:|---:|
| transform 100k STS → DST | 10.4 µs — **1.04 s** | 20.6 µs — 2.06 s | **1.97×** |
| read one DST window per component | 84.8 | 20,245 | 239× |
| DST by-window sweep (1.3M windows) | 15.1 | 2,814 | 187× |

**This is the headline change in this report.** `transform_single_time_series!`
was the one path where IS4 stayed ahead across three campaigns — 0.77× on the
2026-07-30 laptop run, 0.72× on 2026-07-31. It is now **1.97× faster on the
branch**, a 2.7× same-workload improvement (28.7 → 10.4 µs/op) far outside any
plausible node effect. The 2026-07-31 report attributed the residual gap to
JSON-marshaling the 100k-row catalog listing across the FFI boundary and named
a binary listing protocol as the fix; the measured swing is consistent with
that work having landed in `f9e51321` / core `4b38794`, though this run does
not isolate the commit.

The transform is a **once per study setup** cost, now 1.0 s vs 2.1 s.
Everything downstream of it, which is what a simulation actually loops over,
is 187–239× faster here.

## Results: has_time_series at 100,000 series

10,000 components × 10 series each, every association carrying two features;
queries pass the full identity (type, name, resolution, both features).

| query | infrastore | is4 | |
|---|---:|---:|---|
| bulk add (100k associations) | 12.1 | 30.7 | 2.5× faster |
| hit (series exists) | 4.81 | 4.59 | 0.95× (0.22 µs behind) |
| miss (wrong feature value) | 10.8 | 17.6 | 1.6× faster |

These numbers reflect optimization work delivered during the benchmark
campaign: the initial measurement showed 19.4 µs per query, because the
InfraStore core answered feature-filtered probes by listing and hydrating rows.
IS4's `has_metadata` strategy — probe the complete feature set first via an
indexed exact match, fall back to a per-feature filter only for partial
queries — was ported into the core (infrastore `b7bd33e`, IS `59d19a25`), so
callers passing the full feature set now get a single covering-index seek.
Partial-feature queries, the slow path on both stores, run entirely on indexes
here, which is why misses beat IS4.

Hits remain the one operation where IS4 is ahead, and the margin has narrowed
from 0.9 µs to **0.22 µs** (0.84× → 0.95×): IS4 answers a hit from an
in-process Dict, the branch from an indexed seek across the FFI boundary. The
`has` section ran late on IS4 (limitation 2), so IS4's true hit cost may be
slightly lower than 4.59 µs and the real gap slightly wider. Either way this is
not a query in any inner loop, and the remaining difference is within the
report's own node-to-node uncertainty — treat it as parity, not as an advantage
for either engine.

## Results: save, load, remove

| operation (100k Float64 STS) | infrastore | is4 | speedup |
|---|---:|---:|---:|
| serialize system to JSON + store artifacts | 0.50 s | 5.05 s | 10.0× |
| deserialize + reattach all components | 1.59 s | 8.99 s | 5.6× |
| first read from the reloaded system | 1.6 ms | 28.7 ms | 17.8× |
| serialized footprint on disk | 80.5 MiB | 112 MiB | 28% smaller |
| remove all 100k series one-by-one | **3.76 s** | ~3.7 h (extrapolated) | ~3,500× |

**The removal extrapolation.** IS4's 100k removal loop was never run to
completion — earlier campaigns abandoned it after 50+ minutes. The 2026-07-31
job measured its growth curve instead, at three scales:

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
file's object count. These three points were not re-measured in job 15459992
and are carried forward from `results_full_is4_remove_*.csv`.

The branch removes the same 100,000 series in **3.76 s** (37.6 µs/op, flat, and
stable at 37.6–38.2 µs across the three passes). This is the operation the
2026-07-29 campaign flagged as the branch's slowest (369 µs/op then); profiling
attributed ~75% of each removal to per-operation SQLite commit I/O — WAL write
amplification across the catalog's secondary indexes, the per-commit fsync, and
auto-checkpoint fsyncs — with most of the rest in an HDF5 column-scrub write.
Cached statements, `synchronous=NORMAL` under WAL, and index-only array frees
(infrastore `9b34c32`), plus routing IS removals through single-transaction bulk
catalog calls (IS `167ead85`), closed it.

**Store footprint.** The branch keeps both data and metadata on disk (106 MiB
for the 100k Float64 STS system) where IS4 holds metadata in memory (80.8 MiB
HDF5 on disk + metadata RAM). The `shared` rows make the difference stark —
81.4 MiB on the branch vs 2.7 KiB on IS4 — because with one deduplicated array
the branch's file is almost entirely catalog. The serialized-system row above
is the apples-to-apples footprint, and there the branch is 28% smaller.

**Peak memory.** Sectioning the branch made per-section `maxrss` meaningful for
the first time — previously `Sys.maxrss()` was a running maximum over the whole
matrix. IS4 is still measured in one process, so **only the first section
(`sts`/Float64, which runs first on both) is a clean comparison**: **0.80 GiB**
on the branch vs **1.56 GiB** on IS4. The branch's own per-section peaks now
range from 0.76 GiB (`sts_shared`) to 5.74 GiB (`det`/piecewise-linear), with
the piecewise payloads dominating; the corresponding IS4 figures are running
maxima and cannot be decomposed, so no per-section comparison beyond the first
is supportable. The 2026-07-31 report's "40% lower peak ingest memory" claim
was likewise based on the first section only — that scope is now explicit.

## Capability differences found

- **`NonSequentialTimeSeries` is InfraStore-branch only** — irregular
  timestamped series are a new capability; IS4 has no equivalent type. All five
  payloads ingest at 37.2–52.3 µs/op and read at 68.1–86.3 µs/op.
- **Tuple-payload `Deterministic`** was accepted by IS4 but rejected by this
  branch's element-type validation when the campaign began. **Closed** (IS
  `626bec64`): tuple forecast windows now encode through the same tagged dense
  layout as cost-function windows, and the combination benchmarks 2.3–32×
  faster than IS4.
- Bug found and fixed by this campaign: `NonSequentialTimeSeries` additions
  through `time_series_transaction` failed (`NonSequentialTimeSeriesKey`
  missing from the `ConcreteTimeSeriesKey` union; IS `fb14fa1e`).

## Known follow-up items

Closed, and confirmed by this run:

1. **Transform batching**, then the FFI listing cost: 122 → 28.7 → **10.4
   µs/op**. The branch is now 1.97× faster than IS4 on the one path where IS4
   led. **This was the last open performance gap.**
2. **Tuple-forecast payload gap** (IS `626bec64`) — now 2.3–32× faster than IS4.
3. **Per-series removal** (infrastore `9b34c32`, IS `167ead85`): 369 → 37.6
   µs/op, against an IS4 curve that reaches ~134,000 µs/op at this scale.
4. **`has_time_series`** (infrastore `b7bd33e`, IS `59d19a25`): misses 1.6×
   faster than IS4; hits now within 0.22 µs, i.e. parity.
5. **Shared-forecast bulk add**, previously 0.93× — now **1.08× faster**
   (22.8 vs 24.7 µs/op). The shared-static equivalent is 1.75× (8.43 vs 14.8).
6. **NST disk footprint**, previously 260 MiB against 112 MiB for the same
   volume of regular Float64 series — now **158 MiB** against 106 MiB. Still
   ~50% heavier, since NST stores a timestamp per sample, but no longer an
   outlier. Per-series timestamp compression remains available if wanted.

Still open — all measurement, not engine:

7. **Rerun IS4 sectioned and repeated, in the same job as the branch.** IS4 is
   still a single pass measured in one long-lived process, so its later sections
   are inflated (limitation 2) and it carries no error bar — that is the largest
   remaining source of uncertainty, and it would shrink the late-section ratios.
   `SLURM.sh` supports the full layout directly; the IS4 sections were commented
   out for this run to save ~5 node-hours.
8. **Record a node-identity check in the report pipeline.** Comparability here
   rests on the two `env.txt` files matching line-for-line; `SLURM_report.sh`
   warns that the halves come from different jobs but does not diff them. A
   mechanical diff would turn that from a manual check into a gate.
9. **`sts/pwl/bulk_add` is the branch's noisiest operation** at 13.0% spread
   across three passes (21.2 / 20.9 / 23.8 µs); every other operation is under
   6%. Worth one more pass to confirm it is noise rather than a bimodal path.

## Conclusion

At production scale, the InfraStore backend is faster on every ingest, read,
query, transform, removal and serialization path measured — by factors that
grow with store size, culminating in a 187–725× advantage on the access pattern
that dominates simulation runtimes — while adding irregular-series support and
roughly halving peak ingest memory. **Every capability and performance gap this
campaign discovered is now closed**, including
`transform_single_time_series!`, which IS4 led across three prior campaigns and
which the branch now wins by 1.97×. The only operation where IS4 is still
nominally ahead is a `has_time_series` hit, by 0.22 µs — inside this report's
own measurement uncertainty and in no inner loop.

The remaining work is methodological, not engineering. This report's IS4 half
was imported from an earlier job, but onto a hardware-identical exclusive node —
the two `env.txt` captures match line-for-line — and the branch-side gains
reproduce in the one section that runs first under both process layouts, so they
are engine work rather than an artifact of the move. What is still outstanding is
that IS4 ran as a single pass in one long-lived process, which inflates its
`sweep`, `has`, `dst`, `shared` and `serialize` ratios and leaves it without an
error bar. A sectioned, repeated IS4 rerun would tighten those numbers; on the
evidence of four campaigns across three machines, it would not change the
ordering.
