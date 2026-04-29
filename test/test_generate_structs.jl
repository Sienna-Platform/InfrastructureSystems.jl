@testset "Test generated structs" begin
    descriptor_file = joinpath(@__DIR__, "..", "src", "descriptors", "structs.json")
    existing_dir = joinpath(@__DIR__, "..", "src", "generated")
    @test IS.test_generated_structs(descriptor_file, existing_dir)
end

@testset "Test generated structs from StructDefinition" begin
    orig_descriptor_file = joinpath(@__DIR__, "..", "src", "descriptors", "structs.json")
    output_directory = mktempdir()
    descriptor_file = joinpath(output_directory, "structs.json")
    cp(orig_descriptor_file, descriptor_file)
    # This is necessary in cases where the package has been added through a GitHub branch
    # where all source files are read-only.
    chmod(descriptor_file, 0o644)
    new_struct = IS.StructDefinition(;
        struct_name = "MyComponent",
        docstring = "Custom component",
        supertype = "InfrastructureSystemsComponent",
        fields = [
            IS.StructField(; name = "val1", data_type = Float64),
            IS.StructField(; name = "val2", data_type = Int),
            IS.StructField(; name = "val3", data_type = String),
        ],
    )
    redirect_stdout(devnull) do
        IS.generate_struct_file(
            new_struct;
            filename = descriptor_file,
            output_directory = output_directory,
        )
    end
    data = open(descriptor_file, "r") do io
        JSON3.read(io, Dict)
    end

    @test data["auto_generated_structs"][end]["struct_name"] == "MyComponent"
    @test isfile(joinpath(output_directory, "MyComponent.jl"))
end

@testset "conversion_unit validator rejects non-constant expressions" begin
    @test IS._validate_conversion_unit(":active_power") == ":active_power"
    @test IS._validate_conversion_unit("nothing") == "nothing"
    @test IS._validate_conversion_unit("PowerSystems.PowerUnits.MW") ==
          "PowerSystems.PowerUnits.MW"
    @test_throws ErrorException IS._validate_conversion_unit("foo(bar)")
    @test_throws ErrorException IS._validate_conversion_unit("[1, 2]")
    @test_throws ErrorException IS._validate_conversion_unit("a + b")
    @test_throws ErrorException IS._validate_conversion_unit("a*b")
    @test_throws ErrorException IS._validate_conversion_unit("a,b")
    @test_throws ErrorException IS._validate_conversion_unit("\$var")
    @test_throws ErrorException IS._validate_conversion_unit(".mva")
    @test_throws ErrorException IS._validate_conversion_unit("trailing.")
end

@testset "Test StructField errors" begin
    @test_throws ErrorException IS.StructDefinition(
        struct_name = "MyStruct",
        fields = [
            IS.StructField(;
                name = "val",
                data_type = Float64,
                valid_range = "invalid_field",
            ),
        ],
    )
    @test_throws ErrorException IS.StructField(
        name = "val",
        data_type = Float64,
        valid_range = Dict("min" => 0, "invalid" => 100),
    )
    @test_throws ErrorException IS.StructField(
        name = "val",
        data_type = Float64,
        valid_range = Dict("min" => 0, "max" => 100),
        validation_action = "invalid",
    )
end
