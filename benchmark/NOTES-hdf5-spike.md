# Working notes: InfraStore time-series performance investigation

Session handoff notes, 2026-07-29. Context: benchmarking cost-function
(FunctionData) time series on `feat/rust-time-series-store` vs IS4 uncovered an
O(N²) forecast-ingest pathology in the netcdf backend; a direct-HDF5 backend
spike fixes it. Headline numbers and analysis are in [README.md](README.md)
(sections "Cost-function payloads" and "Direct-HDF5 backend spike") — this file
holds the state, environments, and open questions needed to continue.

## Repo / branch state

- **IS3.jl** (`feat/rust-time-series-store`): new `benchmark/bench_costs_*.jl`
  + result CSVs + README sections, all uncommitted. No `src/` changes from this
  investigation (the pre-existing `src/infrastore.jl` / `src/time_series_interface.jl`
  modifications predate it).
- **infrastore** (`~/repos/infrastore`, branch `spike/hdf5-backend`,
  **uncommitted**; branched from `main` @ aef311d "Release v0.3.0"):
  - `crates/infrastore-core/src/storage/hdf5.rs` — new `Hdf5Backend` (+ tests)
  - `crates/infrastore-core/src/storage/netcdf.rs` — helpers/constants made
    `pub(crate)` for sharing (should move to a `storage/common.rs` eventually)
  - `crates/infrastore-core/src/storage.rs` — `BackendKind` enum, module wiring
  - `crates/infrastore-core/src/store.rs` — `create_with_options`, backend
    sniffing in `open` **and in `persist_to`** (was hardwired to netcdf; fixed)
  - `crates/infrastore-core/src/lib.rs` — `create_store_with_options` export
  - `crates/infrastore-core/tests/hdf5_backend_roundtrip.rs` — Store-level test
  - `crates/infrastore-ffi/src/lib.rs` — `infrastore_store_create_with_options`
  - `julia/InfraStore.jl/src/store.jl` — `backend` kwarg, default from
    `INFRASTORE_BACKEND` env (`:netcdf` | `:hdf5`)
  - `Cargo.toml` — added `hdf5-metno = 0.12` (must stay on the 0.11.x
    `hdf5-metno-sys` line that netcdf-sys pins; 0.13+ conflicts)
  - NOTE: `yggdrasil/build_tarballs.jl` had uncommitted changes *before* this
    session — not mine, don't clobber.

## Environments / commands

```sh
export INFRASTORE_LIB=~/repos/infrastore/target/release/libinfrastore_ffi.dylib
# rebuild after Rust changes:
(cd ~/repos/infrastore && cargo build --release -p infrastore-ffi)

# cost benchmark, this branch (backend switched purely by env var):
BENCH_N=10000 julia --project=test benchmark/bench_costs_branch.jl                      # netcdf
INFRASTORE_BACKEND=hdf5 BENCH_LABEL=infrastore-hdf5 BENCH_N=10000 \
  julia --project=test benchmark/bench_costs_branch.jl                                  # hdf5
# knobs: BENCH_LEN (STS length, 24), BENCH_NP (pwl points, 5),
#        BENCH_WINDOWS/BENCH_HORIZON (12/12), BENCH_PAYLOADS=linear,quadratic,pwl

# 100k float benchmark: BENCH_N=100000 julia --project=test benchmark/bench_bulk.jl
# full IS suite on hdf5:  INFRASTORE_BACKEND=hdf5 julia --project=test test/runtests.jl
#   (baseline both backends: 8,749 pass / 1 broken)
# rust tests: cargo test -p infrastore-core   (storage::hdf5 + hdf5_backend_roundtrip)
```

**IS4 comparison env** lived in a PREVIOUS session's scratchpad and may be
gone after a tmp-clean/reboot:
`/private/tmp/claude-853830349/-Users-dthom-repos-sienna-IS3-jl/8793c195-fe65-4691-97e0-d68356c2e9cd/scratchpad/{is4-wt,env_is4}`.
To recreate: `git worktree add <dir> IS4`, then a fresh env with
`Pkg.develop(path=<worktree>)` + `Pkg.add.(["TimeSeries","DataStructures"])`;
run `BENCH_N=10000 julia --project=<env> benchmark/bench_costs_is4.jl`.

## Established findings (details in README)

1. **netcdf backend forecast ingest is O(N²)**: each dense forecast = its own
   NetCDF variable; each define→write cycle triggers netcdf-c's implicit
   `sync_netcdf4_file` → `H5Fflush` → iterate all open datasets. 82% of a
   12k-forecast commit is `H5Fflush` (macOS `sample` profile). Direct HDF5
   dataset creation is flat (~20 µs/op to 8k datasets, probed via HDF5.jl).
2. **Hdf5Backend fixes it without packing forecasts**: commits flat 42.5 µs/op;
   open 0.005 s vs 1.34 s @ 8k forecasts; file 12.1 MB vs 43.5 MB (compact
   layout for standalone arrays ≤ 56 KiB).
3. **HDF5 gotchas encoded in the backend** (both cost a rerun to find):
   chunk cache is per *open dataset handle* → handles are cached for the
   store's lifetime (`Inner.handles`, RefCell behind the Mutex); default cache
   is 1 MiB → 64 MiB set file-wide via fapl (`file_builder()`).

