const OUTPUT_CONTAINERS =
    ("variables", "aux_variables", "parameters", "expressions", "duals")
const _LABEL_KEY_PATTERN = r"^[a-z][a-z0-9_]*$"
const _SCHEMA_VERSION = "0.1.0"
const _OUTPUT_KINDS = ("single", "simulation", "power_flow", "security_analysis")
const _MODEL_TYPES = ("decision", "emulation", "power_flow", "security_analysis")
const _NAME_PATTERN = r"^[A-Z][A-Za-z0-9]*$"
const _OUTPUT_UNIT_SYSTEMS = ("COMPONENT_BASE", "NATURAL_UNITS")

function _check_member(where_::String, field::String, value::AbstractString, allowed)
    if !(value in allowed)
        throw(
            ArgumentError(
                "$where_: $field \"$value\" is not one of $(join(allowed, ", "))",
            ),
        )
    end
    return
end

"""
Return the key of the axis in the `axes` map of its model.
"""
function axis_key end
axis_key(::TimeAxis) = "time"
axis_key(::ExecutionAxis) = "execution"
axis_key(::HorizonAxis) = "horizon"

function axis_key(a::ComponentAxis)
    key = join((c.component_type for c in a.columns), "__")
    if isempty(a.subset)
        return key
    end
    return string(key, "__", a.subset)
end

# The `kind` string of each axis type.
function _axis_kind end
_axis_kind(::TimeAxis) = "time"
_axis_kind(::ExecutionAxis) = "execution"
_axis_kind(::HorizonAxis) = "horizon"
_axis_kind(::ComponentAxis) = "component"
_axis_kind(::LabelAxis) = "label"

# Dispatch: only component axes carry columns.
_component_columns(ax::ComponentAxis) = ax.columns
_component_columns(::AbstractAxis) = AxisColumn[]

"""
Return the number of entries along the axis.
"""
function axis_length end
axis_length(a::TimeAxis) = a.length
axis_length(a::ExecutionAxis) = a.count
axis_length(a::HorizonAxis) = a.horizon_count
axis_length(a::ComponentAxis) = a.length
axis_length(a::LabelAxis) = length(a.labels)

function _check_axis_kind(model::String, name::String, a::AbstractAxis)
    if a.kind != _axis_kind(a)
        throw(
            ArgumentError(
                "model $model: axis \"$name\" has kind \"$(a.kind)\", expected \"$(_axis_kind(a))\"",
            ),
        )
    end
    return
end

function _check_axis_key(model::String, name::String, a::AbstractAxis)
    expected = axis_key(a)
    if name != expected
        throw(
            ArgumentError(
                "model $model: axis key \"$name\" differs from derived key \"$expected\""),
        )
    end
    return
end

function _check_axis_key(model::String, name::String, ::LabelAxis)
    if !occursin(_LABEL_KEY_PATTERN, name)
        throw(
            ArgumentError(
                "model $model: label axis key \"$name\" is not lower snake case"),
        )
    end
    return
end

# COMPONENT_BASE needs a base_reference and "pu"; NATURAL_UNITS has no base_reference.
function _check_unit_fields(
    where_::String,
    unit_system::String,
    base_reference::String,
    units::String,
)
    if unit_system == "COMPONENT_BASE"
        if isempty(base_reference) || units != "pu"
            throw(
                ArgumentError(
                    "$where_: COMPONENT_BASE needs a base_reference and units \"pu\"",
                ),
            )
        end
    elseif !isempty(base_reference)
        throw(ArgumentError("$where_: NATURAL_UNITS must not have a base_reference"))
    end
    return
end

_parse_fill(::Type{T}, v::String) where {T <: AbstractFloat} = parse(T, v)
_parse_fill(::Type{T}, v::Real) where {T <: Real} = T(v)

function _parse_fill(::Type, v::String)
    throw(ArgumentError("string fill value for an integer dtype"))
end

function _check_fill_value(where_::String, d::OutputDataset)
    try
        _parse_fill(_DTYPES[d.dtype][1], d.fill_value)
    catch
        throw(
            ArgumentError(
                "$where_: fill_value $(d.fill_value) is not valid for dtype $(d.dtype)",
            ),
        )
    end
    return
end

# Filter grammar: `shuffle` or `deflate:L` with L in 1 to 9.
function _check_filters(where_::String, names::Vector{String})
    for f in names
        if f == "shuffle"
            continue
        end
        level = nothing
        if startswith(f, "deflate:")
            level = tryparse(Int, f[(length("deflate:") + 1):end])
        end
        if isnothing(level)
            throw(ArgumentError("$where_: unknown filter \"$f\""))
        elseif !(1 <= level <= 9)
            throw(
                ArgumentError(
                    "$where_: invalid filter \"$f\", deflate level must be 1 to 9"),
            )
        end
    end
    return
end

function _check_component_type(where_::String, m::ModelEntry, d::OutputDataset)
    columns = [_component_columns(m.axes[name]) for name in d.axes]
    filter!(!isempty, columns)
    if isempty(columns)
        if !isempty(d.component_type)
            throw(ArgumentError("$where_: component_type without a component axis"))
        end
        return
    end
    expected = first(first(columns)).component_type
    if d.component_type != expected
        throw(
            ArgumentError(
                "$where_: component_type \"$(d.component_type)\" differs from the component axis type \"$expected\"",
            ),
        )
    end
    return
end

