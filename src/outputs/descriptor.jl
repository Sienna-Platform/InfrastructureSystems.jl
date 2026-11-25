"Upper bound of the byte size of one dataset chunk."
const MAX_CHUNK_BYTES = 1024 * 1024

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
    # Time and horizon axes shrink first, then the others.
    sort!(shrinkable; by = i -> (!(axes[i] in ("time", "horizon")), i))
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
Build the `InfrastructureOutputSchemas.Dataset` of the key type `T`, the component type `U`, and `meta`.
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
Build the `InfrastructureOutputSchemas.Dataset` of the key type `T` and `meta` for a dataset that
has no component (no `component_type`). Other arguments follow the component method.
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
    return _dataset_descriptor(
        T, OpenAPI.Runtime.ABSENT, meta, model, axes, axis_lengths, dtype, filters,
    )
end

function _dataset_descriptor(
    ::Type{T},
    component_type::Union{String, OpenAPI.Runtime.Absent},
    meta::AbstractString,
    model::AbstractString,
    axes::Vector{String},
    axis_lengths::Vector{Int},
    dtype::String,
    filters::Vector{String},
) where {T <: Optimization.OptimizationKeyType}
    unit_system = Optimization.output_unit_system(T)
    entry_type = string(nameof(T))
    name = dataset_name(entry_type, _optional_string(component_type), meta)
    return InfrastructureOutputSchemas.Dataset(;
        container = InfrastructureOutputSchemas.Container(Optimization.container_name(T)),
        entry_type = entry_type,
        component_type = component_type,
        meta = String(meta),
        axes = axes,
        dtype = InfrastructureOutputSchemas.Dtype(dtype),
        fill_value = _DTYPES[dtype][2],
        quantity_kind = Optimization.quantity_kind(T),
        unit_system = InfrastructureOutputSchemas.UnitSystem(unit_system_name(unit_system)),
        units = output_units(unit_system, T),
        layout = InfrastructureOutputSchemas.DatasetLayout(;
            chunks = _chunk_shape(axes, axis_lengths, sizeof(_DTYPES[dtype][1])),
            filters = filters,
        ),
        path = string("/", model, "/datasets/", name),
    )
end
