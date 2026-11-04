const StructUtils = JSON.StructUtils

abstract type AbstractAxis end

"Time axis of a model that runs without an execution loop."
struct TimeAxis <: AbstractAxis
    kind::String
    initial_timestamp::Dates.DateTime
    resolution::String
    length::Int
    group::String
end

"Execution axis of a decision model: one entry per solve."
struct ExecutionAxis <: AbstractAxis
    kind::String
    initial_timestamp::Dates.DateTime
    interval::String
    count::Int
    group::String
end

"Horizon axis of a decision model: the steps inside one solve."
struct HorizonAxis <: AbstractAxis
    kind::String
    resolution::String
    horizon_count::Int
end

"One component-type column of a `ComponentAxis`."
struct AxisColumn
    component_type::String
    has_ids::Bool
end

"Axis that lists components. A tuple of component types makes one column per type."
JSON.@defaults struct ComponentAxis <: AbstractAxis
    kind::String
    columns::Vector{AxisColumn}
    length::Int
    group::String
    subset::String = ""
end

"Axis that lists plain labels."
struct LabelAxis <: AbstractAxis
    kind::String
    labels::Vector{String}
end

"HDF5 chunk shape and filter names of a dataset."
struct DatasetLayout
    chunks::Vector{Int}
    filters::Vector{String}
end

# Field lowering that drops an empty optional string from the written JSON.
function _omit_if_empty(s::AbstractString)
    if isempty(s)
        return JSON.Omit()
    end
    return s
end

"""
Description of one HDF5 dataset that stores one entry of a model. An empty
`component_type` or `base_reference` is omitted from the written JSON.
"""
JSON.@defaults struct OutputDataset
    entry_type::String
    meta::String
    axes::Vector{String}
    dtype::String
    fill_value::Union{String, Float64, Int64, Bool}
    quantity_kind::String
    unit_system::String
    units::String
    layout::DatasetLayout
    path::String
    container::String
    component_type::String = "" & (json = (lower = _omit_if_empty,),)
    base_reference::String = "" & (json = (lower = _omit_if_empty,),)
end

"""
Description of one column of an `OutputTable`. Empty unit fields are omitted from the
written JSON.
"""
JSON.@defaults struct OutputColumn
    name::String
    dtype::String
    quantity_kind::String = "" & (json = (lower = _omit_if_empty,),)
    unit_system::String = "" & (json = (lower = _omit_if_empty,),)
    base_reference::String = "" & (json = (lower = _omit_if_empty,),)
    units::String = "" & (json = (lower = _omit_if_empty,),)
end

"Description of one HDF5 table group."
struct OutputTable
    name::String
    group::String
    length::Int
    columns::Vector{OutputColumn}
end

"Description of the outputs of one model."
JSON.@defaults struct ModelEntry
    model_type::String
    system_uuid::String
    base_power::Float64
    settings::Dict{String, Any}
    axes::Dict{String, AbstractAxis}
    datasets::Vector{OutputDataset}
    tables::Vector{OutputTable} = OutputTable[]
end

"Package, package version, and Julia version that wrote the outputs."
struct ProducerInfo
    package::String
    version::String
    julia::String
end

"Simulation-wide parameters. Only present when `kind` is `simulation`."
struct SimulationParams
    initial_time::Dates.DateTime
    step_resolution::String
    num_steps::Int
    execution_order::Vector{String}
end

"""
Content of the `outputs.json` file. The `simulation` field is `nothing` when the file
omits it. Use `has_simulation` and `get_simulation` to access it.
"""
JSON.@defaults struct OutputsMetadata
    schema_version::String
    kind::String
    producer::ProducerInfo
    created_at::String
    status::String
    systems::Dict{String, String}
    models::Dict{String, ModelEntry}
    simulation::Union{Nothing, SimulationParams} = nothing
end

JSON.omit_null(::Type{OutputsMetadata}) = true

function _axis_type(kind::AbstractString)
    if kind == "time"
        return TimeAxis
    elseif kind == "execution"
        return ExecutionAxis
    elseif kind == "horizon"
        return HorizonAxis
    elseif kind == "component"
        return ComponentAxis
    elseif kind == "label"
        return LabelAxis
    end
    throw(ArgumentError("unknown outputs axis kind: $kind"))
end

JSON.@choosetype AbstractAxis x -> _axis_type(x.kind[])

