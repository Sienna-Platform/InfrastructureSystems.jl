# Tests `src/outputs/hdf5_writer.jl`

import HDF5

const _SINGLE_JSON = outputs_fixture("single")
const _KEY = ("ActivePowerVariable", "ThermalStandard", "")

# The fixture holds one execution. The writer tests need several.
function _single_meta()
    m = IS.read_outputs_document(_SINGLE_JSON)
    entry = outputs_model(m, "model")
    set_outputs_axis!(
        entry, "execution", _with(outputs_axis(entry, "execution"); count = 7),
    )
    entry.tables[1] = _with(entry.tables[1]; length = 7)
    return m
end

function _fake_axis_data(ax::InfrastructureOutputSchemas.ComponentAxis)
    n = IS.axis_length(ax)
    nc = length(ax.columns)
    ids = repeat(collect(Int64, 1:n)', nc, 1)
    labels = [string("name_", i) for _ in 1:nc, i in 1:n]
    return IS.AxisData(ids, labels, DateTime[])
end

function _fake_axis_data(ax::InfrastructureOutputSchemas.ExecutionAxis)
    ts = [
        DateTime(ax.initial_timestamp) + (i - 1) * IS.get_interval(ax) for
        i in 1:(ax.count)
    ]
    return IS.AxisData(ts)
end

function _fake_axis_data(ax::InfrastructureOutputSchemas.TimeAxis)
    ts = [
        DateTime(ax.initial_timestamp) + (i - 1) * IS.get_resolution(ax) for
        i in 1:(ax.length)
    ]
    return IS.AxisData(ts)
end

function _add_fake_axis!(
    d,
    model,
    key,
    ax::Union{
        InfrastructureOutputSchemas.ComponentAxis,
        InfrastructureOutputSchemas.ExecutionAxis,
        InfrastructureOutputSchemas.TimeAxis,
    },
)
    d[(model, key)] = _fake_axis_data(ax)
    return
end

function _add_fake_axis!(
    d,
    model,
    key,
    ::Union{InfrastructureOutputSchemas.HorizonAxis, InfrastructureOutputSchemas.LabelAxis},
)
    return
end

function simulation_axis_data(m)
    d = Dict{Tuple{String, String}, IS.AxisData}()
    for model in m.models, ax in model.axes
        _add_fake_axis!(d, model.name, IS.axis_name(ax), ax.value)
    end
    return d
end

struct _MockSystem end
function IS.write_system_bundle(::_MockSystem, dir::AbstractString)
    write(joinpath(dir, "marker.txt"), "x")
    return
end

_dtype_zero(::Val{:f64}) = 0.0
_dtype_zero(::Val{:f32}) = 0.0
_dtype_zero(::Val{:i64}) = 0
_dtype_zero(::Val{:i32}) = 0
_dtype_zero(::Val{:bool}) = false

# Zero values for every dataset of `m`, in the form `write_outputs` takes.
function _all_values(m)
    vals = Dict()
    for entry in m.models, d in entry.datasets
        model = entry.name
        dims = Tuple(reverse([IS.axis_length(outputs_axis(entry, a)) for a in d.axes]))
        vals[(model, IS.dataset_key(d)...)] =
            fill(_dtype_zero(Val(Symbol(string(d.dtype)))), dims)
    end
    return vals
end

_column_fill(c::InfrastructureOutputSchemas.Column, n) =
    _column_fill(Val(Symbol(string(c.dtype))), n)
_column_fill(::Val{:str}, n) = fill("x", n)
_column_fill(::Val{:f64}, n) = zeros(n)
_column_fill(::Val{:i64}, n) = ones(Int64, n)
_column_fill(::Val{:bool}, n) = falses(n)

# Placeholder columns for every table of `m`.
function _all_tables(m)
    tables = Dict()
    for entry in m.models, t in IS._model_tables(entry)
        tables[(entry.name, t.name)] = NamedTuple{Tuple(Symbol(c.name) for c in t.columns)}(
            Tuple(_column_fill(c, t.length) for c in t.columns),
        )
    end
    return tables
end

# A bundle writer object for every system of `m`.
_bundle_systems(m) = Dict(uuid => _MockSystem() for uuid in keys(IS._systems(m)))

@testset "outputs writer: one-shot write then raw read with HDF5" begin
    m = _single_meta()
    dir = mktempdir()
    vals = rand(48, 76, 7)
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m),
        values = merge(_all_values(m), Dict(("model", _KEY...) => vals)),
        tables = _all_tables(m), systems = _bundle_systems(m))
    @test isfile(joinpath(dir, "outputs.json")) && isfile(joinpath(dir, "outputs.h5"))
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        ds = f["/model/datasets/ActivePowerVariable__ThermalStandard"]
        @test size(ds) == (48, 76, 7)
        @test HDF5.get_chunk(ds) == (48, 76, 1)
        @test read(ds) == vals
        @test size(f["/model/axes/ThermalStandard/labels"]) == (1, 76)
        @test size(f["/model/axes/VariableReserve__ThermalStandard/labels"]) == (2, 152)
        @test size(f["/model/axes/VariableReserve__ThermalStandard/ids"]) == (2, 152)
        @test length(f["/model/axes/execution/timestamps"]) == 7
    end
    m2 = IS.read_outputs_document(joinpath(dir, "outputs.json"))
    @test string(m2.status) == "SUCCESSFULLY_FINALIZED"
