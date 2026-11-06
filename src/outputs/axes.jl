const OUTPUT_CONTAINERS =
    ("variables", "aux_variables", "parameters", "expressions", "duals")
const _LABEL_KEY_PATTERN = r"^[a-z][a-z0-9_]*$"
"""
Schema version string of `outputs.json`. Public: producers set it in `OutputsMetadata`.
"""
const OUTPUTS_SCHEMA_VERSION = "0.1.0"
const _OUTPUT_KINDS = ("single", "simulation", "power_flow", "security_analysis")
const _MODEL_TYPES = ("decision", "emulation", "power_flow", "security_analysis")
const _NAME_PATTERN = r"^[A-Z][A-Za-z0-9]*$"
const _OUTPUT_UNIT_SYSTEMS = ("COMPONENT_BASE", "NATURAL_UNITS")
const _BASE_REFERENCES = ("system", "component")
const _UUID_PATTERN = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
const _RFC3339_PATTERN =
    r"^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])[Tt]([01]\d|2[0-3]):[0-5]\d:([0-5]\d|60)(\.\d+)?([Zz]|[+-]([01]\d|2[0-3]):[0-5]\d)$"
const _FILTER_PATTERN = r"^(shuffle|deflate:[1-9])$"

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

# Fill rules of the schema by dtype: a number or "NaN" for floats, an integer for integer
# dtypes, a boolean for bool. A Bool never counts as a number.
_fill_valid(dtype::String, v) = _fill_valid(Val(Symbol(dtype)), v)
_fill_valid(::Val, ::Any) = false
_fill_valid(::Union{Val{:f64}, Val{:f32}}, v::String) = v == "NaN"
_fill_valid(::Union{Val{:f64}, Val{:f32}}, ::Real) = true
_fill_valid(::Union{Val{:f64}, Val{:f32}}, ::Bool) = false
_fill_valid(::Val{:i64}, v::Real) = _fits_integer(Int64, v)
_fill_valid(::Val{:i32}, v::Real) = _fits_integer(Int32, v)
_fill_valid(::Val{:bool}, ::Bool) = true

_fits_integer(::Type{<:Integer}, ::Bool) = false

function _fits_integer(::Type{T}, v::Real) where {T <: Integer}
    return isinteger(v) && typemin(T) <= v <= typemax(T)
end

function _check_fill_value(where_::String, d::OutputDataset)
    if !_fill_valid(d.dtype, d.fill_value)
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
        if !occursin(_FILTER_PATTERN, f)
            throw(
                ArgumentError(
                    "$where_: invalid filter \"$f\", expected shuffle or deflate:1 to deflate:9",
                ),
            )
        end
    end
    return
end

# The deflate level of a filter name that passed `_check_filters`.
_deflate_level(f::AbstractString) = parse(Int, f[(length("deflate:") + 1):end])

function _check_pattern(
    where_::String,
    field::String,
    value::AbstractString,
    pattern::Regex,
    expected::String,
)
    if !occursin(pattern, value)
        throw(ArgumentError("$where_: $field \"$value\" is not $expected"))
    end
    return
end

# Model, axis, and table names form HDF5 paths: one non-empty segment without "/".
function _check_path_name(where_::String, field::String, name::AbstractString)
    if isempty(name) || occursin('/', name)
        throw(ArgumentError("$where_: $field \"$name\" is empty or contains \"/\""))
    end
    return
end

function _check_at_least(where_::String, field::String, value::Real, bound::Real)
    if !(value >= bound)
        throw(ArgumentError("$where_: $field is $value, expected at least $bound"))
    end
    return
end

function _check_duration(where_::String, field::String, value::AbstractString)
    if !is_iso_duration(value)
        throw(ArgumentError("$where_: $field \"$value\" is not an ISO-8601 duration"))
    end
    return
end

function _check_quantity_kind(where_::String, value::AbstractString)
    _check_member(where_, "quantity_kind", value, QUANTITY_KINDS)
    return
end

function _check_axis_group(model::String, name::String, group::String)
    expected = "/$model/axes/$name"
    if group != expected
        throw(
            ArgumentError(
                "model $model: axis \"$name\" has group \"$group\", expected \"$expected\"",
            ),
        )
    end
    return
end

