# Tests `src/outputs/descriptor.jl`

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
        "";
        model = "UC",
        axes = ["execution", "TestComponent", "horizon"],
        axis_lengths = [7, 76, 48],
    )
    @test d.container == "variables" && d.entry_type == "DescPower" &&
          d.component_type == "TestComponent"
    @test d.unit_system == "COMPONENT_BASE" && d.base_reference == "system" &&
          d.units == "pu"
    @test d.layout.chunks == [1, 76, 48] && d.fill_value == "NaN"
    @test d.path == "/UC/datasets/DescPower__TestComponent"
    a = IS.dataset_descriptor(
        DescAngle,
        IS.TestComponent,
        "";
        model = "pf",
        axes = ["time", "TestComponent"],
        axis_lengths = [24, 73],
    )
    @test a.container == "aux_variables" && a.unit_system == "NATURAL_UNITS" &&
          a.base_reference == "" && a.units == "rad"
    @test a.layout.chunks == [24, 73]
    i = IS.dataset_descriptor(
        DescPower,
        IS.TestComponent,
        "m";
        model = "x",
        axes = ["time"],
        axis_lengths = [3],
        dtype = "i64",
    )
    @test i.fill_value === Int64(0) && i.path == "/x/datasets/DescPower__TestComponent__m"
    b = IS.dataset_descriptor(
        DescPower,
        IS.TestComponent,
        "";
        model = "x",
        axes = ["time"],
        axis_lengths = [3],
        dtype = "bool",
    )
    @test b.fill_value === false
    struct DescNoUnits <: IS.Optimization.VariableType end
    IS.Optimization.output_unit_system(::Type{DescNoUnits}) = IS.NU
    IS.Optimization.quantity_kind(::Type{DescNoUnits}) = "Money"
    @test_throws ArgumentError IS.dataset_descriptor(
        DescNoUnits,
        IS.TestComponent,
        "";
        model = "m",
        axes = ["time"],
        axis_lengths = [1],
    )
end

@testset "outputs descriptor: no component and zero-length axes" begin
    struct DescFlag <: IS.Optimization.AuxVariableType end
    IS.Optimization.output_unit_system(::Type{DescFlag}) = IS.NU
    IS.Optimization.quantity_kind(::Type{DescFlag}) = "Dimensionless"
    IS.Optimization.natural_units(::Type{DescFlag}) = "1"
    d = IS.dataset_descriptor(
        DescFlag,
        "";
        model = "pf",
        axes = ["time"],
        axis_lengths = [24],
        dtype = "bool",
    )
    @test d.component_type == "" && d.path == "/pf/datasets/DescFlag"
    @test IS.dataset_name(d) == "DescFlag"
    j = IS.JSON.json(d)
    @test !occursin("component_type", j) && !occursin("base_reference", j)
    m = IS.dataset_descriptor(
        DescFlag, "m"; model = "pf", axes = ["time"], axis_lengths = [24],
    )
    @test m.path == "/pf/datasets/DescFlag__m"
    z = IS.dataset_descriptor(
        DescFlag,
        IS.TestComponent,
        "";
        model = "pf",
        axes = ["execution", "TestComponent"],
        axis_lengths = [0, 0],
    )
    @test z.layout.chunks == [1, 1]
    @test IS._chunk_shape(["time", "x"], [0, 3], 8) == [1, 3]
end

@testset "outputs descriptor: chunk is capped at MAX_CHUNK_BYTES" begin
    @test IS.MAX_CHUNK_BYTES == 64 * 1024 * 1024
    bytes(c, size) = prod(c) * size
    # within the cap: unchanged
    @test IS._chunk_shape(["execution", "c", "horizon"], [7, 76, 48], 8) == [1, 76, 48]
    # over the cap: horizon shrinks first, execution stays 1, component keeps its length
    c = IS._chunk_shape(["execution", "c", "horizon"], [7, 1_000_000, 48], 8)
    @test c == [1, 1_000_000, 8]
    @test bytes(c, 8) <= IS.MAX_CHUNK_BYTES
    # time shrinks before a component axis, whatever the axis order
    c = IS._chunk_shape(["c", "time"], [1_000_000, 100], 8)
    @test c == [1_000_000, 8] && bytes(c, 8) <= IS.MAX_CHUNK_BYTES
    # horizon alone is not enough: the next axis shrinks too
    c = IS._chunk_shape(["execution", "c", "horizon"], [7, 10_000_000, 48], 8)
    @test c == [1, 8_388_608, 1] && bytes(c, 8) <= IS.MAX_CHUNK_BYTES
    # the item size counts
    @test IS._chunk_shape(["time"], [20_000_000], 1) == [20_000_000]
    @test IS._chunk_shape(["time"], [20_000_000], 8) == [8_388_608]
    struct DescBig <: IS.Optimization.VariableType end
    IS.Optimization.output_unit_system(::Type{DescBig}) = IS.SU
    IS.Optimization.quantity_kind(::Type{DescBig}) = "ActivePower"
    d = IS.dataset_descriptor(
        DescBig, IS.TestComponent, ""; model = "m",
        axes = ["execution", "TestComponent", "horizon"],
        axis_lengths = [7, 1_000_000, 48],
    )
    @test d.layout.chunks == [1, 1_000_000, 8]
    @test_throws ArgumentError IS._chunk_shape(["time"], [1, 2], 8)
end
