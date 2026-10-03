# Labeled value axes on N-D time series, and N-D Deterministic / DST reads.

const _VA_T0 = Dates.DateTime("2024-01-01T00:00:00")

_va_bus_axis(n) = IS.TimeSeriesAxis("bus", collect(101:(100 + n)))

@testset "Test value_axes TimeSeriesAxis construction" begin
    axis = IS.TimeSeriesAxis("bus", Int32[1, 2])
    @test axis.labels isa Vector{Int64}
    @test axis == IS.TimeSeriesAxis("bus", [1, 2])
    @test hash(axis) == hash(IS.TimeSeriesAxis("bus", [1, 2]))
    @test axis != IS.TimeSeriesAxis("bus", ["1", "2"])
    @test IS.TimeSeriesAxis("zone", SubString.(["a", "b"])).labels isa Vector{String}
    # Review focus: a DataFrame column with missing values, or an unsupported label type.
    @test_throws ArgumentError IS.TimeSeriesAxis("bus", [1, missing])
    @test_throws ArgumentError IS.TimeSeriesAxis("bus", [:a, :b])
end

@testset "Test value_axes validation against value dimensions" begin
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), IS.TimeSeriesAxis("bus", [1, 2, 3])]
    @test IS._check_value_axes(axes, (2, 3)) === nothing
    @test IS._check_value_axes(nothing, (2, 3)) === nothing
    @test_throws ArgumentError IS._check_value_axes(axes, (2,))
    @test_throws ArgumentError IS._check_value_axes(axes, (2, 4))
    @test_throws ArgumentError IS._check_value_axes(
        [IS.TimeSeriesAxis("bus", [1, 1])],
        (2,),
    )
    @test_throws ArgumentError IS._check_value_axes(
        [IS.TimeSeriesAxis("x", [1]), IS.TimeSeriesAxis("x", [2])],
        (1, 1),
    )
end

@testset "Test value_axes application_data codec" begin
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), IS.TimeSeriesAxis("bus", [7, 9])]
    encoded = IS._value_axes_application_data(axes)
    @test IS._value_axes_from_application_data(encoded) == axes
    @test IS._value_axes_application_data(nothing) === nothing
    @test IS._value_axes_from_application_data(nothing) === nothing
    # Another client's payload: not JSON, JSON that is not an object, an object without the key.
    @test IS._value_axes_from_application_data("not json {") === nothing
    @test IS._value_axes_from_application_data("[1, 2]") === nothing
    @test IS._value_axes_from_application_data("{\"other\": 1}") === nothing
    # Malformed payloads under IS's own "value_axes" key must error, not silently coerce.
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": \"x\"}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [1]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"labels\": [1]}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"label_type\": \"int\", \"labels\": [1]}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": 123, \"label_type\": \"int\", \"labels\": [1]}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"int\", \"labels\": [\"a\"]}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"float\", \"labels\": [1.5]}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"int\", \"labels\": [1.0]}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": {}}",
    )
    # Labels field must be a list.
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"int\", \"labels\": 5}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"string\", \"labels\": \"abc\"}]}",
    )
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"unknown\", \"labels\": 5}]}",
    )
    # Bool coerces to integer; must error.
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"int\", \"labels\": [true]}]}",
    )
    # Oversized integer (BigInt) must error.
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"int\", \"labels\": [99999999999999999999]}]}",
    )
end

function _va_system(n_owners = 1)
    sys = IS.SystemData()
    owners = [IS.TestComponent("va$i", i) for i in 1:n_owners]
    foreach(owner -> IS.add_component!(sys, owner), owners)
    return sys, owners
end

_va_sts(name, data; value_axes = nothing) =
    IS.SingleTimeSeries(name, _VA_T0, Dates.Hour(1), data; value_axes = value_axes)

# Writes a row straight to the store with an `application_data` the test chooses, as
# another client of the same store would.
function _va_add_raw!(sys, owner, name, data, application_data)
    store = IS.get_data_store(sys)
    owner_id, owner_type, category = IS._infrastore_owner_args(owner)
    raw = IS.InfraStore.SingleTimeSeries(
        _VA_T0, Dates.Hour(1), data, name; application_data = application_data,
    )
    batch = IS.InfraStore.AddBatch()
    IS.InfraStore.add_time_series!(batch, owner_id, owner_type, category, raw)
    IS.InfraStore.add_time_series_bulk!(store.inner, batch)
    IS.flush!(store)
    return