for T in (
    TimeAxis,
    ExecutionAxis,
    HorizonAxis,
    AxisColumn,
    ComponentAxis,
    LabelAxis,
    DatasetLayout,
    OutputDataset,
    OutputColumn,
    OutputTable,
    ModelEntry,
    ProducerInfo,
    SimulationParams,
    OutputsMetadata,
)
    @eval function Base.:(==)(a::$T, b::$T)
        return double_equals_from_fields(a, b)
    end
    @eval function Base.hash(a::$T, h::UInt)
        return hash_from_fields(a, h)
    end
end

# Storage type and default fill value of each dataset dtype. Bool is stored as UInt8; the
# reader converts it back. Table columns also allow variable-length strings.
const _DTYPES = Dict(
    "f64" => (Float64, "NaN"),
    "f32" => (Float32, "NaN"),
    "i64" => (Int64, 0),
    "i32" => (Int32, 0),
    "bool" => (UInt8, false),
)
const _COLUMN_DTYPES = ("f64", "i64", "bool", "str")

function _column_storage_type(dtype::String)
    if dtype == "str"
        return String
    end
    return _DTYPES[dtype][1]
end

function _model_entry(m::OutputsMetadata, model::AbstractString)
    if !haskey(m.models, model)
        throw(ArgumentError("unknown model $model"))
    end
    return m.models[model]
end

function _find_dataset(m::OutputsMetadata, model::AbstractString, key::Tuple)
    entry = _model_entry(m, model)
    i = findfirst(d -> dataset_key(d) == key, entry.datasets)
    if isnothing(i)
        throw(ArgumentError("model $model: no dataset $key"))
    end
    return entry.datasets[i]
end

function _find_table(m::OutputsMetadata, model::AbstractString, name::AbstractString)
    entry = _model_entry(m, model)
    i = findfirst(t -> t.name == name, entry.tables)
    if isnothing(i)
        throw(ArgumentError("model $model: no table $name"))
    end
    return entry.tables[i]
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
Return `true` when the metadata has simulation parameters.
"""
function has_simulation(m::OutputsMetadata)
    return !isnothing(m.simulation)
end

"""
Return the `SimulationParams` of the metadata. Throw an error when absent.
"""
function get_simulation(m::OutputsMetadata)
    if !has_simulation(m)
        error("outputs metadata of kind $(m.kind) has no simulation parameters")
    end
    return m.simulation
end

"""
Return the resolution of the axis as `Dates.Millisecond`.
"""
function get_resolution(a::Union{TimeAxis, HorizonAxis})
    return parse_iso_duration(a.resolution)
end

"""
Return the interval of the execution axis as `Dates.Millisecond`.
"""
function get_interval(a::ExecutionAxis)
    return parse_iso_duration(a.interval)
end

"""
Return the full horizon of the axis as `Dates.Millisecond`.
"""
function get_horizon(a::HorizonAxis)
    return a.horizon_count * get_resolution(a)
end

"""
Return `(entry_type, component_type, meta)` of the dataset.
"""
function dataset_key(d::OutputDataset)
    return (d.entry_type, d.component_type, d.meta)
end

"""
Return the dataset name `EntryType__ComponentType[__meta]`. A dataset without a component
type is named `EntryType[__meta]`.
"""
function dataset_name(d::OutputDataset)
    return dataset_name(d.entry_type, d.component_type, d.meta)
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
Read and parse an `outputs.json` file. Throw an error on unknown keys.
"""
function read_outputs_metadata(path::AbstractString)
    return JSON.parse(read(path, String), OutputsMetadata; unknown_fields = :error)
end

"""
Write `m` to `path` as pretty-printed JSON.
"""
function write_outputs_metadata(path::AbstractString, m::OutputsMetadata)
    open(path, "w") do io
        JSON.json(io, m; pretty = 2)
    end
    return
end

"""
Return the metadata `m` with `status` (and optionally `created_at`) replaced.
"""
function with_status(m::OutputsMetadata, status::String; created_at::String = m.created_at)
    return OutputsMetadata(
        m.schema_version, m.kind, m.producer, created_at, status, m.systems, m.models,
        m.simulation,
    )
end

"""
Return the `(unit_system, base_reference)` strings of the output schema for a unit system.
"""
function unit_system_pair end
unit_system_pair(::SystemBaseUnit) = ("COMPONENT_BASE", "system")
unit_system_pair(::ComponentBaseUnit) = ("COMPONENT_BASE", "component")
unit_system_pair(::NaturalUnit) = ("NATURAL_UNITS", "")

"""
Return the `units` string of the output schema for a unit system and a key type.
"""
function output_units end
output_units(::SystemBaseUnit, ::Type) = "pu"
output_units(::ComponentBaseUnit, ::Type) = "pu"
output_units(::NaturalUnit, ::Type{T}) where {T} = Optimization.natural_units(T)
