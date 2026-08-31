@testset "Test units label round-trips for every time series type" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    horizon_count = 24

    # SingleTimeSeries: declared at construction, returned on read.
    sts = IS.SingleTimeSeries("sts", initial_time, resolution, rand(24); units = "MW")
    @test IS.get_units(sts) == "MW"
    IS.add_time_series!(sys, component, sts)
    @test IS.get_units(IS.get_time_series(IS.SingleTimeSeries, component, "sts")) == "MW"

    # A sliced read describes the same values, so it keeps the label.
    sliced = IS.get_time_series(
        IS.SingleTimeSeries,
        component,
        "sts";
        start_time = initial_time + Dates.Hour(2),
        len = 4,
    )
    @test IS.get_units(sliced) == "MW"

    # NonSequentialTimeSeries.
    stamps = [initial_time, initial_time + Dates.Hour(1), initial_time + Dates.Hour(4)]
    nts = IS.NonSequentialTimeSeries("nts", stamps, rand(3); units = "MWh")
    @test IS.get_units(nts) == "MWh"
    IS.add_time_series!(sys, component, nts)
    @test IS.get_units(
        IS.get_time_series(IS.NonSequentialTimeSeries, component, "nts"),
    ) == "MWh"

    # Deterministic.
    one_dim = SortedDict(
        initial_time => rand(horizon_count),
        other_time => rand(horizon_count),
    )
    det = IS.Deterministic("det", one_dim, resolution; units = "MW")
    @test IS.get_units(det) == "MW"
    IS.add_time_series!(sys, component, det)
    @test IS.get_units(IS.get_time_series(IS.Deterministic, component, "det")) == "MW"

    # Probabilistic.
    two_dim = SortedDict(
        initial_time => rand(horizon_count, 3),
        other_time => rand(horizon_count, 3),
    )
    prob = IS.Probabilistic("prob", two_dim, [0.1, 0.5, 0.9], resolution; units = "MW")
    @test IS.get_units(prob) == "MW"
    IS.add_time_series!(sys, component, prob)
    @test IS.get_units(IS.get_time_series(IS.Probabilistic, component, "prob")) == "MW"

    # Scenarios.
    scen = IS.Scenarios("scen", two_dim, resolution; units = "MW")
    @test IS.get_units(scen) == "MW"
    IS.add_time_series!(sys, component, scen)
    @test IS.get_units(IS.get_time_series(IS.Scenarios, component, "scen")) == "MW"
end

@testset "Test units defaults to nothing and is never inferred" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    # Omitting the label leaves `nothing` end to end. IS does not fill it in or
    # guess: `nothing` may mean "unknown" or "dimensionless", and which one is
    # the caller's convention to establish.
    ts = IS.SingleTimeSeries("unitless", initial_time, resolution, rand(24))
    @test IS.get_units(ts) === nothing
    IS.add_time_series!(sys, component, ts)
    stored = IS.get_time_series(IS.SingleTimeSeries, component, "unitless")
    @test IS.get_units(stored) === nothing

    # There is deliberately no setter: the label is immutable after construction.
    @test !isdefined(IS, :set_units!)
end

@testset "Test units is carried by data-sharing constructors" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    horizon_count = 24

    # A constructor that shares another instance's data shares its label too --
    # the label describes the values, and the values are the same values.
    sts = IS.SingleTimeSeries("sts", initial_time, resolution, rand(24); units = "MW")
    @test IS.get_units(IS.SingleTimeSeries(sts, "other_name")) == "MW"

    stamps = [initial_time, initial_time + Dates.Hour(1), initial_time + Dates.Hour(4)]
    nts = IS.NonSequentialTimeSeries("nts", stamps, rand(3); units = "MWh")
    @test IS.get_units(IS.NonSequentialTimeSeries(nts, "other_name")) == "MWh"

    one_dim = SortedDict(
        initial_time => rand(horizon_count),
        other_time => rand(horizon_count),
    )
    det = IS.Deterministic("det", one_dim, resolution; units = "MW")
    @test IS.get_units(IS.Deterministic(det, "other_name")) == "MW"
    # ...including the "existing instance plus a subset of data" form.
    @test IS.get_units(IS.Deterministic(det, one_dim)) == "MW"

    two_dim = SortedDict(
        initial_time => rand(horizon_count, 3),
        other_time => rand(horizon_count, 3),
    )
    prob = IS.Probabilistic("prob", two_dim, [0.1, 0.5, 0.9], resolution; units = "MW")
    @test IS.get_units(IS.Probabilistic(prob, "other_name")) == "MW"

    scen = IS.Scenarios("scen", two_dim, resolution; units = "MW")
    @test IS.get_units(IS.Scenarios(scen, "other_name")) == "MW"
