"""
Schema version string of `outputs.json`. Public: producers set it in the
`InfrastructureOutputSchemas.OutputsDocument`.
"""
const OUTPUTS_SCHEMA_VERSION = "0.1.0"

const _ARTIFACT_FILE_NAMES = ("outputs.json", "outputs.h5")

"""
Return the axis name that a dataset uses to refer to the axis.
"""
function axis_name end
axis_name(axis::InfrastructureOutputSchemas.Axis) = axis_name(axis.value)
axis_name(::InfrastructureOutputSchemas.TimeAxis) = "time"
axis_name(::InfrastructureOutputSchemas.ExecutionAxis) = "execution"
axis_name(::InfrastructureOutputSchemas.HorizonAxis) = "horizon"
axis_name(axis::InfrastructureOutputSchemas.LabelAxis) = axis.name

function axis_name(axis::InfrastructureOutputSchemas.ComponentAxis)
    name = join((column.component_type for column in axis.columns), "__")
    subset = _optional_string(axis.subset)
    if isempty(subset)
        return name
    end
    return string(name, "__", subset)
end

# Dispatch: only component axes carry columns.
_component_columns(axis::InfrastructureOutputSchemas.ComponentAxis) = axis.columns
_component_columns(::Any) = InfrastructureOutputSchemas.ComponentAxisColumnsItem[]

"""
Return the number of entries along the axis.
"""
function axis_length end
axis_length(axis::InfrastructureOutputSchemas.Axis) = axis_length(axis.value)
axis_length(axis::InfrastructureOutputSchemas.TimeAxis) = axis.length
axis_length(axis::InfrastructureOutputSchemas.ExecutionAxis) = axis.count
axis_length(axis::InfrastructureOutputSchemas.HorizonAxis) = axis.horizon_count
axis_length(axis::InfrastructureOutputSchemas.ComponentAxis) = axis.length
axis_length(axis::InfrastructureOutputSchemas.LabelAxis) = length(axis.labels)

_parse_fill(::Type{T}, v::String) where {T <: AbstractFloat} = parse(T, v)
_parse_fill(::Type{T}, v::Real) where {T <: Real} = T(v)

# The schema checks the form of a timestamp, not that the date exists.
function _check_timestamp(where_::String, field::String, value::AbstractString)
    if isnothing(tryparse(Dates.DateTime, value))
        throw(ArgumentError("$where_: $field \"$value\" is not a valid date and time"))
    end
    return
end

function _check_axis_group(model_name::String, name::String, group::String)
    expected = "/$model_name/axes/$name"
    if group != expected
        throw(
            ArgumentError(
                "model $model_name: axis \"$name\" has group \"$group\", expected \"$expected\"",
            ),
        )
    end
    return
end

function _check_axis_fields(
    model_name::String,
    name::String,
    axis::InfrastructureOutputSchemas.TimeAxis,
)
    where_ = "model $model_name: axis \"$name\""
    _check_timestamp(where_, "initial_timestamp", axis.initial_timestamp)
    _check_axis_group(model_name, name, axis.group)
    return
end

function _check_axis_fields(
    model_name::String,
    name::String,
    axis::InfrastructureOutputSchemas.ExecutionAxis,
)
    where_ = "model $model_name: axis \"$name\""
    _check_timestamp(where_, "initial_timestamp", axis.initial_timestamp)
    _check_axis_group(model_name, name, axis.group)
    return
end

_check_axis_fields(::String, ::String, ::InfrastructureOutputSchemas.HorizonAxis) = nothing

function _check_axis_fields(
    model_name::String,
    name::String,
    axis::InfrastructureOutputSchemas.ComponentAxis,
)
    _check_axis_group(model_name, name, axis.group)
    return
end

_check_axis_fields(::String, ::String, ::InfrastructureOutputSchemas.LabelAxis) = nothing

function _check_dataset(
    model_name::String,
    model::InfrastructureOutputSchemas.Model,
    dataset::InfrastructureOutputSchemas.Dataset,
)
    key = dataset_key(dataset)
    where_ = "model $model_name: dataset $key"
    for name in dataset.axes
        if !_has_axis(model, name)
            throw(
                ArgumentError(
                    "$where_ uses axis \"$name\" absent from the model axes",
                ),
            )
        end
    end
    if length(dataset.layout.chunks) != length(dataset.axes)
        throw(
            ArgumentError(
                "$where_ has $(length(dataset.layout.chunks)) chunks for $(length(dataset.axes)) axes",
            ),
        )
    end
    # HDF5 accepts any positive chunk on a zero-length axis.
    for (name, chunk) in zip(dataset.axes, dataset.layout.chunks)
        n = axis_length(_find_axis(model, name))
        if !iszero(n) && chunk > n
            throw(
                ArgumentError(
                    "$where_ has chunk $chunk on axis \"$name\", which is more than the axis length $n",
                ),
            )
        end
    end
    columns = [_component_columns(_find_axis(model, name)) for name in dataset.axes]
    filter!(!isempty, columns)
    component_type = _optional_string(dataset.component_type)
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
    expected = "/$model_name/datasets/$(dataset_name(dataset))"
    if dataset.path != expected
        throw(ArgumentError("$where_ has path \"$(dataset.path)\", expected \"$expected\""))
    end
    return