end

@testset "Test value_axes on SingleTimeSeries construction" begin
    data = rand(24, 3)
    ts = _va_sts("f", data; value_axes = [_va_bus_axis(3)])
    @test IS.get_value_axes(ts) == [_va_bus_axis(3)]
    @test IS.get_value_axes(_va_sts("f", data)) === nothing
    @test_throws ArgumentError _va_sts("f", data; value_axes = [_va_bus_axis(4)])
    @test_throws ArgumentError _va_sts("f", rand(24); value_axes = [_va_bus_axis(1)])
    @test IS.get_value_axes(IS.SingleTimeSeries(ts, "g")) == [_va_bus_axis(3)]
    kw = IS.SingleTimeSeries(;
        name = "k",
        data = data,
        initial_timestamp = _VA_T0,
        resolution = Dates.Hour(1),
        value_axes = [_va_bus_axis(3)],
    )
    @test IS.get_value_axes(kw) == [_va_bus_axis(3)]
    # Review focus: time slicing keeps the value axes.
    @test IS.get_value_axes(IS.head(ts, 5)) == [_va_bus_axis(3)]
    @test IS.get_value_axes(IS.tail(ts, 5)) == [_va_bus_axis(3)]
end

@testset "Test value_axes round-trip through the store" begin
    sys, (owner,) = _va_system()
    data = rand(24, 2, 3)
    axes = [IS.TimeSeriesAxis("zone", ["LZ1", "LZ2"]), _va_bus_axis(3)]
    IS.add_time_series!(sys, owner, _va_sts("f", data; value_axes = axes))
    back = IS.get_time_series(IS.SingleTimeSeries, owner, "f")
    @test IS.get_array(back) == data
    @test IS.get_value_axes(back) == axes
    sliced = IS.get_time_series(
        IS.SingleTimeSeries, owner, "f"; start_time = _VA_T0 + Dates.Hour(2), len = 5,
    )
    @test IS.get_array(sliced) == data[3:7, :, :]
    @test IS.get_value_axes(sliced) == axes
    @test IS.get_value_axes(only(IS.list_time_series_metadata(owner))) == axes
end

@testset "Test value_axes with one array shared by several owners" begin
    sys, owners = _va_system(3)
    data = rand(24, 3)
    IS.add_time_series!(
        sys,
        owners[1:2],
        _va_sts("f", data; value_axes = [_va_bus_axis(3)]),
    )
    for owner in owners[1:2]
        back = IS.get_time_series(IS.SingleTimeSeries, owner, "f")
        @test IS.get_value_axes(back) == [_va_bus_axis(3)]
    end
    # Review focus: labels live on each row, so one array can carry different labels.
    other = IS.TimeSeriesAxis("bus", [7, 8, 9])
    IS.add_time_series!(sys, owners[3], _va_sts("f", data; value_axes = [other]))
    @test IS.get_value_axes(IS.get_time_series(IS.SingleTimeSeries, owners[3], "f")) ==
          [other]
    hashes = IS.get_time_series_hashes(owners, IS.SingleTimeSeries, "f")
    @test length(unique(values(hashes))) == 1
    # Review focus: copying a row keeps its labels.
    copy_owner = IS.TestComponent("va_copy", 9)
    IS.add_component!(sys, copy_owner)
    IS.copy_time_series!(copy_owner, owners[1])
    @test IS.get_value_axes(IS.get_time_series(IS.SingleTimeSeries, copy_owner, "f")) ==
          [_va_bus_axis(3)]
end

@testset "Test value_axes leaves another client's application_data alone" begin
    sys, (owner,) = _va_system()
    _va_add_raw!(sys, owner, "foreign", rand(24, 3), "not json {")
    _va_add_raw!(sys, owner, "other_json", rand(24, 3), "{\"other\": 1}")
    for name in ("foreign", "other_json")
        back = IS.get_time_series(IS.SingleTimeSeries, owner, name)
        @test IS.get_value_axes(back) === nothing
    end
    # IS's own key disagreeing with the stored shape is a storage inconsistency.
    bad = IS._value_axes_application_data([_va_bus_axis(4)])
    _va_add_raw!(sys, owner, "bad", rand(24, 3), bad)
    @test_throws ArgumentError IS.get_time_series(IS.SingleTimeSeries, owner, "bad")
end