end

@testset "Test units is not part of a time series' identity" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    data = rand(24)

    IS.add_time_series!(
        sys,
        component,
        IS.SingleTimeSeries("dup", initial_time, resolution, data; units = "MW"),
    )

    # Two series differing only in their label are the same series, so the
    # second add is a duplicate rather than a second association.
    err = try
        IS.add_time_series!(
            sys,
            component,
            IS.SingleTimeSeries("dup", initial_time, resolution, data; units = "kW"),
        )
        nothing
    catch e
        e
    end
    @test typeof(err) === ArgumentError
    @test occursin("duplicate attributes", sprint(showerror, err))

    # The label appears on no key, so it cannot be addressed or filtered by: a key
    # is its association id and nothing else. It does read back on the catalog
    # row, which describes a series rather than addressing one.
    @test !(:units in fieldnames(IS.TimeSeriesKey))
    md = only(IS.list_time_series_metadata(component))
    @test IS.get_units(md) == "MW"
end

@testset "Test units survives transform_single_time_series!" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    IS.add_time_series!(
        sys,
        component,
        IS.SingleTimeSeries("load", initial_time, resolution, rand(48); units = "MW"),
    )
    IS.transform_single_time_series!(
        sys,
        IS.DeterministicSingleTimeSeries,
        Dates.Hour(24),
        Dates.Hour(24),
    )

    # The derived view is the same data viewed as windows, so it reports the
    # source's label.
    derived = IS.get_time_series(IS.Deterministic, component, "load")
    @test IS.get_units(derived) == "MW"
end

