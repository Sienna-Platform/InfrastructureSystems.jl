function validate_serialization(sys::IS.SystemData; time_series_read_only = false)
    directory = mktempdir()
    filename = joinpath(directory, "test_system_serialization.json")
    IS.prepare_for_serialization_to_file!(sys, filename; force = true)
    data = IS.serialize(sys)
    open(filename, "w") do io
        JSON3.write(io, data)
    end

    # Make sure the code supports the files changing directories.
    test_dir = mktempdir(directory)
    path = mv(filename, joinpath(test_dir, basename(filename)))

    @test haskey(data, "time_series_storage_file") ==
          !isempty(sys.time_series_manager.data_store)
    t_file =
        joinpath(directory, splitext(basename(path))[1] * "_" * IS.TIME_SERIES_STORAGE_FILE)
    if haskey(data, "time_series_storage_file")
        dst_file = joinpath(test_dir, basename(t_file))
        mv(t_file, dst_file)
    else
        @test !isfile(t_file)
    end

    data = open(path) do io
        return JSON3.read(io, Dict)
    end

    orig = pwd()
    try
        cd(dirname(path))
        sys2 =
            IS.deserialize(
                IS.SystemData,
                data;
                time_series_read_only = time_series_read_only,
            )
        # Deserialization of components should be directed by the parent of SystemData.
        # There isn't one in IS, so perform the deserialization in the test code.
        for component in data["components"]
            type = IS.get_type_from_serialization_data(component)
            comp = IS.deserialize(type, component)
            IS.add_component!(sys2, comp; allow_existing_time_series = true)
        end
        return sys2, IS.compare_values(sys, sys2; compare_uuids = true)
    finally
        cd(orig)
    end
end

@testset "Test deserialization type matching" begin
    nt_data = Dict("max" => 1.1, "min" => 0.9)
    nt_type = @NamedTuple{min::Float64, max::Float64}
    nt_result = (min = 0.9, max = 1.1)
    @test IS.deserialize(Union{Float64, nt_type}, nt_data) == nt_result
    @test IS.deserialize(Union{Float64, nt_type}, 4.0) == 4.0
    @test IS.deserialize(Union{Nothing, nt_type}, nt_data) == nt_result
    @test IS.deserialize(Union{Nothing, nt_type}, nothing) === nothing
    @test IS.deserialize(Union{Float64, Dict}, nt_data) == nt_data
    @test_throws ArgumentError IS.deserialize(Union{nt_type, Dict}, nt_data)
end

@testset "Test Vector{Complex} Serialization/Deserialization" begin
    nt_data = [
        Dict("real" => 1.1, "imag" => 0.9),
        Dict("real" => 0.0, "imag" => 0.1),
        Dict("real" => 0.1, "imag" => 0.0),
    ]
    nt_type = Vector{Complex{Float64}}
    nt_result = [1.1 + 0.9im, 0.0 + 0.1im, 0.1 + 0.0im]
    @test IS.deserialize(nt_type, nt_data) == nt_result
    @test IS.serialize(nt_result) == nt_data
end

@testset "Test Vector{Base.UUID} Serialization/Deserialization" begin
    uuids = [Base.UUID(rand(UInt128)) for _ in 1:3]
    serialized = IS.serialize(uuids)
    @test serialized isa Vector{<:Dict}
    @test all(d -> haskey(d, "value"), serialized)
    deserialized = IS.deserialize(Vector{Base.UUID}, serialized)
    @test deserialized isa Vector{Base.UUID}
    @test deserialized == uuids
    # Round-trip through JSON to mimic on-disk format.
    json_round_trip = JSON3.read(JSON3.write(serialized), Vector{Dict})
    @test IS.deserialize(Vector{Base.UUID}, json_round_trip) == uuids
end

@testset "Test JSON serialization of system data" begin
    for in_memory in (true, false)
        sys = create_system_data_shared_time_series(; time_series_in_memory = in_memory)
        _, result = validate_serialization(sys)
        @test result
    end
end

@testset "Test prepare_for_serialization_to_file" begin
    sys = create_system_data_shared_time_series()
    directory = joinpath(mktempdir(), "dir2")
    IS.prepare_for_serialization_to_file!(sys, joinpath(directory, "sys.json"))
    @test IS.get_ext(sys.internal)[IS.SERIALIZATION_METADATA_KEY]["serialization_directory"] ==
          directory
end

function _make_time_series()
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    data = TimeSeries.TimeArray(
        range(initial_time; length = 2, step = resolution),
        ones(2),
    )
    data = IS.SingleTimeSeries(; data = data, name = "ts")
end

