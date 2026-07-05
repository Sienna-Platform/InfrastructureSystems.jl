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
        JSON.parse(io; dicttype = Dict{String, Any})
    end

    @test data["auto_generated_structs"][end]["struct_name"] == "MyComponent"
    @test isfile(joinpath(output_directory, "MyComponent.jl"))
end

@testset "needs_conversion codegen export + getters" begin
    outdir = mktempdir()
    # Build a minimal raw descriptor: one struct with two needs_conversion fields:
    #   "power"  — needs_conversion + exclude_getter (public getter hand-written elsewhere)
    #   "power2" — needs_conversion WITHOUT exclude_getter (generator renders the full
    #              units-getter template block: get_power2(value, units),
    #              get_power2_unitful(value, units), and both display_units_arg methods)
    # We use the same dict shape that structs.json entries use and that
    # generate_structs(directory, data::Vector) consumes directly.
    data = [
        Dict{String, Any}(
            "struct_name" => "TestNeedsConversionStruct",
            "docstring" => "Test struct for needs_conversion codegen.",
            "supertype" => "InfrastructureSystemsComponent",
            "fields" => [
                Dict{String, Any}(
                    "name" => "power",
                    "data_type" => "Float64",
                    "needs_conversion" => true,
                    "exclude_getter" => true,
                    "conversion_unit" => ":system_unit",
                    "null_value" => 0.0,
                ),
                Dict{String, Any}(
                    "name" => "power2",
                    "data_type" => "Float64",
                    "needs_conversion" => true,
                    "conversion_unit" => ":system_unit",
                    "null_value" => 0.0,
                ),
                Dict{String, Any}(
                    "name" => "internal",
                    "data_type" => "InfrastructureSystemsInternal",
                    "internal_default" => "InfrastructureSystemsInternal()",
                ),
            ],
        ),
    ]
    IS.generate_structs(outdir, data; print_results = false)

    gen = read(joinpath(outdir, "TestNeedsConversionStruct.jl"), String)
    # The generated code must parse as valid Julia syntax (covers the units-getter
    # template block rendered for power2).
    @test Meta.parse("begin\n" * gen * "\nend") isa Expr

    # Verify the units-getter template block (lines 66-73 of the template) was rendered
    # for the power2 field (include_getter=true && needs_conversion=true path).
    @test occursin("get_power2(value::TestNeedsConversionStruct, units)", gen)
    @test occursin("get_power2_unitful(value::TestNeedsConversionStruct, units)", gen)
    @test occursin("display_units_arg", gen)

    includes = read(joinpath(outdir, "includes.jl"), String)
    # The base public name is always exported, even when exclude_getter=true
    # (the hand-written getter needs the export)...
    @test occursin("export get_power\n", includes)
    # ...but the `_unitful` companion is deliberately NOT exported for
    # exclude_getter fields (exporting it could break PowerSystems — see the
    # comment at the export gate in generate_structs.jl).
    @test !occursin("export get_power_unitful", includes)
    # The power2 field (include_getter=true) does export its unitful companion.
    @test occursin("export get_power2_unitful", includes)
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
