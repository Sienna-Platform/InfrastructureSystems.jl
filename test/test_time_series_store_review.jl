# Regression tests for the InfraStore-backed time series paths: copy restricted to one
# system and one owner kind, typed forecast lookups, reads inside a
# transaction, calendar periods, key type identity, N-D static series, forecast `len`
# validation, and transform atomicity.

const _T0 = Dates.DateTime("2020-01-01T00:00:00")

function _hourly_sts(name, len = 24)
    return IS.SingleTimeSeries(name, _T0, Dates.Hour(1), collect(1.0:len))
end

function _hourly_det(name, count = 24, horizon = 24)
    data = SortedDict(
        _T0 + Dates.Hour(k) => fill(Float64(k + 1), horizon) for k in 0:(count - 1)
    )
    return IS.Deterministic(name, data, Dates.Hour(1); interval = Dates.Hour(1))
end

function _sys_with_component(name = "c")
    sys = IS.SystemData()
    component = IS.TestComponent(name, 5)
    IS.add_component!(sys, component)
    return sys, component
end

@testset "Test store review: copy_time_series! rejects owners from different systems" begin
    sys1, a = _sys_with_component("a")
    sys2, b = _sys_with_component("b")
    # Both components have id 1 in their own systems, so a store-level copy would
    # address the wrong owner.
    @test IS.get_id(a) == IS.get_id(b)
    IS.add_time_series!(sys1, a, _hourly_sts("s"); scenario = "x")
    IS.add_time_series!(
        sys2,
        b,
        IS.SingleTimeSeries("other", _T0, Dates.Hour(1), fill(100.0, 24)),
    )
    @test_throws ArgumentError IS.copy_time_series!(b, a)
    @test_throws ArgumentError IS.copy_time_series!(a, b)
    # Nothing changed on either side.
    @test [IS.get_name(k) for k in IS.get_time_series_keys(a)] == ["s"]
    @test [IS.get_name(k) for k in IS.get_time_series_keys(b)] == ["other"]
    @test IS.get_time_series_values(IS.SingleTimeSeries, b, "other") == fill(100.0, 24)

    # An owner that is not attached anywhere is rejected too.
    loose = IS.TestComponent("loose", 5)
    @test_throws ArgumentError IS.copy_time_series!(a, loose)
    @test_throws ArgumentError IS.copy_time_series!(loose, a)
end

@testset "Test store review: copy_time_series! rejects a component/attribute pair" begin
    sys, component = _sys_with_component()
    attr = IS.TestSupplemental(; value = 1.0)
    IS.add_supplemental_attribute!(sys, component, attr)
    IS.add_time_series!(sys, attr, _hourly_sts("attr_series"))
    IS.add_time_series!(sys, component, _hourly_sts("comp_series"))

    @test_throws ArgumentError IS.copy_time_series!(component, attr)
    @test_throws ArgumentError IS.copy_time_series!(attr, component)
    # Nothing changed, and no orphan rows: the system-wide iterators still resolve
    # every owner.
    @test [IS.get_name(k) for k in IS.get_time_series_keys(component)] == ["comp_series"]
    @test [IS.get_name(k) for k in IS.get_time_series_keys(attr)] == ["attr_series"]
    @test length(collect(IS.iterate_components_with_time_series(sys))) == 1
    @test length(collect(IS.iterate_supplemental_attributes_with_time_series(sys))) == 1
end