@testset "Test JSON serialization of with read-only time series" begin
    sys = create_system_data_shared_time_series(; time_series_in_memory = false)
    sys2, result = validate_serialization(sys; time_series_read_only = true)
    @test result

    component = first(IS.get_components(IS.TestComponent, sys2))
    @test_throws ArgumentError IS.add_time_series!(sys, component, _make_time_series())
end

@testset "Test JSON serialization of with mutable time series" begin
    sys = create_system_data_shared_time_series(; time_series_in_memory = false)
    sys2, result = validate_serialization(sys; time_series_read_only = false)
    @test result
    component = first(IS.get_components(IS.TestComponent, sys2))
    IS.add_time_series!(sys2, component, _make_time_series())
end

@testset "Test JSON serialization with no time series" begin
    sys = create_system_data(; with_time_series = false)
    sys2, result = validate_serialization(sys)
    @test result
end

@testset "Test JSON serialization with supplemental attributes" begin
    sys = IS.SystemData()
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    ta = TimeSeries.TimeArray(range(initial_time; length = 24, step = resolution), rand(24))
    ts = IS.SingleTimeSeries(; data = ta, name = "test")
    geo = IS.GeographicInfo(; geo_json = Dict("x" => 1.0, "y" => 2.0))

    for i in 1:2
        name = "component_$(i)"
        component = IS.TestComponent(name, 5)
        IS.add_component!(sys, component)
        attr = IS.TestSupplemental(; value = Float64(i))
        IS.add_supplemental_attribute!(sys, component, attr)
        IS.add_time_series!(sys, attr, ts)
        IS.add_supplemental_attribute!(sys, component, geo)
    end

    sys2, result = validate_serialization(sys)
    @test result
    attrs = collect(IS.get_supplemental_attributes(IS.TestSupplemental, sys2))
    @test length(attrs) == 2
    for attr in attrs
        @test IS.has_time_series(IS.SingleTimeSeries, attr)
        ts2 = IS.get_time_series(IS.SingleTimeSeries, attr, "test")
        @test ts2.data == ta
    end
end

@testset "Test version info" begin
    data = IS.serialize_julia_info()
    @test haskey(data, "julia_version")
    @test haskey(data, "package_info")
end

@testset "Test JSON string" begin
    component = IS.SimpleTestComponent("Component1", 1)
    text = IS.to_json(component)
    IS.deserialize(IS.SimpleTestComponent, JSON3.read(text, Dict)) == component
end

@testset "Test pretty-print JSON IO" begin
    component = IS.SimpleTestComponent("Component1", 2)
    io = IOBuffer()
    IS.to_json(io, component; pretty = false)
    text = String(take!(io))
    @test !occursin(" ", text)
    IS.deserialize(IS.SimpleTestComponent, JSON3.read(text, Dict)) == component

    io = IOBuffer()
    IS.to_json(io, component; pretty = true)
    text = String(take!(io))
    @test occursin(" ", text)
    IS.deserialize(IS.SimpleTestComponent, JSON3.read(text, Dict)) == component
end

@testset "Test ext serialization" begin
    @test IS.is_ext_valid_for_serialization(nothing)
    @test IS.is_ext_valid_for_serialization(1)
    @test IS.is_ext_valid_for_serialization("test")
    @test IS.is_ext_valid_for_serialization([1, 2, 3])
    @test IS.is_ext_valid_for_serialization(Dict("a" => 1, "b" => 2, "c" => 3))

    struct MyType
        func::Function
    end

    @test(
        @test_logs(
            (:error, r"only basic types are allowed"),
            match_mode = :any,
            !IS.is_ext_valid_for_serialization(MyType(println))
        )
    )
end

@testset "Test serialization of subsystems" begin
    sys = IS.SystemData(; time_series_in_memory = true)

    components = IS.TestComponent[]
    for i in 1:4
        name = "component_$i"
        component = IS.TestComponent(name, i)
        IS.add_component!(sys, component)
        push!(components, component)
    end

    subsystems = String[]
    for i in 1:2
        name = "subsystem_$i"
        IS.add_subsystem!(sys, name)
        push!(subsystems, name)
    end

    IS.add_component_to_subsystem!(sys, subsystems[1], components[1])
    IS.add_component_to_subsystem!(sys, subsystems[1], components[2])
    IS.add_component_to_subsystem!(sys, subsystems[2], components[3])
    IS.add_component_to_subsystem!(sys, subsystems[2], components[4])

    sys2, result = validate_serialization(sys)
    @test length(IS.get_subsystems(sys2)) == 2
    @test IS.get_assigned_subsystems(sys2, components[4]) == ["subsystem_2"]
end

@testset "Test serialization of deserialized system" begin
    sys = create_system_data(; with_time_series = true, with_supplemental_attributes = true)
    sys2, result = validate_serialization(sys)
    @test result
    _, result = validate_serialization(sys2)
    @test result
end
