# Tests `src/outputs/iso_duration.jl` and `src/outputs/metadata.jl`

@testset "ISO durations round trip" begin
    @test IS.parse_iso_duration("PT1H") == Dates.Millisecond(3_600_000)
    @test IS.parse_iso_duration("P1D") == Dates.Millisecond(86_400_000)
    @test IS.parse_iso_duration("PT5M") == Dates.Millisecond(300_000)
    @test IS.parse_iso_duration("P2DT30M") == Dates.Millisecond(2 * 86_400_000 + 1_800_000)
    @test IS.iso_duration(Dates.Hour(1)) == "PT1H"
    @test IS.iso_duration(Dates.Day(1)) == "P1D"
    @test IS.iso_duration(Dates.Millisecond(300_000)) == "PT5M"
    @test_throws ArgumentError IS.parse_iso_duration("1h")
    @test_throws ArgumentError IS.parse_iso_duration("P")
    @test_throws ArgumentError IS.iso_duration(Dates.Millisecond(1500))
end

@testset "outputs.json parses into typed metadata" begin
    m = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    @test m.schema_version == "0.1.0"
    @test m.kind == "simulation"
    @test IS.has_simulation(m)
    @test IS.get_simulation(m).execution_order == ["UC", "ED"]
    uc = m.models["UC"]
    @test uc.model_type == "decision"
    @test typeof(uc.axes["execution"]) === IS.ExecutionAxis
    @test typeof(uc.axes["horizon"]) === IS.HorizonAxis
    @test typeof(uc.axes["ThermalStandard"]) === IS.ComponentAxis
    @test IS.get_interval(uc.axes["execution"]) == Dates.Millisecond(86_400_000)
    @test IS.get_horizon(uc.axes["horizon"]) == Dates.Millisecond(48 * 3_600_000)
    ds = first(uc.datasets)
    @test IS.dataset_key(ds) == ("ActivePowerVariable", "ThermalStandard", "")
    @test IS.dataset_name(ds) == "ActivePowerVariable__ThermalStandard"
    @test ds.layout.chunks == [1, 76, 48]
    @test IS.dataset_name(uc.datasets[3]) ==
          "ActivePowerReserveVariable__VariableReserve__Reserve_Up"
    em = m.models["EM"]
    @test typeof(em.axes["time"]) === IS.TimeAxis
    @test IS.get_resolution(em.axes["time"]) == Dates.Millisecond(300_000)
    single = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "single", "outputs.json"),
    )
    @test !IS.has_simulation(single)
    @test_throws ErrorException IS.get_simulation(single)
end

@testset "unknown axis kind and unknown fields are rejected" begin
    text = read(joinpath(DATA_DIR, "outputs", "single", "outputs.json"), String)
    path = joinpath(mktempdir(), "outputs.json")
    write(path, replace(text, "\"kind\": \"horizon\"" => "\"kind\": \"bogus\""))
    @test_throws ArgumentError IS.read_outputs_metadata(path)
    write(path, replace(text, "\"status\"" => "\"extra\": 1, \"status\""))
    @test_throws Exception IS.read_outputs_metadata(path)
end

@testset "metadata writes and re-reads identically" begin
    for kind in ("simulation", "single")
        m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", kind, "outputs.json"))
        path = joinpath(mktempdir(), "outputs.json")
        IS.write_outputs_metadata(path, m)
        @test !occursin("null", read(path, String))
        m2 = IS.read_outputs_metadata(path)
        @test m2 == m
    end
end

# IS.JSON.jl parse of the fill_value union: each JSON literal keeps its Julia type.
@testset "fill_value parses to its JSON type" begin
    text = read(joinpath(DATA_DIR, "outputs", "single", "outputs.json"), String)
    path = joinpath(mktempdir(), "outputs.json")
    for (literal, T, expected) in (
        ("0", Int64, 0),
        ("1", Int64, 1),
        ("5", Int64, 5),
        ("-1", Int64, -1),
        ("1.5", Float64, 1.5),
        ("\"NaN\"", String, "NaN"),
        ("false", Bool, false),
    )
        write(path, replace(text, "\"fill_value\": \"NaN\"" => "\"fill_value\": $literal"))
        m = IS.read_outputs_metadata(path)
        fv = first(m.models["model"].datasets).fill_value
        @test typeof(fv) === T
        @test fv == expected
    end
end

@testset "empty optional fields are omitted from the written JSON" begin
    d = IS.OutputDataset(
        "E", "", ["time"], "f64", "NaN", "Q", "NATURAL_UNITS", "rad",
        IS.DatasetLayout([1], String[]), "/m/datasets/E", "variables", "", "",
    )
    c = IS.OutputColumn("n", "i64", "", "", "", "")
    dj = IS.JSON.json(d)
    @test !occursin("component_type", dj) && !occursin("base_reference", dj)
    @test occursin("\"meta\":\"\"", dj)
    cj = IS.JSON.json(c)
    @test cj == "{\"name\":\"n\",\"dtype\":\"i64\"}"
    @test IS.JSON.parse(dj, IS.OutputDataset) == d
    @test IS.JSON.parse(cj, IS.OutputColumn) == c
    @test hash(d) == hash(IS.JSON.parse(dj, IS.OutputDataset))
    @test IS.dataset_name("E", "", "") == "E"
    @test IS.dataset_name("E", "", "m") == "E__m"
    @test IS.dataset_name("E", "C", "") == "E__C"
    @test IS.dataset_name("E", "C", "m") == "E__C__m"