end

@testset "outputs writer: incremental append, unwritten reads NaN" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) ==
          "RUNNING"
    IS.write_execution!(w, "model", _KEY, fill(2.0, 48, 76), 3)
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        a = read(f["/model/datasets/ActivePowerVariable__ThermalStandard"])
        @test all(a[:, :, 3] .== 2.0)
        @test all(isnan, a[:, :, 1])
    end
end

@testset "outputs writer: append bounds" begin
    m = _single_meta()
    w = IS.open_outputs_writer(mktempdir(), m; axis_data = simulation_axis_data(m))
    @test_throws ArgumentError IS.write_execution!(w, "model", _KEY, fill(1.0, 48, 76), 8)
    @test_throws ArgumentError IS.write_execution!(w, "model", _KEY, fill(1.0, 47, 76), 1)
    @test_throws ArgumentError IS.write_execution!(
        w, "model", ("Nope", "ThermalStandard", ""), fill(1.0, 48, 76), 1)
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
    @test_throws ArgumentError IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
end

@testset "outputs writer: axis data shape is checked before any write" begin
    m = _single_meta()
    ad = simulation_axis_data(m)
    ad[("model", "ThermalStandard")] =
        IS.AxisData(zeros(Int64, 1, 75), fill("x", 1, 75), DateTime[])
    dir = mktempdir()
    @test_throws ArgumentError IS.open_outputs_writer(dir, m; axis_data = ad)
    @test !isfile(joinpath(dir, "outputs.h5"))
end

@testset "outputs writer: tables write one dataset per column" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    IS.write_table!(w, "model", "optimizer_stats",
        (execution = collect(1:7), objective_value = rand(7),
            termination_status = fill(1, 7), solve_time = rand(7)))
    @test_throws ArgumentError IS.write_table!(w, "model", "optimizer_stats",
        (execution = collect(1:6), objective_value = rand(6),
            termination_status = fill(1, 6), solve_time = rand(6)))
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        @test length(read(f["/model/tables/optimizer_stats/objective_value"])) == 7
    end
end

@testset "outputs writer: epoch ms and bundle hook" begin
    @test IS.timestamps_epoch_ms([DateTime(1970, 1, 1, 0, 0, 1)]) == [1000]
    @test_throws ArgumentError IS.write_system_bundle(1, mktempdir())
end

