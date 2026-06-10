@testset "Test add_supplemental_attribute" begin
    mgr = IS.SupplementalAttributeManager()
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test length(mgr.data) == 1
    @test length(mgr.data[IS.GeographicInfo]) == 1
    @test IS.get_num_attributes(mgr.associations) == 1
    @test_throws ArgumentError IS.add_supplemental_attribute!(
        mgr,
        component,
        geo_supplemental_attribute,
    )
end

@testset "Test bulk addition of supplemental attributes" begin
    mgr = IS.SupplementalAttributeManager()
    attr1 = IS.GeographicInfo(; geo_json = Dict("x" => 1.0))
    attr2 = IS.GeographicInfo(; geo_json = Dict("x" => 2.0))
    component = IS.TestComponent("component1", 1)
    IS.begin_supplemental_attributes_update(mgr) do
        IS.add_supplemental_attribute!(mgr, component, attr1)
        IS.add_supplemental_attribute!(mgr, component, attr2)
    end
    @test length(mgr.data) == 1
    @test length(mgr.data[IS.GeographicInfo]) == 2
    @test IS.get_num_attributes(mgr.associations) == 2
end

@testset "Test bulk addition of supplemental attributes with error" begin
    mgr = IS.SupplementalAttributeManager()
    attr1 = IS.TestSupplemental(; value = 1.0)
    attr2 = IS.GeographicInfo(; geo_json = Dict("x" => 2.0))
    component = IS.TestComponent("component1", 1)
    @test_throws(
        ArgumentError,
        IS.begin_supplemental_attributes_update(mgr) do
            IS.add_supplemental_attribute!(mgr, component, attr1)
            IS.add_supplemental_attribute!(mgr, component, attr2)
            IS.add_supplemental_attribute!(mgr, component, attr2)
        end,
    )
    @test length(mgr.data) == 0
    @test IS.get_num_attributes(mgr.associations) == 0
end

@testset "Test bulk addition of supplemental attributes with error, existing attrs" begin
    mgr = IS.SupplementalAttributeManager()
    attr1 = IS.TestSupplemental(; value = 1.0)
    attr2 = IS.GeographicInfo(; geo_json = Dict("x" => 2.0))
    component = IS.TestComponent("component1", 1)
    IS.begin_supplemental_attributes_update(mgr) do
        IS.add_supplemental_attribute!(mgr, component, attr1)
        IS.add_supplemental_attribute!(mgr, component, attr2)
    end

    attr3 = IS.TestSupplemental(; value = 3.0)
    attr4 = IS.GeographicInfo(; geo_json = Dict("x" => 3.0))
    @test_throws(
        ArgumentError,
        IS.begin_supplemental_attributes_update(mgr) do
            IS.add_supplemental_attribute!(mgr, component, attr3)
            IS.add_supplemental_attribute!(mgr, component, attr4)
            IS.add_supplemental_attribute!(mgr, component, attr4)
        end,
    )
    @test length(mgr.data) == 2
    @test length(mgr.data[IS.TestSupplemental]) == 1
    @test length(mgr.data[IS.GeographicInfo]) == 1
    @test IS.get_num_attributes(mgr.associations) == 2
end

@testset "Test bulk removal of supplemental attributes with error" begin
    mgr = IS.SupplementalAttributeManager()
    attr1 = IS.TestSupplemental(; value = 1.0)
    attr2 = IS.TestSupplemental(; value = 2.0)
    attr3 = IS.GeographicInfo(; geo_json = Dict("x" => 3.0))
    component = IS.TestComponent("component1", 1)
    IS.begin_supplemental_attributes_update(mgr) do
        IS.add_supplemental_attribute!(mgr, component, attr1)
        IS.add_supplemental_attribute!(mgr, component, attr2)
        IS.add_supplemental_attribute!(mgr, component, attr3)
    end

    @test_throws(
        ArgumentError,
        IS.begin_supplemental_attributes_update(mgr) do
            IS.remove_supplemental_attribute!(mgr, component, attr2)
            IS.remove_supplemental_attribute!(mgr, component, attr3)
            IS.remove_supplemental_attribute!(mgr, component, attr3)
        end,
    )
    @test length(mgr.data) == 2
    @test length(mgr.data[IS.TestSupplemental]) == 2
    @test length(mgr.data[IS.GeographicInfo]) == 1
    @test IS.get_num_attributes(mgr.associations) == 3