end

@testset "negative durations are rejected" begin
    @test_throws ArgumentError IS.iso_duration(Dates.Hour(-1))
end

@testset "outputs metadata: valid and invalid corpus" begin
    for kind in ("simulation", "single", "power_flow", "security_analysis")
        m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", kind, "outputs.json"))
        @test IS.validate_metadata(m) === nothing
    end
    dir = joinpath(DATA_DIR, "outputs", "invalid")
    files = sort(readdir(dir))
    @test length(files) == 12
    @test "invalid_axis_ref.json" in files
    for f in files
        @test_throws ArgumentError IS.validate_metadata(
            IS.read_outputs_metadata(joinpath(dir, f)),
        )
    end
end

@testset "validate_metadata: value sets and table rules" begin
    base = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "power_flow", "outputs.json"),
    )
    function with_model(f)
        m = deepcopy(base)
        entry = m.models["model"]
        m.models["model"] = f(entry)
        return m
    end
    function with_table_column(c)
        return with_model(
            e -> begin
                t = e.tables[1]
                cols = copy(t.columns)
                cols[2] = c
                tables = [IS.OutputTable(t.name, t.group, t.length, cols)]
                return IS.ModelEntry(
                    e.model_type, e.system_uuid, e.base_power, e.settings, e.axes,
                    e.datasets, tables,
                )
            end,
        )
    end
    @test_throws ArgumentError IS.validate_metadata(
        with_model(
            e -> IS.ModelEntry(
                "bogus", e.system_uuid, e.base_power, e.settings, e.axes, e.datasets,
                e.tables,
            ),
        ),
    )
    m = deepcopy(base)
    @test_throws ArgumentError IS.validate_metadata(IS.with_status(m, "DONE"))
    @test_throws ArgumentError IS.validate_metadata(
        with_table_column(IS.OutputColumn("residual", "f16")),
    )
    @test_throws ArgumentError IS.validate_metadata(
        with_table_column(IS.OutputColumn("residual", "f64", "Dimensionless", "", "", "1")),
    )
    @test_throws ArgumentError IS.validate_metadata(
        with_table_column(
            IS.OutputColumn("residual", "f64", "Dimensionless", "PU", "", "1"),
        ),
    )
    @test_throws ArgumentError IS.validate_metadata(
        with_table_column(
            IS.OutputColumn("residual", "f64", "Dimensionless", "COMPONENT_BASE", "", "pu"),
        ),
    )
    @test IS.validate_metadata(
        with_table_column(
            IS.OutputColumn(
                "residual", "f64", "Dimensionless", "COMPONENT_BASE", "system", "pu",
            ),
        ),
    ) === nothing
    @test_throws ArgumentError IS.validate_metadata(
        with_model(
            e -> begin
                t = e.tables[1]
                tables = [
                    IS.OutputTable(t.name, "/model/tables/other", t.length, t.columns),
                ]
                return IS.ModelEntry(
                    e.model_type, e.system_uuid, e.base_power, e.settings, e.axes,
                    e.datasets, tables,
                )
            end,
        ),
    )
    @test_throws ArgumentError IS.validate_metadata(
        with_model(
            e -> begin
                d = e.datasets[1]
                bad = IS.OutputDataset(
                    d.entry_type, d.meta, d.axes, "f16", d.fill_value,
                    d.quantity_kind,
                    d.unit_system, d.units, d.layout, d.path, d.container,
                    d.component_type,
                    d.base_reference,
                )
                return IS.ModelEntry(
                    e.model_type, e.system_uuid, e.base_power, e.settings, e.axes,
                    [bad, e.datasets[2]], e.tables,
                )
            end,
        ),
    )
    @test_throws ArgumentError IS.validate_metadata(
        with_model(
            e -> begin
                d = e.datasets[1]
                bad = IS.OutputDataset(
                    d.entry_type, d.meta, d.axes, d.dtype, d.fill_value,
                    d.quantity_kind,
                    "PU", d.units, d.layout, d.path, d.container, d.component_type,
                    d.base_reference,
                )
                return IS.ModelEntry(
                    e.model_type, e.system_uuid, e.base_power, e.settings, e.axes,
                    [bad, e.datasets[2]], e.tables,
                )
            end,
        ),
    )
end

@testset "component-less datasets: name, path, and descriptor" begin
    pf = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "power_flow", "outputs.json"),
    )
    d = pf.models["model"].datasets[2]
    @test d.component_type == "" && IS.dataset_name(d) == "PowerFlowConverged"
    @test d.path == "/model/datasets/PowerFlowConverged"
end
