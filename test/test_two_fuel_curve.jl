const STACKED = IS.TwoFuelCurve(;
    first_fuel_curve = IS.LinearCurve(9.89, 113.0),
    second_fuel_curve = IS.PiecewiseIncrementalCurve(nothing, [185.4, 304.4], [10.017]),
    fuel_units = IS.CommodityUnits.MMBtu, second_fuel_cost = 3.44,
    fuel_curve_type = IS.TwoFuelCurveType.STACKED)
const BLENDED = IS.TwoFuelCurve(;
    first_fuel_curve = IS.PiecewisePointCurve([
        (100.0, 900.0),
        (200.0, 1700.0),
        (300.0, 2700.0),
    ]),
    second_fuel_curve = IS.PiecewisePointCurve([
        (100.0, 950.0),
        (250.0, 2225.0),
        (300.0, 2725.0),
    ]),
    fuel_units = IS.CommodityUnits.MMBtu, first_fuel_cost = 3.0, second_fuel_cost = 5.0,
    fuel_curve_type = IS.TwoFuelCurveType.BLENDED, second_fuel_output_share = 0.3)
_, (_first_key, _second_key) = create_forecast_key_fixture("first_price", "second_price")
const BLENDED_TS = IS.TwoFuelCurve(;
    first_fuel_curve = IS.get_first_fuel_curve(BLENDED),
    second_fuel_curve = IS.get_second_fuel_curve(BLENDED),
    fuel_units = IS.CommodityUnits.MMBtu,
    first_fuel_cost_time_series = _first_key,
    second_fuel_cost_time_series = _second_key,
    fuel_curve_type = IS.TwoFuelCurveType.BLENDED, second_fuel_output_share = 0.3)

@testset "TwoFuelCurve construction" begin
    @test IS.get_fuel_curve_type(STACKED) == IS.TwoFuelCurveType.STACKED
    @test IS.get_stacking_threshold(STACKED) == 185.4
    @test IS.get_first_fuel_cost(STACKED) == 0.0          # stacked default: paid elsewhere
    @test IS.get_second_fuel_output_share(STACKED) == 0.0
    @test IS.get_fuel_curve_type(BLENDED) == IS.TwoFuelCurveType.BLENDED
    @test IS.get_second_fuel_output_share(BLENDED) == 0.3
    @test IS.get_fuel_units(BLENDED) == IS.CommodityUnits.MMBtu
    @test IS.is_convex(BLENDED)
    @test !IS.is_concave(BLENDED)
    @test IS.is_concave(STACKED)    # a line and one step
    @test_throws ArgumentError IS.get_function_data(BLENDED)
    @test_throws ArgumentError IS.get_initial_input(STACKED)
    @test !IS.is_time_series_backed(BLENDED)
    @test_throws ArgumentError IS.get_stacking_threshold(BLENDED)
    @test_throws ArgumentError IS.get_value_curve(STACKED)
    @test_throws ArgumentError IS.get_value_curve(BLENDED)
    @test_throws ArgumentError IS.get_time_series_key(BLENDED)
    @test_throws ArgumentError IS.get_time_series_key(STACKED)
    @test IS.is_time_series_backed(BLENDED_TS)
    @test IS.get_first_fuel_cost_time_series(BLENDED_TS) == _first_key
    @test IS.get_second_fuel_cost_time_series(BLENDED_TS) == _second_key
    @test isnothing(IS.get_first_fuel_cost(BLENDED_TS))
    @test isnothing(IS.get_second_fuel_cost(BLENDED_TS))
    # a piecewise first curve that ends at the threshold is accepted
    @test IS.TwoFuelCurve(;
        first_fuel_curve = IS.PiecewisePointCurve([(40.0, 500.0), (185.4, 1947.0)]),
        second_fuel_curve = IS.PiecewiseIncrementalCurve(nothing, [185.4, 304.4], [10.017]),
        fuel_units = IS.CommodityUnits.MMBtu, second_fuel_cost = 3.44,
        fuel_curve_type = IS.TwoFuelCurveType.STACKED) isa IS.TwoFuelCurve
    # a first curve with no x range is taken to cover output up to the threshold
    for first_curve in (IS.LinearCurve(9.89, 113.0), IS.QuadraticCurve(0.01, 9.0, 113.0))
        @test IS.get_stacking_threshold(
            IS.TwoFuelCurve(;
                first_fuel_curve = first_curve,
                second_fuel_curve = IS.PiecewiseIncrementalCurve(
                    nothing, [185.4, 304.4], [10.017]),
                fuel_units = IS.CommodityUnits.MMBtu, second_fuel_cost = 3.44,
                fuel_curve_type = IS.TwoFuelCurveType.STACKED),
        ) == 185.4
    end
