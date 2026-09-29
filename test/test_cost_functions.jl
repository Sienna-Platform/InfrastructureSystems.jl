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
    # Cost curves are always natural units, so no unit system is written
    @test !haskey(IS.serialize(cc), "power_units")
    @test !haskey(IS.serialize(fc), "power_units")
    @test IS.deserialize(IS.CostCurve, IS.serialize(cc)) == cc
    @test IS.deserialize(IS.FuelCurve, IS.serialize(fc)) == fc

    # FuelCurve whose fuel_cost is a TimeSeriesKey must round-trip to the
    # concrete key subtype (regression: previously dispatched on the abstract
    # `TimeSeriesKey` and crashed in `fieldnames`).
    sys, (fuel_key,) = create_forecast_key_fixture("fuel_price")
    fc_ts = IS.FuelCurve(
        IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3)),
        fuel_key,
    )
    @test IS.serialize(fc_ts)["fuel_cost_time_series"] == IS.serialize(fuel_key)
    fc_ts_rt = IS.deserialize(IS.FuelCurve, IS.serialize(fc_ts))
    @test IS.compare_values(fc_ts_rt, fc_ts)

    @test zero(cc) == IS.CostCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)))
    @test zero(IS.CostCurve) ==
          IS.CostCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)))
    @test zero(fc) ==
          IS.FuelCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)), 0.0)
    @test zero(IS.FuelCurve) ==
          IS.FuelCurve(IS.InputOutputCurve(IS.LinearFunctionData(0.0, 0.0)), 0.0)

    # repr and sprint(show, ...) must agree; the type parameter may or may not
    # be module-qualified depending on what's in scope, so check key content.
    @test repr(cc) == sprint(show, cc)
    @test occursin("CostCurve", repr(cc))
    @test occursin("QuadraticCurve(1.0, 2.0, 3.0)", repr(cc))
    @test occursin("LinearCurve(0.0, 0.0)", repr(cc))
    @test repr(fc) == sprint(show, fc)
    @test occursin("FuelCurve", repr(fc))
    @test occursin("QuadraticCurve(1.0, 2.0, 3.0)", repr(fc))
    @test occursin("4.0", repr(fc))
    @test sprint(show, "text/plain", cc) ==
          sprint(show, "text/plain", cc; context = :compact => false) ==
          "CostCurve:\n  value_curve: QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0\n  vom_cost: LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 0.0 x + 0.0"
    @test sprint(show, "text/plain", fc) ==
          sprint(show, "text/plain", fc; context = :compact => false) ==
          "FuelCurve:\n  value_curve: QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0\n  fuel_cost: 4.0\n  fuel_cost_time_series: nothing\n  startup_fuel_offtake: LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 0.0 x + 0.0\n  vom_cost: LinearCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 0.0 x + 0.0"
    @test sprint(show, "text/plain", cc; context = :compact => true) ==
          "CostCurve with vom_cost LinearCurve(0.0, 0.0), and value_curve:\n  QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0"
    @test sprint(show, "text/plain", fc; context = :compact => true) ==
          "FuelCurve with fuel_cost 4.0, fuel_cost_time_series nothing, startup_fuel_offtake LinearCurve(0.0, 0.0), vom_cost LinearCurve(0.0, 0.0), and value_curve:\n  QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0"

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
    # A key names one stored series, so its element type is fixed: a
    # `TimeSeriesFunctionData{T}` can only wrap a key of `T` values.
    quad_key = IS.TimeSeriesKey{IS.Deterministic{IS.QuadraticFunctionData}}(1)
    # A fuel cost varies as a plain scalar over time, not as function data.
    forecast_key = IS.TimeSeriesKey{IS.Deterministic{Float64}}(1)

    # Scalar dispatches
    @test IS.is_time_series_backed(forecast_key) == true
    @test IS.is_time_series_backed(nothing) == false

    static_vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1, 2, 3))
    ts_vc = IS.TimeSeriesInputOutputCurve(IS.TimeSeriesQuadraticFunctionData(quad_key))

    # CostCurve: only time-series-backed when its value curve is
    @test IS.is_time_series_backed(IS.CostCurve(static_vc)) == false
    @test IS.is_time_series_backed(IS.CostCurve(ts_vc)) == true

    # FuelCurve 2x2: fuel_cost ∈ {Float64, TimeSeriesKey} × value_curve ∈ {static, time-varying}
    @test IS.is_time_series_backed(IS.FuelCurve(static_vc, 4.0)) == false
    @test IS.is_time_series_backed(IS.FuelCurve(ts_vc, 4.0)) == true
    @test IS.is_time_series_backed(IS.FuelCurve(static_vc, forecast_key)) == true
    @test IS.is_time_series_backed(IS.FuelCurve(ts_vc, forecast_key)) == true

    # CostCurve with TS value curve → returns the value-curve key
    @test IS.get_time_series_key(IS.CostCurve(ts_vc)) ===
          IS.get_time_series_key(ts_vc)

    # get_time_series_key is intentionally undefined for FuelCurve (its value curve and
    # fuel_cost are independently TS-backed). Callers resolve explicitly via
    # get_time_series_key(get_value_curve(c)) or get_fuel_cost(c); the accessor itself
    # throws an ArgumentError for every FuelCurve combination.
    @test_throws ArgumentError IS.get_time_series_key(IS.FuelCurve(ts_vc, 4.0))
    @test_throws ArgumentError IS.get_time_series_key(
        IS.FuelCurve(static_vc, forecast_key),
    )
    @test_throws ArgumentError IS.get_time_series_key(IS.FuelCurve(ts_vc, forecast_key))
