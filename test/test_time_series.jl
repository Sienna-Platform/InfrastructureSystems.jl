@testset "Test add forecasts on the fly from dict" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data =
        SortedDict(initial_time => rand(horizon_count), other_time => rand(horizon_count))

    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution)
    key = IS.add_time_series!(sys, component, forecast)
    @test key isa IS.ForecastKey
    @test key.name == name
    @test key.horizon == horizon_count * resolution
    @test key.resolution == resolution
    var1 =
        IS.get_time_series(IS.Deterministic, component, name; start_time = initial_time)
    @test length(var1) == 2
    @test IS.get_horizon_count(var1) == horizon_count
    @test IS.get_initial_timestamp(var1) == initial_time

    var2 = IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = initial_time,
        count = 2,
    )
    @test length(var2) == 2

    var3 =
        IS.get_time_series(IS.Deterministic, component, name; start_time = other_time)
    @test length(var2) == 2
    # Throws errors
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = initial_time,
        count = 3,
    )
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = other_time,
        count = 2,
    )
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = other_time + resolution,
    )

    count = IS.get_count(var2)
    @test count == 2

    window1 = IS.get_window(var2, initial_time)
    @test window1 isa TimeSeries.TimeArray
    @test TimeSeries.timestamp(window1)[1] == initial_time
    window2 = IS.get_window(var2, other_time)
    @test window2 isa TimeSeries.TimeArray
    @test TimeSeries.timestamp(window2)[1] == other_time

    found = 0
    for ta in IS.iterate_windows(var2)
        @test ta isa TimeSeries.TimeArray
        found += 1
        if found == 1
            @test TimeSeries.timestamp(ta)[1] == initial_time
        else
            @test TimeSeries.timestamp(ta)[1] == other_time
        end
    end
    @test found == count

    @test IS.get_uuid(forecast) == IS.get_uuid(var1)
    @test IS.get_uuid(forecast) == IS.get_uuid(var2)
end

@testset "Test add Deterministic" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data = Dict(initial_time => rand(horizon_count), other_time => rand(horizon_count))
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Deterministic(name, data, resolution)
    @test IS.get_initial_timestamp(forecast) == initial_time
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)

    data_ts = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            rand(horizon_count),
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            rand(horizon_count),
        ),
    )
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Deterministic(name, data_ts)
    @test IS.get_initial_timestamp(forecast) == initial_time
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)

    data_ts_two_cols = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            rand(horizon_count, 2),
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            rand(horizon_count, 2),
        ),
    )
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    @test_throws ArgumentError IS.Deterministic(name, data_ts_two_cols)

    invalid_horizon_count = SortedDict(initial_time => rand(1), other_time => rand(1))
    forecast = IS.Deterministic(;
        data = invalid_horizon_count,
        name = name,
        resolution = resolution,
    )
    @test_throws ArgumentError IS.add_time_series!(sys, component, forecast)
end

@testset "Test add forecast with different horizons" begin
    sys = IS.SystemData()
    name = "Component"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    resolution = Dates.Hour(1)
    initial_time = Dates.DateTime("2020-01-01")
    horizon_count = 24

    name = "test1"
    data = SortedDict(
        initial_time => rand(24),
        initial_time + Dates.Hour(1) => rand(24),
        initial_time + Dates.Hour(2) => rand(25),
    )
    forecast = IS.Deterministic(name, data, resolution)
    @test_throws DimensionMismatch IS.add_time_series!(sys, component, forecast)
end

@testset "Test add forecast with invalid horizon" begin
    sys = IS.SystemData()
    name = "Component"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    resolution = Dates.Hour(1)
    initial_time = Dates.DateTime("2020-01-01")
    horizon_count = 1

    name = "test1"
    data = SortedDict(
        initial_time => rand(horizon_count),
        initial_time + Dates.Hour(1) => rand(horizon_count),
    )
    forecast = IS.Deterministic(name, data, resolution)
    @test_throws ArgumentError IS.add_time_series!(sys, component, forecast)
end

@testset "Test add forecast with inconsistent interval" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    initial_time = Dates.DateTime("2020-01-01")
    horizon_count = 24

    name = "test1"
    one_dim_data = SortedDict(
        initial_time => rand(horizon_count),
        initial_time + Dates.Hour(1) => rand(horizon_count),
        initial_time + Dates.Hour(3) => rand(horizon_count),
    )
    two_dim_data = SortedDict(
        initial_time => rand(horizon_count, 99),
        initial_time + Dates.Hour(1) => rand(horizon_count, 99),
        initial_time + Dates.Hour(3) => rand(horizon_count, 99),
    )

    deterministic = IS.Deterministic(name, one_dim_data, resolution)
    probabilistic = IS.Probabilistic(name, two_dim_data, rand(99), resolution)
    scenarios = IS.Scenarios(name, two_dim_data, resolution)
    for forecast in (deterministic, probabilistic, scenarios)
        @test_throws IS.ConflictingInputsError IS.add_time_series!(sys, component, forecast)
    end
end

@testset "Test add forecast with irregular resolution and interval" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    resolution = Dates.Month(1)
    horizon_count = 12
    interval = Dates.Month(2)
    t1 = Dates.DateTime("2020-01-01")
    t2 = t1 + interval
    t3 = t2 + interval

    one_dim_data = Dict(
        t1 => TimeSeries.TimeArray(
            range(t1; length = horizon_count, step = resolution),
            rand(horizon_count),
        ),
        t2 => TimeSeries.TimeArray(
            range(t2; length = horizon_count, step = resolution),
            rand(horizon_count),
        ),
        t3 => TimeSeries.TimeArray(
            range(t3; length = horizon_count, step = resolution),
            rand(horizon_count),
        ),
    )
    two_dim_data = SortedDict(
        t1 => TimeSeries.TimeArray(
            range(t1; length = horizon_count, step = resolution),
            rand(horizon_count, 99),
        ),
        t2 => TimeSeries.TimeArray(
            range(t2; length = horizon_count, step = resolution),
            rand(horizon_count, 99),
        ),
        t3 => TimeSeries.TimeArray(
            range(t2; length = horizon_count, step = resolution),
            rand(horizon_count, 99),
        ),
    )

    for with_resolution in (false, true), with_interval in (false, true)
        name = "test_$(with_resolution)_$(with_interval)"
        kwargs = Dict{Symbol, Any}()
        if with_resolution
            kwargs[:resolution] = resolution
        end
        if with_interval
            kwargs[:interval] = interval
        end
        if with_resolution && with_interval
            deterministic = IS.Deterministic(name, one_dim_data; kwargs...)
            probabilistic = IS.Probabilistic(name, two_dim_data, rand(99); kwargs...)
            scenarios = IS.Scenarios(name, two_dim_data; kwargs...)
            for forecast in (deterministic, probabilistic, scenarios)
                IS.add_time_series!(sys, component, forecast)
            end
        elseif with_resolution && !with_interval
            deterministic = IS.Deterministic(name, one_dim_data; kwargs...)
            probabilistic = IS.Probabilistic(name, two_dim_data, rand(99); kwargs...)
            scenarios = IS.Scenarios(name, two_dim_data; kwargs...)
        else
            @test_throws IS.ConflictingInputsError IS.Deterministic(
                name,
                one_dim_data;
                kwargs...,
            )
            @test_throws IS.ConflictingInputsError IS.Probabilistic(
                name,
                two_dim_data,
                rand(99);
                kwargs...,
            )
            @test_throws IS.ConflictingInputsError IS.Scenarios(
                name,
                two_dim_data;
                kwargs...,
            )
        end
    end
end

@testset "Test add Deterministic with different resolutions" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution1 = Dates.Minute(5)
    other_time1 = initial_time + resolution1
    horizon_count = 24
    resolution2 = Dates.Minute(10)
    other_time2 = initial_time + resolution2
    horizon_count2 = 12

    name1 = "test1"
    data1 = SortedDict(
        initial_time => rand(horizon_count),
        other_time1 => rand(horizon_count),
    )
    name2 = "test2"
    data2 = SortedDict(
        initial_time => rand(horizon_count2),
        other_time2 => rand(horizon_count2),
    )

    forecast1 = IS.Deterministic(; data = data1, name = name1, resolution = resolution1)
    forecast2 = IS.Deterministic(; data = data2, name = name2, resolution = resolution2)
    key1 = IS.add_time_series!(sys, component, forecast1)
    key2 = IS.add_time_series!(sys, component, forecast2)
    @test key1.horizon == horizon_count * resolution1
    @test key2.horizon == horizon_count2 * resolution2

    resolution3 = Dates.Minute(11)
    other_time3 = initial_time + resolution3
    horizon_count3 = 13
    name3 = "test3"
    data3 = SortedDict(
        initial_time => rand(horizon_count3),
        other_time3 => rand(horizon_count3),
    )
    forecast3 = IS.Deterministic(; data = data3, name = name3, resolution = resolution3)
    key3 = IS.add_time_series!(sys, component, forecast3)
    @test key3.horizon == horizon_count3 * resolution3
end

@testset "Test add Deterministic Cost Timeseries" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    linear_cost = repeat([IS.LinearFunctionData(3.14, 1.23)], 24)
    data_linear = SortedDict(initial_time => linear_cost, other_time => linear_cost)
    polynomial_cost = repeat([IS.QuadraticFunctionData(999.0, 1.0, 0.5)], 24)
    data_polynomial =
        SortedDict(initial_time => polynomial_cost, other_time => polynomial_cost)
    pwl_cost = repeat([IS.PiecewiseLinearData(repeat([(999.0, 1.0)], 5))], 24)
    data_pwl = SortedDict(initial_time => pwl_cost, other_time => pwl_cost)
    for d in [data_linear, data_polynomial, data_pwl]
        @testset "Add deterministic from $(typeof(d))" begin
            sys = IS.SystemData()
            component_name = "Component1"
            component = IS.TestComponent(component_name, 5)
            IS.add_component!(sys, component)
            forecast = IS.Deterministic(name, d, resolution)
            @test IS.get_initial_timestamp(forecast) == initial_time
            IS.add_time_series!(sys, component, forecast)
            @test IS.has_time_series(component)
        end
    end

    data_ts_linear = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            linear_cost,
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            linear_cost,
        ),
    )
    data_ts_polynomial = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            polynomial_cost,
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            polynomial_cost,
        ),
    )
    data_ts_pwl = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            pwl_cost,
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            pwl_cost,
        ),
    )
    for d in [data_ts_linear, data_ts_polynomial, data_ts_pwl]
        @testset "Add deterministic from $(typeof(d))" begin
            sys = IS.SystemData()
            component_name = "Component1"
            component = IS.TestComponent(component_name, 5)
            IS.add_component!(sys, component)
            forecast = IS.Deterministic(name, d)
            @test IS.get_initial_timestamp(forecast) == initial_time
            IS.add_time_series!(sys, component, forecast)
            @test IS.has_time_series(component)
        end
    end
end

@testset "Test add Probabilistic" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data_vec =
        Dict(initial_time => ones(horizon_count, 99), other_time => ones(horizon_count, 99))
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Probabilistic(name, data_vec, ones(99), resolution)
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)
    @test IS.get_initial_timestamp(forecast) == initial_time
    forecast_retrieved =
        IS.get_time_series(
            IS.Probabilistic,
            component,
            "test";
            start_time = initial_time,
        )
    @test IS.get_initial_timestamp(forecast_retrieved) == initial_time

    data_ts = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            ones(horizon_count, 99),
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            ones(horizon_count, 99),
        ),
    )
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Probabilistic(name, data_ts, ones(99))
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)
    @test IS.get_initial_timestamp(forecast) == initial_time
end

@testset "Test add Scenarios" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data_vec =
        Dict(initial_time => ones(horizon_count, 99), other_time => ones(horizon_count, 99))
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Scenarios(name, data_vec, resolution)
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)
    @test IS.get_initial_timestamp(forecast) == initial_time
    forecast_retrieved =
        IS.get_time_series(IS.Scenarios, component, "test"; start_time = initial_time)
    @test IS.get_initial_timestamp(forecast_retrieved) == initial_time

    data_ts = Dict(
        initial_time => TimeSeries.TimeArray(
            range(initial_time; length = horizon_count, step = resolution),
            ones(horizon_count, 2),
        ),
        other_time => TimeSeries.TimeArray(
            range(other_time; length = horizon_count, step = resolution),
            ones(horizon_count, 2),
        ),
    )
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Scenarios(name, data_ts)
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)
    @test IS.get_initial_timestamp(forecast) == initial_time
end

function _test_add_single_time_series_helper(component, initial_time)
    ts1 = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "test_c";
        start_time = initial_time,
        len = 12,
    )
    @test length(IS.get_data(ts1)) == 12
    ts2 = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "test_c";
        start_time = initial_time + Dates.Day(1),
        len = 12,
    )
    @test length(IS.get_data(ts2)) == 12
    ts3 = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "test_c";
        start_time = initial_time + Dates.Day(1),
    )
    @test length(IS.get_data(ts3)) == 341
end

@testset "Test add SingleTimeSeries" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    data = TimeSeries.TimeArray(
        range(initial_time; length = 365, step = resolution),
        ones(365),
    )
    ts_name = "test_c"
    data = IS.SingleTimeSeries(; data = data, name = ts_name)
    IS.add_time_series!(sys, component, data)

    _test_add_single_time_series_helper(component, initial_time)

    #Throws errors
    @test_throws ArgumentError IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "test_c";
        start_time = initial_time,
        len = 1200,
    )
    @test_throws ArgumentError IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "test_c";
        start_time = initial_time - Dates.Day(10),
        len = 12,
    )

    ts = IS.SingleTimeSeries(;
        data = TimeSeries.TimeArray(
            [
                Dates.DateTime(2020, 1, 1),
                Dates.DateTime(2020, 1, 2),
                Dates.DateTime(2020, 1, 4),
            ],
            [1.0, 2.0, 3.0],
        ),
        name = "test",
    )
    @test_throws IS.ConflictingInputsError IS.add_time_series!(sys, component, ts)

    # As of PSY 4.0, multiple resolutions are supported.
    data = TimeSeries.TimeArray(
        range(initial_time; length = 365, step = Dates.Minute(5)),
        ones(365),
    )
    data = IS.SingleTimeSeries(; data = data, name = "test_d")
    IS.add_time_series!(sys, component, data)
end

@testset "Test add SingleTimeSeries with irregular resolution." begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-01-01")
    resolution = Dates.Month(1)

    data = TimeSeries.TimeArray(range(initial_time; length = 12, step = resolution), 1:12)
    ts_name = "ts"

    # resolution must be passed for irregular time series.
    ts_invalid = IS.SingleTimeSeries(; data = data, name = ts_name)
    @test_throws IS.ConflictingInputsError IS.add_time_series!(sys, component, ts_invalid)

    ts1 = IS.SingleTimeSeries(; data = data, name = ts_name, resolution = resolution)
    IS.add_time_series!(sys, component, ts1)

    ts2_full = IS.get_time_series(IS.SingleTimeSeries, component, ts_name)
    @test IS.get_data(ts2_full) == IS.get_data(ts1)

    ts2_partial = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name;
        start_time = initial_time + resolution * 6,
        len = 6,
    )
    @test IS.get_data(ts2_partial) == IS.get_data(ts1)[7:end]
end

@testset "Test add SingleTimeSeries with features" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    data = TimeSeries.TimeArray(
        range(initial_time; length = 365, step = resolution),
        rand(365),
    )
    ts_name = "test_c"
    ts = IS.SingleTimeSeries(; data = data, name = ts_name)
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = "2030")
    # get_time_series with partial query works if there is only 1.
    @test IS.get_time_series(IS.SingleTimeSeries, component, ts_name).data == data
    @test IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name;
        scenario = "low",
    ).data == data
    @test IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name;
        scenario = "low",
        model_year = "2030",
    ).data == data
    @test IS.get_time_series_values(
        IS.SingleTimeSeries,
        component,
        ts_name;
        scenario = "low",
        model_year = "2030",
    ) == TimeSeries.values(data)
    @test IS.get_time_series_timestamps(
        IS.SingleTimeSeries,
        component,
        ts_name;
        scenario = "low",
        model_year = "2030",
    ) == TimeSeries.timestamp(data)

    IS.add_time_series!(sys, component, ts; scenario = "high", model_year = "2030")
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = "2035")
    IS.add_time_series!(sys, component, ts; scenario = "high", model_year = "2035")

    @test_throws ArgumentError IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name,
    )
    @test_throws ArgumentError IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name,
        scenario = "low",
    )
    @test IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name;
        scenario = "low",
        model_year = "2035",
    ) isa IS.SingleTimeSeries
    @test IS.has_time_series(component, IS.SingleTimeSeries)
    @test IS.has_time_series(component, IS.SingleTimeSeries, ts_name)
    @test IS.has_time_series(component; name = ts_name)
    @test IS.has_time_series(component; name = ts_name, resolution = resolution)
    @test IS.has_time_series(component, IS.SingleTimeSeries, ts_name, scenario = "low")
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name,
        resolution = resolution,
        scenario = "low",
    )
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name,
        model_year = "2030",
        scenario = "low",
    )
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name,
        model_year = "2030",
        scenario = "low",
    )
    @test !IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        model_year = "2060",
        scenario = "low",
    )
    @test length(IS.get_time_series_keys(component)) == 4
    @test IS.get_time_series_type(IS.get_time_series_keys(component)[1]) ===
          IS.SingleTimeSeries
    @test Tables.rowtable(
        IS.sql(
            sys.time_series_manager.metadata_store,
            "SELECT COUNT (DISTINCT metadata_uuid) AS count FROM $(IS.ASSOCIATIONS_TABLE_NAME)",
        ),
    )[1].count == 4
    for key in IS.get_time_series_keys(component)
        @test IS.get_data(IS.get_time_series(component, key)) == data
    end
    IS.remove_time_series!(sys, IS.SingleTimeSeries)
    @test isempty(IS.get_time_series_keys(component))
    @test isempty(sys.time_series_manager.metadata_store.metadata_uuids)
end

