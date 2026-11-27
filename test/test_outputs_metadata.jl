# Tests `src/outputs/iso_duration.jl` and `src/outputs/document.jl`

@testset "ISO durations round trip" begin
    @test IS.parse_iso_duration("PT1H") == Dates.Millisecond(3_600_000)
    @test IS.parse_iso_duration("P1D") == Dates.Millisecond(86_400_000)
    @test IS.parse_iso_duration("PT5M") == Dates.Millisecond(300_000)
    @test IS.parse_iso_duration("P2DT30M") == Dates.Millisecond(2 * 86_400_000 + 1_800_000)
    @test IS.iso_duration(Dates.Hour(1)) == "PT1H"
    @test IS.iso_duration(Dates.Day(1)) == "P1D"
    @test IS.iso_duration(Dates.Millisecond(300_000)) == "PT5M"
    @test IS.iso_duration(Dates.Minute(1500)) == "P1DT1H"
    @test IS.iso_duration(Dates.Minute(0)) == "PT0M"
    @test_throws ArgumentError IS.parse_iso_duration("1h")
    @test_throws ArgumentError IS.parse_iso_duration("P")
    @test_throws ArgumentError IS.parse_iso_duration("PT30S")
    @test_throws ArgumentError IS.iso_duration(Dates.Millisecond(1500))
    @test_throws ArgumentError IS.iso_duration(Dates.Second(90))
    @test IS.parse_iso_duration(IS.iso_duration(Dates.Day(999_999_999))) ==
          Dates.Millisecond(999_999_999 * 86_400_000)
    @test_throws ArgumentError IS.iso_duration(Dates.Day(1_000_000_000))
end

@testset "outputs.json parses into typed document" begin
    m = IS.read_outputs_document(outputs_fixture("simulation"))
    @test IS.has_simulation(m)
    @test IS.get_simulation(m).execution_order == ["UC", "ED"]
    uc = outputs_model(m, "UC")
    @test typeof(outputs_axis(uc, "execution")) === IS.ExecutionAxis
    @test typeof(outputs_axis(uc, "horizon")) === IS.HorizonAxis
    @test typeof(outputs_axis(uc, "ThermalStandard")) === IS.ComponentAxis
    @test IS.get_interval(outputs_axis(uc, "execution")) == Dates.Millisecond(86_400_000)
    @test IS.get_horizon(outputs_axis(uc, "horizon")) == Dates.Millisecond(48 * 3_600_000)
    ds = first(uc.datasets)
    @test IS.dataset_key(ds) == ("ActivePowerVariable", "ThermalStandard", "")
    @test IS.dataset_name(ds) == "ActivePowerVariable__ThermalStandard"
    @test IS.dataset_name(uc.datasets[3]) ==
          "ActivePowerReserveVariable__VariableReserve__Reserve_Up"
    em = outputs_model(m, "EM")
    @test typeof(outputs_axis(em, "time")) === IS.TimeAxis
    @test IS.get_resolution(outputs_axis(em, "time")) == Dates.Millisecond(300_000)
    single = IS.read_outputs_document(outputs_fixture("single"))
    @test !IS.has_simulation(single)
    @test_throws ErrorException IS.get_simulation(single)
end

@testset "unknown axis kind and unknown fields are rejected" begin
    path = outputs_fixture_with("single") do raw
        raw["models"][1]["axes"][2]["kind"] = "bogus"
    end
    expect_schema_invalid(path, r"/axes/1: oneOf")
    path = outputs_fixture_with(raw -> (raw["extra"] = 1), "single")
    expect_schema_invalid(path, r"/extra: schema")
end

@testset "document writes and re-reads identically" begin
    for kind in ("simulation", "single", "security_analysis")
        m = IS.read_outputs_document(outputs_fixture(kind))
        path = joinpath(mktempdir(), "outputs.json")
        IS.write_outputs_document(path, m)
        text = read(path, String)
        @test !occursin("null", text)
        @test occursin("simulation", text) == (kind == "simulation")
        m2 = IS.read_outputs_document(path)
        @test IS._encode_document(m2) == IS._encode_document(m)
    end
end

@testset "write_outputs_document keeps the existing path when the replace fails" begin
    m = IS.read_outputs_document(outputs_fixture("single"))
    path = joinpath(mktempdir(), "outputs.json")
    # A directory with content at `path` makes the rename of the temporary file fail.
    mkpath(path)
    write(joinpath(path, "keep.txt"), "previous")
    @test_throws Union{Base.IOError, ArgumentError} IS.write_outputs_document(path, m)
    @test read(joinpath(path, "keep.txt"), String) == "previous"
    @test !ispath(string(path, ".tmp"))
end

# Each JSON literal of fill_value keeps its Julia type.
@testset "fill_value parses to its JSON type" begin
    for (literal, T, expected) in (
        (0, Int64, 0),
        (1, Int64, 1),
        (5, Int64, 5),
        (-1, Int64, -1),
        (1.5, Float64, 1.5),
        ("NaN", String, "NaN"),
    )
        path = outputs_fixture_with("single") do raw
            raw["models"][1]["datasets"][1]["fill_value"] = literal
        end
        fv =
            first(
                outputs_model(IS.read_outputs_document(path), "model").datasets,
            ).fill_value
        @test typeof(fv) === T
        @test fv == expected
    end
    path = outputs_fixture_with("single") do raw
        raw["models"][1]["datasets"][1]["dtype"] = "bool"
        raw["models"][1]["datasets"][1]["fill_value"] = false
    end
    fv = first(outputs_model(IS.read_outputs_document(path), "model").datasets).fill_value
    @test fv === false
