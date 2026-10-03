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