# Field rules of each axis type, on top of kind and key.
function _check_axis_fields(model::String, name::String, a::TimeAxis)
    where_ = "model $model: axis \"$name\""
    _check_duration(where_, "resolution", a.resolution)
    _check_at_least(where_, "length", a.length, 1)
    _check_axis_group(model, name, a.group)
    return
end

function _check_axis_fields(model::String, name::String, a::ExecutionAxis)
    where_ = "model $model: axis \"$name\""
    _check_duration(where_, "interval", a.interval)
    _check_at_least(where_, "count", a.count, 1)
    _check_axis_group(model, name, a.group)
    return
end

function _check_axis_fields(model::String, name::String, a::HorizonAxis)
    where_ = "model $model: axis \"$name\""
    _check_duration(where_, "resolution", a.resolution)
    _check_at_least(where_, "horizon_count", a.horizon_count, 1)
    return
end

function _check_axis_fields(model::String, name::String, a::ComponentAxis)
    where_ = "model $model: axis \"$name\""
    if isempty(a.columns)
        throw(ArgumentError("$where_ has no columns"))
    end
    for c in a.columns
        _check_pattern(
            where_, "column component_type", c.component_type, _NAME_PATTERN, "a type name",
        )
    end
    _check_at_least(where_, "length", a.length, 0)
    _check_axis_group(model, name, a.group)
    return
end

function _check_axis_fields(model::String, name::String, a::LabelAxis)
    where_ = "model $model: axis \"$name\""
    if isempty(a.labels)
        throw(ArgumentError("$where_ has no labels"))
    end
    if !allunique(a.labels)
        throw(ArgumentError("$where_ has duplicate labels"))
    end
    return
end

function _check_axis(model::String, name::String, a::AbstractAxis)
    _check_path_name("model $model", "axis key", name)
    _check_axis_kind(model, name, a)
    _check_axis_fields(model, name, a)
    _check_axis_key(model, name, a)
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
    if occursin('/', d.meta)
        throw(ArgumentError("$where_: meta \"$(d.meta)\" contains \"/\""))
    end
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
    if isempty(d.axes)
        throw(ArgumentError("$where_ has no axes"))
    end
    for name in d.axes
        if !haskey(m.axes, name)
            throw(
                ArgumentError(
                    "$where_ uses axis \"$name\" absent from the model axes",
                ),
            )
        end
    end
    if !allunique(d.axes)
        throw(ArgumentError("$where_ repeats an axis in $(d.axes)"))
    end
    if length(d.layout.chunks) != length(d.axes)
        throw(
            ArgumentError(
                "$where_ has $(length(d.layout.chunks)) chunks for $(length(d.axes)) axes",
            ),
        )
    end
    for c in d.layout.chunks
        _check_at_least(where_, "chunk", c, 1)
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
    _check_quantity_kind(where_, d.quantity_kind)
    if !isempty(d.base_reference)
        _check_member(where_, "base_reference", d.base_reference, _BASE_REFERENCES)
    end
    if isempty(d.units)
        throw(ArgumentError("$where_: units is empty"))
    end
    _check_unit_fields(where_, d.unit_system, d.base_reference, d.units)
    expected = "/$model/datasets/$(dataset_name(d))"
    if d.path != expected
        throw(ArgumentError("$where_ has path \"$(d.path)\", expected \"$expected\""))
    end
    return
end

function _check_table_column(model::String, t::OutputTable, c::OutputColumn)
    where_ = "model $model: table $(t.name) column $(c.name)"
    if isempty(c.name)
        throw(
            ArgumentError("model $model: table $(t.name) has a column with an empty name"),
        )
    end
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
    _check_quantity_kind(where_, c.quantity_kind)
    _check_member(where_, "unit_system", c.unit_system, _OUTPUT_UNIT_SYSTEMS)
    if !isempty(c.base_reference)
        _check_member(where_, "base_reference", c.base_reference, _BASE_REFERENCES)
    end
    _check_unit_fields(where_, c.unit_system, c.base_reference, c.units)
    return
end

function _check_table(model::String, t::OutputTable)
    where_ = "model $model: table \"$(t.name)\""
    _check_path_name("model $model", "table name", t.name)
    expected = "/$model/tables/$(t.name)"
    if t.group != expected
        throw(
            ArgumentError(
                "model $model: table $(t.name) has group \"$(t.group)\", expected \"$expected\"",
            ),
        )
    end
    _check_at_least(where_, "length", t.length, 0)
    if isempty(t.columns)
        throw(ArgumentError("$where_ has no columns"))
    end
    for c in t.columns
        _check_table_column(model, t, c)
    end
    return
