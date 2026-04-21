# Get all possible isomorphic representations of the given `ValueCurve`
function all_conversions(vc::IS.ValueCurve;
    universe = (IS.InputOutputCurve, IS.IncrementalCurve, IS.AverageRateCurve),
)
    convert_to = filter(!=(nameof(typeof(vc))) ∘ nameof, universe)  # x -> nameof(x) != nameof(typeof(vc))
    result = Set{IS.ValueCurve}(constructor(vc) for constructor in convert_to)
    (vc isa IS.InputOutputCurve{IS.LinearFunctionData}) &&
        push!(result, IS.InputOutputCurve{IS.QuadraticFunctionData}(vc))
    return result
end

@testset "Test ValueCurves" begin
    # IS.InputOutputCurve
    io_quadratic = IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1))
    @test io_quadratic isa IS.InputOutputCurve{IS.QuadraticFunctionData}
    @test IS.get_function_data(io_quadratic) == IS.QuadraticFunctionData(3, 2, 1)
    @test IS.IncrementalCurve(io_quadratic) ==
          IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1.0)
    @test IS.AverageRateCurve(io_quadratic) ==
          IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1.0)
    @test zero(io_quadratic) == IS.InputOutputCurve(IS.LinearFunctionData(0, 0))
    @test zero(IS.InputOutputCurve) == IS.InputOutputCurve(IS.LinearFunctionData(0, 0))
    @test IS.is_cost_alias(io_quadratic) == IS.is_cost_alias(typeof(io_quadratic)) == true
    @test repr(io_quadratic) == sprint(show, io_quadratic) ==
          "QuadraticCurve(3.0, 2.0, 1.0)"
    @test sprint(show, "text/plain", io_quadratic) ==
          "QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 3.0 x^2 + 2.0 x + 1.0"

    io_linear = IS.InputOutputCurve(IS.LinearFunctionData(2, 1))
    @test io_linear isa IS.InputOutputCurve{IS.LinearFunctionData}
    @test IS.get_function_data(io_linear) == IS.LinearFunctionData(2, 1)
    @test IS.InputOutputCurve{IS.QuadraticFunctionData}(io_linear) ==
          IS.InputOutputCurve(IS.QuadraticFunctionData(0, 2, 1))
    @test IS.IncrementalCurve(io_linear) ==
          IS.IncrementalCurve(IS.LinearFunctionData(0, 2), 1.0)
    @test IS.AverageRateCurve(io_linear) ==
          IS.AverageRateCurve(IS.LinearFunctionData(0, 2), 1.0)
    @test IS.is_cost_alias(io_linear) == IS.is_cost_alias(typeof(io_linear)) == true
    @test repr(io_linear) == sprint(show, io_linear) ==
          "LinearCurve(2.0, 1.0)"
    @test sprint(show, "text/plain", io_linear) ==
          "LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 2.0 x + 1.0"

    io_piecewise = IS.InputOutputCurve(IS.PiecewiseLinearData([(1, 6), (3, 9), (5, 13)]))
    @test io_piecewise isa IS.InputOutputCurve{IS.PiecewiseLinearData}
    @test IS.get_function_data(io_piecewise) ==
          IS.PiecewiseLinearData([(1, 6), (3, 9), (5, 13)])
    @test IS.IncrementalCurve(io_piecewise) ==
          IS.IncrementalCurve(IS.PiecewiseStepData([1, 3, 5], [1.5, 2]), 6.0)
    @test IS.AverageRateCurve(io_piecewise) ==
          IS.AverageRateCurve(IS.PiecewiseStepData([1, 3, 5], [3, 2.6]), 6.0)
    @test IS.is_cost_alias(io_piecewise) == IS.is_cost_alias(typeof(io_piecewise)) == true
    @test repr(io_piecewise) == sprint(show, io_piecewise) ==
          "PiecewisePointCurve([(x = 1.0, y = 6.0), (x = 3.0, y = 9.0), (x = 5.0, y = 13.0)])"
    @test sprint(show, "text/plain", io_piecewise) ==
          "PiecewisePointCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: piecewise linear y = f(x) connecting points:\n  (x = 1.0, y = 6.0)\n  (x = 3.0, y = 9.0)\n  (x = 5.0, y = 13.0)"

    # IS.IncrementalCurve
    inc_linear = IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1.0)
    inc_linear_no_initial = IS.IncrementalCurve(IS.LinearFunctionData(6, 2), nothing)
    @test inc_linear isa IS.IncrementalCurve{IS.LinearFunctionData}
    @test inc_linear_no_initial isa IS.IncrementalCurve{IS.LinearFunctionData}
    @test IS.get_function_data(inc_linear) == IS.LinearFunctionData(6, 2)
    @test IS.get_initial_input(inc_linear) == 1
    @test IS.InputOutputCurve(inc_linear) ==
          IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1))
    @test IS.InputOutputCurve(IS.IncrementalCurve(IS.LinearFunctionData(0, 2), 1.0)) ==
          IS.InputOutputCurve(IS.LinearFunctionData(2, 1))
    @test IS.AverageRateCurve(inc_linear) ==
          IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1.0)
    @test_throws ArgumentError IS.InputOutputCurve(inc_linear_no_initial)
    @test_throws ArgumentError IS.AverageRateCurve(inc_linear_no_initial)
    @test zero(inc_linear) == IS.IncrementalCurve(IS.LinearFunctionData(0, 0), 0.0)
    @test zero(IS.IncrementalCurve) == IS.IncrementalCurve(IS.LinearFunctionData(0, 0), 0.0)
    @test IS.is_cost_alias(inc_linear) == IS.is_cost_alias(typeof(inc_linear)) == false
    @test repr(inc_linear) == sprint(show, inc_linear) ==
          "InfrastructureSystems.IncrementalCurve{InfrastructureSystems.LinearFunctionData}(InfrastructureSystems.LinearFunctionData(6.0, 2.0), 1.0, nothing)"
    @test sprint(show, "text/plain", inc_linear) ==
          "IncrementalCurve where initial value is 1.0, derivative function f is: f(x) = 6.0 x + 2.0"

    inc_piecewise = IS.IncrementalCurve(IS.PiecewiseStepData([1, 3, 5], [1.5, 2]), 6.0)
    inc_piecewise_no_initial =
        IS.IncrementalCurve(IS.PiecewiseStepData([1, 3, 5], [1.5, 2]), nothing)
    @test inc_piecewise isa IS.IncrementalCurve{IS.PiecewiseStepData}
    @test inc_piecewise_no_initial isa IS.IncrementalCurve{IS.PiecewiseStepData}
    @test IS.get_function_data(inc_piecewise) == IS.PiecewiseStepData([1, 3, 5], [1.5, 2])
    @test IS.get_initial_input(inc_piecewise) == 6
    @test IS.InputOutputCurve(inc_piecewise) ==
          IS.InputOutputCurve(IS.PiecewiseLinearData([(1, 6), (3, 9), (5, 13)]))
    @test IS.AverageRateCurve(inc_piecewise) ==
          IS.AverageRateCurve(IS.PiecewiseStepData([1, 3, 5], [3, 2.6]), 6.0)
    @test_throws ArgumentError IS.InputOutputCurve(inc_piecewise_no_initial)
    @test_throws ArgumentError IS.AverageRateCurve(inc_piecewise_no_initial)
    @test IS.is_cost_alias(inc_piecewise) == IS.is_cost_alias(typeof(inc_piecewise)) ==
          true
    @test repr(inc_piecewise) == sprint(show, inc_piecewise) ==
          "PiecewiseIncrementalCurve(6.0, [1.0, 3.0, 5.0], [1.5, 2.0])"
    @test sprint(show, "text/plain", inc_piecewise) ==
          "PiecewiseIncrementalCurve where initial value is 6.0, derivative function f is: f(x) =\n  1.5 for x in [1.0, 3.0)\n  2.0 for x in [3.0, 5.0)"

    # IS.AverageRateCurve
    ar_linear = IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1.0)
    ar_linear_no_initial = IS.AverageRateCurve(IS.LinearFunctionData(3, 2), nothing)
    @test ar_linear isa IS.AverageRateCurve{IS.LinearFunctionData}
    @test ar_linear_no_initial isa IS.AverageRateCurve{IS.LinearFunctionData}
    @test IS.get_function_data(ar_linear) == IS.LinearFunctionData(3, 2)
    @test IS.get_initial_input(ar_linear) == 1
    @test IS.InputOutputCurve(ar_linear) ==
          IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1))
    @test IS.InputOutputCurve(IS.AverageRateCurve(IS.LinearFunctionData(0, 2), 1.0)) ==
          IS.InputOutputCurve(IS.LinearFunctionData(2, 1))
    @test IS.IncrementalCurve(ar_linear) ==
          IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1.0)
    @test_throws ArgumentError IS.InputOutputCurve(ar_linear_no_initial)
    @test_throws ArgumentError IS.IncrementalCurve(ar_linear_no_initial)
    @test zero(ar_linear) == IS.AverageRateCurve(IS.LinearFunctionData(0, 0), 0.0)
    @test zero(IS.AverageRateCurve) == IS.AverageRateCurve(IS.LinearFunctionData(0, 0), 0.0)
    @test IS.is_cost_alias(ar_linear) == IS.is_cost_alias(typeof(ar_linear)) == false
    @test repr(ar_linear) == sprint(show, ar_linear) ==
          "InfrastructureSystems.AverageRateCurve{InfrastructureSystems.LinearFunctionData}(InfrastructureSystems.LinearFunctionData(3.0, 2.0), 1.0, nothing)"
    @test sprint(show, "text/plain", ar_linear) ==
          "AverageRateCurve where initial value is 1.0, average rate function f is: f(x) = 3.0 x + 2.0"

    ar_piecewise = IS.AverageRateCurve(IS.PiecewiseStepData([1, 3, 5], [3, 2.6]), 6.0)
    ar_piecewise_no_initial =
        IS.AverageRateCurve(IS.PiecewiseStepData([1, 3, 5], [3, 2.6]), nothing)
    @test ar_piecewise isa IS.AverageRateCurve{IS.PiecewiseStepData}
    @test ar_piecewise_no_initial isa IS.AverageRateCurve{IS.PiecewiseStepData}
    @test IS.get_function_data(ar_piecewise) == IS.PiecewiseStepData([1, 3, 5], [3, 2.6])
    @test IS.get_initial_input(ar_piecewise) == 6
    @test IS.InputOutputCurve(ar_piecewise) ==
          IS.InputOutputCurve(IS.PiecewiseLinearData([(1, 6), (3, 9), (5, 13)]))
    @test IS.IncrementalCurve(ar_piecewise) ==
          IS.IncrementalCurve(IS.PiecewiseStepData([1, 3, 5], [1.5, 2]), 6.0)
    @test_throws ArgumentError IS.InputOutputCurve(ar_piecewise_no_initial)
    @test_throws ArgumentError IS.IncrementalCurve(ar_piecewise_no_initial)
    @test IS.is_cost_alias(ar_piecewise) == IS.is_cost_alias(typeof(ar_piecewise)) == true
    @test repr(ar_piecewise) == sprint(show, ar_piecewise) ==
          "PiecewiseAverageCurve(6.0, [1.0, 3.0, 5.0], [3.0, 2.6])"
    @test sprint(show, "text/plain", ar_piecewise) ==
          "PiecewiseAverageCurve where initial value is 6.0, average rate function f is: f(x) =\n  3.0 for x in [1.0, 3.0)\n  2.6 for x in [3.0, 5.0)"

    # Serialization round trip
    curves_by_type = [  # typeof() gives parameterized types
        (io_quadratic, IS.InputOutputCurve),
        (io_linear, IS.InputOutputCurve),
        (io_piecewise, IS.InputOutputCurve),
        (inc_linear, IS.IncrementalCurve),
        (inc_piecewise, IS.IncrementalCurve),
        (ar_linear, IS.AverageRateCurve),
        (ar_piecewise, IS.AverageRateCurve),
        (inc_linear_no_initial, IS.IncrementalCurve),
        (inc_piecewise_no_initial, IS.IncrementalCurve),
        (ar_linear_no_initial, IS.AverageRateCurve),
        (ar_piecewise_no_initial, IS.AverageRateCurve),
    ]
    for (curve, curve_type) in curves_by_type
        @test IS.serialize(curve) isa AbstractDict
        @test IS.deserialize(curve_type, IS.serialize(curve)) == curve
    end

    @test zero(IS.ValueCurve) == IS.InputOutputCurve(IS.LinearFunctionData(0, 0))
