@testset "Test Convexity Checks" begin
    # LinearFunctionData
    lfd = IS.LinearFunctionData(5.0, 1.0)
    @test IS.is_convex(lfd)

    # QuadraticFunctionData
    qfd_convex = IS.QuadraticFunctionData(2.0, 3.0, 4.0)  # a > 0
    @test IS.is_convex(qfd_convex)

    qfd_concave = IS.QuadraticFunctionData(-2.0, 3.0, 4.0)  # a < 0
    @test !IS.is_convex(qfd_concave)

    qfd_linear = IS.QuadraticFunctionData(0.0, 3.0, 4.0)  # a = 0
    @test IS.is_convex(qfd_linear)

    # PiecewiseLinearData
    # Convex: slopes increasing (1.0, 2.0)
    pld_convex =
        IS.PiecewiseLinearData([(x = 0.0, y = 0.0), (x = 1.0, y = 1.0), (x = 2.0, y = 3.0)])
    @test IS.is_convex(pld_convex)

    # Concave: slopes decreasing (2.0, 1.0)
    pld_concave =
        IS.PiecewiseLinearData([(x = 0.0, y = 0.0), (x = 1.0, y = 2.0), (x = 2.0, y = 3.0)])
    @test !IS.is_convex(pld_concave)

    # Linear (Colinear): slopes equal (1.0, 1.0)
    pld_linear =
        IS.PiecewiseLinearData([(x = 0.0, y = 0.0), (x = 1.0, y = 1.0), (x = 2.0, y = 2.0)])
    @test IS.is_convex(pld_linear)

    # Non-convex and Non-concave (Zigzag): slopes (1.0, 0.5, 1.5) -> decrease then increase
    # 0->1 (slope 1), 1->2 (slope 0.5), 2->3 (slope 1.5)
    pld_zigzag = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 1.0, y = 1.0),
        (x = 2.0, y = 1.5),
        (x = 3.0, y = 3.0),
    ])
    @test !IS.is_convex(pld_zigzag)

    # PiecewiseStepData
    # Convex: y-coords increasing (1.0, 2.0)
    psd_convex = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0])
    @test IS.is_convex(psd_convex)

    # Concave: y-coords decreasing (2.0, 1.0)
    psd_concave = IS.PiecewiseStepData([0.0, 1.0, 2.0], [2.0, 1.0])
    @test !IS.is_convex(psd_concave)

    # Linear (Colinear): y-coords equal (1.0, 1.0)
    psd_linear = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 1.0])
    @test IS.is_convex(psd_linear)

    # Non-convex and Non-concave (Zigzag): 1.0, 0.5, 1.5
    psd_zigzag = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [1.0, 0.5, 1.5])
    @test !IS.is_convex(psd_zigzag)

    # Test ValueCurve types

    # LinearCurve (InputOutputCurve{LinearFunctionData})
    linear_curve = IS.InputOutputCurve(IS.LinearFunctionData(5.0, 1.0))
    @test IS.is_convex(linear_curve)

    # QuadraticCurve (InputOutputCurve{QuadraticFunctionData})
    quad_curve_convex = IS.InputOutputCurve(IS.QuadraticFunctionData(2.0, 3.0, 4.0))
    @test IS.is_convex(quad_curve_convex)

    quad_curve_concave = IS.InputOutputCurve(IS.QuadraticFunctionData(-2.0, 3.0, 4.0))
    @test !IS.is_convex(quad_curve_concave)

    # PiecewisePointCurve (InputOutputCurve{PiecewiseLinearData})
    pwp_curve_convex = IS.InputOutputCurve(
        IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1.0),
            (x = 2.0, y = 3.0),
        ]),
    )
    @test IS.is_convex(pwp_curve_convex)

    pwp_curve_concave = IS.InputOutputCurve(
        IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 2.0),
            (x = 2.0, y = 3.0),
        ]),
    )
    @test !IS.is_convex(pwp_curve_concave)

    # PiecewiseIncrementalCurve (IncrementalCurve{PiecewiseStepData})
    pwi_curve_convex = IS.IncrementalCurve(
        IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0]),
        0.0,
        0.0,
    )
    @test IS.is_convex(pwi_curve_convex)

    pwi_curve_concave = IS.IncrementalCurve(
        IS.PiecewiseStepData([0.0, 1.0, 2.0], [2.0, 1.0]),
        0.0,
        0.0,
    )
    @test !IS.is_convex(pwi_curve_concave)

    # PiecewiseAverageCurve (AverageRateCurve{PiecewiseStepData})
    pwa_curve_convex = IS.AverageRateCurve(
        IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0]),
        0.0,
        0.0,
    )
    @test IS.is_convex(pwa_curve_convex)

    pwa_curve_concave = IS.AverageRateCurve(
        IS.PiecewiseStepData([0.0, 1.0, 2.0], [2.0, 1.0]),
        0.0,
        0.0,
    )
    @test !IS.is_convex(pwa_curve_concave)

    # Test is_concave
    # PiecewiseLinearData
    concave_pld =
        IS.PiecewiseLinearData([(x = 0.0, y = 0.0), (x = 1.0, y = 2.0), (x = 2.0, y = 3.0)])
    non_concave_pld =
        IS.PiecewiseLinearData([(x = 0.0, y = 0.0), (x = 1.0, y = 1.0), (x = 2.0, y = 3.0)])

    @test IS.is_concave(concave_pld)
    @test !IS.is_concave(non_concave_pld)

    @test IS.is_concave(IS.InputOutputCurve(concave_pld))
    @test !IS.is_concave(IS.InputOutputCurve(non_concave_pld))

    @test IS.is_concave(IS.CostCurve(IS.InputOutputCurve(concave_pld)))
    @test !IS.is_concave(IS.CostCurve(IS.InputOutputCurve(non_concave_pld)))

    @test IS.is_concave(
        IS.PiecewiseStepData(; x_coords = [0.0, 1.0, 2.0], y_coords = [2.0, 1.0]),
    )
    @test !IS.is_concave(
        IS.PiecewiseStepData(; x_coords = [0.0, 1.0, 2.0], y_coords = [0.9, 1.0]),
    )

    # PiecewiseIncrementalCurve (IncrementalCurve{PiecewiseStepData})
    concave_pic = IS.PiecewiseIncrementalCurve(0.0, [0.0, 1.0, 2.0], [2.0, 1.0])
    non_concave_pic = IS.PiecewiseIncrementalCurve(0.0, [0.0, 1.0, 2.0], [0.9, 1.0])

    @test IS.is_concave(concave_pic)
    @test !IS.is_concave(non_concave_pic)

    @test IS.is_concave(IS.CostCurve(concave_pic))
    @test !IS.is_concave(IS.CostCurve(non_concave_pic))