end

@testset "get_time_series_key fallback for non-TS-backed curves (PVC-E)" begin
    # Previously CostCurve gave a bare MethodError; now a clear ArgumentError
    @test_throws ArgumentError IS.get_time_series_key(IS.CostCurve(IS.LinearCurve(5.0)))
    # FuelCurve static value_curve + Float64 fuel_cost — previously also a MethodError
    @test_throws ArgumentError IS.get_time_series_key(
        IS.FuelCurve(IS.LinearCurve(5.0), 4.0),
    )
end

@testset "FuelCurve fuel_cost / fuel_cost_time_series are mutually exclusive" begin
    vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1.0, 2.0, 3.0))
    sys, (key,) = create_forecast_key_fixture("fuel_price")

    # Float form
    fc_float = IS.FuelCurve(vc, 3.0)
    @test IS.get_fuel_cost(fc_float) == 3.0
    @test IS.get_fuel_cost_time_series(fc_float) === nothing
    @test IS.is_time_series_backed(fc_float) == false

    # Time-series form
    fc_ts = IS.FuelCurve(vc, key)
    @test IS.get_fuel_cost(fc_ts) === nothing
    @test IS.get_fuel_cost_time_series(fc_ts) == key
    @test IS.is_time_series_backed(fc_ts) == true

    # Both set: rejected by the inner constructor
    @test_throws ArgumentError IS.FuelCurve(;
        value_curve = vc,
        fuel_cost = 3.0,
        fuel_cost_time_series = key,
    )

    # A scalar field takes a closed union of concrete key types, so it is stored
    # inline rather than boxed. A key naming anything the field cannot resolve to
    # one Float64 per timestep is refused where it is set, with a message that
    # says what the field is for — not where it would be read.
    for wrong in (
        IS.TimeSeriesKey{IS.Probabilistic{Float64}}(1),
        IS.TimeSeriesKey{IS.SingleTimeSeries{Float32}}(1),
        IS.TimeSeriesKey{IS.SingleTimeSeries{IS.PiecewiseStepData}}(1),
    )
        err = try
            IS.FuelCurve(vc, wrong)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("scalar time series field", sprint(showerror, err))
    end
    @test isconcretetype(typeof(IS.get_fuel_cost_time_series(fc_ts)))

    # Neither set: rejected by the inner constructor
    @test_throws ArgumentError IS.FuelCurve(; value_curve = vc)

    # Serialization round-trip of the float form
    @test IS.deserialize(IS.FuelCurve, IS.serialize(fc_float)) == fc_float

    # The key-form round trip resolves the serialized association id against the store
    # that minted it.
    fc_ts_rt = IS.deserialize(IS.FuelCurve, IS.serialize(fc_ts))
    @test IS.compare_values(fc_ts_rt, fc_ts)
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