end

# Settings values are scalars: string, number, or boolean.
_is_scalar_setting(::Union{AbstractString, Real}) = true
_is_scalar_setting(::Any) = false

function _check_settings(model::String, settings::Dict{String, Any})
    for (k, v) in settings
        if !_is_scalar_setting(v)
            throw(
                ArgumentError(
                    "model $model: setting \"$k\" is a $(typeof(v)), expected a string, number, or boolean",
                ),
            )
        end
    end
    return
end

function _check_model_entry(m::OutputsMetadata, model::String, entry::ModelEntry)
    _check_path_name("metadata", "model name", model)
    _check_member("model $model", "model_type", entry.model_type, _MODEL_TYPES)
    _check_pattern(
        "model $model", "system_uuid", entry.system_uuid, _UUID_PATTERN, "a lowercase UUID",
    )
    if !haskey(m.systems, entry.system_uuid)
        throw(
            ArgumentError(
                "model $model: system_uuid \"$(entry.system_uuid)\" is not in systems",
            ),
        )
    end
    if !(entry.base_power > 0)
        throw(
            ArgumentError("model $model: base_power is $(entry.base_power), expected > 0"),
        )
    end
    _check_settings(model, entry.settings)
    for (name, axis) in entry.axes
        _check_axis(model, name, axis)
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
    return
end

function _check_simulation(m::OutputsMetadata)
    if (m.kind == "simulation") != has_simulation(m)
        throw(
            ArgumentError(
                "metadata of kind $(m.kind): simulation parameters must be present exactly when kind is simulation",
            ),
        )
    end
    if !has_simulation(m)
        return
    end
    sim = get_simulation(m)
    _check_duration("simulation", "step_resolution", sim.step_resolution)
    _check_at_least("simulation", "num_steps", sim.num_steps, 1)
    if isempty(sim.execution_order)
        throw(ArgumentError("simulation: execution_order is empty"))
    end
    for name in sim.execution_order
        if !haskey(m.models, name)
            throw(ArgumentError("execution_order entry \"$name\" is not in the models"))
        end
    end
    return
end

const _RUN_OUTCOMES = ("RUNNING", "SUCCESSFULLY_FINALIZED", "FAILED")

function _check_bundle_name(uuid::AbstractString, name::AbstractString)
    if isempty(name) || name in (".", "..") || isabspath(name) ||
       occursin('/', name) || occursin('\\', name)
        throw(
            ArgumentError(
                "system $uuid has bundle directory \"$name\", expected a plain relative name",
            ),
        )
    end
    return
end

"""
Check the structure of an outputs metadata document against the rules of the outputs JSON
schema. Throw an `ArgumentError` that names the model and the offending key or dataset on
the first violation. Return `nothing`.
"""
function validate_metadata(m::OutputsMetadata)
    if m.schema_version != OUTPUTS_SCHEMA_VERSION
        throw(
            ArgumentError(
                "schema_version \"$(m.schema_version)\" is not \"$OUTPUTS_SCHEMA_VERSION\"",
            ),
        )
    end
    _check_member("metadata", "kind", m.kind, _OUTPUT_KINDS)
    _check_pattern(
        "metadata",
        "created_at",
        m.created_at,
        _RFC3339_PATTERN,
        "an RFC 3339 date-time",
    )
    if !(m.status in _RUN_OUTCOMES)
        throw(
            ArgumentError(
                "metadata: status \"$(m.status)\" is not one of $(join(_RUN_OUTCOMES, ", "))",
            ),
        )
    end
    if isempty(m.systems)
        throw(ArgumentError("metadata: systems is empty"))
    end
    for uuid in keys(m.systems)
        _check_pattern("metadata", "system key", uuid, _UUID_PATTERN, "a lowercase UUID")
    end
    if isempty(m.models)
        throw(ArgumentError("metadata: models is empty"))
    end
    for (uuid, name) in m.systems
        _check_bundle_name(uuid, name)
    end
    _check_simulation(m)
    for (model, entry) in m.models
        _check_model_entry(m, model, entry)
    end
    return
end
