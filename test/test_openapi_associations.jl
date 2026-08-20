# The catalog-backed document rows: one bulk read per table, and one row type per stored
# time series type. The point of every testset here is that the ROW MATCHES THE CATALOG —
# nothing is re-derived from the series objects, because the columns the schema requires
# (`element_type`, `element_shape`) only the store knows.

const _OPENAPI_TS_ADDRESS = "system_time_series.h5"

function _openapi_ts_fixture()
    data = IS.SystemData()
    component = IS.TestComponent("component1", 5)
    IS.add_component!(data, component)
    return data, component
end

_openapi_row(data, name) = only(
    filter(m -> m.name == name, IS.list_time_series_metadata(data)),
)

function _openapi_convert(data, name; id = 1, owner_id = 1)
    return IS.to_openapi(
        _openapi_row(data, name);
        id = id,
        owner_id = owner_id,
        address = _OPENAPI_TS_ADDRESS,
    ).value
end

@testset "list_time_series_metadata reads every series in one query" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    IS.add_time_series!(
        data, component,
        IS.SingleTimeSeries(
            "static",
            TimeSeries.TimeArray(
                [initial + resolution * (i - 1) for i in 1:6], collect(1.0:6.0),
            ),
        ),
    )
    IS.add_time_series!(
        data, component,
        IS.Deterministic(;
            name = "forecast",
            data = SortedDict(
                initial => collect(1.0:4.0), initial + resolution => collect(5.0:8.0),
            ),
            resolution = resolution,
        ),
    )

    metadata = IS.list_time_series_metadata(data)
    @test length(metadata) == 2
    @test Set(m.name for m in metadata) == Set(["static", "forecast"])
    # The store handle is reachable directly too, for a writer staging into a scratch store
    # before any SystemData exists.
    @test length(IS.list_time_series_metadata(data.time_series_manager.data_store)) == 2
end

@testset "to_openapi: SingleTimeSeries carries the grid and the element typing" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    IS.add_time_series!(
        data, component,
        IS.SingleTimeSeries(
            "static",
            TimeSeries.TimeArray(
                [initial + resolution * (i - 1) for i in 1:6], collect(1.0:6.0),
            );
            units = "MW", quantity_kind = "ActivePower",
        ),
    )

    row = _openapi_convert(data, "static"; id = 42, owner_id = 7)
    @test row isa PowerTimeSeriesOpenAPIModels.SingleTimeSeries
    @test row.time_series_type == "SingleTimeSeries"
    @test row.id == 42
    # The DOCUMENT's owner id, not the store's: the caller owns that mapping.
    @test row.owner_id == 7
    @test row.owner_type == "TestComponent"
    @test row.owner_category == "Component"
    @test row.name == "static"
    @test row.resolution == "PT3600S"
    @test row.length == 6
    @test row.address == _OPENAPI_TS_ADDRESS
    @test row.units == "MW"
    @test row.quantity_kind == "ActivePower"
    # Declared by nobody stays unset: unspecified is deliberately not NATURAL_UNITS.
    @test isnothing(row.unit_system)
    # From the catalog, never re-derived: a scalar series has an empty per-step shape.
    @test row.element_type == "f64"
    @test isempty(row.element_shape)
    @test OpenAPI.check_required(row)
end

@testset "to_openapi: NonSequentialTimeSeries declares no grid at all" begin
    data, component = _openapi_ts_fixture()
    stamps = [
        Dates.DateTime(2024, 1, 1),
        Dates.DateTime(2024, 1, 1, 3),
        Dates.DateTime(2024, 1, 2),
    ]
    IS.add_time_series!(
        data, component,
        IS.NonSequentialTimeSeries(
            "irregular", TimeSeries.TimeArray(stamps, [1.0, 2.0, 3.0]),
        ),
    )

    row = _openapi_convert(data, "irregular")
    @test row isa PowerTimeSeriesOpenAPIModels.NonSequentialTimeSeries
    @test row.length == 3
    # ABSENT, not null: an irregular series has no `initial + k * resolution` grid, and the
    # schema says so by not declaring the fields on this type.
    for absent in (:initial_timestamp, :resolution, :horizon, :interval, :count)
        @test !hasfield(typeof(row), absent)
    end
    @test OpenAPI.check_required(row)
