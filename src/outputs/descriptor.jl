"Upper bound of the byte size of one dataset chunk."
const MAX_CHUNK_BYTES = 1024 * 1024

function _chunk_shape(axes::Vector{<:OutputAxis}, itemsize::Int)
    chunks = Int[max(axis_length(axis), 1) for axis in axes]
    for (i, axis) in enumerate(axes)
        if is_append_axis(axis)
            chunks[i] = 1
        end
    end
    shrinkable = [i for (i, axis) in enumerate(axes) if !is_append_axis(axis)]
    sort!(shrinkable; by = i -> (!shrinks_first(axes[i]), i))
    for i in shrinkable
        # Product of the other chunk lengths, capped at MAX_CHUNK_BYTES so it cannot overflow.
        others = 1
        for (j, len) in enumerate(chunks)
            if j != i
                others = min(others * min(len, MAX_CHUNK_BYTES), MAX_CHUNK_BYTES)
            end
        end
        chunks[i] = clamp(MAX_CHUNK_BYTES ÷ (itemsize * others), 1, chunks[i])
    end
    return chunks
end

"""
Build the `OutputDataset` of the key type `T`, the component type `U`, and `meta`.
The key type traits give the container, quantity kind, and units. `axes` gives the axes of
the dataset in storage order. The chunk size is 1 on an append axis and at least 1 on every
axis. A chunk holds at most `MAX_CHUNK_BYTES`: the axes that `shrinks_first` marks shrink
first, then the other non-append axes in order.
"""
function dataset_descriptor(
    ::Type{T},
    ::Type{U},
    meta::AbstractString,
    axes::Vector{<:OutputAxis};
    dtype::String = "f64",
    filters::Vector{String} = ["shuffle", "deflate:3"],
) where {T <: Optimization.OptimizationKeyType, U}
    return _dataset_descriptor(T, string(nameof(U)), meta, axes, dtype, filters)
end

"""
Build the `OutputDataset` of the key type `T` and `meta` for a dataset that has no
component (`component_type` is `""`). Other arguments follow the component method.
"""
function dataset_descriptor(
    ::Type{T},
    meta::AbstractString,
    axes::Vector{<:OutputAxis};
    dtype::String = "f64",
    filters::Vector{String} = ["shuffle", "deflate:3"],
) where {T <: Optimization.OptimizationKeyType}
    return _dataset_descriptor(T, "", meta, axes, dtype, filters)
end

function _dataset_descriptor(
    ::Type{T},
    component_type::String,
    meta::AbstractString,
    axes::Vector{<:OutputAxis},
    dtype::String,
    filters::Vector{String},
) where {T <: Optimization.OptimizationKeyType}
    if !haskey(_DTYPES, dtype)
        throw(ArgumentError("unknown dtype \"$dtype\""))
    end
    unit_system = Optimization.output_unit_system(T)
    return OutputDataset(
        Optimization.container_name(T),
        string(nameof(T)),
        component_type,
        String(meta),
        String[axis_name(axis) for axis in axes],
        dtype,
        _DTYPES[dtype][2],
        Optimization.quantity_kind(T),
        unit_system,
        output_units(unit_system, T),
        _chunk_shape(axes, sizeof(_DTYPES[dtype][1])),
        filters,
    )
end
