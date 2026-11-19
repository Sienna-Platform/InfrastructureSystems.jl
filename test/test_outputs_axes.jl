# Tests `src/outputs/axes.jl`

_column(t) =
    PowerOutputSchemas.ComponentAxisColumnsItem(; component_type = t, has_ids = true)

@testset "axis keys derive from content" begin
    @test IS.axis_key(
        PowerOutputSchemas.ComponentAxis(;
            kind = "component",
            columns = [_column("ThermalStandard")],
            length = 76,
            group = "/UC/axes/ThermalStandard",
        ),
    ) == "ThermalStandard"
    @test IS.axis_key(
        PowerOutputSchemas.ComponentAxis(;
            kind = "component",
            columns = [_column("VariableReserve"), _column("ThermalStandard")],
            length = 152,
            group = "/UC/axes/VariableReserve__ThermalStandard",
        ),
    ) == "VariableReserve__ThermalStandard"
    @test IS.axis_key(
        PowerOutputSchemas.ComponentAxis(;
            kind = "component",
            columns = [_column("ACBranch")],
            length = 10,
            group = "/m/axes/ACBranch__monitored",
            subset = "monitored",
        ),
    ) == "ACBranch__monitored"
    horizon = PowerOutputSchemas.HorizonAxis(;
        kind = "horizon", resolution = "PT1H", horizon_count = 48,
    )
    @test IS.axis_length(horizon) == 48
    @test IS.axis_length(PowerOutputSchemas.Axis(horizon)) == 48
    label = PowerOutputSchemas.LabelAxis(;
        kind = "label",
        name = "winding",
        labels = ["a", "b"],
    )
    @test IS.axis_length(label) == 2
    @test IS.axis_key(label) == "winding"
    @test IS.axis_key(PowerOutputSchemas.Axis(label)) == "winding"
end

_label_axis(name) =
    PowerOutputSchemas.LabelAxis(; kind = "label", name = name, labels = ["a"])

@testset "the outputs fixtures validate" begin
    for name in ("simulation", "single")
        m = IS.read_outputs_metadata(outputs_fixture(name))
        @test IS.validate_metadata(m) === nothing
    end
end

@testset "a dataset axis name must match an axis" begin
    m = IS.read_outputs_metadata(outputs_fixture("simulation"))
    for d in outputs_model(m, "UC").datasets
        replace!(d.axes, "ThermalStandard" => "therm")
    end
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"UC.*axis \"therm\" absent" IS.validate_metadata(m)
end

@testset "model and axis names are unique" begin
    base() = IS.read_outputs_metadata(outputs_fixture("simulation"))
    m = base()
    push!(m.models, outputs_model(m, "UC"))
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"duplicate model name \"UC\"" IS.validate_metadata(m)
    m = base()
    uc = outputs_model(m, "UC")
    push!(uc.axes, PowerOutputSchemas.Axis(outputs_axis(uc, "ThermalStandard")))
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"model UC: duplicate axis name \"ThermalStandard\"" IS.validate_metadata(
        m,
    )
    # The schema reserves the name before the duplicate rule sees it.
    m = base()
    push!(outputs_model(m, "UC").axes, PowerOutputSchemas.Axis(_label_axis("execution")))
    expect_schema_invalid(m, r"LabelAxis\s+/name: not")
end

@testset "label axis name rules" begin
    @test IS.validate_metadata(
        IS.read_outputs_metadata(outputs_fixture("security_analysis")),
    ) ===
          nothing
    for (fixture, name, rx) in (
        ("simulation", "time", r"/name: not"),
        ("security_analysis", "execution", r"/name: not"),
        ("security_analysis", "horizon", r"/name: not"),
        ("security_analysis", "Bad Key", r"/name: pattern"),
        ("security_analysis", "1st", r"/name: pattern"),
        ("security_analysis", "a/b", r"/name: pattern"),
        ("security_analysis", "", r"/name: pattern"),
    )
        m = IS.read_outputs_metadata(outputs_fixture(fixture))
        push!(m.models[1].axes, PowerOutputSchemas.Axis(_label_axis(name)))
        expect_schema_invalid(m, rx)
    end
end