## Open performance questions (the "continue exploring" list)

**2026-07-29 update: the two decision-gating questions below are RESOLVED
(see README "Backend decision head-to-head") — hdf5 reads are at parity and
the per-add path is flat. Recommendation recorded in the README: keep
`Hdf5Backend`, drop `NetCdfBackend`.**

- ~~**100k packed float reads: hdf5 124 µs/op vs netcdf 94.7**~~ **RESOLVED
  2026-07-29: measurement artifact.** The 94.7 (netcdf) and 124 (hdf5) numbers
  were taken 3 days / several IS commits apart. Re-measured both backends on
  identical code, same day (400k reads each): netcdf 127.4, hdf5 129.1 µs/op —
  parity. `sample` profiles are near-identical (both bottom out in libhdf5
  `H5Dread`; netcdf-c wraps it). Per-read cost structure at 100k, both
  backends: ~36–38% Julia/IS-side, ~19–21% SQLite metadata, ~14–16% backend
  read. Backend-independent read optimization targets found on the way:
  - `MetadataStore::get_by_key` runs **twice per read** — once directly from
    `infrastore_store_get_single`, once inside `Store::get_time_series`.
  - Every metadata query pays `btreeBeginTrans` + `sqlite3PagerSharedLock`
    including a `stat()` syscall (fresh read transaction per query) — a
    persistent read txn / WAL / prepared-statement reuse could cut it.
  - hdf5-metno's `read_into_buf` does an `H5Pcreate` (dxpl) per read (~2%).
  - Inside `H5Dread` the time is hyperslab/selection bookkeeping
    (`H5D__chunk_io_init` selection copies, skip-list alloc/free), not data
    movement — inherent to per-column reads on both backends.
- **PWL forecast adds 401 µs vs linear 107** on hdf5 (IS4: 1,332). Data-size
  driven (12.7 KB vs 2.3 KB per forecast). Cost split unknown between IS-side
  ragged→padded encode (`_storage_forecast_array` in `src/infrastore.jl`,
  1.4 GB allocated per 10k run), blake hash of the array, and FFI copy.
  A Julia `@profile` of the bulk_add loop would split it.
- **Shared adds still lose to IS4** (10–345 µs vs 11–18): content-hash dedup
  must hash + FFI-encode the full array before discovering it's a duplicate.
  Known since the float benchmark; unchanged by the backend swap.
- **Forecast reads ~140–190 µs vs STS ~120–137**: per-read dataset open is
  gone, so the remainder is standalone-read + window materialization overhead.
  Not yet profiled.
- ~~**Un-managed per-add path on hdf5 backend untested**~~ **RESOLVED
  2026-07-29: flat.** `bench_branch_scaling.jl` with `INFRASTORE_BACKEND=hdf5`
  (`results_scaling_hdf5.csv`): non-shared adds ~700–890 µs/op from 1k→20k
  store size vs netcdf's 1,398→49,884 (O(N) per call). Un-managed reads on the
  hdf5-built store also flat (123–139 µs). The "must batch or O(N²)" caveat is
  netcdf-only.
- **Compression tradeoff unmeasured**: compact layout disables DEFLATE for
  small standalone arrays. Random-double benchmarks don't compress anyway;
  real PWL cost data (repeated breakpoints, zero-padding) would. Measure file
  sizes with realistic data before deciding a threshold.
- **Not yet benchmarked at all**: read-by-timestamp across many series
  (`read_index_into` — the layout packed STS exists for; note 2026-07-29: not
  FFI-exposed yet, so not probeable from Julia — judged low-risk for the
  backend decision since layout and underlying `H5Dread` machinery are
  identical), removals/compaction, Probabilistic/Scenarios payloads, larger
  BENCH_N on the cost workload.

## Productionization TODOs — executed 2026-07-29 (infrastore commits
## b55293e / 1eb27a7 / 844267b)

- ~~Factor shared helpers into `storage/common.rs`; decide netcdf's fate~~ —
  done: netcdf backend **removed**, layout policy in `storage/common.rs`,
  `Store::open` rejects files without the `storage_backend` attr.
- ~~In-memory `persist_to` materializes via `NetCdfBackend::create`~~ — now
  `Hdf5Backend`.
- ~~Vendored/static build~~ — `vendored = ["hdf5-metno/static", "hdf5-metno/zlib"]`
  (libhdf5 + zlib from `hdf5-metno-src`); netcdf/netcdf-sys dropped. Default
  build verified.
- ~~Backend selection~~ — removed outright (no `BackendKind`, no
  `INFRASTORE_BACKEND`, no Julia `backend` kwarg) rather than wired through
  `SystemData`.
- Also landed while here: single-lookup `get_time_series_with_metadata` (kills
  the double `get_by_key` per FFI read) and WAL journal mode for the catalog
  (checkpoint on `Store::flush` keeps the `.sqlite` copyable). 100k full reads
  129 → 90 µs/op.
- Still open: handle cache grows unboundedly with datasets touched (netcdf-c
  parity; an LRU bound may be nicer for huge stores).
