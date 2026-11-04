# Tests `src/outputs/reader.jl`. Reuses helpers from test_outputs_writer.jl.

function _written_single_dir(vals = rand(48, 76, 7))
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m),
        values = Dict(("model", _KEY...) => vals,
            ("model", "OnVariable", "ThermalStandard", "") => rand(48, 76, 7)),
        tables = Dict(
            ("model", "optimizer_stats") => (
                execution = collect(Int64, 1:7), objective_value = rand(7),
                termination_status = ones(Int64, 7), solve_time = rand(7)),
        ))
    return dir
end

@testset "outputs reader: read back what the writer wrote" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    vals = rand(48, 76, 7)
    a = IS.open_outputs(_written_single_dir(vals))
    @test IS.get_metadata(a).status == "SUCCESSFULLY_FINALIZED"
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
    @test ex.timestamps == simulation_axis_data(m)[("model", "execution")].timestamps
    @test IS.get_axis(a, "model", "horizon") isa IS.HorizonAxis
    @test isempty(IS.read_axis_data(a, "model", "horizon").timestamps)
    tbl = IS.read_table(a, "model", "optimizer_stats")
    @test tbl.execution == 1:7
    @test length(tbl.objective_value) == 7
end

@testset "outputs reader: missing things" begin
    a = IS.open_outputs(_written_single_dir())
    err = try
        IS.read_dataset(a, "model", "Nope", "ThermalStandard")
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("model", err.msg) && occursin("Nope", err.msg)
    @test_throws ArgumentError IS.read_dataset(a, "ZZ", "ActivePowerVariable",
        "ThermalStandard")
    @test_throws ArgumentError IS.read_table(a, "model", "nope")
    @test_throws ArgumentError IS.get_axis(a, "model", "nope")
    @test_throws ArgumentError IS.list_datasets(a, "ZZ")
end

@testset "outputs reader: open_outputs validates the directory" begin
    dir = mktempdir()
    cp(_SINGLE_JSON, joinpath(dir, "outputs.json"))
    @test_throws ArgumentError IS.open_outputs(dir)
    @test_throws ArgumentError IS.open_outputs(mktempdir())
end

function _with_extras(m::IS.OutputsMetadata)
    e = m.models["model"]
    ds = IS.OutputDataset(
        "OnStatus", "", ["execution", "ThermalStandard", "horizon"], "bool", false,
        "Dimensionless", "NATURAL_UNITS", "1", IS.DatasetLayout([1, 76, 48], String[]),
        "/model/datasets/OnStatus__ThermalStandard", "variables", "ThermalStandard", "",
    )
    tbl = IS.OutputTable("notes", "/model/tables/notes", 3,
        [IS.OutputColumn("execution", "i64"), IS.OutputColumn("note", "str")])
    e2 = IS.ModelEntry(e.model_type, e.system_uuid, e.base_power, e.settings, e.axes,
        vcat(e.datasets, ds), vcat(e.tables, tbl))
    return IS.OutputsMetadata(m.schema_version, m.kind, m.producer, m.created_at,
        m.status, m.systems, Dict("model" => e2), m.simulation)
end

@testset "outputs reader: bool dataset and str table column round trip" begin
    m = _with_extras(IS.read_outputs_metadata(_SINGLE_JSON))
    dir = mktempdir()
    flags = rand(Bool, 48, 76, 7)
    notes = ["a", "bb", "ccc"]
    IS.write_outputs(dir, m; axis_data = simulation_axis_data(m),
        values = Dict(("model", "OnStatus", "ThermalStandard", "") => flags),
        tables = Dict(("model", "notes") => (execution = Int64[1, 2, 3], note = notes)))
    a = IS.open_outputs(dir)
    arr, _ = IS.read_dataset(a, "model", "OnStatus", "ThermalStandard")
    @test eltype(arr) == Bool
    @test arr == flags
    t = IS.read_table(a, "model", "notes")
    @test eltype(t.note) == String
    @test t.note == notes
    @test t.execution == [1, 2, 3]
end