@testset "Test add with features with mixed types" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    data = TimeSeries.TimeArray(
        range(initial_time; length = 365, step = resolution),
        rand(365),
    )
    ts_name = "test"
    ts = IS.SingleTimeSeries(; data = data, name = ts_name)
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = "2030")
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        scenario = "low",
        model_year = "2030",
    )
    @test !IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        scenario = "low",
        model_year = 2030,
    )
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = 2030)
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        scenario = "low",
        model_year = 2030,
    )
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = 2035)
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        scenario = "low",
        model_year = 2035,
    )
    @test !IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        scenario = "low",
        model_year = "2035",
    )
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = "2035")
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        scenario = "low",
        model_year = "2035",
    )
    IS.add_time_series!(sys, component, ts; scenario = "low", some_condition = true)
    @test IS.has_time_series(component, IS.SingleTimeSeries, ts_name; some_condition = true)
    @test !IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        some_condition = "true",
    )
    IS.add_time_series!(sys, component, ts; scenario = "low", some_condition = "false")
    @test !IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        some_condition = false,
    )
    IS.add_time_series!(sys, component, ts; scenario = "low", some_condition = false)
    @test IS.has_time_series(
        component,
        IS.SingleTimeSeries,
        ts_name;
        some_condition = false,
    )
    @test_throws MethodError IS.add_time_series!(
        sys,
        component,
        ts;
        scenario = Dict("key" => "val"),
    )
    # Duplicate features in different order.
    @test_throws ArgumentError IS.add_time_series!(
        sys,
        component,
        ts;
        scenario = "low",
        model_year = "2035",
    )
    @test_throws ArgumentError IS.add_time_series!(
        sys,
        component,
        ts;
        model_year = "2035",
        scenario = "low",
    )
end

@testset "Test add Deterministic with features" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    other_time = initial_time + resolution
    ts_name = "test"
    horizon_count = 24
    data =
        SortedDict(initial_time => rand(horizon_count), other_time => rand(horizon_count))

    forecast = IS.Deterministic(; data = data, name = ts_name, resolution = resolution)
    IS.add_time_series!(sys, component, forecast; scenario = "low", model_year = "2030")
    IS.add_time_series!(
        sys,
        component,
        forecast;
        scenario = "high",
        model_year = "2030",
    )
    IS.add_time_series!(sys, component, forecast; scenario = "low", model_year = "2035")
    IS.add_time_series!(
        sys,
        component,
        forecast;
        scenario = "high",
        model_year = "2035",
    )

    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        ts_name,
    )
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        ts_name,
        scenario = "low",
    )
    @test IS.get_time_series(
        IS.Deterministic,
        component,
        ts_name;
        scenario = "low",
        model_year = "2035",
    ) isa IS.Deterministic
    @test length(IS.get_time_series_metadata(component)) == 4
    @test length(
        IS.get_time_series_metadata(component; time_series_type = IS.Deterministic),
    ) == 4
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            name = ts_name,
        ),
    ) == 4
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            name = ts_name,
            scenario = "low",
        ),
    ) == 2
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            name = ts_name,
            scenario = "low",
            model_year = "2035",
        ),
    ) == 1
    @test IS.get_time_series_metadata(
        component;
        time_series_type = IS.Deterministic,
        name = ts_name,
        scenario = "low",
        model_year = "2035",
    )[1].features["model_year"] == "2035"
    @test length(IS.get_time_series_keys(component)) == 4
    @test IS.get_time_series_type(IS.get_time_series_keys(component)[1]) ===
          IS.Deterministic

    IS.remove_time_series!(sys, IS.Deterministic, component, ts_name; scenario = "low")
    @test length(
        IS.get_time_series_metadata(component; time_series_type = IS.Deterministic),
    ) == 2
    for metadata in
        IS.get_time_series_metadata(component; time_series_type = IS.Deterministic)
        @test metadata.features["scenario"] == "high"
    end
    IS.remove_time_series!(sys, IS.Deterministic, component, ts_name)
    @test isempty(IS.get_time_series_metadata(component))
end

@testset "Test Deterministic with a wrapped SingleTimeSeries" begin
    # for in_memory in (true, false)
    for in_memory in (true,)
        sys = IS.SystemData(; time_series_in_memory = in_memory)

        # This is allowed when there are no time series.
        IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            Dates.Hour(24),
            Dates.Hour(24),
        )

        component = IS.TestComponent("Component1", 5)
        IS.add_component!(sys, component)

        resolution = Dates.Minute(5)
        dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:05:00")
        data = collect(1:length(dates))
        ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
        name = "val"
        ts = IS.SingleTimeSeries(name, ta)
        IS.add_time_series!(sys, component, ts)
        horizon_count = 6
        horizon = horizon_count * resolution
        verify_show(sys)

        # Create a Deterministic as a bystander.
        forecast_count = 46
        fdata = SortedDict{Dates.DateTime, Vector{Float64}}()
        for i in 1:forecast_count
            fdata[dates[i]] = ones(horizon_count)
        end
        bystander =
            IS.Deterministic(;
                data = fdata,
                name = "bystander",
                resolution = resolution,
            )
        IS.add_time_series!(sys, component, bystander)

        counts = IS.get_time_series_counts(sys)
        @test counts.components_with_time_series == 1
        @test counts.supplemental_attributes_with_time_series == 0
        @test counts.static_time_series_count == 1
        @test counts.forecast_count == 1

        # This interval is greater than the max possible.
        @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            Dates.Hour(100),
        )
        interval = Dates.Minute(30)
        IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            interval,
        )
        verify_show(sys)

        counts = IS.get_time_series_counts(sys)
        @test counts.components_with_time_series == 1
        @test counts.supplemental_attributes_with_time_series == 0
        @test counts.static_time_series_count == 1
        @test counts.forecast_count == 2

        # The original should still be readable.
        single_vals = IS.get_time_series_values(IS.SingleTimeSeries, component, name)
        @test single_vals == data

        @test IS.get_time_series(IS.Deterministic, component, "bystander") isa
              IS.Deterministic

        # Get the transformed forecast.
        forecast = IS.get_time_series(IS.DeterministicSingleTimeSeries, component, name)
        @test IS.get_horizon(forecast) == horizon
        @test IS.get_interval(forecast) == interval
        window = IS.get_window(forecast, dates[1])
        @test window isa TimeSeries.TimeArray
        @test TimeSeries.timestamp(window) == TimeSeries.timestamp(ta[1:horizon_count])
        @test TimeSeries.values(window) == TimeSeries.values(ta[1:horizon_count])

        windows = collect(IS.iterate_windows(forecast))
        # Note that there is an extra 5 minutes being truncated.
        exp_length = Dates.Hour(dates[end - 1] - first(dates)).value * 2
        @test length(windows) == exp_length
        last_initial_time = dates[end - 1] - interval
        last_it_index = length(dates) - 1 - Int(Dates.Minute(interval) / resolution)
        @test last_initial_time == dates[last_it_index]
        last_val_index = last_it_index + horizon_count - 1
        @test TimeSeries.values(windows[exp_length]) ==
              data[last_it_index:last_val_index]

        # Do the same thing but pass Deterministic instead.
        forecast = IS.get_time_series(IS.Deterministic, component, name)
        window = IS.get_window(forecast, dates[1])
        @test window isa TimeSeries.TimeArray
        @test TimeSeries.timestamp(window) == TimeSeries.timestamp(ta[1:horizon_count])
        @test TimeSeries.values(window) == TimeSeries.values(ta[1:horizon_count])

        # Verify that get_time_series_multiple works with these types.
        forecasts = collect(IS.get_time_series_multiple(sys))
        @test length(forecasts) == 3
        forecasts = collect(IS.get_time_series_multiple(sys; type = IS.Deterministic))
        @test length(forecasts) == 2
        forecasts =
            collect(
                IS.get_time_series_multiple(
                    sys;
                    type = IS.DeterministicSingleTimeSeries,
                ),
            )
        @test length(forecasts) == 1
        @test forecasts[1] isa IS.DeterministicSingleTimeSeries

        # Must start on a window.
        @test_throws ArgumentError IS.get_time_series(
            IS.Deterministic,
            component,
            name;
            start_time = dates[2],
        )
        # Must pass a full horizon.
        @test_throws ArgumentError IS.get_time_series(
            IS.Deterministic,
            component,
            name;
            len = horizon_count - 1,
        )
        # Already stored.
        @test IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            interval,
        ) === nothing
        # Bad horizon
        @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            1000 * resolution, # horizon is longer than single time series
            interval,
        )

        # The next test is not compatible with the bystander.
        IS.remove_time_series!(sys, IS.Deterministic, component, "bystander")

        # Good but different horizon count
        @test IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            12 * resolution,
            interval,
        ) === nothing

        # Good but different interval
        @test IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            2 * resolution,
            Dates.Minute(10),
        ) === nothing

        # Bad interval
        @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            resolution * (horizon_count + 1),
        )

        # Multiple resolutions is not supported yet
        resolution2 = Dates.Hour(1)
        dates = create_dates("2020-01-01T00:00:00", resolution2, "2020-01-02T00:00:00")
        data = collect(1:length(dates))
        ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
        name = "val2"
        ts = IS.SingleTimeSeries(name, ta)
        IS.add_time_series!(sys, component, ts)
        horizon_count = 24
        horizon = horizon_count * resolution
        @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            resolution2 * (horizon_count + 1),
        )

        # Ensure that attempted removal of nonexistent types works fine
        counts = IS.get_time_series_counts(sys)
        IS.remove_time_series!(sys, IS.Probabilistic)
        @test counts === IS.get_time_series_counts(sys)
    end
end

function _create_multi_resolution_horizon_count_system()
    resolution1 = Dates.Minute(5)
    resolution2 = Dates.Minute(10)
    horizon = 6 * resolution2
    interval = Dates.Minute(30)
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    dates1 = create_dates("2020-01-01T00:00:00", resolution1, "2020-01-01T23:00:00")
    data1 = rand(length(dates1))
    ta1 = TimeSeries.TimeArray(dates1, data1, [IS.get_name(component)])
    name1 = "val1"
    ts1 = IS.SingleTimeSeries(name1, ta1)

    dates2 = create_dates("2020-01-01T00:00:00", resolution2, "2020-01-01T23:10:00")
    data2 = rand(length(dates2))
    ta2 = TimeSeries.TimeArray(dates2, data2, [IS.get_name(component)])
    name2 = "val2"
    ts2 = IS.SingleTimeSeries(name2, ta2)

    IS.add_time_series!(sys, component, ts1)
    IS.add_time_series!(sys, component, ts2)

    attr = IS.TestSupplemental(; value = 3.0)
    IS.add_supplemental_attribute!(sys, component, attr)
    resolution_sa = Dates.Hour(1)
    dates_sa = create_dates("2021-01-01T00:00:00", resolution_sa, "2021-01-01T23:00:00")
    data_sa = rand(length(dates_sa))
    ta_sa = TimeSeries.TimeArray(dates_sa, data_sa, [IS.get_name(component)])
    name_sa = "val_sa"
    ts_sa = IS.SingleTimeSeries(name_sa, ta_sa)
    IS.add_time_series!(sys, attr, ts_sa)

    return sys, component, attr, resolution1, resolution2, horizon, interval
end

@testset "Test multi-DTS with mixed resolutions valid" begin
    sys, component, attr, resolution1, resolution2, horizon, interval =
        _create_multi_resolution_horizon_count_system()
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
    ts1b = IS.get_time_series(IS.DeterministicSingleTimeSeries, component, "val1")
    @test IS.get_horizon(ts1b) == horizon
    @test IS.get_horizon_count(ts1b) == horizon ÷ resolution1
    ts2b = IS.get_time_series(IS.DeterministicSingleTimeSeries, component, "val2")
    @test IS.get_horizon(ts2b) == horizon
    @test IS.get_horizon_count(ts2b) == horizon ÷ resolution2
    @test !IS.has_time_series(attr, IS.DeterministicSingleTimeSeries)
end

@testset "Test multi-DTS with mixed resolutions invalid resolution" begin
    sys, component, attr, resolution1, resolution2, horizon, interval =
        _create_multi_resolution_horizon_count_system()
    resolution3 = Dates.Minute(13)
    dates3 = create_dates("2020-01-01T00:00:00", resolution3, "2020-01-01T23:00:00")
    data3 = rand(length(dates3))
    ta3 = TimeSeries.TimeArray(dates3, data3, [IS.get_name(component)])
    name3 = "val3"
    ts3 = IS.SingleTimeSeries(name3, ta3)
    IS.add_time_series!(sys, component, ts3)
    @test_throws "not evenly divisible" IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
    @test !IS.has_time_series(component, IS.DeterministicSingleTimeSeries)
    @test !IS.has_time_series(attr, IS.DeterministicSingleTimeSeries)
end

@testset "Test multi-DTS with mixed resolutions invalid window count" begin
    sys, component, attr, resolution1, resolution2, horizon, interval =
        _create_multi_resolution_horizon_count_system()
    resolution3 = Dates.Minute(10)
    dates3 = create_dates("2020-01-01T00:00:00", resolution3, "2020-01-02T00:00:00")
    data3 = rand(length(dates3))
    ta3 = TimeSeries.TimeArray(dates3, data3, [IS.get_name(component)])
    name3 = "val3"
    ts3 = IS.SingleTimeSeries(name3, ta3)
    IS.add_time_series!(sys, component, ts3)
    @test_throws "different values for count" IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
    @test !IS.has_time_series(component, IS.DeterministicSingleTimeSeries)
    @test !IS.has_time_series(attr, IS.DeterministicSingleTimeSeries)
end

@testset "Test multi-DTS with mixed resolutions invalid initial timestamp" begin
    sys, component, attr, resolution1, resolution2, horizon, interval =
        _create_multi_resolution_horizon_count_system()
    resolution3 = Dates.Minute(10)
    dates3 = create_dates("2020-01-01T01:00:00", resolution3, "2020-01-02T00:10:00")
    data3 = rand(length(dates3))
    ta3 = TimeSeries.TimeArray(dates3, data3, [IS.get_name(component)])
    name3 = "val3"
    ts3 = IS.SingleTimeSeries(name3, ta3)
    IS.add_time_series!(sys, component, ts3)
    @test_throws "different initial timestamps" IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
    !IS.has_time_series(component, IS.DeterministicSingleTimeSeries)
    @test !IS.has_time_series(attr, IS.DeterministicSingleTimeSeries)
end

@testset "Test multiple transform_single_time_series! calls with different resolutions" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    # Add two SingleTimeSeries with different resolutions.
    resolution1 = Dates.Minute(5)
    dates1 = create_dates("2020-01-01T00:00:00", resolution1, "2020-01-01T23:00:00")
    ta1 = TimeSeries.TimeArray(dates1, rand(length(dates1)), [IS.get_name(component)])
    IS.add_time_series!(sys, component, IS.SingleTimeSeries("val1", ta1))

    resolution2 = Dates.Minute(10)
    dates2 = create_dates("2020-01-01T00:00:00", resolution2, "2020-01-01T23:00:00")
    ta2 = TimeSeries.TimeArray(dates2, rand(length(dates2)), [IS.get_name(component)])
    IS.add_time_series!(sys, component, IS.SingleTimeSeries("val2", ta2))

    horizon = Dates.Hour(1)
    interval = Dates.Minute(30)

    # Transform only the 5-minute resolution series.
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval;
        resolution = resolution1,
        delete_existing = false,
    )

    # Second call for the 10-minute resolution series should succeed.
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval;
        resolution = resolution2,
        delete_existing = false,
    )

    # Both sets should coexist.
    all_metadata = collect(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.DeterministicSingleTimeSeries,
        ),
    )
    @test length(all_metadata) == 2
end

@testset "Test transform_single_time_series! idempotent with same parameters" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:00:00")
    data = rand(length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    ts = IS.SingleTimeSeries("val1", ta)
    IS.add_time_series!(sys, component, ts)

    horizon = Dates.Hour(1)
    interval = Dates.Minute(30)
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval;
        delete_existing = false,
    )

    # Same call again should be idempotent (skip existing).
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval;
        delete_existing = false,
    )

    all_metadata = collect(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.DeterministicSingleTimeSeries,
        ),
    )
    @test length(all_metadata) == 1
end

@testset "Test transform_single_time_series! delete_existing removes old transforms" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    # Add two SingleTimeSeries with different resolutions.
    resolution1 = Dates.Minute(5)
    dates1 = create_dates("2020-01-01T00:00:00", resolution1, "2020-01-01T23:00:00")
    ta1 = TimeSeries.TimeArray(dates1, rand(length(dates1)), [IS.get_name(component)])
    IS.add_time_series!(sys, component, IS.SingleTimeSeries("val1", ta1))

    resolution2 = Dates.Minute(10)
    dates2 = create_dates("2020-01-01T00:00:00", resolution2, "2020-01-01T23:00:00")
    ta2 = TimeSeries.TimeArray(dates2, rand(length(dates2)), [IS.get_name(component)])
    IS.add_time_series!(sys, component, IS.SingleTimeSeries("val2", ta2))

    horizon = Dates.Hour(1)
    interval = Dates.Minute(30)

    # Transform both resolutions without deleting.
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval;
        delete_existing = false,
    )

    all_metadata = collect(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.DeterministicSingleTimeSeries,
        ),
    )
    @test length(all_metadata) == 2

    # Call with delete_existing=true (the default) should remove old transforms and recreate.
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval;
        delete_existing = true,
    )

    all_metadata = collect(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.DeterministicSingleTimeSeries,
        ),
    )
    @test length(all_metadata) == 2
end

@testset "Test check_transform_single_time_series" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:00:00")
    data = rand(length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    ts = IS.SingleTimeSeries("val1", ta)
    IS.add_time_series!(sys, component, ts)

    # Valid parameters should return true.
    @test IS.check_transform_single_time_series(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(1),
        Dates.Minute(30),
    )

    # Horizon too large should return false.
    @test !IS.check_transform_single_time_series(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(100),
        Dates.Hour(1),
    )

    # Irregular period should return false.
    @test !IS.check_transform_single_time_series(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Month(1),
        Dates.Hour(1),
    )
end

@testset "Test Deterministic with a wrapped SingleTimeSeries different offsets" begin
    for in_memory in (true, false)
        sys = IS.SystemData(; time_series_in_memory = in_memory)
        component = IS.TestComponent("Component1", 5)
        IS.add_component!(sys, component)

        resolution = Dates.Hour(1)
        dates1 = create_dates("2020-01-01T00:00:00", resolution, "2020-01-02T00:00:00")
        dates2 = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:00:00")
        data1 = collect(1:length(dates1))
        data2 = collect(1:length(dates2))
        ta1 = TimeSeries.TimeArray(dates1, data1, [IS.get_name(component)])
        ta2 = TimeSeries.TimeArray(dates2, data2, [IS.get_name(component)])
        name1 = "val1"
        name2 = "val2"
        ts1 = IS.SingleTimeSeries(name1, ta1)
        ts2 = IS.SingleTimeSeries(name2, ta2)
        IS.add_time_series!(sys, component, ts1)
        IS.add_time_series!(sys, component, ts2)

        horizon_count = 1
        horizon = horizon_count * resolution
        interval = Dates.Hour(1)
        @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            interval,
        )
    end
