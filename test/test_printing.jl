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

@testset "Test show_time_series groups by kind, not by element type" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")
    initial = Dates.DateTime("2020-01-01")
    resolution = Dates.Hour(1)
    IS.add_time_series!(
        sys, component, IS.SingleTimeSeries("floats", initial, resolution, rand(4)),
    )
    IS.add_time_series!(
        sys, component, IS.SingleTimeSeries("ints", initial, resolution, collect(1:4)),
    )
    IS.add_time_series!(
        sys, component,
        IS.SingleTimeSeries(
            "steps", initial, resolution,
            [IS.PiecewiseStepData([1.0, 2.0], [3.0]) for _ in 1:4],
        ),
    )

    io = IOBuffer()
    IS.show_time_series(io, component)
    text = String(take!(io))
    # One table for the kind. The row type is parameterized on the value element
    # type as well, so grouping on it would put each of these three in a table of
    # its own, all titled the same thing.
    @test count("SingleTimeSeries", text) == 1
    @test occursin("floats", text)
    @test occursin("ints", text)
    @test occursin("steps", text)
    # What separates them is a column: the store's own element_type spelling.
    @test occursin("piecewise_step", text)
    @test occursin("i64", text)
    # The content hash is 32 raw bytes and is not one of the columns.
    @test !occursin("UInt8", text)
end

@testset "Test show_components units resolution for Vector columns" begin
    sys = create_system_data(; with_time_series = true, time_series_in_memory = true)
    io = IOBuffer()

    # No override: resolves the column's own `display_units_arg` trait (SU)
    # through its `_unitful` companion, so the cell prints a unit suffix
    # rather than a bare number.
    IS.show_components(io, sys.components, IS.TestComponent, [:val])
    text = String(take!(io))
    @test occursin("SU", text)

    # An explicit `units` override wins over the trait default.
    IS.show_components(io, sys.components, IS.TestComponent, [:val]; units = IS.DU)
    text = String(take!(io))
    @test occursin("DU", text)
    @test !occursin(r"\bSU\b", text)

    # Column order is preserved (not alphabetized) for Vector-form columns,
    # and `val2` (no units trait) is left as a bare, unsuffixed value.
    IS.show_components(io, sys.components, IS.TestComponent, [:val2, :val])
    text = String(take!(io))
    val2_pos = findfirst("val2", text)
    val_pos = findfirst(r"\bval\b", text)
    @test !isnothing(val2_pos) && !isnothing(val_pos)
    @test first(val2_pos) < first(val_pos)

    # A column-to-unit mapping sets units per column; a column missing from the
    # mapping keeps its own trait default rather than inheriting a neighbor's.
    IS.show_components(
        io,
        sys.components,
        IS.TestComponent,
        [:val, :val2];
        units = Dict(:val => IS.DU),
    )
    text = String(take!(io))
    @test occursin("DU", text)
    @test !occursin(r"\bSU\b", text)

    IS.show_components(
        io,
        sys.components,
        IS.TestComponent,
        [:val];
        units = Dict(:val2 => IS.DU),
    )
    text = String(take!(io))
    @test occursin("SU", text)

    # NamedTuple mappings work the same way.
    IS.show_components(io, sys.components, IS.TestComponent, [:val]; units = (val = IS.DU,))
    text = String(take!(io))
    @test occursin("DU", text)

    # `units` is ignored (not an error) for Dict-form additional_columns.
    IS.show_components(
        io,
        sys.components,
        IS.TestComponent,
        Dict("val" => x -> x.val * 10);
        units = IS.DU,
    )
    text = String(take!(io))
    @test occursin("val", text)
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
