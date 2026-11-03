@testset "ForecastCache sizes a single window" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("cache-sizing", 1)
    IS.add_component!(sys, component)
    name = "bounded-sizing"
    resolution = Dates.Minute(5)
    start = Dates.DateTime("2026-01-01T04:05:00")
    horizon_count = 2
    data = SortedDict(
        time => Float64[i, i + 1] for
        (i, time) in enumerate(range(start; step = resolution, length = 9))
    )
    IS.add_time_series!(sys, component, IS.Deterministic(name, data, resolution))

    offset = 3
    initial_time = start + offset * resolution
    cache = IS.ForecastCache(
        IS.Deterministic,
        component,
        name;
        start_time = initial_time,
        cache_size_bytes = 2 * horizon_count * sizeof(Float64),
    )
    sample = IS._get_time_series(cache)
    # sample must be read before the first get_time_series_array! call, which replaces it.
    @test IS.get_count(sample) == 1
    @test length(cache) == 9 - offset
    @test cache.in_memory_count == 2

    actual = IS.get_time_series_array!(cache, initial_time)
    @test vec(TimeSeries.values(actual)) == Float64[offset + 1, offset + 2]
end
