@testset "Test ForecastCache" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)
    file = joinpath(FORECASTS_DIR, "DateTimeAsColumnDeterministic.csv")
    forecast = IS.Deterministic("test", file, component, Dates.Hour(1))
    initial_timestamp = IS.get_initial_timestamp(forecast)
    initial_times = collect(IS.get_initial_times(forecast))
    interval = IS.get_interval(forecast)
    IS.add_time_series!(sys, component, forecast)

    cache = IS.ForecastCache(IS.Deterministic, component, "test")
    @test cache.in_memory_count == 168
    @test IS.get_next_time(cache) == initial_timestamp
    @test length(cache) == cache.common.num_iterations == 168

    # Iterate over all initial times with default cache size.
    cache = IS.ForecastCache(IS.Deterministic, component, "test")
    for (i, ta) in enumerate(cache)
        it = initial_times[i]
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end

    IS.reset!(cache)
    for it in initial_times
        ta = IS.get_next_time_series_array!(cache)
        @test first(TimeSeries.timestamp(ta)) == it
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end
    @test IS.get_next_time(cache) === nothing

    # Iterate over all initial times with custom cache size.
    cache = IS.ForecastCache(IS.Deterministic, component, "test"; cache_size_bytes = 1024)
    @test length(cache) == cache.common.num_iterations == 168
    for (i, ta) in enumerate(cache)
        it = initial_times[i]
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end

    IS.reset!(cache)
    for it in initial_times
        ta = IS.get_next_time_series_array!(cache)
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end

    # Start at an offset.
    cache = IS.ForecastCache(
        IS.Deterministic,
        component,
        "test";
        start_time = Dates.DateTime("2020-01-02T00:00:00"),
    )
    for (i, ta) in enumerate(cache)
        it = initial_times[i + 24]
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end

    # Test caching internals.
    cache = IS.ForecastCache(IS.Deterministic, component, "test"; cache_size_bytes = 1024)
    @test cache.in_memory_count == 5
    @test IS.get_next_time(cache) == initial_timestamp
    for it in initial_times[1:(cache.in_memory_count)]
        ta = IS.get_next_time_series_array!(cache)
        @test IS._get_last_cached_time(cache) == initial_times[5]
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end

    # The next access should trigger a read.
    ta = IS.get_next_time_series_array!(cache)
    @test IS._get_last_cached_time(cache) == initial_times[10]
    @test TimeSeries.timestamp(ta) ==
          IS.get_time_series_timestamps(component, forecast; start_time = initial_times[6])
    @test TimeSeries.values(ta) ==
          IS.get_time_series_values(component, forecast; start_time = initial_times[6])
    @test IS.get_next_time(cache) == initial_times[7]
end

@testset "Test StaticTimeSeriesCache" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_timestamp = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    len = 96
    data = TimeSeries.TimeArray(
        range(initial_timestamp; length = len, step = resolution),
        rand(len),
    )
    ts = IS.SingleTimeSeries(; data = data, name = "test")
    IS.add_time_series!(sys, component, ts)

    cache = IS.StaticTimeSeriesCache(IS.SingleTimeSeries, component, "test")
    @test cache.in_memory_rows == len
    @test IS.get_next_time(cache) == initial_timestamp
    @test length(cache) == cache.common.num_iterations == len

    # Iterate over all initial times with default cache size.
    cache = IS.StaticTimeSeriesCache(IS.SingleTimeSeries, component, "test")
    for (i, ta) in enumerate(cache)
        it = initial_timestamp + (i - 1) * resolution
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, ts; start_time = it, len = 1)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, ts; start_time = it, len = 1)
    end

    ta = IS.get_next_time_series_array!(cache)
    @test first(TimeSeries.timestamp(ta)) == initial_timestamp
    @test TimeSeries.timestamp(ta) ==
          IS.get_time_series_timestamps(
        component,
        ts;
        start_time = initial_timestamp,
        len = 1,
    )
    @test TimeSeries.values(ta) ==
          IS.get_time_series_values(component, ts; start_time = initial_timestamp, len = 1)

    # Iterate over all initial times with custom cache size.
    cache_size_bytes = 96
    cache = IS.StaticTimeSeriesCache(
        IS.SingleTimeSeries,
        component,
        "test";
        cache_size_bytes = cache_size_bytes,
    )
    @test cache.in_memory_rows == cache_size_bytes / 8
    @test length(cache) == cache.common.num_iterations == len
    ta = IS.get_next_time_series_array!(cache)
    @test first(TimeSeries.timestamp(ta)) == initial_timestamp
    @test length(ta) == 1
    @test TimeSeries.values(ta) == [TimeSeries.values(data)[1]]

    IS.reset!(cache)
    for (i, ta) in enumerate(cache)
        it = initial_timestamp + (i - 1) * resolution
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, ts; start_time = it, len = 1)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, ts; start_time = it, len = 1)
    end

    IS.reset!(cache)
    for i in 1:3
        ta = IS.get_next_time_series_array!(cache)
        it = initial_timestamp + (i - 1) * resolution
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, ts; start_time = it, len = 1)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, ts; start_time = it, len = 1)
    end

    cache_size_bytes = 96
    start_time = Dates.DateTime("2020-09-02T08:00:00")
    cache = IS.StaticTimeSeriesCache(
        IS.SingleTimeSeries,
        component,
        "test";
        start_time = start_time,
        cache_size_bytes = cache_size_bytes,
    )
    @test cache.in_memory_rows == cache_size_bytes / 8
    @test cache.common.num_iterations ==
          len - (start_time - initial_timestamp) / Dates.Millisecond(resolution)
    @test IS._get_length_remaining(cache) == cache.common.num_iterations
    for i in 1:2
        ta = IS.get_next_time_series_array!(cache)
        it = start_time + (i - 1) * resolution
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, ts; start_time = it, len = 1)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, ts; start_time = it, len = 1)
    end
