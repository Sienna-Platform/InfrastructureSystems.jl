const _IOS = InfrastructureOutputSchemas

_decoded(kind) =
    _IOS.decode(_IOS.OutputsDocument, JSON.parse(read(outputs_fixture(kind), String)))
_decode_file(path) = IS._decode_document(JSON.parse(read(path, String)))

@testset "outputs serde: the fixtures round trip" begin
    for kind in ("single", "simulation", "power_flow", "security_analysis")
        x = _decoded(kind)
        doc = IS.from_openapi(x)
        @test typeof(doc) == IS.OutputsDocument
        @test _IOS.encode(IS.to_openapi(doc)) == _IOS.encode(x)
        @test IS._encode_document(IS._decode_document(IS._encode_document(doc))) ==
              IS._encode_document(doc)
    end
end

@testset "outputs serde: to_openapi derives kind, group, and path" begin
    t0 = DateTime(2024, 1, 1)
    time_axis = IS.to_openapi(IS.TimeAxis(t0, Dates.Hour(1), 3), "m")
    @test time_axis.kind == "time"
    @test time_axis.group == "/m/axes/time"
    @test time_axis.resolution == "PT1H"
    @test time_axis.initial_timestamp == "2024-01-01T00:00:00"
    component = IS.ComponentAxis([IS.ComponentAxisColumn("Pipe", true)], 2)
    @test IS.to_openapi(component, "m").group == "/m/axes/Pipe"
    @test typeof(IS.to_openapi(component, "m").subset) == IS.OpenAPI.Runtime.Absent
    dataset = IS.OutputDataset(
        "variables", "FlowVariable", "Pipe", "", ["time", "Pipe"], "f64", "NaN",
        "VolumeFlow", IS.NU, "m3/s", [3, 2], ["shuffle"],
    )
    wire = IS.to_openapi(dataset, "m")
    @test wire.path == "/m/datasets/FlowVariable__Pipe"
    @test string(wire.unit_system) == "NATURAL_UNITS"
    @test wire.layout.chunks == [3, 2]
    table = IS.OutputTable("stats", 2, [IS.OutputColumn("execution", "i64")])
    @test IS.to_openapi(table, "m").group == "/m/tables/stats"
end

@testset "outputs serde: from_openapi rejects a wrong derived field" begin
    path = outputs_fixture_with("simulation") do raw
        first(
            a for a in raw["models"][1]["axes"] if a["kind"] == "execution"
        )["group"] = "/UC/axes/other"
    end
    @test_throws ArgumentError _decode_file(path)
    @test_throws r"has group \"/UC/axes/other\", expected" _decode_file(path)
    path = outputs_fixture_with("simulation") do raw
        raw["models"][1]["datasets"][1]["path"] = "/UC/datasets/Other"
    end
    @test_throws r"has path \"/UC/datasets/Other\", expected" _decode_file(path)
    path = outputs_fixture_with("simulation") do raw
        raw["models"][1]["tables"][1]["group"] = "/UC/tables/other"
    end
    @test_throws r"has group \"/UC/tables/other\", expected" _decode_file(path)
    path = outputs_fixture_with("simulation") do raw
        first(
            a for a in raw["models"][1]["axes"] if a["kind"] == "execution"
        )["initial_timestamp"] = "2024-13-01T00:00:00"
    end
    @test_throws r"initial_timestamp \"2024-13-01T00:00:00\" is not a valid date" _decode_file(
        path,
    )
end

@testset "outputs serde: a different spelling reads to the canonical value" begin
    canonical = IS.from_openapi(_decoded("simulation"))
    path = outputs_fixture_with("simulation") do raw
        execution = first(a for a in raw["models"][1]["axes"] if a["kind"] == "execution")
        execution["interval"] = "P000000001D"
        component =
            first(a for a in raw["models"][1]["axes"] if a["kind"] == "component")
        component["subset"] = ""
    end
    doc = _decode_file(path)
    @test _IOS.encode(IS.to_openapi(doc)) == _IOS.encode(IS.to_openapi(canonical))
    path = outputs_fixture_with("simulation") do raw
        execution = first(a for a in raw["models"][1]["axes"] if a["kind"] == "execution")
        execution["initial_timestamp"] = "2024-01-01T00:00:00.5"
    end
    doc = _decode_file(path)
    axis = first(a for a in doc.models[1].axes if IS.axis_name(a) == "execution")
    @test IS.get_initial_timestamp(axis) == DateTime(2024, 1, 1, 0, 0, 0, 500)
    @test tryparse(DateTime, IS.to_openapi(axis, "UC").initial_timestamp) ==
          DateTime(2024, 1, 1, 0, 0, 0, 500)
    path = outputs_fixture_with(raw -> (raw["models"][1]["tables"] = []), "single")
    doc = _decode_file(path)
    @test isempty(doc.models[1].tables)
    @test typeof(IS.to_openapi(doc).models[1].tables) == IS.OpenAPI.Runtime.Absent
end

@testset "outputs serde: unit systems, status, and simulation" begin
    @test IS.unit_system_name(IS.SU) == "SYSTEM_BASE"
    @test IS.unit_system_name(IS.CU) == "COMPONENT_BASE"
    @test IS.unit_system_name(IS.NU) == "NATURAL_UNITS"
    single = IS.from_openapi(_decoded("single"))
    @test typeof(single.simulation) == IS.Simulation.NoSimulation
    @test typeof(IS.to_openapi(single).simulation) == IS.OpenAPI.Runtime.Absent
    simulation = IS.from_openapi(_decoded("simulation"))
    @test typeof(simulation.simulation) == IS.Simulation.SimulationParams
    @test simulation.simulation.step_resolution == Dates.Millisecond(Dates.Day(1))
    @test typeof(simulation.status) == IS.Simulation.RunStatus.Value
end

@testset "outputs serde: a fill_value above Int64 reads as Float64" begin
    path = outputs_fixture_with("simulation") do raw
        raw["models"][1]["datasets"][1]["fill_value"] = 100000000000000000000
    end
    dataset = _decode_file(path).models[1].datasets[1]
    @test dataset.fill_value === 1.0e20
end
