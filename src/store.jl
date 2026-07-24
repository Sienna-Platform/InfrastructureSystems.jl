
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
supplemental-attribute associations. Wraps a `Castore.Store`; the Castore-backed
constructor and operations live in `castore.jl`.
"""
mutable struct Store
    inner::Castore.Store
    "Filesystem base path for the `.nc` / `.sqlite` pair (nothing if in-memory)."
    path::Union{Nothing, String}
    "Compression policy the store was created/opened with."
    compression::CompressionSettings
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