end

@testset "Test Data Quality Checks" begin
    # Test valid data returns true
    valid_pld = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 1.0, y = 10.0),
        (x = 2.0, y = 25.0),
    ])
    @test IS.is_valid_data(valid_pld) == true

    # Use NullLogger to suppress expected error logs from validation tests
    Logging.with_logger(Logging.NullLogger()) do
        # Test that negative slopes are NOW ALLOWED in is_valid_data
        # (use is_strictly_increasing/decreasing to check slope sign)
        negative_slope_pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 10.0),
            (x = 1.0, y = 5.0),   # slope = -5
            (x = 2.0, y = 15.0),
        ])
        @test IS.is_valid_data(negative_slope_pld) == true  # No longer rejected

        # Test negative costs (y-values) returns false
        negative_cost_pld = IS.PiecewiseLinearData([
            (x = 0.0, y = -1e7),  # Very negative cost
            (x = 1.0, y = 10.0),
            (x = 2.0, y = 25.0),
        ])
        @test IS.is_valid_data(negative_cost_pld) == false

        # Test excessive slopes returns false (positive)
        excessive_slope_pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1e9),   # slope = 1e9 > 1e8
            (x = 2.0, y = 2e9),
        ])
        @test IS.is_valid_data(excessive_slope_pld) == false

        # Test excessive slopes returns false (negative - abs value check)
        excessive_negative_slope_pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 1e9),
            (x = 1.0, y = 0.0),   # slope = -1e9, abs > 1e8
            (x = 2.0, y = 1e9),
        ])
        @test IS.is_valid_data(excessive_negative_slope_pld) == false

        # Test excessive magnitudes returns false
        excessive_magnitude_pld = IS.PiecewiseLinearData([
            (x = 0.0, y = 0.0),
            (x = 1.0, y = 1e11),  # > 1e10
            (x = 2.0, y = 1.1e11),
        ])
        @test IS.is_valid_data(excessive_magnitude_pld) == false

        # Test PiecewiseStepData with negative rates is NOW ALLOWED
        negative_rate_psd = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-5.0, 10.0])
        @test IS.is_valid_data(negative_rate_psd) == true  # No longer rejected

        # Test PiecewiseStepData with excessive rates (negative, abs value check)
        excessive_negative_rate_psd = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-1e9, 10.0])
        @test IS.is_valid_data(excessive_negative_rate_psd) == false

        # Test LinearFunctionData with negative slope is NOW ALLOWED
        negative_slope_lfd = IS.LinearFunctionData(-5.0, 10.0)
        @test IS.is_valid_data(negative_slope_lfd) == true  # No longer rejected

        # Test LinearFunctionData with excessive negative slope
        excessive_negative_lfd = IS.LinearFunctionData(-1e9, 10.0)
        @test IS.is_valid_data(excessive_negative_lfd) == false

        # Test QuadraticFunctionData with negative proportional term is NOW ALLOWED
        negative_proportional_qfd = IS.QuadraticFunctionData(0.1, -5.0, 10.0)
        @test IS.is_valid_data(negative_proportional_qfd) == true  # No longer rejected

        # Test QuadraticFunctionData with excessive negative proportional term
        excessive_negative_qfd = IS.QuadraticFunctionData(0.1, -1e9, 10.0)
        @test IS.is_valid_data(excessive_negative_qfd) == false

        # Test ValueCurve wrapper with negative slopes is NOW ALLOWED
        negative_slope_ioc = IS.InputOutputCurve(
            IS.PiecewiseLinearData([
                (x = 0.0, y = 10.0),
                (x = 1.0, y = 5.0),
                (x = 2.0, y = 15.0),
            ]),
        )
        @test IS.is_valid_data(negative_slope_ioc) == true  # No longer rejected
    end

    # Test valid LinearFunctionData
    valid_lfd = IS.LinearFunctionData(5.0, 10.0)
    @test IS.is_valid_data(valid_lfd) == true

    # Test valid QuadraticFunctionData
    valid_qfd = IS.QuadraticFunctionData(0.1, 5.0, 10.0)
    @test IS.is_valid_data(valid_qfd) == true

    # Test ValueCurve wrappers
    valid_ioc = IS.InputOutputCurve(valid_pld)
    @test IS.is_valid_data(valid_ioc) == true

    # Test AverageRateCurve validates via InputOutputCurve conversion
    # This ensures the actual slopes are checked, not just the average rates
    valid_arc_psd = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0])  # Valid average rates
    valid_arc = IS.AverageRateCurve(valid_arc_psd, 0.0)
    @test IS.is_valid_data(valid_arc) == true
