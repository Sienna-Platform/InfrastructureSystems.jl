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

@testset "convert_cost_coefficient" begin
    sb, db = 100.0, 50.0
    @testset "identity (same unit system)" begin
        for U in (IS.SU, IS.DU, IS.NU)
            @test IS.convert_cost_coefficient(2.5, U, U, sb, db) == 2.5
            @test IS.convert_cost_coefficient(2.5, U, U, sb, db, 2) == 2.5
        end
    end

    @testset "DU ↔ SU (linear)" begin
        @test IS.convert_cost_coefficient(2.0, IS.DU, IS.SU, sb, db) ≈ 2.0 * sb / db
        @test IS.convert_cost_coefficient(2.0, IS.SU, IS.DU, sb, db) ≈ 2.0 * db / sb
    end

    @testset "NU ↔ {SU, DU} (linear)" begin
        @test IS.convert_cost_coefficient(2.0, IS.NU, IS.SU, sb, db) ≈ 2.0 * sb
        @test IS.convert_cost_coefficient(2.0, IS.SU, IS.NU, sb, db) ≈ 2.0 / sb
        @test IS.convert_cost_coefficient(2.0, IS.NU, IS.DU, sb, db) ≈ 2.0 * db
        @test IS.convert_cost_coefficient(2.0, IS.DU, IS.NU, sb, db) ≈ 2.0 / db
    end

    @testset "exponent (quadratic)" begin
        @test IS.convert_cost_coefficient(2.0, IS.DU, IS.SU, sb, db, 2) ≈ 2.0 * (sb / db)^2
        @test IS.convert_cost_coefficient(2.0, IS.NU, IS.SU, sb, db, 2) ≈ 2.0 * sb^2
    end

    @testset "round-trip is identity (linear and quadratic)" begin
        for (Ua, Ub) in ((IS.DU, IS.SU), (IS.NU, IS.SU), (IS.NU, IS.DU))
            for k in (1, 2)
                forward = IS.convert_cost_coefficient(2.0, Ua, Ub, sb, db, k)
                back = IS.convert_cost_coefficient(forward, Ub, Ua, sb, db, k)
                @test back ≈ 2.0
            end
        end
    end

    @testset "negative exponent inverts linear ratio (used for piecewise x-coords)" begin
        @test IS.convert_cost_coefficient(2.0, IS.DU, IS.SU, sb, db, -1) ≈ 2.0 * db / sb
        @test IS.convert_cost_coefficient(2.0, IS.NU, IS.SU, sb, db, -1) ≈ 2.0 / sb
    end
end