end

@testset "to_openapi: every forecast type carries its own window geometry" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    windows = [initial, initial + Dates.Hour(1)]

    IS.add_time_series!(
        data, component,
        IS.Deterministic(;
            name = "det",
            data = SortedDict(w => collect(1.0:4.0) for w in windows),
            resolution = resolution,
        ),
    )
    IS.add_time_series!(
        data, component,
        IS.Probabilistic(
            "prob",
            SortedDict(w => rand(4, 3) for w in windows),
            [0.1, 0.5, 0.9],
            resolution,
        ),
    )
    IS.add_time_series!(
        data, component,
        IS.Scenarios("scen", SortedDict(w => rand(4, 5) for w in windows), resolution),
    )

    det = _openapi_convert(data, "det")
    @test det isa PowerTimeSeriesOpenAPIModels.Deterministic
    @test det.horizon == "PT14400S"
    @test det.interval == "PT3600S"
    @test det.count == 2
    # A forecast's shape is horizon/interval/count; `length` is not one of its columns.
    @test !hasfield(typeof(det), :length)

    prob = _openapi_convert(data, "prob")
    @test prob isa PowerTimeSeriesOpenAPIModels.Probabilistic
    @test prob.percentiles == [0.1, 0.5, 0.9]
    @test prob.count == 2

    # `scenario_count` is the stored array's leading axis, which the catalog reports as
    # `length` — the same column a Probabilistic spends on its percentile count.
    scen = _openapi_convert(data, "scen")
    @test scen isa PowerTimeSeriesOpenAPIModels.Scenarios
    @test scen.scenario_count == 5
    @test scen.count == 2

    for row in (det, prob, scen)
        @test OpenAPI.check_required(row)
    end
end

@testset "to_openapi: transform_single_time_series! rows keep their own discriminator" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    IS.add_time_series!(
        data, component,
        IS.SingleTimeSeries(
            "static",
            TimeSeries.TimeArray(
                [initial + resolution * (i - 1) for i in 1:4], collect(1.0:4.0),
            ),
        ),
    )
    IS.transform_single_time_series!(data, IS.DeterministicSingleTimeSeries,
        Dates.Hour(2), Dates.Hour(1))

    rows = [
        IS.to_openapi(m; id = i, owner_id = 1, address = _OPENAPI_TS_ADDRESS).value
        for (i, m) in enumerate(IS.list_time_series_metadata(data))
    ]
    derived = only(
        filter(r -> r isa PowerTimeSeriesOpenAPIModels.DeterministicSingleTimeSeries, rows),
    )
    # The derived forecast is its own stored type, so it does not collide with a real
    # Deterministic under the discriminator.
    @test derived.time_series_type == "DeterministicSingleTimeSeries"
    @test derived.count == 3
    @test OpenAPI.check_required(derived)
end

@testset "to_openapi: the unit system a series declares round trips" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    for (basis, spelling) in ((IS.NU, "NATURAL_UNITS"), (IS.DU, "COMPONENT_BASE"))
        IS.add_time_series!(
            data, component,
            IS.SingleTimeSeries(
                string("series_", spelling),
                TimeSeries.TimeArray(
                    [initial + resolution * (i - 1) for i in 1:3], [1.0, 2.0, 3.0],
                );
                unit_system = basis,
            ),
        )
        row = _openapi_convert(data, string("series_", spelling))
        @test row.unit_system == spelling
    end
end

function _openapi_attr_fixture()
    data = IS.SystemData()
    first_component = IS.TestComponent("component1", 5)
    second_component = IS.TestComponent("component2", 6)
    IS.add_component!(data, first_component)
    IS.add_component!(data, second_component)
    shared = IS.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [1.0, 2.0]),
    )
    IS.add_supplemental_attribute!(data, first_component, shared)
    IS.add_supplemental_attribute!(data, second_component, shared)
    return data, first_component, second_component, shared
end