end

@testset "is_valid_data rejects time-series-backed data" begin
    forecast_key = IS.ForecastKey(;
        time_series_type = IS.Deterministic,
        name = "test_forecast",
        initial_timestamp = Dates.DateTime("2020-01-01"),
        resolution = Dates.Hour(1),
        horizon = Dates.Hour(24),
        interval = Dates.Hour(24),
        count = 1,
        features = Dict{String, Any}(),
    )

    # Raw TimeSeriesFunctionData — no inline data to validate
    ts_lin_fd = IS.TimeSeriesLinearFunctionData(forecast_key)
    @test_throws ArgumentError IS.is_valid_data(ts_lin_fd)

    ts_psd_fd = IS.TimeSeriesPiecewiseStepData(forecast_key)
    @test_throws ArgumentError IS.is_valid_data(ts_psd_fd)

    # TimeSeriesInputOutputCurve — wraps TimeSeriesFunctionData
    ts_io_curve =
        IS.TimeSeriesInputOutputCurve(IS.TimeSeriesLinearFunctionData(forecast_key))
    @test_throws ArgumentError IS.is_valid_data(ts_io_curve)

    # TimeSeriesIncrementalCurve — wraps TimeSeriesFunctionData
    ts_inc_curve = IS.TimeSeriesIncrementalCurve(
        IS.TimeSeriesPiecewiseStepData(forecast_key),
        nothing,
    )
    @test_throws ArgumentError IS.is_valid_data(ts_inc_curve)

    # TimeSeriesAverageRateCurve — wraps TimeSeriesFunctionData
    ts_arc_curve = IS.TimeSeriesAverageRateCurve(
        IS.TimeSeriesPiecewiseStepData(forecast_key),
        nothing,
    )
    @test_throws ArgumentError IS.is_valid_data(ts_arc_curve)
