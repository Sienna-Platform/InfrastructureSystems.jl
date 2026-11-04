"""
Per-axis data written next to the metadata, in Julia order. Needed for `time`,
`execution`, and `component` axes only. For a component axis, `labels` has size
`(ncols, N)` and `ids` has size `(ncols, N)`, or `(0, 0)` when the axis has no ids.
HDF5 stores them in C order as `[N, ncols]`. `timestamps` is empty for component axes.
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

"Return the `AxisData` of a time or execution axis with the given timestamps."
function AxisData(timestamps::Vector{Dates.DateTime})
    return AxisData(zeros(Int64, 0, 0), Matrix{String}(undef, 0, 0), timestamps)
end

# Open handle of one dataset with what `append!` and `write_values!` need. `exec_dim` is the
# execution dimension in Julia order, 0 when absent. `expected` is the size of one
# execution slice (the whole dataset size when `exec_dim` is 0).
struct DatasetRecord
    dataset::HDF5.Dataset
    storage::DataType
    exec_dim::Int
    expected::Tuple{Vararg{Int}}
end

"Writer of an outputs directory. Use `open_outputs_writer` to create one."
mutable struct OutputsWriter
    dir::String
    metadata::OutputsMetadata
    file::HDF5.File
    datasets::Dict{Tuple{String, String, String, String}, DatasetRecord}
end

"Hook that writes the bundle of a system into `dir`. Packages that own systems implement it."
function write_system_bundle(obj, ::AbstractString)
    throw(ArgumentError("no bundle writer for $(typeof(obj))"))
end

"Return the epoch milliseconds of each timestamp."
function timestamps_epoch_ms(ts::Vector{Dates.DateTime})
    return Int64[Dates.value(t - Dates.DateTime(1970)) for t in ts]
end

function _fill_value(
    model::String,
    key,
    dtype::String,
    ::Type{T},
    v::Union{String, Float64, Int64, Bool},
) where {T}
    try
        return _parse_fill(T, v)
    catch
        throw(
            ArgumentError(
                "model $model dataset $key: fill_value $v is not valid for dtype $dtype",
            ),
        )
    end
end

function _make_filters(model::String, key, names::Vector{String})
    filters = HDF5.Filters.Filter[]
    for f in names
        if f == "shuffle"
            push!(filters, HDF5.Filters.Shuffle())
        elseif startswith(f, "deflate:")
            level = tryparse(Int, f[(length("deflate:") + 1):end])
            if isnothing(level) || !(1 <= level <= 9)
                throw(
                    ArgumentError(
                        "model $model: dataset $key has invalid filter \"$f\", deflate level must be 1 to 9",
                    ),
                )
            end
            push!(filters, HDF5.Filters.Deflate(level))
        else
            throw(ArgumentError("model $model: dataset $key has unknown filter \"$f\""))
        end
    end
    return filters
end

# Only time, execution, and component axes carry datasets and need AxisData.
_needs_axis_data(::Union{TimeAxis, ExecutionAxis, ComponentAxis}) = true
_needs_axis_data(::Union{HorizonAxis, LabelAxis}) = false

function _check_axis_set(m::OutputsMetadata, axis_data)
    for (model, name) in keys(axis_data)
        if !haskey(m.models, model) || !haskey(m.models[model].axes, name)
            throw(ArgumentError("model $model: axis data key \"$name\" names no axis"))
        end
        if !_needs_axis_data(m.models[model].axes[name])
            throw(
                ArgumentError(
                    "model $model: axis \"$name\" carries no datasets and takes no axis data",
                ),
            )
        end
    end
    for (model, entry) in m.models, (name, ax) in entry.axes
        if _needs_axis_data(ax)
            if !haskey(axis_data, (model, name))
                throw(ArgumentError("model $model: no axis data for axis \"$name\""))
            end
            _check_axis_data(model, name, ax, axis_data[(model, name)])
        end
    end
    return
end

function _check_axis_data(model::String, name::String, ax::ComponentAxis, d::AxisData)
    n = axis_length(ax)
    nc = length(ax.columns)
    if size(d.labels) != (nc, n)
        throw(
            ArgumentError(
                "model $model: axis \"$name\" labels have size $(size(d.labels)), expected $((nc, n))",
            ),
        )
    end
    with_ids = count(c -> c.has_ids, ax.columns)
    if with_ids == nc
        if size(d.ids) != (nc, n)
            throw(
                ArgumentError(
                    "model $model: axis \"$name\" ids have size $(size(d.ids)), expected $((nc, n))",
                ),
            )
        end
    elseif iszero(with_ids)
        if !isempty(d.ids)
            throw(ArgumentError("model $model: axis \"$name\" has ids but no id columns"))
        end
    else
        throw(
            ArgumentError(
                "model $model: axis \"$name\" mixes columns with and without ids"),
        )
    end
    return
end

function _check_axis_data(
    model::String,
    name::String,
    ax::Union{TimeAxis, ExecutionAxis},
    d::AxisData,
)
    n = axis_length(ax)
    if length(d.timestamps) != n
        throw(
            ArgumentError(
                "model $model: axis \"$name\" has $(length(d.timestamps)) timestamps, expected $n",
            ),
        )
    end
    return
end

# Only time, execution, and component axes index `axis_data`.
_write_axis!(::HDF5.Group, ::HorizonAxis, _, _) = nothing

function _write_axis!(g::HDF5.Group, ax::LabelAxis, _, _)
    g["labels"] = ax.labels
    return
end

function _write_axis!(g::HDF5.Group, ::ComponentAxis, axis_data, key)
    d = axis_data[key]
    if !isempty(d.ids)
        g["ids"] = d.ids
    end
    g["labels"] = d.labels
    return
end

function _write_axis!(g::HDF5.Group, ::Union{TimeAxis, ExecutionAxis}, axis_data, key)
    g["timestamps"] = timestamps_epoch_ms(axis_data[key].timestamps)
    return
end

function _create_dataset!(f::HDF5.File, model::String, d::OutputDataset, m::ModelEntry)
    key = dataset_key(d)
    T = _DTYPES[d.dtype][1]
    dims = reverse([axis_length(m.axes[a]) for a in d.axes])
    pos = findfirst(==("execution"), d.axes)
    exec_dim = 0
    expected = Tuple(dims)
    if !isnothing(pos)
        exec_dim = length(d.axes) - pos + 1
        expected = Tuple(deleteat!(copy(dims), exec_dim))
    end
    ds = HDF5.create_dataset(
        f, d.path, HDF5.datatype(T), HDF5.dataspace(Tuple(dims));
        chunk = Tuple(reverse(d.layout.chunks)),
        fill_value = _fill_value(model, key, d.dtype, T, d.fill_value),
        filters = _make_filters(model, key, d.layout.filters),
    )
    return (model, key...) => DatasetRecord(ds, T, exec_dim, expected)
end

function _create_table!(f::HDF5.File, t::OutputTable)
    g = HDF5.create_group(f, t.group)
    for c in t.columns
        T = _column_storage_type(c.dtype)
        HDF5.create_dataset(g, c.name, HDF5.datatype(T), HDF5.dataspace((t.length,)))
    end
    return
end

function _populate!(f::HDF5.File, m::OutputsMetadata, axis_data)
    records = Dict{Tuple{String, String, String, String}, DatasetRecord}()
    for (model, entry) in m.models
        for (name, ax) in entry.axes
            g = HDF5.create_group(f, "/$model/axes/$name")
            _write_axis!(g, ax, axis_data, (model, name))
        end
        for d in entry.datasets
            push!(records, _create_dataset!(f, model, d, entry))
        end
        for t in entry.tables
            _create_table!(f, t)
        end
    end
    return records
end

# Create the file and close it again when populating fails.
function _create_h5(path::String, m::OutputsMetadata, axis_data)
    f = HDF5.h5open(path, "w")
    try
        return f, _populate!(f, m, axis_data)
    catch
        try
            close(f)
        catch
        end
        rethrow()
    end
end

function _check_fresh(dir::AbstractString)
    for name in ("outputs.json", "outputs.h5")
        path = joinpath(dir, name)
        if ispath(path)
            throw(ArgumentError("outputs file $path already exists"))
        end
    end
    return
end

"""
    open_outputs_writer(dir, m; axis_data) -> OutputsWriter