end

@testset "dataset names" begin
    @test IS.dataset_name("E", "", "") == "E"
    @test IS.dataset_name("E", "", "m") == "E__m"
    @test IS.dataset_name("E", "C", "") == "E__C"
    @test IS.dataset_name("E", "C", "m") == "E__C__m"
end

@testset "negative durations are rejected" begin
    @test_throws ArgumentError IS.iso_duration(Dates.Hour(-1))
end

@testset "outputs document: valid corpus" begin
    for kind in ("simulation", "single", "power_flow", "security_analysis")
        m = IS.read_outputs_document(outputs_fixture(kind))
        @test IS.validate_document(m) === nothing
    end
end

@testset "validate_document: value sets and table rules" begin
    base = IS.read_outputs_document(outputs_fixture("power_flow"))
    function with_model(f)
        m = deepcopy(base)
        i = outputs_model_index(m, "model")
        m.models[i] = f(m.models[i])
        return m
    end
    function with_table_column(c)
        return with_model(
            e -> begin
                t = e.tables[1]
                cols = copy(t.columns)
                cols[2] = c
                return _with(e; tables = [_with(t; columns = cols)])
            end,
        )
    end
    column(unit_system, units) =
        IS.OutputColumn("residual", "f64", "Dimensionless", unit_system, units)
    # Enum values: the reader rejects them.
    rule = Dict(
        "model_type" => "pattern",
        "status" => "enum",
        "dtype" => "enum",
        "unit_system" => "enum",
    )
    for (field, value, at_dataset) in (
        ("model_type", "Bogus", false),
        ("status", "DONE", false),
        ("dtype", "f16", true),
        ("unit_system", "PU", true),
    )
        path = outputs_fixture_with("power_flow") do raw
            target = raw
            if field == "model_type"
                target = raw["models"][1]
            elseif at_dataset
                target = raw["models"][1]["datasets"][1]
            end
            target[field] = value
        end
        expect_schema_invalid(path, Regex("/$field: $(rule[field])"))
    end
    for (field, value) in (("dtype", "f16"), ("unit_system", "PU"))
        path = outputs_fixture_with("power_flow") do raw
            raw["models"][1]["tables"][1]["columns"][2][field] = value
        end
        expect_schema_invalid(path, Regex("/columns/1/$field: enum"))
    end
    # An IS value with a dtype outside the schema enum fails when it converts.
    bad_dtype = with_model(
        e -> _with(
            e;
            datasets = [_with(e.datasets[1]; dtype = "f16"), e.datasets[2:end]...],
        ),
    )
    @test_throws ArgumentError IS.validate_document(bad_dtype)
    @test_throws r"invalid Dtype value \"f16\"" IS.validate_document(bad_dtype)

    uuid = first(keys(base.systems))
    for bad in ("../x", "/abs", "a/b", "a\\b", ".", "..", "")
        m2 = deepcopy(base)
        m2.systems[uuid] = bad
        expect_schema_invalid(m2, Regex("/$uuid: pattern"))
    end
    # An IS column has all three unit fields or none: a file with a partial set is the case.
    path = outputs_fixture_with("power_flow") do raw
        delete!(raw["models"][1]["tables"][1]["columns"][2], "unit_system")
    end
    expect_schema_invalid(path, r": dependentRequired")
    expect_schema_invalid(with_table_column(column(IS.SU, "MW")), r"/units: const")
    @test IS.validate_document(with_table_column(column(IS.CU, "pu"))) === nothing
    # IS derives the table group: a file that gives another value does not read.
    path = outputs_fixture_with("power_flow") do raw
        raw["models"][1]["tables"][1]["group"] = "/model/tables/other"
    end
    @test_throws r"table solver_stats has group \"/model/tables/other\"" IS.read_outputs_document(
        path,
    )
end

@testset "component-less datasets: name, path, and descriptor" begin
    pf = IS.read_outputs_document(outputs_fixture("power_flow"))
    d = outputs_model(pf, "model").datasets[2]
    @test IS.dataset_key(d)[2] == "" && IS.dataset_name(d) == "PowerFlowConverged"
    @test IS.dataset_path("model", d) == "/model/datasets/PowerFlowConverged"
end

@testset "validate_document: a duration must be whole minutes" begin
    doc = IS.read_outputs_document(outputs_fixture("simulation"))
    model = outputs_model(doc, "UC")
    execution = outputs_axis(model, "execution")
    set_outputs_axis!(
        model,
        "execution",
        _with(execution; interval = Dates.Millisecond(1500)),
    )
    @test_throws ArgumentError IS.validate_document(doc)
    @test_throws r"model UC: axis \"execution\": interval: duration is not a whole number of minutes" IS.validate_document(
        doc,
    )
end

@testset "validate_document: the status of a document is RUNNING or a final status" begin
    doc = IS.read_outputs_document(outputs_fixture("single"))
    for status in (IS.Simulation.RunStatus.NOT_READY, IS.Simulation.RunStatus.INITIALIZED)
        bad = IS.with_status(doc, status)
        @test_throws ArgumentError IS.validate_document(bad)
        @test_throws r"invalid RunStatus value" IS.validate_document(bad)
    end
end
