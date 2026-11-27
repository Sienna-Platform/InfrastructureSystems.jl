"""
Schema version string of `outputs.json`. IS writes it in each `OutputsDocument` that a
producer builds.
"""
const OUTPUTS_SCHEMA_VERSION = "0.1.0"

const _JSON_FILE_NAME = "outputs.json"
const _H5_FILE_NAME = "outputs.h5"
const _ARTIFACT_FILE_NAMES = (_JSON_FILE_NAME, _H5_FILE_NAME)
const _STAGING_SUFFIX = ".tmp"
# `write_outputs_document` writes the staging file next to `outputs.json`.
const _RESERVED_BUNDLE_NAMES =
    (_ARTIFACT_FILE_NAMES..., string(_JSON_FILE_NAME, _STAGING_SUFFIX))

"""
Return the axis name that a dataset uses to refer to the axis.
"""
axis_name(::Type{TimeAxis}) = "time"
axis_name(::Type{ExecutionAxis}) = "execution"
axis_name(::Type{HorizonAxis}) = "horizon"
axis_name(::TimeAxis) = axis_name(TimeAxis)
axis_name(::ExecutionAxis) = axis_name(ExecutionAxis)
axis_name(::HorizonAxis) = axis_name(HorizonAxis)
axis_name(axis::LabelAxis) = axis.name

function axis_name(axis::ComponentAxis)
    name = join((column.component_type for column in axis.columns), "__")
    if isempty(axis.subset)
        return name
    end
    return string(name, "__", axis.subset)
end

"""
Return the number of entries along the axis.
"""
axis_length(axis::TimeAxis) = axis.length
axis_length(axis::ExecutionAxis) = axis.count
axis_length(axis::HorizonAxis) = axis.horizon_count
axis_length(axis::ComponentAxis) = axis.length
axis_length(axis::LabelAxis) = length(axis.labels)

"""
Return the timestamps of the axis.
"""
function axis_timestamps(axis::TimeAxis)
    return [axis.initial_timestamp + (i - 1) * axis.resolution for i in 1:(axis.length)]
end

function axis_timestamps(axis::ExecutionAxis)
    return [axis.initial_timestamp + (i - 1) * axis.interval for i in 1:(axis.count)]
end

"""
Return `true` when the axis is the dimension that a writer fills one execution at a time.
"""
is_append_axis(::OutputAxis) = false
is_append_axis(::ExecutionAxis) = true

"""
Return `true` when the axis loses chunk length first, if a chunk is too large.
"""
shrinks_first(::OutputAxis) = false
shrinks_first(::TimeAxis) = true
shrinks_first(::HorizonAxis) = true

"""
Return `true` when the axis needs `AxisData` from the producer.
"""
takes_axis_data(::OutputAxis) = false
takes_axis_data(::ComponentAxis) = true

_component_columns(::OutputAxis) = ComponentAxisColumn[]
_component_columns(axis::ComponentAxis) = axis.columns

_parse_fill(::Type{T}, v::String) where {T <: AbstractFloat} = parse(T, v)
_parse_fill(::Type{T}, v::Real) where {T <: Real} = T(v)

function _check_dataset(model_name::String, model::OutputsModel, dataset::OutputDataset)
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
    if length(dataset.chunks) != length(dataset.axes)
        throw(
            ArgumentError(
                "$where_ has $(length(dataset.chunks)) chunks for $(length(dataset.axes)) axes",
            ),
        )
    end
    # HDF5 accepts any positive chunk on a zero-length axis.
    for (name, chunk) in zip(dataset.axes, dataset.chunks)
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
    if isempty(columns)
        if !isempty(dataset.component_type)
            throw(ArgumentError("$where_: component_type without a component axis"))
        end
    else
        expected_type = first(first(columns)).component_type
        if dataset.component_type != expected_type
            throw(
                ArgumentError(
                    "$where_: component_type \"$(dataset.component_type)\" differs from the component axis type \"$expected_type\"",
                ),
            )
        end
    end
    return
end

function _check_table(model_name::String, table::OutputTable)
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
function _check_realized_values(model_name::String, model::OutputsModel)
    if !model.supports_realized_values_post_calculation
        return
    end
    execution_axis = _find_axis(model, axis_name(ExecutionAxis))
    horizon_axis = _find_axis(model, axis_name(HorizonAxis))
    interval = Dates.value(get_interval(execution_axis))
    resolution = Dates.value(get_resolution(horizon_axis))
    if interval <= 0 || resolution <= 0 || !iszero(rem(interval, resolution))
        throw(
            ArgumentError(
                "model $model_name: supports_realized_values_post_calculation needs an execution interval that is a positive whole multiple of the horizon resolution, got interval $(get_interval(execution_axis)) and resolution $(get_resolution(horizon_axis))",
            ),
        )
    end
    if div(interval, resolution) > axis_length(horizon_axis)
        throw(
            ArgumentError(
                "model $model_name: supports_realized_values_post_calculation needs an execution interval $(get_interval(execution_axis)) of at most the horizon ($(axis_length(horizon_axis)) x $(get_resolution(horizon_axis)))",
            ),
        )
    end
    return
end

function _check_model(doc::OutputsDocument, model::OutputsModel)
    model_name = model.name
    if !haskey(doc.systems, model.system_uuid)
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
    for axis in model.axes
        name = axis_name(axis)
        if name in seen_axes
            throw(ArgumentError("model $model_name: duplicate axis name \"$name\""))
        end
        push!(seen_axes, name)
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
        path = dataset_path(model_name, dataset)
        if haskey(paths, path)
            throw(
                ArgumentError(
                    "model $model_name: datasets $(paths[path]) and $key resolve to the same path \"$path\"",
                ),
            )
        end
        paths[path] = key
    end
    seen_tables = Set{String}()
    for table in model.tables
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
Check an outputs document. First validate it against the outputs JSON schema. That step
throws a `SchemaValidationError` of the OpenAPI runtime for a value that breaks a schema
rule. It throws `ArgumentError` for a value that has no schema form, such as a duration that
is not a whole number of minutes. Then apply the cross-reference rules that the schema cannot
express, which throw an `ArgumentError` that names the model and the offending axis name or
dataset key. Return `nothing`.
"""
function validate_document(doc::OutputsDocument)
    _encode_document(doc)
    owners = Dict{String, String}()
    for (uuid, name) in doc.systems
        # On Windows, `joinpath(dir, "C:foo")` drops `dir`.
        if occursin(r"\A.:"s, name)
            throw(
                ArgumentError(
                    "system $uuid: bundle directory \"$name\" starts with a Windows drive prefix",
                ),
            )
        end
        # A file system that ignores case treats `OUTPUTS.JSON` as `outputs.json`.
        if lowercase(name) in _RESERVED_BUNDLE_NAMES
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
        for name in get_simulation(doc).execution_order
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