end

@testset "Test clear_supplemental_attributes" begin
    data = IS.SystemData(; time_series_in_memory = true)
    geo_supplemental_attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 6)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)
    IS.add_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 1

    IS.clear_supplemental_attributes!(component1)
    @test IS.get_num_supplemental_attributes(data) == 1
    IS.clear_supplemental_attributes!(data)
    supplemental_attributes = IS.get_supplemental_attributes(IS.GeographicInfo, data)
    @test IS.get_num_supplemental_attributes(data) == 0
end

@testset "Test remove supplemental_attribute association on remove_component" begin
    data = IS.SystemData(; time_series_in_memory = true)
    mgr = data.supplemental_attribute_manager
    attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 6)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)
    IS.add_supplemental_attribute!(data, component1, attribute)
    IS.add_supplemental_attribute!(data, component2, attribute)
    components = IS.get_components(IS.TestComponent, data)
    @test length(components) == 2
    @test IS.get_num_supplemental_attributes(data) == 1

    IS.remove_component!(data, component1)
    components = IS.get_components(IS.TestComponent, data)
    @test length(components) == 1
    @test IS.get_num_supplemental_attributes(data) == 1
    @test length(
        IS.list_associated_component_uuids(mgr.associations, attribute, nothing),
    ) == 1
end

@testset "Test remove_supplemental_attribute" begin
    mgr = IS.SupplementalAttributeManager()
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test IS.get_num_attributes(mgr.associations) == 1
    @test_throws ArgumentError IS.remove_supplemental_attribute!(
        mgr,
        geo_supplemental_attribute,
    )
    IS.remove_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test_throws ArgumentError IS.remove_supplemental_attribute!(
        mgr,
        component,
        geo_supplemental_attribute,
    )
    @test IS.get_num_attributes(mgr.associations) == 0
    @test_throws ArgumentError IS.get_supplemental_attribute(
        mgr,
        IS.get_uuid(geo_supplemental_attribute),
    )
end

@testset "Test supplemental attribute attached to multiple components" begin
    data = IS.SystemData()
    geo_supplemental_attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 7)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)
    IS.add_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 1

    IS.remove_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 1
    IS.remove_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    @test IS.get_num_supplemental_attributes(data) == 0
end

@testset "Test iterate_SupplementalAttributeManager" begin
    mgr = IS.SupplementalAttributeManager()
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    @test length(collect(IS.iterate_supplemental_attributes(mgr))) == 1
end

@testset "Summarize SupplementalAttributeManager" begin
    mgr = IS.SupplementalAttributeManager()
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_supplemental_attribute!(mgr, component, geo_supplemental_attribute)
    summary(devnull, mgr)
end

@testset "Test supplemental_attributes serialization" begin
    data = IS.SystemData()
    geo_supplemental_attribute = IS.GeographicInfo()
    component = IS.TestComponent("component1", 5)
    IS.add_component!(data, component)
    IS.add_supplemental_attribute!(data, component, geo_supplemental_attribute)
    data = IS.serialize(data.supplemental_attribute_manager)
    @test data isa Dict
    @test length(data["associations"]) == 1
    @test length(data["attributes"]) == 1
end

@testset "Add time series to supplemental_attribute" begin
    data = IS.SystemData()
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    ta = TimeSeries.TimeArray(range(initial_time; length = 24, step = resolution), ones(24))
    ts = IS.SingleTimeSeries(; data = ta, name = "test")
    components = IS.TestComponent[]
    attrs = IS.TestSupplemental[]

    for i in 1:3
        name = "component_$(i)"
        component = IS.TestComponent(name, 5)
        IS.add_component!(data, component)
        supp_attribute = IS.TestSupplemental(; value = Float64(i))
        IS.add_supplemental_attribute!(data, component, supp_attribute)
        IS.add_time_series!(data, supp_attribute, ts)
        push!(components, component)
        push!(attrs, supp_attribute)
    end

    for attribute in IS.iterate_supplemental_attributes(data)
        ts_ = IS.get_time_series(IS.SingleTimeSeries, attribute, "test")
        @test IS.get_initial_timestamp(ts_) == initial_time
    end

    @test length(collect(IS.iterate_supplemental_attributes_with_time_series(data))) == 3
    @test IS.get_num_time_series(data) == 1
    IS.remove_supplemental_attribute!(data, components[1], attrs[1])
    @test IS.get_num_time_series(data) == 1
    IS.remove_supplemental_attribute!(data, components[2], attrs[2])
    @test IS.get_num_time_series(data) == 1
    IS.remove_supplemental_attribute!(data, components[3], attrs[3])
    @test IS.get_num_time_series(data) == 0
