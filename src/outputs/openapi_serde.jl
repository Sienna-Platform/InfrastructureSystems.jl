# Serde between the IS outputs types and the generated OpenAPI structs of
# InfrastructureOutputSchemas. This is the only file of IS that names that package.

"""
Return the `unit_system` string of the output schema for a unit system.
"""
function unit_system_name end
unit_system_name(::SystemBaseUnit) = "SYSTEM_BASE"
unit_system_name(::ComponentBaseUnit) = "COMPONENT_BASE"
unit_system_name(::NaturalUnit) = "NATURAL_UNITS"

const _WIRE_UNIT_SYSTEMS =
    Dict(unit_system_name(unit_system) => unit_system for unit_system in (SU, CU, NU))

const _WIRE_RUN_STATUS = Dict(
    string(status) => status for status in (
        Simulation.RunStatus.RUNNING,
        Simulation.RunStatus.SUCCESSFULLY_FINALIZED,
        Simulation.RunStatus.FAILED,
    )
)

# An optional wire field is a value, `ABSENT`, or `nothing`.
_wire_optional(value::AbstractString) = value
_wire_optional(::Union{OpenAPI.Runtime.Absent, Nothing}) = ""

function _absent_if_empty(value)
    if isempty(value)
        return OpenAPI.Runtime.ABSENT
    end
    return value
end

_column_units(::Nothing) =
    (OpenAPI.Runtime.ABSENT, OpenAPI.Runtime.ABSENT, OpenAPI.Runtime.ABSENT)

function _column_units(info::ColumnUnits)
    return (
        info.quantity_kind,
        InfrastructureOutputSchemas.UnitSystem(unit_system_name(info.unit_system)),
        info.units,
    )
end

_simulation_to_openapi(::Simulation.NoSimulation) = OpenAPI.Runtime.ABSENT
_simulation_to_openapi(params::Simulation.SimulationParams) = to_openapi(params)

_simulation_from_openapi(::Union{OpenAPI.Runtime.Absent, Nothing}) =
    Simulation.NoSimulation()
_simulation_from_openapi(params::InfrastructureOutputSchemas.SimulationParams) =
    from_openapi(params)

function _parse_timestamp(
    where_::AbstractString,
    field::AbstractString,
    value::AbstractString,
)
    parsed = tryparse(Dates.DateTime, value)
    return _checked_timestamp(parsed, where_, field, value)
end

_checked_timestamp(
    parsed::Dates.DateTime,
    ::AbstractString,
    ::AbstractString,
    ::AbstractString,
) =
    parsed

function _checked_timestamp(
    ::Nothing,
    where_::AbstractString,
    field::AbstractString,
    value::AbstractString,
)
    throw(ArgumentError("$where_: $field \"$value\" is not a valid date and time"))
end

_axis_context(model_name::AbstractString, axis::OutputAxis) =
    "model $model_name: axis \"$(axis_name(axis))\""

function _wire_duration(where_::AbstractString, field::AbstractString, period::Dates.Period)
    try
        return iso_duration(period)
    catch e
        e isa ArgumentError || rethrow()
        throw(ArgumentError("$where_: $field: $(e.msg)"))
    end
end

_fill_value(value::Union{String, Bool, Int64, Float64}) = value
_fill_value(value::Real) = Float64(value)

function _check_axis_group(model_name, axis::OutputAxis, group::AbstractString)
    expected = axis_group(model_name, axis)
    if group != expected
        throw(
            ArgumentError(
                "model $model_name: axis \"$(axis_name(axis))\" has group \"$group\", expected \"$expected\"",
            ),
        )
    end
    return
end

"""
Convert an outputs type into its generated struct of `InfrastructureOutputSchemas`. The
derived fields `kind`, `group`, and `path` come from the model name and the IS type.
"""
function to_openapi(axis::TimeAxis, model_name::AbstractString)
    return InfrastructureOutputSchemas.TimeAxis(;
        kind = axis_name(axis),
        initial_timestamp = string(axis.initial_timestamp),
        resolution = _wire_duration(
            _axis_context(model_name, axis),
            "resolution",
            axis.resolution,
        ),
        length = axis.length,
        group = axis_group(model_name, axis),
    )
end

function to_openapi(axis::ExecutionAxis, model_name::AbstractString)
    return InfrastructureOutputSchemas.ExecutionAxis(;
        kind = axis_name(axis),
        initial_timestamp = string(axis.initial_timestamp),
        interval = _wire_duration(
            _axis_context(model_name, axis),
            "interval",
            axis.interval,
        ),
        count = axis.count,
        group = axis_group(model_name, axis),
    )
end

function to_openapi(axis::HorizonAxis, model_name::AbstractString)
    return InfrastructureOutputSchemas.HorizonAxis(;
        kind = axis_name(axis),
        resolution = _wire_duration(
            _axis_context(model_name, axis),
            "resolution",
            axis.resolution,
        ),
        horizon_count = axis.horizon_count,
    )
end