@testset "outputs writer: axis data names are exact" begin
    m = _single_meta()
    ad = simulation_axis_data(m)
    ad[("model", "horizon")] =
        _fake_axis_data(outputs_axis(outputs_model(m, "model"), "execution"))
    @test_throws ArgumentError IS.open_outputs_writer(mktempdir(), m; axis_data = ad)
    ad = simulation_axis_data(m)
    ad[("model", "nope")] =
        _fake_axis_data(outputs_axis(outputs_model(m, "model"), "execution"))
    @test_throws ArgumentError IS.open_outputs_writer(mktempdir(), m; axis_data = ad)
    ad = simulation_axis_data(m)
    delete!(ad, ("model", "execution"))
    @test_throws ArgumentError IS.open_outputs_writer(mktempdir(), m; axis_data = ad)
end

function _with_dataset(m, f)
    m2 = deepcopy(m)
    entry = outputs_model(m2, "model")
    entry.datasets[1] = f(entry.datasets[1])
    return m2
end

@testset "outputs writer: bad layout fails before any file exists" begin
    m = _single_meta()
    ad = simulation_axis_data(m)
    d0 = outputs_model(m, "model").datasets[1]
    mk(; dtype = d0.dtype, fill_value = d0.fill_value, filters = d0.layout.filters) =
        _with_dataset(
            m,
            d -> _with(
                d;
                dtype = dtype,
                fill_value = fill_value,
                layout = InfrastructureOutputSchemas.DatasetLayout(;
                    chunks = d.layout.chunks, filters = filters,
                ),
            ),
        )
    for bad in (
        mk(; fill_value = 1.5, dtype = InfrastructureOutputSchemas.Dtype("i64")),
        mk(; filters = ["lz4"]),
        mk(; filters = ["deflate:0"]),
        mk(; filters = ["deflate:10"]),
        mk(; filters = ["deflate:x"]),
    )
        dir = joinpath(mktempdir(), "out")
        @test_throws InfrastructureOutputSchemas.SchemaValidationError IS.open_outputs_writer(
            dir, bad; axis_data = ad)
        @test !ispath(dir)
    end
    @test_throws r"/fill_value: type" IS.open_outputs_writer(
        mktempdir(),
        mk(; fill_value = 1.5, dtype = InfrastructureOutputSchemas.Dtype("i64"));
        axis_data = ad)
end

@testset "outputs writer: axis timestamps follow the declared step" begin
    sim = IS.read_outputs_document(outputs_fixture("simulation"))
    for (m, model, key, i, expected) in (
        (_single_meta(), "model", "execution", 3, DateTime(2024, 1, 3)),
        (sim, "EM", "time", 2, DateTime(2024, 1, 1, 0, 5)),
    )
        ad = simulation_axis_data(m)
        ts = copy(ad[(model, key)].timestamps)
        @test ts[i] == expected
        ts[i] += Minute(1)
        ad[(model, key)] = IS.AxisData(ts)
        dir = joinpath(mktempdir(), "out")
        @test_throws ArgumentError IS.open_outputs_writer(dir, m; axis_data = ad)
        @test_throws Regex(
            "model $model: axis \"$key\" timestamp $i is $(ts[i]), expected $expected",
        ) IS.open_outputs_writer(dir, m; axis_data = ad)
        @test !ispath(dir)
        w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
        IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
        @test isfile(joinpath(dir, "outputs.h5"))
    end
end

@testset "outputs writer: a zero-length component axis keeps its ids" begin
    m = _single_meta()
    entry = outputs_model(m, "model")
    set_outputs_axis!(
        entry, "ThermalStandard", _with(outputs_axis(entry, "ThermalStandard"); length = 0),
    )
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m), values = _all_values(m),
        tables = _all_tables(m), systems = _bundle_systems(m))
    a = IS.open_outputs_reader(dir)
    @test size(IS.read_axis_data(a, "model", "ThermalStandard").ids) == (1, 0)
    @test size(IS.read_axis_data(a, "model", "ThermalStandard").labels) == (1, 0)
