"""
Handle of an outputs directory. The HDF5 file is opened for each read, never held.
Use `open_outputs` to create one.
"""
struct OutputArtifact
    dir::String
    metadata::OutputsMetadata
end

"""
    open_outputs(dir) -> OutputArtifact

Read and validate `outputs.json` in `dir`. Check that `outputs.h5` and the bundle directory
of every declared system exist. Warn when the status is `RUNNING`: the run is in progress or
ended without a final status, and datasets can be partly written.
"""
function open_outputs(dir::AbstractString)
    json = joinpath(dir, "outputs.json")
    if !isfile(json)
        throw(ArgumentError("outputs directory $dir has no outputs.json"))
    end
    m = read_outputs_metadata(json)
    validate_metadata(m)
    if !isfile(joinpath(dir, "outputs.h5"))
        throw(ArgumentError("outputs directory $dir has no outputs.h5"))
    end
    for (uuid, name) in m.systems
        if !isdir(joinpath(dir, name))
            throw(
                ArgumentError(
                    "outputs directory $dir has no bundle directory \"$name\" for system $uuid",
                ),
            )
        end
    end
    if m.status == string(Simulation.RunStatus.RUNNING)
        @warn "Outputs in $dir have status RUNNING: the run is not finished or ended without a final status. Datasets can be partly written."
    end
    return OutputArtifact(String(dir), m)
end

"Return the `OutputsMetadata` of the artifact."
get_metadata(a::OutputArtifact) = a.metadata

"Return the sorted model names of the artifact."
list_models(a::OutputArtifact) = sort!(collect(keys(a.metadata.models)))

"Return `(entry_type, component_type, meta)` of every dataset of `model`."
function list_datasets(a::OutputArtifact, model::AbstractString)
    return Tuple{String, String, String}[
        dataset_key(d) for d in _model_entry(a.metadata, model).datasets
    ]
end

"Return the table names of `model`."
function list_tables(a::OutputArtifact, model::AbstractString)
    return String[t.name for t in _model_entry(a.metadata, model).tables]
end

"Return the axis `key` of `model`."
function get_axis(a::OutputArtifact, model::AbstractString, key::AbstractString)
    entry = _model_entry(a.metadata, model)
    if !haskey(entry.axes, key)
        throw(ArgumentError("model $model: no axis \"$key\""))
    end
    return entry.axes[key]
end

_h5_path(a::OutputArtifact) = joinpath(a.dir, "outputs.h5")

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
    model::AbstractString,
    key::AbstractString,
    ax::ComponentAxis,
)
    g = f[ax.group]
    ids = zeros(Int64, 0, 0)
    if haskey(g, "ids")
        ids = read(g["ids"])
    elseif all(c -> c.has_ids, ax.columns)
        throw(ArgumentError("model $model: axis $key has id columns but no ids dataset"))
    end
    return AxisData(ids, read(g["labels"]), Dates.DateTime[])
end

function _read_axis_data(
    f::HDF5.File,
    ::AbstractString,
    ::AbstractString,
    ax::Union{TimeAxis, ExecutionAxis},
)
    ts = [
        Dates.DateTime(1970) + Dates.Millisecond(ms) for
        ms in read(f[ax.group]["timestamps"])
    ]
    return AxisData(ts)
end

"Return the `AxisData` stored for axis `key` of `model`."
function read_axis_data(a::OutputArtifact, model::AbstractString, key::AbstractString)
    ax = get_axis(a, model, key)
    return HDF5.h5open(_h5_path(a), "r") do f
        return _read_axis_data(f, model, key, ax)
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

# Design check 4: the stored shape and element type match the metadata.
function _check_stored(model, key, d::OutputDataset, ds::HDF5.Dataset, expected::Tuple)
    if size(ds) != expected
        throw(
            ArgumentError(
                "model $model: dataset $key is stored with size $(size(ds)), the metadata expects $expected",
            ),
        )
    end
    storage = _DTYPES[d.dtype][1]
    if eltype(ds) != storage
        throw(
            ArgumentError(
                "model $model: dataset $key is stored as $(eltype(ds)), the metadata dtype $(d.dtype) expects $storage",
            ),
        )
    end
    return
end

"""
    read_dataset(a, model, entry_type, component_type; meta = "", execution = Colon())
        -> (array, axis_keys)

Read one dataset in Julia order (the reverse of the metadata `axes`). `axis_keys` lists
the axes in the same order. `execution` (`Colon`, `Int`, or `UnitRange`) selects along the
execution axis only. An `Int` removes that axis from the result. Bool datasets return `Bool`.
"""
function read_dataset(
    a::OutputArtifact,
    model::AbstractString,
    entry_type::AbstractString,
    component_type::AbstractString;
    meta::AbstractString = "",
    execution = Colon(),
)
    key = (String(entry_type), String(component_type), String(meta))
    d = _find_dataset(a.metadata, model, key)
    keys_julia = reverse(d.axes)
    idx = Any[Colon() for _ in keys_julia]
    keep = trues(length(keys_julia))
    pos = findfirst(==("execution"), keys_julia)
    if isnothing(pos)
        if execution != Colon()
            throw(ArgumentError("model $model: dataset $key has no execution axis"))
        end
    else
        idx[pos], keep[pos] =
            _execution_selection(
                execution,
                axis_length(_model_entry(a.metadata, model).axes["execution"]),
            )
    end
    expected = Tuple(
        reverse([axis_length(_model_entry(a.metadata, model).axes[k]) for k in d.axes]),
    )
    arr = HDF5.h5open(_h5_path(a), "r") do f
        ds = f[d.path]
        _check_stored(model, key, d, ds, expected)
        return ds[idx...]
    end
    return _decode(d.dtype, arr), keys_julia[keep]
end

"Return the columns of table `name` of `model` as a `NamedTuple` of vectors."
function read_table(a::OutputArtifact, model::AbstractString, name::AbstractString)
    t = _find_table(a.metadata, model, name)
    cols = HDF5.h5open(_h5_path(a), "r") do f
        return [read(f[string(t.group, "/", c.name)]) for c in t.columns]
    end
    return NamedTuple{Tuple(Symbol(c.name) for c in t.columns)}(
        Tuple(_decode(c.dtype, v) for (c, v) in zip(t.columns, cols)),
    )
end
