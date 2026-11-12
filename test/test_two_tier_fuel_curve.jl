const TT_FIRST = IS.PiecewiseIncrementalCurve(180.0, [20.0, 60.0], [7.5])
const TT_SECOND = IS.PiecewiseIncrementalCurve(0.0, [60.0, 70.0, 80.0], [9.5, 10.5])
_two_tier(; kw...) = IS.TwoTierFuelCurve(; first_tier_curve = TT_FIRST,
    second_tier_curve = TT_SECOND, tier_threshold = 60.0,
    fuel_units = IS.CommodityUnits.MMBtu, kw...)

@testset "TwoTierFuelCurve construction" begin
    c = _two_tier(; second_tier_fuel_cost = 3.0)
    @test IS.get_first_tier_curve(c) == TT_FIRST
    @test IS.get_second_tier_curve(c) == TT_SECOND
    @test IS.get_value_curve(c) == TT_SECOND
    @test IS.get_tier_threshold(c) == 60.0
    @test IS.get_second_tier_fuel_cost(c) == 3.0
    @test IS.get_first_tier_fuel_cost(c) == 0.0
    @test !IS.is_first_tier_priced(c)
    @test IS.get_fuel_units(c) == IS.CommodityUnits.MMBtu
    @test IS.get_power_units(c) == IS.NaturalUnit()
    @test IS.is_convex(c)
    @test !IS.is_time_series_backed(c)
    @test isconcretetype(typeof(c))

    mixed = IS.TwoTierFuelCurve(; first_tier_curve = IS.LinearCurve(7.5, 30.0),
        second_tier_curve = IS.LinearCurve(9.5), tier_threshold = 60.0,
        fuel_units = IS.CommodityUnits.MMBtu, second_tier_fuel_cost = 3.0)
    @test IS.get_first_tier_curve(mixed) == IS.LinearCurve(7.5, 30.0)
    @test isconcretetype(typeof(mixed))
    @test IS.is_first_tier_priced(
        _two_tier(; first_tier_fuel_cost = 1.0, second_tier_fuel_cost = 3.0),
    )
end

@testset "TwoTierFuelCurve rejects bad input" begin
    key = IS.TimeSeriesKey{IS.Deterministic{Float64}}(1)
    @test_throws UndefKeywordError IS.TwoTierFuelCurve(; second_tier_curve = TT_SECOND,
        tier_threshold = 60.0, fuel_units = IS.CommodityUnits.MMBtu,
        second_tier_fuel_cost = 3.0)
    @test_throws ArgumentError _two_tier()                                  # no price
    @test_throws ArgumentError _two_tier(; second_tier_fuel_cost = 3.0,
        second_tier_fuel_cost_time_series = key)                            # both prices
    @test_throws ArgumentError _two_tier(;
        second_tier_fuel_cost = 3.0,
        tier_threshold = 65.0,
    )
    @test_throws ArgumentError _two_tier(;
        second_tier_fuel_cost = 3.0,
        tier_threshold = -1.0,
    )
    @test_throws ArgumentError _two_tier(; second_tier_fuel_cost = 3.0,
        first_tier_fuel_cost = -1.0)
    @test_throws ArgumentError IS.get_time_series_key(
        _two_tier(; second_tier_fuel_cost = 3.0),
    )
end

@testset "TwoTierFuelCurve serialization and units" begin
    for c in (
        _two_tier(; second_tier_fuel_cost = 3.0),
        IS.TwoTierFuelCurve(; first_tier_curve = IS.LinearCurve(7.5, 30.0),
            second_tier_curve = IS.LinearCurve(9.5), tier_threshold = 60.0,
            fuel_units = u"GJ", second_tier_fuel_cost = 3.0, first_tier_fuel_cost = 1.0),
    )
        @test IS.deserialize(typeof(c), IS.serialize(c)) == c
    end
    c = _two_tier(; second_tier_fuel_cost = 3.0)
    pu = IS.convert_power_units(c, IS.SystemBaseUnit(), 100.0, 1.0)
    @test IS.get_tier_threshold(pu) ≈ 0.6
    @test IS.get_power_units(pu) == IS.SystemBaseUnit()
    @test IS.get_x_coords(IS.get_function_data(IS.get_first_tier_curve(pu))) ≈ [0.2, 0.6]
    @test IS.convert_power_units(c, IS.NaturalUnit(), 1.0, 1.0) === c
end