@testset "cost curve legacy power_units key" begin
    # Data written while cost curves carried a unit system has a "power_units" key.
    # "NaturalUnit" is what every cost curve now is, so it loads; anything else throws.
    vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1.0, 2.0, 3.0))
    for (T, curve) in
        ((IS.CostCurve, IS.CostCurve(vc)), (IS.FuelCurve, IS.FuelCurve(vc, 5.0)))
        data = IS.serialize(curve)
        @test IS.deserialize(T, merge(data, Dict("power_units" => "NaturalUnit"))) == curve
        for bad in ("SystemBaseUnit", "ComponentBaseUnit", "bogus")
            @test_throws ArgumentError IS.deserialize(
                T,
                merge(data, Dict("power_units" => bad)),
            )
        end
    end
end

@testset "unit-system string decode" begin
    @test IS._unit_system_instance("SystemBaseUnit") == IS.SystemBaseUnit()
    @test IS._unit_system_instance("ComponentBaseUnit") == IS.ComponentBaseUnit()
    @test IS._unit_system_instance("NaturalUnit") == IS.NaturalUnit()
    @test_throws ArgumentError IS._unit_system_instance("bogus")
    # Legacy IS3 `UnitSystem` enum value-names are no longer accepted.
    @test_throws ArgumentError IS._unit_system_instance("SYSTEM_BASE")
    @test_throws ArgumentError IS._unit_system_instance("NATURAL_UNITS")
end

@testset "hash distinguishes unit systems and curve types" begin
    vc = IS.InputOutputCurve(IS.LinearFunctionData(1.0, 1.0))
    # The unit system lives in a type parameter, not a field, so a field-only hash
    # would collide across unit systems
    curves = [
        IS.LossCurve(vc, U)
        for U in (IS.NaturalUnit(), IS.SystemBaseUnit(), IS.ComponentBaseUnit())
    ]
    @test length(unique(hash.(curves))) == length(curves)
    # Same unit system still satisfies the isequal => hash contract, including the
    # NaN case where isequal and == deliberately diverge
    for fd in (IS.LinearFunctionData(1.0, 1.0), IS.LinearFunctionData(NaN, 1.0))
        a = IS.CostCurve(IS.InputOutputCurve(fd))
        b = IS.CostCurve(IS.InputOutputCurve(fd))
        @test isequal(a, b)
        @test hash(a) == hash(b)
    end
    # Distinct types with identical fields must not collide either
    @test hash(IS.CostCurve(vc)) != hash(IS.FuelCurve(vc, 1.0))
    @test hash(IS.IncrementalCurve(IS.LinearFunctionData(1.0, 1.0), 1.0)) !=
          hash(IS.AverageRateCurve(IS.LinearFunctionData(1.0, 1.0), 1.0))
end

@testset "Test IS.LossCurve" begin
    vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1.0, 2.0, 3.0))
    lc = IS.LossCurve(vc, IS.NaturalUnit())

    @test lc isa IS.LossCurve{IS.QuadraticCurve, IS.NaturalUnit}
    @test IS.get_value_curve(lc) == vc
    @test IS.get_function_data(lc) == IS.QuadraticFunctionData(1.0, 2.0, 3.0)
    @test IS.get_power_units(lc) == IS.NaturalUnit()
    @test lc == IS.LossCurve(vc, IS.NaturalUnit())
    @test isequal(lc, IS.LossCurve(vc, IS.NaturalUnit()))
    @test hash(lc) == hash(IS.LossCurve(vc, IS.NaturalUnit()))

    # `power_units` is a type parameter, so curves that differ only in units are distinct
    @test IS.LossCurve(vc, IS.SystemBaseUnit()) != lc

    @test IS.LossCurve(vc, IS.SystemBaseUnit()) ==
          IS.LossCurve(; value_curve = vc, power_units = IS.SystemBaseUnit())

    @test sprint(show, "text/plain", lc) ==
          "LossCurve:\n  value_curve: QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0\n  power_units: NU"
    @test sprint(show, "text/plain", lc; context = :compact => true) ==
          "LossCurve with power_units NU, and value_curve:\n  QuadraticCurve (a type of InfrastructureSystems.InputOutputCurve) where function is: f(x) = 1.0 x^2 + 2.0 x + 3.0"
