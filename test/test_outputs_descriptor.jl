# Tests `src/outputs/descriptor.jl`

const _DESC_T0 = Dates.DateTime(2024, 1, 1)
_desc_time_axis(n) = IS.TimeAxis(_DESC_T0, Dates.Hour(1), n)
_desc_execution_axis(n) = IS.ExecutionAxis(_DESC_T0, Dates.Day(1), n)
_desc_horizon_axis(n) = IS.HorizonAxis(Dates.Hour(1), n)
_desc_component_axis(type, n) = IS.ComponentAxis([IS.ComponentAxisColumn(type, true)], n)
_desc_label_axis(name, n) = IS.LabelAxis(name, fill("a", n))

@testset "outputs descriptor: entry built from the traits" begin
    struct DescPower <: IS.Optimization.VariableType end
    struct DescAngle <: IS.Optimization.AuxVariableType end
    IS.Optimization.output_unit_system(::Type{DescPower}) = IS.SU
    IS.Optimization.quantity_kind(::Type{DescPower}) = "ActivePower"
    IS.Optimization.output_unit_system(::Type{DescAngle}) = IS.NU
    IS.Optimization.quantity_kind(::Type{DescAngle}) = "Angle"
    IS.Optimization.natural_units(::Type{DescAngle}) = "rad"
    d = IS.dataset_descriptor(
        DescPower,
        IS.TestComponent,
        "",
        IS.OutputAxis[
            _desc_execution_axis(7),
            _desc_component_axis("TestComponent", 76),
            _desc_horizon_axis(48),
        ],
    )
    @test_throws r"unknown dtype \"f16\"" IS.dataset_descriptor(
        DescPower,
        IS.TestComponent,
        "",
        IS.OutputAxis[
            _desc_execution_axis(7),
            _desc_component_axis("TestComponent", 76),
            _desc_horizon_axis(48),
        ];
        dtype = "f16",
    )
    @test d.container == "variables" &&
          IS.dataset_key(d) == ("DescPower", "TestComponent", "")
    @test IS.unit_system_name(d.unit_system) == "SYSTEM_BASE" && d.units == "pu"
    @test d.chunks == [1, 76, 48] && d.fill_value == "NaN"
    @test d.axes == ["execution", "TestComponent", "horizon"]
    @test IS.dataset_path("UC", d) == "/UC/datasets/DescPower__TestComponent"
    a = IS.dataset_descriptor(
        DescAngle,
        IS.TestComponent,
        "",
        IS.OutputAxis[_desc_time_axis(24), _desc_component_axis("TestComponent", 73)],
    )
    @test a.container == "aux_variables" &&
          IS.unit_system_name(a.unit_system) == "NATURAL_UNITS" && a.units == "rad"
    @test a.chunks == [24, 73]
    i = IS.dataset_descriptor(
        DescPower,
        IS.TestComponent,
        "m",
        [_desc_time_axis(3)];
        dtype = "i64",
    )
    @test i.fill_value === Int64(0) &&
          IS.dataset_path("x", i) == "/x/datasets/DescPower__TestComponent__m"
    b = IS.dataset_descriptor(
        DescPower,
        IS.TestComponent,
        "",
        [_desc_time_axis(3)];
        dtype = "bool",
    )
    @test b.fill_value === false
    struct DescNoUnits <: IS.Optimization.VariableType end
    IS.Optimization.output_unit_system(::Type{DescNoUnits}) = IS.NU
    IS.Optimization.quantity_kind(::Type{DescNoUnits}) = "Money"
    @test_throws ArgumentError IS.dataset_descriptor(
        DescNoUnits,
        IS.TestComponent,
        "",
        [_desc_time_axis(1)],
    )
end

