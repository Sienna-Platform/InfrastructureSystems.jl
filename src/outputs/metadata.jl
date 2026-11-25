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
# rejects an explicit `nothing`, so only `validate_metadata` can tell the two apart.
_optional_string(s::String) = s
_optional_string(::Union{OpenAPI.Runtime.Absent, Nothing}) = ""

_model_tables(entry::InfrastructureOutputSchemas.Model) = _model_tables(entry.tables)
_model_tables(tables::Vector{InfrastructureOutputSchemas.Table}) = tables
_model_tables(::Union{OpenAPI.Runtime.Absent, Nothing}) =
    InfrastructureOutputSchemas.Table[]

_systems(m::InfrastructureOutputSchemas.OutputsDocument) = m.systems.additional_properties

# The concrete axis of each `InfrastructureOutputSchemas.Axis` of the model.
_axes(entry::InfrastructureOutputSchemas.Model) = (a.value for a in entry.axes)

function _model_entry(m::InfrastructureOutputSchemas.OutputsDocument, model::AbstractString)
    i = findfirst(e -> e.name == model, m.models)
    if isnothing(i)
        throw(ArgumentError("unknown model $model"))
    end
    return m.models[i]
end

function _has_axis(entry::InfrastructureOutputSchemas.Model, name::AbstractString)
    return any(a -> axis_key(a) == name, entry.axes)
end

function _find_axis(entry::InfrastructureOutputSchemas.Model, name::AbstractString)
    i = findfirst(a -> axis_key(a) == name, entry.axes)
    if isnothing(i)
        throw(ArgumentError("model $(entry.name): unknown axis $name"))
    end
    return entry.axes[i].value
end

function _find_dataset(
    m::InfrastructureOutputSchemas.OutputsDocument,
    model::AbstractString,
    key::Tuple,
)
    entry = _model_entry(m, model)
    i = findfirst(d -> dataset_key(d) == key, entry.datasets)
    if isnothing(i)
        throw(ArgumentError("model $model: no dataset $key"))
    end
    return entry.datasets[i]
end

function _find_table(
    m::InfrastructureOutputSchemas.OutputsDocument,
    model::AbstractString,
    name::AbstractString,
)
    tables = _model_tables(_model_entry(m, model))
    i = findfirst(t -> t.name == name, tables)
    if isnothing(i)
        throw(ArgumentError("model $model: no table $name"))
    end
    return tables[i]
end

function _check_values_size(
    model::AbstractString,
    key,
    values::AbstractArray,
    expected::Tuple,
)
    if size(values) != expected
        throw(
            ArgumentError(
                "model $model: dataset $key values have size $(size(values)), expected $expected",
            ),
        )
    end
    return
end

"""
Return `true` when the document has simulation parameters.
"""
function has_simulation(m::InfrastructureOutputSchemas.OutputsDocument)
    return _has_simulation(m.simulation)
end

_has_simulation(::InfrastructureOutputSchemas.SimulationParams) = true
_has_simulation(::Union{OpenAPI.Runtime.Absent, Nothing}) = false

"""
Return the `InfrastructureOutputSchemas.SimulationParams` of the document. Throw an error when absent.
"""
function get_simulation(m::InfrastructureOutputSchemas.OutputsDocument)
    return _get_simulation(m.simulation, string(m.kind))
end

_get_simulation(s::InfrastructureOutputSchemas.SimulationParams, ::String) = s

function _get_simulation(::Union{OpenAPI.Runtime.Absent, Nothing}, kind::String)
    error("outputs metadata of kind $kind has no simulation parameters")
end

"""
Return the resolution of the axis as `Dates.Millisecond`.
"""
function get_resolution(
    a::Union{InfrastructureOutputSchemas.TimeAxis, InfrastructureOutputSchemas.HorizonAxis},
)
    return parse_iso_duration(a.resolution)
end

"""
Return the interval of the execution axis as `Dates.Millisecond`.
"""
function get_interval(a::InfrastructureOutputSchemas.ExecutionAxis)
    return parse_iso_duration(a.interval)
end

"""
Return the full horizon of the axis as `Dates.Millisecond`. Throw `OverflowError` when the
horizon is too long for `Int64` milliseconds.
"""
function get_horizon(a::InfrastructureOutputSchemas.HorizonAxis)
    ms = Base.checked_mul(a.horizon_count, Dates.value(get_resolution(a)))
    return Dates.Millisecond(ms)
end

"""
Return `(entry_type, component_type, meta)` of the dataset. The component type is `""` when
the dataset has none.
"""
function dataset_key(d::InfrastructureOutputSchemas.Dataset)
    return (d.entry_type, _optional_string(d.component_type), d.meta)
end

"""
Return the dataset name `EntryType__ComponentType[__meta]`. A dataset without a component
type is named `EntryType[__meta]`.
"""
function dataset_name(d::InfrastructureOutputSchemas.Dataset)
    return dataset_name(dataset_key(d)...)
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
function read_outputs_metadata(path::AbstractString)
    return InfrastructureOutputSchemas.decode(
        InfrastructureOutputSchemas.OutputsDocument,
        JSON.parse(read(path, String)),
    )
end

"""
Write `m` to `path` as pretty-printed JSON. Write a temporary file in the same directory,
then move it to `path`. When the write fails, `path` keeps its previous contents.
"""
function write_outputs_metadata(
    path::AbstractString,
    m::InfrastructureOutputSchemas.OutputsDocument,
)
    doc = InfrastructureOutputSchemas.encode(m)
    tmp = string(path, ".tmp")
    try
        open(tmp, "w") do io
            JSON.json(io, doc; pretty = 2)
        end
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return
end

"""
Return the document `m` with `status` (and optionally `created_at`) replaced.
"""
function with_status(
    m::InfrastructureOutputSchemas.OutputsDocument,
    status::String;
    created_at::TimeZones.ZonedDateTime = m.created_at,
)
    return InfrastructureOutputSchemas.OutputsDocument(;
        schema_version = m.schema_version,
        kind = m.kind,
        producer = m.producer,
        created_at = created_at,
        status = InfrastructureOutputSchemas.RunStatus(status),
        systems = m.systems,
        simulation = m.simulation,
        models = m.models,
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
