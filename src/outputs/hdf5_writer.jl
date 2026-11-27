"""
Per-axis data, in Julia order. A producer gives it for component axes only. For a component
axis, `labels` has size `(ncols, N)` and `ids` has size `(ncols, N)`, or `(0, 0)` when the
axis has no ids. HDF5 stores them in C order as `[N, ncols]`. `read_axis_data` returns the
stored `timestamps` of a time or execution axis in it.
"""
struct AxisData
    ids::Matrix{Int64}
    labels::Matrix{String}
    timestamps::Vector{Dates.DateTime}
end

"Return an empty `AxisData`, for axes that store no data."
function AxisData()
    return AxisData(zeros(Int64, 0, 0), Matrix{String}(undef, 0, 0), Dates.DateTime[])
end

"Return the `AxisData` of a component axis with the given ids and labels."
function AxisData(ids::Matrix{Int64}, labels::Matrix{String})
    return AxisData(ids, labels, Dates.DateTime[])
end

"Return the `AxisData` of a time or execution axis with the given timestamps."
function AxisData(timestamps::Vector{Dates.DateTime})
    return AxisData(zeros(Int64, 0, 0), Matrix{String}(undef, 0, 0), timestamps)
end

"Return the ids of the `AxisData`."
get_ids(data::AxisData) = data.ids

"Return the labels of the `AxisData`."
get_labels(data::AxisData) = data.labels

"Return the timestamps of the `AxisData`."
get_timestamps(data::AxisData) = data.timestamps

# Open handle of the HDF5 dataset of one dataset with what `write_execution!` and `write_values!` need.
# `exec_dim` is the execution dimension in Julia order, 0 when absent. `expected` is the
# size of one execution slice (the whole dataset size when `exec_dim` is 0). `written` has
# one entry per execution, or one entry when `exec_dim` is 0.
struct DatasetRecord
    h5_dataset::HDF5.Dataset
    storage_type::DataType
    exec_dim::Int
    expected::Vector{Int}
    written::BitVector
end

"Writer of an artifact. It holds an `OutputsDocument`. Use `open_outputs_writer` to create one."
mutable struct OutputsWriter
    dir::String
    document::OutputsDocument
    file::HDF5.File
    datasets::Dict{Tuple{String, String, String, String}, DatasetRecord}
    tables_written::Set{Tuple{String, String}}
end

"Hook that writes the bundle of a system into `dir`. Packages that own systems implement it."
function write_system_bundle(obj, ::AbstractString)
    throw(ArgumentError("no bundle writer for $(typeof(obj))"))
end

"Return the epoch milliseconds of each timestamp."
function timestamps_epoch_ms(ts::Vector{Dates.DateTime})
    return Int64[Dates.value(t - Dates.DateTime(1970)) for t in ts]
end

function _check_axis_set(doc::OutputsDocument, axis_data)
    for (model_name, name) in keys(axis_data)
        i = findfirst(model -> model.name == model_name, doc.models)
        if isnothing(i) || !_has_axis(doc.models[i], name)
            throw(
                ArgumentError("model $model_name: axis data name \"$name\" names no axis"),
            )
        end
        if !takes_axis_data(_find_axis(doc.models[i], name))
            throw(
                ArgumentError("model $model_name: axis \"$name\" takes no axis data"),
            )
        end
    end
    for model in doc.models, axis in model.axes
        if takes_axis_data(axis)
            model_name = model.name
            name = axis_name(axis)
            if !haskey(axis_data, (model_name, name))
                throw(
                    ArgumentError("model $model_name: no axis data for axis \"$name\""),
                )
            end
            _check_axis_data(model_name, name, axis, axis_data[(model_name, name)])
        end
    end
    return
end

function _check_axis_data(
    model_name::String,
    name::String,
    axis::ComponentAxis,
    data::AxisData,
)
    n = axis_length(axis)
    nc = length(axis.columns)
    if size(data.labels) != (nc, n)
        throw(
            ArgumentError(
                "model $model_name: axis \"$name\" labels have size $(size(data.labels)), expected $((nc, n))",
            ),
        )
    end
    with_ids = count(column -> column.has_ids, axis.columns)
    if with_ids == nc
        if size(data.ids) != (nc, n)
            throw(
                ArgumentError(
                    "model $model_name: axis \"$name\" ids have size $(size(data.ids)), expected $((nc, n))",
                ),
            )
        end
    elseif iszero(with_ids)
        if !isempty(data.ids)
            throw(
                ArgumentError(
                    "model $model_name: axis \"$name\" has ids but no id columns",
                ),
            )
        end
    else
        throw(
            ArgumentError(
                "model $model_name: axis \"$name\" mixes columns with and without ids"),
        )
    end
    return
