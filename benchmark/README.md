# Time series benchmarks: InfraStore branch vs IS4

Comparison of `add_time_series!` / `get_time_series` between
`feat/rust-time-series-store` (InfraStore backend) and the `IS4` branch
(HDF5 + SQLite backend), measured 2026-07-25 on macOS (Julia 1.12.6).

Workload: `SingleTimeSeries`, 24 steps, `Float64`, `Hour(1)` resolution, one
series per `TestComponent`, disk-backed stores (defaults for both branches).

- **non-shared**: every component gets a distinct random array.
- **shared**: one `SingleTimeSeries` instance added to every component
  (IS4 dedups by UUID; InfraStore by content hash).

## Files

| file | purpose |
|---|---|
| `bench_common.jl` | shared driver: builds the system, times add/get/sliced-get |
| `bench_branch.jl` | entry point for this branch (`julia --project=test`, needs `INFRASTORE_LIB`) |
| `bench_is4.jl` | entry point for IS4 (needs an env with IS4 dev'd + TimeSeries) |
| `bench_branch_scaling.jl` | chunked marginal-cost sweep for this branch (per-1000-op timing) |
| `results_is4.csv` | IS4 full 100k-series run |
| `results_scaling.csv` | this branch's 20k marginal-cost sweep (pre-fix, per-add path) |
| `bench_bulk.jl` | post-fix benchmark: `bulk_add_time_series!` (AddBatch path) + reads |
| `results_bulk_postfix.csv` | this branch's 100k run after the AddBatch/read-path fixes |

Run:

```sh
INFRASTORE_LIB=/path/to/libinfrastore_ffi.dylib BENCH_N=100000 julia --project=test benchmark/bench_branch.jl
BENCH_N=100000 julia --project=<is4-env> benchmark/bench_is4.jl
```

## Results (2026-07-25, pre-fix baseline)

IS4 at 100,000 series (average µs/op over the full run):

| scenario | add | get (full) | get (sliced len=12) |
|---|---:|---:|---:|
| non-shared | 4,173 | 9,318 | 9,164 |
| shared | 16 | 8,695 | 9,141 |

IS4 degrades with N on both paths (252 µs/add and 187 µs/get at N=500).

InfraStore branch, marginal µs/op at store size (per-add path, before the
`AddBatch` bulk fix):

| store size | add non-shared | add shared | get full | get shared |
|---:|---:|---:|---:|---:|
| 1,000 | 1,398 | 497 | 209 | 74 |
| 9,000 | 22,546 | 612 | 212 | 70 |
| 19,000 | 47,374 | 451 | 210 | 74 |

Key observations:

1. **Reads on the InfraStore branch are flat with store size** (~210 µs
   non-shared, ~72 µs shared) vs IS4's ~9 ms at 100k — a 40-100× win at scale.
2. **Per-add (un-managed) writes on the InfraStore branch scale O(N) per add**
   (≈ 2.5 µs × store size; O(N²) total — a 100k non-shared build projects to
   ~3.5 h). Cause: the Rust core's incremental write packs each array into a
   shared NetCDF dataset via a per-column read-modify-write. The fix is the
   batch path: `bulk_add_time_series!` now stages onto a `InfraStore.AddBatch`
   and commits once (whole-chunk block writes, one metadata transaction).
3. **Shared adds**: InfraStore ~500 µs (content hashing + association insert) vs
   IS4 16 µs (metadata row only). Partially addressed by dropping the per-add
   existence pre-check; the remaining gap is FFI encode + hashing.

## Results after the fixes (same day, 100,000 series)

`bulk_add_time_series!` staged onto a `InfraStore.AddBatch` (one commit,
whole-chunk block writes); reads via key validation + server-side `time_range`
slicing (no full-array materialization, no redundant catalog queries):

| scenario | bulk add | get (full) | get (sliced len=12) |
|---|---:|---:|---:|
| non-shared | 17.6 | 94.7 | 88.4 |
| shared | 8.2 | 93.6 | 87.8 |

(µs/op; totals: non-shared bulk add 1.76 s, full read of all 100k in 9.5 s.)

vs IS4 at the same scale: adds 238× faster (non-shared), reads ~98× faster,
and both stay flat with store size. The O(N²) build is gone; per-add
(`add_time_series!` one at a time) still takes the un-managed Rust write path
and remains O(N) per call — prefer `bulk_add_time_series!` for large ingests
until the core's incremental write is fixed.