Validate `m`, create `dir`, write `outputs.json` with status `RUNNING`, and create
`outputs.h5` with every axis, dataset, and table of `m`. `axis_data` is keyed by
`(model, axis_key)`. Throw `ArgumentError` when `dir` already holds `outputs.json` or
`outputs.h5`.
"""
function open_outputs_writer(
    dir::AbstractString,
    m::OutputsMetadata;
    axis_data::Dict{Tuple{String, String}, AxisData},
)
    validate_metadata(m)
    _check_axis_set(m, axis_data)
    _check_fresh(dir)
    mkpath(dir)
    json_path = joinpath(dir, "outputs.json")
    h5_path = joinpath(dir, "outputs.h5")
    try
        running = with_status(m, string(Simulation.RunStatus.RUNNING))
        write_outputs_metadata(json_path, running)
        f, records = _create_h5(h5_path, m, axis_data)
        return OutputsWriter(String(dir), running, f, records)
    catch
        rm(h5_path; force = true)
        rm(json_path; force = true)
        rethrow()
    end
end

function _check_running(w::OutputsWriter)
    if w.metadata.status != string(Simulation.RunStatus.RUNNING) || !isopen(w.file)
        throw(ArgumentError("outputs writer for $(w.dir) is not running"))
    end
    return
end

function _record(
    w::OutputsWriter,
    model::AbstractString,
    key::Tuple{String, String, String},
)
    k = (String(model), key...)
    if !haskey(w.datasets, k)
        throw(ArgumentError("model $model: no dataset $key"))
    end
    return w.datasets[k]
end

function _convert_values(::Type{T}, values::AbstractArray) where {T}
    return T.(values)
end

_convert_values(::Type{T}, values::Array{T}) where {T} = values

function _slice_index(i::Int, exec_dim::Int, execution_index::Int)
    if i == exec_dim
        return execution_index
    end
    return Colon()
end

"""
    append!(w, model, key, values, execution_index)

