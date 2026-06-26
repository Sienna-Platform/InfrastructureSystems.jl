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

# True if the Rust time series backend (the cdylib / TimeSeriesStore_jll) is
# available, so on-disk serialization tests can run. Set TIME_SERIES_STORE_LIB
# for a development cdylib.
function rust_ts_available()
    try
        store = IS.RustTimeSeriesStore(; in_memory = true)
        IS.close!(store)
        return true
    catch
        return false
    end
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
