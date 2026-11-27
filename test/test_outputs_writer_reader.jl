# Tests `src/outputs/reader.jl`. Reuses helpers from test_outputs_writer.jl.

function _written_single_dir(vals = rand(48, 76, 7))
    m = _single_meta()
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m),
        systems = _bundle_systems(m),
        values = Dict(("model", _KEY...) => vals,
            ("model", "OnVariable", "ThermalStandard", "") => rand(48, 76, 7),
            ("model", "ActivePowerReserveVariable", "VariableReserve", "Reserve_Up") =>
                rand(48, 152, 7),
            ("model", "ProductionCostExpression", "ThermalStandard", "") =>
                rand(48, 76, 7)),
        tables = Dict(
            ("model", "optimizer_stats") => (
                execution = collect(Int64, 1:7), objective_value = rand(7),
                termination_status = ones(Int64, 7), solve_time = rand(7)),
        ))
    return dir
end

@testset "outputs reader: read back what the writer wrote" begin
    m = _single_meta()
    vals = rand(48, 76, 7)
    a = IS.open_outputs_reader(_written_single_dir(vals))
    @test IS.get_document(a).status == IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED
    @test IS.list_models(a) == ["model"]
    @test _KEY in IS.list_datasets(a, "model")
    @test IS.list_tables(a, "model") == ["optimizer_stats"]
    arr, axes = IS.read_dataset(a, "model", "ActivePowerVariable", "ThermalStandard")
    @test arr == vals
    @test axes == ["horizon", "ThermalStandard", "execution"]
    part, paxes = IS.read_dataset(a, "model", "ActivePowerVariable", "ThermalStandard";
        execution = 2:3)
    @test part == vals[:, :, 2:3]
    @test paxes == axes
    one, oaxes = IS.read_dataset(a, "model", "ActivePowerVariable", "ThermalStandard";
        execution = 4)
    @test one == vals[:, :, 4]
    @test oaxes == ["horizon", "ThermalStandard"]
    @test_throws ArgumentError IS.read_dataset(a, "model", "ActivePowerVariable",
        "ThermalStandard"; execution = 8)
    ad = IS.read_axis_data(a, "model", "ThermalStandard")
    @test size(ad.labels) == (1, 76)
    @test size(ad.ids) == (1, 76)
    ex = IS.read_axis_data(a, "model", "execution")
    @test ex.timestamps == IS.axis_timestamps(outputs_axis(m.models[1], "execution"))
    @test typeof(IS.get_axis(a, "model", "horizon")) === IS.HorizonAxis
    @test isempty(IS.read_axis_data(a, "model", "horizon").timestamps)
    tbl = IS.read_table(a, "model", "optimizer_stats")
    @test tbl.execution == 1:7
    @test length(tbl.objective_value) == 7
end

@testset "outputs reader: missing things" begin
    a = IS.open_outputs_reader(_written_single_dir())
    @test_throws ArgumentError IS.read_dataset(a, "model", "Nope", "ThermalStandard")
    @test_throws r"model.*Nope" IS.read_dataset(a, "model", "Nope", "ThermalStandard")
    @test_throws ArgumentError IS.read_dataset(a, "ZZ", "ActivePowerVariable",
        "ThermalStandard")
    @test_throws ArgumentError IS.read_table(a, "model", "nope")
    @test_throws ArgumentError IS.get_axis(a, "model", "nope")
    @test_throws ArgumentError IS.list_datasets(a, "ZZ")
end

@testset "outputs reader: open_outputs_reader validates the directory" begin
    dir = mktempdir()
    cp(_SINGLE_JSON, joinpath(dir, "outputs.json"))
    @test_throws ArgumentError IS.open_outputs_reader(dir)
    @test_throws ArgumentError IS.open_outputs_reader(mktempdir())
end

function _with_extras(m::IS.OutputsDocument)
    e = outputs_model(m, "model")
    ds = IS.OutputDataset(
        "variables",
        "OnStatus",
        "ThermalStandard",
        "",
        ["execution", "ThermalStandard", "horizon"],
        "bool",
        false,
        "Dimensionless",
        IS.NaturalUnit(),
        "1",
        [1, 76, 48],
        String[],
    )
    tbl = IS.OutputTable(
        "notes",
        3,
        [IS.OutputColumn("execution", "i64"), IS.OutputColumn("note", "str")],
    )
    e2 = _with(e; datasets = vcat(e.datasets, ds), tables = vcat(e.tables, tbl))
    return _with(m; models = [e2])
end

@testset "outputs reader: bool dataset and str table column round trip" begin
    m = _with_extras(_single_meta())
    dir = mktempdir()
    flags = rand(Bool, 48, 76, 7)
    notes = ["a", "bb", "ccc"]
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m),
        systems = _bundle_systems(m),
        values = merge(_all_values(m),
            Dict(("model", "OnStatus", "ThermalStandard", "") => flags)),
        tables = merge(_all_tables(m),
            Dict(("model", "notes") => (execution = Int64[1, 2, 3], note = notes))))
    a = IS.open_outputs_reader(dir)
    arr, _ = IS.read_dataset(a, "model", "OnStatus", "ThermalStandard")
    @test eltype(arr) == Bool
    @test arr == flags
    t = IS.read_table(a, "model", "notes")
    @test eltype(t.note) == String
    @test t.note == notes
    @test t.execution == [1, 2, 3]
end

@testset "outputs reader: OutputsReader is a plain struct" begin
    @test !(IS.OutputsReader <: IS.Outputs)
    @test supertype(IS.OutputsReader) === Any
end

@testset "outputs reader: RUNNING status warns" begin
    m = _single_meta()
    dir = mktempdir()
    w = IS.open_outputs_writer(dir, m; axis_data = simulation_axis_data(m))
    for name in values(m.systems)
        mkpath(joinpath(dir, name))
    end
    flush(w)
    @test_logs (:warn, r"status RUNNING") IS.open_outputs_reader(dir)
    IS.finalize!(w; status = IS.Simulation.RunStatus.FAILED)
    @test_logs IS.open_outputs_reader(dir)
end

@testset "outputs reader: a missing system bundle directory is an error" begin
    dir = _written_single_dir()
    uuid, name = first(IS.read_outputs_document(joinpath(dir, "outputs.json")).systems)
    rm(joinpath(dir, name); recursive = true)
    @test_throws ArgumentError IS.open_outputs_reader(dir)
    @test_throws "bundle directory \"$name\"" IS.open_outputs_reader(dir)
end

@testset "outputs reader: stored shape and dtype must match the document" begin
    dir = _written_single_dir()
    a = IS.open_outputs_reader(dir)
    path = "/model/datasets/OnVariable__ThermalStandard"
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r+") do f
        HDF5.delete_object(f, path)
        f[path] = rand(48, 75, 7)
    end
    @test_throws ArgumentError IS.read_dataset(a, "model", "OnVariable", "ThermalStandard")
    @test_throws "stored with size (48, 75, 7)" IS.read_dataset(
        a, "model", "OnVariable", "ThermalStandard")
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r+") do f
        HDF5.delete_object(f, path)
        f[path] = rand(Float32, 48, 76, 7)
    end
    @test_throws "stored as Float32" IS.read_dataset(
        a, "model", "OnVariable", "ThermalStandard")
    # the other datasets still read
    arr, _ = IS.read_dataset(a, "model", "ActivePowerVariable", "ThermalStandard")
    @test size(arr) == (48, 76, 7)
end
