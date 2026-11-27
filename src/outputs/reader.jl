"""
Handle of an artifact. It holds an `OutputsDocument`. The HDF5 file is opened for each read,
never held. Use `open_outputs_reader` to create one.
"""
struct OutputsReader
    dir::String
    document::OutputsDocument
end

"""
    open_outputs_reader(dir) -> OutputsReader

Read and validate `outputs.json` in `dir`. Check that `outputs.h5` and the bundle directory
of every declared system exist. Warn when the status is `RUNNING`: the run is in progress or
ended without a final status, and datasets can be partly written.
"""
function open_outputs_reader(dir::AbstractString)
    json_path = joinpath(dir, _JSON_FILE_NAME)
    if !isfile(json_path)
        throw(ArgumentError("artifact $dir has no $_JSON_FILE_NAME"))
    end
    doc = read_outputs_document(json_path)
    validate_document(doc)
    if !isfile(joinpath(dir, _H5_FILE_NAME))
        throw(ArgumentError("artifact $dir has no $_H5_FILE_NAME"))
    end
    for (uuid, name) in doc.systems
        if !isdir(joinpath(dir, name))
            throw(
                ArgumentError(
                    "artifact $dir has no bundle directory \"$name\" for system $uuid",
                ),
            )
        end
    end
    if _is_running(doc)
        @warn "The artifact in $dir has status RUNNING: the run is not finished or ended without a final status. Datasets can be partly written."
    end
    return OutputsReader(String(dir), doc)
end

"Return the `OutputsDocument` of the artifact."
get_document(reader::OutputsReader) = reader.document

"Return the sorted model names of the artifact."
function list_models(reader::OutputsReader)
    return sort!(String[model.name for model in reader.document.models])
end

"Return the dataset key `(entry_type, component_type, meta)` of every dataset of the model `model_name`."
function list_datasets(reader::OutputsReader, model_name::AbstractString)
    return Tuple{String, String, String}[
        dataset_key(dataset) for
        dataset in _find_model(reader.document, model_name).datasets
    ]
end

"Return the table names of the model `model_name`."
function list_tables(reader::OutputsReader, model_name::AbstractString)
    return String[
        table.name for table in _find_model(reader.document, model_name).tables
    ]
end

"Return the `OutputAxis` with the axis name `name` of the model `model_name`."
function get_axis(
    reader::OutputsReader,
    model_name::AbstractString,
    name::AbstractString,
)
    model = _find_model(reader.document, model_name)
    return _find_axis(model, name)
end

_h5_path(reader::OutputsReader) = joinpath(reader.dir, _H5_FILE_NAME)

# Axes without stored data (horizon, label) give empty AxisData.
function _read_axis_data(
    ::HDF5.File,
    ::AbstractString,
    ::AbstractString,
    ::Union{HorizonAxis, LabelAxis},
)
    return AxisData()
end

function _read_axis_data(
    f::HDF5.File,
    model_name::AbstractString,
    name::AbstractString,
    axis::ComponentAxis,
)
    g = f[axis_group(model_name, axis)]
    ids = zeros(Int64, 0, 0)
    if haskey(g, "ids")
        ids = read(g["ids"])
    elseif all(column -> column.has_ids, axis.columns)
        throw(
            ArgumentError(
                "model $model_name: axis $name has id columns but no ids HDF5 dataset",
            ),
        )
    end
    return AxisData(ids, read(g["labels"]), Dates.DateTime[])
end

function _read_axis_data(
    f::HDF5.File,
    model_name::AbstractString,
    ::AbstractString,
    axis::Union{TimeAxis, ExecutionAxis},
)
    timestamps = [
        Dates.DateTime(1970) + Dates.Millisecond(ms) for
        ms in read(f[axis_group(model_name, axis)]["timestamps"])
    ]
    return AxisData(timestamps)
end