@testset "Test store review: get_time_series honors the requested forecast type" begin
    sys, component = _sys_with_component()
    IS.add_time_series!(sys, component, _hourly_det("fx"))
    @test_throws ArgumentError IS.get_time_series(IS.Probabilistic, component, "fx")
    @test_throws ArgumentError IS.get_time_series(IS.Scenarios, component, "fx")
    @test IS.get_time_series(IS.Deterministic, component, "fx") isa IS.Deterministic

    data = SortedDict(_T0 + Dates.Hour(k) => rand(24, 3) for k in 0:23)
    prob = IS.Probabilistic(
        "fx",
        data,
        [0.25, 0.5, 0.75],
        Dates.Hour(1);
        interval = Dates.Hour(1),
    )
    IS.add_time_series!(sys, component, prob)
    @test IS.get_time_series(IS.Deterministic, component, "fx") isa IS.Deterministic
    @test IS.get_time_series(IS.Probabilistic, component, "fx") isa IS.Probabilistic
    @test_throws ArgumentError IS.get_time_series(IS.Forecast, component, "fx")
end

@testset "Test store review: reads inside a transaction see staged additions" begin
    sys, component = _sys_with_component()
    IS.time_series_transaction(sys) do txn
        IS.add_time_series!(txn, component, _hourly_sts("v"))
        @test IS.has_time_series(component, IS.SingleTimeSeries, "v")
        @test length(IS.get_time_series_keys(component)) == 1
        @test IS.get_time_series_values(IS.SingleTimeSeries, component, "v") ==
              collect(1.0:24)
        # Adds keep working after the implicit flush, and the block stays one transaction.
        IS.add_time_series!(txn, component, _hourly_sts("w"))
    end
    @test IS.has_time_series(component, IS.SingleTimeSeries, "w")

    # A removal inside the block of a series staged earlier in it removes it.
    IS.time_series_transaction(sys) do txn
        IS.add_time_series!(txn, component, _hourly_sts("x"))
        IS.remove_time_series!(sys, IS.SingleTimeSeries, component, "x")
    end
    @test !IS.has_time_series(component, IS.SingleTimeSeries, "x")

    # A transform inside the block covers the staged series.
    IS.time_series_transaction(sys) do txn
        IS.add_time_series!(txn, component, _hourly_sts("y"))
        IS.transform_single_time_series!(
            sys,
            IS.DeterministicSingleTimeSeries,
            Dates.Hour(24),
            Dates.Hour(24),
        )
    end
    @test IS.has_time_series(component, IS.DeterministicSingleTimeSeries, "y")

    # Everything flushed inside a failing block still rolls back.
    @test_throws ErrorException IS.time_series_transaction(sys) do txn
        IS.add_time_series!(txn, component, _hourly_sts("z"))
        @test IS.has_time_series(component, IS.SingleTimeSeries, "z")
        error("boom")
    end
    @test !IS.has_time_series(component, IS.SingleTimeSeries, "z")
    @test isnothing(sys.time_series_manager.active_context)
end

@testset "Test store review: calendar-interval forecast windows" begin
    sys, component = _sys_with_component()
    resolution = Dates.Month(1)
    interval = Dates.Month(2)
    horizon_count = 12
    t1 = _T0
    t2 = t1 + interval
    t3 = t2 + interval
    data = Dict(
        t => TimeSeries.TimeArray(
            range(t; length = horizon_count, step = resolution),
            fill(Float64(i), horizon_count),
        ) for (i, t) in enumerate((t1, t2, t3))
    )
    det = IS.Deterministic("month_fc", data; resolution = resolution, interval = interval)
    IS.add_time_series!(sys, component, det)

    fc = IS.get_time_series(IS.Deterministic, component, "month_fc"; start_time = t2)
    @test IS.get_count(fc) == 2
    @test first(keys(IS.get_data(fc))) == t2
    @test IS.get_time_series_values(
        IS.Deterministic,
        component,
        "month_fc";
        start_time = t3,
    ) ==
          fill(3.0, horizon_count)
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        "month_fc";
        start_time = t1 + Dates.Month(1),
    )
    @test IS.get_time_series_resolutions(sys) == [Dates.Month(1)]
    @test IS.get_time_series_resolutions(sys; time_series_type = IS.Deterministic) ==
          [Dates.Month(1)]

    cache = IS.ForecastCache(IS.Deterministic, component, "month_fc"; start_time = t2)
    @test length(cache) == 2
    @test TimeSeries.values(IS.get_next_time_series_array!(cache)) ==
          fill(2.0, horizon_count)
    @test TimeSeries.values(IS.get_next_time_series_array!(cache)) ==
          fill(3.0, horizon_count)
    @test isnothing(IS.get_next_time(cache))