end

@testset "Test SingleTimeSeries transform with multiple forecasts per component" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:05:00")
    data = collect(1:length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    ts_names = []
    for i in 1:10
        name = string(UUIDs.uuid4())
        ts = IS.SingleTimeSeries(name, ta)
        IS.add_time_series!(sys, component, ts)
        push!(ts_names, name)
    end
    horizon_count = 6
    horizon = horizon_count * resolution

    interval = Dates.Minute(30)
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )

    for name in ts_names
        forecast = IS.get_time_series(IS.Deterministic, component, name)
        @test forecast isa IS.DeterministicSingleTimeSeries
    end
end

@testset "Test SingleTimeSeries transform deletions" begin
    for in_memory in (true, false)
        sys = IS.SystemData(; time_series_in_memory = in_memory)
        component = IS.TestComponent("Component1", 5)
        IS.add_component!(sys, component)

        resolution = Dates.Minute(5)
        dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:05:00")
        data = collect(1:length(dates))
        ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
        name = "val"
        ts = IS.SingleTimeSeries(name, ta)
        IS.add_time_series!(sys, component, ts)
        horizon_count = 6
        horizon = horizon_count * resolution

        interval = Dates.Minute(30)
        IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            horizon,
            interval,
        )

        # Ensure that deleting one doesn't delete the other.
        # Note: we block deletion of SingleTimeSeries when there is
        # a DeterministicSingleTimeSeries attached to it.
        if in_memory
            IS.remove_time_series!(sys, IS.Deterministic, component, name)
            @test IS.get_time_series(IS.SingleTimeSeries, component, name) isa
                  IS.SingleTimeSeries
        else
            IS.remove_time_series!(sys, IS.DeterministicSingleTimeSeries, component, name)
            @test IS.get_time_series(IS.SingleTimeSeries, component, name) isa
                  IS.SingleTimeSeries
        end
    end
end

@testset "Test DeterministicSingleTimeSeries with single window" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Hour(1)
    horizon_count = 24
    horizon = horizon_count * resolution
    dates = collect(
        range(
            Dates.DateTime("2020-01-01T00:00:00");
            length = horizon_count,
            step = resolution,
        ),
    )
    data = collect(1:horizon_count)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)

    interval = Dates.Hour(horizon_count)
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )

    initial_times = collect(IS.get_forecast_initial_times(sys))
    @test initial_times == [Dates.DateTime("2020-01-01T00:00:00")]
    forecast = IS.get_time_series(IS.DeterministicSingleTimeSeries, component, name)
    @test IS.get_interval(forecast) == Dates.Second(0)
end

@testset "Test DeterministicSingleTimeSeries with interval = resolution" begin
    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Hour(1)
    horizon_count = 24
    horizon = horizon_count * resolution
    dates = collect(
        range(
            Dates.DateTime("2020-01-01T00:00:00");
            length = horizon_count,
            step = resolution,
        ),
    )
    data = collect(1:horizon_count)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)

    interval = resolution
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )

    initial_times = collect(IS.get_forecast_initial_times(sys))
    @test initial_times == [Dates.DateTime("2020-01-01T00:00:00")]
    forecast = IS.get_time_series(IS.DeterministicSingleTimeSeries, component, name)
    @test IS.get_interval(forecast) == interval
end

@testset "Test component removal with DeterministicSingleTimeSeries" begin
    sys = IS.SystemData()
    component = IS.TestComponent("Component1", 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:00:00")
    data = collect(1:length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)
    horizon_count = 6
    horizon = horizon_count * resolution
    interval = Dates.Minute(10)
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
    IS.remove_component!(sys, component)
    @test length(IS.get_components(IS.TestComponent, sys)) == 0
end

@testset "Test transform_single_time_series with irregular resolution" begin
    sys = IS.SystemData()
    component = IS.TestComponent("Component1", 1)
    IS.add_component!(sys, component)

    resolution = Dates.Month(1)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2021-01-01T00:00:00")
    data = collect(1:length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta; resolution = resolution)
    IS.add_time_series!(sys, component, ts)
    horizon_count = 12
    horizon = horizon_count * resolution
    interval = Dates.Month(1)
    @test_throws "transform_single_time_series! does not support irregular" IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
end

@testset "Test transform_single_time_series with conflicting Deterministic" begin
    # Test 1: Transformation fails when Deterministic exists with same name, resolution, and features
    sys1 = IS.SystemData()
    component1 = IS.TestComponent("Component1", 1)
    IS.add_component!(sys1, component1)

    resolution = Dates.Hour(1)
    initial_time = Dates.DateTime("2020-01-01T00:00:00")

    # Add a Deterministic forecast with interval = 1 hour, horizon = 24 hours, 2 windows
    horizon_count = 24
    interval = Dates.Hour(1)
    other_time = initial_time + interval
    name = "power"
    forecast_data = SortedDict(
        initial_time => ones(horizon_count),
        other_time => ones(horizon_count) * 2,
    )
    forecast =
        IS.Deterministic(; data = forecast_data, name = name, resolution = resolution)
    IS.add_time_series!(sys1, component1, forecast)

    # Add a SingleTimeSeries with the same name, resolution, and no features
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-02T00:00:00")
    data = collect(1:length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component1)])
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys1, component1, ts)

    # Attempt to transform - this should fail because there's already a Deterministic
    # with the same name, resolution, and features
    horizon = horizon_count * resolution
    @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
        sys1,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )

    # Test 2: Transformation succeeds when features are different
    sys2 = IS.SystemData()
    component2 = IS.TestComponent("Component2", 2)
    IS.add_component!(sys2, component2)

    forecast2 =
        IS.Deterministic(; data = forecast_data, name = name, resolution = resolution)
    IS.add_time_series!(sys2, component2, forecast2)

    ts_with_features = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys2, component2, ts_with_features; scenario = "high")

    IS.transform_single_time_series!(
        sys2,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )
    @test IS.has_time_series(component2, IS.DeterministicSingleTimeSeries, name)
    @test IS.has_time_series(component2, IS.Deterministic, name)
    @test IS.has_time_series(component2, IS.SingleTimeSeries, name; scenario = "high")

    # Test 3: Transformation succeeds when resolution is different
    sys3 = IS.SystemData()
    component3 = IS.TestComponent("Component3", 3)
    IS.add_component!(sys3, component3)

    forecast3 =
        IS.Deterministic(; data = forecast_data, name = name, resolution = resolution)
    IS.add_time_series!(sys3, component3, forecast3)

    # Add SingleTimeSeries with different resolution (30 minutes)
    resolution_30min = Dates.Minute(30)
    dates_30min =
        create_dates("2020-01-01T00:00:00", resolution_30min, "2020-01-02T00:00:00")
    data_30min = collect(1:length(dates_30min))
    ta_30min = TimeSeries.TimeArray(dates_30min, data_30min, [IS.get_name(component3)])
    ts_different_resolution =
        IS.SingleTimeSeries(name, ta_30min; resolution = resolution_30min)
    IS.add_time_series!(sys3, component3, ts_different_resolution)

    horizon_30min = 48 * resolution_30min  # 24 hours
    interval_30min = Dates.Minute(30)
    IS.transform_single_time_series!(
        sys3,
        IS.DeterministicSingleTimeSeries,
        horizon_30min,
        interval_30min,
    )
    @test IS.has_time_series(
        component3,
        IS.DeterministicSingleTimeSeries,
        name;
        resolution = resolution_30min,
    )
    @test IS.has_time_series(component3, IS.Deterministic, name; resolution = resolution)
end

function _test_add_single_time_series_type(test_value, type_name)
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    data_series =
        TimeSeries.TimeArray(
            range(initial_time; length = 365, step = resolution),
            test_value,
        )
    data = IS.SingleTimeSeries(; data = data_series, name = "test_c")
    IS.add_time_series!(sys, component, data)
    ts = IS.get_time_series(IS.SingleTimeSeries, component, "test_c";)
    @test split(IS.get_data_type(ts), '.')[end] == type_name
    @test reshape(TimeSeries.values(IS.get_data(ts)), 365) == TimeSeries.values(data_series)
    _test_add_single_time_series_helper(component, initial_time)
end

@testset "Test add SingleTimeSeries with LinearFunctionData Cost" begin
    _test_add_single_time_series_type(
        repeat([IS.LinearFunctionData(3.14, 1.23)], 365),
        "LinearFunctionData",
    )
end

@testset "Test add SingleTimeSeries with QuadraticFunctionData Cost" begin
    _test_add_single_time_series_type(
        repeat([IS.QuadraticFunctionData(999.0, 1.0, 0.5)], 365),
        "QuadraticFunctionData",
    )
end

@testset "Test add SingleTimeSeries with PiecewiseLinearData Cost" begin
    _test_add_single_time_series_type(
        repeat([IS.PiecewiseLinearData(repeat([(999.0, 1.0)], 5))], 365),
        "PiecewiseLinearData",
    )
end

@testset "Test read_time_series_file_metadata" begin
    file = joinpath(FORECASTS_DIR, "ComponentsAsColumnsNoTime.json")
    time_series = IS.read_time_series_file_metadata(file)
    @test length(time_series) == 1

    for time_series in time_series
        @test isfile(time_series.data_file)
    end
end

@testset "Test add_time_series from file" begin
    data = IS.SystemData()

    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(data, component)
    @test !IS.has_time_series(component)

    file = joinpath(FORECASTS_DIR, "ComponentsAsColumnsNoTime.json")
    res = IS.add_time_series_from_file_metadata!(
        data,
        IS.InfrastructureSystemsComponent,
        file,
    )
    @test !isempty(res) && first(res) isa IS.StaticTimeSeriesKey
    @test IS.has_time_series(component)

    all_time_series = collect(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    @test length(all_time_series) == 1
    time_series = all_time_series[1]
    @test time_series isa IS.SingleTimeSeries

    time_series2 = IS.get_time_series(
        typeof(time_series),
        component,
        IS.get_name(time_series);
        start_time = IS.get_initial_timestamp(time_series),
    )
    @test length(time_series) == length(time_series2)
    @test IS.get_initial_timestamp(time_series) ==
          IS.get_initial_timestamp(time_series2)

    it = IS.get_initial_timestamp(time_series)

    all_time_series = collect(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    @test length(all_time_series) == 1

    data = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(data, component)
    @test !IS.has_time_series(component)
    file = joinpath(FORECASTS_DIR, "ForecastPointers.json")
    IS.add_time_series_from_file_metadata!(
        data,
        IS.InfrastructureSystemsComponent,
        file,
    )
    @test IS.has_time_series(component)

    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)
    @test !IS.has_time_series(component)
    file = joinpath(FORECASTS_DIR, "DateTimeAsColumnDeterministic.csv")
    raw_data = IS.read_time_series(IS.Deterministic, file, "Component1")
    data = IS.Deterministic("test", file, component, Dates.Hour(1))
    IS.add_time_series!(sys, component, data)
    @test IS.has_time_series(component)
    ini_time = IS.get_initial_timestamp(data)
    retrieved_data =
        IS.get_time_series(IS.Deterministic, component, "test"; start_time = ini_time)
    @test IS.get_name(data) == IS.get_name(retrieved_data)
    @test IS.get_resolution(data) == IS.get_resolution(retrieved_data)
end

@testset "Test add_time_series" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(;
        name = name,
        data = ta,
        scaling_factor_multiplier = IS.get_val,
    )
    IS.add_time_series!(sys, component, ts)
    ts = IS.get_time_series(IS.SingleTimeSeries, component, name; start_time = dates[1])
    @test ts isa IS.SingleTimeSeries

    name = "Component2"
    component2 = IS.TestComponent(name, component_val)
    @test_throws ArgumentError IS.add_time_series!(sys, component2, ts)

    # The component name will exist but not the component.
    component3 = IS.TestComponent(name, component_val)
    @test_throws ArgumentError IS.add_time_series!(sys, component3, ts)
end

@testset "Test add_time_series multiple components" begin
    sys = IS.SystemData()
    components = []
    len = 3
    for i in 1:len
        component = IS.TestComponent(string(i), i)
        IS.add_component!(sys, component)
        push!(components, component)
    end

    initial_time = Dates.DateTime("2020-01-01T00:00:00")
    end_time = Dates.DateTime("2020-01-01T23:00:00")
    dates = collect(initial_time:Dates.Hour(1):end_time)
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, ["1"])
    name = "val"
    ts = IS.SingleTimeSeries(;
        name = name,
        data = ta,
        scaling_factor_multiplier = IS.get_val,
    )
    IS.add_time_series!(sys, components, ts)

    hash_ta_main = nothing
    for i in 1:len
        component = IS.get_component(IS.TestComponent, sys, string(i))
        ts = IS.get_time_series(IS.SingleTimeSeries, component, name)
        hash_ta = hash(IS.get_data(ts))
        if i == 1
            hash_ta_main = hash_ta
        else
            @test hash_ta == hash_ta_main
        end
    end

    ts_storage = sys.time_series_manager.data_store
    @test ts_storage isa IS.Hdf5TimeSeriesStorage
    @test IS.get_num_time_series(ts_storage) == 1
end

@testset "Test get_time_series_multiple" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)
    initial_time1 = Dates.DateTime("2020-01-01T00:00:00")
    initial_time2 = Dates.DateTime("2020-01-02T00:00:00")

    dates1 = collect(initial_time1:Dates.Hour(1):Dates.DateTime("2020-01-01T23:00:00"))
    dates2 = collect(initial_time2:Dates.Hour(1):Dates.DateTime("2020-01-02T23:00:00"))
    data1 = collect(1:24)
    data2 = collect(25:48)
    ta1 = TimeSeries.TimeArray(dates1, data1, [IS.get_name(component)])
    ta2 = TimeSeries.TimeArray(dates2, data2, [IS.get_name(component)])
    time_series1 =
        IS.SingleTimeSeries(;
            name = "val",
            data = ta1,
            scaling_factor_multiplier = IS.get_val,
        )
    time_series2 =
        IS.SingleTimeSeries(;
            name = "val2",
            data = ta2,
            scaling_factor_multiplier = IS.get_val,
        )
    IS.add_time_series!(sys, component, time_series1)
    IS.add_time_series!(sys, component, time_series2)

    @test length(collect(IS.get_time_series_multiple(sys))) == 2
    @test length(collect(IS.get_time_series_multiple(component))) == 2
    @test length(collect(IS.get_time_series_multiple(sys))) == 2

    @test length(
        collect(IS.get_time_series_multiple(sys; type = IS.SingleTimeSeries)),
    ) == 2
    @test isempty(IS.get_time_series_multiple(sys; type = IS.Probabilistic))

    time_series = collect(IS.get_time_series_multiple(sys))
    @test length(time_series) == 2

    @test length(collect(IS.get_time_series_multiple(sys; name = "val"))) == 1
    @test isempty(IS.get_time_series_multiple(sys; name = "bad_name"))

    filter_func = x -> TimeSeries.values(IS.get_data(x))[12] == 12
    @test isempty(IS.get_time_series_multiple(sys, filter_func; name = "val2"))
end

@testset "Test add_time_series from TimeArray" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta; scaling_factor_multiplier = IS.get_val)
    IS.add_time_series!(sys, component, ts)
    time_series = IS.get_time_series(IS.SingleTimeSeries, component, name)
    @test time_series isa IS.SingleTimeSeries
end

