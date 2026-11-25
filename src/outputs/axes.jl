"""
Schema version string of `outputs.json`. Public: producers set it in the
`InfrastructureOutputSchemas.OutputsDocument`.
"""
const OUTPUTS_SCHEMA_VERSION = "0.1.0"

const _ARTIFACT_FILE_NAMES = ("outputs.json", "outputs.h5")

"""
Return the name that a dataset uses to refer to the axis.
"""
function axis_key end
axis_key(a::InfrastructureOutputSchemas.Axis) = axis_key(a.value)
axis_key(::InfrastructureOutputSchemas.TimeAxis) = "time"
axis_key(::InfrastructureOutputSchemas.ExecutionAxis) = "execution"
axis_key(::InfrastructureOutputSchemas.HorizonAxis) = "horizon"
axis_key(a::InfrastructureOutputSchemas.LabelAxis) = a.name

function axis_key(a::InfrastructureOutputSchemas.ComponentAxis)
    key = join((c.component_type for c in a.columns), "__")
    subset = _optional_string(a.subset)
    if isempty(subset)
        return key
    end
    return string(key, "__", subset)
end

# Dispatch: only component axes carry columns.
_component_columns(ax::InfrastructureOutputSchemas.ComponentAxis) = ax.columns
_component_columns(::Any) = InfrastructureOutputSchemas.ComponentAxisColumnsItem[]

"""
Return the number of entries along the axis.
"""
function axis_length end
axis_length(a::InfrastructureOutputSchemas.Axis) = axis_length(a.value)
axis_length(a::InfrastructureOutputSchemas.TimeAxis) = a.length
axis_length(a::InfrastructureOutputSchemas.ExecutionAxis) = a.count
axis_length(a::InfrastructureOutputSchemas.HorizonAxis) = a.horizon_count
axis_length(a::InfrastructureOutputSchemas.ComponentAxis) = a.length
axis_length(a::InfrastructureOutputSchemas.LabelAxis) = length(a.labels)

_parse_fill(::Type{T}, v::String) where {T <: AbstractFloat} = parse(T, v)
_parse_fill(::Type{T}, v::Real) where {T <: Real} = T(v)

# The schema checks the form of a timestamp, not that the date exists.
function _check_timestamp(where_::String, field::String, value::AbstractString)
    if isnothing(tryparse(Dates.DateTime, value))
        throw(ArgumentError("$where_: $field \"$value\" is not a valid date and time"))
    end
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

function _check_axis_fields(
    model::String,
    name::String,
    a::InfrastructureOutputSchemas.TimeAxis,
)
    where_ = "model $model: axis \"$name\""
    _check_timestamp(where_, "initial_timestamp", a.initial_timestamp)
    _check_axis_group(model, name, a.group)
    return
end

function _check_axis_fields(
    model::String,
    name::String,
    a::InfrastructureOutputSchemas.ExecutionAxis,
)
    where_ = "model $model: axis \"$name\""
    _check_timestamp(where_, "initial_timestamp", a.initial_timestamp)
    _check_axis_group(model, name, a.group)
    return
end

_check_axis_fields(::String, ::String, ::InfrastructureOutputSchemas.HorizonAxis) = nothing

function _check_axis_fields(
    model::String,
    name::String,
    a::InfrastructureOutputSchemas.ComponentAxis,
)
    _check_axis_group(model, name, a.group)
    return
end

_check_axis_fields(::String, ::String, ::InfrastructureOutputSchemas.LabelAxis) = nothing

function _check_dataset(
    model::String,
    m::InfrastructureOutputSchemas.Model,
    d::InfrastructureOutputSchemas.Dataset,
)
    key = dataset_key(d)
    where_ = "model $model: dataset $key"
    for name in d.axes
        if !_has_axis(m, name)
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
    # HDF5 accepts any positive chunk on a zero-length axis.
    for (name, chunk) in zip(d.axes, d.layout.chunks)
        n = axis_length(_find_axis(m, name))
        if !iszero(n) && chunk > n
            throw(
                ArgumentError(
                    "$where_ has chunk $chunk on axis \"$name\", which is more than the axis length $n",
                ),
            )
        end
    end
    columns = [_component_columns(_find_axis(m, name)) for name in d.axes]
    filter!(!isempty, columns)
    component_type = _optional_string(d.component_type)
    if isempty(columns)
        if !isempty(component_type)
            throw(ArgumentError("$where_: component_type without a component axis"))
        end
    else
        expected_type = first(first(columns)).component_type
        if component_type != expected_type
            throw(
                ArgumentError(
                    "$where_: component_type \"$component_type\" differs from the component axis type \"$expected_type\"",
                ),
            )
        end
    end
    expected = "/$model/datasets/$(dataset_name(d))"
    if d.path != expected
        throw(ArgumentError("$where_ has path \"$(d.path)\", expected \"$expected\""))
    end
    return
end