end

@testset "Test Monotonicity Predicates" begin
    # =========================================================================
    # LinearFunctionData
    # =========================================================================
    # Positive slope -> strictly increasing
    lfd_positive = IS.LinearFunctionData(5.0, 10.0)
    @test IS.is_strictly_increasing(lfd_positive) == true
    @test IS.is_strictly_decreasing(lfd_positive) == false

    # Negative slope -> strictly decreasing
    lfd_negative = IS.LinearFunctionData(-5.0, 10.0)
    @test IS.is_strictly_increasing(lfd_negative) == false
    @test IS.is_strictly_decreasing(lfd_negative) == true

    # Zero slope -> both true (within tolerance)
    lfd_zero = IS.LinearFunctionData(0.0, 10.0)
    @test IS.is_strictly_increasing(lfd_zero) == true
    @test IS.is_strictly_decreasing(lfd_zero) == true

    # Near-zero slope (within tolerance) -> both true
    lfd_tiny = IS.LinearFunctionData(1e-12, 10.0)
    @test IS.is_strictly_increasing(lfd_tiny) == true
    @test IS.is_strictly_decreasing(lfd_tiny) == true

    # =========================================================================
    # PiecewiseLinearData
    # =========================================================================
    # All positive slopes -> strictly increasing
    pld_increasing = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 1.0, y = 10.0),  # slope = 10
        (x = 2.0, y = 25.0),  # slope = 15
    ])
    @test IS.is_strictly_increasing(pld_increasing) == true
    @test IS.is_strictly_decreasing(pld_increasing) == false

    # All negative slopes -> strictly decreasing
    pld_decreasing = IS.PiecewiseLinearData([
        (x = 0.0, y = 25.0),
        (x = 1.0, y = 15.0),  # slope = -10
        (x = 2.0, y = 0.0),   # slope = -15
    ])
    @test IS.is_strictly_increasing(pld_decreasing) == false
    @test IS.is_strictly_decreasing(pld_decreasing) == true

    # Mixed slopes -> neither
    pld_mixed = IS.PiecewiseLinearData([
        (x = 0.0, y = 10.0),
        (x = 1.0, y = 5.0),   # slope = -5
        (x = 2.0, y = 15.0),  # slope = +10
    ])
    @test IS.is_strictly_increasing(pld_mixed) == false
    @test IS.is_strictly_decreasing(pld_mixed) == false

    # All zero slopes -> both true
    pld_flat = IS.PiecewiseLinearData([
        (x = 0.0, y = 10.0),
        (x = 1.0, y = 10.0),
        (x = 2.0, y = 10.0),
    ])
    @test IS.is_strictly_increasing(pld_flat) == true
    @test IS.is_strictly_decreasing(pld_flat) == true

    # =========================================================================
    # PiecewiseStepData
    # =========================================================================
    # All positive rates -> strictly increasing
    psd_increasing = IS.PiecewiseStepData([0.0, 1.0, 2.0], [5.0, 10.0])
    @test IS.is_strictly_increasing(psd_increasing) == true
    @test IS.is_strictly_decreasing(psd_increasing) == false

    # All negative rates -> strictly decreasing
    psd_decreasing = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-5.0, -10.0])
    @test IS.is_strictly_increasing(psd_decreasing) == false
    @test IS.is_strictly_decreasing(psd_decreasing) == true

    # Mixed rates -> neither
    psd_mixed = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-5.0, 10.0])
    @test IS.is_strictly_increasing(psd_mixed) == false
    @test IS.is_strictly_decreasing(psd_mixed) == false

    # All zero rates -> both true
    psd_flat = IS.PiecewiseStepData([0.0, 1.0, 2.0], [0.0, 0.0])
    @test IS.is_strictly_increasing(psd_flat) == true
    @test IS.is_strictly_decreasing(psd_flat) == true

    # =========================================================================
    # InputOutputCurve (delegates to FunctionData)
    # =========================================================================
    ioc_increasing = IS.InputOutputCurve(lfd_positive)
    @test IS.is_strictly_increasing(ioc_increasing) == true
    @test IS.is_strictly_decreasing(ioc_increasing) == false

    ioc_decreasing = IS.InputOutputCurve(lfd_negative)
    @test IS.is_strictly_increasing(ioc_decreasing) == false
    @test IS.is_strictly_decreasing(ioc_decreasing) == true

    # =========================================================================
    # IncrementalCurve (delegates to FunctionData, y-coords are slopes)
    # =========================================================================
    inc_psd_positive = IS.PiecewiseStepData([0.0, 1.0, 2.0], [5.0, 10.0])
    inc_increasing = IS.IncrementalCurve(inc_psd_positive, 0.0)
    @test IS.is_strictly_increasing(inc_increasing) == true
    @test IS.is_strictly_decreasing(inc_increasing) == false

    inc_psd_negative = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-5.0, -10.0])
    inc_decreasing = IS.IncrementalCurve(inc_psd_negative, 0.0)
    @test IS.is_strictly_increasing(inc_decreasing) == false
    @test IS.is_strictly_decreasing(inc_decreasing) == true

    # Mixed slopes -> neither
    inc_psd_mixed = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-5.0, 10.0])
    inc_mixed = IS.IncrementalCurve(inc_psd_mixed, 0.0)
    @test IS.is_strictly_increasing(inc_mixed) == false
    @test IS.is_strictly_decreasing(inc_mixed) == false

    # =========================================================================
    # AverageRateCurve (converts to InputOutputCurve first)
    # =========================================================================
    # Positive average rates -> check actual slopes after conversion
    arc_psd_positive = IS.PiecewiseStepData([0.0, 1.0, 2.0], [5.0, 10.0])
    arc_increasing = IS.AverageRateCurve(arc_psd_positive, 0.0)
    @test IS.is_strictly_increasing(arc_increasing) == true
    @test IS.is_strictly_decreasing(arc_increasing) == false

    # Negative average rates
    arc_psd_negative = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-5.0, -10.0])
    arc_decreasing = IS.AverageRateCurve(arc_psd_negative, 0.0)
    @test IS.is_strictly_increasing(arc_decreasing) == false
    @test IS.is_strictly_decreasing(arc_decreasing) == true
end