end

@testset "Test DeterministicSingleTimeSeries with ForecastCache" begin
    sys = IS.SystemData()
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-31T23:00:00")
    data = collect(1:length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)
    horizon_count = 24
    horizon = horizon_count * resolution
    interval = Dates.Hour(1)
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )

    forecast = IS.get_time_series(IS.Deterministic, component, name)
    initial_times = collect(IS.get_initial_times(forecast))
    cache =
        IS.ForecastCache(IS.Deterministic, component, name; cache_size_bytes = 1024)

    for (i, ta) in enumerate(cache)
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(
            component,
            forecast;
            start_time = initial_times[i],
        )
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = initial_times[i])
    end
end

@testset "Test Probabilistic with ForecastCache" begin
    initial_time = Dates.DateTime("2020-09-01")
    interval = Dates.Hour(1)
    resolution = Dates.Hour(1)
    name = "test"
    horizon_count = 24
    data = SortedDict{Dates.DateTime, Matrix{Float64}}()
    for (i, it) in enumerate(range(initial_time; step = interval, length = 100))
        data[it] = ones(horizon_count, 99) * i
    end
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Probabilistic(name, data, collect(range(0.01, 0.99; length = 99)), resolution)
    IS.add_time_series!(sys, component, forecast)

    # Iterate over all initial times with custom cache size.
    sz = 1024 * 1024
    cache = IS.ForecastCache(IS.Probabilistic, component, "test"; cache_size_bytes = sz)
    initial_times = collect(keys(data))
    @test cache.in_memory_count == trunc(Int, sz / (99 * 8 * 24))
    for (i, ta) in enumerate(cache)
        it = initial_times[i]
        @test TimeSeries.timestamp(ta) ==
              IS.get_time_series_timestamps(component, forecast; start_time = it)
        @test TimeSeries.values(ta) ==
              IS.get_time_series_values(component, forecast; start_time = it)
    end
end

@testset "Test repeated reads of time series cache" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)
    file = joinpath(FORECASTS_DIR, "DateTimeAsColumnDeterministic.csv")
    resolution = Dates.Hour(1)
    forecast = IS.Deterministic("test", file, component, resolution)
    initial_timestamp = IS.get_initial_timestamp(forecast)
    initial_times = collect(IS.get_initial_times(forecast))
    interval = IS.get_interval(forecast)
    IS.add_time_series!(sys, component, forecast)

    cache = IS.ForecastCache(IS.Deterministic, component, "test")
    @test cache.in_memory_count == 168
    @test IS.get_next_time(cache) == initial_timestamp
    @test length(cache) == cache.common.num_iterations == 168

    for it in initial_times
        expected_timestamps =
            IS.get_time_series_timestamps(component, forecast; start_time = it)
        expected_values = IS.get_time_series_values(component, forecast; start_time = it)
        for _ in 1:2
            ta = IS.get_time_series_array!(cache, it)
            @test TimeSeries.timestamp(ta) ==
                  IS.get_time_series_timestamps(component, forecast; start_time = it)
            @test TimeSeries.values(ta) ==
                  IS.get_time_series_values(component, forecast; start_time = it)
        end
    end

    @test_throws IS.InvalidValue IS.get_time_series_array!(cache, initial_timestamp)
    @test_throws IS.InvalidValue IS.get_time_series_array!(
        cache,
        initial_times[end] + resolution,
    )
    IS.reset!(cache)
    @test_throws IS.InvalidValue IS.get_time_series_array!(
        cache,
        initial_timestamp - resolution,
    )
    IS.get_time_series_array!(cache, initial_timestamp)
    @test_throws IS.InvalidValue IS.get_time_series_array!(cache, initial_times[3])
end