end

@testset "TwoFuelCurve rejects bad input" begin
    key = IS.TimeSeriesKey{IS.SingleTimeSeries{Float64}}(1)
    stacked(; kw...) = IS.TwoFuelCurve(;
        first_fuel_curve = IS.LinearCurve(9.89, 113.0),
        second_fuel_curve = IS.PiecewiseIncrementalCurve(nothing, [185.4, 304.4], [10.017]),
        fuel_units = IS.CommodityUnits.MMBtu, second_fuel_cost = 3.44,
        fuel_curve_type = IS.TwoFuelCurveType.STACKED, kw...)
    blended(; kw...) = IS.TwoFuelCurve(;
        first_fuel_curve = IS.PiecewisePointCurve([
            (100.0, 900.0),
            (200.0, 1700.0),
            (300.0, 2700.0),
        ]),
        second_fuel_curve = IS.PiecewisePointCurve([
            (100.0, 950.0),
            (250.0, 2225.0),
            (300.0, 2725.0),
        ]),
        fuel_units = IS.CommodityUnits.MMBtu, first_fuel_cost = 3.0,
        second_fuel_cost = 5.0, fuel_curve_type = IS.TwoFuelCurveType.BLENDED,
        second_fuel_output_share = 0.3, kw...)
    @test_throws ArgumentError stacked(second_fuel_curve = IS.LinearCurve(10.017))
    @test_throws ArgumentError stacked(
        second_fuel_curve = IS.PiecewiseIncrementalCurve(0.0, [185.4, 304.4], [10.017]))
    @test_throws ArgumentError stacked(
        first_fuel_curve = IS.PiecewisePointCurve([(40.0, 500.0), (150.0, 1947.0)]))
    # A STACKED curve takes no share, and a BLENDED one needs total fuel on both curves.
    err = try
        stacked(; second_fuel_output_share = 0.3)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("second_fuel_output_share = 0", err.msg)
    err = try
        IS.TwoFuelCurve(;
            first_fuel_curve = IS.LinearCurve(9.89, 113.0),
            second_fuel_curve = IS.PiecewiseIncrementalCurve(
                nothing, [185.4, 304.4], [10.017]),
            fuel_units = IS.CommodityUnits.MMBtu, first_fuel_cost = 0.0,
            second_fuel_cost = 3.44, fuel_curve_type = IS.TwoFuelCurveType.BLENDED,
            second_fuel_output_share = 0.3)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("initial_input", err.msg)
    @test occursin("the second fuel curve", err.msg)
    err = try
        blended(;
            first_fuel_curve = IS.PiecewiseIncrementalCurve(
                nothing, [100.0, 250.0, 300.0], [10.0, 11.0]),
        )
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("the first fuel curve", err.msg)
    @test occursin("initial_input", err.msg)
    @test blended(;
        first_fuel_curve = IS.PiecewiseIncrementalCurve(
            900.0, [100.0, 250.0, 300.0], [10.0, 11.0]),
        second_fuel_curve = IS.PiecewiseIncrementalCurve(
            950.0, [100.0, 250.0, 300.0], [9.0, 10.0]),
    ) isa IS.TwoFuelCurve
    @test_throws ArgumentError stacked(second_fuel_cost = nothing)
    @test_throws ArgumentError stacked(second_fuel_cost_time_series = key)
    @test_throws ArgumentError stacked(
        first_fuel_cost = 1.0, first_fuel_cost_time_series = key)
    for share in (1.2, -0.1, NaN)
        @test_throws ArgumentError blended(second_fuel_output_share = share)
    end
    @test_throws ArgumentError blended(first_fuel_cost = nothing)
    @test_throws ArgumentError blended(
        second_fuel_curve = IS.PiecewisePointCurve([
            (200.0, 950.0),
            (250.0, 2225.0),
            (300.0, 2725.0),
        ]))
    @test_throws ArgumentError blended(
        second_fuel_curve = IS.PiecewisePointCurve([
            (100.0, 950.0),
            (250.0, 2225.0),
            (280.0, 2725.0),
        ]))
    @test_throws ArgumentError stacked(second_fuel_cost = -1.0)
    @test_throws ArgumentError blended(second_fuel_cost = -1.0)
    @test_throws ArgumentError blended(second_fuel_cost = NaN)