@testset "Test remove_time_series" begin
    data = create_system_data(; with_time_series = true)
    components = collect(IS.iterate_components(data))
    @test length(components) == 1
    component = components[1]
    time_series = collect(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    @test length(time_series) == 1

    time_series = time_series[1]
    IS.remove_time_series!(
        data,
        typeof(time_series),
        component,
        IS.get_name(time_series),
    )

    @test isempty(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
end

@testset "Test clear_time_series" begin
    data = create_system_data(; with_time_series = true)
    IS.clear_time_series!(data)
    @test isempty(IS.get_time_series_multiple(data))
end

@testset "Test that remove_component removes time_series" begin
    data = create_system_data(; with_time_series = true)

    components = collect(IS.get_components(IS.InfrastructureSystemsComponent, data))
    @test length(components) == 1
    component = components[1]

    all_time_series = collect(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    @test length(all_time_series) == 1
    time_series = all_time_series[1]

    IS.remove_component!(data, component)
    @test isempty(IS.get_components(IS.InfrastructureSystemsComponent, data))
    @test isempty(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
end

@testset "Test get_time_series_array" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(
        name,
        ta;
        normalization_factor = 1.0,
        scaling_factor_multiplier = IS.get_val,
    )
    IS.add_time_series!(sys, component, ts)
    time_series = IS.get_time_series(IS.SingleTimeSeries, component, name)

    # Test both versions of the function.
    vals = IS.get_time_series_array(component, time_series)
    @test TimeSeries.timestamp(vals) == dates
    @test TimeSeries.values(vals) == data .* component_val

    vals2 = IS.get_time_series_array(IS.SingleTimeSeries, component, name)
    @test TimeSeries.timestamp(vals2) == dates
    @test TimeSeries.values(vals2) == data .* component_val
end

@testset "Test get subset of time_series" begin
    sys = create_system_data()
    components = collect(IS.get_components(IS.InfrastructureSystemsComponent, sys))
    @test length(components) == 1
    component = components[1]

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    data = collect(1:24)

    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)

    ts = IS.get_time_series(IS.SingleTimeSeries, component, name; start_time = dates[1])
    @test TimeSeries.timestamp(IS.get_data(ts))[1] == dates[1]
    @test length(ts) == 24

    ts = IS.get_time_series(IS.SingleTimeSeries, component, name; start_time = dates[3])
    @test TimeSeries.timestamp(IS.get_data(ts))[1] == dates[3]
    @test length(ts) == 22

    time_series = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        name;
        start_time = dates[5],
        len = 10,
    )
    @test TimeSeries.timestamp(IS.get_data(time_series))[1] == dates[5]
    @test length(time_series) == 10
end

@testset "Test copy time_series no name mapping" begin
    sys = create_system_data()
    components = collect(IS.get_components(IS.InfrastructureSystemsComponent, sys))
    @test length(components) == 1
    component = components[1]

    initial_time = Dates.DateTime("2020-01-01T00:00:00")
    dates = collect(initial_time:Dates.Hour(1):Dates.DateTime("2020-01-01T23:00:00"))
    data = collect(1:24)

    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)

    component2 = IS.TestComponent("component2", 6)
    IS.add_component!(sys, component2)
    IS.copy_time_series!(component2, component)
    time_series = IS.get_time_series(IS.SingleTimeSeries, component2, name)
    @test time_series isa IS.SingleTimeSeries
    @test IS.get_initial_timestamp(time_series) == initial_time
    @test IS.get_name(time_series) == name
end

@testset "Test copy time_series name mapping" begin
    sys = create_system_data()
    components = collect(IS.get_components(IS.InfrastructureSystemsComponent, sys))
    @test length(components) == 1
    component = components[1]

    initial_time = Dates.DateTime("2020-01-01T00:00:00")
    dates = collect(initial_time:Dates.Hour(1):Dates.DateTime("2020-01-01T23:00:00"))
    data = collect(1:24)

    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name1 = "val1"
    ts = IS.SingleTimeSeries(name1, ta)
    IS.add_time_series!(sys, component, ts)

    component2 = IS.TestComponent("component2", 6)
    IS.add_component!(sys, component2)
    name2 = "val2"
    name_mapping = Dict((IS.get_name(component), name1) => name2)
    IS.copy_time_series!(component2, component; name_mapping = name_mapping)
    time_series = IS.get_time_series(IS.SingleTimeSeries, component2, name2)
    @test time_series isa IS.SingleTimeSeries
    @test IS.get_initial_timestamp(time_series) == initial_time
    @test IS.get_name(time_series) == name2
end

@testset "Test copy time_series name mapping, missing name" begin
    sys = create_system_data()
    components = collect(IS.get_components(IS.InfrastructureSystemsComponent, sys))
    @test length(components) == 1
    component = components[1]

    initial_time1 = Dates.DateTime("2020-01-01T00:00:00")
    end_time1 = Dates.DateTime("2020-01-01T23:00:00")
    dates1 = collect(initial_time1:Dates.Hour(1):end_time1)
    initial_time2 = Dates.DateTime("2020-01-02T00:00:00")
    end_time2 = Dates.DateTime("2020-01-02T23:00:00")
    dates2 = collect(initial_time2:Dates.Hour(1):end_time2)
    data = collect(1:24)

    ta1 = TimeSeries.TimeArray(dates1, data, [IS.get_name(component)])
    ta2 = TimeSeries.TimeArray(dates2, data, [IS.get_name(component)])
    name1 = "val1"
    name2a = "val2a"
    ts1 = IS.SingleTimeSeries(name1, ta1)
    ts2 = IS.SingleTimeSeries(name2a, ta2)
    IS.add_time_series!(sys, component, ts1)
    IS.add_time_series!(sys, component, ts2)

    component2 = IS.TestComponent("component2", 6)
    IS.add_component!(sys, component2)
    name2b = "val2b"
    name_mapping = Dict((IS.get_name(component), name2a) => name2b)
    IS.copy_time_series!(component2, component; name_mapping = name_mapping)
    time_series = IS.get_time_series(IS.SingleTimeSeries, component2, name2b)
    @test time_series isa IS.SingleTimeSeries
    @test IS.get_initial_timestamp(time_series) == initial_time2
    @test IS.get_name(time_series) == name2b
    @test_throws ArgumentError IS.get_time_series(
        IS.SingleTimeSeries,
        component2,
        name2a,
    )
end

@testset "Test copy time_series with transformed time series" begin
    sys = create_system_data(; time_series_in_memory = true)
    components = collect(IS.get_components(IS.InfrastructureSystemsComponent, sys))
    @test length(components) == 1
    component = components[1]

    resolution = Dates.Minute(5)
    dates = create_dates("2020-01-01T00:00:00", resolution, "2020-01-01T23:00:00")
    data = collect(1:length(dates))
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)
    horizon_count = 6
    horizon = horizon_count * resolution
    interval = Dates.Minute(10)
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval,
    )

    component2 = IS.TestComponent("component2", 6)
    IS.add_component!(sys, component2)
    IS.copy_time_series!(component2, component)

    time_series = IS.get_time_series(IS.SingleTimeSeries, component2, name)
    @test time_series isa IS.SingleTimeSeries
    @test IS.get_initial_timestamp(time_series) == dates[1]
    @test IS.get_name(time_series) == name

    time_series = IS.get_time_series(IS.DeterministicSingleTimeSeries, component2, name)
    @test time_series isa IS.DeterministicSingleTimeSeries
    @test IS.get_initial_timestamp(time_series) == dates[1]
    @test IS.get_name(time_series) == name
end

@testset "Test component-time_series being added to multiple systems" begin
    sys1 = IS.SystemData()
    sys2 = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys1, component)

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys1, component, ts)

    @test_throws ArgumentError IS.add_component!(sys1, component)
end

@testset "Test time_series forwarding methods" begin
    data = create_system_data(; with_time_series = true)
    time_series = first(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))

    # Iteration
    size = 24
    @test length(time_series) == size
    i = 0
    for x in time_series
        i += 1
    end
    @test i == size

    # Indexing
    @test length(time_series[1:16]) == 16

    # when
    fcast = IS.when(time_series, TimeSeries.minute, 0)
    @test length(fcast) == 24
end

@testset "Test time_series head" begin
    data = create_system_data(; with_time_series = true)
    time_series = first(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    fcast = IS.head(time_series)
    # head returns a length of 6 by default, but don't hard-code that.
    @test length(fcast) < length(time_series)

    fcast = IS.head(time_series, 10)
    @test length(fcast) == 10
end

@testset "Test time_series tail" begin
    data = create_system_data(; with_time_series = true)
    time_series = first(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    fcast = IS.tail(time_series)
    # tail returns a length of 6 by default, but don't hard-code that.
    @test length(fcast) < length(time_series)

    fcast = IS.head(time_series, 10)
    @test length(fcast) == 10
end

@testset "Test time_series from" begin
    data = create_system_data(; with_time_series = true)
    time_series = first(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    start_time = Dates.DateTime(Dates.today()) + Dates.Hour(3)
    fcast = IS.from(time_series, start_time)
    @test length(fcast) == 21
    @test TimeSeries.timestamp(IS.get_data(fcast))[1] == start_time
end

@testset "Test time_series to" begin
    data = create_system_data(; with_time_series = true)
    time_series = first(IS.get_time_series_multiple(data; type = IS.SingleTimeSeries))
    for end_time in (
        Dates.DateTime(Dates.today()) + Dates.Hour(15),
        Dates.DateTime(Dates.today()) + Dates.Hour(15) + Dates.Minute(5),
    )
        fcast = IS.to(time_series, end_time)
        @test length(fcast) == 16
        @test TimeSeries.timestamp(IS.get_data(fcast))[end] <= end_time
    end
end

@testset "Test Scenarios time_series" begin
    for in_memory in (true, false)
        sys = IS.SystemData(; time_series_in_memory = in_memory)
        sys = IS.SystemData()
        name = "Component1"
        name = "val"
        component = IS.TestComponent(name, 5)
        IS.add_component!(sys, component)

        initial_timestamp = Dates.DateTime("2020-01-01T00:00:00")
        resolution = Dates.Hour(1)
        other_timestamp = initial_timestamp + resolution
        horizon_count = 24
        horizon = horizon_count * resolution
        scenario_count = 2
        data_input = rand(horizon_count, scenario_count)
        data_input2 = rand(horizon_count, scenario_count)
        data = SortedDict(initial_timestamp => data_input, other_timestamp => data_input2)
        time_series = IS.Scenarios(;
            name = name,
            resolution = resolution,
            scenario_count = scenario_count,
            data = data,
        )
        fdata = IS.get_data(time_series)
        @test size(first(values(fdata)))[2] == 2
        @test initial_timestamp == first(keys((fdata)))
        @test data_input == first(values((fdata)))

        IS.add_time_series!(sys, component, time_series)
        time_series2 = IS.get_time_series(IS.Scenarios, component, name)
        @test time_series2 isa IS.Scenarios
        fdata2 = IS.get_data(time_series2)
        @test size(first(values(fdata2)))[2] == 2
        @test initial_timestamp == first(keys((fdata2)))
        @test data_input == first(values((fdata2)))
    end
end

@testset "Test Probabilistic time_series" begin
    for in_memory in (true, false)
        sys = IS.SystemData(; time_series_in_memory = in_memory)
        name = "Component1"
        name = "val"
        component = IS.TestComponent(name, 5)
        IS.add_component!(sys, component)

        initial_timestamp = Dates.DateTime("2020-01-01T00:00:00")
        resolution = Dates.Hour(1)
        other_timestamp = initial_timestamp + resolution
        horizon_count = 24
        horizon = horizon_count * resolution
        percentiles = 1:99
        data_input = rand(horizon_count, length(percentiles))
        data_input2 = rand(horizon_count, length(percentiles))
        data = SortedDict(initial_timestamp => data_input, other_timestamp => data_input2)
        time_series = IS.Probabilistic(;
            name = name,
            resolution = resolution,
            percentiles = percentiles,
            data = data,
        )
        fdata = IS.get_data(time_series)
        @test size(first(values(fdata)))[2] == length(percentiles)
        @test initial_timestamp == first(keys((fdata)))
        @test data_input == first(values((fdata)))

        IS.add_time_series!(sys, component, time_series)
        time_series2 = IS.get_time_series(IS.Probabilistic, component, name)
        @test time_series2 isa IS.Probabilistic
        fdata2 = IS.get_data(time_series2)
        @test size(first(values(fdata2)))[2] == length(percentiles)
        @test initial_timestamp == first(keys((fdata2)))
        @test data_input == first(values((fdata2)))
    end
end

@testset "Add time_series to unsupported struct" begin
    struct TestComponentNoTimeSeries <: IS.InfrastructureSystemsComponent
        name::AbstractString
        internal::IS.InfrastructureSystemsInternal
    end

    function TestComponentNoTimeSeries(name)
        return TestComponentNoTimeSeries(name, IS.InfrastructureSystemsInternal())
    end

    sys = IS.SystemData()
    name = "component"
    component = TestComponentNoTimeSeries(name)
    IS.add_component!(sys, component)
    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    ta = TimeSeries.TimeArray(dates, collect(1:24), [IS.get_name(component)])
    time_series = IS.SingleTimeSeries(; name = "val", data = ta)
    @test_throws ArgumentError IS.add_time_series!(sys, component, time_series)
end

@testset "Test system time series parameters" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    @test isempty(IS.get_forecast_initial_times(sys))

    resolution = Dates.Hour(1)
    initial_time = Dates.DateTime("2020-09-01")
    second_time = initial_time + resolution
    name = "test_forecast"
    horizon_count = 24
    horizon = horizon_count * resolution
    data =
        SortedDict(initial_time => ones(horizon_count), second_time => ones(horizon_count))

    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution)
    IS.add_time_series!(sys, component, forecast)

    sts_data =
        TimeSeries.TimeArray(
            range(initial_time; length = 365, step = resolution),
            ones(365),
        )
    sts = IS.SingleTimeSeries(; data = sts_data, name = "test_sts")
    IS.add_time_series!(sys, component, sts)

    @test IS.get_forecast_window_count(sys) == 2
    @test IS.get_forecast_horizon(sys) == horizon
    @test IS.get_forecast_initial_timestamp(sys) == initial_time
    @test IS.get_forecast_interval(sys) == second_time - initial_time
    @test IS.get_forecast_initial_times(sys) == [initial_time, second_time]
    @test collect(IS.get_initial_times(forecast)) ==
          collect(IS.get_forecast_initial_times(sys))
end

# TODO something like this could be much more widespread to reduce code duplication
default_time_params = (
    interval = Dates.Hour(1),
    initial_timestamp = Dates.DateTime("2020-09-01"),
    initial_times = collect(
        range(Dates.DateTime("2020-09-01"); length = 24, step = Dates.Hour(1)),
    ),
    horizon_count = 24,
)

function _test_get_time_series_option_type(test_data, in_memory, extended)
    sys = IS.SystemData(; time_series_in_memory = in_memory)
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    # Set baseline parameters for the rest of the tests.
    resolution = Dates.Minute(5)
    name = "test"

    forecast = if extended
        IS.Deterministic(; data = test_data, name = name, resolution = resolution)
    else
        IS.Deterministic(name, test_data, resolution)
    end
    IS.add_time_series!(sys, component, forecast)
    @test IS.get_forecast_window_count(sys) == length(test_data)

    f2 = IS.get_time_series(IS.Deterministic, component, name)
    @test IS.get_count(f2) == length(test_data)
    @test IS.get_initial_timestamp(f2) == default_time_params.initial_times[1]
    for (i, window) in enumerate(IS.iterate_windows(f2))
        @test TimeSeries.values(window) ==
              test_data[default_time_params.initial_times[i]]
    end

    if extended
        offset = 1
        count = 1
        it = default_time_params.initial_times[offset]
        f2 = IS.get_time_series(
            IS.Deterministic,
            component,
            name;
            start_time = it,
            count = count,
        )
        @test IS.get_initial_timestamp(f2) == it
        @test IS.get_count(f2) == count
        @test IS.get_horizon_count(f2) == default_time_params.horizon_count
        for (i, window) in enumerate(IS.iterate_windows(f2))
            @test TimeSeries.values(window) ==
                  test_data[default_time_params.initial_times[i + offset - 1]]
        end
    end

    offset = 12
    count = 5
    it = default_time_params.initial_times[offset]
    f2 = IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = it,
        count = count,
    )
    @test IS.get_initial_timestamp(f2) == it
    @test IS.get_count(f2) == count
    @test IS.get_horizon_count(f2) == default_time_params.horizon_count
    for (i, window) in enumerate(IS.iterate_windows(f2))
        @test TimeSeries.values(window) ==
              test_data[default_time_params.initial_times[i + offset - 1]]
    end

    f2 = IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = it,
        count = count,
        len = default_time_params.horizon_count - 1,
    )
    @test IS.get_initial_timestamp(f2) == it
    @test IS.get_count(f2) == count
    @test IS.get_horizon_count(f2) == default_time_params.horizon_count - 1
    for (i, window) in enumerate(IS.iterate_windows(f2))
        @test TimeSeries.values(window) ==
              test_data[default_time_params.initial_times[i + offset - 1]][1:(default_time_params.horizon_count - 1)]
    end

    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        name;
        start_time = it + Dates.Minute(1),
    )
end
@testset "Test get_time_series options" begin
    for in_memory in (true, false)
        _test_get_time_series_option_type(
            SortedDict{Dates.DateTime, Vector{Float64}}(
                it => ones(default_time_params.horizon_count) * i for
                (i, it) in enumerate(default_time_params.initial_times)
            ),
            in_memory,
            false,
        )
    end
end

@testset "Test get_time_series options for LinearFunctionData Cost" begin
    for in_memory in (true, false)
        _test_get_time_series_option_type(
            SortedDict{Dates.DateTime, Vector{IS.LinearFunctionData}}(
                it => repeat([IS.LinearFunctionData(3.14 * i, 1.23 * i)], 24) for
                (i, it) in enumerate(default_time_params.initial_times)
            ), in_memory, true)
    end
end

@testset "Test get_time_series options for QuadraticFunctionData Cost" begin
    for in_memory in (true, false)
        _test_get_time_series_option_type(
            SortedDict{Dates.DateTime, Vector{IS.QuadraticFunctionData}}(
                it => repeat([IS.QuadraticFunctionData(999.0, 1.0 * i, 1.23)], 24) for
                (i, it) in enumerate(default_time_params.initial_times)
            ), in_memory, true)
    end
end

@testset "Test get_time_series options for PiecewiseLinearData Cost" begin
    for in_memory in (true, false)
        _test_get_time_series_option_type(
            SortedDict{Dates.DateTime, Vector{IS.PiecewiseLinearData}}(
                it => repeat(
                    [IS.PiecewiseLinearData(repeat([(999.0, 1.0 * i)], 5))],
                    24,
                ) for
                (i, it) in enumerate(default_time_params.initial_times)
            ), in_memory, true)
    end
end

@testset "Test get_time_series_array SingleTimeSeries" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T23:00:00")
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    name = "val"
    ts = IS.SingleTimeSeries(name, ta; scaling_factor_multiplier = IS.get_val)
    IS.add_time_series!(sys, component, ts)

    # Get data from storage, defaults.
    ta2 = IS.get_time_series_array(IS.SingleTimeSeries, component, name)
    @test ta2 isa TimeSeries.TimeArray
    @test TimeSeries.timestamp(ta2) == dates
    @test TimeSeries.timestamp(ta2) ==
          IS.get_time_series_timestamps(IS.SingleTimeSeries, component, name)
    @test TimeSeries.values(ta2) == data * IS.get_val(component)
    @test TimeSeries.values(ta2) ==
          IS.get_time_series_values(IS.SingleTimeSeries, component, name)

    # Get data from storage, custom offsets
    ta2 = IS.get_time_series_array(
        IS.SingleTimeSeries,
        component,
        name;
        start_time = dates[5],
        len = 5,
    )
    @test TimeSeries.timestamp(ta2) == dates[5:9]
    @test TimeSeries.timestamp(ta2) == IS.get_time_series_timestamps(
        IS.SingleTimeSeries,
        component,
        name;
        start_time = dates[5],
        len = 5,
    )
    @test TimeSeries.values(ta2) == data[5:9] * IS.get_val(component)
    @test TimeSeries.values(ta2) == IS.get_time_series_values(
        IS.SingleTimeSeries,
        component,
        name;
        start_time = dates[5],
        len = 5,
    )

    # Get data from storage, ignore_scaling_factors.
    ta2 = IS.get_time_series_array(
        IS.SingleTimeSeries,
        component,
        name;
        start_time = dates[5],
        ignore_scaling_factors = true,
    )
    @test TimeSeries.timestamp(ta2) == dates[5:end]
    @test TimeSeries.values(ta2) == data[5:end]

    # Get data from cached instance, defaults
    ta2 = IS.get_time_series_array(component, ts)
    @test TimeSeries.timestamp(ta2) == dates
    @test TimeSeries.timestamp(ta2) == IS.get_time_series_timestamps(component, ts)
    @test TimeSeries.values(ta2) == data * IS.get_val(component)
    @test TimeSeries.values(ta2) == IS.get_time_series_values(component, ts)

    # Get data from cached instance, custom offsets
    ta2 = IS.get_time_series_array(component, ts; start_time = dates[5], len = 5)
    @test TimeSeries.timestamp(ta2) == dates[5:9]
    @test TimeSeries.timestamp(ta2) ==
          IS.get_time_series_timestamps(component, ts; start_time = dates[5], len = 5)
    @test TimeSeries.values(ta2) == data[5:9] * IS.get_val(component)
    @test TimeSeries.values(ta2) ==
          IS.get_time_series_values(component, ts; start_time = dates[5], len = 5)

    # Get data from cached instance, custom offsets, ignore_scaling_factors.
    ta2 = IS.get_time_series_array(
        component,
        ts;
        start_time = dates[5],
        len = 5,
        ignore_scaling_factors = true,
    )
    @test TimeSeries.timestamp(ta2) == dates[5:9]
    @test TimeSeries.values(ta2) == data[5:9]
    @test TimeSeries.values(ta2) == IS.get_time_series_values(
        component,
        ts;
        start_time = dates[5],
        len = 5,
        ignore_scaling_factors = true,
    )

    IS.clear_time_series!(sys)

    # No scaling_factor_multiplier
    ts = IS.SingleTimeSeries(name, ta)
    IS.add_time_series!(sys, component, ts)
    ta2 = IS.get_time_series_array(IS.SingleTimeSeries, component, name)
    @test ta2 isa TimeSeries.TimeArray
    @test TimeSeries.timestamp(ta2) == dates
    @test TimeSeries.values(ta2) == data
    @test IS.get_time_series_timestamps(IS.SingleTimeSeries, component, name) == dates
    @test IS.get_time_series_values(IS.SingleTimeSeries, component, name) == data
