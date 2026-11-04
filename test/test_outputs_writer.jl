# Tests `src/outputs/hdf5_writer.jl`

import HDF5

const _SINGLE_JSON = joinpath(DATA_DIR, "outputs", "single", "outputs.json")
const _KEY = ("ActivePowerVariable", "ThermalStandard", "")

function _fake_axis_data(ax::IS.ComponentAxis)
    n = IS.axis_length(ax)
    nc = length(ax.columns)
    ids = repeat(collect(Int64, 1:n)', nc, 1)
    labels = [string("name_", i) for _ in 1:nc, i in 1:n]
    return IS.AxisData(ids, labels, DateTime[])
end

function _fake_axis_data(ax::IS.ExecutionAxis)
    ts = [ax.initial_timestamp + Day(i - 1) for i in 1:(ax.count)]
    return IS.AxisData(ts)
end

function _fake_axis_data(ax::IS.TimeAxis)
    ts = [ax.initial_timestamp + Hour(i - 1) for i in 1:(ax.length)]
    return IS.AxisData(ts)
end

function _add_fake_axis!(
    d,
    model,
    key,
    ax::Union{IS.ComponentAxis, IS.ExecutionAxis, IS.TimeAxis},
)
    d[(model, key)] = _fake_axis_data(ax)
    return
end

_add_fake_axis!(d, model, key, ::Union{IS.HorizonAxis, IS.LabelAxis}) = nothing

function simulation_axis_data(m)
    d = Dict{Tuple{String, String}, IS.AxisData}()
    for (model_name, model) in m.models, (key, ax) in model.axes
        _add_fake_axis!(d, model_name, key, ax)
    end
    return d
end

@testset "outputs writer: one-shot write then raw read with HDF5" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    vals = rand(48, 76, 7)
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m),
        values = Dict(("model", _KEY...) => vals), tables = Dict())
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
    m2 = IS.read_outputs_metadata(joinpath(dir, "outputs.json"))
    @test m2.status == "SUCCESSFULLY_FINALIZED"
end

