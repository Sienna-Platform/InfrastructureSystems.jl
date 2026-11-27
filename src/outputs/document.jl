# Storage type and default fill value of each dataset dtype. Bool is stored as UInt8; the
# reader converts it back. Table columns also allow variable-length strings.
const _DTYPES = Dict(
    "f64" => (Float64, "NaN"),
    "f32" => (Float32, "NaN"),
    "i64" => (Int64, 0),
    "i32" => (Int32, 0),
    "bool" => (UInt8, false),
)

function _column_storage_type(dtype::String)
    if dtype == "str"
        return String
    end
    return _DTYPES[dtype][1]
end

function _find_model(doc::OutputsDocument, model_name::AbstractString)
    i = findfirst(model -> model.name == model_name, doc.models)
    if isnothing(i)
        throw(ArgumentError("unknown model $model_name"))
    end
    return doc.models[i]
end

function _has_axis(model::OutputsModel, name::AbstractString)
    return any(axis -> axis_name(axis) == name, model.axes)
end

function _find_axis(model::OutputsModel, name::AbstractString)
    i = findfirst(axis -> axis_name(axis) == name, model.axes)
    if isnothing(i)
        throw(ArgumentError("model $(model.name): unknown axis $name"))
    end
    return model.axes[i]
end

function _find_dataset(model::OutputsModel, key::Tuple)
    i = findfirst(dataset -> dataset_key(dataset) == key, model.datasets)
    if isnothing(i)
        throw(ArgumentError("model $(model.name): no dataset $key"))
    end
    return model.datasets[i]
end

# The axes of the dataset in storage order, as the document `axes` list them.
function _dataset_axes(model::OutputsModel, dataset::OutputDataset)
    return OutputAxis[_find_axis(model, name) for name in dataset.axes]
end

# Size of the dataset in Julia order: the reverse of the document `axes`.
_dataset_dims(axes::Vector{OutputAxis}) = reverse(Int[axis_length(axis) for axis in axes])

_dataset_dims(model::OutputsModel, dataset::OutputDataset) =
    _dataset_dims(_dataset_axes(model, dataset))

function _find_table(doc::OutputsDocument, model_name::AbstractString, name::AbstractString)
    tables = _find_model(doc, model_name).tables
    i = findfirst(table -> table.name == name, tables)
    if isnothing(i)
        throw(ArgumentError("model $model_name: no table $name"))
    end
    return tables[i]
end

function _check_values_size(
    model_name::AbstractString,
    key,
    values::AbstractArray,
    expected::Tuple,
)
    if size(values) != expected
        throw(
            ArgumentError(
                "model $model_name: dataset $key values have size $(size(values)), expected $expected",
            ),
        )
    end
    return
end

"""
Return `true` when the document has simulation parameters.
"""
has_simulation(doc::OutputsDocument) = _has_simulation(doc.simulation)

_has_simulation(::Simulation.SimulationParams) = true
_has_simulation(::Simulation.NoSimulation) = false

"""
Return the `Simulation.SimulationParams` of the document. Throw an error when absent.
"""
get_simulation(doc::OutputsDocument) = _get_simulation(doc.simulation, doc.kind)

_get_simulation(simulation::Simulation.SimulationParams, ::String) = simulation

function _get_simulation(::Simulation.NoSimulation, kind::String)
    error("outputs document of kind $kind has no simulation parameters")
end

"""
Return the dataset name `EntryType__ComponentType[__meta]`. A dataset without a component
type is named `EntryType[__meta]`.
"""
function dataset_name(dataset::OutputDataset)
    return dataset_name(dataset_key(dataset)...)
end

function dataset_name(
    entry_type::AbstractString,
    component_type::AbstractString,
    meta::AbstractString,
)
    parts = String[entry_type]
    if !isempty(component_type)
        push!(parts, component_type)
    end
    if !isempty(meta)
        push!(parts, meta)
    end
    return join(parts, "__")
end

"""
Read an `outputs.json` file into an `OutputsDocument`. Throw
a `SchemaValidationError` of the OpenAPI runtime when the file does not satisfy the outputs
schema. Throw `ArgumentError` when a derived field (`group` or `path`) differs from the value
that IS derives, or when a timestamp is not a valid date and time.
"""
function read_outputs_document(path::AbstractString)
    return _decode_document(JSON.parse(read(path, String)))
end

"""
Write `doc` to `path` as pretty-printed JSON. Write a temporary file in the same directory,
then rename it to `path`. The rename replaces `path` in one operation. When the write or the
rename fails, `path` keeps its previous contents.
"""
function write_outputs_document(path::AbstractString, doc::OutputsDocument)
    json = _encode_document(doc)
    tmp = string(path, _STAGING_SUFFIX)
    try
        open(tmp, "w") do io
            JSON.json(io, json; pretty = 2)
        end
        # `mv` with `force = true` can delete `path` before it renames `tmp`.
        Base.Filesystem.rename(tmp, path)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return
end

"""
Return the document `doc` with `status` (and optionally `created_at`) replaced.
"""
function with_status(
    doc::OutputsDocument,
    status::Simulation.RunStatus.Value;
    created_at::TimeZones.ZonedDateTime = doc.created_at,
)
    return OutputsDocument(
        doc.schema_version,
        doc.kind,
        doc.producer,
        created_at,
        status,
        doc.systems,
        doc.simulation,
        doc.models,
    )
end

"""
Return the `units` string of the output schema for a unit system and a key type.
"""
function output_units end
output_units(::SystemBaseUnit, ::Type) = "pu"
output_units(::ComponentBaseUnit, ::Type) = "pu"
output_units(::NaturalUnit, ::Type{T}) where {T} = Optimization.natural_units(T)

"""
Return the dataset key `(entry_type, component_type, meta)` of the dataset. The component type is `""` when
the dataset has none.
"""
dataset_key(dataset::OutputDataset) =
    (dataset.entry_type, dataset.component_type, dataset.meta)

"""
Return the HDF5 group of the axis: `/<model name>/axes/<axis name>`.
"""
axis_group(model_name::AbstractString, axis::OutputAxis) =
    "/$model_name/axes/$(axis_name(axis))"

"""
Return the HDF5 path of the dataset: `/<model name>/datasets/<dataset name>`.
"""
dataset_path(model_name::AbstractString, dataset::OutputDataset) =
    "/$model_name/datasets/$(dataset_name(dataset))"

"""
Return the HDF5 group of the table: `/<model name>/tables/<table name>`.
"""
table_group(model_name::AbstractString, table::OutputTable) =
    "/$model_name/tables/$(table.name)"