end

@testset "Test get_time_series_array Deterministic" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    resolution = Dates.Minute(5)
    interval = Dates.Hour(1)
    initial_timestamp = Dates.DateTime("2020-09-01")
    initial_times = collect(range(initial_timestamp; length = 2, step = interval))
    name = "test"
    horizon_count = 24
    data = SortedDict{Dates.DateTime, Vector{Float64}}(
        it => ones(horizon_count) * i for (i, it) in enumerate(initial_times)
    )

    forecast =
        IS.Deterministic(name, data, resolution; scaling_factor_multiplier = IS.get_val)
    IS.add_time_series!(sys, component, forecast)
    start_time = initial_timestamp + interval
    # Verify all permutations with defaults.
    ta2 =
        IS.get_time_series_array(
            IS.Deterministic,
            component,
            name;
            start_time = start_time,
        )

    @test ta2 isa TimeSeries.TimeArray
    @test TimeSeries.timestamp(ta2) ==
          collect(range(start_time; length = horizon_count, step = resolution))
    @test TimeSeries.timestamp(ta2) == IS.get_time_series_timestamps(
        IS.Deterministic,
        component,
        name;
        start_time = start_time,
    )
    @test TimeSeries.timestamp(ta2) ==
          IS.get_time_series_timestamps(component, forecast; start_time = start_time)
    @test TimeSeries.values(ta2) == data[initial_times[2]] * IS.get_val(component)
    @test TimeSeries.values(ta2) == IS.get_time_series_values(
        IS.Deterministic,
        component,
        name;
        start_time = start_time,
    )
    @test TimeSeries.values(ta2) ==
          IS.get_time_series_values(component, forecast; start_time = start_time)
    @test TimeSeries.values(ta2) ==
          TimeSeries.values(
        IS.get_time_series_array(component, forecast; start_time = start_time),
    )

    # ignore_scaling_factors
    TimeSeries.values(
        IS.get_time_series_array(
            IS.Deterministic,
            component,
            name;
            start_time = start_time,
            ignore_scaling_factors = true,
        ),
    ) == data[start_time]
    IS.get_time_series_values(
        IS.Deterministic,
        component,
        name;
        start_time = start_time,
        ignore_scaling_factors = true,
    ) == data[start_time]
    IS.get_time_series_values(
        component,
        forecast;
        start_time = start_time,
        ignore_scaling_factors = true,
    ) == data[start_time]

    # Custom length
    len = 10
    @test TimeSeries.timestamp(ta2)[1:10] == IS.get_time_series_timestamps(
        IS.Deterministic,
        component,
        name;
        start_time = start_time,
        len = 10,
    )
    @test TimeSeries.timestamp(ta2)[1:10] ==
          IS.get_time_series_timestamps(
        component,
        forecast;
        start_time = start_time,
        len = 10,
    )
    @test TimeSeries.values(ta2)[1:10] == IS.get_time_series_values(
        IS.Deterministic,
        component,
        name;
        start_time = start_time,
        len = len,
    )
    @test TimeSeries.values(ta2)[1:10] ==
          IS.get_time_series_values(component, forecast; start_time = start_time, len = 10)
    @test TimeSeries.values(ta2)[1:10] == TimeSeries.values(
        IS.get_time_series_array(component, forecast; start_time = start_time, len = 10),
    )
end

@testset "Test get_time_series_array Probabilistic" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data1 = rand(horizon_count, 99)
    data2 = rand(horizon_count, 99)
    data_vec = Dict(initial_time => data1, other_time => data2)
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Probabilistic(name, data_vec, ones(99), resolution)
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)
    @test IS.get_initial_timestamp(forecast) == initial_time
    forecast_retrieved =
        IS.get_time_series(
            IS.Probabilistic,
            component,
            "test";
            start_time = initial_time,
        )
    @test IS.get_initial_timestamp(forecast_retrieved) == initial_time
    t = IS.get_time_series_array(
        IS.Probabilistic,
        component,
        "test";
        start_time = initial_time,
    )
    @test size(t) == (24, 99)
    @test TimeSeries.values(t) == data1

    t = IS.get_time_series_array(
        IS.Probabilistic,
        component,
        "test";
        start_time = initial_time,
        len = 12,
    )
    @test size(t) == (12, 99)
    @test TimeSeries.values(t) == data1[1:12, :]
    t_other =
        IS.get_time_series(IS.Probabilistic, component, "test"; start_time = other_time)
    @test collect(keys(IS.get_data(t_other)))[1] == other_time
end

@testset "Test get_time_series_array Scenarios" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data1 = rand(horizon_count, 99)
    data2 = rand(horizon_count, 99)
    data_vec = Dict(initial_time => data1, other_time => data2)
    sys = IS.SystemData()
    component_name = "Component1"
    component = IS.TestComponent(component_name, 5)
    IS.add_component!(sys, component)
    forecast = IS.Scenarios(name, data_vec, resolution)
    IS.add_time_series!(sys, component, forecast)
    @test IS.has_time_series(component)
    @test IS.get_initial_timestamp(forecast) == initial_time
    forecast_retrieved =
        IS.get_time_series(IS.Scenarios, component, "test"; start_time = initial_time)
    @test IS.get_initial_timestamp(forecast_retrieved) == initial_time
    t = IS.get_time_series_array(
        IS.Scenarios,
        component,
        "test";
        start_time = initial_time,
    )
    @test size(t) == (24, 99)
    @test TimeSeries.values(t) == data1

    t = IS.get_time_series_array(
        IS.Scenarios,
        component,
        "test";
        start_time = initial_time,
        len = 12,
    )
    @test size(t) == (12, 99)
    @test TimeSeries.values(t) == data1[1:12, :]
    t_other =
        IS.get_time_series(IS.Scenarios, component, "test"; start_time = other_time)
    @test collect(keys(IS.get_data(t_other)))[1] == other_time
end

@testset "Test conflicting time series parameters" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    resolution = Dates.Hour(1)
    initial_time = Dates.DateTime("2020-09-01")
    second_time = initial_time + resolution
    name = "test"
    horizon_count = 24

    # Horizon must be greater than 1.
    bad_data = SortedDict{Dates.DateTime, Vector{Float64}}(
        initial_time => ones(1),
        second_time => ones(1),
    )
    forecast = IS.Deterministic(; data = bad_data, name = name, resolution = resolution)
    @test_throws ArgumentError IS.add_time_series!(sys, component, forecast)

    # Arrays must have the same length.
    bad_data = SortedDict{Dates.DateTime, Vector{Float64}}(
        initial_time => ones(2),
        second_time => ones(3),
    )
    forecast = IS.Deterministic(;
        data = bad_data,
        name = name,
        resolution = resolution,
    )
    @test_throws DimensionMismatch IS.add_time_series!(sys, component, forecast)

    # Set baseline parameters for the rest of the tests.
    data =
        SortedDict{Dates.DateTime, Vector{Float64}}(
            initial_time => ones(horizon_count),
            second_time => ones(horizon_count),
        )
    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution)
    IS.add_time_series!(sys, component, forecast)

    # Different initial time implies different interval, which is a separate group.
    initial_time2 = Dates.DateTime("2020-09-02")
    name = "test2"
    data =
        SortedDict{Dates.DateTime, Vector{Float64}}(
            initial_time2 => ones(horizon_count),
            second_time => ones(horizon_count),
        )

    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution)
    IS.add_time_series!(sys, component, forecast)

    # Different resolutions are allowed as separate (resolution, interval) groups.
    resolution2 = Dates.Minute(5)
    name = "test4"
    data =
        SortedDict{Dates.DateTime, Vector{Float64}}(
            initial_time => ones(horizon_count),
            second_time => ones(horizon_count),
        )

    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution2)
    IS.add_time_series!(sys, component, forecast)

    # Conflicting count
    name = "test3"
    third_time = second_time + resolution
    data = SortedDict(
        initial_time => ones(horizon_count),
        second_time => ones(horizon_count),
        third_time => ones(horizon_count),
    )

    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution)
    @test_throws IS.ConflictingInputsError IS.add_time_series!(sys, component, forecast)
end

@testset "Test deepcopy on HDF5" begin
    sys = IS.SystemData(; time_series_in_memory = false)
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_timestamp = Dates.DateTime("2020-01-01T00:00:00")
    horizon_count = 24
    resolution = Dates.Hour(1)
    other_timestamp = initial_timestamp + resolution
    data_input = rand(horizon_count)
    data_input2 = rand(horizon_count)
    data = SortedDict{Dates.DateTime, Vector{Float64}}(
        initial_timestamp => data_input,
        other_timestamp => data_input2,
    )
    time_series = IS.Deterministic(; name = name, resolution = resolution, data = data)
    fdata = IS.get_data(time_series)
    @test initial_timestamp == first(keys((fdata)))
    @test data_input == first(values((fdata)))

    IS.add_time_series!(sys, component, time_series)
    new_sys = deepcopy(sys)
    orig_file = IS.get_file_path(sys.time_series_manager.data_store)
    new_file = IS.get_file_path(new_sys.time_series_manager.data_store)
    @test orig_file != new_file

    component2 = IS.get_component(IS.TestComponent, sys, name)
    time_series2 = IS.get_time_series(IS.Deterministic, component2, name)
    @test time_series2 isa IS.Deterministic
    fdata2 = IS.get_data(time_series2)
    @test initial_timestamp == first(keys((fdata2)))
    @test data_input == first(values((fdata2)))
end

@testset "Test copy_h5_file" begin
    function compare_attributes(src, dst)
        src_keys = collect(keys(HDF5.attributes(src)))
        dst_keys = collect(keys(HDF5.attributes(dst)))
        @test !isempty(src_keys)
        @test dst_keys == src_keys
        for name in src_keys
            @test HDF5.read(HDF5.attributes(dst)[name]) ==
                  HDF5.read(HDF5.attributes(src)[name])
        end
    end

    for compression_enabled in (true, false)
        compression = IS.CompressionSettings(; enabled = compression_enabled)
        sys = IS.SystemData(; time_series_in_memory = false, compression = compression)
        @test sys.time_series_manager.data_store.compression.enabled ==
              compression_enabled
        name = "Component1"
        name = "val"
        component = IS.TestComponent(name, 5)
        IS.add_component!(sys, component)

        initial_timestamp = Dates.DateTime("2020-01-01T00:00:00")
        horizon_count = 24
        resolution = Dates.Hour(1)
        data_input = rand(horizon_count)
        data_input2 = rand(horizon_count)
        other_timestamp = initial_timestamp + resolution
        data = SortedDict{Dates.DateTime, Vector{Float64}}(
            initial_timestamp => data_input,
            other_timestamp => data_input2,
        )
        for i in 1:2
            time_series =
                IS.Deterministic(;
                    name = "name_$i",
                    resolution = resolution,
                    data = data,
                )
            IS.add_time_series!(sys, component, time_series)
        end
        old_file = IS.get_file_path(sys.time_series_manager.data_store)
        new_file, io = mktemp()
        close(io)
        IS.copy_h5_file(old_file, new_file)

        HDF5.h5open(old_file, "r") do fo
            old_uuids = collect(keys(fo[IS.HDF5_TS_ROOT_PATH]))
            @test length(old_uuids) == 2
            HDF5.h5open(new_file, "r") do fn
                compare_attributes(fo[IS.HDF5_TS_ROOT_PATH], fn[IS.HDF5_TS_ROOT_PATH])
                new_uuids = collect(keys(fn[IS.HDF5_TS_ROOT_PATH]))
                @test length(new_uuids) == 2
                @test old_uuids == new_uuids
                for uuid in new_uuids
                    compare_attributes(
                        fo[IS.HDF5_TS_ROOT_PATH][uuid],
                        fn[IS.HDF5_TS_ROOT_PATH][uuid],
                    )
                    old_data = fo[IS.HDF5_TS_ROOT_PATH][uuid]["data"][:, :]
                    new_data = fn[IS.HDF5_TS_ROOT_PATH][uuid]["data"][:, :]
                    @test old_data == new_data
                end
            end
        end
    end
end

@testset "Test assign_new_uuid_internal! for component with time series" begin
    for in_memory in (true, false)
        sys = IS.SystemData(; time_series_in_memory = in_memory)
        name = "Component1"
        component = IS.TestComponent(name, 5)
        IS.add_component!(sys, component)

        initial_time = Dates.DateTime("2020-09-01")
        resolution = Dates.Hour(1)
        name = "test"

        data =
            TimeSeries.TimeArray(
                range(initial_time; length = 24, step = resolution),
                ones(24),
            )
        data = IS.SingleTimeSeries(; data = data, name = name)
        IS.add_time_series!(sys, component, data)
        @test IS.get_time_series(IS.SingleTimeSeries, component, name) isa
              IS.SingleTimeSeries

        old_uuid = IS.get_uuid(component)
        IS.assign_new_uuid_internal!(component)
        new_uuid = IS.get_uuid(component)
        @test old_uuid != new_uuid

        # The time series storage uses component UUIDs, so they must get updated.
        @test IS.get_time_series(IS.SingleTimeSeries, component, name) isa
              IS.SingleTimeSeries
    end
end

@testset "Test SingleTimeSeries shared by two component fields" begin
    for use_scaling_factor in (true, false)
        for in_memory in (true, false)
            sys = IS.SystemData(; time_series_in_memory = in_memory)
            component = IS.TestComponent("Component1", 2; val2 = 3)
            IS.add_component!(sys, component)

            initial_time = Dates.DateTime("2020-01-01T00:00:00")
            end_time = Dates.DateTime("2020-01-01T23:00:00")
            dates = collect(initial_time:Dates.Hour(1):end_time)
            len = length(dates)
            resolution = Dates.Hour(1)
            data = rand(24)
            ta = TimeSeries.TimeArray(dates, data, ["1"])
            name1 = "val"
            name2 = "val2"
            sfm1 = use_scaling_factor ? IS.get_val : nothing
            sfm2 = use_scaling_factor ? IS.get_val2 : nothing
            ts1a = IS.SingleTimeSeries(;
                name = name1,
                data = ta,
                scaling_factor_multiplier = sfm1,
            )
            IS.add_time_series!(sys, component, ts1a)
            ts2a = IS.SingleTimeSeries(ts1a, name2; scaling_factor_multiplier = sfm2)
            IS.add_time_series!(sys, component, ts2a)
            @test IS.get_num_time_series(sys) == 1
            ts1b = IS.get_time_series(IS.SingleTimeSeries, component, name1)
            ts2b = IS.get_time_series(IS.SingleTimeSeries, component, name2)
            @test ts1b.data == ts2b.data
            ta_vals = TimeSeries.values(ta)
            expected1 = use_scaling_factor ? ta_vals * component.val : ta_vals
            expected2 = use_scaling_factor ? ta_vals * component.val2 : ta_vals
            @test IS.get_time_series_values(
                component,
                ts1b;
                start_time = initial_time,
            ) == expected1
            @test IS.get_time_series_values(
                component,
                ts2b;
                start_time = initial_time,
            ) == expected2
        end
    end
end

function test_forecasts_with_shared_component_fields(forecast_type)
    for use_scaling_factor in (true, false)
        for in_memory in (true, false)
            sys = IS.SystemData(; time_series_in_memory = in_memory)
            component = IS.TestComponent("Component1", 2; val2 = 3)
            IS.add_component!(sys, component)

            initial_time = Dates.DateTime("2020-01-01T00:00:00")
            end_time = Dates.DateTime("2020-01-01T23:00:00")
            dates = collect(initial_time:Dates.Hour(1):end_time)
            len = length(dates)
            resolution = Dates.Hour(1)
            other_time = initial_time + resolution
            name1 = "val"
            name2 = "val2"
            horizon_count = 24
            sfm1 = use_scaling_factor ? IS.get_val : nothing
            sfm2 = use_scaling_factor ? IS.get_val2 : nothing
            if forecast_type <: IS.Deterministic
                data =
                    SortedDict(
                        initial_time => rand(horizon_count),
                        other_time => rand(horizon_count),
                    )
                forecast1a = IS.Deterministic(;
                    data = data,
                    name = name1,
                    resolution = resolution,
                    scaling_factor_multiplier = sfm1,
                )
            elseif forecast_type <: IS.Probabilistic
                data =
                    Dict(
                        initial_time => rand(horizon_count, 99),
                        other_time => ones(horizon_count, 99),
                    )
                forecast1a = IS.Probabilistic(
                    name1,
                    data,
                    ones(99),
                    resolution;
                    scaling_factor_multiplier = sfm1,
                )
            elseif forecast_type <: IS.Scenarios
                data =
                    Dict(
                        initial_time => rand(horizon_count, 99),
                        other_time => ones(horizon_count, 99),
                    )
                forecast1a =
                    IS.Scenarios(
                        name1,
                        data,
                        resolution;
                        scaling_factor_multiplier = sfm1,
                    )
            else
                error("Unsupported forecast type: $forecast_type")
            end
            IS.add_time_series!(sys, component, forecast1a)
            forecast2a =
                forecast_type(forecast1a, name2; scaling_factor_multiplier = sfm2)
            IS.add_time_series!(sys, component, forecast2a)
            @test IS.get_num_time_series(sys) == 1
            forecast1b = IS.get_time_series(forecast_type, component, name1)
            forecast2b = IS.get_time_series(forecast_type, component, name2)
            @test forecast1b.data == forecast2b.data
            expected1 =
                if use_scaling_factor
                    data[initial_time] * component.val
                else
                    data[initial_time]
                end
            expected2 = if use_scaling_factor
                data[initial_time] * component.val2
            else
                data[initial_time]
            end
            @test IS.get_time_series_values(
                component,
                forecast1b;
                start_time = initial_time,
            ) == expected1
            @test IS.get_time_series_values(
                component,
                forecast2b;
                start_time = initial_time,
            ) == expected2
            IS.remove_time_series!(sys, forecast_type, component, "val")
            @test IS.get_num_time_series(sys) == 1
            @test IS.get_time_series_values(
                component,
                forecast2b;
                start_time = initial_time,
            ) == expected2
            IS.remove_time_series!(sys, forecast_type, component, "val2")
            @test IS.get_num_time_series(sys) == 0
        end
    end
