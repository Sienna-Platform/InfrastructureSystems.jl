function _default_fill(dtype::String)
    if !haskey(_DTYPES, dtype)
        throw(ArgumentError("Unsupported dtype `$dtype`."))
    end
    return _DTYPES[dtype][2]
end

"Upper bound of the byte size of one dataset chunk."
const MAX_CHUNK_BYTES = 64 * 1024 * 1024

# Axes that shrink first when a chunk is too large: time and horizon, then the others.
function _shrink_priority(name::String)
    if name in ("time", "horizon")
        return 0
    end
    return 1
end

function _chunk_shape(axes::Vector{String}, axis_lengths::Vector{Int}, itemsize::Int)
    if length(axes) != length(axis_lengths)
        throw(
            ArgumentError(
                "axes and axis_lengths differ in length: $(length(axes)) and $(length(axis_lengths)).",
            ),
        )
    end
    chunks = Int[max(len, 1) for len in axis_lengths]
    for (i, name) in enumerate(axes)
        if name == "execution"
            chunks[i] = 1
        end
    end
    shrinkable = [i for (i, name) in enumerate(axes) if name != "execution"]
    sort!(shrinkable; by = i -> (_shrink_priority(axes[i]), i))
    for i in shrinkable
        others = prod(chunks) ÷ chunks[i]
        chunks[i] = clamp(MAX_CHUNK_BYTES ÷ (itemsize * others), 1, chunks[i])
    end
    return chunks
end

"""
Build the `OutputDataset` of the key type `T`, the component type `U`, and `meta`.
The key type traits give the container, quantity kind, and units. `axis_lengths` gives the
length of each axis in `axes`. The chunk size is 1 on the `execution` axis and at least 1
on every axis. A chunk holds at most `MAX_CHUNK_BYTES`: the `time` and `horizon` axes shrink
first, then the other non-execution axes in order.
"""
function dataset_descriptor(
    ::Type{T},
    ::Type{U},
    meta::AbstractString;
    model::AbstractString,
    axes::Vector{String},
    axis_lengths::Vector{Int},
    dtype::String = "f64",
    filters::Vector{String} = ["shuffle", "deflate:3"],
) where {T <: Optimization.OptimizationKeyType, U}
    return _dataset_descriptor(
        T, string(nameof(U)), meta, model, axes, axis_lengths, dtype, filters,
    )
end

"""
Build the `OutputDataset` of the key type `T` and `meta` for a dataset that has no
component (empty `component_type`). Other arguments follow the component method.
"""
function dataset_descriptor(
    ::Type{T},
    meta::AbstractString;
    model::AbstractString,
    axes::Vector{String},
    axis_lengths::Vector{Int},
    dtype::String = "f64",
    filters::Vector{String} = ["shuffle", "deflate:3"],
) where {T <: Optimization.OptimizationKeyType}
    return _dataset_descriptor(T, "", meta, model, axes, axis_lengths, dtype, filters)
end

function _dataset_descriptor(
    ::Type{T},
    component_type::String,
    meta::AbstractString,
    model::AbstractString,
    axes::Vector{String},
    axis_lengths::Vector{Int},
    dtype::String,
    filters::Vector{String},
) where {T <: Optimization.OptimizationKeyType}
    unit_system = Optimization.output_unit_system(T)
    (unit_system_name, base_reference) = unit_system_pair(unit_system)
    entry_type = string(nameof(T))
    name = dataset_name(entry_type, component_type, meta)
    return OutputDataset(
        entry_type,
        String(meta),
        axes,
        dtype,
        _default_fill(dtype),
        Optimization.quantity_kind(T),
        unit_system_name,
        output_units(unit_system, T),
        DatasetLayout(
            _chunk_shape(axes, axis_lengths, sizeof(_DTYPES[dtype][1])), filters,
        ),
        string("/", model, "/datasets/", name),
        Optimization.container_name(T),
        component_type,
        base_reference,
    )
end
