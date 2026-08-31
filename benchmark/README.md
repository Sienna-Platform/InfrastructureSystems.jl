# Time series benchmarks

A single suite, `bench.jl`, covering the ingest and read paths that matter to
the rest of the platform. The default run takes **under a minute** (58 s on the
reference machine below, ~30 s of which is Julia startup and JIT).

```sh
export INFRASTORE_LIB=/path/to/libinfrastore_ffi.dylib
julia --project=test benchmark/bench.jl > /tmp/results.csv
julia --project=test benchmark/report.jl /tmp/results.csv
```

`report.jl` diffs a run against `baseline.csv` and exits non-zero if any op
regressed past the threshold (default 40% — see Noise below), so it can gate CI.

```sh
# explicit paths and a tighter threshold, for a same-session A/B
julia --project=test benchmark/report.jl /tmp/after.csv /tmp/before.csv 0.15
```

To refresh the baseline after an intentional performance change, commit a fresh
`bench.jl` run as `benchmark/baseline.csv` and say so in the commit message.

## What is measured

One CSV row per (kind, eltype, op): `kind,eltype,op,n,total_s,us_per_op,bytes,status`.
Each op is timed with `@timed` after a `GC.gc()`, and a JIT warmup pass over
every section precedes measurement. A combo the store rejects is recorded as an
`error:` row rather than aborting the run.

| section | what it covers | n |
|---|---|---|
| `ingest` | `bulk_add` of every time series type × element type: `SingleTimeSeries`, `NonSequentialTimeSeries`, `Deterministic` × {float64, ntuple2, linear, quadratic, pwl}, plus `Probabilistic` and `Scenarios` (float64) | `BENCH_N` |
| `sweep` | the simulation inner loop — every component read at one timestamp (`StaticTimeSeriesReader`) or one window (`ForecastReader`). float64 at full scale; pwl exercises the structured-payload decode that PSY's time-varying cost curves read through | `BENCH_SWEEP_N` (pwl at `BENCH_N`) |
| `has` | `has_time_series` with the full identity (type, name, resolution, two features), hits and misses. `n` counts **associations**: `BENCH_SWEEP_N ÷ 10` components × 10 associations each (2 names × 5 scenario values, plus a `model_year` feature) | `BENCH_SWEEP_N` |
| `reads` | per-series read canary: `get_full`, `get_sliced`, `get_window`, and `get_metadata` — the keyed catalog fetch, one primary-key row lookup with no array read, against `get_full`'s filtered resolve plus read. float64 only | `BENCH_N` |
| `dst` | `transform_single_time_series!` to `DeterministicSingleTimeSeries` plus the window sweep over the result — the PowerSimulations feed path | `BENCH_N` |
| `serialize` | `to_json` / `from_json` round-trip including the store artifacts, verified with one read from the reloaded system | `BENCH_N` |
| `remove` | `remove_time_series!` of every series, one call per component | `BENCH_N` |
| `scaling` | the same ingest at two store sizes. µs/op must stay flat — a rising ratio means per-op cost that grows with store size, the O(N²) failure mode the storage rewrite removed | `BENCH_N` and `BENCH_SCALING_N` |
| `shared` | **opt-in**: one instance added to every component (deduplicated storage), with reads and sweeps | `BENCH_N` |

Reader construction (`build_static_reader` / `build_forecast_reader`, µs per
entry) is timed separately from the sweep it feeds (`read_by_timestamp` /
`read_by_window`). It is a one-time O(entries) catalog query — a simulation
builds one reader and sweeps thousands of timesteps through it — and it is large
enough to swamp the read cost if the two are bundled: at 100k entries the reader
build is ~1.7 s against ~0.36 s for a 24-step sweep.

**Read the sweep rows together with their `*_storage_read` row.** The sweep row
is amortized per *(component, timestep)* pair — `n` is components × timesteps,
so 100k components × 12 windows = 1,200,000 — which makes it a throughput
figure, not the cost of a read. The columnar reader issues **one storage read
per timestep for all components**, and `timestamp_storage_read` /
`window_storage_read` report those directly (`n` = the number of reads, µs
each). At 100k components:

| | reads | each | slab | share of sweep |
|---|---:|---:|---:|---:|
| `sts` by timestamp | 24 | 12.5 ms | 0.8 MB | 82% |
| `det` by window | 12 | 86.9 ms | 9.2 MB | 75% |
| `dst` by window | 13 | 130 ms | derived | 98% |

