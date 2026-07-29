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
| `bench_bulk.jl` | post-fix benchmark: batched adds via `time_series_transaction` (AddBatch path) + reads |
| `results_bulk_postfix.csv` | this branch's 100k run after the AddBatch/read-path fixes |
| `bench_costs_common.jl` | shared driver for FunctionData (cost) payloads: STS + Deterministic, add/read |
| `bench_costs_branch.jl` | cost-payload entry point for this branch (adds via `time_series_transaction`) |
| `bench_costs_is4.jl` | cost-payload entry point for IS4 (adds via `begin_time_series_update`) |
| `results_costs_branch.csv` | this branch's 10k cost-payload run (netcdf backend) |
| `results_costs_is4.csv` | IS4's 10k cost-payload run |
| `results_costs_hdf5.csv` | this branch's 10k cost-payload run, `INFRASTORE_BACKEND=hdf5` spike |
| `results_bulk_hdf5.csv` | this branch's 100k float run, `INFRASTORE_BACKEND=hdf5` spike |
| `results_scaling_hdf5.csv` | per-add (un-managed path) 20k sweep on the hdf5 backend |
| `results_costs_postfix.csv` | 10k cost-payload run after netcdf removal + read fixes (current state) |

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
   batch path: adds staged inside a `time_series_transaction` block land on an
   `InfraStore.AddBatch` and commit once (whole-chunk block writes, one
   metadata transaction).
3. **Shared adds**: InfraStore ~500 µs (content hashing + association insert) vs
   IS4 16 µs (metadata row only). Partially addressed by dropping the per-add
   existence pre-check; the remaining gap is FFI encode + hashing.

## Results after the fixes (same day, 100,000 series)

Adds staged onto an `InfraStore.AddBatch` inside a `time_series_transaction`
block (one commit, whole-chunk block writes); reads via key validation +
server-side `time_range` slicing (no full-array materialization, no redundant
catalog queries). (Measured via the then-named `bulk_add_time_series!`, since
replaced by `time_series_transaction` — same AddBatch path, so the numbers
carry over.)

| scenario | bulk add | get (full) | get (sliced len=12) |
|---|---:|---:|---:|
| non-shared | 17.6 | 94.7 | 88.4 |
| shared | 8.2 | 93.6 | 87.8 |

(µs/op; totals: non-shared bulk add 1.76 s, full read of all 100k in 9.5 s.)

vs IS4 at the same scale: adds 238× faster (non-shared), reads ~98× faster,
and both stay flat with store size. The O(N²) build is gone; per-add
(`add_time_series!` one at a time) still takes the un-managed Rust write path
and remains O(N) per call — batch large ingests inside a
`time_series_transaction` block until the core's incremental write is fixed.

## Cost-function (FunctionData) payloads (2026-07-28, 10,000 series)

> Historical: measured on the removed netcdf backend, before the read-path
> fixes. Current numbers are in "Cost payloads rerun on the final build"
> below.

Workload (`bench_costs_*.jl`): per `TestComponent`, either a 24-step
`SingleTimeSeries` or a 12-window x 12-step `Deterministic`, with
`LinearFunctionData`, `QuadraticFunctionData`, or 5-point
`PiecewiseLinearData` elements. Both sides use their recommended batched-add
path (`time_series_transaction` here, `begin_time_series_update` on IS4), so
unlike the float benchmark above, IS4 adds are measured with the HDF5 handle
held open and one SQLite transaction. `BENCH_N=10000`; µs/op.

Run:

```sh
INFRASTORE_LIB=... BENCH_N=10000 julia --project=test benchmark/bench_costs_branch.jl
BENCH_N=10000 julia --project=<is4-env> benchmark/bench_costs_is4.jl
```

Non-shared (distinct data per component), PiecewiseLinearData:

| kind | op | infrastore | is4 | speedup |
|---|---|---:|---:|---:|
| STS | bulk add | 68 | 97 | 1.4× |
| STS | get full | 129 | 1,348 | 10.5× |
| STS | get sliced (len=12) | 121 | 1,308 | 10.8× |
| Deterministic | bulk add | 3,659 | 1,332 | **0.36× (slower)** |
| Deterministic | get full | 258 | 1,626 | 6.3× |
| Deterministic | get window | 239 | 1,396 | 5.8× |

