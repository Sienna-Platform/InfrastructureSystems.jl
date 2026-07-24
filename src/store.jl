
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
supplemental-attribute associations. Wraps a `Castore.Store`; the operations live
in `castore.jl`.
"""
mutable struct Store
    inner::Castore.Store
    "Filesystem base path for the `.nc` / `.sqlite` pair (nothing if in-memory). Tracked
    here because `Castore.Store` does not expose its backing path or in-memory status."
    path::Union{Nothing, String}
end

"""
    Store(; in_memory=false, path=nothing, compression=CompressionSettings())

Create a Castore-backed store (time series data plus component / supplemental-attribute
associations). When `in_memory=false`, `path` is the base path for the on-disk artifacts
(`<path>.nc` and `<path>.sqlite`).

`compression` is a [`CompressionSettings`](@ref). The Castore backend supports
`DEFLATE` (with `level` 0-9 and `shuffle`) or no compression (`enabled=false`);
`BLOSC` is not available and raises an error.
"""
function Store(;
    in_memory::Bool = false,
    path = nothing,
    compression::CompressionSettings = CompressionSettings(),
)
    kwargs = _castore_compression_kwargs(compression)
    inner = if in_memory
        Castore.Store(; in_memory = true, kwargs...)
    else
        Castore.Store(; in_memory = false, path = path, kwargs...)
    end
    return Store(inner, path === nothing ? nothing : String(path))
end

# Translate a `CompressionSettings` into the keyword arguments accepted by
# `Castore.Store`. BLOSC is not supported by the Castore backend.
function _castore_compression_kwargs(c::CompressionSettings)
    if !c.enabled
        return (; compression = :none)
    end
    if c.type == CompressionTypes.DEFLATE
        return (; compression = :deflate, compression_level = c.level, shuffle = c.shuffle)
    end
    error(
        "Castore does not support $(c.type) compression; " *
        "use CompressionTypes.DEFLATE or disable compression (enabled=false).",
    )
end

"""
Open the storage for a batch of operations. The Castore backend has no file handle
to manage at this layer, so this just runs `func`.
"""
function open_store!(
    func::Function,
    ::Store,
    mode = "r",
    args...;
    kwargs...,
)
    return func(args...; kwargs...)
end

function make_component_name(component_uuid::UUIDs.UUID, name::AbstractString)
    return string(component_uuid) * COMPONENT_NAME_DELIMITER * name
end

function deserialize_component_name(component_name::AbstractString)
    data = split(component_name, COMPONENT_NAME_DELIMITER)
    component = UUIDs.UUID(data[1])
    name = data[2]
    return component, name
end
