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
    @test IS.axis_length(IS.LabelAxis("label", ["a", "b"])) == 2
end

@testset "the outputs fixtures validate" begin
    for name in ("simulation", "single")
        m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", name, "outputs.json"))
        @test IS.validate_metadata(m) === nothing
    end
end

@testset "derived keys are enforced" begin
    m = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    uc = m.models["UC"]
    uc.axes["therm"] = pop!(uc.axes, "ThermalStandard")
    for d in uc.datasets
        replace!(d.axes, "ThermalStandard" => "therm")
    end
    err = try
        IS.validate_metadata(m)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("UC", err.msg) && occursin("therm", err.msg) &&
          occursin("ThermalStandard", err.msg)
end

@testset "every structural rule has a failing case" begin
    base() = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    first_ds(m) = first(m.models["UC"].datasets)
    function with_fields(d; kw...)
        vals = Dict{Symbol, Any}(k => getfield(d, k) for k in fieldnames(IS.OutputDataset))
        merge!(vals, Dict{Symbol, Any}(kw))
        return IS.OutputDataset((vals[k] for k in fieldnames(IS.OutputDataset))...)
    end
    cases = [
        ("axis ref", m -> push!(first_ds(m).axes, "Nope")),
        ("chunk rank", m -> push!(first_ds(m).layout.chunks, 1)),
        ("duplicate tuple", m -> push!(m.models["UC"].datasets, first_ds(m))),
        (
            "missing container",
            m ->
                (m.models["UC"].datasets[1] = with_fields(first_ds(m); container = "")),
        ),
        (
            "bad container",
            m -> (m.models["UC"].datasets[1] =
                    with_fields(first_ds(m); container = "x")),
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
                (m.models["UC"].datasets[1] = with_fields(first_ds(m); path = "/UC/x")),
        ),
        (
            "base unit without reference",
            m -> (
                m.models["UC"].datasets[1] = with_fields(
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
                m.models["UC"].datasets[1] = with_fields(
                    first_ds(m);
                    unit_system = "NATURAL_UNITS",
                    base_reference = "system",
                )
            ),
        ),
        (
            "component_type without component axis",
            m -> (
                m.models["UC"].datasets[1] =
                    with_fields(first_ds(m); axes = ["execution"],
                        layout = IS.DatasetLayout([1], String[]))
            ),
        ),
        (
            "component_type differs from axis",
            m -> (
                m.models["UC"].datasets[1] =
                    with_fields(first_ds(m); component_type = "Other")
            ),
        ),
        (
            "meta with double underscore",
            m -> (m.models["UC"].datasets[1] = with_fields(first_ds(m); meta = "a__b")),
        ),
        (
            "entry_type not a type name",
            m -> (
                m.models["UC"].datasets[1] =
                    with_fields(first_ds(m); entry_type = "bad name")
            ),
        ),
        (
            "axis kind differs from type",
            m -> (m.models["UC"].axes["horizon"] = IS.HorizonAxis("time", "PT1H", 48)),
        ),
        ("system uuid", m -> empty!(m.systems)),
        ("label key", m -> (m.models["UC"].axes["Bad Key"] =
                IS.LabelAxis("label", ["a"]))),
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
        m.models, nothing,
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