end

@testset "Test assign_new_uuid! for component with supplemental attributes" begin
    data = IS.SystemData()
    geo = IS.GeographicInfo()
    other = IS.TestSupplemental(; value = 1.1)
    component1 = IS.TestComponent("component1", 5)
    IS.add_component!(data, component1)
    IS.add_supplemental_attribute!(data, component1, geo)
    IS.add_supplemental_attribute!(data, component1, other)
    IS.assign_new_uuid!(data, component1)
    @test IS.get_supplemental_attribute(component1, IS.get_uuid(geo)) isa IS.GeographicInfo
    @test IS.get_supplemental_attribute(component1, IS.get_uuid(other)) isa
          IS.TestSupplemental
    geo_attrs = collect(IS.get_supplemental_attributes(IS.GeographicInfo, component1))
    @test length(geo_attrs) == 1
    @test geo_attrs[1] == geo
    ts_attrs = collect(IS.get_supplemental_attributes(IS.TestSupplemental, component1))
    @test length(ts_attrs) == 1
    @test ts_attrs[1] == other
end

@testset "Test counts of supplemental attribute" begin
    data = IS.SystemData()
    geo_supplemental_attribute = IS.GeographicInfo()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 7)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)
    IS.add_supplemental_attribute!(data, component1, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(data, component2, geo_supplemental_attribute)
    IS.add_supplemental_attribute!(
        data,
        component1,
        IS.TestSupplemental(; value = Float64(1)),
    )
    IS.add_supplemental_attribute!(
        data,
        component2,
        IS.TestSupplemental(; value = Float64(2)),
    )
    df = IS.get_supplemental_attribute_summary_table(data)
    for (a_type, c_type) in
        zip(("GeographicInfo", "TestSupplemental"), ("TestComponent", "TestComponent"))
        subdf = filter(x -> x.attribute_type == a_type && x.component_type == c_type, df)
        @test DataFrames.nrow(subdf) == 1
        @test subdf[!, "count"][1] == 2
    end

    counts = IS.get_supplemental_attribute_counts_by_type(data)
    types = Set{String}()
    @test length(counts) == 2
    for item in counts
        @test item["count"] == 2
        push!(types, item["type"])
    end
    @test sort!(collect(types)) == ["GeographicInfo", "TestSupplemental"]

    @test IS.get_num_components_with_supplemental_attributes(data) == 2

    # The attributes can be counted in the assocation table or in the attribute dicts.
    @test IS.get_num_supplemental_attributes(data) == 3
    @test IS.get_num_members(data.supplemental_attribute_manager) == 3

    table = Tables.rowtable(
        IS.sql(
            data.supplemental_attribute_manager.associations,
            "SELECT * FROM $(IS.SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME)",
        ),
    )
    @test length(table) == 4
end

@testset "Test optimize_database!" begin
    mgr = IS.SupplementalAttributeManager()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 7)

    # Add several associations to create data for optimization
    for i in 1:10
        attr = IS.TestSupplemental(; value = Float64(i))
        IS.add_supplemental_attribute!(mgr, component1, attr)
        IS.add_supplemental_attribute!(mgr, component2, attr)
    end

    # Verify data was added
    @test IS.get_num_attributes(mgr.associations) == 10

    # Call optimize_database! - should not throw and data should remain intact
    IS.optimize_database!(mgr.associations)

    # Verify data is still accessible after optimization
    @test IS.get_num_attributes(mgr.associations) == 10
    @test IS.has_association(mgr.associations, component1)
    @test IS.has_association(mgr.associations, component2)
end

@testset "get_attr_value(::TestSupplemental)" begin
    attr = IS.TestSupplemental(; value = 42.0)
    @test IS.get_attr_value(attr) == 42.0
end