"""
Return the `AxisData` stored for the axis `name` of the model `model_name`. A time or
execution axis gives its stored timestamps, a component axis gives its ids and labels, and a
horizon or label axis gives an empty `AxisData`.
"""
function read_axis_data(
    reader::OutputsReader,
    model_name::AbstractString,
    name::AbstractString,
)
    axis = get_axis(reader, model_name, name)
    return HDF5.h5open(_h5_path(reader), "r") do f
        return _read_axis_data(f, model_name, name, axis)
    end
end

# Selection on the execution dimension and whether the dimension remains.
_execution_selection(::Colon, ::Int) = (Colon(), true)

function _execution_selection(i::Int, n::Int)
    _check_range(i:i, n)
    return (i, false)
end

function _execution_selection(r::UnitRange{Int}, n::Int)
    _check_range(r, n)
    return (r, true)
end

function _check_range(r::UnitRange{Int}, n::Int)
    if isempty(r) || first(r) < 1 || last(r) > n
        throw(ArgumentError("execution $r is outside 1:$n"))
    end
    return
end

# The writer stores bool as UInt8.
function _decode(dtype::String, v)
    if dtype == "bool"
        return Bool.(v)
    end
    return v
end

# The stored shape and element type match the document.
function _check_stored(
    model_name,
    key,
    dataset::OutputDataset,
    h5_dataset::HDF5.Dataset,
    expected::Tuple,
)
    if size(h5_dataset) != expected
        throw(
            ArgumentError(
                "model $model_name: dataset $key is stored with size $(size(h5_dataset)), the document expects $expected",
            ),
        )
    end
    dtype = dataset.dtype
    storage = _DTYPES[dtype][1]
    if eltype(h5_dataset) != storage
        throw(
            ArgumentError(
                "model $model_name: dataset $key is stored as $(eltype(h5_dataset)), the document dtype $dtype expects $storage",
            ),
        )
    end
    return
end

"""
    read_dataset(reader, model_name, entry_type, component_type; meta = "", execution = Colon())
        -> (array, axis_names)

Read one dataset in Julia order (the reverse of the document `axes`). `axis_names` lists
the axis names in the same order. `execution` (`Colon`, `Int`, or `UnitRange`) selects along
the execution axis only. An `Int` removes that axis from the result. Bool datasets return
`Bool`.
"""
function read_dataset(
    reader::OutputsReader,
    model_name::AbstractString,
    entry_type::AbstractString,
    component_type::AbstractString;
    meta::AbstractString = "",
    execution = Colon(),
)
    key = (String(entry_type), String(component_type), String(meta))
    model = _find_model(reader.document, model_name)
    dataset = _find_dataset(model, key)
    names_julia = reverse(dataset.axes)
    idx = Any[Colon() for _ in names_julia]
    keep = trues(length(names_julia))
    dataset_axes = _dataset_axes(model, dataset)
    axes_julia = reverse(dataset_axes)
    pos = findfirst(is_append_axis, axes_julia)
    if isnothing(pos)
        if execution != Colon()
            throw(ArgumentError("model $model_name: dataset $key has no execution axis"))
        end
    else
        idx[pos], keep[pos] =
            _execution_selection(execution, axis_length(axes_julia[pos]))
    end
    expected = Tuple(_dataset_dims(dataset_axes))
    arr = HDF5.h5open(_h5_path(reader), "r") do f
        h5_dataset = f[dataset_path(model_name, dataset)]
        _check_stored(model_name, key, dataset, h5_dataset, expected)
        return h5_dataset[idx...]
    end
    return _decode(dataset.dtype, arr), names_julia[keep]
end

"Return the columns of the table `table_name` of the model `model_name` as a `NamedTuple` of vectors."
function read_table(
    reader::OutputsReader,
    model_name::AbstractString,
    table_name::AbstractString,
)
    table = _find_table(reader.document, model_name, table_name)
    column_values = HDF5.h5open(_h5_path(reader), "r") do f
        return [
            read(f[string(table_group(model_name, table), "/", column.name)]) for
            column in table.columns
        ]
    end
    return NamedTuple{Tuple(Symbol(column.name) for column in table.columns)}(
        Tuple(
            _decode(column.dtype, v) for
            (column, v) in zip(table.columns, column_values)
        ),
    )
end