struct NoUnitsVariable <: IS.Optimization.VariableType end
IS.Optimization.output_unit_system(::Type{NoUnitsVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{NoUnitsVariable}) = "Dimensionless"

@testset "a natural units key type without natural_units is an error" begin
    @test_throws r"NoUnitsVariable" IS.dataset_descriptor(
        NoUnitsVariable, "", [_desc_time_axis(2)],
    )
end

@testset "outputs descriptor: no component and zero-length axes" begin
    struct DescFlag <: IS.Optimization.AuxVariableType end
    IS.Optimization.output_unit_system(::Type{DescFlag}) = IS.NU
    IS.Optimization.quantity_kind(::Type{DescFlag}) = "Dimensionless"
    IS.Optimization.natural_units(::Type{DescFlag}) = "1"
    d = IS.dataset_descriptor(DescFlag, "", [_desc_time_axis(24)]; dtype = "bool")
    @test IS.dataset_key(d)[2] == "" && IS.dataset_path("pf", d) == "/pf/datasets/DescFlag"
    @test IS.dataset_name(d) == "DescFlag"
    j = InfrastructureOutputSchemas.encode(IS.to_openapi(d, "pf"))
    @test !haskey(j, "component_type")
    m = IS.dataset_descriptor(DescFlag, "m", [_desc_time_axis(24)])
    @test IS.dataset_path("pf", m) == "/pf/datasets/DescFlag__m"
    z = IS.dataset_descriptor(
        DescFlag,
        IS.TestComponent,
        "",
        IS.OutputAxis[_desc_execution_axis(0), _desc_component_axis("TestComponent", 0)],
    )
    @test z.chunks == [1, 1]
    @test IS._chunk_shape(IS.OutputAxis[_desc_time_axis(0), _desc_label_axis("x", 3)], 8) ==
          [1, 3]
end

@testset "outputs descriptor: chunk is capped at MAX_CHUNK_BYTES" begin
    bytes(c, size) = prod(c) * size
    x, c, h, t = _desc_execution_axis,
    n -> _desc_component_axis("c", n),
    _desc_horizon_axis,
    _desc_time_axis
    # within the cap: unchanged
    @test IS._chunk_shape(IS.OutputAxis[x(7), c(76), h(48)], 8) == [1, 76, 48]
    # over the cap: horizon shrinks first, execution stays 1, component keeps its length
    ch = IS._chunk_shape(IS.OutputAxis[x(7), c(15_625), h(48)], 8)
    @test ch == [1, 15_625, 8]
    @test bytes(ch, 8) <= IS.MAX_CHUNK_BYTES
    # time shrinks before a component axis, whatever the axis order
    ch = IS._chunk_shape(IS.OutputAxis[c(15_625), t(100)], 8)
    @test ch == [15_625, 8] && bytes(ch, 8) <= IS.MAX_CHUNK_BYTES
    # horizon alone is not enough: the next axis shrinks too
    ch = IS._chunk_shape(IS.OutputAxis[x(7), c(156_250), h(48)], 8)
    @test ch == [1, 131_072, 1] && bytes(ch, 8) <= IS.MAX_CHUNK_BYTES
    # the item size counts
    @test IS._chunk_shape(IS.OutputAxis[t(312_500)], 1) == [312_500]
    @test IS._chunk_shape(IS.OutputAxis[t(2), c(2^61)], 8) == [1, 131_072]
    ch = IS._chunk_shape(IS.OutputAxis[c(65_536) for _ in 1:4], 8)
    @test ch == [1, 1, 2, 65_536] && bytes(ch, 8) <= IS.MAX_CHUNK_BYTES
    @test IS._chunk_shape(IS.OutputAxis[t(312_500)], 8) == [131_072]
    struct DescBig <: IS.Optimization.VariableType end
    IS.Optimization.output_unit_system(::Type{DescBig}) = IS.SU
    IS.Optimization.quantity_kind(::Type{DescBig}) = "ActivePower"
    d = IS.dataset_descriptor(
        DescBig, IS.TestComponent, "",
        IS.OutputAxis[x(7), _desc_component_axis("TestComponent", 15_625), h(48)],
    )
    @test d.chunks == [1, 15_625, 8]
end
