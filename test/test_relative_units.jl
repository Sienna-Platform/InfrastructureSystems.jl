# Stand-in domain bases for `resolve_per_unit`, deliberately not power-system ones: IS must
# work for any network.
module TestPerUnitBases
using Unitful: @dimension, @refunit
@dimension 𝐂𝐩𝐫 "Cpr" CompPressureBase
@dimension 𝐒𝐩𝐫 "Spr" SysPressureBase
@refunit CUpr "CUpr" CUpr 𝐂𝐩𝐫 false
@refunit SUpr "SUpr" SUpr 𝐒𝐩𝐫 false
end

const _CU_BASE = TestPerUnitBases.CUpr
const _SU_BASE = TestPerUnitBases.SUpr

@testset "generic per-unit units" begin
    @test string(0.6u"CU") == "0.6 CU"
    @test string(0.3u"SU") == "0.3 SU"
    @test 0.6u"CU" + 0.4u"CU" ≈ 1.0u"CU"
    # Each carries its own dimension: no mixing bases, no conversion to a natural unit.
    @test_throws DimensionError 0.6u"CU" + 0.4u"SU"
    @test_throws DimensionError uconvert(u"hr", 0.6u"CU")
    @test_throws DimensionError 0.6u"CU" + 0.4
end

@testset "resolve_per_unit" begin
    resolve(u) = IS.resolve_per_unit(u, _CU_BASE, _SU_BASE)

    @test resolve(u"CU") == _CU_BASE
    @test resolve(u"SU") == _SU_BASE
    # The caller's residual is kept around the swapped-in base.
    @test resolve(u"CU/hr") == _CU_BASE / u"hr"
    @test resolve(u"SU*hr") == _SU_BASE * u"hr"
    # A natural target has nothing to resolve.
    @test resolve(u"hr") == u"hr"

    # Neither says which base the field is per-unit on.
    @test_throws ArgumentError resolve(u"CU^2")
    @test_throws ArgumentError resolve(u"CU^-1")
    @test_throws ArgumentError resolve(u"CU*SU")
    @test_throws ArgumentError resolve(u"CU^(1/2)")

    # Per-unit values of different kinds, once resolved, no longer add.
    other_base = _CU_BASE^2
    @test_throws DimensionError 1.0 * resolve(u"CU") +
                                1.0 * IS.resolve_per_unit(u"CU", other_base, _SU_BASE)

    # Runs on every unit-aware getter: must fold to a constant with the target passed as an
    # argument, as a getter receives it.
    g(units) = IS.resolve_per_unit(units, _CU_BASE, _SU_BASE)
    for units in (u"CU", u"SU/hr", u"hr")
        code, return_type = only(code_typed(g, (typeof(units),)))
        @test isconcretetype(return_type)
        @test length(code.code) == 1  # `return <constant>`
        g(units)
        @test (@allocated g(units)) == 0
    end
end

@testset "_strip_units" begin
    @test IS._strip_units(0.6u"CU") == 0.6
    @test IS._strip_units(2.0u"hr") == 2.0
    @test IS._strip_units((min = 0.1u"CU", max = 0.9u"CU")) == (min = 0.1, max = 0.9)
    @test IS._strip_units(1.5) == 1.5
end

@testset "unit-system markers" begin
    @test sprint(show, IS.CU) == "CU"
    @test sprint(show, IS.SU) == "SU"
    @test sprint(show, IS.NU) == "NU"
    # The pre-Unitful `0.6 * CU` spelling errors, naming `0.6u"CU"`.
    @test_throws ArgumentError 0.6 * IS.CU
    @test_throws ArgumentError IS.SU * 0.6
end

@testset "unit markers broadcast as scalars" begin
    # Regression for #629: without `broadcastable`, Base's fallback tries to
    # `collect` the marker and fails with `no method matching length(::ComponentBaseUnit)`.
    scale(x, ::IS.AbstractUnitSystem) = x
    for units in (IS.CU, IS.SU, IS.NU)
        @test scale.([1.0, 2.0, 3.0], units) == [1.0, 2.0, 3.0]
    end
    # an array of markers is still broadcast element-wise
    @test ([IS.CU, IS.SU] .=== IS.CU) == [true, false]
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

@testset "display_string" begin
    # Anything without a domain method renders exactly as `print` would.
    @test IS.display_string(1.5) == "1.5"
    @test IS.display_string(nothing) == "nothing"
    @test IS.display_string(0.6u"CU") == "0.6 CU"
    # Compound fields render element-wise.
    @test IS.display_string((min = 0.0, max = 2.5)) == "(min = 0.0, max = 2.5)"
end
