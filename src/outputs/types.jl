"""
Supertype of the axes of an outputs dataset.
"""
abstract type OutputAxis end

"""
Axis of regularly spaced timestamps.
"""
struct TimeAxis <: OutputAxis
    initial_timestamp::Dates.DateTime
    resolution::Dates.Millisecond
    length::Int
end

"""
Axis of the start times of the executions of a model.
"""
struct ExecutionAxis <: OutputAxis
    initial_timestamp::Dates.DateTime
    interval::Dates.Millisecond
    count::Int
end

"""
Axis of the steps of a forecast horizon.
"""
struct HorizonAxis <: OutputAxis
    resolution::Dates.Millisecond
    horizon_count::Int
end

"""
One component type of a component axis.
"""
struct ComponentAxisColumn
    component_type::String
    has_ids::Bool
end

"""
Axis of components. `subset` is `""` when the axis has no subset.
"""
struct ComponentAxis <: OutputAxis
    columns::Vector{ComponentAxisColumn}
    length::Int
    subset::String
end

ComponentAxis(columns, length) = ComponentAxis(columns, length, "")

"""
Axis of named labels.
"""
struct LabelAxis <: OutputAxis
    name::String
    labels::Vector{String}
end

"""
Description of one dataset of the HDF5 file. `component_type` is `""` when the dataset has
no component.
"""
struct OutputDataset
    container::String
    entry_type::String
    component_type::String
    meta::String
    axes::Vector{String}
    dtype::String
    fill_value::Union{String, Float64, Int64, Bool}
    quantity_kind::String
    unit_system::AbstractUnitSystem
    units::String
    chunks::Vector{Int}
    filters::Vector{String}
end

"""
Quantity kind, unit system, and units of a table column.
"""
struct ColumnUnits
    quantity_kind::String
    unit_system::AbstractUnitSystem
    units::String
end

"""
Column of an output table. Build a column with no units from a name and a dtype. Build a
column with units from a name, a dtype, a quantity kind, a unit system, and units.
"""
struct OutputColumn
    name::String
    dtype::String
    unit_info::Union{Nothing, ColumnUnits}
end

OutputColumn(name, dtype) = OutputColumn(name, dtype, nothing)

function OutputColumn(name, dtype, quantity_kind, unit_system, units)
    return OutputColumn(name, dtype, ColumnUnits(quantity_kind, unit_system, units))
end

"""
Table of an outputs model. `length` is the number of rows.
"""
struct OutputTable
    name::String
    length::Int
    columns::Vector{OutputColumn}
end

"""
One model of an outputs document, with its axes, datasets, and tables.
"""
Base.@kwdef struct OutputsModel
    name::String
    model_type::String
    system_uuid::String
    base_power::Float64
    supports_realized_values_post_calculation::Bool
    settings::Dict{String, Any}
    axes::Vector{OutputAxis}
    datasets::Vector{OutputDataset}
    tables::Vector{OutputTable} = OutputTable[]
end

"""
Package, package version, and Julia version of the producer of a document.
"""
struct ProducerInfo
    package::String
    version::String
    julia::String
end

"""
The content of `outputs.json`.
"""
struct OutputsDocument
    schema_version::String
    kind::String
    producer::ProducerInfo
    created_at::TimeZones.ZonedDateTime
    status::Simulation.RunStatus.Value
    systems::Dict{String, String}
    simulation::Simulation.AbstractSimulation
    models::Vector{OutputsModel}
end

"""
Build a document from the producer fields. IS fills `schema_version`, `created_at` (now, in
UTC), and the status `RUNNING`. The method without `simulation` gives a document with no
simulation.
"""
function OutputsDocument(kind, producer, systems, models, simulation)
    return OutputsDocument(
        OUTPUTS_SCHEMA_VERSION,
        kind,
        producer,
        TimeZones.now(TimeZones.tz"UTC"),
        Simulation.RunStatus.RUNNING,
        systems,
        simulation,
        models,
    )
end

function OutputsDocument(kind, producer, systems, models)
    return OutputsDocument(kind, producer, systems, models, Simulation.NoSimulation())
end