end

@testset "Test store review: calendar-resolution static series slicing" begin
    sys, component = _sys_with_component()
    sts = IS.SingleTimeSeries(
        "monthly",
        TimeSeries.TimeArray(
            range(_T0; length = 24, step = Dates.Month(1)),
            collect(1.0:24),
        );
        resolution = Dates.Month(1),
    )
    IS.add_time_series!(sys, component, sts)
    full = IS.get_time_series(IS.SingleTimeSeries, component, "monthly")
    @test IS.get_time_series_values(
        component,
        full;
        start_time = _T0 + Dates.Month(3),
        len = 4,
    ) ==
          [4.0, 5.0, 6.0, 7.0]
    @test IS.get_time_series_values(component, full; start_time = _T0 + Dates.Month(20)) ==
          collect(21.0:24)
    IS.add_time_series!(
        sys,
        component,
        IS.SingleTimeSeries("hourly", _T0, Dates.Hour(1), collect(1.0:24)),
    )
    @test IS.get_time_series_resolutions(sys) == [Dates.Hour(1), Dates.Month(1)]

    cache = IS.StaticTimeSeriesCache(
        IS.SingleTimeSeries,
        component,
        "monthly";
        start_time = _T0 + Dates.Month(2),
        cache_size_bytes = 5 * sizeof(Float64),
    )
    @test length(cache) == 22
    vals = Float64[]
    for ta in cache
        append!(vals, TimeSeries.values(ta))
    end
    @test vals == collect(3.0:24)
end

@testset "Test store review: single-window forecast rejects a misaligned start_time" begin
    sys, component = _sys_with_component()
    IS.add_time_series!(sys, component, _hourly_sts("s"))
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(24),
        Dates.Hour(24),
    )
    key = only(IS.get_time_series_keys(component; time_series_type = IS.Deterministic))
    @test IS.get_interval(key) == Dates.Millisecond(0)
    @test IS.get_count(
        IS.get_time_series(IS.Deterministic, component, "s"; start_time = _T0),
    ) == 1
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        "s";
        start_time = _T0 + Dates.Hour(5),
    )
    @test_throws ArgumentError IS.get_time_series_array(
        IS.Deterministic,
        component,
        "s";
        start_time = _T0 + Dates.Hour(5),
    )
end

@testset "Test store review: component iteration is consistent with and without resolution" begin
    sys, component = _sys_with_component()
    IS.add_time_series!(sys, component, _hourly_sts("s", 48))
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(24),
        Dates.Hour(24),
    )
    for T in (
        IS.Deterministic,
        IS.AbstractDeterministic,
        IS.DeterministicSingleTimeSeries,
        IS.Forecast,
    )
        @test length(
            collect(IS.iterate_components_with_time_series(sys; time_series_type = T)),
        ) == 1
        @test length(
            collect(
                IS.iterate_components_with_time_series(
                    sys;
                    time_series_type = T,
                    resolution = Dates.Hour(1),
                ),
            ),
        ) == 1
    end
    for T in (IS.Probabilistic, IS.Scenarios)
        @test isempty(
            collect(IS.iterate_components_with_time_series(sys; time_series_type = T)),
        )
        @test isempty(
            collect(
                IS.iterate_components_with_time_series(
                    sys;
                    time_series_type = T,
                    resolution = Dates.Hour(1),
                ),
            ),
        )
    end
end