function _check_names(where_::String, d::OutputDataset)
    if occursin("__", d.meta)
        throw(ArgumentError("$where_: meta \"$(d.meta)\" contains \"__\""))
    end
    if !occursin(_NAME_PATTERN, d.entry_type)
        throw(ArgumentError("$where_: entry_type \"$(d.entry_type)\" is not a type name"))
    end
    if !isempty(d.component_type) && !occursin(_NAME_PATTERN, d.component_type)
        throw(
            ArgumentError(
                "$where_: component_type \"$(d.component_type)\" is not a type name"),
        )
    end
    return
end

function _check_dataset(model::String, m::ModelEntry, d::OutputDataset)
    key = dataset_key(d)
    where_ = "model $model: dataset $key"
    for name in d.axes
        if !haskey(m.axes, name)
            throw(
                ArgumentError(
                    "$where_ uses axis \"$name\" absent from the model axes",
                ),
            )
        end
    end
    if length(d.layout.chunks) != length(d.axes)
        throw(
            ArgumentError(
                "$where_ has $(length(d.layout.chunks)) chunks for $(length(d.axes)) axes",
            ),
        )
    end
    for name in ("execution", "horizon", "time")
        if count(==(name), d.axes) > 1
            throw(ArgumentError("$where_ repeats axis \"$name\""))
        end
    end
    if "horizon" in d.axes && !("execution" in d.axes)
        throw(ArgumentError("$where_ has a horizon axis without an execution axis"))
    end
    _check_member(where_, "dtype", d.dtype, keys(_DTYPES))
    _check_member(where_, "unit_system", d.unit_system, _OUTPUT_UNIT_SYSTEMS)
    _check_fill_value(where_, d)
    _check_filters(where_, d.layout.filters)
    _check_names(where_, d)
    _check_component_type(where_, m, d)
    _check_member(where_, "container", d.container, OUTPUT_CONTAINERS)
    _check_unit_fields(where_, d.unit_system, d.base_reference, d.units)
    expected = "/$model/datasets/$(dataset_name(d))"
    if d.path != expected
        throw(ArgumentError("$where_ has path \"$(d.path)\", expected \"$expected\""))
    end
    return
end

function _check_table_column(model::String, t::OutputTable, c::OutputColumn)
    where_ = "model $model: table $(t.name) column $(c.name)"
    _check_member(where_, "dtype", c.dtype, _COLUMN_DTYPES)
    has = (!isempty(c.quantity_kind), !isempty(c.unit_system), !isempty(c.units))
    if !(all(has) || !any(has))
        throw(
            ArgumentError(
                "$where_: quantity_kind, unit_system, and units must be all present or all absent",
            ),
        )
    end
    if !any(has)
        if !isempty(c.base_reference)
            throw(ArgumentError("$where_: base_reference without unit_system"))
        end
        return
    end
    _check_member(where_, "unit_system", c.unit_system, _OUTPUT_UNIT_SYSTEMS)
    _check_unit_fields(where_, c.unit_system, c.base_reference, c.units)
    return
end

function _check_table(model::String, t::OutputTable)
    expected = "/$model/tables/$(t.name)"
    if t.group != expected
        throw(
            ArgumentError(
                "model $model: table $(t.name) has group \"$(t.group)\", expected \"$expected\"",
            ),
        )
    end
    for c in t.columns
        _check_table_column(model, t, c)
    end
    return
end

"""
Check the structure of an outputs metadata document. Throw an `ArgumentError` that names
the model and the offending key or dataset on the first violation. Return `nothing`.
"""
function validate_metadata(m::OutputsMetadata)
    if m.schema_version != _SCHEMA_VERSION
        throw(
            ArgumentError(
                "schema_version \"$(m.schema_version)\" is not \"$_SCHEMA_VERSION\""),
        )
    end
    _check_member("metadata", "kind", m.kind, _OUTPUT_KINDS)
    status = Simulation.RunStatus.Value(m.status)
    if !(
        status in (
            Simulation.RunStatus.RUNNING,
            Simulation.RunStatus.SUCCESSFULLY_FINALIZED,
            Simulation.RunStatus.FAILED,
        )
    )
        throw(ArgumentError("metadata: status \"$(m.status)\" is not a run outcome"))
    end
    if (m.kind == "simulation") != has_simulation(m)
        throw(
            ArgumentError(
                "metadata of kind $(m.kind): simulation parameters must be present exactly when kind is simulation",
            ),
        )
    end
    if has_simulation(m)
        for name in get_simulation(m).execution_order
            if !haskey(m.models, name)
                throw(
                    ArgumentError(
                        "execution_order entry \"$name\" is not in the models"),
                )
            end
        end
    end
    for (model, entry) in m.models
        _check_member("model $model", "model_type", entry.model_type, _MODEL_TYPES)
        if !haskey(m.systems, entry.system_uuid)
            throw(
                ArgumentError(
                    "model $model: system_uuid \"$(entry.system_uuid)\" is not in systems",
                ),
            )
        end
        for (name, axis) in entry.axes
            _check_axis_kind(model, name, axis)
            _check_axis_key(model, name, axis)
        end
        seen = Set{Tuple{String, String, String}}()
        for d in entry.datasets
            key = dataset_key(d)
            if key in seen
                throw(ArgumentError("model $model: duplicate dataset $key"))
            end
            push!(seen, key)
            _check_dataset(model, entry, d)
        end
        for t in entry.tables
            _check_table(model, t)
        end
    end
    return
end