end

function _check_table(model_name::String, table::InfrastructureOutputSchemas.Table)
    expected = "/$model_name/tables/$(table.name)"
    if table.group != expected
        throw(
            ArgumentError(
                "model $model_name: table $(table.name) has group \"$(table.group)\", expected \"$expected\"",
            ),
        )
    end
    seen = Set{String}()
    for column in table.columns
        if column.name in seen
            throw(
                ArgumentError(
                    "model $model_name: table $(table.name) has a duplicate column name \"$(column.name)\"",
                ),
            )
        end
        push!(seen, column.name)
    end
    return
end

# The schema requires the execution and horizon axes and forbids a time axis under the flag.
function _check_realized_values(
    model_name::String,
    model::InfrastructureOutputSchemas.Model,
)
    if !model.supports_realized_values_post_calculation
        return
    end
    execution_axis = _find_axis(model, "execution")
    horizon_axis = _find_axis(model, "horizon")
    interval = Dates.value(get_interval(execution_axis))
    resolution = Dates.value(get_resolution(horizon_axis))
    if interval <= 0 || resolution <= 0 || !iszero(rem(interval, resolution))
        throw(
            ArgumentError(
                "model $model_name: supports_realized_values_post_calculation needs an execution interval that is a positive whole multiple of the horizon resolution, got interval \"$(execution_axis.interval)\" and resolution \"$(horizon_axis.resolution)\"",
            ),
        )
    end
    if div(interval, resolution) > horizon_axis.horizon_count
        throw(
            ArgumentError(
                "model $model_name: supports_realized_values_post_calculation needs an execution interval \"$(execution_axis.interval)\" of at most the horizon ($(horizon_axis.horizon_count) x \"$(horizon_axis.resolution)\")",
            ),
        )
    end
    return
end

function _check_model(
    doc::InfrastructureOutputSchemas.OutputsDocument,
    model::InfrastructureOutputSchemas.Model,
)
    model_name = model.name
    if !haskey(_systems(doc), model.system_uuid)
        throw(
            ArgumentError(
                "model $model_name: system_uuid \"$(model.system_uuid)\" is not in systems",
            ),
        )
    end
    # The schema validation accepts NaN.
    if !(model.base_power > 0)
        throw(
            ArgumentError(
                "model $model_name: base_power is $(model.base_power), expected > 0",
            ),
        )
    end
    seen_axes = Set{String}()
    for axis in _axes(model)
        name = axis_name(axis)
        if name in seen_axes
            throw(ArgumentError("model $model_name: duplicate axis name \"$name\""))
        end
        push!(seen_axes, name)
        _check_axis_fields(model_name, name, axis)
    end
    _check_realized_values(model_name, model)
    seen = Set{Tuple{String, String, String}}()
    paths = Dict{String, Tuple{String, String, String}}()
    for dataset in model.datasets
        key = dataset_key(dataset)
        if key in seen
            throw(ArgumentError("model $model_name: duplicate dataset $key"))
        end
        push!(seen, key)
        _check_dataset(model_name, model, dataset)
        if haskey(paths, dataset.path)
            throw(
                ArgumentError(
                    "model $model_name: datasets $(paths[dataset.path]) and $key resolve to the same path \"$(dataset.path)\"",
                ),
            )
        end
        paths[dataset.path] = key
    end
    seen_tables = Set{String}()
    for table in _model_tables(model)
        if table.name in seen_tables
            throw(
                ArgumentError(
                    "model $model_name: duplicate table name \"$(table.name)\"",
                ),
            )
        end
        push!(seen_tables, table.name)
        _check_table(model_name, table)
    end
    return
end

"""
Check an outputs document. First validate it against the outputs JSON schema, which throws
`InfrastructureOutputSchemas.SchemaValidationError`. Then apply the cross-reference rules that the
schema cannot express, which throw an `ArgumentError` that names the model and the
offending axis name or dataset key. Return `nothing`.
"""
function validate_document(doc::InfrastructureOutputSchemas.OutputsDocument)
    InfrastructureOutputSchemas.encode(doc)
    owners = Dict{String, String}()
    for (uuid, name) in _systems(doc)
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
    if has_simulation(doc)
        sim = get_simulation(doc)
        _check_timestamp("simulation", "initial_time", sim.initial_time)
        for name in sim.execution_order
            if !any(model -> model.name == name, doc.models)
                throw(ArgumentError("execution_order entry \"$name\" is not in the models"))
            end
        end
    end
    seen_models = Set{String}()
    for model in doc.models
        if model.name in seen_models
            throw(ArgumentError("document: duplicate model name \"$(model.name)\""))
        end
        push!(seen_models, model.name)
        _check_model(doc, model)
    end
    return
end
