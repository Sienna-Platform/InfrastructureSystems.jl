# Time Series Data

`InfrastructureSystems.jl` implements containers and routines to efficiently manage time
series data. This document contains content for developers of new time series data. For the
usage please refer to the documentation in [PowerSystems.jl](https://sienna-platform.github.io/PowerSystems.jl/stable).

Time series storage is backed by the `time-series-store` Rust library (wrapped by the
`TimeSeriesStore.jl` binding). Reasons to consider using it:

  - Numerical arrays are stored independently of components in a NetCDF file with a SQLite
    catalog; components store associations to that data rather than copies.
  - System memory is not depleted by loading all time series data at once. Only data that you
    need is loaded.
  - Storage is **content-addressed**: identical arrays are de-duplicated automatically by their
    SHA-256 hash, so multiple components or supplemental attributes that share the same data
    cost a single array on disk.
  - Supports serialization and deserialization.
  - Supports parsing raw data files of several formats as well as data stored in
    `TimeSeries.TimeArray` and `DataFrames.DataFrame` objects.

## On-disk artifact

A persisted store is **two files that form one logical artifact** and must be moved, copied,
and deleted together:

  - `<path>.nc` — a NetCDF4 file holding the numerical arrays.
  - `<path>.sqlite` — a SQLite catalog of time series *associations* (metadata).

> **`deepcopy` does not duplicate the on-disk `.nc`/`.sqlite` files.** A `deepcopy` of a
> system yields a new object that still references the same files on disk. To obtain an
> independent copy, serialize and then deserialize the system.

*Notes*:

  - Time series data can optionally be stored fully in memory. Refer to the
    [`InfrastructureSystems.SystemData`](@ref) documentation (`time_series_in_memory`).
  - On-disk artifacts are created on the tmp filesystem by default, using the location obtained
    from `tempdir()`. This can be changed via `time_series_directory` if the data is larger than
    the available tmp space. Refer to the [`InfrastructureSystems.SystemData`](@ref) link above.
  - By default, the call to `add_time_series!` writes and flushes per call, which has overhead.
    If you will add thousands of time series arrays, batch them with `open_time_series_store!`
    (or `bulk_add_time_series!`) so a single handle is reused.

## Instructions

 1. Ensure that `supports_time_series(::MyComponent)` returns true for the struct. It may
    be implemented on a supertype of the struct.

## Data Format

Numerical arrays live in the NetCDF file, keyed by the SHA-256 hash of their contents
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

For the authoritative on-disk format — NetCDF dataset layout, hashing, the SQLite schema, and
the `DATA_FORMAT_VERSION` compatibility contract — see the `time-series-store` repository's
file-format reference.

## Identifying and retrieving a time series

Address a stored time series by its [`TimeSeriesKey`](@ref) — a `StaticTimeSeriesKey` or
`ForecastKey` — which captures `name`, `resolution`, `features`, and the concrete type
(forecasts additionally capture `horizon`, `interval`, and `count`). Combined with the owner,
this is the unique identity of an association:

```julia
keys = get_time_series_keys(owner)      # enumerate the owner's associations
ts = get_time_series(owner, keys[1])    # retrieve one by its key
```

> **Migration note.** The former `get_time_series_uuid` function and the `time_series_uuid`
> metadata field have been removed. That UUID was derived from the array's content hash, so it
> was *not* unique per association — two associations that happened to share identical data
> shared a single UUID, making it unsuitable as a handle. Use [`TimeSeriesKey`](@ref) (above)
> to address a specific time series. If you need *data* identity ("is this the same underlying
> array?"), that is the array's SHA-256 content hash held by the store.

## Debugging

Inspect the artifacts with standard NetCDF and SQLite tools. For example, `ncdump -h <path>.nc`
shows the array layout and dimensions, and `sqlite3 <path>.sqlite` lets you query the
association catalog directly.

## Maintenance

NetCDF files cannot shrink in place: deleting time series frees logical slots for reuse but
does not immediately reduce the file size. Recovering that space requires an explicit
compaction — rebuilding the artifact with only the active arrays — which is provided by the
`time-series-store` backend.