end

@testset "Test Deterministic shared by two component fields" begin
    test_forecasts_with_shared_component_fields(IS.Deterministic)
end

@testset "Test Probabilistic shared by two component fields" begin
    test_forecasts_with_shared_component_fields(IS.Probabilistic)
end

@testset "Test Scenarios shared by two component fields" begin
    test_forecasts_with_shared_component_fields(IS.Scenarios)
end

@testset "Test custom time series directory via env" begin
    @assert !haskey(ENV, IS.TIME_SERIES_DIRECTORY_ENV_VAR)
    path = mkpath("tmp-ts-dir")
    ENV[IS.TIME_SERIES_DIRECTORY_ENV_VAR] = path
    try
        sys = IS.SystemData()
        @test splitpath(sys.time_series_manager.data_store.file_path)[1] == path
    finally
        pop!(ENV, IS.TIME_SERIES_DIRECTORY_ENV_VAR)
    end
end

@testset "Test time series counts" begin
    sys = create_system_data_shared_time_series(; time_series_in_memory = true)
    counts = IS.get_time_series_counts(sys)
    @test counts.static_time_series_count == 1
    @test counts.components_with_time_series == 2
end

@testset "Test custom time series directories" begin
    @test IS._get_time_series_parent_dir(nothing) == tempdir()
    @test IS._get_time_series_parent_dir(pwd()) == pwd()
    @test_throws ErrorException IS._get_time_series_parent_dir(
        "/some/invalid/directory/",
    )

    ENV["SIENNA_TIME_SERIES_DIRECTORY"] = pwd()
    try
        @test IS._get_time_series_parent_dir() == pwd()
        ENV["SIENNA_TIME_SERIES_DIRECTORY"] = "/some/invalid/directory/"
        @test_throws ErrorException IS._get_time_series_parent_dir()
    finally
        pop!(ENV, "SIENNA_TIME_SERIES_DIRECTORY")
    end
end

@testset "Test get_time_series_uuid" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    data = TimeSeries.TimeArray(
        range(initial_time; length = 365, step = resolution),
        rand(365),
    )
    ts_name = "test"
    ts = IS.SingleTimeSeries(; data = data, name = ts_name)
    uuid = IS.get_uuid(ts)
    IS.add_time_series!(sys, component, ts)
    ts2 = IS.get_time_series_uuid(IS.SingleTimeSeries, component, ts_name)
end

@testset "Test serialization of time series keys" begin
    key = IS.StaticTimeSeriesKey(
        IS.SingleTimeSeries,
        "test",
        Dates.now(),
        Dates.Hour(1),
        12,
        Dict("scenario" => "high"),
    )
    key2 = IS.deserialize(IS.StaticTimeSeriesKey, IS.serialize(key))
    @test key2 !== key
    for field in fieldnames(IS.StaticTimeSeriesKey)
        if field == :features
            @test key2.features["scenario"] == key.features["scenario"]
        else
            @test getproperty(key2, field) == getproperty(key, field)
        end
    end
end

@testset "Test get_time_series_timestamps with TimeSeriesKey" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    dates = collect(range(initial_time; length = 24, step = resolution))
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    ts_name = "test_single"
    ts = IS.SingleTimeSeries(; data = ta, name = ts_name)
    key = IS.add_time_series!(sys, component, ts)
    timestamps = IS.get_time_series_timestamps(component, key)
    @test timestamps == dates
    @test timestamps ==
          IS.get_time_series_timestamps(IS.SingleTimeSeries, component, ts_name)

    timestamps_subset =
        IS.get_time_series_timestamps(component, key; start_time = dates[5], len = 5)
    @test timestamps_subset == dates[5:9]
    @test timestamps_subset == IS.get_time_series_timestamps(
        IS.SingleTimeSeries, component, ts_name; start_time = dates[5], len = 5,
    )

    other_time = initial_time + resolution
    horizon_count = 12
    forecast_data = SortedDict{DateTime, Vector{Float64}}(
        initial_time => collect(1:horizon_count),
        other_time => collect(1:horizon_count) .+ 100,
    )
    forecast_name = "test_forecast"
    forecast = IS.Deterministic(;
        data = forecast_data,
        name = forecast_name,
        resolution = resolution,
    )
    forecast_key = IS.add_time_series!(sys, component, forecast)
    forecast_timestamps =
        IS.get_time_series_timestamps(component, forecast_key; start_time = other_time)
    expected_timestamps =
        collect(range(other_time; length = horizon_count, step = resolution))
    @test forecast_timestamps == expected_timestamps
    @test forecast_timestamps == IS.get_time_series_timestamps(
        IS.Deterministic, component, forecast_name; start_time = other_time,
    )
end

@testset "Test get_time_series_array with TimeSeriesKey" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    dates = collect(range(initial_time; length = 24, step = resolution))
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    ts_name = "test_array"
    ts = IS.SingleTimeSeries(;
        data = ta,
        name = ts_name,
        scaling_factor_multiplier = IS.get_val,
    )
    key = IS.add_time_series!(sys, component, ts)

    ta_result = IS.get_time_series_array(component, key)
    @test ta_result isa TimeSeries.TimeArray
    @test TimeSeries.timestamp(ta_result) == dates
    @test TimeSeries.values(ta_result) == data * component_val

    ta_by_name = IS.get_time_series_array(IS.SingleTimeSeries, component, ts_name)
    @test TimeSeries.timestamp(ta_result) == TimeSeries.timestamp(ta_by_name)
    @test TimeSeries.values(ta_result) == TimeSeries.values(ta_by_name)

    ta_subset = IS.get_time_series_array(component, key; start_time = dates[5], len = 5)
    @test TimeSeries.timestamp(ta_subset) == dates[5:9]
    @test TimeSeries.values(ta_subset) == data[5:9] * component_val

    ta_unscaled = IS.get_time_series_array(component, key; ignore_scaling_factors = true)
    @test TimeSeries.timestamp(ta_unscaled) == dates
    @test TimeSeries.values(ta_unscaled) == data

    other_time = initial_time + resolution
    horizon_count = 12
    forecast_data = SortedDict{DateTime, Vector{Float64}}(
        initial_time => ones(horizon_count),
        other_time => ones(horizon_count) * 2,
    )
    forecast_name = "test_forecast_array"
    forecast = IS.Deterministic(;
        data = forecast_data,
        name = forecast_name,
        resolution = resolution,
        scaling_factor_multiplier = IS.get_val,
    )
    forecast_key = IS.add_time_series!(sys, component, forecast)

    ta_forecast = IS.get_time_series_array(component, forecast_key; start_time = other_time)
    expected_timestamps =
        collect(range(other_time; length = horizon_count, step = resolution))
    @test TimeSeries.timestamp(ta_forecast) == expected_timestamps
    @test TimeSeries.values(ta_forecast) == ones(horizon_count) * 2 * component_val

    ta_forecast_by_name = IS.get_time_series_array(
        IS.Deterministic, component, forecast_name; start_time = other_time,
    )
    @test TimeSeries.timestamp(ta_forecast) == TimeSeries.timestamp(ta_forecast_by_name)
    @test TimeSeries.values(ta_forecast) == TimeSeries.values(ta_forecast_by_name)
end

@testset "Test get_time_series_values with TimeSeriesKey" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    dates = collect(range(initial_time; length = 24, step = resolution))
    data = collect(1:24)
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    ts_name = "test_values"
    ts = IS.SingleTimeSeries(;
        data = ta,
        name = ts_name,
        scaling_factor_multiplier = IS.get_val,
    )
    key = IS.add_time_series!(sys, component, ts)
    values = IS.get_time_series_values(component, key)
    @test values == data * component_val
    @test values == IS.get_time_series_values(IS.SingleTimeSeries, component, ts_name)

    values_subset =
        IS.get_time_series_values(component, key; start_time = dates[5], len = 5)
    @test values_subset == data[5:9] * component_val
    @test values_subset == IS.get_time_series_values(
        IS.SingleTimeSeries, component, ts_name; start_time = dates[5], len = 5,
    )

    values_unscaled =
        IS.get_time_series_values(component, key; ignore_scaling_factors = true)
    @test values_unscaled == data
    @test values_unscaled == IS.get_time_series_values(
        IS.SingleTimeSeries, component, ts_name; ignore_scaling_factors = true,
    )

    other_time = initial_time + resolution
    horizon_count = 12
    forecast_data = SortedDict{DateTime, Vector{Float64}}(
        initial_time => ones(horizon_count),
        other_time => ones(horizon_count) * 2,
    )
    forecast_name = "test_forecast_values"
    forecast = IS.Deterministic(;
        data = forecast_data,
        name = forecast_name,
        resolution = resolution,
        scaling_factor_multiplier = IS.get_val,
    )
    forecast_key = IS.add_time_series!(sys, component, forecast)
    forecast_values =
        IS.get_time_series_values(component, forecast_key; start_time = other_time)
    @test forecast_values == ones(horizon_count) * 2 * component_val
    @test forecast_values == IS.get_time_series_values(
        IS.Deterministic, component, forecast_name; start_time = other_time,
    )

    forecast_values_unscaled = IS.get_time_series_values(
        component, forecast_key; start_time = other_time, ignore_scaling_factors = true,
    )
    @test forecast_values_unscaled == ones(horizon_count) * 2
end

@testset "Test get_time_series functions with TimeSeriesKey and features" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    ts_keys = []
    for scenario in ["high", "low"]
        dates = collect(range(initial_time; length = 24, step = resolution))
        data = scenario == "high" ? collect(1:24) : collect(24:-1:1)
        ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
        ts_name = "power"
        ts = IS.SingleTimeSeries(; data = ta, name = ts_name)
        key = IS.add_time_series!(sys, component, ts; scenario = scenario)
        push!(ts_keys, key)
    end

    for key in ts_keys
        timestamps = IS.get_time_series_timestamps(component, key)
        values = IS.get_time_series_values(component, key)

        @test length(timestamps) == 24
        @test length(values) == 24

        # Verify the values match the expected pattern
        if haskey(key.features, "scenario") && key.features["scenario"] == "high"
            @test values == collect(1:24)
        elseif haskey(key.features, "scenario") && key.features["scenario"] == "low"
            @test values == collect(24:-1:1)
        end
    end

    # Test with subset parameters
    high_key = filter(
        k -> haskey(k.features, "scenario") && k.features["scenario"] == "high",
        ts_keys,
    )[1]
    timestamps_subset = IS.get_time_series_timestamps(
        component,
        high_key;
        start_time = initial_time + resolution * 5,
        len = 10,
    )
    values_subset = IS.get_time_series_values(
        component,
        high_key;
        start_time = initial_time + resolution * 5,
        len = 10,
    )

    @test length(timestamps_subset) == 10
    @test length(values_subset) == 10
    @test values_subset == collect(6:15)
end

@testset "Test get_total_period" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    data =
        SortedDict(initial_time => rand(horizon_count), other_time => rand(horizon_count))

    forecast = IS.Deterministic(; data = data, name = name, resolution = resolution)
    IS.add_time_series!(sys, component, forecast)
    @test IS.get_forecast_total_period(sys) ==
          other_time + horizon_count * resolution - initial_time
end

@testset "Test forecast utils" begin
    @test_throws ErrorException IS.get_horizon_count(Dates.Hour(1), Dates.Minute(33))
end

@testset "Test bulk_add_time_series" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24

    make_values(count, index) = ones(count) * index
    associations = (
        IS.TimeSeriesAssociation(
            component,
            IS.Deterministic(;
                data = SortedDict(
                    initial_time => make_values(horizon_count, i),
                    other_time => make_values(horizon_count, i),
                ),
                name = "ts_$(i)", resolution = resolution,
            );
            model_year = "high",
        )
        for i in 1:30
    )
    IS.bulk_add_time_series!(sys, associations; batch_size = 13)
    ts_keys = IS.get_time_series_keys(component)
    @test length(ts_keys) == 30
    actual_ts_data = Dict(IS.get_name(x) => x for x in ts_keys)
    for i in 1:30
        name = "ts_$(i)"
        @test haskey(actual_ts_data, name)
        key = actual_ts_data[name]
        ts = IS.get_time_series(component, key)
        @test ts isa IS.Deterministic
        data = IS.get_data(ts)
        @test !isempty(values(data))
        for val in values(data)
            @test val == make_values(horizon_count, i)
        end
    end
end

@testset "Test bulk_add_time_series with duplicates" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24
    forecast = IS.Deterministic(;
        data = SortedDict(
            initial_time => rand(10),
            other_time => rand(10),
        ),
        name = "ts", resolution = resolution,
    )

    @test_throws ArgumentError IS.bulk_add_time_series!(
        sys,
        [
            IS.TimeSeriesAssociation(component, forecast; model_year = "high"),
            IS.TimeSeriesAssociation(component, forecast; model_year = "low"),
            IS.TimeSeriesAssociation(component, forecast; model_year = "high"),
        ],
    )

    @test_throws ArgumentError IS.bulk_add_time_series!(
        sys,
        [
            IS.TimeSeriesAssociation(component, forecast),
            IS.TimeSeriesAssociation(component, forecast),
            IS.TimeSeriesAssociation(component, forecast),
        ],
    )
end

@testset "Test bulk addition of time series with transaction" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24

    make_values(count, index) = ones(count) * index
    IS.begin_time_series_update(sys.time_series_manager) do
        for i in 1:5
            forecast = IS.Deterministic(;
                data = SortedDict(
                    initial_time => make_values(horizon_count, i),
                    other_time => make_values(horizon_count, i),
                ),
                name = "ts_$(i)", resolution = resolution,
            )
            IS.add_time_series!(sys, component, forecast; model_year = "high")
        end
    end
    ts_keys = IS.get_time_series_keys(component)
    @test length(ts_keys) == 5
    actual_ts_data = Dict(IS.get_name(x) => x for x in ts_keys)
    for i in 1:5
        name = "ts_$(i)"
        @test haskey(actual_ts_data, name)
        key = actual_ts_data[name]
        ts = IS.get_time_series(component, key)
        @test ts isa IS.Deterministic
        data = IS.get_data(ts)
        @test !isempty(values(data))
        for val in values(data)
            @test val == make_values(horizon_count, i)
        end
    end
end

@testset "Test bulk addition of time series with transaction and error" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    other_time = initial_time + resolution
    name = "test"
    horizon_count = 24

    make_values(count, index) = ones(count) * index

    bystander = IS.Deterministic(;
        data = SortedDict(
            initial_time => rand(horizon_count),
            other_time => rand(horizon_count),
        ),
        name = "bystander", resolution = resolution,
    )
    IS.add_time_series!(sys, component, bystander)

    @test_throws(
        ArgumentError,
        IS.begin_time_series_update(sys.time_series_manager) do
            for i in 1:5
                if i < 5
                    name = "ts_$i"
                else
                    name = "ts_$(i - 1)"
                end
                forecast = IS.Deterministic(;
                    data = SortedDict(
                        initial_time => make_values(horizon_count, i),
                        other_time => make_values(horizon_count, i),
                    ),
                    name = name, resolution = resolution,
                )
                IS.add_time_series!(sys, component, forecast)
            end
        end,
    )
    ts_keys = IS.get_time_series_keys(component)
    @test length(ts_keys) == 1
    key = ts_keys[1]
    @test IS.get_name(key) == "bystander"
    res = IS.get_time_series(component, key)
    @test res isa IS.Deterministic
    @test IS.get_data(res) == IS.get_data(bystander)
end

@testset "Test migration of IS 2.3 time series schema to metadata format v1.0.0" begin
    filename, component = _setup_for_migration_tests_from_IS_v2_3()
    new_db = SQLite.DB(filename)
    @test IS._needs_migration_from_v2_3(new_db)
    new_store = IS.TimeSeriesMetadataStore(filename)
    @test !IS._needs_migration_from_v2_4(new_store.db)
    result = IS.list_metadata(new_store, component)
    @test length(result) == 4
end

@testset "Test migration of IS 2.4 time series schema to metadata format v1.0.0" begin
    filename, component = _setup_for_migration_tests_from_IS_v2_4()
    new_db = SQLite.DB(filename)
    new_rows = Tuple[]
    for row in Tables.rowtable(
        SQLite.DBInterface.execute(
            new_db,
            "SELECT * FROM $(IS.ASSOCIATIONS_TABLE_NAME)",
        ),
    )
        new_row = (
            row.id,
            row.time_series_uuid,
            row.time_series_type,
            "unused_time_series_category",
            row.initial_timestamp,
            IS.from_iso_8601(row.resolution),
            ismissing(row.horizon) ? nothing : IS.from_iso_8601(row.horizon),
            ismissing(row.interval) ? nothing : IS.from_iso_8601(row.interval),
            row.window_count,
            row.length,
            row.name,
            row.owner_uuid,
            row.owner_type,
            row.owner_category,
            row.features,
            row.metadata_uuid,
        )
        push!(new_rows, new_row)
    end
    SQLite.DBInterface.execute(new_db, "DROP TABLE $(IS.ASSOCIATIONS_TABLE_NAME)")
    # This is the original schema for the migration.
    schema = [
        "id INTEGER PRIMARY KEY",
        "time_series_uuid TEXT NOT NULL",
        "time_series_type TEXT NOT NULL",
        "time_series_category TEXT NOT NULL",
        "initial_timestamp TEXT NOT NULL",
        "resolution_ms INTEGER NOT NULL",
        "horizon_ms INTEGER",
        "interval_ms INTEGER",
        "window_count INTEGER",
        "length INTEGER",
        "name TEXT NOT NULL",
        "owner_uuid TEXT NOT NULL",
        "owner_type TEXT NOT NULL",
        "owner_category TEXT NOT NULL",
        "features TEXT NOT NULL",
        "metadata_uuid TEXT NOT NULL",
    ]
    schema_text = join(schema, ",")
    SQLite.DBInterface.execute(
        new_db,
        "CREATE TABLE $(IS.ASSOCIATIONS_TABLE_NAME)($(schema_text))",
    )
    IS._add_rows!(
        new_db,
        new_rows,
        (
            "id",
            "time_series_uuid",
            "time_series_type",
            "time_series_category",
            "initial_timestamp",
            "resolution_ms",
            "horizon_ms",
            "interval_ms",
            "window_count",
            "length",
            "name",
            "owner_uuid",
            "owner_type",
            "owner_category",
            "features",
            "metadata_uuid",
        ),
        IS.ASSOCIATIONS_TABLE_NAME,
    )
    @test IS._needs_migration_from_v2_4(new_db)
    new_store = IS.TimeSeriesMetadataStore(filename)
    @test !IS._needs_migration_from_v2_4(new_store.db)
    result = IS.list_metadata(new_store, component)
    @test length(result) == 4
