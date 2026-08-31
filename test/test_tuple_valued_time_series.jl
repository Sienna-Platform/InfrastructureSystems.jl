@testset "Tuple-valued time series" begin
    StartUpStages = NamedTuple{(:hot, :warm, :cold), NTuple{3, Float64}}
    MinMax = NamedTuple{(:min, :max), NTuple{2, Float64}}

    @testset "Round-trip (in-memory)" begin
        initial_time = Dates.DateTime("2024-01-01")
        resolution = Dates.Hour(1)
        horizon_count = 24
        timestamps = range(initial_time; step = resolution, length = horizon_count)

        # N=3
        vals3 = [(Float64(i), Float64(i) + 10.0, Float64(i) + 20.0)
         for i in 1:horizon_count]
        ta3 = TimeSeries.TimeArray(collect(timestamps), vals3)
        sts3 = IS.SingleTimeSeries(; name = "su_stages", data = ta3)

        sys3 = create_system_data(; time_series_in_memory = true)
        comp3 = IS.get_component(IS.TestComponent, sys3, "Component1")
        IS.add_time_series!(sys3, comp3, sts3)

        key3 = only(IS.list_time_series_metadata(comp3))
        s0 = StartUpStages(
            only(
                IS.get_time_series_values(
                    comp3, key3; start_time = initial_time, len = 1,
                ),
            ),
        )
        s5 = StartUpStages(
            only(
                IS.get_time_series_values(
                    comp3, key3; start_time = initial_time + Dates.Hour(5), len = 1,
                ),
            ),
        )
        @test typeof(s0) === StartUpStages
        @test s0 == (hot = 1.0, warm = 11.0, cold = 21.0)
        @test s5 == (hot = 6.0, warm = 16.0, cold = 26.0)

        # N=2
        vals2 = [(Float64(i), Float64(i) + 100.0) for i in 1:horizon_count]
        ta2 = TimeSeries.TimeArray(collect(timestamps), vals2)
        sts2 = IS.SingleTimeSeries(; name = "min_max", data = ta2)

        sys2 = create_system_data(; time_series_in_memory = true)
        comp2 = IS.get_component(IS.TestComponent, sys2, "Component1")
        IS.add_time_series!(sys2, comp2, sts2)

        key2 = only(IS.list_time_series_metadata(comp2))
        mm = MinMax(
            only(
                IS.get_time_series_values(
                    comp2, key2; start_time = initial_time + Dates.Hour(7), len = 1,
                ),
            ),
        )
        @test typeof(mm) === MinMax
        @test mm == (min = 8.0, max = 108.0)
    end

    @testset "Round-trip (disk-backed store)" begin
        initial_time = Dates.DateTime("2024-01-01")
        resolution = Dates.Hour(1)
        horizon_count = 48
        timestamps = range(initial_time; step = resolution, length = horizon_count)

        for (T, arity_vals) in (
            (StartUpStages,
                [
                    (Float64(i), Float64(i) + 10.0, Float64(i) + 20.0)
                    for i in 1:horizon_count
                ]),
            (MinMax,
                [(Float64(i), Float64(i) + 100.0) for i in 1:horizon_count]),
        )
            mktempdir() do tmp
                sys = IS.SystemData(;
                    time_series_directory = tmp,
                    time_series_in_memory = false,
                )
                # The store must be closed before the block exits: Windows refuses to
                # delete the still-open HDF5 file, and `mktempdir`'s cleanup logs that
                # failure at `Error` level, which fails the suite's log-error gate.
                try
                    comp = IS.TestComponent("gen", 5)
                    IS.add_component!(sys, comp)

                    ta = TimeSeries.TimeArray(collect(timestamps), arity_vals)
                    sts = IS.SingleTimeSeries(; name = "tuple_ts", data = ta)
                    IS.add_time_series!(sys, comp, sts)

                    key = only(IS.list_time_series_metadata(comp))
                    resolve(t) = T(
                        only(
                            IS.get_time_series_values(
                                comp, key; start_time = t, len = 1,
                            ),
                        ),
                    )
                    v_first = resolve(initial_time)
                    v_mid = resolve(initial_time + Dates.Hour(10))
                    v_last = resolve(initial_time + (horizon_count - 1) * resolution)

                    @test typeof(v_first) === T
                    @test v_first == T(arity_vals[1])
                    @test v_mid == T(arity_vals[11])
                    @test v_last == T(arity_vals[end])
                finally
                    IS.close!(sys.time_series_manager.data_store)
                end
            end
        end
    end
end
