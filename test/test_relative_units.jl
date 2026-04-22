@testset "RelativeQuantity construction and arithmetic" begin
    a = 0.6 * IS.DU
    b = 0.4 * IS.DU
    @test a isa IS.RelativeQuantity{Float64, IS.DeviceBaseUnit}
    @test IS.ustrip(a + b) ≈ 1.0
    @test IS.ustrip(a - b) ≈ 0.2
    @test IS.ustrip(-a) ≈ -0.6
    # scalar multiplication dispatches differently on each side
    @test IS.ustrip(2.0 * a) ≈ 1.2
    @test IS.ustrip(a * 2.0) ≈ 1.2
    @test IS.ustrip(a / 2.0) ≈ 0.3
end

@testset "RelativeQuantity comparisons" begin
    @test 0.6 * IS.DU < 0.7 * IS.DU
    @test 0.6 * IS.DU <= 0.6 * IS.DU
    @test isapprox(0.6 * IS.DU, 0.60000001 * IS.DU; atol = 1e-6)
    @test isless(0.6 * IS.DU, 0.7 * IS.DU)
end

@testset "DU and SU cannot be mixed" begin
    @test_throws Exception 0.6 * IS.DU + 0.4 * IS.SU
    @test_throws Exception 0.6 * IS.DU == 0.4 * IS.SU
end

@testset "RelativeQuantity zero and one" begin
    @test zero(IS.RelativeQuantity{Float64, IS.DeviceBaseUnit}) == 0.0 * IS.DU
    @test one(IS.RelativeQuantity{Float64, IS.DeviceBaseUnit}) == 1.0 * IS.DU
end

@testset "RelativeQuantity display" begin
    @test sprint(show, 0.6 * IS.DU) == "0.6 DU"
    @test sprint(show, 0.3 * IS.SU) == "0.3 SU"
    @test sprint(show, IS.DU) == "DU"
    @test sprint(show, IS.SU) == "SU"
    @test sprint(show, IS.NU) == "NU"
end
