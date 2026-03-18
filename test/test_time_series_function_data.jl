@testset "TimeSeriesFunctionData" begin
    forecast_key = IS.ForecastKey(;
        time_series_type = IS.Deterministic,
        name = "test_forecast",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        horizon = Dates.Hour(24),
        interval = Dates.Hour(24),
        count = 1,
        features = Dict{String, Any}(),
    )

    ts_types = [
        IS.TimeSeriesLinearFunctionData,
        IS.TimeSeriesQuadraticFunctionData,
        IS.TimeSeriesPiecewiseLinearData,
        IS.TimeSeriesPiecewiseStepData,
    ]

    underlying_types = [
        IS.LinearFunctionData,
        IS.QuadraticFunctionData,
        IS.PiecewiseLinearData,
        IS.PiecewiseStepData,
    ]

    @testset "is_time_series_backed" begin
        for T in ts_types
            @test IS.is_time_series_backed(T(forecast_key)) == true
        end
        @test IS.is_time_series_backed(IS.LinearFunctionData(1.0, 2.0)) == false
        @test IS.is_time_series_backed(IS.QuadraticFunctionData(1.0, 2.0, 3.0)) == false
        @test IS.is_time_series_backed(
            IS.PiecewiseLinearData([(x = 1.0, y = 1.0), (x = 2.0, y = 2.0)]),
        ) == false
        @test IS.is_time_series_backed(
            IS.PiecewiseStepData([1.0, 2.0, 3.0], [1.0, 2.0]),
        ) == false
    end

    @testset "get_underlying_function_data_type" begin
        for (T, U) in zip(ts_types, underlying_types)
            @test IS.get_underlying_function_data_type(T) == U
            @test IS.get_underlying_function_data_type(T(forecast_key)) == U
        end
    end

    @testset "Serialization round-trip" begin
        for T in ts_types
            fd = T(forecast_key)
            serialized = IS.serialize(fd)
            deserialized = IS.deserialize(T, serialized)
            @test deserialized isa T
            deserialized_key = IS.get_time_series_key(deserialized)
            @test IS.get_name(deserialized_key) == IS.get_name(forecast_key)
            @test IS.get_resolution(deserialized_key) == IS.get_resolution(forecast_key)
        end
    end

    @testset "Show" begin
        for (T, U) in zip(ts_types, underlying_types)
            fd = T(forecast_key)
            str = sprint(show, MIME("text/plain"), fd)
            @test contains(str, "test_forecast")
            @test contains(str, string(U))
        end
    end

    @testset "Integration with time series storage" begin
        initial_time = Dates.DateTime("2020-01-01")
        resolution = Dates.Hour(1)
        horizon_count = 24
        name = "cost_data"

        # FunctionData vectors for each type, one element per timestep
        fd_vectors = Dict(
            IS.TimeSeriesLinearFunctionData => [
                IS.LinearFunctionData(Float64(i), Float64(i) + 1.0)
                for i in 1:horizon_count
            ],
            IS.TimeSeriesQuadraticFunctionData => [
                IS.QuadraticFunctionData(Float64(i), Float64(i) + 1.0, Float64(i) + 2.0)
                for i in 1:horizon_count
            ],
            IS.TimeSeriesPiecewiseLinearData => [
                IS.PiecewiseLinearData([
                    (x = Float64(i), y = Float64(i) + 1.0),
                    (x = Float64(i) + 2.0, y = Float64(i) + 5.0),
                    (x = Float64(i) + 4.0, y = Float64(i) + 10.0),
                ])
                for i in 1:horizon_count
            ],
            IS.TimeSeriesPiecewiseStepData => [
                IS.PiecewiseStepData(
                    [Float64(i), Float64(i) + 2.0, Float64(i) + 4.0],
                    [Float64(i) + 1.0, Float64(i) + 3.0],
                )
                for i in 1:horizon_count
            ],
        )

        for (TSType, fd_data) in fd_vectors
            @testset "$TSType" begin
                sys = IS.SystemData(; time_series_in_memory = true)
                component = IS.TestComponent("gen1", 5)
                IS.add_component!(sys, component)

                ts_data = SortedDict(initial_time => fd_data)
                forecast = IS.Deterministic(; data = ts_data, name = name,
                    resolution = resolution)
                key = IS.add_time_series!(sys, component, forecast)

                # Wrap the key in the corresponding TimeSeriesFunctionData
                ts_fd = TSType(key)
                @test IS.is_time_series_backed(ts_fd)
                @test IS.get_name(IS.get_time_series_key(ts_fd)) == name

                # Retrieve the time series via the key extracted from the wrapper,
                # exercising the key-based retrieval path rather than by-name.
                retrieved_key = IS.get_time_series_key(ts_fd)
                retrieved_ts = IS.get_time_series(
                    component, retrieved_key;
                    start_time = initial_time, len = horizon_count,
                    count = 1,
                )
                retrieved_data = first(values(IS.get_data(retrieved_ts)))
                @test length(retrieved_data) == horizon_count
                @test retrieved_data == fd_data

                # Verify the underlying type matches the stored data
                UnderlyingType = IS.get_underlying_function_data_type(TSType)
                @test eltype(retrieved_data) == UnderlyingType
            end
        end
    end

    @testset "HDF5 round-trip with TimeSeriesFunctionData key" begin
        initial_time = Dates.DateTime("2020-01-01")
        other_time = Dates.DateTime("2020-01-02")
        resolution = Dates.Hour(1)
        horizon_count = 3
        name = "cost_curve"

        # Test each FunctionData type through HDF5 serialization
        fd_test_cases = Dict(
            IS.TimeSeriesLinearFunctionData => [
                IS.LinearFunctionData(1.0, 2.0),
                IS.LinearFunctionData(3.0, 4.0),
                IS.LinearFunctionData(5.0, 6.0),
            ],
            IS.TimeSeriesQuadraticFunctionData => [
                IS.QuadraticFunctionData(1.0, 2.0, 3.0),
                IS.QuadraticFunctionData(4.0, 5.0, 6.0),
                IS.QuadraticFunctionData(7.0, 8.0, 9.0),
            ],
            IS.TimeSeriesPiecewiseLinearData => [
                IS.PiecewiseLinearData([(x = 1.0, y = 2.0), (x = 3.0, y = 6.0)]),
                IS.PiecewiseLinearData([(x = 2.0, y = 3.0), (x = 4.0, y = 7.0)]),
                IS.PiecewiseLinearData([(x = 3.0, y = 4.0), (x = 5.0, y = 8.0)]),
            ],
            IS.TimeSeriesPiecewiseStepData => [
                IS.PiecewiseStepData([1.0, 3.0, 5.0], [2.0, 4.0]),
                IS.PiecewiseStepData([2.0, 4.0, 6.0], [3.0, 5.0]),
                IS.PiecewiseStepData([3.0, 5.0, 7.0], [4.0, 6.0]),
            ],
        )

        fd_test_cases_2 = Dict(
            IS.TimeSeriesLinearFunctionData => [
                IS.LinearFunctionData(10.0, 20.0),
                IS.LinearFunctionData(30.0, 40.0),
                IS.LinearFunctionData(50.0, 60.0),
            ],
            IS.TimeSeriesQuadraticFunctionData => [
                IS.QuadraticFunctionData(10.0, 20.0, 30.0),
                IS.QuadraticFunctionData(40.0, 50.0, 60.0),
                IS.QuadraticFunctionData(70.0, 80.0, 90.0),
            ],
            IS.TimeSeriesPiecewiseLinearData => [
                IS.PiecewiseLinearData([(x = 10.0, y = 20.0), (x = 30.0, y = 60.0)]),
                IS.PiecewiseLinearData([(x = 20.0, y = 30.0), (x = 40.0, y = 70.0)]),
                IS.PiecewiseLinearData([(x = 30.0, y = 40.0), (x = 50.0, y = 80.0)]),
            ],
            IS.TimeSeriesPiecewiseStepData => [
                IS.PiecewiseStepData([10.0, 30.0, 50.0], [20.0, 40.0]),
                IS.PiecewiseStepData([20.0, 40.0, 60.0], [30.0, 50.0]),
                IS.PiecewiseStepData([30.0, 50.0, 70.0], [40.0, 60.0]),
            ],
        )

        for (TSType, fd_data) in fd_test_cases
            @testset "HDF5 $TSType" begin
                sys = IS.SystemData(; time_series_in_memory = false)
                component = IS.TestComponent("gen1", 5)
                IS.add_component!(sys, component)

                ts_data = SortedDict(
                    initial_time => fd_data,
                    other_time => fd_test_cases_2[TSType],
                )
                forecast = IS.Deterministic(; data = ts_data, name = name,
                    resolution = resolution)
                key = IS.add_time_series!(sys, component, forecast)

                # Create TimeSeriesFunctionData from the key, then retrieve via that
                # key to exercise the wrapper's key-based retrieval path.
                ts_fd = TSType(key)
                retrieved_key = IS.get_time_series_key(ts_fd)

                # Retrieve the first window and verify data survived HDF5 round-trip
                retrieved_ts = IS.get_time_series(
                    component, retrieved_key;
                    start_time = initial_time, len = horizon_count,
                    count = 1,
                )
                retrieved_values = first(values(IS.get_data(retrieved_ts)))
                @test retrieved_values == fd_data

                # Retrieve the second window via the same key
                retrieved_ts_2 = IS.get_time_series(
                    component, retrieved_key;
                    start_time = other_time, len = horizon_count,
                    count = 1,
                )
                retrieved_values_2 = first(values(IS.get_data(retrieved_ts_2)))
                @test retrieved_values_2 == fd_test_cases_2[TSType]
            end
        end
    end