@testset "outputs writer: incremental append, unwritten reads NaN" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    @test IS.read_outputs_metadata(joinpath(dir, "outputs.json")).status == "RUNNING"
    IS.append!(w, "model", _KEY, fill(2.0, 48, 76), 3)
    IS.finalize!(w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        a = read(f["/model/datasets/ActivePowerVariable__ThermalStandard"])
        @test all(a[:, :, 3] .== 2.0)
        @test all(isnan, a[:, :, 1])
    end
end

@testset "outputs writer: append bounds" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    w = IS.open_outputs_writer(mktempdir(), m; axis_data = simulation_axis_data(m))
    @test_throws ArgumentError IS.append!(w, "model", _KEY, fill(1.0, 48, 76), 8)
    @test_throws ArgumentError IS.append!(w, "model", _KEY, fill(1.0, 47, 76), 1)
    @test_throws ArgumentError IS.append!(
        w, "model", ("Nope", "ThermalStandard", ""), fill(1.0, 48, 76), 1)
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
    @test_throws ArgumentError IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
end

@testset "outputs writer: axis data shape is checked before any write" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    ad = simulation_axis_data(m)
    ad[("model", "ThermalStandard")] =
        IS.AxisData(zeros(Int64, 1, 75), fill("x", 1, 75), DateTime[])
    dir = mktempdir()
    @test_throws ArgumentError IS.open_outputs_writer(dir, m; axis_data = ad)
    @test !isfile(joinpath(dir, "outputs.h5"))
end

@testset "outputs writer: tables write one dataset per column" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    IS.write_table!(w, "model", "optimizer_stats",
        (execution = collect(1:7), objective_value = rand(7),
            termination_status = fill(1, 7), solve_time = rand(7)))
    @test_throws ArgumentError IS.write_table!(w, "model", "optimizer_stats",
        (execution = collect(1:6), objective_value = rand(6),
            termination_status = fill(1, 6), solve_time = rand(6)))
    IS.finalize!(w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        @test length(read(f["/model/tables/optimizer_stats/objective_value"])) == 7
    end
end

@testset "outputs writer: epoch ms and bundle hook" begin
    @test IS.timestamps_epoch_ms([DateTime(1970, 1, 1, 0, 0, 1)]) == [1000]
    @test_throws ArgumentError IS.write_system_bundle(1, mktempdir())
end

@testset "outputs writer: axis data keys are exact" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    ad = simulation_axis_data(m)
    ad[("model", "horizon")] = _fake_axis_data(m.models["model"].axes["execution"])
    @test_throws ArgumentError IS.open_outputs_writer(mktempdir(), m; axis_data = ad)
    ad = simulation_axis_data(m)
    ad[("model", "nope")] = _fake_axis_data(m.models["model"].axes["execution"])
    @test_throws ArgumentError IS.open_outputs_writer(mktempdir(), m; axis_data = ad)
    ad = simulation_axis_data(m)
    delete!(ad, ("model", "execution"))
    @test_throws ArgumentError IS.open_outputs_writer(mktempdir(), m; axis_data = ad)
end

function _with_dataset(m, f)
    m2 = deepcopy(m)
    d = m2.models["model"].datasets[1]
    m2.models["model"].datasets[1] = f(d)
    return m2
end

@testset "outputs writer: bad layout fails before any file exists" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    ad = simulation_axis_data(m)
    d0 = m.models["model"].datasets[1]
    mk(; dtype = d0.dtype, fill_value = d0.fill_value, filters = d0.layout.filters) =
        _with_dataset(
            m,
            d -> IS.OutputDataset(
                d.entry_type, d.meta, d.axes, dtype, fill_value, d.quantity_kind,
                d.unit_system, d.units, IS.DatasetLayout(d.layout.chunks, filters),
                d.path,
                d.container, d.component_type, d.base_reference),
        )
    for bad in (
        mk(; dtype = "f16"),
        mk(; fill_value = 1.5, dtype = "i64"),
        mk(; filters = ["lz4"]),
        mk(; filters = ["deflate:0"]),
        mk(; filters = ["deflate:10"]),
        mk(; filters = ["deflate:x"]),
    )
        dir = joinpath(mktempdir(), "out")
        @test_throws ArgumentError IS.open_outputs_writer(dir, bad; axis_data = ad)
        @test !ispath(dir)
    end
    err = try
        IS.open_outputs_writer(mktempdir(), mk(; fill_value = 1.5, dtype = "i64");
            axis_data = ad)
    catch e
        e
    end
    @test occursin("fill_value 1.5 is not valid for dtype i64", err.msg)
end

struct _MockSystem end
function IS.write_system_bundle(::_MockSystem, dir::AbstractString)
    write(joinpath(dir, "marker.txt"), "x")
    return
end

struct _FailingSystem end
function IS.write_system_bundle(::_FailingSystem, ::AbstractString)
    error("bundle boom")
end

@testset "outputs writer: systems path" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    ad = simulation_axis_data(m)
    uuid, name = first(m.systems)
    vals = Dict(("model", _KEY...) => rand(48, 76, 7))
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, values = vals, tables = Dict(),
        systems = Dict(uuid => _MockSystem()))
    @test read(joinpath(dir, name, "marker.txt"), String) == "x"

    # a failing bundle writer: original error surfaces, run marked FAILED, file closed
    dir = mktempdir()
    err = try
        IS.write_outputs(dir, m; axis_data = ad, values = vals, tables = Dict(),
            systems = Dict(uuid => _FailingSystem()))
    catch e
        e
    end
    @test occursin("bundle boom", sprint(showerror, err))
    @test IS.read_outputs_metadata(joinpath(dir, "outputs.json")).status == "FAILED"
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r") do f
        @test haskey(f, "/model/datasets")
    end

    # bad uuid fails before any file exists
    dir = joinpath(mktempdir(), "out")
    @test_throws ArgumentError IS.write_outputs(dir, m; axis_data = ad, values = vals,
        tables = Dict(), systems = Dict("no-such-uuid" => _MockSystem()))
    @test !ispath(dir)

    # bundle directory must be a plain relative name
    for bad in ("../x", "/abs", "a/b", "..", "")
        m2 = deepcopy(m)
        m2.systems[uuid] = bad
        dir = joinpath(mktempdir(), "out")
        @test_throws ArgumentError IS.write_outputs(dir, m2; axis_data = ad,
            values = vals, tables = Dict(), systems = Dict(uuid => _MockSystem()))
        @test !ispath(dir)
    end
end

@testset "outputs writer: appended values are readable before finalize" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    IS.append!(w, "model", _KEY, fill(4.0, 48, 76), 2)
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
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    @test_throws ArgumentError IS.finalize!(w; status = IS.Simulation.RunStatus.RUNNING)
    @test_throws ArgumentError IS.finalize!(
        w; status = IS.Simulation.RunStatus.INITIALIZED)
    @test w.metadata.status == "RUNNING"
    IS.finalize!(w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    @test IS.read_outputs_metadata(joinpath(dir, "outputs.json")).status ==
          "SUCCESSFULLY_FINALIZED"
end

@testset "outputs writer: refuses a directory that holds outputs files" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    ad = simulation_axis_data(m)
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = ad)
    IS.finalize!(w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
    err = try
        IS.open_outputs_writer(dir, m; axis_data = ad)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin(joinpath(dir, "outputs.json"), err.msg)
    @test IS.read_outputs_metadata(joinpath(dir, "outputs.json")).status ==
          "SUCCESSFULLY_FINALIZED"
    rm(joinpath(dir, "outputs.json"))
    err = try
        IS.open_outputs_writer(dir, m; axis_data = ad)
    catch e
        e
    end
    @test err isa ArgumentError && occursin(joinpath(dir, "outputs.h5"), err.msg)
    @test_throws ArgumentError IS.write_outputs(
        dir, m; axis_data = ad, values = Dict(), tables = Dict())
end

@testset "outputs writer: a failed JSON write leaves the writer finalizable" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    json = joinpath(dir, "outputs.json")
    if !Sys.iswindows() && !iszero(Libc.getuid())
        chmod(json, 0o444)
        @test_throws SystemError IS.finalize!(
            w; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)
        chmod(json, 0o644)
        @test IS.read_outputs_metadata(json).status == "RUNNING"
        @test w.metadata.status == "RUNNING"
        @test_throws ArgumentError IS.append!(w, "model", _KEY, fill(1.0, 48, 76), 1)
        IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
        @test IS.read_outputs_metadata(json).status == "FAILED"
        @test w.metadata.status == "FAILED"
        @test !isopen(w.file)
    else
        IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
        @test IS.read_outputs_metadata(json).status == "FAILED"
    end
end
