# Tests `src/outputs/axes.jl`

@testset "axis keys derive from content" begin
    @test IS.axis_key(
        IS.ComponentAxis(
            "component",
            [IS.AxisColumn("ThermalStandard", true)],
            76,
            "/UC/axes/ThermalStandard",
            "",
        ),
    ) == "ThermalStandard"
    @test IS.axis_key(
        IS.ComponentAxis("component",
            [
                IS.AxisColumn("VariableReserve", true),
                IS.AxisColumn("ThermalStandard", true),
            ], 152, "/UC/axes/VariableReserve__ThermalStandard", ""),
    ) == "VariableReserve__ThermalStandard"
    @test IS.axis_key(
        IS.ComponentAxis(
            "component",
            [IS.AxisColumn("ACBranch", true)],
            10,
            "/m/axes/ACBranch__monitored",
            "monitored",
        ),
    ) == "ACBranch__monitored"
    @test IS.axis_length(IS.HorizonAxis("horizon", "PT1H", 48)) == 48
    @test IS.axis_length(IS.LabelAxis("label", "winding", ["a", "b"])) == 2
    @test IS.axis_key(IS.LabelAxis("label", "winding", ["a", "b"])) == "winding"
end

@testset "the outputs fixtures validate" begin
    for name in ("simulation", "single")
        m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", name, "outputs.json"))
        @test IS.validate_metadata(m) === nothing
    end
end

@testset "a dataset axis name must match an axis" begin
    m = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    for d in outputs_model(m, "UC").datasets
        replace!(d.axes, "ThermalStandard" => "therm")
    end
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"UC.*axis \"therm\" absent" IS.validate_metadata(m)
end

@testset "model and axis names are unique" begin
    base() = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    m = base()
    push!(m.models, outputs_model(m, "UC"))
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"duplicate model name \"UC\"" IS.validate_metadata(m)
    m = base()
    uc = outputs_model(m, "UC")
    push!(uc.axes, outputs_axis(uc, "ThermalStandard"))
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"model UC: duplicate axis name \"ThermalStandard\"" IS.validate_metadata(
        m,
    )
    m = base()
    uc = outputs_model(m, "UC")
    push!(uc.axes, IS.LabelAxis("label", "execution", ["a"]))
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws r"duplicate axis name \"execution\"" IS.validate_metadata(m)
end

@testset "label axis name rules" begin
    read_fixture(name) = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", name, "outputs.json"),
    )
    @test IS.validate_metadata(read_fixture("security_analysis")) === nothing
    for (fixture, name, rx) in (
        ("simulation", "time", r"label axis name \"time\" is reserved"),
        ("security_analysis", "execution", r"label axis name \"execution\" is reserved"),
        ("security_analysis", "horizon", r"label axis name \"horizon\" is reserved"),
        (
            "security_analysis",
            "Bad Key",
            r"label axis name \"Bad Key\" is not lower snake case",
        ),
        ("security_analysis", "1st", r"not lower snake case"),
        ("security_analysis", "a/b", r"axis name \"a/b\""),
        ("security_analysis", "", r"axis name"),
    )
        m = read_fixture(fixture)
        push!(m.models[1].axes, IS.LabelAxis("label", name, ["primary"]))
        @test_throws ArgumentError IS.validate_metadata(m)
        @test_throws rx IS.validate_metadata(m)
    end
end

@testset "every structural rule has a failing case" begin
    base() = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    first_ds(m) = first(outputs_model(m, "UC").datasets)
    function with_fields(d; kw...)
        vals = Dict{Symbol, Any}(k => getfield(d, k) for k in fieldnames(IS.OutputDataset))
        merge!(vals, Dict{Symbol, Any}(kw))
        return IS.OutputDataset((vals[k] for k in fieldnames(IS.OutputDataset))...)
    end
    cases = [
        ("axis ref", m -> push!(first_ds(m).axes, "Nope")),
        ("chunk rank", m -> push!(first_ds(m).layout.chunks, 1)),
        ("duplicate tuple", m -> push!(outputs_model(m, "UC").datasets, first_ds(m))),
        (
            "missing container",
            m ->
                (
                    outputs_model(m, "UC").datasets[1] =
                        with_fields(first_ds(m); container = "")
                ),
        ),
        (
            "bad container",
            m -> (
                outputs_model(m, "UC").datasets[1] =
                    with_fields(first_ds(m); container = "x")
            ),
        ),
        ("execution_order", m -> push!(IS.get_simulation(m).execution_order, "XX")),
        (
            "two execution axes",
            m -> (
                push!(first_ds(m).axes, "execution"); push!(first_ds(m).layout.chunks, 1)
            ),
        ),
        (
            "horizon without execution",
            m -> (
                filter!(!=("execution"), first_ds(m).axes); pop!(first_ds(m).layout.chunks)
            ),
        ),
        (
            "bad path",
            m ->
                (
                    outputs_model(m, "UC").datasets[1] =
                        with_fields(first_ds(m); path = "/UC/x")
                ),
        ),
        (
            "base unit without reference",
            m -> (
                outputs_model(m, "UC").datasets[1] = with_fields(
                    first_ds(m);
                    unit_system = "COMPONENT_BASE",
                    base_reference = "",
                    units = "pu",
                )
            ),
        ),
        (
            "natural units with reference",
            m -> (
                outputs_model(m, "UC").datasets[1] = with_fields(
                    first_ds(m);
                    unit_system = "NATURAL_UNITS",
                    base_reference = "system",
                )
            ),
        ),
        (
            "component_type without component axis",
            m -> (
                outputs_model(m, "UC").datasets[1] =
                    with_fields(first_ds(m); axes = ["execution"],
                        layout = IS.DatasetLayout([1], String[]))
            ),
        ),
        (
            "component_type differs from axis",
            m -> (
                outputs_model(m, "UC").datasets[1] =
                    with_fields(first_ds(m); component_type = "Other")
            ),
        ),
        (
            "meta with double underscore",
            m -> (
                outputs_model(m, "UC").datasets[1] =
                    with_fields(first_ds(m); meta = "a__b")
            ),
        ),
        (
            "entry_type not a type name",
            m -> (
                outputs_model(m, "UC").datasets[1] =
                    with_fields(first_ds(m); entry_type = "bad name")
            ),
        ),
        (
            "axis kind differs from type",
            m -> (
                outputs_model(m, "UC").axes[outputs_axis_index(
                    outputs_model(m, "UC"),
                    "horizon",
                )] =
                    IS.HorizonAxis("time", "PT1H", 48)
            ),
        ),
        ("system uuid", m -> empty!(m.systems)),
        (
            "label name",
            m -> push!(
                outputs_model(m, "UC").axes,
                IS.LabelAxis("label", "Bad Key", ["a"]),
            ),
        ),
    ]
    for (label, mutate!) in cases
        m = base()
        mutate!(m)
        @testset "$label" begin
            @test_throws ArgumentError IS.validate_metadata(m)
        end
    end

    m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", "single", "outputs.json"))
    @test IS.validate_metadata(m) === nothing
    bad = IS.OutputsMetadata(
        m.schema_version, "simulation", m.producer, m.created_at, m.status, m.systems,
        m.models, IS.NoSimulation(),
    )
    @test_throws ArgumentError IS.validate_metadata(bad)
end

@testset "simulation parameters need kind simulation" begin
    m = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    bad = IS.OutputsMetadata(
        m.schema_version, "single", m.producer, m.created_at, m.status, m.systems,
        m.models, m.simulation,
    )
    @test_throws ArgumentError IS.validate_metadata(bad)
end