end

_write_axis!(::HDF5.Group, ::HorizonAxis, _, _) = nothing

function _write_axis!(g::HDF5.Group, axis::LabelAxis, _, _)
    g["labels"] = axis.labels
    return
end

function _write_axis!(g::HDF5.Group, axis::ComponentAxis, axis_data, model_axis)
    data = axis_data[model_axis]
    if all(column -> column.has_ids, axis.columns)
        g["ids"] = data.ids
    end
    g["labels"] = data.labels
    return
end

function _write_axis!(g::HDF5.Group, axis::Union{TimeAxis, ExecutionAxis}, _, _)
    g["timestamps"] = timestamps_epoch_ms(axis_timestamps(axis))
    return
end

function _create_dataset!(
    f::HDF5.File,
    model_name::String,
    dataset::OutputDataset,
    model::OutputsModel,
)
    key = dataset_key(dataset)
    T = _DTYPES[dataset.dtype][1]
    dataset_axes = _dataset_axes(model, dataset)
    dims = _dataset_dims(dataset_axes)
    pos = findfirst(is_append_axis, dataset_axes)
    exec_dim = 0
    expected = dims
    written = falses(1)
    if !isnothing(pos)
        exec_dim = length(dataset.axes) - pos + 1
        expected = deleteat!(copy(dims), exec_dim)
        written = falses(dims[exec_dim])
    end
    # The schema accepts only `shuffle` and `deflate:L` names.
    filters = HDF5.Filters.Filter[]
    for filter_name in dataset.filters
        if filter_name == "shuffle"
            push!(filters, HDF5.Filters.Shuffle())
        else
            # The schema accepts `deflate:1` to `deflate:9`.
            level = parse(Int, filter_name[(length("deflate:") + 1):end])
            push!(filters, HDF5.Filters.Deflate(level))
        end
    end
    h5_dataset = HDF5.create_dataset(
        f, dataset_path(model_name, dataset), HDF5.datatype(T),
        HDF5.dataspace(Tuple(dims));
        chunk = Tuple(reverse(dataset.chunks)),
        fill_value = _parse_fill(T, dataset.fill_value),
        filters,
    )
    return (model_name, key...) =>
        DatasetRecord(h5_dataset, T, exec_dim, expected, written)
end

# Create the file and close it again when populating fails.
function _create_h5(
    path::String,
    doc::OutputsDocument,
    axis_data,
)
    f = HDF5.h5open(path, "w")
    try
        records = Dict{Tuple{String, String, String, String}, DatasetRecord}()
        for model in doc.models
            model_name = model.name
            for axis in model.axes
                g = HDF5.create_group(f, axis_group(model_name, axis))
                _write_axis!(g, axis, axis_data, (model_name, axis_name(axis)))
            end
            for dataset in model.datasets
                push!(records, _create_dataset!(f, model_name, dataset, model))
            end
            for table in model.tables
                g = HDF5.create_group(f, table_group(model_name, table))
                for column in table.columns
                    T = _column_storage_type(column.dtype)
                    HDF5.create_dataset(
                        g,
                        column.name,
                        HDF5.datatype(T),
                        HDF5.dataspace((table.length,)),
                    )
                end
            end
        end
        return f, records
    catch
        try
            close(f)
        catch
        end
        rethrow()
    end
end

"""
    open_outputs_writer(dir, doc; axis_data) -> OutputsWriter

Validate `doc`, create `dir`, write `outputs.json` with status `RUNNING`, and create
`outputs.h5` with every axis, dataset, and table of `doc`. `axis_data` is keyed by
`(model_name, axis_name)`. It has one entry for each axis where `takes_axis_data` is `true`
and no other entry. The writer stores the timestamps of a time or execution axis from the
axis itself. Throw `ArgumentError` when `dir` already holds `outputs.json` or
`outputs.h5`.
"""
function open_outputs_writer(
    dir::AbstractString,
    doc::OutputsDocument;
    axis_data::Dict{Tuple{String, String}, AxisData},
)
    validate_document(doc)
    _check_axis_set(doc, axis_data)
    for name in _ARTIFACT_FILE_NAMES
        path = joinpath(dir, name)
        if ispath(path)
            throw(ArgumentError("outputs file $path already exists"))
        end
    end
    mkpath(dir)
    json_path = joinpath(dir, _JSON_FILE_NAME)
    h5_path = joinpath(dir, _H5_FILE_NAME)
    try
        running = with_status(doc, Simulation.RunStatus.RUNNING)
        write_outputs_document(json_path, running)
        f, records = _create_h5(h5_path, doc, axis_data)
        return OutputsWriter(String(dir), running, f, records, Set{Tuple{String, String}}())
    catch
        rm(h5_path; force = true)
        rm(json_path; force = true)
        rethrow()
    end