end

@testset "LossCurve requires explicit power_units" begin
    # An unstated base is the ambiguity the type exists to remove, so there is no default
    # and no `zero(::Type{LossCurve})` to smuggle one in.
    vc = IS.InputOutputCurve(IS.LinearFunctionData(1.0, 1.0))
    @test_throws MethodError IS.LossCurve(vc)
    @test_throws Union{MethodError, UndefKeywordError} IS.LossCurve(; value_curve = vc)
    @test_throws MethodError zero(IS.LossCurve)
    # ...but a curve that already has a base can hand it to its own zero
    for U in (IS.NaturalUnit(), IS.SystemBaseUnit(), IS.ComponentBaseUnit())
        @test IS.get_power_units(zero(IS.LossCurve(vc, U))) == U
    end
end

@testset "LossCurve serialize round-trip all unit systems" begin
    vc = IS.InputOutputCurve(IS.LinearFunctionData(1.5, 0.25))
    for U in (IS.NaturalUnit(), IS.SystemBaseUnit(), IS.ComponentBaseUnit())
        lc = IS.LossCurve(vc, U)
        data = IS.serialize(lc)
        @test data["power_units"] == string(nameof(typeof(U)))
        lc_rt = IS.deserialize(IS.LossCurve, data)
        @test lc_rt == lc
        @test IS.get_power_units(lc_rt) == U
    end
end

@testset "y_axis_power_dimension trait" begin
    # How many powers of the base the y-axis carries: a loss is power, like its x-axis.
    @test IS.y_axis_power_dimension(IS.LossCurve{IS.LinearCurve, IS.NaturalUnit}) == Val(1)
end

# `convert_power_units` takes the x-axis ratio between two bases; `PowerSystems` derives it
# per component, so these tests spell it out. Writing `x_U = P / base_U` (with `base_NU`
# = 1, i.e. P already in MW) gives `x_from = (base_to / base_from) * x_to`.
_x_base(::IS.NaturalUnit, _, _) = 1.0
_x_base(::IS.SystemBaseUnit, sb, _) = sb
_x_base(::IS.ComponentBaseUnit, _, db) = db

_convert(curve, to, sb, db) = IS.convert_power_units(
    curve,
    to,
    _x_base(to, sb, db) / _x_base(IS.get_power_units(curve), sb, db),
)

