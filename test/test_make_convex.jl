@testset "increasing_curve_convex_approximation Tests" begin
    @testset "Test increasing_curve_convex_approximation for InputOutputCurve{PiecewiseLinearData}" begin
        # Convex (non-decreasing slopes) - unchanged
        pld_convex = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1.0),
            (x = 2.0, y = 3.0),
        ])
        ppc_convex = IS.InputOutputCurve(pld_convex)
        result = IS.increasing_curve_convex_approximation(ppc_convex)
        @test IS.is_convex(result)
        @test result === ppc_convex

        # Concave (decreasing slopes) - apply isotonic regression
        pld_concave = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 2.0),
            (x = 2.0, y = 3.0),
        ])
        ppc_concave = IS.InputOutputCurve(pld_concave)
        result = IS.increasing_curve_convex_approximation(ppc_concave)
        @test IS.is_convex(result)
        # With merge_colinear=true (default), equal slopes get merged into single segment
        # With merge_colinear=false, slopes should be equal (both 1.5)
        result_no_merge =
            IS.increasing_curve_convex_approximation(ppc_concave; merge_colinear = false)
        slopes = IS.get_slopes(IS.get_function_data(result_no_merge))
        @test slopes[1] ≤ slopes[2]
    end

    @testset "Test increasing_curve_convex_approximation for IncrementalCurve{PiecewiseStepData}" begin
        # Convex (non-decreasing y-coords) - unchanged
        psd_convex = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0])
        pic_convex = IS.IncrementalCurve(psd_convex, 0.0)
        result = IS.increasing_curve_convex_approximation(pic_convex)
        @test IS.is_convex(result)
        @test result == pic_convex

        # Concave (decreasing y-coords) - apply isotonic regression
        psd_concave = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [3.0, 2.0, 1.0])
        pic_concave = IS.IncrementalCurve(psd_concave, 0.0)
        result = IS.increasing_curve_convex_approximation(pic_concave)
        @test IS.is_convex(result)
        # With merge_colinear=true (default), equal y-values get merged
        # With merge_colinear=false, y-coords should be equal (all 2.0)
        result_no_merge =
            IS.increasing_curve_convex_approximation(pic_concave; merge_colinear = false)
        @test IS.get_y_coords(IS.get_function_data(result_no_merge)) ≈ [2.0, 2.0, 2.0]
    end

    @testset "Test increasing_curve_convex_approximation for AverageRateCurve{PiecewiseStepData}" begin
        # AverageRateCurve{PiecewiseStepData} - increasing
        psd = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0])
        arc_psd = IS.AverageRateCurve(psd, 0.0)
        result = IS.increasing_curve_convex_approximation(arc_psd)
        @test IS.is_convex(result)
    end

    @testset "Test merge_colinear before and after convexification" begin
        # Create a non-convex curve with colinear segments that would affect weighting
        # Slopes: [1.0, 1.0, 3.0, 2.0] - first two are colinear, last two are concave
        pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1.0),   # slope 1.0
            (x = 2.0, y = 2.0),   # slope 1.0 (colinear with previous)
            (x = 3.0, y = 5.0),   # slope 3.0
            (x = 4.0, y = 7.0),   # slope 2.0 (non-convex: 3.0 > 2.0)
        ])
        ioc = IS.InputOutputCurve(pld)
        @test !IS.is_convex(ioc)

        # With merge_colinear=true (default), colinear segments are merged first
        result = IS.increasing_curve_convex_approximation(ioc)
        @test IS.is_convex(result)
        # The result should have fewer points due to merging
        result_points = IS.get_points(IS.get_function_data(result))
        @test length(result_points) < 5  # Less than original 5 points

        # With merge_colinear=false, all original segments are preserved (except for isotonic pooling)
        result_no_merge =
            IS.increasing_curve_convex_approximation(ioc; merge_colinear = false)
        @test IS.is_convex(result_no_merge)
        result_no_merge_points = IS.get_points(IS.get_function_data(result_no_merge))
        @test length(result_no_merge_points) == 5  # All 5 points preserved
    end

    @testset "Test is_convex for ValueCurves with integration" begin
        # Test that IncrementalCurve performs integration for convexity check
        psd = IS.PiecewiseStepData([0.0, 1.0, 2.0], [3.0, 5.0])
        inc = IS.IncrementalCurve(psd, 10.0, 0.0)
        @test IS.is_convex(inc)

        # Verify integration happens correctly
        ioc = IS.InputOutputCurve(inc)
        pld = IS.get_function_data(ioc)
        points = IS.get_points(pld)
        @test points[1].y == 10.0
        @test points[2].y ≈ 13.0  # 10 + 3*1
        @test points[3].y ≈ 18.0  # 13 + 5*1

        # Test concave incremental curve
        psd_concave = IS.PiecewiseStepData([0.0, 1.0, 2.0], [5.0, 3.0])
        inc_concave = IS.IncrementalCurve(psd_concave, 0.0, 0.0)
        @test !IS.is_convex(inc_concave)

        # Test increasing_curve_convex_approximation on concave curve
        result = IS.increasing_curve_convex_approximation(inc_concave)
        @test IS.is_convex(result)
    end

    @testset "Test increasing_curve_convex_approximation idempotency" begin
        # increasing_curve_convex_approximation(increasing_curve_convex_approximation(x)) should equal increasing_curve_convex_approximation(x)
        psd = IS.PiecewiseStepData([0.0, 1.0, 2.0], [3.0, 1.0])  # concave
        ic = IS.IncrementalCurve(psd, 0.0)
        convex_once = IS.increasing_curve_convex_approximation(ic)
        convex_twice = IS.increasing_curve_convex_approximation(convex_once)

        @test IS.get_y_coords(IS.get_function_data(convex_once)) ==
              IS.get_y_coords(IS.get_function_data(convex_twice))
        @test IS.is_convex(convex_once)
        @test IS.is_convex(convex_twice)
        @test convex_twice == convex_once  # Should return equivalent object
    end

    @testset "Test increasing_curve_convex_approximation anchor options for PiecewiseLinearData" begin
        # Concave curve with slopes [2.0, 1.0]
        pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 2.0),
            (x = 2.0, y = 3.0),
        ])
        ioc = IS.InputOutputCurve(pld)

        # Test anchor=:first (default) - preserves first point
        result_first = IS.increasing_curve_convex_approximation(ioc; anchor = :first)
        points_first = IS.get_points(IS.get_function_data(result_first))
        @test points_first[1] == (x = 0.0, y = 0.0)  # First point preserved

        # Test anchor=:last - preserves last point
        result_last = IS.increasing_curve_convex_approximation(ioc; anchor = :last)
        points_last = IS.get_points(IS.get_function_data(result_last))
        @test points_last[end] == (x = 2.0, y = 3.0)  # Last point preserved
    end

    @testset "Test increasing_curve_convex_approximation throws error for non-strictly-increasing curves" begin
        # Use NullLogger to suppress expected @error logs from is_valid_data()
        Logging.with_logger(Logging.NullLogger()) do
            # Curve with a negative slope segment (not strictly increasing)
            pld_neg = IS.PiecewiseLinearData([
                (x = 0.0, y = 10.0),
                (x = 1.0, y = 5.0),   # slope = -5 (decreasing)
                (x = 2.0, y = 8.0),
            ])
            ioc_neg = IS.InputOutputCurve(pld_neg)
            @test !IS.is_strictly_increasing(ioc_neg)

            # Should throw an error
            @test_throws ErrorException IS.increasing_curve_convex_approximation(ioc_neg)

            # Same test with IncrementalCurve
            psd_neg = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-1.0, 2.0])
            pic_neg = IS.IncrementalCurve(psd_neg, 0.0)
            @test !IS.is_strictly_increasing(pic_neg)

            @test_throws ErrorException IS.increasing_curve_convex_approximation(pic_neg)
        end
    end

    @testset "Test increasing_curve_convex_approximation device_name parameter" begin
        # Non-convex curve that will be convexified
        pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 10.0),  # slope = 10
            (x = 2.0, y = 15.0),  # slope = 5 (non-convex)
        ])
        ioc = IS.InputOutputCurve(pld)

        # Test that device_name parameter is accepted and function works
        result_with_name = IS.increasing_curve_convex_approximation(
            ioc;
            device_name = "TestGen123",
        )
        @test IS.is_convex(result_with_name)

        # Without device_name also works
        result_no_name = IS.increasing_curve_convex_approximation(ioc)
        @test IS.is_convex(result_no_name)
    end

    @testset "Test increasing_curve_convex_approximation for CostCurve" begin
        # Convex CostCurve - should return unchanged
        pld_convex = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1.0),
            (x = 2.0, y = 3.0),
        ])
        ioc_convex = IS.InputOutputCurve(pld_convex)
        vom_cost = IS.LinearCurve(0.5)
        cost_curve_convex = IS.CostCurve(;
            value_curve = ioc_convex,
            power_units = IS.NaturalUnit(),
            vom_cost = vom_cost,
        )

        result = IS.increasing_curve_convex_approximation(cost_curve_convex)
        @test result isa IS.CostCurve
        @test IS.is_convex(result)
        @test IS.get_power_units(result) == IS.NaturalUnit()
        @test IS.get_vom_cost(result) == vom_cost

        # Non-convex CostCurve - should be convexified
        pld_concave = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 2.0),  # slope = 2
            (x = 2.0, y = 3.0),  # slope = 1 (non-convex)
        ])
        ioc_concave = IS.InputOutputCurve(pld_concave)
        vom_cost_2 = IS.LinearCurve(1.0)
        cost_curve_concave = IS.CostCurve(;
            value_curve = ioc_concave,
            power_units = IS.SystemBaseUnit(),
            vom_cost = vom_cost_2,
        )

        result_concave = IS.increasing_curve_convex_approximation(cost_curve_concave)
        @test result_concave isa IS.CostCurve
        @test IS.is_convex(result_concave)
        @test IS.get_power_units(result_concave) == IS.SystemBaseUnit()
        @test IS.get_vom_cost(result_concave) == vom_cost_2

        # Invalid CostCurve (not strictly increasing) - should throw error
        # Use NullLogger to suppress expected @error logs from is_valid_data()
        Logging.with_logger(Logging.NullLogger()) do
            pld_invalid = IS.PiecewiseLinearData([
                (x = 0.0, y = 10.0),
                (x = 1.0, y = 5.0),   # decreasing
                (x = 2.0, y = 8.0),
            ])
            ioc_invalid = IS.InputOutputCurve(pld_invalid)
            cost_curve_invalid = IS.CostCurve(ioc_invalid)

            @test_throws ErrorException IS.increasing_curve_convex_approximation(
                cost_curve_invalid,
            )
        end
    end

    @testset "Test increasing_curve_convex_approximation for FuelCurve" begin
        # Convex FuelCurve - should return unchanged
        pld_convex = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1.0),
            (x = 2.0, y = 3.0),
        ])
        ioc_convex = IS.InputOutputCurve(pld_convex)
        vom_cost = IS.LinearCurve(0.5)
        fuel_curve_convex = IS.FuelCurve(;
            value_curve = ioc_convex,
            power_units = IS.NaturalUnit(),
            fuel_cost = 25.0,
            vom_cost = vom_cost,
        )

        result = IS.increasing_curve_convex_approximation(fuel_curve_convex)
        @test result isa IS.FuelCurve
        @test IS.is_convex(result)
        @test IS.get_power_units(result) == IS.NaturalUnit()
        @test result.fuel_cost == 25.0
        @test IS.get_vom_cost(result) == vom_cost

        # Non-convex FuelCurve - should be convexified
        pld_concave = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 2.0),  # slope = 2
            (x = 2.0, y = 3.0),  # slope = 1 (non-convex)
        ])
        ioc_concave = IS.InputOutputCurve(pld_concave)
        vom_cost_2 = IS.LinearCurve(1.0)
        fuel_curve_concave = IS.FuelCurve(;
            value_curve = ioc_concave,
            power_units = IS.SystemBaseUnit(),
            fuel_cost = 30.0,
            vom_cost = vom_cost_2,
        )

        result_concave = IS.increasing_curve_convex_approximation(fuel_curve_concave)
        @test result_concave isa IS.FuelCurve
        @test IS.is_convex(result_concave)
        @test IS.get_power_units(result_concave) == IS.SystemBaseUnit()
        @test result_concave.fuel_cost == 30.0
        @test IS.get_vom_cost(result_concave) == vom_cost_2

        # FuelCurve with IncrementalCurve (PiecewiseStepData)
        psd_convex = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0])
        inc_convex = IS.IncrementalCurve(psd_convex, 0.0)
        fuel_curve_inc = IS.FuelCurve(;
            value_curve = inc_convex,
            power_units = IS.NaturalUnit(),
            fuel_cost = 20.0,
        )

        result_inc = IS.increasing_curve_convex_approximation(fuel_curve_inc)
        @test result_inc isa IS.FuelCurve
        @test IS.is_convex(result_inc)
        @test result_inc.fuel_cost == 20.0

        # Invalid FuelCurve (not strictly increasing) - should throw error
        # Use NullLogger to suppress expected @error logs from is_valid_data()
        Logging.with_logger(Logging.NullLogger()) do
            pld_invalid = IS.PiecewiseLinearData([
                (x = 0.0, y = 10.0),
                (x = 1.0, y = 5.0),   # decreasing
                (x = 2.0, y = 8.0),
            ])
            ioc_invalid = IS.InputOutputCurve(pld_invalid)
            fuel_curve_invalid = IS.FuelCurve(;
                value_curve = ioc_invalid,
                power_units = IS.NaturalUnit(),
                fuel_cost = 25.0,
            )

            @test_throws ErrorException IS.increasing_curve_convex_approximation(
                fuel_curve_invalid,
            )
        end
    end
end
