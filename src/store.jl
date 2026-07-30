
const DEFAULT_COMPRESSION = false

@scoped_enum(CompressionTypes, BLOSC = 0, DEFLATE = 1,)

@doc """
HDF5 compression algorithm types for time series storage.

# Values
- `BLOSC`: Blosc compression (fast, general-purpose)
- `DEFLATE`: Deflate/zlib compression
""" CompressionTypes

"""
    CompressionSettings(enabled, type, level, shuffle)

Provides customization of HDF5 compression settings.

$(TYPEDFIELDS)

Refer to the [HDF5.jl](https://juliaio.github.io/HDF5.jl/stable/) and
[HDF5](https://portal.hdfgroup.org/) documentation for more details on the
options.

# Example
```julia
settings = CompressionSettings(
    enabled = true,
    type = CompressionTypes.DEFLATE,  # BLOSC is also supported
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
    Store(; in_memory=false, path=nothing, compression=CompressionSettings())

Create a InfraStore-backed store (time series data plus component / supplemental-attribute
associations). When `in_memory=false`, `path` is the base path for the on-disk artifacts
(`<path>.h5` and `<path>.sqlite`).

`compression` is a [`CompressionSettings`](@ref). The InfraStore backend supports
`DEFLATE` (with `level` 0-9 and `shuffle`) or no compression (`enabled=false`);
`BLOSC` is not available and raises an error.
"""
function Store(;
    in_memory::Bool = false,
    path = nothing,
    compression::CompressionSettings = CompressionSettings(),
)
    kwargs = _infrastore_compression_kwargs(compression)
    inner = if in_memory
        InfraStore.Store(; in_memory = true, kwargs...)
    else
        InfraStore.Store(; in_memory = false, path = path, kwargs...)
    end
    return Store(inner)
end

# Translate a `CompressionSettings` into the keyword arguments accepted by
# `InfraStore.Store`. BLOSC is not supported by the InfraStore backend.
function _infrastore_compression_kwargs(c::CompressionSettings)
    if !c.enabled
        return (; compression = :none)
    end
    if c.type == CompressionTypes.DEFLATE
        return (; compression = :deflate, compression_level = c.level, shuffle = c.shuffle)
    end
    error(
        "InfraStore does not support $(c.type) compression; " *
        "use CompressionTypes.DEFLATE or disable compression (enabled=false).",
    )
end