Linear/Quadratic payloads follow the same pattern (STS reads ~126 µs flat on
this branch vs 412–1,050 µs on IS4; forecast reads ~245 µs vs 545–1,301 µs).
IS4 read costs also grow with element width (linear → quadratic → pwl) and
with store size, while this branch's stay flat across all three payloads.

Key observations:

1. **Reads are payload-independent on this branch** (~120–130 µs STS,
   ~240–260 µs forecast, non-shared) — 6–11× faster than IS4 at 10k and the
   gap widens with N since IS4 reads degrade with store size.
2. **Non-shared `Deterministic` bulk adds are a real regression**: ~3.3–3.7 ms
   per forecast on this branch vs 0.12–1.3 ms on IS4. The cost is flat across
   payload types (linear ≈ quadratic ≈ pwl), i.e. per-array overhead in the
   AddBatch path for distinct 3-D forecast arrays, not data volume. Shared
   forecast adds (one deduped array) are fast (78–346 µs), so the overhead is
   in the array write, not the association insert.

   **Root cause (profiled 2026-07-28, InfraStore core):** dense forecasts are
   exempt from the packed-block path — `flush_bulk_add` writes each one as its
   own standalone NetCDF variable (`put_standalone`: new dims + new var + data
   write, per forecast). Each define-mode switch makes the following
   `NC4_put_vars` run netcdf-c's implicit `sync_netcdf4_file` → `H5Fflush` →
   `H5D_flush_all`, which iterates every dataset already in the file — O(vars)
   per forecast, O(N²) per ingest. 82% of a 12k-forecast commit is inside
   `H5Fflush`. Measured at the InfraStore level (12×12 Float64 forecasts,
   commit only): 385 µs/op into a fresh store vs 1,898 µs/op into a store
   already holding 4,000 forecasts, same batch size — while packed STS commits
   stay flat at ~13 µs/op. Fix belongs in infrastore-core: pack same-shape
   dense forecasts into shared block datasets like STS (layout is a write-time
   policy only, reads are chunk-agnostic), or at minimum split the bulk commit
   into define-all-then-write-all phases so each batch pays one sync instead
   of one per forecast.
3. **Shared adds still favor IS4** (~11–18 µs metadata-only row vs
   10–345 µs content-hash dedup here), consistent with the float benchmark.
4. Allocation: IS4's pwl forecast ingest allocates 7.1 GB (HDF5 transform
   round-trip) vs 1.5 GB here.

## Direct-HDF5 backend spike (2026-07-28, infrastore `spike/hdf5-backend`)

The forecast O(N²) traced to netcdf-c's define-mode semantics (see above), so
the spike adds an `Hdf5Backend` to infrastore-core: identical logical layout
(packed `sts_*` datasets for STS, standalone `arr_<hash>` per dense forecast),
driven by libhdf5 directly via `hdf5-metno`. Select it with
`INFRASTORE_BACKEND=hdf5` (Julia binding kwarg `Store(; backend=:hdf5)`);
`open_store` sniffs the backend from the file. Full IS suite passes on both
backends. Two performance-critical details found on the way:

1. Small standalone arrays use HDF5's **compact layout** (data in the object
   header, no chunk B-tree): 12.1 MB for 8k forecasts vs 43.5 MB on netcdf.
2. HDF5's chunk cache lives per *open dataset handle*, so the backend holds
   handles open for the store's lifetime (as netcdf-c does with variables) and
   sets a 64 MiB file-level cache. Without this, packed column reads re-inflate
   every chunk per call (pwl STS reads were 20× slower).

Cost payloads, non-shared, N=10k (µs/op; `results_costs_hdf5.csv`):

| kind | op | hdf5 | netcdf | is4 |
|---|---|---:|---:|---:|
| STS pwl | bulk add | 64 | 68 | 97 |
| STS pwl | get full | 137 | 129 | 1,348 |
| Det linear | bulk add | **107** | 3,255 | 118 |
| Det quadratic | bulk add | **113** | 3,425 | 116 |
| Det pwl | bulk add | **401** | 3,659 | 1,332 |
| Det pwl | get full | 188 | 258 | 1,626 |
| Det pwl | get window | 142 | 239 | 1,396 |