Write `values` (Julia order, every axis except `execution`) into slice `execution_index`
of the dataset `key = (entry_type, component_type, meta)`.
"""
function Base.append!(
    w::OutputsWriter,
    model::AbstractString,
    key::Tuple{String, String, String},
    values::AbstractArray,
    execution_index::Int,
)
    _check_running(w)
    r = _record(w, model, key)
    if iszero(r.exec_dim)
        throw(ArgumentError("model $model: dataset $key has no execution axis"))
    end
    count = size(r.dataset, r.exec_dim)
    if !(1 <= execution_index <= count)
        throw(
            ArgumentError(
                "model $model: dataset $key execution_index $execution_index is outside 1:$count",
            ),
        )
    end
    _check_values_size(model, key, values, r.expected)
    idx = ntuple(
        i -> _slice_index(i, r.exec_dim, execution_index),
        ndims(r.dataset),
    )
    r.dataset[idx...] = _convert_values(r.storage, values)
    return
end

"""
    write_values!(w, model, key, values)

Write the whole dataset `key`. The size of `values` must equal the dataset size.
"""
function write_values!(
    w::OutputsWriter,
    model::AbstractString,
    key::Tuple{String, String, String},
    values::AbstractArray,
)
    _check_running(w)
    r = _record(w, model, key)
    _check_values_size(model, key, values, size(r.dataset))
    r.dataset[axes(values)...] = _convert_values(r.storage, values)
    return
end

"""
    write_table!(w, model, table_name, columns::NamedTuple)

Write one vector per column of the table. Every vector has the table `length`.
"""
function write_table!(
    w::OutputsWriter,
    model::AbstractString,
    table_name::AbstractString,
    columns::NamedTuple,
)
    _check_running(w)
    t = _find_table(w.metadata, model, table_name)
    if Set(keys(columns)) != Set(Symbol(c.name) for c in t.columns)
        throw(
            ArgumentError(
                "model $model: table $table_name columns $(collect(keys(columns))) differ from the metadata",
            ),
        )
    end
    for c in t.columns
        v = columns[Symbol(c.name)]
        if length(v) != t.length
            throw(
                ArgumentError(
                    "model $model: table $table_name column $(c.name) has length $(length(v)), expected $(t.length)",
                ),
            )
        end
        w.file[string(t.group, "/", c.name)][:] =
            _convert_values(_column_storage_type(c.dtype), v)
    end
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

"""
    finalize!(w; status)

Close the HDF5 file, then rewrite `outputs.json` with `status` and the current time.
`status` is `SUCCESSFULLY_FINALIZED` or `FAILED`. The writer must have status `RUNNING`.
When the JSON write fails, the writer keeps status `RUNNING` and `finalize!` can run again.
"""
function finalize!(w::OutputsWriter; status::Simulation.RunStatus.Value)
    if w.metadata.status != string(Simulation.RunStatus.RUNNING)
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
    for r in values(w.datasets)
        close(r.dataset)
    end
    if isopen(w.file)
        close(w.file)
    end
    stamp = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"
    m = with_status(w.metadata, string(status); created_at = stamp)
    write_outputs_metadata(joinpath(w.dir, "outputs.json"), m)
    w.metadata = m
    return
end

function _check_systems(m::OutputsMetadata, systems::AbstractDict)
    for uuid in keys(systems)
        if !haskey(m.systems, uuid)
            throw(ArgumentError("system $uuid is not in the metadata systems"))
        end
        name = m.systems[uuid]
        if isempty(name) || name in (".", "..") || isabspath(name) ||
           occursin('/', name) || occursin('\\', name)
            throw(
                ArgumentError(
                    "system $uuid has bundle directory \"$name\", expected a plain relative name",
                ),
            )
        end
    end
    return
end

# Mark the run FAILED when possible and always close the file. Never throws.
function _abort!(w::OutputsWriter)
    if w.metadata.status == string(Simulation.RunStatus.RUNNING)
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
    write_outputs(dir, m; axis_data, values, tables, systems)

One-shot writer. `values` is keyed by `(model, entry_type, component_type, meta)` and
`tables` by `(model, table_name)`. `systems` maps a system uuid to an object that
implements `write_system_bundle(obj, dir)`.
"""
function write_outputs(
    dir::AbstractString,
    m::OutputsMetadata;
    axis_data::Dict{Tuple{String, String}, AxisData},
    values::AbstractDict,
    tables::AbstractDict,
    systems::AbstractDict = Dict{String, Any}(),
)
    _check_systems(m, systems)
    w = open_outputs_writer(dir, m; axis_data = axis_data)
    try
        for ((model, entry_type, component_type, meta), v) in values
            write_values!(w, model, (entry_type, component_type, meta), v)
        end
        for ((model, table), cols) in tables
            write_table!(w, model, table, cols)
        end
        for (uuid, obj) in systems
            bundle = joinpath(dir, m.systems[uuid])
            mkpath(bundle)
            write_system_bundle(obj, bundle)
        end
        finalize!(w; status = Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    catch
        _abort!(w)
        rethrow()
    end
    return
end
