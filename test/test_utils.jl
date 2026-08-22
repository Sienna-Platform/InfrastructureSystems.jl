@testset "Test utility functions" begin
    concrete_types = IS.get_all_concrete_subtypes(IS.InfrastructureSystemsComponent)
    @test length([x for x in concrete_types if isconcretetype(x)]) == length(concrete_types)
end

@testset "Test strip_module_name" begin
    @test IS.strip_module_name("PowerSystems.HydroDispatch") == "HydroDispatch"

    @test IS.strip_module_name(
        "InfrastructureSystems.SingleTimeSeries{PowerSystems.HydroDispatch}",
    ) == "SingleTimeSeries{PowerSystems.HydroDispatch}"

    @test IS.strip_module_name("SingleTimeSeries{PowerSystems.HydroDispatch}") ==
          "SingleTimeSeries{PowerSystems.HydroDispatch}"
end

@testset "Test exported names" begin
    @test IS.validate_exported_names(IS)
end

IS.@scoped_enum Fruit APPLE = 1 ORANGE = 2

@testset "Test scoped_enum correctness" begin
    @test Fruit.APPLE isa Fruit
    @test Fruit.ORANGE isa Fruit
    @test sort([Fruit.ORANGE, Fruit.APPLE]) == [Fruit.APPLE, Fruit.ORANGE]

    @kwdef struct Foo
        fruit::Fruit
    end
    @test Foo(1) == Foo(Fruit.APPLE)

    @test IS.serialize(Fruit.APPLE) isa AbstractString
    @test IS.deserialize(Fruit, IS.serialize(Fruit.APPLE)) == Fruit.APPLE

    @test IS.deserialize_struct(Foo, IS.serialize_struct(Foo(Fruit.APPLE))) ==
          Foo(Fruit.APPLE)
end

@testset "Test scoped_enum performance" begin
    is_apple(x::Fruit) = x == Fruit.APPLE
    function f()
        @test (@allocated Fruit.APPLE) == 0
        @test (@allocated instances(Fruit)) == 0

        rng = Random.Xoshiro(47)
        my_fruits = [rand(rng, instances(Fruit)) for _ in 1:1_000]
        my_results = Vector{Bool}(undef, length(my_fruits))
        # Ref(x) rather than [x] is necessary to avoid spurious allocation
        @test (@allocated my_results .= (my_fruits .== Ref(Fruit.APPLE))) == 0
        # After compilation, here is observed the most drastic difference between the Dict-based implementation and the multiple dispach-based one:
        @test (@allocated my_results .= is_apple.(my_fruits)) == 0
        @test (@allocated my_results .= (my_fruits .< Ref(Fruit.ORANGE))) == 0
        @test (@allocated my_fruits .= Fruit.(3 .- getproperty.(my_fruits, :value))) == 0
        @test (@allocated(
            my_fruits .= convert.(Fruit, 3 .- getproperty.(my_fruits, :value)))) == 0
    end
    f()
    f()
end

@testset "Test undef component prints" begin
    v = Vector{IS.InfrastructureSystemsComponent}(undef, 3)
    @test sprint(show, v) ==
          "InfrastructureSystems.InfrastructureSystemsComponent[#undef, #undef, #undef]"
end

struct FakeTimeSeries <: InfrastructureSystems.TimeSeriesData{Float64} end
Base.length(::FakeTimeSeries) = 42
IS.get_name(::FakeTimeSeries) = "fake"

@testset "Test TimeSeriesData printing" begin
    @test occursin(
        "FakeTimeSeries: fake",
        sprint(show, MIME("text/plain"), summary(FakeTimeSeries())),
    )
end