end

@testset "Test ValueCurve type conversion constructors" begin
    @test IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1), 1) ==
          IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1), 1.0)
    @test IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1) ==
          IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1.0)
    @test IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1) ==
          IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1.0)
end

@testset "Test cost aliases" begin
    lc = IS.LinearCurve(3.0, 5.0)
    @test lc == IS.InputOutputCurve(IS.LinearFunctionData(3.0, 5.0))
    @test IS.LinearCurve(3.0) == IS.InputOutputCurve(IS.LinearFunctionData(3.0, 0.0))
    @test IS.get_proportional_term(lc) == 3.0
    @test IS.get_constant_term(lc) == 5.0

    qc = IS.QuadraticCurve(1.0, 2.0, 18.0)
    @test qc == IS.InputOutputCurve(IS.QuadraticFunctionData(1.0, 2.0, 18.0))
    @test IS.get_quadratic_term(qc) == 1.0
    @test IS.get_proportional_term(qc) == 2.0
    @test IS.get_constant_term(qc) == 18.0

    ppc = IS.PiecewisePointCurve([(1.0, 20.0), (2.0, 24.0), (3.0, 30.0)])
    @test ppc ==
          IS.InputOutputCurve(
        IS.PiecewiseLinearData([(1.0, 20.0), (2.0, 24.0), (3.0, 30.0)]),
    )
    @test IS.get_points(ppc) ==
          [(x = 1.0, y = 20.0), (x = 2.0, y = 24.0), (x = 3.0, y = 30.0)]
    @test IS.get_x_coords(ppc) == [1.0, 2.0, 3.0]
    @test IS.get_y_coords(ppc) == [20.0, 24.0, 30.0]
    @test IS.get_slopes(ppc) == [4.0, 6.0]

    pic = IS.PiecewiseIncrementalCurve(20.0, [1.0, 2.0, 3.0], [4.0, 6.0])
    @test pic ==
          IS.IncrementalCurve(IS.PiecewiseStepData([1.0, 2.0, 3.0], [4.0, 6.0]), 20.0)
    @test IS.get_x_coords(pic) == [1.0, 2.0, 3.0]
    @test IS.get_slopes(pic) == [4.0, 6.0]

    pac = IS.PiecewiseAverageCurve(20.0, [1.0, 2.0, 3.0], [12.0, 10.0])
    @test pac ==
          IS.AverageRateCurve(IS.PiecewiseStepData([1.0, 2.0, 3.0], [12.0, 10.0]), 20.0)
    @test IS.get_x_coords(pac) == [1.0, 2.0, 3.0]
    @test IS.get_average_rates(pac) == [12.0, 10.0]

    # Make sure the aliases get registered properly
    @test sprint(show, "text/plain", IS.QuadraticCurve) ==
          "QuadraticCurve (alias for InfrastructureSystems.InputOutputCurve{InfrastructureSystems.QuadraticFunctionData})"