end

"""
Create a SQLite database in the format of IS v2.3. Return the db filename.
"""
function _setup_for_migration_tests_from_IS_v2_3()
    sys, component = _create_system_for_migration_tests()
    filename = IS.backup_to_temp(sys.time_series_manager.metadata_store)
    new_db = SQLite.DB(filename)
    SQLite.DBInterface.execute(new_db, "DROP TABLE time_series_associations")
    SQLite.DBInterface.execute(new_db, "DROP TABLE $(IS.KEY_VALUE_TABLE_NAME)")
    try
        _create_metadata_table_v2_3!(new_db)
        placeholder = repeat("?,", 15) * "jsonb(?)"
        query = "INSERT INTO $(IS.METADATA_TABLE_NAME) VALUES($placeholder)"
        SQLite.transaction(new_db) do
            stmt = SQLite.Stmt(new_db, query)
            for metadata in values(sys.time_series_manager.metadata_store.metadata_uuids)
                owner_category = "Component"
                ts_type = IS.time_series_metadata_to_data(metadata)
                @assert ts_type === IS.SingleTimeSeries
                ts_category = "StaticTimeSeries"
                features = IS.make_features_string(metadata.features)
                params =
                    (
                        missing,
                        string(IS.get_time_series_uuid(metadata)),
                        string(nameof(ts_type)),
                        ts_category,
                        string(IS.get_initial_timestamp(metadata)),
                        Dates.Millisecond(IS.get_resolution(metadata)).value,
                        missing,
                        missing,
                        missing,
                        IS.get_length(metadata),
                        IS.get_name(metadata),
                        string(IS.get_uuid(component)),
                        string(nameof(typeof(component))),
                        owner_category,
                        features,
                        JSON.json(IS.serialize(metadata)),
                    )
                SQLite.DBInterface.execute(stmt, params)
            end
        end
    finally
        close(new_db)
    end
    return filename, component
end

function _setup_for_migration_tests_from_IS_v2_4()
    sys, component = _create_system_for_migration_tests()
    filename = IS.backup_to_temp(sys.time_series_manager.metadata_store)
    new_db = SQLite.DB(filename)
    SQLite.DBInterface.execute(new_db, "DROP TABLE $(IS.KEY_VALUE_TABLE_NAME)")
    try
        _create_metadata_table_v2_4!(new_db)
        query = "INSERT INTO $(IS.METADATA_TABLE_NAME) VALUES(?,?,jsonb(?))"
        SQLite.transaction(new_db) do
            stmt = SQLite.Stmt(new_db, query)
            for metadata in values(sys.time_series_manager.metadata_store.metadata_uuids)
                params =
                    (
                        missing,
                        string(IS.get_uuid(metadata)),
                        JSON.json(IS.serialize(metadata)),
                    )
                SQLite.DBInterface.execute(stmt, params)
            end
        end
    finally
        close(new_db)
    end
    return filename, component
end

function _create_system_for_migration_tests()
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    data = TimeSeries.TimeArray(
        range(initial_time; length = 5, step = resolution),
        rand(5),
    )
    ts_name = "test_c"
    ts = IS.SingleTimeSeries(; data = data, name = ts_name)
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = "2030")
    IS.add_time_series!(sys, component, ts; scenario = "high", model_year = "2030")
    IS.add_time_series!(sys, component, ts; scenario = "low", model_year = "2035")
    IS.add_time_series!(sys, component, ts; scenario = "high", model_year = "2035")
    return sys, component
end

function _create_metadata_table_v2_4!(db::SQLite.DB)
    schema = [
        "id INTEGER PRIMARY KEY",
        "metadata_uuid TEXT NOT NULL",
        "metadata JSON NOT NULL",
    ]
    schema_text = join(schema, ",")
    SQLite.DBInterface.execute(
        db,
        "CREATE TABLE $(IS.METADATA_TABLE_NAME)($(schema_text))",
    )
    return
end

function _create_metadata_table_v2_3!(db::SQLite.DB)
    schema = [
        "id INTEGER PRIMARY KEY",
        "time_series_uuid TEXT NOT NULL",
        "time_series_type TEXT NOT NULL",
        "time_series_category TEXT NOT NULL",
        "initial_timestamp TEXT NOT NULL",
        "resolution_ms INTEGER NOT NULL",
        "horizon_ms INTEGER",
        "interval_ms INTEGER",
        "window_count INTEGER",
        "length INTEGER",
        "name TEXT NOT NULL",
        "owner_uuid TEXT NOT NULL",
        "owner_type TEXT NOT NULL",
        "owner_category TEXT NOT NULL",
        "features TEXT NOT NULL",
        "metadata JSON NOT NULL",
    ]
    schema_text = join(schema, ",")
    SQLite.DBInterface.execute(
        db,
        "CREATE TABLE time_series_metadata($(schema_text))",
    )
    return
end

@testset "Test invalid normalization factors" begin
    sys = IS.SystemData()
    name = "Component1"
    component_val = 5
    component = IS.TestComponent(name, component_val)
    IS.add_component!(sys, component)

    dates = create_dates("2020-01-01T00:00:00", Dates.Hour(1), "2020-01-01T02:00:00")
    data = [0.0, 0.0, 0.0]
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    @test_throws ErrorException IS.SingleTimeSeries(
        "val",
        ta;
        normalization_factor = IS.NormalizationTypes.MAX,
    )
    data = [1.1, 1.2, 1.3]
    ta = TimeSeries.TimeArray(dates, data, [IS.get_name(component)])
    @test_throws ErrorException IS.SingleTimeSeries(
        "val",
        ta;
        normalization_factor = 0.0,
    )
end

"""
Create a system with two SingleTimeSeries and two Deterministic time series,
two resolutions each. One component bystander.
"""
function setup_for_multi_resolution_tests()
    sys = IS.SystemData()
    name = "Component1"
    sts_name = "test_sts"
    f_name = "test_det"
    component = IS.TestComponent(name, 1)
    IS.add_component!(sys, component)
    IS.add_component!(sys, IS.TestComponent("bystander", 2))

    initial_time = Dates.DateTime("2020-09-01")
    resolution1 = Dates.Minute(5)
    length1 = 25
    data1 = TimeSeries.TimeArray(
        range(initial_time; length = length1, step = resolution1),
        rand(length1),
    )
    sts1 = IS.SingleTimeSeries(; data = data1, name = sts_name)

    resolution2 = Dates.Minute(10)
    length2 = 13
    data2 = TimeSeries.TimeArray(
        range(initial_time; length = length2, step = resolution2),
        rand(length2),
    )
    sts2 = IS.SingleTimeSeries(; data = data2, name = sts_name)

    IS.add_time_series!(sys, component, sts1)
    IS.add_time_series!(sys, component, sts2)

    other_time1 = initial_time + resolution1
    horizon_count1 = 24
    data1 =
        SortedDict(
            initial_time => rand(horizon_count1),
            other_time1 => rand(horizon_count1),
        )
    forecast1 = IS.Deterministic(; data = data1, name = f_name, resolution = resolution1)

    other_time2 = initial_time + resolution2
    horizon_count2 = 12
    data2 =
        SortedDict(
            initial_time => rand(horizon_count2),
            other_time2 => rand(horizon_count2),
        )
    forecast2 = IS.Deterministic(; data = data2, name = f_name, resolution = resolution2)

    IS.add_time_series!(sys, component, forecast1)
    IS.add_time_series!(sys, component, forecast2)

    return (
        system = sys,
        component = component,
        initial_time = initial_time,
        sts_name = sts_name,
        f_name = f_name,
        resolution1 = resolution1,
        resolution2 = resolution2,
        sts1 = sts1,
        sts2 = sts2,
        forecast1 = forecast1,
        forecast2 = forecast2,
    )
end

@testset "Test SingleTimeSeries with multiple resolutions" begin
    params = setup_for_multi_resolution_tests()
    data1 = IS.get_data(params.sts1)
    data2 = IS.get_data(params.sts2)
    component = params.component
    ts_name = params.sts_name
    resolution1 = params.resolution1
    resolution2 = params.resolution2
    ts1 = params.sts1
    ts2 = params.sts2
    @test IS.get_data(
        IS.get_time_series(
            IS.SingleTimeSeries,
            component,
            ts_name;
            resolution = resolution1,
        ),
    ) ==
          IS.get_data(ts1)
    @test IS.get_data(
        IS.get_time_series(
            IS.SingleTimeSeries,
            component,
            ts_name;
            resolution = resolution2,
        ),
    ) ==
          IS.get_data(ts2)
    @test_throws ArgumentError IS.get_time_series(IS.SingleTimeSeries, component, ts_name)
    @test_throws ArgumentError IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        ts_name;
        resolution = Dates.Minute(1),
    )

    @test IS.has_time_series(component, resolution = resolution1)
    @test IS.has_time_series(component, resolution = resolution2)
    @test IS.has_time_series(
        component,
        time_series_type = IS.SingleTimeSeries,
        name = ts_name,
        resolution = resolution1,
    )
    @test IS.has_time_series(
        component,
        time_series_type = IS.SingleTimeSeries,
        name = ts_name,
        resolution = resolution2,
    )
    @test !IS.has_time_series(
        component;
        time_series_type = IS.SingleTimeSeries,
        name = ts_name,
        resolution = Dates.Minute(1),
    )

    @test IS.get_time_series_array(
        IS.SingleTimeSeries,
        component,
        ts_name;
        resolution = resolution1,
    ) == data1
    @test IS.get_time_series_values(
        IS.SingleTimeSeries,
        component,
        ts_name;
        resolution = resolution1,
    ) == TimeSeries.values(data1)
    @test IS.get_time_series_timestamps(
        IS.SingleTimeSeries,
        component,
        ts_name;
        resolution = resolution1,
    ) == TimeSeries.timestamp(data1)

    ts_multiple = collect(
        IS.get_time_series_multiple(
            component;
            type = IS.SingleTimeSeries,
            name = ts_name,
            resolution = resolution1,
        ),
    )
    @test length(ts_multiple) == 1
    @test IS.get_data(ts_multiple[1]) == IS.get_data(params.sts1)
    @test isempty(
        collect(
            IS.get_time_series_multiple(
                component;
                type = IS.SingleTimeSeries,
                name = ts_name,
                resolution = Dates.Minute(1),
            ),
        ),
    )
    @test length(
        IS.get_time_series_metadata(component; time_series_type = IS.SingleTimeSeries),
    ) == 2
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.SingleTimeSeries,
            resolution = resolution1,
        ),
    ) == 1
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.SingleTimeSeries,
            name = ts_name,
            resolution = resolution2,
        ),
    ) == 1
end

@testset "Test Deterministic with multiple resolutions" begin
    params = setup_for_multi_resolution_tests()
    data1 = IS.get_data(params.forecast1)
    data2 = IS.get_data(params.forecast2)
    component = params.component
    f_name = params.f_name
    initial_time = params.initial_time
    resolution1 = params.resolution1
    resolution2 = params.resolution2
    f1 = params.forecast1
    f2 = params.forecast2
    @test IS.get_data(
        IS.get_time_series(
            IS.Deterministic,
            component,
            f_name;
            resolution = resolution1,
        ),
    ) ==
          IS.get_data(f1)
    @test IS.get_data(
        IS.get_time_series(
            IS.Deterministic,
            component,
            f_name;
            resolution = resolution2,
        ),
    ) ==
          IS.get_data(f2)
    @test_throws ArgumentError IS.get_time_series(IS.Deterministic, component, f_name)
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        f_name;
        resolution = Dates.Minute(1),
    )

    @test IS.has_time_series(component, resolution = resolution1)
    @test IS.has_time_series(component, resolution = resolution2)
    @test IS.has_time_series(
        component,
        time_series_type = IS.Deterministic,
        name = f_name,
        resolution = resolution1,
    )
    @test IS.has_time_series(
        component,
        time_series_type = IS.Deterministic,
        name = f_name,
        resolution = resolution2,
    )
    @test !IS.has_time_series(
        component;
        time_series_type = IS.Deterministic,
        name = f_name,
        resolution = Dates.Minute(1),
    )

    fdata = IS.get_time_series_array(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution1,
    )
    @test IS.get_time_series_array(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution1,
    ) == IS.get_time_series_array(component, f1; start_time = initial_time)
    @test IS.get_time_series_values(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution1,
    ) == TimeSeries.values(
        IS.get_time_series_array(component, f1; start_time = initial_time),
    )
    @test IS.get_time_series_timestamps(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution1,
    ) == TimeSeries.timestamp(
        IS.get_time_series_array(component, f1; start_time = initial_time),
    )

    ts_multiple = collect(
        IS.get_time_series_multiple(
            component;
            type = IS.Deterministic,
            name = f_name,
            resolution = resolution1,
        ),
    )
    @test length(ts_multiple) == 1
    @test IS.get_data(ts_multiple[1]) == IS.get_data(f1)
    @test isempty(
        collect(
            IS.get_time_series_multiple(
                component;
                type = IS.Deterministic,
                name = f_name,
                resolution = Dates.Minute(1),
            ),
        ),
    )
    @test length(
        IS.get_time_series_metadata(component; time_series_type = IS.Deterministic),
    ) == 2
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            resolution = resolution1,
        ),
    ) == 1
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            name = f_name,
            resolution = resolution2,
        ),
    ) == 1
end

function setup_for_multi_interval_tests()
    sys = IS.SystemData()
    name = "Component1"
    f_name = "test_det"
    component = IS.TestComponent(name, 1)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Minute(5)
    horizon_count = 24

    # Forecast with hourly interval (windows every hour)
    interval1 = Dates.Hour(1)
    other_time1 = initial_time + interval1
    data1 =
        SortedDict(
            initial_time => rand(horizon_count),
            other_time1 => rand(horizon_count),
        )
    forecast1 = IS.Deterministic(;
        data = data1,
        name = f_name,
        resolution = resolution,
        interval = interval1,
    )

    # Forecast with daily interval (windows every day)
    interval2 = Dates.Day(1)
    other_time2 = initial_time + interval2
    data2 =
        SortedDict(
            initial_time => rand(horizon_count),
            other_time2 => rand(horizon_count),
        )
    forecast2 = IS.Deterministic(;
        data = data2,
        name = f_name,
        resolution = resolution,
        interval = interval2,
    )

    IS.add_time_series!(sys, component, forecast1)
    IS.add_time_series!(sys, component, forecast2)

    return (
        system = sys,
        component = component,
        initial_time = initial_time,
        f_name = f_name,
        resolution = resolution,
        interval1 = interval1,
        interval2 = interval2,
        forecast1 = forecast1,
        forecast2 = forecast2,
    )
end

@testset "Test Deterministic with multiple intervals" begin
    params = setup_for_multi_interval_tests()
    component = params.component
    f_name = params.f_name
    initial_time = params.initial_time
    resolution = params.resolution
    interval1 = params.interval1
    interval2 = params.interval2
    f1 = params.forecast1
    f2 = params.forecast2

    # Retrieving by interval returns correct data
    @test IS.get_data(
        IS.get_time_series(
            IS.Deterministic,
            component,
            f_name;
            resolution = resolution,
            interval = interval1,
        ),
    ) == IS.get_data(f1)
    @test IS.get_data(
        IS.get_time_series(
            IS.Deterministic,
            component,
            f_name;
            resolution = resolution,
            interval = interval2,
        ),
    ) == IS.get_data(f2)

    # Without interval, ambiguous query throws
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution,
    )

    # Non-existent interval throws
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution,
        interval = Dates.Minute(1),
    )

    # has_time_series with interval
    @test IS.has_time_series(
        component,
        IS.Deterministic,
        f_name;
        resolution = resolution,
        interval = interval1,
    )
    @test IS.has_time_series(
        component,
        IS.Deterministic,
        f_name;
        resolution = resolution,
        interval = interval2,
    )
    @test !IS.has_time_series(
        component,
        IS.Deterministic,
        f_name;
        resolution = resolution,
        interval = Dates.Minute(1),
    )

    # get_time_series_array with interval
    @test IS.get_time_series_array(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution,
        interval = interval1,
    ) == IS.get_time_series_array(component, f1; start_time = initial_time)
    @test IS.get_time_series_array(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution,
        interval = interval2,
    ) == IS.get_time_series_array(component, f2; start_time = initial_time)

    # get_time_series_values with interval
    @test IS.get_time_series_values(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution,
        interval = interval1,
    ) == TimeSeries.values(
        IS.get_time_series_array(component, f1; start_time = initial_time),
    )

    # get_time_series_timestamps with interval
    @test IS.get_time_series_timestamps(
        IS.Deterministic,
        component,
        f_name;
        resolution = resolution,
        interval = interval1,
    ) == TimeSeries.timestamp(
        IS.get_time_series_array(component, f1; start_time = initial_time),
    )

    # get_time_series_multiple with interval
    ts_multiple = collect(
        IS.get_time_series_multiple(
            component;
            type = IS.Deterministic,
            name = f_name,
            interval = interval1,
        ),
    )
    @test length(ts_multiple) == 1
    @test IS.get_data(ts_multiple[1]) == IS.get_data(f1)

    ts_multiple_all = collect(
        IS.get_time_series_multiple(
            component;
            type = IS.Deterministic,
            name = f_name,
        ),
    )
    @test length(ts_multiple_all) == 2

    @test isempty(
        collect(
            IS.get_time_series_multiple(
                component;
                type = IS.Deterministic,
                name = f_name,
                interval = Dates.Minute(1),
            ),
        ),
    )

    # get_time_series_metadata with interval
    @test length(
        IS.get_time_series_metadata(component; time_series_type = IS.Deterministic),
    ) == 2
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            interval = interval1,
        ),
    ) == 1
    @test length(
        IS.get_time_series_metadata(
            component;
            time_series_type = IS.Deterministic,
            name = f_name,
            interval = interval2,
        ),
    ) == 1
end