@testset "to_openapi: a supplemental attribute association row" begin
    data, first_component, _second, shared = _openapi_attr_fixture()
    rows = IS.list_supplemental_attribute_association_rows(data)
    row = only(filter(r -> r.component_id == IS.get_id(first_component), rows))

    # Document ids, not store ids: an attribute's document id is assigned fresh from the
    # document counter, so neither end is read off the row.
    assoc = IS.to_openapi(row; attribute_id = 77, entity_id = 3)
    @test assoc isa PowerCoreOpenAPIModels.SupplementalAttributeAssociation
    @test assoc.attribute_id == 77
    @test assoc.entity_id == 3
    # `attribute_type` DOES come off the row — the store recorded it at attach time, so it
    # matches the attribute without being re-derived from the object.
    @test assoc.attribute_type == "GeographicInfo"
    @test assoc.attribute_type == string(nameof(typeof(shared)))
    @test OpenAPI.check_required(assoc)
end

@testset "to_openapi: one attribute shared by two components makes two rows" begin
    data, first_component, second_component, _shared = _openapi_attr_fixture()
    rows = IS.list_supplemental_attribute_association_rows(data)
    # One attribute, two attachments: the association table is what fans out, and the
    # document's attribute id is shared across both rows.
    assocs = [
        IS.to_openapi(r; attribute_id = 50, entity_id = Int(r.component_id)) for r in rows
    ]
    @test length(assocs) == 2
    @test all(a -> a.attribute_id == 50, assocs)
    @test Set(a.entity_id for a in assocs) ==
          Set([IS.get_id(first_component), IS.get_id(second_component)])
    @test all(a -> a.attribute_type == "GeographicInfo", assocs)
end

@testset "begin_association_batch defers the inserts and writes them once" begin
    data = IS.SystemData()
    components = [IS.TestComponent("component$i", i) for i in 1:5]
    for component in components
        IS.add_component!(data, component)
    end

    IS.begin_association_batch(data) do
        for (i, component) in enumerate(components)
            IS.add_supplemental_attribute!(
                data, component,
                IS.GeographicInfo(;
                    geo_json = Dict("type" => "Point", "coordinates" => [Float64(i), 0.0]),
                ),
            )
        end
        # WRITE-ONLY while open: the store has not been touched yet, so a count still reads
        # zero. This is the documented limit, asserted so it cannot drift silently.
        @test IS.get_num_associations(data.supplemental_attribute_manager.associations) == 0
    end

    @test IS.get_num_associations(data.supplemental_attribute_manager.associations) == 5
    @test length(IS.list_supplemental_attribute_association_rows(data)) == 5
    for component in components
        @test length(IS.get_supplemental_attributes(component)) == 1
    end
end

@testset "begin_association_batch still rejects a duplicate pair by name" begin
    data = IS.SystemData()
    component = IS.TestComponent("component1", 5)
    IS.add_component!(data, component)
    shared = IS.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [1.0, 2.0]),
    )
    # The probe reads the pending buffer as well as the store, so the second attach of the
    # same pair is caught here — with the objects named — rather than at flush by the store.
    @test_throws ArgumentError IS.begin_association_batch(data) do
        IS.add_supplemental_attribute!(data, component, shared)
        IS.add_supplemental_attribute!(data, component, shared)
    end
    # The failed batch wrote nothing, so there is no half-applied association table.
    @test IS.get_num_associations(data.supplemental_attribute_manager.associations) == 0
end

@testset "begin_association_batch does not nest" begin
    data = IS.SystemData()
    @test_throws ErrorException IS.begin_association_batch(data) do
        IS.begin_association_batch(() -> nothing, data)
    end
end

@testset "list_supplemental_attribute_association_rows reads the whole table" begin
    data = IS.SystemData()
    first_component = IS.TestComponent("component1", 5)
    second_component = IS.TestComponent("component2", 6)
    IS.add_component!(data, first_component)
    IS.add_component!(data, second_component)
    # One attribute shared by two components: two rows, one attribute.
    shared = IS.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [1.0, 2.0]),
    )
    IS.add_supplemental_attribute!(data, first_component, shared)
    IS.add_supplemental_attribute!(data, second_component, shared)

    rows = IS.list_supplemental_attribute_association_rows(data)
    @test length(rows) == 2
    @test all(r -> r.attribute_id == IS.get_id(shared), rows)
    @test Set(r.component_id for r in rows) ==
          Set([IS.get_id(first_component), IS.get_id(second_component)])
    @test all(r -> r.attribute_type == "GeographicInfo", rows)
    @test all(r -> r.component_type == "TestComponent", rows)
end