end

@testset "Test input_at_zero" begin
    iaz = 1234.5
    pwinc_without_iaz =
        IS.IncrementalCurve(IS.PiecewiseStepData([1, 3, 5], [1.5, 2]), 6.0, nothing)
    pwinc_with_iaz =
        IS.IncrementalCurve(IS.PiecewiseStepData([1, 3, 5], [1.5, 2]), 6.0, iaz)
    all_without_iaz = [
        IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1), nothing),
        IS.InputOutputCurve(IS.LinearFunctionData(2, 1), nothing),
        IS.InputOutputCurve(IS.PiecewiseLinearData([(1, 6), (3, 9), (5, 13)]), nothing),
        IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1.0, nothing),
        pwinc_without_iaz,
        IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1.0, nothing),
        IS.AverageRateCurve(IS.PiecewiseStepData([1, 3, 5], [3, 2.6]), 6.0, nothing),
    ]
    all_with_iaz = [
        IS.InputOutputCurve(IS.QuadraticFunctionData(3, 2, 1), iaz),
        IS.InputOutputCurve(IS.LinearFunctionData(2, 1), iaz),
        IS.InputOutputCurve(IS.PiecewiseLinearData([(1, 6), (3, 9), (5, 13)]), iaz),
        IS.IncrementalCurve(IS.LinearFunctionData(6, 2), 1.0, iaz),
        pwinc_with_iaz,
        IS.AverageRateCurve(IS.LinearFunctionData(3, 2), 1.0, iaz),
        IS.AverageRateCurve(IS.PiecewiseStepData([1, 3, 5], [3, 2.6]), 6.0, iaz),
    ]

    # Alias constructors
    @test IS.PiecewiseIncrementalCurve(1234.5, 6.0, [1.0, 3.0, 5.0], [1.5, 2.0]) ==
          pwinc_with_iaz

    # Getters and printouts
    for (without_iaz, with_iaz) in zip(all_without_iaz, all_with_iaz)
        @test IS.get_input_at_zero(without_iaz) === nothing
        @test IS.get_input_at_zero(with_iaz) == iaz
        @test occursin(string(iaz), repr(with_iaz))
        @test sprint(show, with_iaz) == repr(with_iaz)
        @test occursin(string(iaz), sprint(show, "text/plain", with_iaz))
    end

    @test repr(pwinc_with_iaz) == sprint(show, pwinc_with_iaz) ==
          "PiecewiseIncrementalCurve(1234.5, 6.0, [1.0, 3.0, 5.0], [1.5, 2.0])"
    @test sprint(show, "text/plain", pwinc_with_iaz) ==
          "PiecewiseIncrementalCurve where value at zero is 1234.5, initial value is 6.0, derivative function f is: f(x) =\n  1.5 for x in [1.0, 3.0)\n  2.0 for x in [3.0, 5.0)"

    # Preserved under conversion
    for without_iaz in Iterators.flatten(all_conversions.(all_without_iaz))
        @test IS.get_input_at_zero(without_iaz) === nothing
    end
    for with_iaz in Iterators.flatten(all_conversions.(all_with_iaz))
        @test IS.get_input_at_zero(with_iaz) == iaz
    end