end

@testset "TwoFuelCurve blended time series curves" begin
    fk(::Type{T}) where {T} = IS.TimeSeriesKey{IS.Deterministic{T}}(1)
    sk = IS.TimeSeriesKey{IS.Deterministic{Float64}}(2)
    first_c = IS.PiecewisePointCurve([(100.0, 900.0), (300.0, 2700.0)])
    mk(c) = IS.TwoFuelCurve(; first_fuel_curve = first_c, second_fuel_curve = c,
        fuel_units = IS.CommodityUnits.MMBtu, first_fuel_cost = 3.0,
        second_fuel_cost = 5.0, fuel_curve_type = IS.TwoFuelCurveType.BLENDED,
        second_fuel_output_share = 0.3)
    @test mk(
        IS.TimeSeriesPiecewiseIncrementalCurve(fk(IS.PiecewiseStepData), sk, nothing),
    ) isa IS.TwoFuelCurve
    @test_throws ArgumentError mk(
        IS.TimeSeriesPiecewiseIncrementalCurve(fk(IS.PiecewiseStepData), nothing, nothing),
    )
    @test mk(
        IS.TimeSeriesPiecewisePointCurve(fk(IS.PiecewiseLinearData)),
    ) isa IS.TwoFuelCurve
end

# Natural units to a base of 100 MW; the fuel axis has no ratio.
_to_base(curve, to) = IS.convert_power_units(curve, to, 100.0, 1.0)

@testset "TwoFuelCurve serialization and units" begin
    for curve in (STACKED, BLENDED, BLENDED_TS)
        @test IS.deserialize(typeof(curve), IS.serialize(curve)) == curve
    end
    stacked_db = _to_base(STACKED, IS.SystemBaseUnit())
    @test IS.get_power_units(stacked_db) isa IS.SystemBaseUnit
    @test IS.get_stacking_threshold(stacked_db) ≈ 1.854
    blended_db = _to_base(BLENDED, IS.SystemBaseUnit())
    @test IS.get_second_fuel_output_share(blended_db) == 0.3
    @test IS.get_fuel_curve_type(blended_db) == IS.TwoFuelCurveType.BLENDED
    @test first(
        IS.get_x_coords(IS.get_function_data(IS.get_first_fuel_curve(blended_db))),
    ) ≈
          1.0
    @test IS.get_first_fuel_cost(blended_db) == 3.0
    @test IS.get_second_fuel_cost(blended_db) == 5.0
    ts_db = _to_base(BLENDED_TS, IS.SystemBaseUnit())
    @test IS.get_second_fuel_cost_time_series(ts_db) == _second_key
    @test _to_base(STACKED, IS.NaturalUnit()) === STACKED
    compact(c) = sprint(show, MIME"text/plain"(), c; context = :compact => true)
    @test occursin("blend", compact(BLENDED))
    @test occursin("185.4", compact(STACKED))
    expanded(c) = sprint(show, MIME"text/plain"(), c)
    @test occursin("fuel_curve_type: TwoFuelCurveType.STACKED", expanded(STACKED))
    @test occursin("second_fuel_output_share: 0.3", expanded(BLENDED))