So a `read_by_window` of 1.16 µs/op is 1.39 s ÷ 1,200,000, of which 1.04 s is
twelve real reads of 9.2 MB each. The I/O is present and dominant; it is spread
over 100,000 components per read.

These are **first-touch** reads — each timestep is read once, never re-read,
which is how a simulation walks forward through time. Re-sweeping the same
windows is ~3× cheaper (0.36 µs/op for `det`), and that warm number is the one
to quote only if the consumer really does re-read the same timesteps.

The `has` section builds its associations from just **2 distinct arrays**, which
the store deduplicates by content — its `.h5` stays at ~9 KB whatever `n` is.
So `bulk_add_associations` measures association and feature-set writes, not array
writes, and its µs/op is not comparable to the ingest matrix's `bulk_add`, where
every op stores a distinct array. The op is named differently for that reason.

`store_disk_bytes` rows record each store's on-disk footprint (every system gets
a private temp directory); `maxrss` rows record process peak RSS after an
ingest, and are monotone, so only the first combo in a process attributes
cleanly. Neither participates in the regression check.

## Noise

Two distinct classes, measured on the reference machine:

- **Stable ops** — `sts` ingest, `has_time_series`, the sweeps, the scaling
  canary: within ±2% run to run, and within ±8% across sessions.
- **Write-heavy ops** — `nst` / `det` / `prob` / `scen` ingest, `remove`: within
  ±8% back to back, but observed to swing up to **35% between sessions**. These
  allocate 75–600 MB per op and are bound by GC and page-cache state, not by the
  code under test.

The 40% default threshold is sized for the second class. Back-to-back runs in
one session are far tighter, so for an A/B of two commits — build both, run both
without leaving the session — pass a lower threshold:

```sh
julia --project=test benchmark/report.jl /tmp/after.csv /tmp/before.csv 0.15
```

That is the comparison to trust for a change you expect to be small. A diff
against the committed `baseline.csv` taken on another day answers a coarser
question: did anything fall off a cliff.

## Knobs

| variable | default | effect |
|---|---|---|
| `BENCH_KINDS` | `ingest,sweep,has,reads,dst,serialize,remove,scaling` | comma list of sections; add `shared` for the dedup path |
| `BENCH_ELTYPES` | `float64,ntuple2,linear,quadratic,pwl` | element types in the ingest matrix |
| `BENCH_N` | `10000` | ingest matrix and capability sections |
| `BENCH_SWEEP_N` | `100000` | the sweeps and `has` — production scale, where the columnar readers earn their keep |
| `BENCH_SCALING_N` | `100000` | upper point of the scaling canary |
| `BENCH_LEN` | `24` | steps per static series |
| `BENCH_WINDOWS` / `BENCH_HORIZON` | `12` / `12` | forecast windows and steps per window |
| `BENCH_NP` | `5` | points per piecewise-linear curve |

Cost is linear in `n`, so the 10k default is enough to catch a throughput
regression and `scaling` guards the superlinear case. For a higher-signal run
(roughly 75 s), raise the matrix scale:

```sh
BENCH_N=25000 julia --project=test benchmark/bench.jl > /tmp/results.csv
```

Baselines are only comparable at matching `BENCH_N` / `BENCH_SWEEP_N`; the
committed `baseline.csv` is a defaults run.

## Storage configuration

The suite measures a **disk-backed** store: `SystemData` defaults to
`time_series_in_memory = false`, so arrays go to `<dir>/<uuid>_time_series.h5`
and only the SQLite catalog is held in RAM (`catalog = :memory`, see
`TimeSeriesManager`). Each system gets a private temp directory, and the
`store_disk_bytes` rows show the resulting `.h5` — e.g. 24.5 MB for 100k × 24
`Float64`, against 19.2 MB of raw payload.

Sweep numbers look small per value because the columnar reader does **one `.h5`
read per timestep for all entries**, not one per component — see the storage
read table above for what the actual reads cost. Reads are served through the OS
page cache, as they would be in production; these are not cold-media numbers.

## Reference machine

`baseline.csv` was measured 2026-08-22 on an Apple M2 Pro (32 GB, macOS 26.6.2),
Julia 1.12.7, infrastore @ `82a3e70`. Absolute numbers are machine-specific —
compare a run against a baseline taken on the same machine.