end

function _is_running(doc::OutputsDocument)
    return doc.status == Simulation.RunStatus.RUNNING
end

function _check_running(w::OutputsWriter)
    if !_is_running(w.document) || !isopen(w.file)
        throw(ArgumentError("outputs writer for $(w.dir) is not running"))
    end
    return
end

function _record(
    w::OutputsWriter,
    model_name::AbstractString,
    key::Tuple{String, String, String},
)
    record_key = (String(model_name), key...)
    if !haskey(w.datasets, record_key)
        throw(ArgumentError("model $model_name: no dataset $key"))
    end
    return w.datasets[record_key]
end

function _convert_values(::Type{T}, values::AbstractArray) where {T}
    return T.(values)
end

_convert_values(::Type{T}, values::Array{T}) where {T} = values

"""
    write_execution!(w, model_name, key, values, execution_index)

Write `values` (Julia order, every axis except `execution`) into slice `execution_index`
of the dataset with the dataset key `key = (entry_type, component_type, meta)`.
"""
function write_execution!(
    w::OutputsWriter,
    model_name::AbstractString,
    key::Tuple{String, String, String},
    values::AbstractArray,
    execution_index::Int,
)
    _check_running(w)
    record = _record(w, model_name, key)
    if iszero(record.exec_dim)
        throw(ArgumentError("model $model_name: dataset $key has no execution axis"))
    end
    count = length(record.written)
    if !(1 <= execution_index <= count)
        throw(
            ArgumentError(
                "model $model_name: dataset $key execution_index $execution_index is outside 1:$count",
            ),
        )
    end
    _check_values_size(model_name, key, values, Tuple(record.expected))
    idx = Any[Colon() for _ in 1:ndims(record.h5_dataset)]
    idx[record.exec_dim] = execution_index
    record.h5_dataset[idx...] = _convert_values(record.storage_type, values)
    record.written[execution_index] = true
    return
end

"""
    write_values!(w, model_name, key, values)

Write the whole dataset with the dataset key `key`. The size of `values` must equal the
dataset size.
"""
function write_values!(
    w::OutputsWriter,
    model_name::AbstractString,
    key::Tuple{String, String, String},
    values::AbstractArray,
)
    _check_running(w)
    record = _record(w, model_name, key)
    _check_values_size(model_name, key, values, size(record.h5_dataset))
    record.h5_dataset[axes(values)...] = _convert_values(record.storage_type, values)
    fill!(record.written, true)
    return
end

"""
    write_table!(w, model_name, table_name, columns::NamedTuple)

Write one vector per column of the table. Every vector has the table `length`.
"""
function write_table!(
    w::OutputsWriter,
    model_name::AbstractString,
    table_name::AbstractString,
    columns::NamedTuple,
)
    _check_running(w)
    table = _find_table(w.document, model_name, table_name)
    if Set(keys(columns)) != Set(Symbol(column.name) for column in table.columns)
        throw(
            ArgumentError(
                "model $model_name: table $table_name columns $(collect(keys(columns))) differ from the document",
            ),
        )
    end
    for column in table.columns
        v = columns[Symbol(column.name)]
        if length(v) != table.length
            throw(
                ArgumentError(
                    "model $model_name: table $table_name column $(column.name) has length $(length(v)), expected $(table.length)",
                ),
            )
        end
        w.file[string(table_group(model_name, table), "/", column.name)][:] =
            _convert_values(_column_storage_type(column.dtype), v)
    end
    push!(w.tables_written, (String(model_name), String(table_name)))
    return
end

"""
Flush the HDF5 file to disk. Producers call it once per execution, so readers see the
values written so far.
"""
function Base.flush(w::OutputsWriter)
    flush(w.file)
    return
end