"""
Return the initial timestamp of the axis.
"""
get_initial_timestamp(axis::Union{TimeAxis, ExecutionAxis}) = axis.initial_timestamp

"""
Return the resolution of the axis as `Dates.Millisecond`.
"""
get_resolution(axis::Union{TimeAxis, HorizonAxis}) = axis.resolution

"""
Return the interval of the execution axis as `Dates.Millisecond`.
"""
get_interval(axis::ExecutionAxis) = axis.interval

"""
Return the full horizon of the axis as `Dates.Millisecond`. Throw `OverflowError` when the
horizon is too long for `Int64` milliseconds.
"""
function get_horizon(axis::HorizonAxis)
    ms = Base.checked_mul(axis.horizon_count, Dates.value(axis.resolution))
    return Dates.Millisecond(ms)
end

"""
Return the labels of the axis.
"""
get_labels(axis::LabelAxis) = axis.labels

"""
Return the axis names of the dataset in storage order.
"""
get_axis_names(dataset::OutputDataset) = dataset.axes

"""
Return `true` when the column has units.
"""
has_units(column::OutputColumn) = _has_units(column.unit_info)

_has_units(::ColumnUnits) = true
_has_units(::Nothing) = false

"""
Return the quantity kind of the column. Throw `ArgumentError` when the column has no units.
"""
get_quantity_kind(column::OutputColumn) =
    _unit_info(column, column.unit_info).quantity_kind

"""
Return the unit system of the column. Throw `ArgumentError` when the column has no units.
"""
get_unit_system(column::OutputColumn) = _unit_info(column, column.unit_info).unit_system

"""
Return the units of the column. Throw `ArgumentError` when the column has no units.
"""
get_units(column::OutputColumn) = _unit_info(column, column.unit_info).units

_unit_info(::OutputColumn, info::ColumnUnits) = info

function _unit_info(column::OutputColumn, ::Nothing)
    throw(ArgumentError("column $(column.name) has no units"))
end

"""
Return the `status` of the `OutputsDocument`.
"""
get_status(doc::OutputsDocument) = doc.status

"""
Return the `models` of the `OutputsDocument`.
"""
get_models(doc::OutputsDocument) = doc.models

"""
Return the `systems` of the `OutputsDocument`.
"""
get_systems(doc::OutputsDocument) = doc.systems

"""
Return the `name` of the `OutputsModel`.
"""
get_name(model::OutputsModel) = model.name

"""
Return the `datasets` of the `OutputsModel`.
"""
get_datasets(model::OutputsModel) = model.datasets

"""
Return the `supports_realized_values_post_calculation` of the `OutputsModel`.
"""
get_supports_realized_values_post_calculation(model::OutputsModel) =
    model.supports_realized_values_post_calculation

"""
Return the `container` of the `OutputDataset`.
"""
get_container(dataset::OutputDataset) = dataset.container

"""
Return the `entry_type` of the `OutputDataset`.
"""
get_entry_type(dataset::OutputDataset) = dataset.entry_type

"""
Return the `component_type` of the `OutputDataset`.
"""
get_component_type(dataset::OutputDataset) = dataset.component_type

"""
Return the `meta` of the `OutputDataset`.
"""
get_meta(dataset::OutputDataset) = dataset.meta

"""
Return the `chunks` of the `OutputDataset`.
"""
get_chunks(dataset::OutputDataset) = dataset.chunks

"""
Return the `columns` of the `ComponentAxis`.
"""
get_columns(axis::ComponentAxis) = axis.columns

"""
Return the `component_type` of the `ComponentAxisColumn`.
"""
get_component_type(column::ComponentAxisColumn) = column.component_type

"""
Return the `has_ids` of the `ComponentAxisColumn`.
"""
get_has_ids(column::ComponentAxisColumn) = column.has_ids

"""
Return the `name` of the `OutputTable`.
"""
get_name(table::OutputTable) = table.name

"""
Return the `length` of the `OutputTable`.
"""
get_length(table::OutputTable) = table.length

"""
Return the `columns` of the `OutputTable`.
"""
get_columns(table::OutputTable) = table.columns

"""
Return the `name` of the `OutputColumn`.
"""
get_name(column::OutputColumn) = column.name