@testset "LossCurve convert_power_units" begin
    sys_base, dev_base = 100.0, 50.0

    # y = 0.05 x + 2.0: 5% marginal loss plus 2 MW of fixed loss.
    lc = IS.LossCurve(IS.LinearCurve(0.05, 2.0), IS.NaturalUnit())

    su = _convert(lc, IS.SystemBaseUnit(), sys_base, dev_base)
    @test su isa IS.LossCurve{IS.LinearCurve, IS.SystemBaseUnit}
    # Both axes are power, so the proportional term is dimensionless and does not move;
    # only the constant term, which is a bare power, rescales.
    @test IS.get_function_data(su) == IS.LinearFunctionData(0.05, 2.0 / sys_base)

    du = _convert(lc, IS.ComponentBaseUnit(), sys_base, dev_base)
    @test IS.get_function_data(du) == IS.LinearFunctionData(0.05, 2.0 / dev_base)

    # SU <-> CU directly, and every round trip
    @test _convert(su, IS.ComponentBaseUnit(), sys_base, dev_base) == du
    for U in (IS.NaturalUnit(), IS.SystemBaseUnit(), IS.ComponentBaseUnit()),
        V in (IS.NaturalUnit(), IS.SystemBaseUnit(), IS.ComponentBaseUnit())

        start = _convert(lc, U, sys_base, dev_base)
        there = _convert(start, V, sys_base, dev_base)
        @test _convert(there, U, sys_base, dev_base) == start
    end

    # Converting to the base the curve already carries is the identity, not a rebuild
    @test _convert(lc, IS.NaturalUnit(), sys_base, dev_base) === lc

    # The converted curve agrees pointwise with the original: the same physical loss,
    # read off in the new base.
    f = IS.get_value_curve(lc)
    f_su = IS.get_value_curve(su)
    for x_mw in (0.0, 10.0, 55.0, 100.0)
        @test f_su(x_mw / sys_base) ≈ f(x_mw) / sys_base
    end

    # A quadratic loss curve: the quadratic term picks up one net power of the base.
    qc = IS.LossCurve(IS.QuadraticCurve(0.01, 0.05, 2.0), IS.NaturalUnit())
    q_su = _convert(qc, IS.SystemBaseUnit(), sys_base, dev_base)
    @test IS.get_function_data(q_su) ==
          IS.QuadraticFunctionData(0.01 * sys_base, 0.05, 2.0 / sys_base)

    # A piecewise loss curve: breakpoints are power and move; segment slopes do not.
    pw = IS.LossCurve(
        IS.PiecewiseIncrementalCurve(0.0, [0.0, 50.0, 100.0], [0.03, 0.06]),
        IS.NaturalUnit(),
    )
    pw_su = _convert(pw, IS.SystemBaseUnit(), sys_base, dev_base)
    fd = IS.get_function_data(pw_su)
    @test IS.get_x_coords(fd) == [0.0, 0.5, 1.0]
    @test IS.get_y_coords(fd) == [0.03, 0.06]
    @test IS.get_initial_input(pw_su) == 0.0

    # Time-series-backed curves have no data to rescale
    forecast_key = IS.TimeSeriesKey{IS.Deterministic{IS.LinearFunctionData}}(1)
    ts_vc = IS.TimeSeriesInputOutputCurve(IS.TimeSeriesLinearFunctionData(forecast_key))
    @test_throws ArgumentError _convert(
        IS.LossCurve(ts_vc, IS.NaturalUnit()), IS.SystemBaseUnit(), sys_base, dev_base)
end

@testset "convert_power_units resolves at compile time" begin
    # The design requirement: the y-axis dimension is a `Val`, so the exponent is
    # dispatched, not tested at run time, and the arithmetic folds to multiplies and
    # divides -- never a call to `^`.
    sys_base, dev_base = 100.0, 50.0
    curves = (
        IS.LossCurve(IS.LinearCurve(0.05, 2.0), IS.NaturalUnit()),
        IS.LossCurve(IS.QuadraticCurve(0.01, 0.05, 2.0), IS.NaturalUnit()),
    )
    for curve in curves
        T = typeof(curve)
        # Fully inferred, to a concrete type carrying the target unit system
        @test isconcretetype(
            Base.promote_op(IS.convert_power_units, T, IS.SystemBaseUnit, Float64),
        )
        @test (@inferred IS.convert_power_units(
            curve, IS.SystemBaseUnit(), 2.0,
        )) isa IS.LossCurve

        # No runtime power call and no dynamic dispatch survive optimization
        src, _ = only(
            code_typed(
                IS.convert_power_units, (T, IS.SystemBaseUnit, Float64);
                optimize = true,
            ),
        )
        ir = string(src.code)
        @test !occursin("power_by_squaring", ir)
        @test !occursin("jl_apply_generic", ir)
    end
end

@testset "FuelCurve deserialize garbage fuel_cost (PVC-003)" begin
    fc_example = IS.FuelCurve(IS.InputOutputCurve(IS.LinearFunctionData(1.0, 0.0)), 2.5)
    bad_dict = merge(IS.serialize(fc_example), Dict("fuel_cost" => "oops"))
    @test_throws ArgumentError IS.deserialize(IS.FuelCurve, bad_dict)
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

