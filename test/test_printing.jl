@testset "Test printing of the system and components" begin
    sys = create_system_data(;
        with_time_series = true,
        time_series_in_memory = true,
        with_supplemental_attributes = true,
    )
    io = IOBuffer()
    for mime in ("text/plain", "text/html")
        show(io, mime, sys)
        text = String(take!(io))
        @test occursin("TestComponent", text)
        @test occursin("time_series_type", text)
        @test occursin("StaticTimeSeries Summary", text)
        @test occursin("Supplemental Attribute Summary", text)
    end
end

@testset "Test show_component_tables" begin
    sys = create_system_data(;
        with_time_series = true,
        time_series_in_memory = true,
        with_supplemental_attributes = true,
    )
    io = IOBuffer()
    IS.show_components(io, sys.components, IS.TestComponent)
    @test occursin("TestComponent", String(take!(io)))

    IS.show_components(io, sys.components, IS.TestComponent, [:val])
    text = String(take!(io))
    @test occursin("TestComponent", text)
    @test occursin("val", text)

    IS.show_components(io, sys.components, IS.TestComponent, Dict("val" => x -> x.val * 10))
    text = String(take!(io))
    @test occursin("TestComponent", text)
    @test occursin("val", text)

    component = first(IS.get_components(IS.TestComponent, sys))
    io = IOBuffer()
    show(io, "text/plain", component)
    text = String(take!(io))
    @test occursin("TestComponent", text)
    @test occursin("val", text)
    io = IOBuffer()
    show(io, component)
    text = String(take!(io))
    @test occursin("TestComponent", text)
    @test !occursin("val", text)

    @test IS.has_time_series(component)
    io = IOBuffer()
    IS.show_time_series(io, component)
    text = String(take!(io))
    @test occursin("SingleTimeSeries", text)

    @test IS.has_supplemental_attributes(component)
    io = IOBuffer()
    IS.show_supplemental_attributes(io, component)
    text = String(take!(io))
    @test occursin("GeographicInfo", text)
end

@testset "Test printing of internal" begin
    sys = create_system_data(;
        time_series_in_memory = true,
    )
    component = first(IS.get_components(IS.TestComponent, sys))
    internal = IS.get_internal(component)
    io = IOBuffer()
    show(io, "text/plain", internal)
    text = String(take!(io))
    @test occursin("InfrastructureSystemsInternal", text)
    @test occursin("id", text)
    @test !occursin("shared_system_references", text)
end