@testset "Test DeterministicSingleTimeSeries with multiple resolutions" begin
    params = setup_for_multi_resolution_tests()
    for _ in 1:2
        IS.transform_single_time_series!(
            params.system,
            IS.DeterministicSingleTimeSeries,
            Dates.Hour(2),
            params.resolution1;
            resolution = params.resolution1,
        )

        counts = IS.get_time_series_counts(params.system)
        @test counts.components_with_time_series == 1
        @test counts.supplemental_attributes_with_time_series == 0
        @test counts.static_time_series_count == 2
        @test counts.forecast_count == 3

        @test IS.has_time_series(
            params.component,
            IS.DeterministicSingleTimeSeries,
            params.sts_name,
            resolution = params.resolution1,
        )
        @test IS.get_time_series(
            IS.DeterministicSingleTimeSeries,
            params.component,
            params.sts_name;
            resolution = params.resolution1,
        ) isa IS.DeterministicSingleTimeSeries

        # The original should still be readable.
        @test IS.has_time_series(
            params.component,
            IS.SingleTimeSeries,
            params.sts_name,
            resolution = params.resolution1,
        )
        @test IS.get_data(
            IS.get_time_series(
                IS.SingleTimeSeries,
                params.component,
                params.sts_name;
                resolution = params.resolution1,
            ),
        ) ==
              IS.get_data(params.sts1)
        @test IS.get_data(
            IS.get_time_series(
                IS.Deterministic,
                params.component,
                params.f_name;
                resolution = params.resolution1,
            ),
        ) == IS.get_data(params.forecast1)
    end
end

@testset "Test Deterministic retrieval with multiple intervals" begin
    sys = IS.SystemData()
    component = IS.TestComponent("Component1", 1)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Minute(5)
    horizon_count = 12
    f_name = "max_active_power"

    # Two forecasts with same resolution/name/horizon but different intervals.
    # Both must have the same window count and initial_timestamp for system compatibility.
    interval1 = Dates.Hour(1)
    interval2 = Dates.Day(1)

    times1 = [initial_time, initial_time + interval1]
    data1 = SortedDict(t => rand(horizon_count) for t in times1)
    f1 = IS.Deterministic(;
        data = data1,
        name = f_name,
        resolution = resolution,
        interval = interval1,
    )

    times2 = [initial_time, initial_time + interval2]
    data2 = SortedDict(t => rand(horizon_count) for t in times2)
    f2 = IS.Deterministic(;
        data = data2,
        name = f_name,
        resolution = resolution,
        interval = interval2,
    )

    IS.add_time_series!(sys, component, f1)
    IS.add_time_series!(sys, component, f2)

    # Retrieve by interval returns correct data
    ts1 = IS.get_time_series(
        IS.Deterministic,
        component,
        f_name;
        interval = interval1,
    )
    @test IS.get_interval(ts1) == interval1
    @test IS.get_data(ts1) == IS.get_data(f1)

    ts2 = IS.get_time_series(
        IS.Deterministic,
        component,
        f_name;
        interval = interval2,
    )
    @test IS.get_interval(ts2) == interval2
    @test IS.get_data(ts2) == IS.get_data(f2)

    # Without interval, ambiguous query throws
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        f_name,
    )

    # get_time_series_array with interval
    ta1 = IS.get_time_series_array(
        IS.Deterministic,
        component,
        f_name;
        interval = interval1,
    )
    @test length(ta1) == horizon_count
    @test_throws ArgumentError IS.get_time_series_array(
        IS.Deterministic,
        component,
        f_name,
    )

    # get_time_series_values with interval
    vals = IS.get_time_series_values(
        IS.Deterministic,
        component,
        f_name;
        interval = interval1,
    )
    @test vals == TimeSeries.values(ta1)
    @test_throws ArgumentError IS.get_time_series_values(
        IS.Deterministic,
        component,
        f_name,
    )

    # get_time_series_timestamps with interval
    ts_stamps = IS.get_time_series_timestamps(
        IS.Deterministic,
        component,
        f_name;
        interval = interval2,
    )
    @test length(ts_stamps) == horizon_count
    @test_throws ArgumentError IS.get_time_series_timestamps(
        IS.Deterministic,
        component,
        f_name,
    )
end

@testset "Test DeterministicSingleTimeSeries with multiple intervals" begin
    sys = IS.SystemData()
    component = IS.TestComponent("Component1", 1)
    IS.add_component!(sys, component)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Minute(5)
    sts_length = 288  # 24 hours at 5-min resolution
    data = TimeSeries.TimeArray(
        range(initial_time; length = sts_length, step = resolution),
        rand(sts_length),
    )
    sts_name = "test_sts"
    sts = IS.SingleTimeSeries(; data = data, name = sts_name)
    IS.add_time_series!(sys, component, sts)

    horizon = Dates.Hour(1)
    interval1 = Dates.Minute(30)
    interval2 = Dates.Hour(1)

    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval1;
        delete_existing = false,
    )
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        horizon,
        interval2;
        delete_existing = false,
    )

    # Both transforms exist
    @test IS.has_time_series(
        component,
        IS.DeterministicSingleTimeSeries,
        sts_name;
        interval = interval1,
    )
    @test IS.has_time_series(
        component,
        IS.DeterministicSingleTimeSeries,
        sts_name;
        interval = interval2,
    )

    # Retrieve by interval
    ts1 = IS.get_time_series(
        IS.DeterministicSingleTimeSeries,
        component,
        sts_name;
        interval = interval1,
    )
    @test ts1 isa IS.DeterministicSingleTimeSeries
    @test IS.get_interval(ts1) == interval1

    ts2 = IS.get_time_series(
        IS.DeterministicSingleTimeSeries,
        component,
        sts_name;
        interval = interval2,
    )
    @test ts2 isa IS.DeterministicSingleTimeSeries
    @test IS.get_interval(ts2) == interval2

    # Without interval, ambiguous query throws
    @test_throws ArgumentError IS.get_time_series(
        IS.DeterministicSingleTimeSeries,
        component,
        sts_name,
    )

    # get_time_series_array works with interval, fails without
    ta1 = IS.get_time_series_array(
        IS.DeterministicSingleTimeSeries,
        component,
        sts_name;
        interval = interval1,
    )
    @test length(ta1) > 0
    @test_throws ArgumentError IS.get_time_series_array(
        IS.DeterministicSingleTimeSeries,
        component,
        sts_name,
    )

    # Original SingleTimeSeries still accessible
    @test IS.has_time_series(component, IS.SingleTimeSeries, sts_name)
    @test IS.get_data(
        IS.get_time_series(IS.SingleTimeSeries, component, sts_name),
    ) == IS.get_data(sts)
end

@testset "Test ForecastCache with multiple intervals" begin
    params = setup_for_multi_interval_tests()
    component = params.component
    f_name = params.f_name
    initial_time = params.initial_time
    interval1 = params.interval1
    interval2 = params.interval2
    f1 = params.forecast1
    f2 = params.forecast2

    horizon_count = length(first(values(IS.get_data(f1))))

    # Cache with interval1 returns interval1 data
    cache1 = IS.ForecastCache(
        IS.Deterministic,
        component,
        f_name;
        start_time = initial_time,
        horizon_count = horizon_count,
        interval = interval1,
    )
    ta1 = IS.get_time_series_array!(cache1, initial_time)
    expected_vals1 = IS.get_data(f1)[initial_time]
    @test TimeSeries.values(ta1) == expected_vals1

    # Cache with interval2 returns interval2 data
    cache2 = IS.ForecastCache(
        IS.Deterministic,
        component,
        f_name;
        start_time = initial_time,
        horizon_count = horizon_count,
        interval = interval2,
    )
    ta2 = IS.get_time_series_array!(cache2, initial_time)
    expected_vals2 = IS.get_data(f2)[initial_time]
    @test TimeSeries.values(ta2) == expected_vals2

    # Values from different intervals are different
    @test expected_vals1 != expected_vals2

    # Cache without interval throws on ambiguous data
    @test_throws ArgumentError IS.ForecastCache(
        IS.Deterministic,
        component,
        f_name;
        start_time = initial_time,
        horizon_count = horizon_count,
    )

    # make_time_series_cache with interval works
    cache3 = IS.make_time_series_cache(
        IS.Deterministic,
        component,
        f_name,
        initial_time,
        horizon_count;
        interval = interval1,
    )
    ta3 = IS.get_time_series_array!(cache3, initial_time)
    @test TimeSeries.values(ta3) == expected_vals1
end

@testset "Test removals of time series with multiple resolutions" begin
    params = setup_for_multi_resolution_tests()
    for (ts_type, ts_name) in
        zip((IS.SingleTimeSeries, IS.Deterministic), (params.sts_name, params.f_name))
        @test IS.has_time_series(
            params.component,
            ts_type,
            ts_name,
            resolution = params.resolution1,
        )
        @test IS.has_time_series(
            params.component,
            ts_type,
            ts_name,
            resolution = params.resolution2,
        )
        IS.remove_time_series!(
            params.system,
            ts_type,
            params.component,
            ts_name;
            resolution = params.resolution1,
        )
        @test !IS.has_time_series(
            params.component,
            ts_type,
            ts_name;
            resolution = params.resolution1,
        )
        @test IS.has_time_series(
            params.component,
            ts_type,
            ts_name,
            resolution = params.resolution2,
        )
        IS.remove_time_series!(
            params.system,
            ts_type;
            resolution = params.resolution2,
        )
        @test !IS.has_time_series(params.component, ts_type)
    end
    @test !IS.has_time_series(params.component)
end

@testset "Remove time series on supplemental attribute" begin
    for by_metadata in (false, true)
        sys = IS.SystemData()
        name = "Component1"
        component = IS.TestComponent(name, 5)
        IS.add_component!(sys, component)
        attr = IS.TestSupplemental(; value = 3.0)
        IS.add_supplemental_attribute!(sys, component, attr)

        initial_time = Dates.DateTime("2020-09-01")
        resolution = Dates.Hour(1)
        data = TimeSeries.TimeArray(
            range(initial_time; length = 12, step = resolution),
            ones(12),
        )
        ts_name = "test"
        data = IS.SingleTimeSeries(; data = data, name = ts_name)
        IS.add_time_series!(sys, attr, data)
        all_metadata = IS.get_time_series_metadata(
            attr;
            time_series_type = IS.SingleTimeSeries,
        )
        @test isempty(
            IS.get_time_series_metadata(
                component;
                time_series_type = IS.SingleTimeSeries,
            ),
        )
        @test length(all_metadata) == 1
        if by_metadata
            IS.remove_time_series!(sys, attr, all_metadata[1])
        else
            IS.remove_time_series!(sys, IS.SingleTimeSeries, attr, ts_name)
        end
        @test isempty(
            IS.get_time_series_metadata(
                attr;
                time_series_type = IS.SingleTimeSeries,
            ),
        )
    end
end

@testset "Test to_dataframe" begin
    sys = create_system_data(; with_time_series = true, time_series_in_memory = true)
    @test IS.to_dataframe(sys.time_series_manager.metadata_store) isa DataFrame
    @test IS.to_dataframe(
        sys.time_series_manager.metadata_store;
        table = IS.KEY_VALUE_TABLE_NAME,
    ) isa DataFrame
end

@testset "Test removal of SingleTimeSeries attached to a DeterministicSingleTimeSeries" begin
    sys = IS.SystemData()
    name = "Component1"
    component = IS.TestComponent(name, 5)
    component2 = IS.TestComponent("Component2", 3)
    IS.add_component!(sys, component)
    IS.add_component!(sys, component2)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    data = TimeSeries.TimeArray(
        range(initial_time; length = 12, step = resolution),
        ones(12),
    )
    ts_name = "test"
    data = IS.SingleTimeSeries(; data = data, name = ts_name)
    IS.add_time_series!(sys, component, data)
    IS.add_time_series!(sys, component2, data)

    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(2),
        resolution;
        resolution = resolution,
    )
    @test IS.has_time_series(component, IS.SingleTimeSeries, ts_name)
    @test IS.has_time_series(component, IS.DeterministicSingleTimeSeries, ts_name)
    @test IS.has_time_series(component2, IS.SingleTimeSeries, ts_name)
    @test IS.has_time_series(component2, IS.DeterministicSingleTimeSeries, ts_name)

    # removing from one component is fine, as long as another still has the SingleTimeSeries
    mgr = IS.get_time_series_manager(component2)
    @test !isnothing(mgr)
    IS.remove_time_series!(mgr, IS.SingleTimeSeries, component2, ts_name)
    # so that we can test removing just the SingleTimeSeries from the other component
    IS.remove_time_series!(mgr, IS.DeterministicSingleTimeSeries, component2, ts_name)

    metadata = IS.get_time_series_metadata(
        component;
        time_series_type = IS.SingleTimeSeries,
        name = ts_name,
        resolution = resolution,
    )
    @assert length(metadata) == 1
    @test_throws(ArgumentError, IS.remove_time_series!(sys, component, metadata[1]))
    @test_throws(
        ArgumentError,
        IS.remove_time_series!(sys, IS.SingleTimeSeries, component, ts_name)
    )
    @test IS.has_time_series(component, IS.SingleTimeSeries, ts_name)
    @test IS.has_time_series(component, IS.DeterministicSingleTimeSeries, ts_name)

    IS.remove_time_series!(sys, IS.DeterministicSingleTimeSeries, component, ts_name)
    IS.remove_time_series!(sys, IS.SingleTimeSeries, component, ts_name)
    @test !IS.has_time_series(component, IS.SingleTimeSeries, ts_name)
    @test !IS.has_time_series(component, IS.DeterministicSingleTimeSeries, ts_name)
end

@testset "Test removal order: DeterministicSingleTimeSeries before SingleTimeSeries" begin
    sys = IS.SystemData()
    component1 = IS.TestComponent("Component1", 5)
    component2 = IS.TestComponent("Component2", 3)
    IS.add_component!(sys, component1)
    IS.add_component!(sys, component2)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    data = TimeSeries.TimeArray(
        range(initial_time; length = 12, step = resolution),
        ones(12),
    )
    ts_name = "test"
    data = IS.SingleTimeSeries(; data = data, name = ts_name)
    # prevent the indices from affecting the order of removal
    IS._drop_all_indexes!(sys.time_series_manager.metadata_store.db)
    IS.add_time_series!(sys, component1, data)
    IS.add_time_series!(sys, component2, data)

    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(2),
        resolution;
        resolution = resolution,
    )
    @test IS.has_time_series(component1, IS.SingleTimeSeries, ts_name)
    @test IS.has_time_series(component1, IS.DeterministicSingleTimeSeries, ts_name)
    @test IS.has_time_series(component2, IS.SingleTimeSeries, ts_name)
    @test IS.has_time_series(component2, IS.DeterministicSingleTimeSeries, ts_name)
    mgr = IS.get_time_series_manager(component1)
    @test !isnothing(mgr)
    # removing all from one component is fine, as long as another still has the SingleTimeSeries
    IS.clear_time_series!(mgr, component1)
    # can't remove just the SingleTimeSeries from the other component
    @test_throws(
        ArgumentError,
        IS.remove_time_series!(sys, IS.SingleTimeSeries, component2, ts_name)
    )
    # but removing both is ok.
    IS.clear_time_series!(mgr, component2)
end

@testset "Test early validation of time series data types in Deterministic constructor" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    # Test 1: Vector{Any} should be caught early
    data_any = Dict(
        initial_time => Any[1.0, 2, 3.0],
        initial_time + resolution => Any[4, 5.0, 6],
    )
    @test_throws ArgumentError IS.Deterministic(
        name = "test",
        data = data_any,
        resolution = resolution,
    )
    try
        IS.Deterministic(; name = "test", data = data_any, resolution = resolution)
    catch e
        @test e isa ArgumentError
        @test occursin("non-concrete element type", e.msg)
        @test occursin("Supported types:", e.msg)
    end

    # Test 2: Unsupported concrete type should be caught early
    struct TestUnsupportedTypeInConstructor
        value::Int
    end
    data_custom = Dict(
        initial_time =>
            [TestUnsupportedTypeInConstructor(1), TestUnsupportedTypeInConstructor(2)],
        initial_time + resolution =>
            [TestUnsupportedTypeInConstructor(3), TestUnsupportedTypeInConstructor(4)],
    )
    @test_throws ArgumentError IS.Deterministic(
        name = "test",
        data = data_custom,
        resolution = resolution,
    )
    try
        IS.Deterministic(; name = "test", data = data_custom, resolution = resolution)
    catch e
        @test e isa ArgumentError
        @test occursin("unsupported element type", e.msg)
        @test occursin("Supported types:", e.msg)
    end

    # Test 3: Supported types should work fine
    data_float = Dict(
        initial_time => [1.0, 2.0, 3.0],
        initial_time + resolution => [4.0, 5.0, 6.0],
    )
    det = IS.Deterministic(; name = "test", data = data_float, resolution = resolution)
    @test det isa IS.Deterministic
    @test IS.get_name(det) == "test"
end

@testset "Test validation rejects arbitrary SortedDict types" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    # Test: Arbitrary SortedDict (not SortedDict{DateTime, Vector{T}}) should be rejected
    # For example, SortedDict{String, Vector{Float64}} is not supported
    data_wrong_key = SortedDict{String, Vector{Float64}}(
        "key1" => [1.0, 2.0, 3.0],
        "key2" => [4.0, 5.0, 6.0],
    )
    @test_throws ArgumentError IS.Deterministic(
        name = "test",
        data = data_wrong_key,
        resolution = resolution,
    )
end

@testset "Test optimize_database! for TimeSeriesMetadataStore" begin
    sys = IS.SystemData()
    component1 = IS.TestComponent("component1", 5)
    component2 = IS.TestComponent("component2", 7)
    IS.add_component!(sys, component1)
    IS.add_component!(sys, component2)

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    # Add several time series to create data for optimization
    for i in 1:10
        data = TimeSeries.TimeArray(
            range(initial_time; length = 24, step = resolution),
            rand(24),
        )
        ts = IS.SingleTimeSeries(; data = data, name = "test_$i")
        IS.add_time_series!(sys, component1, ts)
        IS.add_time_series!(sys, component2, ts)
    end

    # Verify data was added
    @test IS.get_num_time_series(sys.time_series_manager.metadata_store) == 10

    # Call optimize_database! - should not throw and data should remain intact
    IS.optimize_database!(sys.time_series_manager.metadata_store)

    # Verify data is still accessible after optimization
    @test IS.get_num_time_series(sys.time_series_manager.metadata_store) == 10
    @test IS.has_time_series(component1)
    @test IS.has_time_series(component2)
end