function _check_table(model::String, t::InfrastructureOutputSchemas.Table)
    expected = "/$model/tables/$(t.name)"
    if t.group != expected
        throw(
            ArgumentError(
                "model $model: table $(t.name) has group \"$(t.group)\", expected \"$expected\"",
            ),
        )
    end
    seen = Set{String}()
    for c in t.columns
        if c.name in seen
            throw(
                ArgumentError(
                    "model $model: table $(t.name) has a duplicate column name \"$(c.name)\"",
                ),
            )
        end
        push!(seen, c.name)
    end
    return
end

# The schema requires the execution and horizon axes and forbids a time axis under the flag.
function _check_realized_values(model::String, entry::InfrastructureOutputSchemas.Model)
    if !entry.supports_realized_values_post_calculation
        return
    end
    e = _find_axis(entry, "execution")
    h = _find_axis(entry, "horizon")
    interval = Dates.value(get_interval(e))
    resolution = Dates.value(get_resolution(h))
    if interval <= 0 || resolution <= 0 || !iszero(rem(interval, resolution))
        throw(
            ArgumentError(
                "model $model: supports_realized_values_post_calculation needs an execution interval that is a positive whole multiple of the horizon resolution, got interval \"$(e.interval)\" and resolution \"$(h.resolution)\"",
            ),
        )
    end
    if div(interval, resolution) > h.horizon_count
        throw(
            ArgumentError(
                "model $model: supports_realized_values_post_calculation needs an execution interval \"$(e.interval)\" of at most the horizon ($(h.horizon_count) x \"$(h.resolution)\")",
            ),
        )
    end
    return
end

function _check_model_entry(
    m::InfrastructureOutputSchemas.OutputsDocument,
    entry::InfrastructureOutputSchemas.Model,
)
    model = entry.name
    if !haskey(_systems(m), entry.system_uuid)
        throw(
            ArgumentError(
                "model $model: system_uuid \"$(entry.system_uuid)\" is not in systems",
            ),
        )
    end
    # The schema validation accepts NaN.
    if !(entry.base_power > 0)
        throw(
            ArgumentError("model $model: base_power is $(entry.base_power), expected > 0"),
        )
    end
    seen_axes = Set{String}()
    for axis in _axes(entry)
        name = axis_key(axis)
        if name in seen_axes
            throw(ArgumentError("model $model: duplicate axis name \"$name\""))
        end
        push!(seen_axes, name)
        _check_axis_fields(model, name, axis)
    end
    _check_realized_values(model, entry)
    seen = Set{Tuple{String, String, String}}()
    paths = Dict{String, Tuple{String, String, String}}()
    for d in entry.datasets
        key = dataset_key(d)
        if key in seen
            throw(ArgumentError("model $model: duplicate dataset $key"))
        end
        push!(seen, key)
        _check_dataset(model, entry, d)
        if haskey(paths, d.path)
            throw(
                ArgumentError(
                    "model $model: datasets $(paths[d.path]) and $key resolve to the same path \"$(d.path)\"",
                ),
            )
        end
        paths[d.path] = key
    end
    seen_tables = Set{String}()
    for t in _model_tables(entry)
        if t.name in seen_tables
            throw(ArgumentError("model $model: duplicate table name \"$(t.name)\""))
        end
        push!(seen_tables, t.name)
        _check_table(model, t)
    end
    return
end

"""
Check an outputs document. First validate it against the outputs JSON schema, which throws
`InfrastructureOutputSchemas.SchemaValidationError`. Then apply the cross-reference rules that the
schema cannot express, which throw an `ArgumentError` that names the model and the
offending key or dataset. Return `nothing`.
"""
function validate_metadata(m::InfrastructureOutputSchemas.OutputsDocument)
    InfrastructureOutputSchemas.encode(m)
    owners = Dict{String, String}()
    for (uuid, name) in _systems(m)
        # On Windows, `joinpath(dir, "C:foo")` drops `dir`.
        if occursin(r"\A.:"s, name)
            throw(
                ArgumentError(
                    "system $uuid: bundle directory \"$name\" starts with a Windows drive prefix",
                ),
            )
        end
        # A file system that ignores case treats `OUTPUTS.JSON` as `outputs.json`.
        if lowercase(name) in _ARTIFACT_FILE_NAMES
            throw(
                ArgumentError(
                    "system $uuid: bundle directory \"$name\" is the name of an artifact file",
                ),
            )
        end
        if haskey(owners, name)
            throw(
                ArgumentError(
                    "systems $(owners[name]) and $uuid use the same bundle directory \"$name\"",
                ),
            )
        end
        owners[name] = uuid
    end
    if has_simulation(m)
        sim = get_simulation(m)
        _check_timestamp("simulation", "initial_time", sim.initial_time)
        for name in sim.execution_order
            if !any(e -> e.name == name, m.models)
                throw(ArgumentError("execution_order entry \"$name\" is not in the models"))
            end
        end
    end
    seen_models = Set{String}()
    for entry in m.models
        if entry.name in seen_models
            throw(ArgumentError("metadata: duplicate model name \"$(entry.name)\""))
        end
        push!(seen_models, entry.name)
        _check_model_entry(m, entry)
    end
    return
end
