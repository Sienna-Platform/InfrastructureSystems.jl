# Asserts the catalog-backed document rows match the catalog, through the
# `IS.openapi_*_association_*` wrappers.

const _HEX_HASH_RE = r"^[0-9a-f]{64}$"

function _openapi_ts_fixture()
    data = IS.SystemData()
    component = IS.TestComponent("component1", 5)
    IS.add_component!(data, component)
    return data, component
end

_openapi_row_json(data, name; kwargs...) = only(
    filter(
        r -> r["name"] == name,
        JSON.parse(IS.openapi_time_series_association_json(data; kwargs...)),
    ),
)

function _openapi_row(data, name; kwargs...)
    return only(
        filter(
            m -> m.value.name == name,
            IS.openapi_time_series_association_rows(data; kwargs...),
        ),
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
    # Filter pushdown to InfraStore.list_time_series.
    @test length(IS.list_time_series_metadata(data; name = "static")) == 1
    @test only(IS.list_time_series_metadata(data; name = "static")).name == "static"
    @test isempty(IS.list_time_series_metadata(data; name = "nonexistent"))
    @test length(
        IS.list_time_series_metadata(data; time_series_type = IS.InfraStore.Deterministic),
    ) == 1
    @test length(
        IS.list_time_series_metadata(data; owner_category = IS.InfraStore.Component),
    ) == 2
end

@testset "openapi_time_series_association_rows: SingleTimeSeries carries the grid and the element typing" begin
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

    row = _openapi_row(data, "static")
    @test typeof(row) === PowerTimeSeriesOpenAPIModels.SingleTimeSeries
    @test row.time_series_type == "SingleTimeSeries"
    @test row.owner_id == IS.get_id(component)
    @test row.owner_type == "TestComponent"
    @test row.owner_category == "Component"
    @test row.name == "static"
    @test row.resolution == "PT1H"
    @test row.length == 6
    # `uri` and `data_hash` are the store's own content hash, never a caller-supplied
    # locator — the same hex string in both fields.
    @test occursin(_HEX_HASH_RE, row.uri)
    @test row.data_hash == row.uri
    @test row.units == "MW"
    @test row.quantity_kind == "ActivePower"
    # Declared by nobody stays unset: unspecified is deliberately not NATURAL_UNITS.
    @test isnothing(row.unit_system)
    # From the catalog, never re-derived: a scalar series has an empty per-step shape.
    @test row.element_type == "f64"
    @test isempty(row.element_shape)
    @test OpenAPI.check_required(row)
end

@testset "openapi_time_series_association_rows: NonSequentialTimeSeries declares no grid at all" begin
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

    row = _openapi_row(data, "irregular")
    @test typeof(row) === PowerTimeSeriesOpenAPIModels.NonSequentialTimeSeries
    @test row.length == 3
    # ABSENT, not null: an irregular series has no `initial + k * resolution` grid, and the
    # schema says so by not declaring the fields on this type.
    for absent in (:initial_timestamp, :resolution, :horizon, :interval, :count)
        @test !hasfield(typeof(row), absent)
    end
    @test OpenAPI.check_required(row)
end

@testset "openapi_time_series_association_rows: every forecast type carries its own window geometry" begin
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

    det = _openapi_row(data, "det")
    @test typeof(det) === PowerTimeSeriesOpenAPIModels.Deterministic
    @test det.horizon == "PT4H"
    @test det.interval == "PT1H"
    @test det.count == 2
    # A forecast's shape is horizon/interval/count; `length` is not one of its columns.
    @test !hasfield(typeof(det), :length)

    prob = _openapi_row(data, "prob")
    @test typeof(prob) === PowerTimeSeriesOpenAPIModels.Probabilistic
    @test prob.percentiles == [0.1, 0.5, 0.9]
    @test prob.count == 2

    # `scenario_count` is the stored array's leading axis, which the catalog reports as
    # `length` — the same column a Probabilistic spends on its percentile count.
    scen = _openapi_row(data, "scen")
    @test typeof(scen) === PowerTimeSeriesOpenAPIModels.Scenarios
    @test scen.scenario_count == 5
    @test scen.count == 2

    for row in (det, prob, scen)
        @test OpenAPI.check_required(row)
    end
end

@testset "openapi_time_series_association_rows: transform_single_time_series! rows keep their own discriminator, distinct from Deterministic" begin
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

    rows = [row.value for row in IS.openapi_time_series_association_rows(data)]
    derived = only(
        filter(
            r ->
                typeof(r) === PowerTimeSeriesOpenAPIModels.DeterministicSingleTimeSeries,
            rows,
        ),
    )
    # The derived forecast is its own stored type, so it does not collide with a real
    # Deterministic under the discriminator.
    @test derived.time_series_type == "DeterministicSingleTimeSeries"
    @test derived.count == 3
    @test !any(r -> typeof(r) === PowerTimeSeriesOpenAPIModels.Deterministic, rows)
    @test OpenAPI.check_required(derived)
end

@testset "openapi_time_series_association_rows: the unit system a series declares round trips, unset stays absent" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    IS.add_time_series!(
        data, component,
        IS.SingleTimeSeries(
            "series_unset",
            TimeSeries.TimeArray(
                [initial + resolution * (i - 1) for i in 1:3], [1.0, 2.0, 3.0],
            ),
        ),
    )
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
        row = _openapi_row(data, string("series_", spelling))
        @test row.unit_system == spelling
    end
    @test isnothing(_openapi_row(data, "series_unset").unit_system)
end

@testset "openapi_time_series_association_rows: a sub-second resolution round trips through the document" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Millisecond(500)
    IS.add_time_series!(
        data, component,
        IS.SingleTimeSeries(
            "subsecond",
            TimeSeries.TimeArray(
                [initial + resolution * (i - 1) for i in 1:4], collect(1.0:4.0),
            );
            units = "MW", quantity_kind = "ActivePower",
        ),
    )
    row = _openapi_row(data, "subsecond")
    @test row.resolution == "PT0.5S"
    @test OpenAPI.check_required(row)
end

@testset "openapi_time_series_association_json: raw JSON matches the typed rows field-for-field" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    IS.add_time_series!(
        data, component,
        IS.SingleTimeSeries(
            "static", TimeSeries.TimeArray([initial, initial + Dates.Hour(1)], [1.0, 2.0]),
        ),
    )
    raw = _openapi_row_json(data, "static")
    typed = _openapi_row(data, "static")
    @test raw["owner_id"] == typed.owner_id
    @test raw["resolution"] == typed.resolution
    @test raw["uri"] == typed.uri
    @test raw["data_hash"] == typed.data_hash
end

@testset "openapi_time_series_association_rows: export is deterministic regardless of insert order" begin
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    names = ["c", "a", "b"]

    function _build(order)
        data = IS.SystemData()
        component = IS.TestComponent("component1", 5)
        IS.add_component!(data, component)
        for name in order
            IS.add_time_series!(
                data, component,
                IS.SingleTimeSeries(
                    name,
                    TimeSeries.TimeArray(
                        [initial + resolution * (i - 1) for i in 1:3], [1.0, 2.0, 3.0],
                    ),
                ),
            )
        end
        return IS.openapi_time_series_association_json(data)
    end

    # The store assigns `id` from its own rowid counter, so it tracks INSERT order, not sort
    # order — two stores built by inserting the same series in a different sequence get
    # different rowids and are not byte-identical. What "the store sorts" guarantees is the
    # ROW ORDER in the export, by the identity tuple, independent of insertion order.
    forward = [row["name"] for row in JSON.parse(_build(names))]
    shuffled = [row["name"] for row in JSON.parse(_build(reverse(names)))]
    @test forward == shuffled == sort(names)
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

@testset "openapi_supplemental_attribute_association_rows: a shared attribute makes one row per component" begin
    data, first_component, second_component, shared = _openapi_attr_fixture()
    rows = IS.openapi_supplemental_attribute_association_rows(data)
    @test length(rows) == 2
    @test all(
        r -> typeof(r) === PowerCoreOpenAPIModels.SupplementalAttributeAssociation,
        rows,
    )
    # Document/store ids agree by construction now: the association row's ids ARE the IS ids.
    @test Set(r.component_id for r in rows) ==
          Set([IS.get_id(first_component), IS.get_id(second_component)])
    @test all(r -> r.attribute_id == IS.get_id(shared), rows)
    @test all(r -> r.attribute_type == "GeographicInfo", rows)
    @test all(r -> r.component_type == "TestComponent", rows)
    for row in rows
        @test OpenAPI.check_required(row)
    end
end

@testset "list_supplemental_attribute_association_rows reads the whole table" begin
    data, first_component, second_component, shared = _openapi_attr_fixture()
    rows = IS.list_supplemental_attribute_association_rows(data)
    @test length(rows) == 2
    @test all(r -> r.attribute_id == IS.get_id(shared), rows)
    @test Set(r.component_id for r in rows) ==
          Set([IS.get_id(first_component), IS.get_id(second_component)])
    @test all(r -> r.attribute_type == "GeographicInfo", rows)
    @test all(r -> r.component_type == "TestComponent", rows)
end

@testset "import_supplemental_attribute_association_rows!: SA import round trip" begin
    data, first_component, second_component, _shared = _openapi_attr_fixture()
    json = IS.openapi_supplemental_attribute_association_json(data)

    fresh = IS.SystemData()
    IS.add_component!(fresh, IS.TestComponent("component1", 5))
    IS.add_component!(fresh, IS.TestComponent("component2", 6))
    n = IS.import_supplemental_attribute_association_rows!(fresh, json)
    @test n == 2
    @test IS.get_num_associations(fresh.supplemental_attribute_manager.associations) == 2
    reimported = IS.list_supplemental_attribute_association_rows(fresh)
    @test length(reimported) == 2
    @test Set((r.component_id, r.attribute_id) for r in reimported) ==
          Set(
        (r.component_id, r.attribute_id) for
        r in IS.list_supplemental_attribute_association_rows(data)
    )
end

@testset "add_time_series!: a declared scenario_count disagreeing with the data errors loudly and writes nothing" begin
    data, component = _openapi_ts_fixture()
    initial = Dates.DateTime(2024, 1, 1)
    resolution = Dates.Hour(1)
    windows = [initial, initial + resolution]
    # The explicit-`scenario_count` constructor takes the count independently of the
    # per-window matrices, so it can disagree with their actual width (3 here, not 5) —
    # the geometry-vs-association mismatch the store now rejects at addition.
    mismatched = IS.Scenarios(
        "scen_mismatch",
        SortedDict(w => rand(4, 3) for w in windows),
        5,
        resolution,
        resolution,
    )
    @test_throws DimensionMismatch IS.add_time_series!(data, component, mismatched)
    @test isempty(IS.list_time_series_metadata(data))
end

@testset "attach_supplemental_attribute!: attaches in memory without writing an association row" begin
    data, component = _openapi_ts_fixture()
    attribute = IS.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [1.0, 2.0]),
    )
    IS.set_id!(attribute, 12345)
    before = IS.get_num_associations(data.supplemental_attribute_manager.associations)

    IS.attach_supplemental_attribute!(data, component, attribute)

    @test IS.get_num_associations(data.supplemental_attribute_manager.associations) ==
          before
    @test IS.is_attached(attribute, data.supplemental_attribute_manager)
    @test only(collect(IS.iterate_supplemental_attributes(data))) === attribute
