function create_system_data(;
    with_time_series = false,
    time_series_in_memory = false,
    with_supplemental_attributes = false,
)
    data = IS.SystemData(; time_series_in_memory = time_series_in_memory)

    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(data, component)

    if with_time_series
        # Start at the current day to match the behavior previously provided by the
        # CSV-based `ComponentsAsColumnsNoTime` parser, which some tests rely on.
        sts_resolution = Dates.Hour(1)
        sts_initial_time = Dates.DateTime(Dates.today())
        sts_data = TimeSeries.TimeArray(
            range(sts_initial_time; length = 24, step = sts_resolution),
            ones(24),
        )
        ts = IS.SingleTimeSeries(; name = "val", data = sts_data)
        IS.add_time_series!(data, component, ts)

        resolution = Dates.Hour(1)
        it1 = Dates.DateTime("2020-09-01")
        it2 = it1 + resolution
        name = "test"
        horizon_count = 24
        fdata = SortedDict(it1 => rand(horizon_count), it2 => rand(horizon_count))
        forecast = IS.Deterministic(;
            data = fdata,
            name = name,
            resolution = resolution,
        )
        IS.add_time_series!(data, component, forecast)

        for ts_type in (IS.Deterministic, IS.SingleTimeSeries)
            @assert !isempty(collect(IS.get_time_series_multiple(data; type = ts_type)))
        end
    end

    if with_supplemental_attributes
        geo_info = IS.GeographicInfo()
        IS.add_supplemental_attribute!(data, component, geo_info)
    end

    return data
end

function create_system_data_shared_time_series(;
    time_series_in_memory = false,
)
    data = IS.SystemData(;
        time_series_in_memory = time_series_in_memory,
    )

    name1 = "Component1"
    name2 = "Component2"
    component1 = IS.TestComponent(name1, 5)
    component2 = IS.TestComponent(name2, 6)
    IS.add_component!(data, component1)
    IS.add_component!(data, component2)

    ts = IS.SingleTimeSeries(; name = "val", data = create_time_array())
    IS.add_time_series!(data, component1, ts)
    IS.add_time_series!(data, component2, ts)

    return data
end

function create_time_array()
    dates = collect(
        Dates.DateTime("1/1/2020 00:00:00", "d/m/y H:M:S"):Dates.Hour(1):Dates.DateTime(
            "1/1/2020 23:00:00",
            "d/m/y H:M:S",
        ),
    )
    data = collect(1:24)
    component_name = "gen"
    return TimeSeries.TimeArray(dates, data, [component_name])
end

function create_dates(start_time::Dates.DateTime, resolution, end_time::Dates.DateTime)
    return collect(start_time:resolution:end_time)
end

function create_dates(start_time::String, resolution, end_time::String)
    return create_dates(Dates.DateTime(start_time), resolution, Dates.DateTime(end_time))
end

"""
Verifies that printing an object doesn't crash, which has happened several times.
"""
function verify_show(obj)
    io = IOBuffer()
    show(io, "text/plain", obj)
    val = String(take!(io))
    @test !isempty(val)
    return
end

get_simple_test_components() = [
    IS.TestComponent("DuplicateName", 10),
    IS.TestComponent("Component1", 11),
    IS.TestComponent("Component2", 12),
    IS.AdditionalTestComponent("DuplicateName", 20),
    IS.AdditionalTestComponent("Component3", 23),
    IS.AdditionalTestComponent("Component4", 24),
]

function create_simple_components()
    container = IS.Components(IS.TimeSeriesManager(; in_memory = true))
    IS.add_component!.(Ref(container), get_simple_test_components())
    return container
end

function create_simple_system_data()
    data = IS.SystemData()
    IS.add_component!.(Ref(data), get_simple_test_components())
    return data
end

sort_name!(x) = sort!(collect(x); by = IS.get_name)

# One forecast window of `n` values of the given element type. A key names one
# stored series, so a `TimeSeriesFunctionData{T}` can only wrap a key of `T`
# values — a fixture that always stored `Float64` could only build combinations
# the type system now rejects.
_fixture_window(::Type{Float64}, n) = rand(n)
_fixture_window(::Type{IS.LinearFunctionData}, n) =
    [IS.LinearFunctionData(i, 2i) for i in 1.0:n]
_fixture_window(::Type{IS.QuadraticFunctionData}, n) =
    [IS.QuadraticFunctionData(i, 2i, 3i) for i in 1.0:n]
_fixture_window(::Type{IS.PiecewiseLinearData}, n) =
    [IS.PiecewiseLinearData([(x = 1.0, y = i), (x = 2.0, y = 2i)]) for i in 1.0:n]
_fixture_window(::Type{IS.PiecewiseStepData}, n) =
    [IS.PiecewiseStepData([1.0, 2.0, 3.0], [i, 2i]) for i in 1.0:n]

"""
A system holding one `Deterministic` per name in `names`, returned with the real
`TimeSeriesKey` for each, in order.

A key names a store-minted association id, so tests that exercise real keys need
ones a system actually minted; a fabricated id names nothing the store can read
back.
"""
function create_forecast_key_fixture(
    names...;
    horizon_count = 24,
    element_type::Type = Float64,
)
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)
    initial_time = Dates.DateTime("2020-01-01")
    resolution = Dates.Hour(1)
    keys = map(names) do name
        forecast = IS.Deterministic(;
            data = SortedDict(
                initial_time => _fixture_window(element_type, horizon_count),
            ),
            name = name,
            resolution = resolution,
        )
        return IS.add_time_series!(sys, component, forecast)
    end
    return sys, keys
end