Float STS at 100k (`results_bulk_hdf5.csv` vs `results_bulk_postfix.csv`):
bulk add 15.8 vs 17.6, get full 124 vs 94.7, get sliced 117 vs 88.4 — writes at
parity, full/sliced reads ~30 µs/op behind netcdf at this scale (worth a look
if the spike is adopted, likely per-read selection/allocation overhead in the
read helpers).

InfraStore-level probes (12×12 f64 forecasts): commit **42.5 µs/op flat** with
batch size (500→8k) and store size (fresh vs 4k existing) — netcdf degrades
337 → 1,903 µs/op over the same range; store open 0.005 s vs 1.34 s at 8k
forecasts.

Bottom line: the hdf5 backend removes the forecast-ingest O(N²) *without*
packing forecasts (each stays its own dataset), fixes open-time and file-size
overhead, and matches or beats the netcdf backend everywhere except a modest
gap on 100k-scale packed float reads.

## Backend decision head-to-head (2026-07-29)

Follow-up measurements to close the open questions before keeping a single
backend in infrastore. Same environment as above (macOS, Julia 1.12.6,
infrastore `spike/hdf5-backend`, IS `feat/rust-time-series-store`).

### 1. The 100k packed-float read gap was a measurement artifact

The 2026-07-28 table above compared `results_bulk_hdf5.csv` (hdf5, 07-28)
against `results_bulk_postfix.csv` (netcdf, 07-25) — three days and several IS
commits apart (InfraStore v0.3.0 upgrade, `has_time_series` change). Re-measured
both backends on identical code the same day (100k float STS, 4 full read
passes of all 100k series each = 400k reads per backend):

| backend | get full (µs/op, 400k-read avg) |
|---|---:|
| netcdf | 127.4 |
| hdf5 | 129.1 |

Parity (1.3%, within pass-to-pass noise: netcdf passes ranged 123–137,
hdf5 125–129). There is no hdf5 read regression to fix.

`sample`-profiles of both read loops are near-identical, which is why parity is
expected: both backends bottom out in the same libhdf5 `H5Dread` machinery
(netcdf-c is a wrapper over it). Shared per-read cost structure at 100k,
as a fraction of wall time (~12.4–12.5k samples each):

- ~36–38% Julia/IS side (key validation, TimeArray construction, FFI marshal);
- ~19–21% SQLite metadata — **`MetadataStore::get_by_key` runs twice per
  read** (once from `infrastore_store_get_single`, once inside
  `Store::get_time_series`), and every query pays `btreeBeginTrans` +
  `sqlite3PagerSharedLock`, including a `stat()` syscall per read;
- ~14–16% backend read; inside `H5Dread` the time is selection bookkeeping
  (`H5D__chunk_io_init` hyperslab copies, skip-list alloc/free) plus a
  per-read `H5Pcreate`, not data movement.

None of this differentiates the backends; the double metadata lookup and the
per-query SQLite transaction overhead are the top backend-independent
optimization targets for the read path (potentially ~2× on 24-step reads).

### 2. Un-managed per-add path: hdf5 is flat, netcdf is O(N)

`bench_branch_scaling.jl` with `INFRASTORE_BACKEND=hdf5`
(`results_scaling_hdf5.csv`) vs the netcdf run (`results_scaling.csv`),
non-shared adds, marginal µs/op:

| store size | netcdf | hdf5 |
|---:|---:|---:|
| 1,000 | 1,398 | 782 |
| 5,000 | 11,865 | 701 |
| 10,000 | 25,408 | 891 |
| 20,000 | 49,884 | 692 |

The per-column read-modify-write that is O(N) per call on netcdf is flat on
hdf5 because the cached dataset handle keeps the packed chunk in the chunk
cache. Un-managed `get_full` reads on the hdf5-built store are also flat
(123–139 µs across the sweep). The "batch large ingests or suffer O(N²)"
caveat disappears with the hdf5 backend.

### Decision summary

Every measured axis now favors or ties the hdf5 backend:

| axis | netcdf | hdf5 |
|---|---|---|
| forecast bulk ingest | O(N²) (`H5Fflush` per var) | flat 42.5 µs/op |
| un-managed per-add | O(N) per call | flat ~700 µs |
| bulk STS add (100k) | 17.6 µs/op | 15.8 µs/op |
| packed reads (100k) | 127 µs/op | 129 µs/op (parity) |
| forecast reads (10k) | 239–258 µs | 142–188 µs |
| store open @ 8k forecasts | 1.34 s | 0.005 s |
| file size @ 8k forecasts | 43.5 MB | 12.1 MB |
| full IS test suite | pass | pass |

Not measured, judged low-risk: `read_index_into` (read-by-timestamp) — not
FFI-exposed yet, identical logical layout and the read profiles show identical
underlying machinery; Probabilistic/Scenarios payloads (same standalone-array
path as Deterministic); compression thresholds for realistic (compressible)
cost data — a tuning question for the hdf5 backend's `COMPACT_MAX_BYTES`, not
a backend differentiator, since netcdf's small-array handling is strictly
larger on disk.

**Recommendation: keep `Hdf5Backend`, drop `NetCdfBackend`.** The netcdf
format's only residual value would be reading stores written before the
switch; no such stores exist outside this spike (InfraStore is pre-release).

## Post-decision fixes (2026-07-29, infrastore `spike/hdf5-backend`)

The recommendation above is executed in three infrastore commits:

1. `b55293e` — netcdf backend removed; hdf5 is the only on-disk backend
   (shared layout policy in `storage/common.rs`, `vendored` builds libhdf5 +
   zlib via `hdf5-metno-src`, netcdf-written stores rejected on open,
   `Store::netcdf_path()` → `file_path()`, Julia `backend` kwarg /
   `INFRASTORE_BACKEND` env removed).
2. `1eb27a7` — the double `get_by_key` per read is gone:
   `Store::get_time_series_with_metadata` returns data + catalog row from one
   lookup; all four FFI getters use it.
3. `844267b` — SQLite catalog switched to WAL journal mode (no per-statement
   shared-lock fcntl + hot-journal `stat()`); `Store::flush` checkpoints
   (TRUNCATE) so the `.sqlite` stays complete before file-level copies.

100k float STS after the two read fixes (µs/op; vs the head-to-head numbers
above):

| op | before | after |
|---|---:|---:|
| get full (non-shared) | 129 | **90.6** |
| get sliced len=12 | 117 | **84.8** |
| bulk add | 15.8 | 16.7 (unchanged) |

Reads are now ~30% faster than either backend measured during the analysis
(and faster than netcdf's best 94.7). Suites re-verified on the final build:
518 infrastore workspace tests, InfraStore.jl suite, IS suite 8,749 pass /
1 broken (baseline).

### Cost payloads rerun on the final build (2026-07-29, N=10k)

`results_costs_postfix.csv`; non-shared, µs/op. "spike" is the pre-fix hdf5
column from the section above; IS4 repeated for reference. The earlier
netcdf columns describe the removed backend and are historical.

| payload | kind | op | current | spike | is4 |
|---|---|---|---:|---:|---:|
| linear | STS | bulk add | 15 | 13 | 75 |
| linear | STS | get full | **96** | 129 | 412 |
| linear | Det | bulk add | 110 | 107 | 118 |
| linear | Det | get full | **122** | 158 | 545 |
| linear | Det | get window | **100** | 139 | 493 |
| quadratic | STS | get full | **101** | 129 | 1,050 |
| quadratic | Det | get full | **121** | 162 | 1,301 |
| pwl | STS | bulk add | 65 | 64 | 97 |
| pwl | STS | get full | **104** | 137 | 1,348 |
| pwl | STS | get sliced | **90** | 123 | 1,308 |
| pwl | Det | bulk add | 428 | 401 | 1,332 |
| pwl | Det | get full | **144** | 188 | 1,626 |
| pwl | Det | get window | **100** | 142 | 1,396 |

Every read op improved 25–30% (the single-lookup + WAL commits); adds are
unchanged within noise. Reads remain payload-flat (~96–104 µs STS,
~121–144 µs forecast full, ~100 µs single window) — now 4–13× faster than
IS4 at 10k on every payload, with the gap still widening with N since IS4
reads degrade with store size. Shared-scenario reads land within ~10% of
non-shared (83–118 µs); shared forecast adds are 80–352 µs vs IS4's
metadata-only ~11–18 µs, unchanged from the earlier analysis.