# Names of the declared datasets and tables that no write call filled completely.
function _unwritten(w::OutputsWriter)
    missing_ = String[]
    for ((model_name, entry_type, component_type, meta), record) in w.datasets
        name = dataset_name(entry_type, component_type, meta)
        if iszero(record.exec_dim) && !only(record.written)
            push!(missing_, "model $model_name: dataset $name was never written")
        elseif !all(record.written)
            executions = findall(!, record.written)
            if length(executions) <= 5
                summary = string(executions)
            else
                summary = string(executions[1:5], " and ", length(executions) - 5, " more")
            end
            push!(
                missing_,
                "model $model_name: dataset $name lacks executions $summary",
            )
        end
    end
    for model in w.document.models, table in model.tables
        model_name = model.name
        if !((model_name, table.name) in w.tables_written)
            push!(missing_, "model $model_name: table $(table.name) was never written")
        end
    end
    return sort!(missing_)
end

"""
    finalize!(w; status)

Close the HDF5 file, then rewrite `outputs.json` with `status` and the current time.
`status` is `SUCCESSFULLY_FINALIZED` or `FAILED`. The writer must have status `RUNNING`.
`SUCCESSFULLY_FINALIZED` throws `ArgumentError` when a declared dataset or table was never
written, an execution of a dataset was never written, or a declared system bundle
directory does not exist. The writer keeps status `RUNNING`
then, and `finalize!` with `FAILED` stays possible.
When the JSON write fails, the writer keeps status `RUNNING` and `finalize!` can run again.
"""
function finalize!(w::OutputsWriter; status::Simulation.RunStatus.Value)
    if !_is_running(w.document)
        throw(ArgumentError("outputs writer for $(w.dir) is finalized"))
    end
    if !(
        status in (
            Simulation.RunStatus.SUCCESSFULLY_FINALIZED,
            Simulation.RunStatus.FAILED,
        )
    )
        throw(
            ArgumentError(
                "finalize! accepts SUCCESSFULLY_FINALIZED or FAILED, got $status",
            ),
        )
    end
    if status == Simulation.RunStatus.SUCCESSFULLY_FINALIZED
        unwritten = _unwritten(w)
        for (uuid, name) in w.document.systems
            if !isdir(joinpath(w.dir, name))
                push!(unwritten, "system $uuid: bundle directory $name does not exist")
            end
        end
        if !isempty(unwritten)
            throw(
                ArgumentError(
                    "outputs writer for $(w.dir) cannot finalize as SUCCESSFULLY_FINALIZED:\n" *
                    join(unwritten, "\n"),
                ),
            )
        end
    end
    for record in values(w.datasets)
        close(record.h5_dataset)
    end
    if isopen(w.file)
        close(w.file)
    end
    stamp = TimeZones.now(TimeZones.tz"UTC")
    doc = with_status(w.document, status; created_at = stamp)
    write_outputs_document(joinpath(w.dir, _JSON_FILE_NAME), doc)
    w.document = doc
    return
end

"""
    abort!(w)

Mark the run `FAILED` when possible and always close the file. Never throws. Public: the
producers of outputs call it when a write fails.
"""
function abort!(w::OutputsWriter)
    if _is_running(w.document)
        try
            finalize!(w; status = Simulation.RunStatus.FAILED)
        catch
        end
    end
    try
        if isopen(w.file)
            close(w.file)
        end
    catch
    end
    return
end

"""
    write_outputs(dir, doc; axis_data, values, tables, systems)

One-shot writer. `axis_data` follows the rule of `open_outputs_writer`. `values` is keyed by `(model_name, entry_type, component_type, meta)` and
`tables` by `(model_name, table_name)`. `systems` maps a system uuid to an object that
implements `write_system_bundle(obj, dir)`.
"""
function write_outputs(
    dir::AbstractString,
    doc::OutputsDocument;
    axis_data::Dict{Tuple{String, String}, AxisData},
    values::AbstractDict,
    tables::AbstractDict,
    systems::AbstractDict = Dict{String, Any}(),
)
    for uuid in keys(systems)
        if !haskey(doc.systems, uuid)
            throw(ArgumentError("system $uuid is not in the document systems"))
        end
    end
    w = open_outputs_writer(dir, doc; axis_data = axis_data)
    try
        for ((model_name, entry_type, component_type, meta), v) in values
            write_values!(w, model_name, (entry_type, component_type, meta), v)
        end
        for ((model_name, table_name), cols) in tables
            write_table!(w, model_name, table_name, cols)
        end
        for (uuid, obj) in systems
            bundle = joinpath(dir, doc.systems[uuid])
            mkpath(bundle)
            write_system_bundle(obj, bundle)
        end
        finalize!(w; status = Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    catch
        abort!(w)
        rethrow()
    end
    return
end