function to_openapi(axis::ComponentAxis, model_name::AbstractString)
    return InfrastructureOutputSchemas.ComponentAxis(;
        kind = "component",
        columns = [
            InfrastructureOutputSchemas.ComponentAxisColumnsItem(;
                component_type = column.component_type,
                has_ids = column.has_ids,
            ) for column in axis.columns
        ],
        length = axis.length,
        group = axis_group(model_name, axis),
        subset = _absent_if_empty(axis.subset),
    )
end

function to_openapi(axis::LabelAxis, ::AbstractString)
    return InfrastructureOutputSchemas.LabelAxis(;
        kind = "label",
        name = axis.name,
        labels = axis.labels,
    )
end

function to_openapi(dataset::OutputDataset, model_name::AbstractString)
    return InfrastructureOutputSchemas.Dataset(;
        container = InfrastructureOutputSchemas.Container(dataset.container),
        entry_type = dataset.entry_type,
        component_type = _absent_if_empty(dataset.component_type),
        meta = dataset.meta,
        axes = dataset.axes,
        dtype = InfrastructureOutputSchemas.Dtype(dataset.dtype),
        fill_value = dataset.fill_value,
        quantity_kind = dataset.quantity_kind,
        unit_system = InfrastructureOutputSchemas.UnitSystem(
            unit_system_name(dataset.unit_system),
        ),
        units = dataset.units,
        layout = InfrastructureOutputSchemas.DatasetLayout(;
            chunks = dataset.chunks,
            filters = dataset.filters,
        ),
        path = dataset_path(model_name, dataset),
    )
end

function to_openapi(column::OutputColumn)
    quantity_kind, unit_system, units = _column_units(column.unit_info)
    return InfrastructureOutputSchemas.Column(;
        name = column.name,
        dtype = InfrastructureOutputSchemas.ColumnDtype(column.dtype),
        quantity_kind = quantity_kind,
        unit_system = unit_system,
        units = units,
    )
end

function to_openapi(table::OutputTable, model_name::AbstractString)
    return InfrastructureOutputSchemas.Table(;
        name = table.name,
        group = table_group(model_name, table),
        length = table.length,
        columns = [to_openapi(column) for column in table.columns],
    )
end

function to_openapi(model::OutputsModel)
    return InfrastructureOutputSchemas.Model(;
        name = model.name,
        model_type = model.model_type,
        system_uuid = model.system_uuid,
        base_power = model.base_power,
        supports_realized_values_post_calculation = model.supports_realized_values_post_calculation,
        settings = InfrastructureOutputSchemas.ModelSettings(;
            additional_properties = model.settings,
        ),
        axes = [
            InfrastructureOutputSchemas.Axis(to_openapi(axis, model.name)) for
            axis in model.axes
        ],
        datasets = [to_openapi(dataset, model.name) for dataset in model.datasets],
        tables = _absent_if_empty([
            to_openapi(table, model.name) for table in model.tables
        ]),
    )
end

function to_openapi(producer::ProducerInfo)
    return InfrastructureOutputSchemas.ProducerInfo(;
        package = producer.package,
        version = producer.version,
        julia = producer.julia,
    )
end

function to_openapi(params::Simulation.SimulationParams)
    return InfrastructureOutputSchemas.SimulationParams(;
        initial_time = string(params.initial_time),
        step_resolution = _wire_duration(
            "simulation",
            "step_resolution",
            params.step_resolution,
        ),
        num_steps = params.num_steps,
        execution_order = params.execution_order,
    )
end

function to_openapi(doc::OutputsDocument)
    return InfrastructureOutputSchemas.OutputsDocument(;
        schema_version = doc.schema_version,
        kind = doc.kind,
        producer = to_openapi(doc.producer),
        created_at = doc.created_at,
        status = InfrastructureOutputSchemas.RunStatus(string(doc.status)),
        systems = InfrastructureOutputSchemas.OutputsDocumentSystems(;
            additional_properties = doc.systems,
        ),
        simulation = _simulation_to_openapi(doc.simulation),
        models = [to_openapi(model) for model in doc.models],
    )
end

"""
Convert a generated struct of `InfrastructureOutputSchemas` into its outputs type. Throw
`ArgumentError` when a derived field (`group` or `path`) differs from the value that the
model name and the content give, or when a timestamp is not a valid date and time.
"""
function from_openapi(axis::InfrastructureOutputSchemas.Axis, model_name::AbstractString)
    return from_openapi(axis.value, model_name)
end

function from_openapi(
    axis::InfrastructureOutputSchemas.TimeAxis,
    model_name::AbstractString,
)
    result = TimeAxis(
        _parse_timestamp(
            "model $model_name: axis \"$(axis_name(TimeAxis))\"",
            "initial_timestamp",
            axis.initial_timestamp,
        ),
        parse_iso_duration(axis.resolution),
        axis.length,
    )
    _check_axis_group(model_name, result, axis.group)
    return result
end

function from_openapi(
    axis::InfrastructureOutputSchemas.ExecutionAxis,
    model_name::AbstractString,
)
    result = ExecutionAxis(
        _parse_timestamp(
            "model $model_name: axis \"$(axis_name(ExecutionAxis))\"",
            "initial_timestamp",
            axis.initial_timestamp,
        ),
        parse_iso_duration(axis.interval),
        axis.count,
    )
    _check_axis_group(model_name, result, axis.group)
    return result
