# Time Series Data

`InfrastructureSystems.jl` implements containers and routines to efficiently manage time
series data. This document contains content for developers of new time series data. For the
usage please refer to the documentation in [PowerSystems.jl](https://sienna-platform.github.io/PowerSystems.jl/stable).

Time series storage is backed by **InfraStore**, accessed through its `InfraStore.jl` binding.
InfraStore manages both the time series data and the associations between components /
supplemental attributes and that data. Reasons to consider using it:

  - Numerical arrays are stored independently of components in an HDF5 file with a SQLite
    catalog; components store associations to that data rather than copies.
  - System memory is not depleted by loading all time series data at once. Only data that you
    need is loaded.
  - Storage is **content-addressed**: identical arrays are de-duplicated automatically by their
    SHA-256 hash, so multiple components or supplemental attributes that share the same data
    cost a single array on disk.
  - Supports serialization and deserialization.

## On-disk artifact

A persisted store is **two files that form one logical artifact** and must be moved, copied,
and deleted together:

  - `<path>.h5` — an HDF5 file holding the numerical arrays.
  - `<path>.sqlite` — a SQLite catalog of time series *associations* (metadata).

> **`deepcopy` does not duplicate the on-disk `.h5`/`.sqlite` files.** A `deepcopy` of a
> system yields a new object that still references the same files on disk. To obtain an
> independent copy, serialize and then deserialize the system.

*Notes*:

  - Time series data can optionally be stored fully in memory. Refer to the
    [`InfrastructureSystems.SystemData`](@ref) documentation (`time_series_in_memory`).
  - On-disk artifacts are created on the tmp filesystem by default, using the location obtained
    from `tempdir()`. This can be changed via `time_series_directory` if the data is larger than
    the available tmp space. Refer to the [`InfrastructureSystems.SystemData`](@ref) link above.
  - By default, the call to `add_time_series!` writes per call, which has overhead. If you will
    add thousands of time series arrays, batch them with `time_series_transaction`: call
    `add_time_series!` on the yielded transaction and they are written as one bulk call.
    The block is also a transaction — if it throws, everything it did is rolled back,
    **including removals**, which are irreversible outside one. Hold the block only for the
    writes; gather the data first, since an open block holds the store's write lock.

## Instructions

 1. Ensure that `supports_time_series(::MyComponent)` returns true for the struct. It may
    be implemented on a supertype of the struct.

## Data Format

Numerical arrays live in the HDF5 file, keyed by the SHA-256 hash of their contents
(content addressing, which yields automatic de-duplication). The SQLite catalog records one
row per **association** between an owner (component or supplemental attribute) and a stored
array, identified by:

  - `owner_id` and `owner_category` (component or supplemental attribute)
  - `name`
  - `resolution`
  - `features` (user-defined tags)
  - `time_series_type` (`SingleTimeSeries`, `Deterministic`, `Probabilistic`, `Scenarios`, or
    `DeterministicSingleTimeSeries`)

together with the forecast window parameters (`initial_timestamp`, `horizon`, `interval`,
`count`) and the array's content hash. A `DeterministicSingleTimeSeries` shares the underlying
`SingleTimeSeries` array and synthesizes its forecast windows on read.

### The `units` label

Every time series type carries an optional `units` label — a user-declared string such as
`"MW"`, read back with `get_units`:

```julia
ts = SingleTimeSeries("load", initial_timestamp, resolution, values; units = "MW")
get_units(get_time_series(SingleTimeSeries, component, "load"))  # "MW"
```

It is deliberately *not* like `features`. Features are identity: they are part of the key
and they filter a query. The label is a description of the values, so:

  - it is set at construction and is **immutable** — there is no setter;
  - it is **never** an argument to `get_time_series`, never filters, and never appears on a
    `TimeSeriesKey`. Two series differing only in their label are the same series, and
    adding both is a duplicate;
  - it is carried over by constructors that share another instance's data, and by a derived
    `DeterministicSingleTimeSeries`;
  - it defaults to `nothing`, which IS never fills in — whether that means "unknown" or
    "dimensionless" is the caller's convention.

IS neither interprets nor validates it: there is no units vocabulary in IS, so a consumer
that converts values on read owns both the vocabulary and the conversion. Do not confuse it
with the unit *system* concept in `RelativeUnits` (`SU`/`DU`/`NU`), which selects a per-unit
normalization base rather than naming a physical dimension. The two are independent: a
series labeled `"MW"` may still be read against any normalization base.

For the authoritative on-disk format — HDF5 dataset layout, hashing, the SQLite schema, and
the `DATA_FORMAT_VERSION` compatibility contract — see the `InfraStore` repository's
file-format reference.

## Identifying and retrieving a time series

Address a stored time series by its [`InfrastructureSystems.TimeSeriesKey`](@ref) — a `StaticTimeSeriesKey` or
`ForecastKey` — which captures `name`, `resolution`, `features`, and the concrete type
(forecasts additionally capture `horizon`, `interval`, and `count`). Combined with the owner,
this is the unique identity of an association:

```julia
keys = get_time_series_keys(owner)      # enumerate the owner's associations
ts = get_time_series(owner, keys[1])    # retrieve one by its key
```

## Debugging

Inspect a persisted (closed) store with standard HDF5 and SQLite tools. For example,
`h5ls -r <path>.h5` shows the dataset layout and shapes, and `sqlite3 <path>.sqlite` lets you
query the association catalog directly. Do not open a *live* store's `.h5` file with HDF5.jl —
InfraStore statically links its own pinned libhdf5 and holds the file open; go through the
store's API instead.

## Maintenance

HDF5 files cannot shrink in place. Deleting time series drops the arrays, but the `.h5` file
stays the same size — and this holds for `clear_time_series!` too, which empties the store
without shrinking its file. Small arrays share packed datasets, so their slots are reused by
later additions; the space held by a large standalone array is not returned.

Serializing and deserializing does not repack the artifact either: an on-disk store is
persisted by copying its two files byte-for-byte.

`compact_time_series!(data)` is the operation that does reclaim it. For a system whose time series live
on disk, it rewrites the `.h5` from what the catalog still references and swaps the rewrite
over the original, so the file finally shrinks; the system stays usable across the swap. It
returns an `InfraStore.CompactionReport`, whose `bytes_reclaimed` says how much came back:

```julia
report = IS.compact_time_series!(data)
@show report.bytes_reclaimed
```

Two caveats. The rewrite assumes this process is the artifact's only user — another process
with it open keeps reading the pre-compaction file on Unix, and blocks the replacement on
Windows. And a system holding its time series in memory has no file to rewrite, so it
reports `0` bytes; there, building a fresh `SystemData` with only the data worth keeping is
still the way to shed the arrays.
