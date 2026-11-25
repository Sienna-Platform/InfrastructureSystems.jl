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

# The generated types spell an absent optional field as `ABSENT` or `nothing`. The schema
# rejects an explicit `nothing`, so only `validate_document` can tell the two apart.
_optional_string(s::String) = s
_optional_string(::Union{OpenAPI.Runtime.Absent, Nothing}) = ""

_model_tables(model::InfrastructureOutputSchemas.Model) = _model_tables(model.tables)
_model_tables(tables::Vector{InfrastructureOutputSchemas.Table}) = tables
_model_tables(::Union{OpenAPI.Runtime.Absent, Nothing}) =
    InfrastructureOutputSchemas.Table[]

_systems(doc::InfrastructureOutputSchemas.OutputsDocument) =
    doc.systems.additional_properties

# The concrete axis of each `InfrastructureOutputSchemas.Axis` of the model.
_axes(model::InfrastructureOutputSchemas.Model) = (axis.value for axis in model.axes)

function _find_model(
    doc::InfrastructureOutputSchemas.OutputsDocument,
    model_name::AbstractString,
)
    i = findfirst(model -> model.name == model_name, doc.models)
    if isnothing(i)
        throw(ArgumentError("unknown model $model_name"))
    end
    return doc.models[i]
end

function _has_axis(model::InfrastructureOutputSchemas.Model, name::AbstractString)
    return any(axis -> axis_name(axis) == name, model.axes)
end

function _find_axis(model::InfrastructureOutputSchemas.Model, name::AbstractString)
    i = findfirst(axis -> axis_name(axis) == name, model.axes)
    if isnothing(i)
        throw(ArgumentError("model $(model.name): unknown axis $name"))
    end
    return model.axes[i].value
end

function _find_dataset(model::InfrastructureOutputSchemas.Model, key::Tuple)
    i = findfirst(dataset -> dataset_key(dataset) == key, model.datasets)
    if isnothing(i)
        throw(ArgumentError("model $(model.name): no dataset $key"))
    end
    return model.datasets[i]
end

# Size of the dataset in Julia order: the reverse of the document `axes`.
function _dataset_dims(
    model::InfrastructureOutputSchemas.Model,
    dataset::InfrastructureOutputSchemas.Dataset,
)
    return reverse([axis_length(_find_axis(model, name)) for name in dataset.axes])
end

function _find_table(
    doc::InfrastructureOutputSchemas.OutputsDocument,
    model_name::AbstractString,
    name::AbstractString,
)
    tables = _model_tables(_find_model(doc, model_name))
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
function has_simulation(doc::InfrastructureOutputSchemas.OutputsDocument)
    return _has_simulation(doc.simulation)
end

_has_simulation(::InfrastructureOutputSchemas.SimulationParams) = true
_has_simulation(::Union{OpenAPI.Runtime.Absent, Nothing}) = false

"""
Return the `InfrastructureOutputSchemas.SimulationParams` of the document. Throw an error when absent.
"""
function get_simulation(doc::InfrastructureOutputSchemas.OutputsDocument)
    return _get_simulation(doc.simulation, string(doc.kind))
end

_get_simulation(s::InfrastructureOutputSchemas.SimulationParams, ::String) = s

function _get_simulation(::Union{OpenAPI.Runtime.Absent, Nothing}, kind::String)
    error("outputs document of kind $kind has no simulation parameters")
end

"""
Return the resolution of the axis as `Dates.Millisecond`.
"""
function get_resolution(
    axis::Union{
        InfrastructureOutputSchemas.TimeAxis,
        InfrastructureOutputSchemas.HorizonAxis,
    },
)
    return parse_iso_duration(axis.resolution)
end

"""
Return the interval of the execution axis as `Dates.Millisecond`.
"""
function get_interval(axis::InfrastructureOutputSchemas.ExecutionAxis)
    return parse_iso_duration(axis.interval)
end

"""
Return the full horizon of the axis as `Dates.Millisecond`. Throw `OverflowError` when the
horizon is too long for `Int64` milliseconds.
"""
function get_horizon(axis::InfrastructureOutputSchemas.HorizonAxis)
    ms = Base.checked_mul(axis.horizon_count, Dates.value(get_resolution(axis)))
    return Dates.Millisecond(ms)
end

"""
Return the dataset key `(entry_type, component_type, meta)` of the dataset. The component type is `""` when
the dataset has none.
"""
function dataset_key(dataset::InfrastructureOutputSchemas.Dataset)
    return (dataset.entry_type, _optional_string(dataset.component_type), dataset.meta)
end

"""
Return the dataset name `EntryType__ComponentType[__meta]`. A dataset without a component
type is named `EntryType[__meta]`.
"""
function dataset_name(dataset::InfrastructureOutputSchemas.Dataset)
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
Read an `outputs.json` file into an `InfrastructureOutputSchemas.OutputsDocument`. Throw
`InfrastructureOutputSchemas.SchemaValidationError` when the file does not satisfy the outputs schema.
"""
function read_outputs_document(path::AbstractString)
    return InfrastructureOutputSchemas.decode(
        InfrastructureOutputSchemas.OutputsDocument,
        JSON.parse(read(path, String)),
    )
end

"""
Write `doc` to `path` as pretty-printed JSON. Write a temporary file in the same directory,
then move it to `path`. When the write fails, `path` keeps its previous contents.
"""
function write_outputs_document(
    path::AbstractString,
    doc::InfrastructureOutputSchemas.OutputsDocument,
)
    json = InfrastructureOutputSchemas.encode(doc)
    tmp = string(path, ".tmp")
    try
        open(tmp, "w") do io
            JSON.json(io, json; pretty = 2)
        end
        mv(tmp, path; force = true)
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
    doc::InfrastructureOutputSchemas.OutputsDocument,
    status::String;
    created_at::TimeZones.ZonedDateTime = doc.created_at,
)
    return InfrastructureOutputSchemas.OutputsDocument(;
        schema_version = doc.schema_version,
        kind = doc.kind,
        producer = doc.producer,
        created_at = created_at,
        status = InfrastructureOutputSchemas.RunStatus(status),
        systems = doc.systems,
        simulation = doc.simulation,
        models = doc.models,
    )
end

"""
Return the `unit_system` string of the output schema for a unit system.
"""
function unit_system_name end
unit_system_name(::SystemBaseUnit) = "SYSTEM_BASE"
unit_system_name(::ComponentBaseUnit) = "COMPONENT_BASE"
unit_system_name(::NaturalUnit) = "NATURAL_UNITS"

"""
Return the `units` string of the output schema for a unit system and a key type.
"""
function output_units end
output_units(::SystemBaseUnit, ::Type) = "pu"
output_units(::ComponentBaseUnit, ::Type) = "pu"
output_units(::NaturalUnit, ::Type{T}) where {T} = Optimization.natural_units(T)