end

@testset "Test IS.CostCurve and IS.FuelCurve" begin
    cc = IS.CostCurve(IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3)))
    fc = IS.FuelCurve(IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3)), 4.0)
    # TODO also test fuel curves with time series

    @test IS.get_value_curve(cc) == IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3))
    @test IS.get_value_curve(fc) == IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3))
    @test IS.get_fuel_cost(fc) == 4

    @test IS.serialize(cc) isa AbstractDict
    @test IS.serialize(fc) isa AbstractDict
    @test IS.deserialize(IS.CostCurve, IS.serialize(cc)) == cc
    @test IS.deserialize(IS.FuelCurve, IS.serialize(fc)) == fc

    @test zero(cc) == IS.CostCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)))
    @test zero(IS.CostCurve) ==
          IS.CostCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)))
    @test zero(fc) ==
          IS.FuelCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)), 0.0)
    @test zero(IS.FuelCurve) ==
          IS.FuelCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)), 0.0)

    @test repr(cc) == sprint(show, cc) ==
          "InfrastructureSystems.CostCurve{QuadraticCurve}(QuadraticCurve(1.0, 2.0, 3.0), InfrastructureSystems.UnitSystemModule.UnitSystem.NATURAL_UNITS = 2, LinearCurve(0.0, 0.0))"
    @test repr(fc) == sprint(show, fc) ==
          "InfrastructureSystems.FuelCurve{QuadraticCurve}(QuadraticCurve(1.0, 2.0, 3.0), InfrastructureSystems.UnitSystemModule.UnitSystem.NATURAL_UNITS = 2, 4.0, LinearCurve(0.0, 0.0), LinearCurve(0.0, 0.0))"
    @test sprint(show, "text/plain", cc) ==
          sprint(show, "text/plain", cc; context = :compact => false) ==
          "CostCurve:\n  value_curve: QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0\n  power_units: InfrastructureSystems.UnitSystemModule.UnitSystem.NATURAL_UNITS = 2\n  vom_cost: LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 0.0 x + 0.0"
    @test sprint(show, "text/plain", fc) ==
          sprint(show, "text/plain", fc; context = :compact => false) ==
          "FuelCurve:\n  value_curve: QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0\n  power_units: InfrastructureSystems.UnitSystemModule.UnitSystem.NATURAL_UNITS = 2\n  fuel_cost: 4.0\n  startup_fuel_offtake: LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 0.0 x + 0.0\n  vom_cost: LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 0.0 x + 0.0"
    @test sprint(show, "text/plain", cc; context = :compact => true) ==
          "CostCurve with power_units InfrastructureSystems.UnitSystemModule.UnitSystem.NATURAL_UNITS = 2, vom_cost LinearCurve(0.0, 0.0), and value_curve:\n  QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0"
    @test sprint(show, "text/plain", fc; context = :compact => true) ==
          "FuelCurve with power_units InfrastructureSystems.UnitSystemModule.UnitSystem.NATURAL_UNITS = 2, fuel_cost 4.0, startup_fuel_offtake LinearCurve(0.0, 0.0), vom_cost LinearCurve(0.0, 0.0), and value_curve:\n  QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0"

    @test IS.get_power_units(cc) == IS.UnitSystem.NATURAL_UNITS
    @test IS.get_power_units(fc) == IS.UnitSystem.NATURAL_UNITS
    @test IS.get_power_units(
        IS.CostCurve(zero(IS.InputOutputCurve), IS.UnitSystem.SYSTEM_BASE),
    ) ==
          IS.UnitSystem.SYSTEM_BASE
    @test IS.get_power_units(
        IS.FuelCurve(zero(IS.InputOutputCurve), IS.UnitSystem.DEVICE_BASE, 1.0),
    ) ==
          IS.UnitSystem.DEVICE_BASE

    @test IS.get_vom_cost(cc) == IS.LinearCurve(0.0)
    @test IS.get_vom_cost(fc) == IS.LinearCurve(0.0)
    @test IS.get_vom_cost(
        IS.CostCurve(zero(IS.InputOutputCurve), IS.LinearCurve(1.0, 2.0)),
    ) ==
          IS.LinearCurve(1.0, 2.0)
    @test IS.get_vom_cost(
        IS.FuelCurve(
            zero(IS.InputOutputCurve),
            1.0,
            IS.LinearCurve(10.0, 7.0),
            IS.LinearCurve(3.0, 4.0),
        ),
    ) ==
          IS.LinearCurve(3.0, 4.0)
    @test IS.get_startup_fuel_offtake(
        IS.FuelCurve(
            zero(IS.InputOutputCurve),
            1.0,
            IS.LinearCurve(10.0, 7.0),
            IS.LinearCurve(3.0, 4.0),
        ),
    ) ==
          IS.LinearCurve(10.0, 7.0)