@testset "every structural rule has a failing case" begin
    base() = IS.read_outputs_metadata(outputs_fixture("simulation"))
    first_ds(m) = first(outputs_model(m, "UC").datasets)
    set_first_ds!(m, d) = (outputs_model(m, "UC").datasets[1] = d)
    layout(chunks) = PowerOutputSchemas.DatasetLayout(; chunks = chunks, filters = String[])
    # Cases that the cross-reference rules of IS reject.
    is_cases = [
        ("axis ref", m -> push!(first_ds(m).axes, "Nope")),
        ("chunk rank", m -> push!(first_ds(m).layout.chunks, 1)),
        ("duplicate tuple", m -> push!(outputs_model(m, "UC").datasets, first_ds(m))),
        ("execution_order", m -> push!(IS.get_simulation(m).execution_order, "XX")),
        (
            "path of another dataset",
            m -> set_first_ds!(m, _with(first_ds(m); path = "/UC/datasets/Other")),
        ),
        (
            "component_type without component axis",
            m -> set_first_ds!(
                m,
                _with(first_ds(m); axes = ["execution"], layout = layout([1])),
            ),
        ),
        (
            "component_type differs from axis",
            m -> set_first_ds!(m, _with(first_ds(m); component_type = "Other")),
        ),
    ]
    for (label, mutate!) in is_cases
        m = base()
        mutate!(m)
        @testset "$label" begin
            @test_throws ArgumentError IS.validate_metadata(m)
        end
    end
    # Cases that the outputs schema rejects.
    schema_cases = [
        (
            "bad path",
            m -> set_first_ds!(m, _with(first_ds(m); path = "/UC/x")),
            r"/path: pattern",
        ),
        (
            "two execution axes",
            m -> (
                push!(first_ds(m).axes, "execution"); push!(first_ds(m).layout.chunks, 1)
            ),
            r"/axes: uniqueItems",
        ),
        (
            "horizon without execution",
            m -> (
                filter!(!=("execution"), first_ds(m).axes); pop!(first_ds(m).layout.chunks)
            ),
            r"/axes: contains",
        ),
        (
            "base unit without reference",
            m -> set_first_ds!(
                m,
                _with(first_ds(m); base_reference = OpenAPI.Runtime.ABSENT),
            ),
            r"Dataset\s+: required",
        ),
        (
            "natural units with reference",
            m -> set_first_ds!(
                m,
                _with(
                    first_ds(m);
                    unit_system = PowerOutputSchemas.UnitSystem("NATURAL_UNITS"),
                ),
            ),
            r"Dataset\s+: not",
        ),
        (
            "meta with double underscore",
            m -> set_first_ds!(m, _with(first_ds(m); meta = "a__b")),
            r"/meta: not",
        ),
        (
            "entry_type not a type name",
            m -> set_first_ds!(m, _with(first_ds(m); entry_type = "bad name")),
            r"/entry_type: pattern",
        ),
        (
            "axis kind differs from type",
            m -> set_outputs_axis!(
                outputs_model(m, "UC"),
                "horizon",
                PowerOutputSchemas.HorizonAxis(;
                    kind = "time", resolution = "PT1H", horizon_count = 48,
                ),
            ),
            r"/kind: const",
        ),
        (
            "system uuid",
            m -> empty!(IS._systems(m)),
            r"/systems: minProperties|: minProperties",
        ),
        (
            "label name",
            m -> push!(
                outputs_model(m, "UC").axes,
                PowerOutputSchemas.Axis(_label_axis("Bad Key")),
            ),
            r"/name: pattern",
        ),
    ]
    for (label, mutate!, rx) in schema_cases
        m = base()
        mutate!(m)
        @testset "$label" begin
            expect_schema_invalid(m, rx)
        end
    end
    # Enum fields cannot hold another value in Julia: the JSON reader rejects them.
    for (label, value) in (("missing container", ""), ("bad container", "x"))
        @testset "$label" begin
            path = outputs_fixture_with("simulation") do raw
                raw["models"][1]["datasets"][1]["container"] = value
            end
            expect_schema_invalid(path, r"/container: enum")
        end
    end

    m = IS.read_outputs_metadata(outputs_fixture("single"))
    @test IS.validate_metadata(m) === nothing
    bad = _with(m; kind = PowerOutputSchemas.Kind("simulation"))
    expect_schema_invalid(bad, r": required")
end

@testset "simulation parameters need kind simulation" begin
    m = IS.read_outputs_metadata(outputs_fixture("simulation"))
    bad = _with(m; kind = PowerOutputSchemas.Kind("single"))
    expect_schema_invalid(bad, r"OutputsDocument\s+: not")
end
