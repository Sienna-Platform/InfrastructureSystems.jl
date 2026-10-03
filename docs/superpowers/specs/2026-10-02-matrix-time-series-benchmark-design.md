# Matrix time series: IS axis support and storage benchmark

Date: 2026-10-02.
Branch: `rh/ts_matrix_benchmark`.
Results go to NatLabRockies/infrastore#100.

## Goal

Find whether load-zone distribution factors cost less to read, serialize and deserialize as one matrix-valued series than as today's one-series-per-bus layout.
Everything runs through IS, not InfraStore directly.
The result decides whether `MatrixTimeSeries` needs to be a new type or can stay a `SingleTimeSeries` with axis labels.

Out of scope for this round: reserves (Option B link map), trading hubs, a full year of data, raw HDF5.jl layouts, and a dense `[T, B_all]` matrix with a bus-to-zone map.

## Background

- The store already holds any per-step shape: static series as `[length, *E]`, forecasts as `[H, count, *E]`.
- `SingleTimeSeries{T, N}` with `N >= 2` already writes, reads and slices through IS.
- The store's DST transform and read already handle `*E`, and the DST row inherits the source row's `element_shape` and `application_data` (`derived_view_row`, infrastore-core `store.rs:6286`, v0.14.1).
- One array can have many owners: `add_time_series!(sys, components, ts)` stores it once and writes one association row per owner.
- Two things block the benchmark in IS today:
  1. IS has no way to store axis labels. It never writes `application_data` and drops it on read.
  2. IS cannot read an N-D `Deterministic` or DST. `_check_deterministic_window_shape` throws for rank 3 and above, and several helpers assume vector windows.

## Part 1: IS changes

### 1a. Value axes on `SingleTimeSeries` and `Deterministic`

A new field, modeled on `units`:

```julia
struct TimeSeriesAxis
    name::String
    labels::Union{Vector{Int64}, Vector{String}}
end

value_axes::Union{Nothing, Vector{TimeSeriesAxis}}   # default nothing
```

- `value_axes` names every non-time dimension of a step's value, in order.
  For `M2`: `[TimeSeriesAxis("zone", zone_names), TimeSeriesAxis("bus", bus_numbers)]`.
- Validated at construction, failing loudly with an `ArgumentError`:
  - `length(value_axes)` equals the value rank (`N - 1` for `SingleTimeSeries`, window rank minus 1 for `Deterministic`).
  - Each axis's label count equals the size of its dimension.
  - Labels are unique within an axis.
- Set at construction and immutable, with no setter.
- Not part of identity and not filterable, like `units`.
- Carried over by every data-sharing constructor (`X(src, name)`, subset forms) and by `_single_from_store`.
- Read with `get_value_axes(ts)`, which is not exported.
- `get_value_axes(md::TimeSeriesMetadata)` decodes the same labels from a catalog row, for readers that hand back raw arrays (the forecast reader).

**Persistence.**
IS writes `application_data = {"value_axes": [{"name": ..., "labels": [...]}, ...]}` on the add path (`serialize_single!`, the `Deterministic` stager, and the store-level `_serialize_static!`).
On read, IS fills `value_axes` from that key.
A row whose `application_data` is not IS's JSON object (another client's opaque data) reads back as `value_axes = nothing`; IS leaves the string alone.
A row whose `value_axes` disagrees with the stored shape is a storage inconsistency and throws.
The OpenAPI association rows already carry `application_data`, so both serialization paths round-trip the labels with no extra work.

`DeterministicSingleTimeSeries` stays a fieldless marker.
Its materialized `Deterministic` gets `value_axes` from the inherited row.

`NonSequentialTimeSeries`, `Probabilistic` and `Scenarios` do not get the field this round.

### 1b. N-D `Deterministic` read and write

| Where | Change |
|---|---|
| `validate_time_series_data_for_backend` (`src/utils/utils.jl:63`) | Accept `SortedDict{DateTime, Array{T, N}}` for scalar `T`, with every window the same size |
| `_check_deterministic_window_shape` (`src/infrastore.jl:1380`) | Allow rank >= 2 when the element type is a plain dtype; keep the throw for composite element types (the existing test passes `"piecewise_step"` and still holds) |
| `_forecast_from_store` (`src/infrastore.jl:1402`) | Window `i` is `copy(selectdim(d.data, 2, i))`, giving `[H, *E]` |
| `_truncate_window` (`src/infrastore.jl:1321`) | Add an N-D method truncating the leading axis |
| `_infrastore_build_forecast` (`src/infrastore.jl:1145`) | `stack(windows; dims = 2)` instead of `reduce(hcat, windows)`, which mixes windows and value columns for N-D windows |
| `get_window_common` (`src/forecasts.jl:231`) | Slice the leading axis; rank 3 and above throws an `ArgumentError` pointing at `get_data` (a `TimeArray` holds at most 2 dimensions). Today rank 3 returns wrong values without an error |
| `_decode_forecast_reader_window` (`src/infrastore.jl:1478`) | No code change expected; add an N-D test |