end

@testset "TimeSeriesValueCurve" begin
    forecast_key = IS.ForecastKey(;
        time_series_type = IS.Deterministic,
        name = "test_forecast",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        horizon = Dates.Hour(24),
        interval = Dates.Hour(24),
        count = 1,
        features = Dict{String, Any}(),
    )

    ii_key = IS.ForecastKey(;
        time_series_type = IS.Deterministic,
        name = "initial_input",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        horizon = Dates.Hour(24),
        interval = Dates.Hour(24),
        count = 1,
        features = Dict{String, Any}(),
    )

    iaz_key = IS.ForecastKey(;
        time_series_type = IS.Deterministic,
        name = "input_at_zero",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        horizon = Dates.Hour(24),
        interval = Dates.Hour(24),
        count = 1,
        features = Dict{String, Any}(),
    )

    @testset "Construction and field access" begin
        # InputOutputCurve with non-default input_at_zero
        io_with_iaz = IS.TimeSeriesInputOutputCurve(
            IS.TimeSeriesLinearFunctionData(forecast_key), 42.0,
        )
        @test IS.get_input_at_zero(io_with_iaz) == 42.0
        @test IS.get_time_series_key(io_with_iaz) === forecast_key

        # IncrementalCurve with initial_input and input_at_zero keys
        inc = IS.TimeSeriesIncrementalCurve(
            IS.TimeSeriesPiecewiseStepData(forecast_key), ii_key, iaz_key,
        )
        @test IS.get_initial_input(inc) === ii_key
        @test IS.get_input_at_zero(inc) === iaz_key

        # AverageRateCurve with nothing initial_input
        ar = IS.TimeSeriesAverageRateCurve(
            IS.TimeSeriesLinearFunctionData(forecast_key), nothing,
        )
        @test IS.get_initial_input(ar) === nothing
    end

    @testset "Cost aliases" begin
        aliases = [
            IS.TimeSeriesLinearCurve(forecast_key),
            IS.TimeSeriesQuadraticCurve(forecast_key),
            IS.TimeSeriesPiecewisePointCurve(forecast_key),
        ]
        for obj in aliases
            @test IS.is_cost_alias(obj) == true
        end

        # Incremental/average aliases propagate initial_input and input_at_zero
        pic = IS.TimeSeriesPiecewiseIncrementalCurve(forecast_key, ii_key, iaz_key)
        @test IS.get_initial_input(pic) === ii_key
        @test IS.get_input_at_zero(pic) === iaz_key
        @test IS.is_cost_alias(pic) == true

        pac = IS.TimeSeriesPiecewiseAverageCurve(forecast_key, ii_key, iaz_key)
        @test IS.get_initial_input(pac) === ii_key
        @test IS.get_input_at_zero(pac) === iaz_key
    end

    @testset "Invalid type combinations" begin
        @test_throws MethodError IS.TimeSeriesInputOutputCurve(
            IS.TimeSeriesPiecewiseStepData(forecast_key),
        )
        @test_throws MethodError IS.TimeSeriesIncrementalCurve(
            IS.TimeSeriesQuadraticFunctionData(forecast_key), nothing,
        )
        @test_throws MethodError IS.TimeSeriesAverageRateCurve(
            IS.TimeSeriesPiecewiseLinearData(forecast_key), nothing,
        )
    end

    @testset "is_time_series_backed and get_time_series_key propagation" begin
        ts_io = IS.TimeSeriesInputOutputCurve(
            IS.TimeSeriesLinearFunctionData(forecast_key),
        )
        @test IS.is_time_series_backed(ts_io) == true

        # Static ValueCurves are not
        @test IS.is_time_series_backed(
            IS.InputOutputCurve(IS.LinearFunctionData(1.0, 2.0)),
        ) == false

        # Propagation through CostCurve and FuelCurve
        cc = IS.CostCurve(ts_io)
        @test IS.is_time_series_backed(cc) == true
        @test IS.get_time_series_key(cc) === forecast_key

        fc = IS.FuelCurve(ts_io, 1.0)
        @test IS.is_time_series_backed(fc) == true
        @test IS.get_time_series_key(fc) === forecast_key
    end

    @testset "Serialization round-trip" begin
        ts_curves = [
            (
                IS.TimeSeriesInputOutputCurve(
                    IS.TimeSeriesLinearFunctionData(forecast_key),
                ),
                IS.TimeSeriesInputOutputCurve,
            ),
            (
                IS.TimeSeriesInputOutputCurve(
                    IS.TimeSeriesLinearFunctionData(forecast_key), 42.0,
                ),
                IS.TimeSeriesInputOutputCurve,
            ),
            (
                IS.TimeSeriesIncrementalCurve(
                    IS.TimeSeriesPiecewiseStepData(forecast_key), ii_key,
                ),
                IS.TimeSeriesIncrementalCurve,
            ),
            (
                IS.TimeSeriesAverageRateCurve(
                    IS.TimeSeriesPiecewiseStepData(forecast_key), ii_key,
                ),
                IS.TimeSeriesAverageRateCurve,
            ),
        ]

        for (curve, curve_type) in ts_curves
            deserialized = IS.deserialize(curve_type, IS.serialize(curve))
            @test typeof(deserialized) == typeof(curve)
            @test IS.get_name(IS.get_time_series_key(deserialized)) ==
                  IS.get_name(IS.get_time_series_key(curve))
        end

        # CostCurve wrapping TS ValueCurve round-trips
        cc = IS.CostCurve(IS.TimeSeriesLinearCurve(forecast_key))
        cc_deser = IS.deserialize(IS.CostCurve, IS.serialize(cc))
        @test IS.is_time_series_backed(cc_deser) == true
        @test IS.get_name(IS.get_time_series_key(cc_deser)) == "test_forecast"
    end

    @testset "CostCurve and FuelCurve wrapping" begin
        ts_io = IS.TimeSeriesInputOutputCurve(
            IS.TimeSeriesLinearFunctionData(forecast_key),
        )
        # CostCurve preserves value_curve and accepts power_units
        cc = IS.CostCurve(ts_io, IS.UnitSystem.SYSTEM_BASE)
        @test IS.get_value_curve(cc) === ts_io
        @test IS.get_power_units(cc) == IS.UnitSystem.SYSTEM_BASE

        # FuelCurve preserves fuel_cost
        fc = IS.FuelCurve(ts_io, 5.0)
        @test IS.get_fuel_cost(fc) == 5.0
    end