end

function from_openapi(
    axis::InfrastructureOutputSchemas.HorizonAxis,
    ::AbstractString,
)
    return HorizonAxis(parse_iso_duration(axis.resolution), axis.horizon_count)
end

function from_openapi(
    axis::InfrastructureOutputSchemas.ComponentAxis,
    model_name::AbstractString,
)
    result = ComponentAxis(
        [
            ComponentAxisColumn(column.component_type, column.has_ids) for
            column in axis.columns
        ],
        axis.length,
        _wire_optional(axis.subset),
    )
    _check_axis_group(model_name, result, axis.group)
    return result
end

function from_openapi(axis::InfrastructureOutputSchemas.LabelAxis, ::AbstractString)
    return LabelAxis(axis.name, axis.labels)
end

function from_openapi(
    dataset::InfrastructureOutputSchemas.Dataset,
    model_name::AbstractString,
)
    result = OutputDataset(
        string(dataset.container),
        dataset.entry_type,
        _wire_optional(dataset.component_type),
        dataset.meta,
        dataset.axes,
        string(dataset.dtype),
        _fill_value(dataset.fill_value),
        dataset.quantity_kind,
        _WIRE_UNIT_SYSTEMS[string(dataset.unit_system)],
        dataset.units,
        dataset.layout.chunks,
        dataset.layout.filters,
    )
    expected = dataset_path(model_name, result)
    if dataset.path != expected
        throw(
            ArgumentError(
                "model $model_name: dataset $(dataset_key(result)) has path \"$(dataset.path)\", expected \"$expected\"",
            ),
        )
    end
    return result
end

_column_from_openapi(
    name,
    dtype,
    ::Union{OpenAPI.Runtime.Absent, Nothing},
    ::Union{OpenAPI.Runtime.Absent, Nothing},
    ::Union{OpenAPI.Runtime.Absent, Nothing},
) = OutputColumn(name, dtype)

_column_from_openapi(
    name,
    dtype,
    quantity_kind::AbstractString,
    unit_system::InfrastructureOutputSchemas.UnitSystem,
    units::AbstractString,
) = OutputColumn(name, dtype, quantity_kind, _WIRE_UNIT_SYSTEMS[string(unit_system)], units)

function from_openapi(column::InfrastructureOutputSchemas.Column)
    return _column_from_openapi(
        column.name,
        string(column.dtype),
        column.quantity_kind,
        column.unit_system,
        column.units,
    )
end

function from_openapi(table::InfrastructureOutputSchemas.Table, model_name::AbstractString)
    result = OutputTable(
        table.name,
        table.length,
        [from_openapi(column) for column in table.columns],
    )
    expected = table_group(model_name, result)
    if table.group != expected
        throw(
            ArgumentError(
                "model $model_name: table $(table.name) has group \"$(table.group)\", expected \"$expected\"",
            ),
        )
    end
    return result
end

_tables_from_openapi(::AbstractString, ::Union{OpenAPI.Runtime.Absent, Nothing}) =
    OutputTable[]

function _tables_from_openapi(
    model_name::AbstractString,
    tables::Vector{InfrastructureOutputSchemas.Table},
)
    return [from_openapi(table, model_name) for table in tables]
end

function from_openapi(model::InfrastructureOutputSchemas.Model)
    return OutputsModel(;
        name = model.name,
        model_type = model.model_type,
        system_uuid = model.system_uuid,
        base_power = model.base_power,
        supports_realized_values_post_calculation = model.supports_realized_values_post_calculation,
        settings = Dict{String, Any}(model.settings.additional_properties),
        axes = OutputAxis[from_openapi(axis, model.name) for axis in model.axes],
        datasets = [from_openapi(dataset, model.name) for dataset in model.datasets],
        tables = _tables_from_openapi(model.name, model.tables),
    )
end

function from_openapi(producer::InfrastructureOutputSchemas.ProducerInfo)
    return ProducerInfo(producer.package, producer.version, producer.julia)
end

function from_openapi(params::InfrastructureOutputSchemas.SimulationParams)
    return Simulation.SimulationParams(
        _parse_timestamp("simulation", "initial_time", params.initial_time),
        parse_iso_duration(params.step_resolution),
        params.num_steps,
        params.execution_order,
    )
end

function from_openapi(doc::InfrastructureOutputSchemas.OutputsDocument)
    return OutputsDocument(
        doc.schema_version,
        doc.kind,
        from_openapi(doc.producer),
        doc.created_at,
        _WIRE_RUN_STATUS[string(doc.status)],
        Dict{String, String}(doc.systems.additional_properties),
        _simulation_from_openapi(doc.simulation),
        [from_openapi(model) for model in doc.models],
    )
end

_encode_document(doc::OutputsDocument) =
    InfrastructureOutputSchemas.encode(to_openapi(doc))

_decode_document(data) =
    from_openapi(
        InfrastructureOutputSchemas.decode(
            InfrastructureOutputSchemas.OutputsDocument,
            data,
        ),
    )
