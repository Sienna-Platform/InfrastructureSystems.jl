
const DEFAULT_COMPRESSION = false

@scoped_enum(CompressionTypes, DEFLATE = 1,)

@doc """
HDF5 compression algorithm types for time series storage.

# Values
- `DEFLATE`: Deflate/zlib compression
""" CompressionTypes

"""
    CompressionSettings(enabled, type, level, shuffle)

Provides customization of HDF5 compression settings.

$(TYPEDFIELDS)

# Example
```julia
settings = CompressionSettings(
    enabled = true,
    type = CompressionTypes.DEFLATE,
    level = 3,
    shuffle = true,
)
```
"""
struct CompressionSettings
    "Controls whether compression is enabled."
    enabled::Bool
    "Specifies the type of compression to use."
    type::CompressionTypes.Value
    "Supported values are 0-9. Higher values deliver better compression ratios but take longer."
    level::Int
    "Controls whether to enable the shuffle filter. Used with DEFLATE."
    shuffle::Bool
end

function CompressionSettings(;
    enabled = DEFAULT_COMPRESSION,
    type = CompressionTypes.DEFLATE,
    level = 3,
    shuffle = true,
)
    return CompressionSettings(enabled, type, level, shuffle)
end

"""
The store backing a system's time series data and its component /
supplemental-attribute associations. A thin wrapper over `InfraStore.Store` that lets IS
own its `deepcopy`/`isempty`/serialization semantics; the operations live in `infrastore.jl`.

`scratch_path` is set when IS chose the store's location (a system's working store, a
writable copy of a deserialized one, a `deepcopy`): the `.h5` path, whose files are deleted
when the store is closed or its handle is finalized, which Julia also does at exit. A store
opened from a caller's path has no `scratch_path`, and IS never deletes it.
"""
mutable struct Store
    inner::InfraStore.Store
    scratch_path::Union{Nothing, String}
end

Store(inner::InfraStore.Store) = Store(inner, nothing)

# A fresh absolute `<directory>/<uuid>_time_series.h5` path, so cleanup still finds the
# files after a `cd`; `directory` defaults to `tempdir()`.
function _scratch_store_path(directory::Union{Nothing, AbstractString})
    dir = isnothing(directory) ? tempdir() : String(directory)
    mkpath(dir)
    return abspath(joinpath(dir, string(UUIDs.uuid4()) * "_time_series.h5"))
end

# The catalogs are in WAL mode, so SQLite never writes a `-journal`; `-wal`/`-shm` are
# deleted by a clean close and are listed only in case the close failed.
const _STORE_SIDECAR_SUFFIXES = ("", ".sqlite", ".sqlite-wal", ".sqlite-shm")

# Must not throw or yield: it also runs as a finalizer. A file the OS refuses to delete
# (e.g. still open on Windows) is left behind.
function _remove_store_files(path::String)
    for suffix in _STORE_SIDECAR_SUFFIXES
        try
            rm(path * suffix; force = true)
        catch
        end
    end
    return
end

# Run `open_fn` to create a store at the scratch `path` and make IS its owner. If
# `open_fn` throws, whatever it left at `path` is removed. The cleanup finalizer is
# attached to the InfraStore handle, not the IS wrapper: code routinely pulls
# `store.inner` out and calls into the backend with it, and the wrapper can be collected
# mid-call.
function _open_scratch_store(open_fn, path::String)
    store = try
        open_fn()
    catch
        _remove_store_files(path)
        rethrow()
    end
    store.scratch_path = path
    finalizer(store.inner) do inner
        InfraStore.close!(inner)
        _remove_store_files(path)
    end
    return store
end

"""
    Store(; in_memory=false, path=nothing, compression=CompressionSettings(), catalog=nothing)

Create a InfraStore-backed store (time series data plus component / supplemental-attribute
associations). When `in_memory=false`, `path` is the base path for the on-disk artifacts
(`<path>.h5` and `<path>.sqlite`).

`compression` is a [`CompressionSettings`](@ref). The InfraStore backend supports
`DEFLATE` (with `level` 0-9 and `shuffle`) or no compression (`enabled=false`).

`catalog` places the SQLite catalog: `:attached` makes it the `.sqlite` file, where every
commit is durable, while `:memory` holds it in RAM so it reaches disk only through
`serialize`/`persist!`. Arrays stream to the `.h5` either way, so `:memory` does not
require the data to fit in memory. `nothing` (the default) lets InfraStore match the
backend. A system's working store uses `:memory` — see [`TimeSeriesManager`](@ref).
"""
function Store(;
    in_memory::Bool = false,
    path = nothing,
    compression::CompressionSettings = CompressionSettings(),
    catalog = nothing,
)
    kwargs = _infrastore_compression_kwargs(compression)
    # `catalog = nothing` is InfraStore's own default, so it needs no special case.
    inner = if in_memory
        InfraStore.Store(; in_memory = true, catalog = catalog, kwargs...)
    else
        InfraStore.Store(;
            in_memory = false,
            path = path,
            catalog = catalog,
            kwargs...,
        )
    end
    return Store(inner)
end

# Translate a `CompressionSettings` into the keyword arguments accepted by
# `InfraStore.Store`.
function _infrastore_compression_kwargs(c::CompressionSettings)
    if !c.enabled
        return (; compression = :none)
    end
    return (; compression = :deflate, compression_level = c.level, shuffle = c.shuffle)
end