end

@testset "build_static_curve" begin
    initial_time = Dates.DateTime("2020-01-01")
    resolution = Dates.Hour(1)
    horizon_count = 3

    fd_data = [
        IS.PiecewiseStepData([1.0, 3.0, 5.0], [2.0, 4.0]),
        IS.PiecewiseStepData([2.0, 4.0, 6.0], [3.0, 5.0]),
        IS.PiecewiseStepData([3.0, 5.0, 7.0], [4.0, 6.0]),
    ]
    ii_data = [10.0, 20.0, 30.0]
    iaz_data = [100.0, 200.0, 300.0]

    sys = IS.SystemData(; time_series_in_memory = true)
    component = IS.TestComponent("gen1", 5)
    IS.add_component!(sys, component)

    fd_forecast = IS.Deterministic(;
        data = SortedDict(initial_time => fd_data),
        name = "cost_fd",
        resolution = resolution,
    )
    fd_key = IS.add_time_series!(sys, component, fd_forecast)

    ii_forecast = IS.Deterministic(;
        data = SortedDict(initial_time => ii_data),
        name = "initial_input",
        resolution = resolution,
    )
    ii_key = IS.add_time_series!(sys, component, ii_forecast)

    iaz_forecast = IS.Deterministic(;
        data = SortedDict(initial_time => iaz_data),
        name = "input_at_zero",
        resolution = resolution,
    )
    iaz_key = IS.add_time_series!(sys, component, iaz_forecast)

    @testset "TimeSeriesInputOutputCurve" begin
        # InputOutputCurve uses PiecewiseLinearData, not PiecewiseStepData
        linear_fd = [
            IS.LinearFunctionData(1.0, 2.0),
            IS.LinearFunctionData(3.0, 4.0),
            IS.LinearFunctionData(5.0, 6.0),
        ]
        lin_forecast = IS.Deterministic(;
            data = SortedDict(initial_time => linear_fd),
            name = "cost_io",
            resolution = resolution,
        )
        lin_key = IS.add_time_series!(sys, component, lin_forecast)

        curve = IS.TimeSeriesInputOutputCurve(
            IS.TimeSeriesLinearFunctionData(lin_key), 42.0,
        )
        static = IS.build_static_curve(curve, component, initial_time)
        @test static isa IS.InputOutputCurve{IS.LinearFunctionData}
        @test IS.get_function_data(static) == linear_fd[1]
        @test IS.get_input_at_zero(static) == 42.0
    end

    @testset "TimeSeriesIncrementalCurve" begin
        curve = IS.TimeSeriesIncrementalCurve(
            IS.TimeSeriesPiecewiseStepData(fd_key), ii_key, iaz_key,
        )
        static = IS.build_static_curve(curve, component, initial_time)
        @test static isa IS.IncrementalCurve{IS.PiecewiseStepData}
        @test IS.get_function_data(static) == fd_data[1]
        @test IS.get_initial_input(static) == 10.0
        @test IS.get_input_at_zero(static) == 100.0
    end

    @testset "TimeSeriesAverageRateCurve" begin
        curve = IS.TimeSeriesAverageRateCurve(
            IS.TimeSeriesPiecewiseStepData(fd_key), ii_key, nothing,
        )
        static = IS.build_static_curve(curve, component, initial_time)
        @test static isa IS.AverageRateCurve{IS.PiecewiseStepData}
        @test IS.get_function_data(static) == fd_data[1]
        @test IS.get_initial_input(static) == 10.0
        @test IS.get_input_at_zero(static) === nothing
    end
end