end

@testset "attach_supplemental_attribute!: advances next_id past the attribute's id" begin
    data, component = _openapi_ts_fixture()
    attribute = IS.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [1.0, 2.0]),
    )
    IS.set_id!(attribute, 12345)

    IS.attach_supplemental_attribute!(data, component, attribute)

    @test IS.get_next_id!(data) > IS.get_id(attribute)
end

@testset "attach_supplemental_attribute!: errors loudly on an unassigned attribute id" begin
    data, component = _openapi_ts_fixture()
    attribute = IS.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [1.0, 2.0]),
    )
    @test IS.get_id(attribute) == IS.UNASSIGNED_ID
    @test_throws ArgumentError IS.attach_supplemental_attribute!(data, component, attribute)
end

@testset "attach_supplemental_attribute!: respects allow_existing_time_series" begin
    data, component = _openapi_ts_fixture()
    # GeographicInfo does not support time series at all; TestSupplemental does.
    attribute = IS.TestSupplemental(; value = 1.0)
    IS.set_id!(attribute, 55)
    # Simulate an importer adopting a sidecar that already carries a time series owned by
    # this (not-yet-attached) attribute: wire the manager reference the way
    # `attach_supplemental_attribute!` itself would, then add the series through the
    # manager-level API, which needs only an owner id/category, not an association row.
    IS.set_shared_system_references!(
        attribute,
        IS.SharedSystemReferences(;
            supplemental_attribute_manager = data.supplemental_attribute_manager,
            time_series_manager = data.time_series_manager,
        ),
    )
    IS.add_time_series!(
        data.time_series_manager, attribute,
        IS.SingleTimeSeries(
            "static",
            TimeSeries.TimeArray(
                [Dates.DateTime(2024, 1, 1), Dates.DateTime(2024, 1, 1, 1)], [1.0, 2.0],
            ),
        ),
    )
    @test_throws ArgumentError IS.attach_supplemental_attribute!(data, component, attribute)
    IS.attach_supplemental_attribute!(
        data, component, attribute; allow_existing_time_series = true,
    )
    @test IS.is_attached(attribute, data.supplemental_attribute_manager)
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
        @test iszero(
            IS.get_num_associations(data.supplemental_attribute_manager.associations),
        )
    end

    @test IS.get_num_associations(data.supplemental_attribute_manager.associations) == 5
    @test length(IS.list_supplemental_attribute_association_rows(data)) == 5
    for component in components
        @test length(IS.get_supplemental_attributes(component)) == 1
    end
end

@testset "begin_association_batch still rejects a duplicate pair by name" begin
    data, component = _openapi_ts_fixture()
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
    @test iszero(IS.get_num_associations(data.supplemental_attribute_manager.associations))
    # Regression guard for the orphan bug: the first `add_supplemental_attribute!` attaches
    # `shared` to the manager's `mgr.data` before buffering its association row, so without a
    # rollback of the manager too, `shared` would be left attached with no association
    # pointing at it. The SystemData-level `begin_association_batch` wraps the batch in
    # `begin_supplemental_attributes_update`, which must undo that attach on failure.
    @test isempty(collect(IS.iterate_supplemental_attributes(data)))
end

@testset "begin_association_batch does not nest" begin
    data = IS.SystemData()
    @test_throws ErrorException IS.begin_association_batch(data) do
        IS.begin_association_batch(() -> nothing, data)
    end
end