# Helpers for the scaling / unit-conversion testsets below. `FunctionData` has no
# `isapprox`, so compare the defining terms elementwise.
_fd_terms(fd::IS.LinearFunctionData) =
    [IS.get_proportional_term(fd), IS.get_constant_term(fd)]
_fd_terms(fd::IS.QuadraticFunctionData) =
    [IS.get_quadratic_term(fd), IS.get_proportional_term(fd), IS.get_constant_term(fd)]
_fd_terms(fd::Union{IS.PiecewiseLinearData, IS.PiecewiseStepData}) =
    vcat(IS.get_x_coords(fd), IS.get_y_coords(fd))

fd_approx(a::T, b::T) where {T <: IS.FunctionData} =
    all(isapprox.(_fd_terms(a), _fd_terms(b)))
fd_approx(::IS.FunctionData, ::IS.FunctionData) = false  # differing shapes never match

function ts_input_output_curve()
    key = IS.TimeSeriesKey{IS.Deterministic{IS.QuadraticFunctionData}}(1)
    return IS.TimeSeriesInputOutputCurve(IS.TimeSeriesQuadraticFunctionData(key))
end

@testset "ValueCurve scaling (scale_x, scale_y)" begin
    ratio = 4.0
    # scale_x is defined on the input-output function a curve represents, so it must
    # commute with conversion to InputOutputCurve for every representation.
    for curve in (
        IS.IncrementalCurve(IS.LinearFunctionData(4, 6), 4.0),
        IS.AverageRateCurve(IS.LinearFunctionData(2, 3), 4.0),
        IS.IncrementalCurve(IS.PiecewiseStepData([1, 2, 4], [10, 20]), 5.0),
        IS.AverageRateCurve(IS.PiecewiseStepData([1, 2, 4], [10, 20]), 5.0),
    )
        via_scale = IS.InputOutputCurve(IS.scale_x(curve, ratio))
        via_convert = IS.scale_x(IS.InputOutputCurve(curve), ratio)
        @test fd_approx(IS.get_function_data(via_scale), IS.get_function_data(via_convert))
    end

    # An InputOutputCurve evaluates as f(c * x)
    io = IS.InputOutputCurve(IS.QuadraticFunctionData(2, 3, 4))
    io_scaled = IS.scale_x(io, ratio)
    for x in (0.5, 1.0, 2.0)
        @test io_scaled(x) ≈ io(ratio * x)
    end
    @test IS.scale_x(io, 1.0) == io

    # Piecewise input-output data keeps its y-coordinates; only x moves
    pw_io = IS.InputOutputCurve(IS.PiecewiseLinearData([(1, 1), (3, 5), (5, 10)]))
    pw_io_scaled = IS.scale_x(pw_io, ratio)
    @test IS.get_x_coords(IS.get_function_data(pw_io_scaled)) ≈ [0.25, 0.75, 1.25]
    @test IS.get_y_coords(IS.get_function_data(pw_io_scaled)) ==
          IS.get_y_coords(IS.get_function_data(pw_io))

    # Vertical scaling also scales initial_input and input_at_zero, and skips `nothing`
    inc = IS.IncrementalCurve(IS.LinearFunctionData(4, 6), 4.0, 2.0)
    inc_scaled = 3.0 * inc
    @test IS.get_initial_input(inc_scaled) == 12.0
    @test IS.get_input_at_zero(inc_scaled) == 6.0
    @test IS.get_function_data(inc_scaled) == 3.0 * IS.get_function_data(inc)
    @test inc * 3.0 == inc_scaled
    @test IS.scale_y(inc, 3.0) == inc_scaled
    @test IS.get_input_at_zero(2.0 * IS.InputOutputCurve(IS.LinearFunctionData(1, 1))) ===
          nothing
    @test IS.get_initial_input(
        2.0 * IS.IncrementalCurve(IS.LinearFunctionData(1, 1),
            nothing),
    ) === nothing

    # Time-series-backed curves have no data to scale
    ts_vc = ts_input_output_curve()
    @test_throws ArgumentError IS.scale_x(ts_vc, 2.0)
    @test_throws ArgumentError 2.0 * ts_vc
