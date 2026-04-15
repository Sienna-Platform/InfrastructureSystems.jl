@testset "TupleTimeSeries" begin
    StartUpStages = NamedTuple{(:hot, :warm, :cold), NTuple{3, Float64}}
    MinMax = NamedTuple{(:min, :max), NTuple{2, Float64}}

    static_key = IS.StaticTimeSeriesKey(;
        time_series_type = IS.SingleTimeSeries,
        name = "su_stages",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        length = 24,
        features = Dict{String, Any}(),
    )

    @testset "Construction" begin
        tts3 = IS.TupleTimeSeries{StartUpStages}(static_key)
        @test IS.get_time_series_key(tts3) === static_key
        @test IS.is_time_series_backed(tts3)
        @test IS.get_underlying_namedtuple_type(tts3) === StartUpStages
        @test IS.get_underlying_namedtuple_type(typeof(tts3)) === StartUpStages

        # Keyword constructor
        tts3_kw = IS.TupleTimeSeries{StartUpStages}(; time_series_key = static_key)
        @test IS.get_time_series_key(tts3_kw) === static_key

        tts2 = IS.TupleTimeSeries{MinMax}(static_key)
        @test IS.get_underlying_namedtuple_type(tts2) === MinMax
    end

    @testset "Rejected type parameters" begin
        # Plain tuples rejected by the T <: NamedTuple constraint
        @test_throws TypeError IS.TupleTimeSeries{Tuple{Float64, Float64}}(static_key)
        @test_throws TypeError IS.TupleTimeSeries{NTuple{3, Float64}}(static_key)

        # NamedTuples with non-Float64 fields rejected at the validator
        BadIntNT = NamedTuple{(:a, :b), Tuple{Int, Int}}
        @test_throws ArgumentError IS.TupleTimeSeries{BadIntNT}(static_key)

        MixedNT = NamedTuple{(:a, :b), Tuple{Float64, Int}}
        @test_throws ArgumentError IS.TupleTimeSeries{MixedNT}(static_key)

        # Non-concrete NamedTuple rejected
        @test_throws ArgumentError IS.TupleTimeSeries{NamedTuple}(static_key)

        # Non-concrete UnionAll matching an arity-specialized validator is rejected
        NonConcrete = NamedTuple{Names, NTuple{2, Float64}} where {Names}
        @test_throws ArgumentError IS.TupleTimeSeries{NonConcrete}(static_key)
    end

    @testset "Show" begin
        tts = IS.TupleTimeSeries{StartUpStages}(static_key)
        str = sprint(show, MIME("text/plain"), tts)
        @test contains(str, "TupleTimeSeries")
        @test contains(str, "su_stages")
        @test contains(str, string(StartUpStages))
    end

    @testset "build_static_tuple round-trip (in-memory)" begin
        initial_time = Dates.DateTime("2024-01-01")
        resolution = Dates.Hour(1)
        horizon_count = 24
        timestamps = range(initial_time; step = resolution, length = horizon_count)

        # N=3
        vals3 = [(Float64(i), Float64(i) + 10.0, Float64(i) + 20.0)
         for i in 1:horizon_count]
        ta3 = TimeSeries.TimeArray(collect(timestamps), vals3)
        sts3 = IS.SingleTimeSeries(; name = "su_stages", data = ta3)

        sys3 = IS.SystemData(; time_series_in_memory = true)
        comp3 = IS.TestComponent("c3", 5)
        IS.add_component!(sys3, comp3)
        IS.add_time_series!(sys3, comp3, sts3)

        key3 = only(IS.get_time_series_keys(comp3))
        tts3 = IS.TupleTimeSeries{StartUpStages}(key3)
        s0 = IS.build_static_tuple(tts3, comp3, initial_time)
        s5 = IS.build_static_tuple(tts3, comp3, initial_time + Dates.Hour(5))
        @test s0 isa StartUpStages
        @test s0 == (hot = 1.0, warm = 11.0, cold = 21.0)
        @test s5 == (hot = 6.0, warm = 16.0, cold = 26.0)

        # N=2
        vals2 = [(Float64(i), Float64(i) + 100.0) for i in 1:horizon_count]
        ta2 = TimeSeries.TimeArray(collect(timestamps), vals2)
        sts2 = IS.SingleTimeSeries(; name = "min_max", data = ta2)

        sys2 = IS.SystemData(; time_series_in_memory = true)
        comp2 = IS.TestComponent("c2", 5)
        IS.add_component!(sys2, comp2)
        IS.add_time_series!(sys2, comp2, sts2)

        key2 = only(IS.get_time_series_keys(comp2))
        tts2 = IS.TupleTimeSeries{MinMax}(key2)
        mm = IS.build_static_tuple(tts2, comp2, initial_time + Dates.Hour(7))
        @test mm isa MinMax
        @test mm == (min = 8.0, max = 108.0)
    end

    @testset "build_static_tuple type stability" begin
        initial_time = Dates.DateTime("2024-01-01")
        resolution = Dates.Hour(1)
        horizon_count = 6
        timestamps = range(initial_time; step = resolution, length = horizon_count)
        vals = [(Float64(i), Float64(i) + 10.0, Float64(i) + 20.0)
                for i in 1:horizon_count]
        ta = TimeSeries.TimeArray(collect(timestamps), vals)
        sts = IS.SingleTimeSeries(; name = "su_stages", data = ta)

        sys = IS.SystemData(; time_series_in_memory = true)
        comp = IS.TestComponent("c", 5)
        IS.add_component!(sys, comp)
        IS.add_time_series!(sys, comp, sts)

        tts = IS.TupleTimeSeries{StartUpStages}(only(IS.get_time_series_keys(comp)))
        inferred = Core.Compiler.return_type(
            IS.build_static_tuple,
            Tuple{typeof(tts), typeof(comp), Dates.DateTime},
        )
        @test inferred === StartUpStages
    end

    @testset "Missing time series" begin
        bogus_key = IS.StaticTimeSeriesKey(;
            time_series_type = IS.SingleTimeSeries,
            name = "nonexistent",
            initial_timestamp = Dates.DateTime("2024-01-01"),
            resolution = Dates.Hour(1),
            length = 24,
            features = Dict{String, Any}(),
        )
        tts = IS.TupleTimeSeries{StartUpStages}(bogus_key)

        sys = IS.SystemData(; time_series_in_memory = true)
        comp = IS.TestComponent("c", 5)
        IS.add_component!(sys, comp)

        @test_throws ArgumentError("No matching metadata is stored.") IS.build_static_tuple(
            tts, comp, Dates.DateTime("2024-01-01"),
        )
    end

    @testset "Serialization round-trip" begin
        tts = IS.TupleTimeSeries{StartUpStages}(static_key)
        tts_rt = IS.deserialize(IS.TupleTimeSeries, IS.serialize_struct(tts))
        @test tts_rt isa IS.TupleTimeSeries{StartUpStages}
        rt_key = IS.get_time_series_key(tts_rt)
        @test IS.get_name(rt_key) == IS.get_name(static_key)
        @test IS.get_time_series_type(rt_key) === IS.get_time_series_type(static_key)

        # Arity-2 round-trip
        tts2 = IS.TupleTimeSeries{MinMax}(static_key)
        tts2_rt = IS.deserialize(IS.TupleTimeSeries, IS.serialize_struct(tts2))
        @test tts2_rt isa IS.TupleTimeSeries{MinMax}
    end

    @testset "build_static_tuple round-trip (HDF5)" begin
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
                comp = IS.TestComponent("gen", 5)
                IS.add_component!(sys, comp)

                ta = TimeSeries.TimeArray(collect(timestamps), arity_vals)
                sts = IS.SingleTimeSeries(; name = "tuple_ts", data = ta)
                IS.add_time_series!(sys, comp, sts)

                key = only(IS.get_time_series_keys(comp))
                tts = IS.TupleTimeSeries{T}(key)

                v_first = IS.build_static_tuple(tts, comp, initial_time)
                v_mid = IS.build_static_tuple(tts, comp, initial_time + Dates.Hour(10))
                v_last = IS.build_static_tuple(
                    tts, comp, initial_time + (horizon_count - 1) * resolution,
                )

                @test v_first isa T
                @test v_first == T(arity_vals[1])
                @test v_mid == T(arity_vals[11])
                @test v_last == T(arity_vals[end])
            end
        end
    end
end
