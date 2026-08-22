
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
    type::CompressionTypes
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
"""
mutable struct Store
    inner::InfraStore.Store
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