end

@testset "cost curves have no convert_power_units" begin
    # Cost curves are always natural units; only LossCurve changes base.
    @test !hasmethod(
        IS.convert_power_units,
        Tuple{IS.CostCurve{IS.LinearCurve}, IS.SystemBaseUnit, Float64},
    )
    @test !hasmethod(
        IS.convert_power_units,
        Tuple{IS.FuelCurve{IS.LinearCurve}, IS.SystemBaseUnit, Float64},
    )
end

@testset "CostCurve from FuelCurve" begin
    # Multiplying through by a scalar fuel cost gives the equivalent CostCurve
    fc = IS.FuelCurve(IS.QuadraticCurve(2.0, 3.0, 4.0), 12.5, IS.LinearCurve(0.0),
        IS.LinearCurve(7.0))
    cc = IS.CostCurve(fc)
    @test cc isa IS.CostCurve
    for mw in (10.0, 55.0)
        @test IS.get_value_curve(cc)(mw) ≈ 12.5 * IS.get_value_curve(fc)(mw)
    end
    # vom_cost is already in currency, so it carries over untouched
    @test IS.get_vom_cost(cc) == IS.get_vom_cost(fc)

    # Incremental representation: initial_input scales with the rest of the curve
    inc = IS.FuelCurve(IS.PiecewiseIncrementalCurve(1.0, [1.0, 2.0, 4.0], [10.0, 20.0]),
        3.0)
    inc_cc = IS.CostCurve(inc)
    @test IS.get_initial_input(inc_cc) == 3.0
    @test IS.get_y_coords(IS.get_function_data(inc_cc)) == [30.0, 60.0]

    # Nonzero startup_fuel_offtake cannot be represented and must not vanish silently
    @test_throws ArgumentError IS.CostCurve(
        IS.FuelCurve(IS.LinearCurve(5.0), 2.0, IS.LinearCurve(1.0), IS.LinearCurve(0.0)),
    )
    @test_throws ArgumentError IS.CostCurve(
        IS.FuelCurve(IS.LinearCurve(5.0), 2.0, IS.LinearCurve(0.0, 1.0),
            IS.LinearCurve(0.0)),
    )

    # A time-series-backed fuel cost is not a scalar. The key must be a valid scalar key,
    # so the FuelCurve itself constructs and the conversion is what refuses it.
    fc_ts =
        IS.FuelCurve(IS.LinearCurve(5.0), IS.TimeSeriesKey{IS.Deterministic{Float64}}(1))
    @test_throws ArgumentError IS.CostCurve(fc_ts)
end

@testset "cost curve power_units bridge" begin
    # Short-lived bridge: NaturalUnit is accepted with a deprecation warning, any other
    # unit system throws. `@test_deprecated` checks the warning when depwarn is on.
    vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1.0, 2.0, 3.0))
    vom = IS.LinearCurve(7.0)
    startup = IS.LinearCurve(2.0)
    cc = IS.CostCurve(vc)
    cc_vom = IS.CostCurve(vc, vom)
    fc = IS.FuelCurve(vc, 4.0)
    fc_full = IS.FuelCurve(vc, 4.0, startup, vom)

    @test (@test_deprecated IS.CostCurve(vc, IS.NU)) == cc
    @test (@test_deprecated IS.CostCurve(vc, IS.NU, vom)) == cc_vom
    @test (@test_deprecated IS.CostCurve(; value_curve = vc, power_units = IS.NU)) == cc
    @test (@test_deprecated IS.FuelCurve(vc, IS.NU, 4.0)) == fc
    @test (@test_deprecated IS.FuelCurve(vc, IS.NU, 4.0, startup, vom)) == fc_full
    @test (@test_deprecated IS.FuelCurve(;
        value_curve = vc,
        fuel_cost = 4.0,
        power_units = IS.NU,
    )) == fc
    # get_power_units warns once per session; reset so each call warns.
    IS._POWER_UNITS_DEPWARNED[] = false
    @test (@test_deprecated IS.get_power_units(cc)) === IS.NU
    IS._POWER_UNITS_DEPWARNED[] = false
    @test (@test_deprecated IS.get_power_units(fc)) === IS.NU
    @test (@test_logs min_level = Logging.Warn IS.get_power_units(cc)) === IS.NU
    @test (@inferred IS.get_power_units(cc)) === IS.NU

    for U in (IS.SU, IS.CU)
        @test_throws ArgumentError IS.CostCurve(vc, U)
        @test_throws ArgumentError IS.CostCurve(vc, U, vom)
        @test_throws ArgumentError IS.CostCurve(; value_curve = vc, power_units = U)
        @test_throws ArgumentError IS.FuelCurve(vc, U, 4.0)
        @test_throws ArgumentError IS.FuelCurve(vc, U, 4.0, startup, vom)
        @test_throws ArgumentError IS.FuelCurve(;
            value_curve = vc,
            fuel_cost = 4.0,
            power_units = U,
        )
    end
