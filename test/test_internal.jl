@testset "Test integer ID" begin
    component = IS.TestComponent("component", 5)
    # A freshly constructed component has no ID until attached to a system.
    @test IS.get_id(component) == IS.UNASSIGNED_ID
    IS.set_id!(component, 5)
    @test IS.get_id(component) == 5
end

@testset "Test ext" begin
    internal = IS.InfrastructureSystemsInternal()
    @test isnothing(internal.ext)
    ext = IS.get_ext(internal)
    ext["my_value"] = 1
    @test IS.get_ext(internal)["my_value"] == 1

    internal2 = IS.deserialize(IS.InfrastructureSystemsInternal, IS.serialize(internal))
    @test internal.uuid == internal2.uuid
    @test internal.id == internal2.id
    @test internal.ext == internal2.ext

    IS.clear_ext!(internal)
    @test isnothing(internal.ext)
end
