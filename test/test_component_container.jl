# Tests parts of `src/component_container.jl`; subtype implementations are tested elsewhere

@testset "Test default availability behavior" begin
    cse(x, y) = (sort_name!(x) == sort_name!(y))  # collect, sort, equality
    @testset for test_sys in [create_simple_components(), create_simple_system_data()]
        component1 = IS.get_component(IS.TestComponent, test_sys, "Component1")
        test_id = IS.get_id(component1)
        test_type_sel = IS.TypeComponentSelector(IS.TestComponent, :all, nothing)
        test_name_sel = IS.NameComponentSelector(IS.TestComponent, "Component1", nothing)

        @test cse(IS.get_available_components(IS.TestComponent, test_sys),
            IS.get_components(IS.TestComponent, test_sys))
        @test cse(IS.get_available_components(x -> true, IS.TestComponent, test_sys),
            IS.get_components(x -> true, IS.TestComponent, test_sys))
        @test cse(IS.get_available_components(test_type_sel, test_sys),
            IS.get_components(test_type_sel, test_sys))

        if test_sys isa IS.SystemData
            @test IS.get_available_component(test_sys, test_id) ==
                  IS.get_component(test_sys, test_id)
            geo_supplemental_attribute = IS.GeographicInfo()
            IS.add_supplemental_attribute!(test_sys, component1, geo_supplemental_attribute)
        end

        @test IS.get_available_component(IS.TestComponent, test_sys, "Component1") ==
              IS.get_component(IS.TestComponent, test_sys, "Component1")
        @test IS.get_available_component(test_name_sel, test_sys) ==
              IS.get_component(test_name_sel, test_sys)

        @test sort!(collect(IS.get_available_groups(test_type_sel, test_sys))) ==
              sort!(collect(IS.get_groups(test_type_sel, test_sys)))
    end
end
