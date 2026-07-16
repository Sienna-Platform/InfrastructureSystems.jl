@testset "Test dictionary time period conversion" begin
    faketimes1 = Dict("one" => Dates.Week(40), "two" => Dates.Day(6))
    faketimes2 = Dict("one" => Dates.Minute(40), "two" => Dates.Minute(6))
    faketimes3 = Dict(
        "one" => Dates.Millisecond(3),
        "two" => Dates.Second(4),
        "three" => Dates.Minute(40),
        "four" => Dates.Hour(3),
    )
    convert1 = IS.time_period_conversion(faketimes1)
    convert2 = IS.time_period_conversion(faketimes2)
    convert3 = IS.time_period_conversion(faketimes3)
    for dict in [convert1, convert2, convert3]
        for (k, v) in dict
            @test typeof(v) == Dates.Millisecond
        end
    end
end

@testset "Test time period conversion" begin
    fake1 = IS.time_period_conversion(Dates.Day(2))
    fake2 = IS.time_period_conversion(Dates.Hour(2))
    fake3 = IS.time_period_conversion(Dates.Minute(2))
    fake4 = IS.time_period_conversion(Dates.Second(2))
    fake5 = IS.time_period_conversion(Dates.Millisecond(2))
    fake_times = [fake1, fake2, fake3, fake4, fake5]
    for time_period in fake_times
        @test typeof(time_period) == Dates.Millisecond
    end
end

@testset "InfrastructureSystemsInternal units-anchor accessors" begin
    internal = IS.InfrastructureSystemsInternal()
    @test IS.get_base_value(internal) === nothing
    IS.set_base_value!(internal, 100.0)
    @test IS.get_base_value(internal) === 100.0
    IS.set_base_value!(internal, nothing)
    @test IS.get_base_value(internal) === nothing
end