end

@testset "TwoFuelCurve startup fuel offtake" begin
    for c in (STACKED, BLENDED)
        @test IS.get_first_fuel_startup_offtake(c) == IS.LinearCurve(0.0)
        @test IS.get_second_fuel_startup_offtake(c) == IS.LinearCurve(0.0)
    end
    with_offtake(c) = IS.TwoFuelCurve(;
        first_fuel_curve = IS.get_first_fuel_curve(c),
        second_fuel_curve = IS.get_second_fuel_curve(c),
        fuel_units = IS.CommodityUnits.MMBtu,
        first_fuel_cost = IS.get_first_fuel_cost(c),
        second_fuel_cost = IS.get_second_fuel_cost(c),
        fuel_curve_type = IS.get_fuel_curve_type(c),
        second_fuel_output_share = IS.get_second_fuel_output_share(c),
        first_fuel_startup_offtake = IS.LinearCurve(5.0),
        second_fuel_startup_offtake = IS.LinearCurve(2.0))
    for c in (STACKED, BLENDED)
        o = with_offtake(c)
        @test IS.get_first_fuel_startup_offtake(o) == IS.LinearCurve(5.0)
        @test IS.get_second_fuel_startup_offtake(o) == IS.LinearCurve(2.0)
        @test IS.deserialize(typeof(o), IS.serialize(o)) == o
        # Like FuelCurve, a conversion leaves the startup offtake as it is.
        db = _to_base(o, IS.SystemBaseUnit())
        @test IS.get_first_fuel_startup_offtake(db) == IS.LinearCurve(5.0)
        @test IS.get_second_fuel_startup_offtake(db) == IS.LinearCurve(2.0)
    end
end

@testset "TwoFuelCurve with UNDEFINED fuel_curve_type" begin
    first_c = IS.PiecewisePointCurve([(100.0, 900.0), (300.0, 2700.0)])
    second_c = IS.PiecewiseIncrementalCurve(nothing, [185.4, 304.4], [10.017])
    # The layout is not checked, but prices and the share still are.
    c = IS.TwoFuelCurve(; first_fuel_curve = first_c, second_fuel_curve = second_c,
        fuel_units = IS.CommodityUnits.MMBtu, first_fuel_cost = 3.0,
        second_fuel_cost = 5.0)
    @test IS.get_fuel_curve_type(c) == IS.TwoFuelCurveType.UNDEFINED
    @test IS.deserialize(typeof(c), IS.serialize(c)) == c
    @test IS.serialize(c)["fuel_curve_type"] == "UNDEFINED"
    @test_throws ArgumentError IS.get_stacking_threshold(c)
    @test occursin(
        "UNDEFINED",
        sprint(show, MIME"text/plain"(), c; context = :compact => true),
    )
    # Only a STACKED curve defaults the first fuel price to 0.
    @test_throws ArgumentError IS.TwoFuelCurve(; first_fuel_curve = first_c,
        second_fuel_curve = second_c, fuel_units = IS.CommodityUnits.MMBtu,
        second_fuel_cost = 5.0)
    @test_throws ArgumentError IS.TwoFuelCurve(; first_fuel_curve = first_c,
        second_fuel_curve = second_c, fuel_units = IS.CommodityUnits.MMBtu,
        first_fuel_cost = 3.0, second_fuel_cost = 5.0, second_fuel_output_share = 1.5)
end
