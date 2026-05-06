# Time Series Data

`InfrastructureSystems.jl` implements containers and routines to efficiently manage time
series data. This document contains content for developers of new time series data. For the
usage please refer to the documentation in [PowerSystems.jl](https://sienna-platform.github.io/PowerSystems.jl/stable).

`InfrastructureSystems.jl` provides a mechanism to store time series data for
components. Here are reasons to consider using it:

  - Time series data, by default, is stored independently of components in HDF5 files. Components store references to that data.
  - System memory is not depleted by loading all time series data at once. Only data that you need is loaded.
  - Multiple components can share the same time series data by sharing references instead of
    making expensive copies.
  - Supports serialization and deserialization.
  - Supports parsing raw data files of several formats as well as data stored in
    `TimeSeries.TimeArray` and `DataFrames.DataFrame` objects.

> **Your package must reimplement a deepcopy method if you use HDF5 storage for TimeSeriesData.**

If you store an instance of [`InfrastructureSystems.SystemData`](@ref) within your
system and then a user calls `deepcopy` on a system, the .h5 file will not be copied.
The new and old instances will have references to the same file. You will need to
reimplement `deepcopy` to handle this. One solution is to serialize and then
deserialize the system.

*Notes*:

  - Time series data can optionally be stored fully in memory. Refer to the [`InfrastructureSystems.SystemData`](@ref) documentation.
  - `InfrastructureSystems.jl` creates HDF5 files on the tmp filesystem by default, using the location obtained from `tempdir()`. This can be changed if the time series data is larger than the amount of tmp space available. Refer to the [`InfrastructureSystems.SystemData`](@ref) link above.
  - By default, the call to `add_time_series!` will open the .h5 file, write the data to the file,
    and close the file. Opening and closing the file has overhead. If you will add thousands of time
    series arrays, consider using `open_time_series_store!` to add all the arrays with one file handle.

## Instructions

 1. Ensure that `supports_time_series(::MyComponent)` returns true for the struct. It may
    be implemented on a supertype of the struct.

## Data Format

Time series arrays are stored in an
[HDF5](https://support.hdfgroup.org/HDF5/whatishdf5.html) file according the
format described here.

The root path `/time_series` defines these HDF5 attributes to control deserialization:

  - `data_format_version`: Designates the InfrastructureSystems format for the file.
  - `compression_enabled`: Specifies whether compression is enabled and will be used for new time series.
  - `compression_type`: Specifies the type of compression being used.
  - `compression_level`: Specifies the level of compression being used.
  - `compression_shuffle`: Specifies whether the shuffle filter is being used.

Each time series array is stored in an HDF5 group named with the array's UUID.
Each group contains a dataset called `data` which contains the actual data.
Each group also contains a group called `component_references` which contains
an HDF5 attribute for each component reference. The component reference uses the
format `<component_uuid>__<time_series_name>`.

Each time series group defines attributes that control how the data will be
deserialized into a `TimeSeriesData` instance.

  - `initial_timestamp`: Defines the first timestamp of the array. (All times are not stored.)
  - `resolution`: Resolution of the time series in milliseconds.
  - `type`: Type of the time series. Subtype of `TimeSeriesData`.
  - `module`: Module that defines the type of the time series.
  - `data_type`: Describes the type of the array stored.

Example:

```
/time_series
    data_format_version = "1.0.1"
    compression_enabled = 1
    /9f02f706-3394-4af3-8084-8903d302cbba
        /component_references
            0b6ecb61-8e8d-4563-b795-f001246c3ea5__max_active_power
            613ddbc2-b666-4c9d-adb5-fa69e7f40a95__max_active_power
        /data
```

## Debugging

The HDF Group provides tools to inspect and manipulate files. Refer to their
[website](https://support.hdfgroup.org/products/hdf5_tools/).

`HDFView` is especially useful for viewing data. Note that using `h5ls` and
`h5dump` in a terminal combined with UNIX tools like `grep` can sometimes be
faster.

## Maintenance

If you delete time series arrays in your system you may notice that the actual
size of the HDF5 does not decrease. The only way to recover this space is to
build a new file with only the active objects. The HDF5 tools package provides
the tool `h5repack` for this purpose.

```console
$ h5repack time_series.h5 new.h5
$ mv new.h5 time_series.h5
```