end

@testset "is_time_series_backed for CostCurve and FuelCurve" begin
    forecast_key = IS.ForecastKey(;
        time_series_type = IS.Deterministic,
        name = "fuel_price",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        horizon = Dates.Hour(24),
        interval = Dates.Hour(24),
        count = 1,
        features = Dict{String, Any}(),
    )

    # Scalar dispatches
    @test IS.is_time_series_backed(forecast_key) == true
    @test IS.is_time_series_backed(nothing) == false

    static_vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3))
    ts_vc = IS.TimeSeriesInputOutputCurve(IS.TimeSeriesQuadraticFunctionData(forecast_key))

    # CostCurve: only time-series-backed when its value curve is
    @test IS.is_time_series_backed(IS.CostCurve(static_vc)) == false
    @test IS.is_time_series_backed(IS.CostCurve(ts_vc)) == true

    # FuelCurve 2x2: fuel_cost ∈ {Float64, TimeSeriesKey} × value_curve ∈ {static, time-varying}
    @test IS.is_time_series_backed(IS.FuelCurve(static_vc, 4.0)) == false
    @test IS.is_time_series_backed(IS.FuelCurve(ts_vc, 4.0)) == true
    @test IS.is_time_series_backed(IS.FuelCurve(static_vc, forecast_key)) == true
    @test IS.is_time_series_backed(IS.FuelCurve(ts_vc, forecast_key)) == true