@testset "Test quantity_kind and unit_system round-trip for every type" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    horizon_count = 24
    descriptors(x) = (IS.get_quantity_kind(x), IS.get_unit_system(x))

    sts = IS.SingleTimeSeries(
        "sts", initial_time, resolution, rand(24);
        units = "MW", quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    @test descriptors(sts) == ("ActivePower", IS.DU)
    IS.add_time_series!(sys, component, sts)
    @test descriptors(IS.get_time_series(IS.SingleTimeSeries, component, "sts")) ==
          ("ActivePower", IS.DU)

    # A sliced read describes the same values, so it keeps both.
    sliced = IS.get_time_series(
        IS.SingleTimeSeries, component, "sts";
        start_time = initial_time + Dates.Hour(2), len = 4,
    )
    @test descriptors(sliced) == ("ActivePower", IS.DU)

    stamps = [initial_time, initial_time + Dates.Hour(1), initial_time + Dates.Hour(4)]
    nts = IS.NonSequentialTimeSeries(
        "nts", stamps, rand(3);
        quantity_kind = "Energy", unit_system = IS.NU,
    )
    IS.add_time_series!(sys, component, nts)
    @test descriptors(IS.get_time_series(IS.NonSequentialTimeSeries, component, "nts")) ==
          ("Energy", IS.NU)

    one_dim = SortedDict(
        initial_time => rand(horizon_count),
        other_time => rand(horizon_count),
    )
    det = IS.Deterministic(
        "det", one_dim, resolution; quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    IS.add_time_series!(sys, component, det)
    @test descriptors(IS.get_time_series(IS.Deterministic, component, "det")) ==
          ("ActivePower", IS.DU)

    two_dim = SortedDict(
        initial_time => rand(horizon_count, 3),
        other_time => rand(horizon_count, 3),
    )
    prob = IS.Probabilistic(
        "prob", two_dim, [0.1, 0.5, 0.9], resolution;
        quantity_kind = "ActivePower", unit_system = IS.NU,
    )
    IS.add_time_series!(sys, component, prob)
    @test descriptors(IS.get_time_series(IS.Probabilistic, component, "prob")) ==
          ("ActivePower", IS.NU)

    scen = IS.Scenarios(
        "scen", two_dim, resolution; quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    IS.add_time_series!(sys, component, scen)
    @test descriptors(IS.get_time_series(IS.Scenarios, component, "scen")) ==
          ("ActivePower", IS.DU)
end

@testset "Test unset unit_system stays unspecified rather than NaturalUnit" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    # Declaring nothing must read back as nothing. `NU` would be a claim the
    # caller never made -- and per-unit values mislabeled as natural are wrong
    # by the component's base, silently.
    ts = IS.SingleTimeSeries("plain", initial_time, resolution, rand(24))
    @test IS.get_quantity_kind(ts) === nothing
    @test IS.get_unit_system(ts) === nothing
    IS.add_time_series!(sys, component, ts)
    stored = IS.get_time_series(IS.SingleTimeSeries, component, "plain")
    @test IS.get_quantity_kind(stored) === nothing
    @test IS.get_unit_system(stored) === nothing
    @test IS.get_unit_system(stored) !== IS.NU

    # Both are immutable, like the units label.
    @test !isdefined(IS, :set_quantity_kind!)
    @test !isdefined(IS, :set_unit_system!)
end

@testset "Test quantity_kind and unit_system are carried by data-sharing constructors" begin
    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)
    other_time = initial_time + resolution
    horizon_count = 24
    descriptors(x) = (IS.get_quantity_kind(x), IS.get_unit_system(x))

    sts = IS.SingleTimeSeries(
        "sts", initial_time, resolution, rand(24);
        quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    @test descriptors(IS.SingleTimeSeries(sts, "other_name")) == ("ActivePower", IS.DU)

    stamps = [initial_time, initial_time + Dates.Hour(1), initial_time + Dates.Hour(4)]
    nts = IS.NonSequentialTimeSeries(
        "nts", stamps, rand(3); quantity_kind = "Energy", unit_system = IS.NU,
    )
    @test descriptors(IS.NonSequentialTimeSeries(nts, "other_name")) == ("Energy", IS.NU)

    one_dim = SortedDict(
        initial_time => rand(horizon_count),
        other_time => rand(horizon_count),
    )
    det = IS.Deterministic(
        "det", one_dim, resolution; quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    @test descriptors(IS.Deterministic(det, "other_name")) == ("ActivePower", IS.DU)
    @test descriptors(IS.Deterministic(det, one_dim)) == ("ActivePower", IS.DU)

    two_dim = SortedDict(
        initial_time => rand(horizon_count, 3),
        other_time => rand(horizon_count, 3),
    )
    prob = IS.Probabilistic(
        "prob", two_dim, [0.1, 0.5, 0.9], resolution;
        quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    @test descriptors(IS.Probabilistic(prob, "other_name")) == ("ActivePower", IS.DU)

    scen = IS.Scenarios(
        "scen", two_dim, resolution; quantity_kind = "ActivePower", unit_system = IS.DU,
    )
    @test descriptors(IS.Scenarios(scen, "other_name")) == ("ActivePower", IS.DU)
end

@testset "Test SystemBaseUnit is rejected by the store rather than downgraded" begin
    sys = create_system_data()
    component = IS.get_component(IS.TestComponent, sys, "Component1")

    initial_time = Dates.DateTime("2020-09-01")
    resolution = Dates.Hour(1)

    # IS names three bases; the store represents two. A system-base series is
    # refused at the boundary instead of being written as device base or dropped
    # to unspecified -- either would misreport the basis of every value to the
    # next reader, unrecoverably.
    ts = IS.SingleTimeSeries(
        "su", initial_time, resolution, rand(24); unit_system = IS.SU,
    )
    @test IS.get_unit_system(ts) === IS.SU
    @test_throws ArgumentError IS.add_time_series!(sys, component, ts)

    # The two the store does represent go through.
    for (name, marker) in (("du", IS.DU), ("nu", IS.NU))
        ok = IS.SingleTimeSeries(
            name, initial_time, resolution, rand(24); unit_system = marker,
        )
        IS.add_time_series!(sys, component, ok)
        @test IS.get_unit_system(
            IS.get_time_series(IS.SingleTimeSeries, component, name),
        ) === marker
    end
end