end

struct _FailingSystem end
function IS.write_system_bundle(::_FailingSystem, ::AbstractString)
    error("bundle boom")
end

@testset "outputs writer: systems path" begin
    m = _single_meta()
    ad = simulation_axis_data(m)
    uuid, name = first(IS._systems(m))
    vals = merge(_all_values(m), Dict(("model", _KEY...) => rand(48, 76, 7)))
    tbls = _all_tables(m)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, values = vals, tables = tbls,
        systems = Dict(uuid => _MockSystem()))
    @test read(joinpath(dir, name, "marker.txt"), String) == "x"

    # a failing bundle writer: original error surfaces, run marked FAILED, file closed
    dir = mktempdir()
    @test_throws "bundle boom" IS.write_outputs(dir, m; axis_data = ad, values = vals,
        tables = tbls, systems = Dict(uuid => _FailingSystem()))
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) == "FAILED"
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        @test haskey(f, "/model/datasets")
    end

    # bad uuid fails before any file exists
    dir = joinpath(mktempdir(), "out")
    @test_throws ArgumentError IS.write_outputs(dir, m; axis_data = ad, values = vals,
        tables = tbls, systems = Dict("no-such-uuid" => _MockSystem()))
    @test !ispath(dir)

    # bundle directory must be a plain relative name
    for bad in ("../x", "/abs", "a/b", "..", "")
        m2 = deepcopy(m)
        IS._systems(m2)[uuid] = bad
        dir = joinpath(mktempdir(), "out")
        @test_throws InfrastructureOutputSchemas.SchemaValidationError IS.write_outputs(
            dir, m2; axis_data = ad,
            values = vals, tables = tbls, systems = Dict(uuid => _MockSystem()))
        @test !ispath(dir)
    end
end

@testset "outputs writer: appended values are readable before finalize" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    IS.write_execution!(w, "model", _KEY, fill(4.0, 48, 76), 2)
    flush(w)
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        a = read(f["/model/datasets/ActivePowerVariable__ThermalStandard"])
        @test all(a[:, :, 2] .== 4.0)
    end
    IS.write_table!(w, "model", "optimizer_stats",
        (execution = collect(1:7), objective_value = fill(2.5, 7),
            termination_status = fill(1, 7), solve_time = rand(7)))
    flush(w)
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        @test all(read(f["/model/tables/optimizer_stats/objective_value"]) .== 2.5)
    end
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
end

@testset "outputs writer: finalize! accepts only terminal statuses" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    @test_throws ArgumentError IS.finalize!(w; status = IS.Simulation.RunStatus.RUNNING)
    @test_throws ArgumentError IS.finalize!(
        w; status = IS.Simulation.RunStatus.INITIALIZED)
    @test string(w.document.status) == "RUNNING"
    for (k, v) in _all_values(m)
        IS.write_values!(w, k[1], k[2:end], v)
    end
    for ((model, name), cols) in _all_tables(m)
        IS.write_table!(w, model, name, cols)
    end
    for name in values(IS._systems(m))
        mkpath(joinpath(dir, name))
    end
    IS.finalize!(w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) ==
          "SUCCESSFULLY_FINALIZED"
end

@testset "outputs writer: refuses a directory that holds outputs files" begin
    m = _single_meta()
    ad = simulation_axis_data(m)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, values = _all_values(m),
        tables = _all_tables(m), systems = _bundle_systems(m))
    @test_throws ArgumentError IS.open_outputs_writer(dir, m; axis_data = ad)
    @test_throws joinpath(dir, "outputs.json") IS.open_outputs_writer(
        dir, m; axis_data = ad)
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) ==
          "SUCCESSFULLY_FINALIZED"
    rm(joinpath(dir, "outputs.json"))
    @test_throws ArgumentError IS.open_outputs_writer(dir, m; axis_data = ad)
    @test_throws joinpath(dir, "outputs.h5") IS.open_outputs_writer(
        dir, m; axis_data = ad)
    @test_throws ArgumentError IS.write_outputs(
        dir, m; axis_data = ad, values = Dict(), tables = Dict())