@testset "Test store review: keys and queries use the unparameterized type" begin
    sys, component = _sys_with_component()
    data = SortedDict(_T0 + Dates.Hour(k) => rand(24, 3) for k in 0:23)
    prob = IS.Probabilistic(
        "p",
        data,
        [0.25, 0.5, 0.75],
        Dates.Hour(1);
        interval = Dates.Hour(1),
    )
    key = IS.add_time_series!(sys, component, prob)
    @test IS.get_time_series_type(key) === IS.Probabilistic
    @test IS.get_time_series_type(key) ===
          IS.get_time_series_type(only(IS.get_time_series_keys(component)))
    @test IS.get_time_series_hash(component, key) ==
          IS.get_time_series_hash(component, only(IS.get_time_series_keys(component)))

    sts = _hourly_sts("s")
    IS.add_time_series!(sys, component, sts)
    @test IS.has_time_series(component, typeof(sts), "s")
    @test IS.has_time_series(component, typeof(prob), "p")
    @test length(IS.get_time_series_keys(component; time_series_type = typeof(sts))) == 1
    @test IS.get_time_series(typeof(sts), component, "s") isa IS.SingleTimeSeries
    IS.remove_time_series!(sys, typeof(sts), component, "s")
    @test !IS.has_time_series(component, IS.SingleTimeSeries, "s")
end

@testset "Test store review: N-D SingleTimeSeries round-trips through the store" begin
    sys, component = _sys_with_component()
    mat = reshape(collect(1.0:72), 24, 3)
    mts = IS.SingleTimeSeries("matrix", _T0, Dates.Hour(1), mat)
    @test mts isa IS.SingleTimeSeries{Float64, 2}
    IS.add_time_series!(sys, component, mts)
    back = IS.get_time_series(IS.SingleTimeSeries, component, "matrix")
    @test back isa IS.SingleTimeSeries{Float64, 2}
    @test IS.get_array(back) == mat
    sliced = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "matrix";
        start_time = _T0 + Dates.Hour(2),
        len = 5,
    )
    @test IS.get_array(sliced) == mat[3:7, :]
    @test IS.get_initial_timestamp(sliced) == _T0 + Dates.Hour(2)

    cube = rand(24, 2, 2)
    IS.add_time_series!(
        sys,
        component,
        IS.SingleTimeSeries("cube", _T0, Dates.Hour(1), cube),
    )
    @test IS.get_array(IS.get_time_series(IS.SingleTimeSeries, component, "cube")) == cube

    nts = IS.NonSequentialTimeSeries(
        "nseq",
        [_T0, _T0 + Dates.Hour(3), _T0 + Dates.Hour(7)],
        reshape(collect(1.0:6), 3, 2),
    )
    IS.add_time_series!(sys, component, nts)
    @test IS.get_array(IS.get_time_series(IS.NonSequentialTimeSeries, component, "nseq")) ==
          reshape(collect(1.0:6), 3, 2)
end

@testset "Test store review: forecast len is validated against the horizon" begin
    sys, component = _sys_with_component()
    IS.add_time_series!(sys, component, _hourly_det("fc"))
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        "fc";
        len = 25,
    )
    @test_throws ArgumentError IS.get_time_series(
        IS.Deterministic,
        component,
        "fc";
        len = 0,
    )
    @test length(
        IS.get_time_series_values(IS.Deterministic, component, "fc"; len = 24),
    ) == 24
    @test length(
        IS.get_time_series_values(IS.Deterministic, component, "fc"; len = 3),
    ) == 3
end

@testset "Test store review: transform_single_time_series! keeps old views on failure" begin
    sys, component = _sys_with_component()
    IS.add_time_series!(sys, component, _hourly_sts("s", 48))
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(24),
        Dates.Hour(24),
    )
    @test IS.has_time_series(component, IS.DeterministicSingleTimeSeries, "s")
    @test_throws IS.ConflictingInputsError IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(100),
        Dates.Hour(1),
    )
    @test IS.has_time_series(component, IS.DeterministicSingleTimeSeries, "s")
    @test IS.get_forecast_parameters(sys).horizon == Dates.Hour(24)
end