`TimeArray` accessors (`get_time_series_array`, `get_time_series_values`, the caches) stay scalar or matrix only.
The benchmark reads through `get_time_series` plus `get_array` or `get_data`.

### 1c. Tests

Written before the code, in `test/test_time_series.jl` and `test/test_time_series_consistency.jl`:

- `value_axes` construction rejects a wrong axis count, a wrong label count and duplicate labels.
- `SingleTimeSeries` with `value_axes` round-trips through the store, including a sliced read.
- A multi-owner add keeps `value_axes` on every owner's row.
- Another client's `application_data` reads back as `value_axes = nothing` without error.
- An N-D `Deterministic` round-trips (add, then `get_time_series`), with and without `len`.
- Transforming an N-D `SingleTimeSeries` and reading the DST gives the expected `[H, Z, B]` windows and the source's `value_axes`.
- The forecast reader returns correct N-D windows.
- `get_window_common` slices a rank-3 window correctly.
- `serialize` / `deserialize` of a `SystemData` and the OpenAPI rows path both keep `value_axes`.

The full suite and the psy6 smoke import (`CLAUDE.md`) must pass, and the formatter must run.

## Part 2: The benchmark

### Data

- 24 hourly steps, 8 `LoadZone`-like components, 50,000 buses, 6,250 per zone.
- Smooth per-bus factors that sum to 1 within each zone.
- Every bus has distinct values, so content addressing cannot deduplicate B0.

### Representations

Each runs in its own `SystemData`.

| ID | Series | Owners | Labels |
|---|---|---|---|
| B0-Det | 50,000 scalar `Deterministic` (H = 24, one window) with feature `"bus" => n` | each bus's zone | features |
| B0-DST | 50,000 scalar `SingleTimeSeries` with feature `"bus" => n`, then `transform_single_time_series!` | each bus's zone | features |
| M1 | 8 `SingleTimeSeries{Float64, 2}`, `[24, n_members]` | one zone each | `value_axes = [bus]` |
| M2 | 1 `SingleTimeSeries{Float64, 3}`, `[24, 8, 50_000]`, 0 for non-members | all 8 zones, one multi-owner add | `value_axes = [zone, bus]` |
| M2-DST | `transform_single_time_series!` over M2 | all 8 zones | inherited |

### Operations

| Op | What is timed |
|---|---|
| `write` | All adds inside one `time_series_transaction`, plus the transform where there is one |
| `read_zone` | For each zone, building its `(bus, t)` factor array. B0 uses the POM `cc12092` loop: one `list_time_series_metadata` pass, then `get_time_series_values(zone, key; start_time, len)` per bus |
| `read_all_once` | M2 and M2-DST only: group owners with `get_time_series_hashes`, read the shared array once, slice zones in memory. M2-DST also through `build_forecast_reader` |
| `ser_legacy` / `de_legacy` | `serialize(SystemData)` to JSON + `.h5` + `.sqlite`, then deserialize |
| `ser_openapi` / `de_openapi` | `openapi_time_series_association_json` + `serialize_arrays`, then `deserialize_arrays` + `import_time_series_association_rows!` |

### Metrics and correctness

- Median wall time and allocated bytes, after a warmup run on a small system.
- `.h5`, `.sqlite` and JSON sizes.
- Peak RSS, from one fresh `julia` process per representation.
- All five representations must return the same factor array for every zone, and `value_axes` must survive both serialization paths.
  A mismatch is a failed row in the output, never a skipped one.

### Files

- `benchmark/matrix_bench.jl`: one script, with the case passed as an argument, plus a driver mode that runs each case in a fresh process.
- Output in `bench.jl`'s CSV format: `kind,eltype,op,n,total_s,us_per_op,bytes,status`.
- `benchmark/bench.jl` gets an `abspath(PROGRAM_FILE) == @__FILE__` guard so `matrix_bench.jl` can include its helpers (`timed_op`, `build_system`, `report_disk`, `report_maxrss`).
- The results become a short HTML report, posted to infrastore#100 only after review.

## Risks

- The multi-owner add copies and hashes M2's 76.8 MB once per owner before the store deduplicates it. The benchmark measures this cost; it does not fix it.
- `application_data` is per row, so M2's labels (about 400 KB of JSON) are stored once per owner and once more per DST row.
- Writing `application_data` from IS claims a field other clients may use. The `"value_axes"` key, and leaving non-IS data alone, keeps that safe.
