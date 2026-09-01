@testset "RelativeQuantity construction and arithmetic" begin
    a = 0.6 * IS.DU
    b = 0.4 * IS.DU
    @test a isa IS.RelativeQuantity{Float64, IS.DeviceBaseUnit}
    @test IS._strip_units(a + b) ≈ 1.0
    @test IS._strip_units(a - b) ≈ 0.2
    @test IS._strip_units(-a) ≈ -0.6
    # scalar multiplication dispatches differently on each side
    @test IS._strip_units(2.0 * a) ≈ 1.2
    @test IS._strip_units(a * 2.0) ≈ 1.2
    @test IS._strip_units(a / 2.0) ≈ 0.3
end

@testset "RelativeQuantity comparisons" begin
    @test 0.6 * IS.DU < 0.7 * IS.DU
    @test 0.6 * IS.DU <= 0.6 * IS.DU
    @test isapprox(0.6 * IS.DU, 0.60000001 * IS.DU; atol = 1e-6)
    @test isless(0.6 * IS.DU, 0.7 * IS.DU)
end

@testset "DU and SU cannot be mixed" begin
    # Cross-unit operations now throw ArgumentError with a clear message
    # instead of a cryptic ErrorException from Base's promotion path.
    @test_throws ArgumentError 0.6 * IS.DU + 0.4 * IS.SU
    @test_throws ArgumentError 0.6 * IS.DU == 0.4 * IS.SU
    @test_throws ArgumentError 0.6 * IS.DU < 0.4 * IS.SU
    # isapprox lives outside the @eval loop (needs kwargs) — most regression-prone
    @test_throws ArgumentError isapprox(0.6 * IS.DU, 0.6 * IS.SU)
    # subtraction and isless are inside the @eval loop — verify they also throw
    @test_throws ArgumentError 0.6 * IS.DU - 0.4 * IS.SU
    @test_throws ArgumentError isless(0.6 * IS.DU, 0.7 * IS.SU)
end

@testset "tagged-vs-untagged mixing raises ArgumentError" begin
    # RelativeQuantity <: Number but NOT <: Real: the (RQ, Real) and (Real, RQ)
    # erroring methods use Real to avoid any ambiguity with (RQ, RQ) pairs.
    @test_throws ArgumentError 0.6 * IS.DU == 0.5
    @test_throws ArgumentError 0.5 + 0.6 * IS.DU
    @test_throws ArgumentError 0.6 * IS.DU - 0.5
    # Same-unit comparison must still work (more-specific dispatch is not disrupted)
    @test (0.6 * IS.DU == 0.6 * IS.DU)
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

@testset "Double-tagging is rejected" begin
    @test_throws ArgumentError (0.6 * IS.DU) * IS.SU
    @test_throws ArgumentError IS.SU * (0.6 * IS.DU)
end

@testset "RelativeQuantity hash matches ==" begin
    q1 = 1.0 * IS.DU
    q2 = 1 * IS.DU
    @test q1 == q2
    @test hash(q1) == hash(q2)
    d = Dict(q1 => "a")
    d[q2] = "b"
    @test length(d) == 1
end

@testset "RelativeQuantity Number interface completeness" begin
    q = 0.6 * IS.DU

    @testset "instance zero/one and predicates" begin
        @test zero(q) == 0.0 * IS.DU
        @test one(q) == 1.0 * IS.DU
        @test !iszero(q)
        @test iszero(zero(q))
        @test isfinite(q)
        @test !isnan(q)
        @test isnan(IS.RelativeQuantity(NaN, IS.DU))
        @test !isfinite(IS.RelativeQuantity(Inf, IS.SU))
        @test isinf(IS.RelativeQuantity(Inf, IS.SU))
        @test abs(-q) == q
    end

    @testset "isapprox against an untagged number errors clearly" begin
        @test_throws ArgumentError isapprox(q, 0.6)
        @test_throws ArgumentError isapprox(0.6, q)
    end

    @testset "isequal is total for container semantics" begin
        @test isequal(0.6 * IS.DU, 0.6 * IS.DU)
        @test !isequal(0.6 * IS.DU, 0.6 * IS.SU)
        @test !isequal(q, 0.6)
        @test !isequal(0.6, q)
        d = Dict((0.6 * IS.DU) => 1)
        @test !haskey(d, 0.6 * IS.SU)
        s = Set([0.6 * IS.DU])
        @test !(0.6 * IS.SU in s)
    end

    @testset "products of tagged quantities error clearly" begin
        @test_throws ArgumentError q * q
        @test_throws ArgumentError q^2
        @test_throws ArgumentError q / (0.5 * IS.DU)
    end
end

# `convert_cost_coefficient` no longer resolves unit systems: it applies an x-axis ratio
# the caller supplies. Which ratio a given (from, to) pair implies is the domain package's
# business -- `PowerSystems` owns that table and tests it against its own base machinery.
@testset "convert_cost_coefficient" begin
    @testset "identity (unit ratio)" begin
        @test IS.convert_cost_coefficient(2.5, 1.0) == 2.5
        @test IS.convert_cost_coefficient(2.5, 1.0, 2) == 2.5
    end

    @testset "linear" begin
        @test IS.convert_cost_coefficient(2.0, 4.0) ≈ 8.0
        @test IS.convert_cost_coefficient(2.0, 0.25) ≈ 0.5
    end

    @testset "exponent (quadratic)" begin
        @test IS.convert_cost_coefficient(2.0, 4.0, 2) ≈ 2.0 * 16.0
    end

    @testset "round-trip through the reciprocal ratio" begin
        for ratio in (2.0, 0.25, 100.0), k in (1, 2)
            forward = IS.convert_cost_coefficient(2.0, ratio, k)
            @test IS.convert_cost_coefficient(forward, inv(ratio), k) ≈ 2.0
        end
    end

    @testset "negative exponent inverts the ratio (used for piecewise x-coords)" begin
        @test IS.convert_cost_coefficient(2.0, 4.0, -1) ≈ 0.5
    end
end
@testset "display_string spells per-unit tags out" begin
    @test IS.display_string(0.6 * IS.DU) == "0.6 p.u. in component base"
    @test IS.display_string(0.3 * IS.SU) == "0.3 p.u. in system base"
    # Untagged values render exactly as `print` would.
    @test IS.display_string(1.5) == "1.5"
    @test IS.display_string(nothing) == "nothing"

    # A compound field on one base states that base once, after the tuple.
    @test IS.display_string((min = 0.0 * IS.SU, max = 2.5 * IS.SU)) ==
          "(min = 0.0 p.u., max = 2.5 p.u.) in system base"
    # Mixed bases have nothing to factor out, so each element is spelled out.
    @test IS.display_string((min = 0.0 * IS.SU, max = 2.5 * IS.DU)) ==
          "(min = 0.0 p.u. in system base, max = 2.5 p.u. in component base)"
    # So does a tuple that is not all tagged.
    @test IS.display_string((min = 0.0 * IS.SU, max = 2.5)) ==
          "(min = 0.0 p.u. in system base, max = 2.5)"
end