end

@testset "ValueCurveWrapper is the unit-free parent of cost and loss curves" begin
    vc = IS.InputOutputCurve(IS.QuadraticFunctionData(1.0, 2.0, 3.0))
    cc = IS.CostCurve(vc)
    fc = IS.FuelCurve(vc, 4.0)
    lc = IS.LossCurve(vc, IS.SU)

    # Cost curves carry no unit system; loss curves do
    @test cc isa IS.ValueCurveWrapper{typeof(vc)}
    @test fc isa IS.ValueCurveWrapper{typeof(vc)}
    @test lc isa IS.ValueCurveWrapper{typeof(vc)}
    @test !(cc isa IS.ValueCurveWithUnits)
    @test !(fc isa IS.ValueCurveWithUnits)
    @test lc isa IS.ValueCurveWithUnits{typeof(vc), IS.SystemBaseUnit}
    @test length(typeof(cc).parameters) == 1
    @test length(typeof(fc).parameters) == 1

    # Shared read-only methods work the same across both families
    for curve in (cc, fc, lc)
        @test IS.get_value_curve(curve) == vc
        @test IS.get_function_data(curve) == IS.QuadraticFunctionData(1.0, 2.0, 3.0)
        @test IS.is_convex(curve)
        @test !IS.is_concave(curve)
        @test !IS.is_time_series_backed(curve)
        @test_throws ArgumentError IS.get_time_series_key(curve)
        @test curve == deepcopy(curve)
        @test isequal(curve, deepcopy(curve))
        @test hash(curve) == hash(deepcopy(curve))
    end
    inc = IS.PiecewiseIncrementalCurve(1.5, [0.0, 1.0, 2.0], [3.0, 4.0])
    for curve in (IS.CostCurve(inc), IS.FuelCurve(inc, 1.0), IS.LossCurve(inc, IS.NU))
        @test IS.get_initial_input(curve) == 1.5
    end

    # The time-series key accessor is shared by CostCurve and LossCurve
    key = IS.TimeSeriesKey{IS.Deterministic{IS.QuadraticFunctionData}}(1)
    ts_vc = IS.TimeSeriesInputOutputCurve(IS.TimeSeriesQuadraticFunctionData(key))
    for curve in (IS.CostCurve(ts_vc), IS.LossCurve(ts_vc, IS.NU))
        @test IS.is_time_series_backed(curve)
        @test IS.get_time_series_key(curve) === IS.get_time_series_key(ts_vc)
    end

    # Only the unit-carrying family prints and serializes power_units
    @test !occursin("power_units", sprint(show, "text/plain", cc))
    @test !occursin("power_units", sprint(show, "text/plain", fc))
    @test occursin("power_units: SU", sprint(show, "text/plain", lc))
    @test IS.serialize(lc)["power_units"] == "SystemBaseUnit"
    @test IS.deserialize(IS.LossCurve, IS.serialize(lc)) == lc
end