end

@testset "Test prohibited FunctionData types" begin
    # Incremental and Average Rate curves only support
    # linear and piecewise step function data.
    q_fd = IS.QuadraticFunctionData(1, 2, 3)
    pwl_fd = IS.PiecewiseLinearData([(x = 0.0, y = 1.0), (x = 1.0, y = 2.0)])
    @test_throws MethodError IS.IncrementalCurve(q_fd, 0.0)
    @test_throws MethodError IS.AverageRateCurve(q_fd, 0.0)
    @test_throws MethodError IS.IncrementalCurve(pwl_fd, 0.0)
    @test_throws MethodError IS.AverageRateCurve(pwl_fd, 0.0)
end

@testset "Test InputOutputCurve evaluation" begin
    io_quadratic = IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3))
    @test io_quadratic(0.0) == 3.0
    @test io_quadratic(1.0) == 6.0
    @test io_quadratic(2.0) == 11.0

    io_linear = IS.InputOutputCurve(IS.LinearFunctionData(3, 2))
    @test io_linear(0.0) == 2.0
    @test io_linear(1.0) == 5.0
    @test io_linear(2.0) == 8.0

    pwl = IS.PiecewiseLinearData([(x = 1, y = 3), (x = 3, y = 7), (x = 5, y = 11)])
    io_piecewise = IS.InputOutputCurve(pwl)
    @test io_piecewise(1.0) == 3.0
    @test io_piecewise(3.0) == 7.0
    @test io_piecewise(5.0) == 11.0
end
