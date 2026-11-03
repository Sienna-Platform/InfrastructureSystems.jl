
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

`scratch_dir` is set when IS chose the store's location (a system's working store, a
writable copy of a deserialized one, a `deepcopy`): a directory from
`mktempdir(; cleanup = true)` holding only this store. It is removed when the store is
closed or finalized, and at process exit otherwise. A store opened from a caller's path has
no `scratch_dir`, and IS never deletes it.
"""
mutable struct Store
    inner::InfraStore.Store
    scratch_dir::Union{Nothing, String}
    function Store(inner::InfraStore.Store, scratch_dir = nothing)
        store = new(inner, scratch_dir)
        isnothing(scratch_dir) || finalizer(close!, store)
        return store
    end
end

# A fresh `.h5` path in its own directory under `parent`, deleted at process exit
# (`.sqlite` and any other sidecar included). Returns `(scratch_dir, path)`.
function _scratch_store_path(parent::AbstractString)
    mkpath(parent)
    dir = mktempdir(parent; prefix = "sienna_time_series_", cleanup = true)
    return dir, joinpath(dir, "time_series.h5")
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

`scratch_dir`, if given, is a directory holding only this store, deleted when it is closed
or finalized (see [`Store`](@ref)).
"""
function Store(;
    in_memory::Bool = false,
    path = nothing,
    compression::CompressionSettings = CompressionSettings(),
    catalog = nothing,
    scratch_dir = nothing,
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
    return Store(inner, scratch_dir)
end

# Translate a `CompressionSettings` into the keyword arguments accepted by
# `InfraStore.Store`.
function _infrastore_compression_kwargs(c::CompressionSettings)
    if !c.enabled
        return (; compression = :none)
    end
    return (; compression = :deflate, compression_level = c.level, shuffle = c.shuffle)
end