end

@testset "outputs writer: a failed JSON write leaves the writer finalizable" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    for (k, v) in _all_values(m)
        IS.write_values!(w, k[1], k[2:end], v)
    end
    for ((model, name), cols) in _all_tables(m)
        IS.write_table!(w, model, name, cols)
    end
    for name in values(IS._systems(m))
        mkpath(joinpath(dir, name))
    end
    json = joinpath(dir, "outputs.json")
    if !Sys.iswindows() && !iszero(Libc.getuid())
        before = read(json, String)
        inode = stat(json).inode
        # A read-only directory makes the temporary file fail.
        chmod(dir, 0o555)
        @test_throws SystemError IS.finalize!(
            w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
        chmod(dir, 0o755)
        @test read(json, String) == before
        @test sort!(readdir(dir)) == sort!(
            ["outputs.h5", "outputs.json", collect(values(IS._systems(m)))...],
        )
        @test string(IS.read_outputs_document(json).status) == "RUNNING"
        @test string(w.document.status) == "RUNNING"
        @test_throws ArgumentError IS.write_execution!(
            w,
            "model",
            _KEY,
            fill(1.0, 48, 76),
            1,
        )
        IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
        @test string(IS.read_outputs_document(json).status) == "FAILED"
        @test string(w.document.status) == "FAILED"
        @test !isopen(w.file)
        # The manifest is replaced, not rewritten in place.
        @test stat(json).inode != inode
    else
        IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
        @test string(IS.read_outputs_document(json).status) == "FAILED"
    end
end

@testset "outputs writer: SUCCESSFULLY_FINALIZED needs every dataset and table" begin
    m = _single_meta()
    ad = simulation_axis_data(m)
    success = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = ad)
    @test_throws ArgumentError IS.finalize!(w; status = success)
    @test_throws "never written" IS.finalize!(w; status = success)
    @test_throws "table optimizer_stats was never written" IS.finalize!(
        w; status = success)
    @test string(w.document.status) == "RUNNING" && isopen(w.file)
    # a failed attempt leaves the writer usable
    for (k, v) in _all_values(m)
        if k[2:end] != _KEY
            IS.write_values!(w, k[1], k[2:end], v)
        end
    end
    for ((model, name), cols) in _all_tables(m)
        IS.write_table!(w, model, name, cols)
    end
    # a dataset with an execution that was never written
    for i in 1:6
        IS.write_execution!(w, "model", _KEY, fill(1.0, 48, 76), i)
    end
    @test_throws "dataset ActivePowerVariable__ThermalStandard lacks executions [7]" IS.finalize!(
        w; status = success)
    IS.write_execution!(w, "model", _KEY, fill(1.0, 48, 76), 7)
    @test_throws "bundle directory" IS.finalize!(w; status = success)
    @test string(w.document.status) == "RUNNING" && isopen(w.file)
    for name in values(IS._systems(m))
        mkpath(joinpath(dir, name))
    end
    IS.finalize!(w; status = success)
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) ==
          "SUCCESSFULLY_FINALIZED"
end

@testset "outputs writer: FAILED is allowed at any point" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) == "FAILED"
end

@testset "outputs writer: write_outputs with a missing dataset fails the run" begin
    m = _single_meta()
    dir = mktempdir()
    @test_throws "never written" IS.write_outputs(dir, m;
        axis_data = simulation_axis_data(m), values = Dict(), tables = Dict())
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) == "FAILED"
end

@testset "outputs writer: abort! marks FAILED and closes the file" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    @test IS.abort!(w) === nothing
    @test !isopen(w.file)
    @test string(IS.read_outputs_document(joinpath(dir, "outputs.json")).status) == "FAILED"
    @test IS.OUTPUTS_SCHEMA_VERSION == "0.1.0"
end
