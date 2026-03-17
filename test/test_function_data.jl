get_test_function_data() = [
    IS.LinearFunctionData(5, 1),
    IS.QuadraticFunctionData(2, 3, 4),
    IS.PiecewiseLinearData([(1, 1), (3, 5), (5, 10)]),
    IS.PiecewiseStepData([1, 3, 5], [2, 2.5]),
]

get_test_function_data_zeros() = [
    IS.LinearFunctionData(0.0, 0.0),
    IS.QuadraticFunctionData(0.0, 0.0, 0.0),
    IS.PiecewiseLinearData([(1.0, 0.0), (3.0, 0.0), (5.0, 0.0)]),
    IS.PiecewiseStepData([1.0, 3.0, 5.0], [0.0, 0.0]),
]

# Dictionary by type and whether we want NaNs
get_more_test_function_data() = Dict(
    (IS.LinearFunctionData, false) => IS.LinearFunctionData(1.0, 2.0),
    (IS.LinearFunctionData, true) => IS.LinearFunctionData(1.0, NaN),
    (IS.QuadraticFunctionData, false) => IS.QuadraticFunctionData(2.0, 3.0, 4.0),
    (IS.QuadraticFunctionData, true) => IS.QuadraticFunctionData(2.0, 3.0, NaN),
    (IS.PiecewiseLinearData, false) =>
        IS.PiecewiseLinearData([(1.0, 1.0), (3.0, 5.0), (5.0, 10.0)]),
    (IS.PiecewiseLinearData, true) =>
        IS.PiecewiseLinearData([(NaN, 1.0), (3.0, 5.0), (5.0, 10.0)]),
    (IS.PiecewiseStepData, false) =>
        IS.PiecewiseStepData([1.0, 3.0, 5.0], [2.0, 2.5]),
    (IS.PiecewiseStepData, true) =>
        IS.PiecewiseStepData([NaN, 3.0, 5.0], [2.0, 2.5]),
)

@testset "Test FunctionData constructors" begin
    @test all(isa.(get_test_function_data(), IS.FunctionData))
    @test IS.LinearFunctionData(5) isa IS.FunctionData
end

@testset "Test FunctionData validation" begin
    # x-coordinates need to be sorted
    @test_throws ArgumentError IS.PiecewiseLinearData([(2, 1), (1, 1)])
    @test_throws ArgumentError IS.PiecewiseStepData([2, 1], [1])

    # must specify at least two x-coordinates
    @test_throws ArgumentError IS.PiecewiseLinearData([(2, 1)])

    @test IS.PiecewiseLinearData([(x = 1, y = 1), (x = 2, y = 2)]) isa Any  # Test absence of error
    @test IS.PiecewiseLinearData([Dict("x" => 1, "y" => 1), Dict("x" => 2, "y" => 2)]) isa
          Any
    @test_throws ArgumentError IS.PiecewiseLinearData([(y = 1, x = 1), (y = 2, x = 2)])
    @test_throws ArgumentError IS.PiecewiseLinearData([Dict("x" => 1), Dict("x" => 2)])
end

@testset "Test FunctionData trivial getters" begin
    ld = IS.LinearFunctionData(5, 1)
    @test IS.get_proportional_term(ld) == 5

    qd = IS.QuadraticFunctionData(2, 3, 4)
    @test IS.get_quadratic_term(qd) == 2
    @test IS.get_proportional_term(qd) == 3
    @test IS.get_constant_term(qd) == 4

    yd = IS.PiecewiseLinearData([(1, 1), (3, 5)])
    @test IS.get_points(yd) == [(x = 1, y = 1), (x = 3, y = 5)]
    @test IS.get_x_coords(yd) == ([1, 3])
    @test IS.get_y_coords(yd) == ([1, 5])

    dd = IS.PiecewiseStepData([1, 3, 5], [3, 6])
    @test IS.get_x_coords(dd) == [1, 3, 5]
    @test IS.get_y_coords(dd) == [3, 6]
end

@testset "Test FunctionData core calculations" begin
    @test length(IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2)])) == 2
    @test length(IS.PiecewiseStepData([1, 1.1, 1.2], [1.1, 10])) == 2

    @test IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2)])[2] == (x = 1, y = 1)
    @test IS.get_x_coords(IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2)])) ==
          [0, 1, 1.1]

    # Tests our overridden Base.:(==)
    @test all(get_test_function_data() .== get_test_function_data())

    @test all(
        isapprox.(
            IS.get_slopes(IS.PiecewiseLinearData([(0, 0), (10, 31.4)])), [3.14]),
    )
    @test isapprox(
        IS.get_slopes(IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2), (1.2, 3)])),
        [1, 10, 10])
    @test isapprox(
        IS.get_slopes(IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2)])),
        [1, 10])

    @test IS.running_sum(IS.PiecewiseStepData([1, 3, 5], [2.5, 10])) isa
          Vector{IS.XY_COORDS}
    @test isapprox(
        collect.(IS.running_sum(IS.PiecewiseStepData([1, 3, 5], [2.5, 10]))),
        collect.([(1, 0), (3, 5), (5, 25)]),
    )

    @test isapprox(
        IS.get_x_lengths(IS.PiecewiseLinearData([(1, 1), (1.1, 2), (1.2, 3)])),
        [0.1, 0.1])
    @test isapprox(
        IS.get_x_lengths(IS.PiecewiseStepData([1, 1.1, 1.2], [1.1, 10])),
        [0.1, 0.1])

    convex_pld = IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2), (1.2, 3)])
    non_convex_pld = IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2), (5, 3)])

    @test IS.is_convex(convex_pld)
    @test !IS.is_convex(non_convex_pld)

    @test IS.is_convex(IS.InputOutputCurve(convex_pld))
    @test !IS.is_convex(IS.InputOutputCurve(non_convex_pld))

    @test IS.is_convex(IS.CostCurve(IS.InputOutputCurve(convex_pld)))
    @test !IS.is_convex(IS.CostCurve(IS.InputOutputCurve(non_convex_pld)))

    @test IS.is_convex(
        IS.PiecewiseStepData(; x_coords = [0.0, 1.0, 2.0], y_coords = [1.0, 2.0]),
    )
    @test !IS.is_convex(
        IS.PiecewiseStepData(; x_coords = [0.0, 1.0, 2.0], y_coords = [1.0, 0.9]),
    )

    concave_pld = IS.PiecewiseLinearData([(0, 3), (1, 2), (1.1, 1), (1.2, 0)])
    non_concave_pld = IS.PiecewiseLinearData([(0, 3), (1, 2), (1.1, 1), (1.2, 5)])

    # Test convexity checks (is_nonconvex removed)
    @test IS.is_convex(IS.LinearFunctionData(5.0, 1.0))
    @test IS.is_convex(IS.QuadraticFunctionData(2.0, 3.0, 4.0))  # a > 0
    @test !IS.is_convex(IS.QuadraticFunctionData(-2.0, 3.0, 4.0))  # a < 0
    @test IS.is_convex(convex_pld)
    @test !IS.is_convex(non_convex_pld)
    @test IS.is_convex(
        IS.PiecewiseStepData(; x_coords = [0.0, 1.0, 2.0], y_coords = [1.0, 2.0]),
    )
    @test !IS.is_convex(
        IS.PiecewiseStepData(; x_coords = [0.0, 1.0, 2.0], y_coords = [2.0, 1.0]),
    )

    @test IS.QuadraticFunctionData(IS.LinearFunctionData(1, 2)) ==
          convert(IS.QuadraticFunctionData, IS.LinearFunctionData(1, 2)) ==
          IS.QuadraticFunctionData(0, 1, 2)

    @test IS.get_domain(IS.LinearFunctionData(1, 2)) == (-Inf, Inf)
    @test IS.get_domain(IS.QuadraticFunctionData(1, 2, 3)) == (-Inf, Inf)
    @test IS.get_domain(IS.PiecewiseLinearData([(1, 1), (3, 1), (5, 1)])) == (1, 5)
    @test IS.get_domain(IS.PiecewiseStepData([1, 3, 5], [1, 1])) == (1, 5)

    for (fd, answer) in zip(get_test_function_data(), get_test_function_data_zeros())
        @test zero(fd) == answer
    end

    pld_zero = IS.PiecewiseLinearData([(1.0, 0), (5.0, 0)])
    psd_zero = IS.PiecewiseStepData([1.0, 5.0], [0.0])

    @test zero(IS.LinearFunctionData) == IS.LinearFunctionData(0, 0)
    @test zero(IS.QuadraticFunctionData) == IS.QuadraticFunctionData(0, 0, 0)
    @test zero(IS.PiecewiseLinearData) == IS.PiecewiseLinearData([(-Inf, 0), (Inf, 0)])
    @test zero(IS.PiecewiseStepData) == IS.PiecewiseStepData([-Inf, Inf], [0.0])
    @test zero(IS.PiecewiseLinearData; domain = (1.0, 5.0)) == pld_zero
    @test zero(IS.PiecewiseStepData; domain = (1.0, 5.0)) == psd_zero
    @test zero(IS.FunctionData) == IS.LinearFunctionData(0, 0)

    # non-Float64 Reals
    for arg in
        ((1, 5), (1 // 1, 5 // 1), (Float32(1), Float32(5)), (BigFloat(1), BigFloat(5)))
        @test zero(IS.PiecewiseLinearData; domain = arg) == pld_zero
        @test zero(IS.PiecewiseStepData; domain = arg) == psd_zero
    end
end

@testset "Test FunctionData higher-level arithmetic" begin
    # SCALAR MULTIPLICATION AND UNARY NEGATION
    # Test scalar multiplication for LinearFunctionData
    ld = IS.LinearFunctionData(5, 1)  # f(x) = 5x + 1
    ld_scaled = 3.0 * ld
    @test ld_scaled isa IS.LinearFunctionData
    @test IS.get_proportional_term(ld_scaled) == 15.0  # 3 * 5
    @test IS.get_constant_term(ld_scaled) == 3.0       # 3 * 1

    # Test scalar multiplication for QuadraticFunctionData
    qd = IS.QuadraticFunctionData(2, 3, 4)  # f(x) = 2x^2 + 3x + 4
    qd_scaled = 2.5 * qd
    @test qd_scaled isa IS.QuadraticFunctionData
    @test IS.get_quadratic_term(qd_scaled) == 5.0    # 2.5 * 2
    @test IS.get_proportional_term(qd_scaled) == 7.5 # 2.5 * 3
    @test IS.get_constant_term(qd_scaled) == 10.0    # 2.5 * 4

    # Test scalar multiplication for PiecewiseLinearData
    pld = IS.PiecewiseLinearData([(1, 2), (3, 6), (5, 10)])
    pld_scaled = 0.5 * pld
    @test pld_scaled isa IS.PiecewiseLinearData
    expected_points = [(x = 1.0, y = 1.0), (x = 3.0, y = 3.0), (x = 5.0, y = 5.0)]
    @test IS.get_points(pld_scaled) == expected_points
    @test IS.get_x_coords(pld_scaled) == [1, 3, 5]  # x-coordinates unchanged
    @test IS.get_y_coords(pld_scaled) == [1.0, 3.0, 5.0]  # y-coordinates scaled

    # Test scalar multiplication for PiecewiseStepData
    psd = IS.PiecewiseStepData([1, 3, 5], [4, 8])
    psd_scaled = 0.25 * psd
    @test psd_scaled isa IS.PiecewiseStepData
    @test IS.get_x_coords(psd_scaled) == [1, 3, 5]  # x-coordinates unchanged
    @test IS.get_y_coords(psd_scaled) == [1.0, 2.0]  # y-coordinates scaled: [0.25*4, 0.25*8]

    # Test commutativity of scalar multiplication
    scalars = [3.0, 2.5, 0.5, 0.25]
    for (fd, scalar) in zip(get_test_function_data(), scalars)
        @test fd * scalar == scalar * fd
    end

    # Test multiplication by zero
    for (fd, answer) in zip(get_test_function_data(), get_test_function_data_zeros())
        fd_zero = 0.0 * fd
        @test fd_zero isa typeof(fd)
        @test fd_zero == answer
    end

    # Test multiplication by one (identity)
    for fd in get_test_function_data()
        fd_identity = 1.0 * fd
        @test fd_identity == fd
        @test fd * 1.0 == fd
    end

    # Test multiplication by negative scalar and unary negation
    for fd in get_test_function_data()
        fd_neg = -1.0 * fd
        @test fd_neg isa typeof(fd)
        if fd isa IS.LinearFunctionData
            @test IS.get_proportional_term(fd_neg) == -IS.get_proportional_term(fd)
            @test IS.get_constant_term(fd_neg) == -IS.get_constant_term(fd)
        elseif fd isa IS.QuadraticFunctionData
            @test IS.get_quadratic_term(fd_neg) == -IS.get_quadratic_term(fd)
            @test IS.get_proportional_term(fd_neg) == -IS.get_proportional_term(fd)
            @test IS.get_constant_term(fd_neg) == -IS.get_constant_term(fd)
        elseif fd isa IS.PiecewiseLinearData
            orig_points = IS.get_points(fd)
            neg_points = IS.get_points(fd_neg)
            for (orig, neg) in zip(orig_points, neg_points)
                @test orig.x == neg.x
                @test orig.y == -neg.y
            end
        elseif fd isa IS.PiecewiseStepData
            @test IS.get_x_coords(fd_neg) == IS.get_x_coords(fd)
            @test IS.get_y_coords(fd_neg) == -IS.get_y_coords(fd)
        end

        @test -fd == fd_neg
    end

    # SCALAR ADDITION
    # Test scalar addition for LinearFunctionData
    ld = IS.LinearFunctionData(5, 1)  # f(x) = 5x + 1
    ld_plus_scalar = ld + 3.0         # (f + 3)(x) = 5x + 4
    @test ld_plus_scalar isa IS.LinearFunctionData
    @test IS.get_proportional_term(ld_plus_scalar) == 5.0  # unchanged
    @test IS.get_constant_term(ld_plus_scalar) == 4.0      # 1 + 3

    # Test scalar addition for QuadraticFunctionData
    qd = IS.QuadraticFunctionData(2, 3, 4)  # f(x) = 2x^2 + 3x + 4
    qd_plus_scalar = qd + 2.5               # (f + 2.5)(x) = 2x^2 + 3x + 6.5
    @test qd_plus_scalar isa IS.QuadraticFunctionData
    @test IS.get_quadratic_term(qd_plus_scalar) == 2.0      # unchanged
    @test IS.get_proportional_term(qd_plus_scalar) == 3.0   # unchanged
    @test IS.get_constant_term(qd_plus_scalar) == 6.5       # 4 + 2.5

    # Test scalar addition for PiecewiseLinearData
    pld = IS.PiecewiseLinearData([(1, 2), (3, 6), (5, 10)])
    pld_plus_scalar = pld + 1.5
    @test pld_plus_scalar isa IS.PiecewiseLinearData
    expected_points = [(x = 1.0, y = 3.5), (x = 3.0, y = 7.5), (x = 5.0, y = 11.5)]
    @test IS.get_points(pld_plus_scalar) == expected_points
    @test IS.get_x_coords(pld_plus_scalar) == [1, 3, 5]  # x-coordinates unchanged
    @test IS.get_y_coords(pld_plus_scalar) == [3.5, 7.5, 11.5]  # y-coordinates shifted up

    # Test scalar addition for PiecewiseStepData
    psd = IS.PiecewiseStepData([1, 3, 5], [4, 8])
    psd_plus_scalar = psd + 0.5
    @test psd_plus_scalar isa IS.PiecewiseStepData
    @test IS.get_x_coords(psd_plus_scalar) == [1, 3, 5]    # x-coordinates unchanged
    @test IS.get_y_coords(psd_plus_scalar) == [4.5, 8.5]   # y-coordinates shifted up: [4+0.5, 8+0.5]

    # Test commutativity of scalar addition (f + c = c + f)
    scalars = [3.0, 2.5, 1.5, 0.5]
    for (fd, scalar) in zip(get_test_function_data(), scalars)
        @test fd + scalar == scalar + fd
    end

    # Test adding zero (identity)
    for fd in get_test_function_data()
        @test fd + 0.0 == fd
        @test 0.0 + fd == fd
    end

    # Test adding negative scalar
    for fd in get_test_function_data()
        fd_minus_one = fd + (-1.0)
        @test fd_minus_one isa typeof(fd)
        if fd isa IS.LinearFunctionData
            @test IS.get_proportional_term(fd_minus_one) == IS.get_proportional_term(fd)
            @test IS.get_constant_term(fd_minus_one) == IS.get_constant_term(fd) - 1.0
        elseif fd isa IS.QuadraticFunctionData
            @test IS.get_quadratic_term(fd_minus_one) == IS.get_quadratic_term(fd)
            @test IS.get_proportional_term(fd_minus_one) == IS.get_proportional_term(fd)
            @test IS.get_constant_term(fd_minus_one) == IS.get_constant_term(fd) - 1.0
        elseif fd isa IS.PiecewiseLinearData
            orig_points = IS.get_points(fd)
            shifted_points = IS.get_points(fd_minus_one)
            for (orig, shifted) in zip(orig_points, shifted_points)
                @test orig.x == shifted.x
                @test orig.y - 1.0 == shifted.y
            end
        elseif fd isa IS.PiecewiseStepData
            @test IS.get_x_coords(fd_minus_one) == IS.get_x_coords(fd)
            @test IS.get_y_coords(fd_minus_one) == IS.get_y_coords(fd) .- 1.0
        end
    end

    # SHIFT BY A SCALAR
    # Test right shift for LinearFunctionData
    ld = IS.LinearFunctionData(5, 1)  # f(x) = 5x + 1
    ld_shifted = ld >> 2.0            # (f >> 2)(x) = f(x - 2) = 5(x - 2) + 1 = 5x - 9
    @test ld_shifted isa IS.LinearFunctionData
    @test IS.get_proportional_term(ld_shifted) == 5.0   # unchanged
    @test IS.get_constant_term(ld_shifted) == -9.0      # 1 - 5*2

    # Test right shift for QuadraticFunctionData
    qd = IS.QuadraticFunctionData(2, 3, 4)  # f(x) = 2x^2 + 3x + 4
    qd_shifted = qd >> 1.0                  # (f >> 1)(x) = f(x - 1) = 2(x-1)^2 + 3(x-1) + 4 = 2x^2 - x + 3
    @test qd_shifted isa IS.QuadraticFunctionData
    @test IS.get_quadratic_term(qd_shifted) == 2.0       # unchanged
    @test IS.get_proportional_term(qd_shifted) == -1.0    # 3 - 2*2*1
    @test IS.get_constant_term(qd_shifted) == 3.0        # 4 + 2*1^2 - 3*1

    # Another quadratic case
    qd2 = IS.QuadraticFunctionData(1, -2, 5)  # g(x) = x^2 - 2x + 5
    qd2_shifted = qd2 >> 3.0                  # (g >> 3)(x) = g(x - 3) = (x-3)^2 - 2(x-3) + 5 = x^2 - 8x + 20
    @test qd2_shifted isa IS.QuadraticFunctionData
    @test IS.get_quadratic_term(qd2_shifted) == 1.0      # unchanged
    @test IS.get_proportional_term(qd2_shifted) == -8.0  # -2 - 2*1*3 = -2 - 6 = -8
    @test IS.get_constant_term(qd2_shifted) == 20.0      # 5 + 1*3^2 - (-2)*3 = 5 + 9 + 6 = 20

    # Test right shift for PiecewiseLinearData
    pld = IS.PiecewiseLinearData([(1, 2), (3, 6), (5, 10)])
    pld_shifted = pld >> 1.5  # shifts x-coordinates right by 1.5
    @test pld_shifted isa IS.PiecewiseLinearData
    expected_points = [(x = 2.5, y = 2.0), (x = 4.5, y = 6.0), (x = 6.5, y = 10.0)]
    @test IS.get_points(pld_shifted) == expected_points
    @test IS.get_x_coords(pld_shifted) == [2.5, 4.5, 6.5]  # x-coordinates shifted
    @test IS.get_y_coords(pld_shifted) == [2.0, 6.0, 10.0]  # y-coordinates unchanged

    # Test right shift for PiecewiseStepData
    psd = IS.PiecewiseStepData([1, 3, 5], [4, 8])
    psd_shifted = psd >> 0.5  # shifts x-coordinates right by 0.5
    @test psd_shifted isa IS.PiecewiseStepData
    @test IS.get_x_coords(psd_shifted) == [1.5, 3.5, 5.5]  # x-coordinates shifted
    @test IS.get_y_coords(psd_shifted) == [4, 8]           # y-coordinates unchanged

    # Test left shift (f << c = f >> -c)
    shifts = [2.0, 1.0, 1.5, 0.5]
    for (fd, shift) in zip(get_test_function_data(), shifts)
        @test fd << shift == fd >> (-shift)
    end

    # Test shifting by zero (identity)
    for fd in get_test_function_data()
        @test fd >> 0.0 == fd
        @test fd << 0.0 == fd
    end

    # Test double shift equivalence: (f >> a) >> b = f >> (a + b)
    for fd in get_test_function_data()
        a, b = 1.0, 2.0
        @test (fd >> a) >> b == fd >> (a + b)
        @test (fd << a) << b == fd << (a + b)
    end

    # Test shift then reverse shift (should return to original)
    shifts = [1.0, 2.5, 0.75, 3.0]
    for (fd, shift) in zip(get_test_function_data(), shifts)
        shifted_back = (fd >> shift) << shift
        if fd isa Union{IS.LinearFunctionData, IS.QuadraticFunctionData}
            # For polynomial functions, use approximate equality due to floating point arithmetic
            if fd isa IS.LinearFunctionData
                @test isapprox(
                    IS.get_proportional_term(shifted_back),
                    IS.get_proportional_term(fd),
                )
                @test isapprox(IS.get_constant_term(shifted_back), IS.get_constant_term(fd))
            else  # QuadraticFunctionData
                @test isapprox(
                    IS.get_quadratic_term(shifted_back),
                    IS.get_quadratic_term(fd),
                )
                @test isapprox(
                    IS.get_proportional_term(shifted_back),
                    IS.get_proportional_term(fd),
                )
                @test isapprox(IS.get_constant_term(shifted_back), IS.get_constant_term(fd))
            end
        else
            # For piecewise functions, exact equality should hold
            @test shifted_back == fd
        end
    end

    # Test applicability to non-Float64 Reals
    for fd in get_test_function_data()
        for arg in (3, 3 // 1, Float32(3), BigFloat(3))
            @test arg * fd == 3.0 * fd
            @test fd * arg == fd * 3.0
            @test fd + arg == fd + 3.0
            @test arg + fd == 3.0 + fd
            @test fd >> arg == fd >> 3.0
            @test fd << arg == fd << 3.0
        end
    end

    # FLIP ABOUT Y-AXIS
    # Test flip for LinearFunctionData
    ld = IS.LinearFunctionData(5, 1)  # f(x) = 5x + 1
    ld_flipped = ~ld                  # (~f)(x) = f(-x) = 5(-x) + 1 = -5x + 1
    @test ld_flipped isa IS.LinearFunctionData
    @test IS.get_proportional_term(ld_flipped) == -5.0  # -5
    @test IS.get_constant_term(ld_flipped) == 1.0       # unchanged

    # Test flip for QuadraticFunctionData
    qd = IS.QuadraticFunctionData(2, 3, 4)  # f(x) = 2x^2 + 3x + 4
    qd_flipped = ~qd                        # (~f)(x) = f(-x) = 2(-x)^2 + 3(-x) + 4 = 2x^2 - 3x + 4
    @test qd_flipped isa IS.QuadraticFunctionData
    @test IS.get_quadratic_term(qd_flipped) == 2.0      # unchanged (even power)
    @test IS.get_proportional_term(qd_flipped) == -3.0  # -3 (odd power)
    @test IS.get_constant_term(qd_flipped) == 4.0       # unchanged

    # Test flip for PiecewiseLinearData
    pld = IS.PiecewiseLinearData([(1, 2), (3, 6), (5, 10)])
    pld_flipped = ~pld  # flips x-coordinates and reverses order
    @test pld_flipped isa IS.PiecewiseLinearData
    expected_points = [(x = -5.0, y = 10.0), (x = -3.0, y = 6.0), (x = -1.0, y = 2.0)]
    @test IS.get_points(pld_flipped) == expected_points
    @test IS.get_x_coords(pld_flipped) == [-5.0, -3.0, -1.0]  # negated and reversed
    @test IS.get_y_coords(pld_flipped) == [10.0, 6.0, 2.0]    # reversed

    # Test flip for PiecewiseStepData
    psd = IS.PiecewiseStepData([1, 3, 5], [4, 8])
    psd_flipped = ~psd  # flips x-coordinates and reverses both x and y arrays
    @test psd_flipped isa IS.PiecewiseStepData
    @test IS.get_x_coords(psd_flipped) == [-5, -3, -1]  # negated and reversed
    @test IS.get_y_coords(psd_flipped) == [8, 4]        # reversed

    # Test double flip returns to original
    for fd in get_test_function_data()
        double_flipped = ~(~fd)
        @test double_flipped == fd
    end

    # ADDITION OF TWO FUNCTIONDATAS
    # Test addition for LinearFunctionData
    ld1 = IS.LinearFunctionData(5, 1)   # f(x) = 5x + 1
    ld2 = IS.LinearFunctionData(3, 2)   # g(x) = 3x + 2
    ld_sum = ld1 + ld2                  # (f+g)(x) = 8x + 3
    @test ld_sum isa IS.LinearFunctionData
    @test IS.get_proportional_term(ld_sum) == 8.0  # 5 + 3
    @test IS.get_constant_term(ld_sum) == 3.0       # 1 + 2

    # Test addition for QuadraticFunctionData
    qd1 = IS.QuadraticFunctionData(2, 3, 4)  # f(x) = 2x^2 + 3x + 4
    qd2 = IS.QuadraticFunctionData(1, 2, 1)  # g(x) = x^2 + 2x + 1
    qd_sum = qd1 + qd2                       # (f+g)(x) = 3x^2 + 5x + 5
    @test qd_sum isa IS.QuadraticFunctionData
    @test IS.get_quadratic_term(qd_sum) == 3.0      # 2 + 1
    @test IS.get_proportional_term(qd_sum) == 5.0   # 3 + 2
    @test IS.get_constant_term(qd_sum) == 5.0       # 4 + 1

    # Test addition for PiecewiseLinearData with same x-coordinates
    pld1 = IS.PiecewiseLinearData([(1, 2), (3, 6), (5, 10)])
    pld2 = IS.PiecewiseLinearData([(1, 1), (3, 2), (5, 3)])
    pld_sum = pld1 + pld2
    @test pld_sum isa IS.PiecewiseLinearData
    expected_points = [(x = 1.0, y = 3.0), (x = 3.0, y = 8.0), (x = 5.0, y = 13.0)]
    @test IS.get_points(pld_sum) == expected_points
    @test IS.get_x_coords(pld_sum) == [1, 3, 5]
    @test IS.get_y_coords(pld_sum) == [3.0, 8.0, 13.0]

    # Test addition for PiecewiseStepData with same x-coordinates
    psd1 = IS.PiecewiseStepData([1, 3, 5], [4, 8])
    psd2 = IS.PiecewiseStepData([1, 3, 5], [2, 3])
    psd_sum = psd1 + psd2
    @test psd_sum isa IS.PiecewiseStepData
    @test IS.get_x_coords(psd_sum) == [1, 3, 5]
    @test IS.get_y_coords(psd_sum) == [6.0, 11.0]  # [4+2, 8+3]

    # Test addition errors for PiecewiseLinearData with different x-coordinates
    pld_diff = IS.PiecewiseLinearData([(1, 1), (2, 2), (4, 4)])  # different x-coords
    @test_throws ArgumentError pld1 + pld_diff

    # Test addition errors for PiecewiseStepData with different x-coordinates
    psd_diff = IS.PiecewiseStepData([1, 2, 4], [1, 2])  # different x-coords
    @test_throws ArgumentError psd1 + psd_diff

    # Test commutativity of addition (f + g = g + f)
    @test ld1 + ld2 == ld2 + ld1
    @test qd1 + qd2 == qd2 + qd1
    @test pld1 + pld2 == pld2 + pld1
    @test psd1 + psd2 == psd2 + psd1

    # Test associativity of addition ((f + g) + h = f + (g + h))
    ld3 = IS.LinearFunctionData(1, 3)
    @test (ld1 + ld2) + ld3 == ld1 + (ld2 + ld3)

    qd3 = IS.QuadraticFunctionData(1, 1, 2)
    @test (qd1 + qd2) + qd3 == qd1 + (qd2 + qd3)

    pld3 = IS.PiecewiseLinearData([(1, 0.5), (3, 1.5), (5, 2.5)])
    @test (pld1 + pld2) + pld3 == pld1 + (pld2 + pld3)

    psd3 = IS.PiecewiseStepData([1, 3, 5], [1, 1])
    @test (psd1 + psd2) + psd3 == psd1 + (psd2 + psd3)
end

@testset "Test FunctionData evaluation" begin
    # Test LinearFunctionData evaluation
    ld = IS.LinearFunctionData(5, 1)  # f(x) = 5x + 1
    @test ld(0) == 1.0      # f(0) = 5*0 + 1 = 1
    @test ld(2) == 11.0     # f(2) = 5*2 + 1 = 11
    @test ld(-1) == -4.0    # f(-1) = 5*(-1) + 1 = -4
    @test ld(1.5) == 8.5    # f(1.5) = 5*1.5 + 1 = 8.5

    # Test QuadraticFunctionData evaluation
    qd = IS.QuadraticFunctionData(2, 3, 4)  # f(x) = 2x^2 + 3x + 4
    @test qd(0) == 4.0      # f(0) = 2*0^2 + 3*0 + 4 = 4
    @test qd(1) == 9.0      # f(1) = 2*1^2 + 3*1 + 4 = 9
    @test qd(-1) == 3.0     # f(-1) = 2*(-1)^2 + 3*(-1) + 4 = 3
    @test qd(2) == 18.0     # f(2) = 2*2^2 + 3*2 + 4 = 18
    @test qd(0.5) == 6.0    # f(0.5) = 2*0.25 + 3*0.5 + 4 = 6

    # Test PiecewiseLinearData evaluation
    pld = IS.PiecewiseLinearData([(1, 2), (3, 6), (5, 10)])
    @test pld(1) == 2.0     # at first point
    @test pld(3) == 6.0     # at middle point
    @test pld(5) == 10.0    # at last point
    @test pld(2) == 4.0     # interpolated: halfway between (1,2) and (3,6)
    @test pld(4) == 8.0     # interpolated: halfway between (3,6) and (5,10)
    @test pld(1.5) == 3.0   # interpolated: 1/4 way from (1,2) to (3,6)

    # Test PiecewiseStepData evaluation
    psd = IS.PiecewiseStepData([1, 3, 5], [4, 8])
    @test psd(1) == 4       # at first x-coordinate
    @test psd(2) == 4       # in first interval [1, 3)
    @test psd(2.9) == 4     # still in first interval
    @test psd(3) == 8       # at second x-coordinate
    @test psd(4) == 8       # in second interval [3, 5)
    @test psd(5) == 8       # at last x-coordinate

    # Test domain checking for piecewise functions
    @test_throws ArgumentError pld(0.5)  # below domain
    @test_throws ArgumentError pld(5.5)  # above domain
    @test_throws ArgumentError psd(0.5)  # below domain
    @test_throws ArgumentError psd(5.5)  # above domain

    # Test evaluation with various numeric types
    for fd in [ld, qd, pld, psd]
        @test fd(2) == fd(2.0) == fd(2 // 1)  # Int, Float64, Rational
    end

    # Test evaluation with complex numbers
    # LinearFunctionData: f(x) = 5x + 1
    @test ld(1 + 2im) == 6 + 10im  # 5*(1 + 2im) + 1
    @test ld(2 - im) == 11 - 5im  # 5*(2 - im) + 1

    # QuadraticFunctionData: f(x) = 2x^2 + 3x + 4
    @test qd(1im) == 2 + 3im  # 2*(1im)^2 + 3*(1im) + 4
    @test qd(1 + im) == 7 + 7im  # 2*(1 + im)^2 + 3*(1 + im) + 4

    # Test consistency: evaluation after mathematical operations
    ld1 = IS.LinearFunctionData(2, 1)  # f(x) = 2x + 1
    ld2 = IS.LinearFunctionData(3, 2)  # g(x) = 3x + 2
    x_test = 1.5

    # Test that (f + g)(x) = f(x) + g(x)
    sum_fd = ld1 + ld2
    @test sum_fd(x_test) ≈ ld1(x_test) + ld2(x_test)

    # Test that (c * f)(x) = c * f(x)
    scaled_fd = 2.5 * ld1
    @test scaled_fd(x_test) ≈ 2.5 * ld1(x_test)

    # Test that (f + c)(x) = f(x) + c
    shifted_fd = ld1 + 3.0
    @test shifted_fd(x_test) ≈ ld1(x_test) + 3.0
end

@testset "Test PiecewiseLinearData <-> PiecewiseStepData conversion" begin
    rng = Random.Xoshiro(47)  # Set random seed for determinism
    n_tests = 100
    n_points = 10
    for _ in 1:n_tests
        rand_x = sort(rand(rng, n_points))
        rand_y = rand(rng, n_points)
        pointwise = IS.PiecewiseLinearData(collect(zip(rand_x, rand_y)))
        slopewise =
            IS.PiecewiseStepData(IS.get_x_coords(pointwise), IS.get_slopes(pointwise))
        c = first(IS.get_points(pointwise)).y
        pointwise_2 =
            IS.PiecewiseLinearData([(p.x, p.y + c) for p in IS.running_sum(slopewise)])
        @test isapprox(
            collect.(IS.get_points(pointwise_2)), collect.(IS.get_points(pointwise)))
    end
end

@testset "Test FunctionData serialization round trip" begin
    for fd in get_test_function_data()
        for do_jsonify in (false, true)
            serialized = IS.serialize(fd)
            do_jsonify && (serialized = JSON3.read(JSON3.write(serialized), Dict))
            @test typeof(serialized) <: AbstractDict
            deserialized = IS.deserialize(typeof(fd), serialized)
            @test deserialized == fd
        end
    end
end

@testset "Test FunctionData raw data" begin
    raw_data_answers = [
        (5.0, 1.0),
        (2.0, 3.0, 4.0),
        [(1.0, 1.0), (3.0, 5.0), (5.0, 10.0)],
        [1.0 NaN; 3.0 2.0; 5.0 2.5],
    ]
    for (fd, answer) in zip(get_test_function_data(), raw_data_answers)
        @test IS.get_raw_data_type(fd) == typeof(answer)
    end
    for (fd, answer) in zip(get_test_function_data(), raw_data_answers)
        @test IS.get_raw_data_type(typeof(fd)) == typeof(answer)
    end
end

@testset "Test FunctionData equality with NaN" begin
    examples_1 = get_more_test_function_data()
    examples_2 = get_more_test_function_data()

    # Value-equal function data should be == except when containing NaN since NaN != NaN;
    # value-equal function data should be isequal even when containing NaN; hash equality
    # should correspond with isequal
    for my_type in IS.get_all_concrete_subtypes(IS.StaticFunctionData)
        @test examples_1[(my_type, false)] == examples_2[(my_type, false)]
        @test examples_1[(my_type, true)] != examples_2[(my_type, true)]
        @test examples_1[(my_type, false)] != examples_2[(my_type, true)]
        @test isequal(examples_1[(my_type, false)], examples_2[(my_type, false)])
        @test isequal(examples_1[(my_type, true)], examples_2[(my_type, true)])
        @test !isequal(examples_1[(my_type, false)], examples_2[(my_type, true)])
        @test hash(examples_1[(my_type, false)]) == hash(examples_2[(my_type, false)])
        @test hash(examples_1[(my_type, true)]) == hash(examples_2[(my_type, true)])
        @test hash(examples_1[(my_type, false)]) != hash(examples_2[(my_type, true)])
    end
end

@testset "Test FunctionData printing" begin
    type_prefix = @static VERSION >= v"1.12" ? "" : "@NamedTuple{x::Float64, y::Float64}"
    repr_answers = [
        "InfrastructureSystems.LinearFunctionData(5.0, 1.0)",
        "InfrastructureSystems.QuadraticFunctionData(2.0, 3.0, 4.0)",
        "InfrastructureSystems.PiecewiseLinearData($(type_prefix)[(x = 1.0, y = 1.0), (x = 3.0, y = 5.0), (x = 5.0, y = 10.0)])",
        "InfrastructureSystems.PiecewiseStepData([1.0, 3.0, 5.0], [2.0, 2.5])",
    ]
    plain_answers = [
        "InfrastructureSystems.LinearFunctionData representing function f(x) = 5.0 x + 1.0",
        "InfrastructureSystems.QuadraticFunctionData representing function f(x) = 2.0 x^2 + 3.0 x + 4.0",
        "InfrastructureSystems.PiecewiseLinearData representing piecewise linear function y = f(x) connecting points:\n  (x = 1.0, y = 1.0)\n  (x = 3.0, y = 5.0)\n  (x = 5.0, y = 10.0)",
        "InfrastructureSystems.PiecewiseStepData representing step (piecewise constant) function f(x) =\n  2.0 for x in [1.0, 3.0)\n  2.5 for x in [3.0, 5.0)",
    ]
    compact_plain_answers = [
        "f(x) = 5.0 x + 1.0",
        "f(x) = 2.0 x^2 + 3.0 x + 4.0",
        "piecewise linear y = f(x) connecting points:\n  (x = 1.0, y = 1.0)\n  (x = 3.0, y = 5.0)\n  (x = 5.0, y = 10.0)",
        "f(x) =\n  2.0 for x in [1.0, 3.0)\n  2.5 for x in [3.0, 5.0)",
    ]

    for (fd, repr_ans, plain_ans, compact_plain_ans) in
        zip(get_test_function_data(), repr_answers, plain_answers, compact_plain_answers)
        @test sprint(show, fd) == repr(fd) == repr_ans
        @test sprint(show, "text/plain", fd) ==
              sprint(show, "text/plain", fd; context = :compact => false) == plain_ans
        @test sprint(show, "text/plain", fd; context = :compact => true) ==
              compact_plain_ans
    end
end

@testset "Test isotonic regression" begin
    # Test basic isotonic regression
    values = [3.0, 1.0, 4.0, 1.0, 5.0]
    weights = ones(5)
    result = IS.isotonic_regression(values, weights)
    @test issorted(result)  # Result should be non-decreasing

    # Test with uniform weights - first two should pool
    values = [10.0, 5.0, 15.0]
    weights = [1.0, 1.0, 1.0]
    result = IS.isotonic_regression(values, weights)
    @test result[1] ≈ 7.5  # (10 + 5) / 2
    @test result[2] ≈ 7.5
    @test result[3] ≈ 15.0
    @test issorted(result)

    # Test with different weights
    values = [10.0, 5.0, 15.0]
    weights = [2.0, 1.0, 1.0]  # First element has twice the weight
    result = IS.isotonic_regression(values, weights)
    expected_pooled = (10.0 * 2.0 + 5.0 * 1.0) / (2.0 + 1.0)  # 25/3 ≈ 8.33
    @test result[1] ≈ expected_pooled
    @test result[2] ≈ expected_pooled
    @test result[3] ≈ 15.0

    # Test already monotone sequence
    values = [1.0, 2.0, 3.0, 4.0]
    weights = ones(4)
    result = IS.isotonic_regression(values, weights)
    @test result ≈ values

    # Test constant sequence
    values = [5.0, 5.0, 5.0]
    weights = ones(3)
    result = IS.isotonic_regression(values, weights)
    @test result ≈ values

    # Test empty input
    @test IS.isotonic_regression(Float64[], Float64[]) == Float64[]

    # Test mismatched lengths
    @test_throws ArgumentError IS.isotonic_regression([1.0, 2.0], [1.0])
end

@testset "Test increasing_curve_convex_approximation for PiecewiseStepData" begin
    # Test basic non-convex case via IncrementalCurve
    # Slopes: [10, 5, 15] - violation at index 1 (10 > 5)
    step_data = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 15.0])
    curve = IS.IncrementalCurve(step_data, 0.0)
    @test !IS.is_convex(curve)

    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :uniform,
            merge_colinear = false,
        )
    @test IS.is_convex(convex_curve)
    convex_step = IS.get_function_data(convex_curve)
    @test IS.get_x_coords(convex_step) == IS.get_x_coords(step_data)

    # Check that the first two slopes are pooled
    new_y = IS.get_y_coords(convex_step)
    @test new_y[1] ≈ new_y[2] ≈ 7.5  # (10 + 5) / 2
    @test new_y[3] ≈ 15.0

    # Test with length weighting
    step_data = IS.PiecewiseStepData([0.0, 2.0, 3.0, 6.0], [10.0, 5.0, 15.0])
    curve = IS.IncrementalCurve(step_data, 0.0)
    # Segment lengths: [2, 1, 3]
    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :length,
            merge_colinear = false,
        )
    @test IS.is_convex(convex_curve)
    new_y = IS.get_y_coords(IS.get_function_data(convex_curve))
    # Pooled value = (10*2 + 5*1) / (2+1) = 25/3 ≈ 8.33
    @test new_y[1] ≈ new_y[2] ≈ 25.0 / 3.0

    # Test already convex data (should return equivalent curve)
    convex_data = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1.0, 2.0])
    curve = IS.IncrementalCurve(convex_data, 0.0)
    @test IS.is_convex(curve)
    result = IS.increasing_curve_convex_approximation(curve)
    @test result == curve  # Should be equivalent curve

    # Test multiple violations
    step_data = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0, 4.0], [5.0, 3.0, 1.0, 10.0])
    curve = IS.IncrementalCurve(step_data, 0.0)
    convex_curve = IS.increasing_curve_convex_approximation(curve; weights = :uniform)
    @test IS.is_convex(convex_curve)

    # Test uniform weights
    step_data = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 15.0])
    curve = IS.IncrementalCurve(step_data, 0.0)
    convex_curve = IS.increasing_curve_convex_approximation(curve; weights = :uniform)
    @test IS.is_convex(convex_curve)
end

@testset "Test increasing_curve_convex_approximation for PiecewiseLinearData" begin
    # Test basic non-convex case via InputOutputCurve
    linear_data = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 1.0, y = 10.0),   # slope = 10
        (x = 2.0, y = 15.0),   # slope = 5  <- violation!
        (x = 3.0, y = 30.0),   # slope = 15
    ])
    curve = IS.InputOutputCurve(linear_data)
    @test !IS.is_convex(curve)

    # Test with anchor=:first (with merge_colinear=false to preserve x-coords)
    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :uniform,
            anchor = :first,
            merge_colinear = false,
        )
    @test IS.is_convex(convex_curve)
    convex_linear = IS.get_function_data(convex_curve)
    @test IS.get_x_coords(convex_linear) == IS.get_x_coords(linear_data)
    # First point should be preserved
    @test IS.get_points(convex_linear)[1] == IS.get_points(linear_data)[1]

    # Test with anchor=:last (with merge_colinear=false to preserve x-coords)
    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :uniform,
            anchor = :last,
            merge_colinear = false,
        )
    @test IS.is_convex(convex_curve)
    convex_linear = IS.get_function_data(convex_curve)
    # Last point should be preserved
    @test IS.get_points(convex_linear)[end] == IS.get_points(linear_data)[end]

    # Test with anchor=:centroid
    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :uniform,
            anchor = :centroid,
        )
    @test IS.is_convex(convex_curve)

    # Test already convex data (with colinear segments)
    convex_data = IS.PiecewiseLinearData([(0, 0), (1, 1), (1.1, 2), (1.2, 3)])
    curve = IS.InputOutputCurve(convex_data)
    @test IS.is_convex(curve)
    result = IS.increasing_curve_convex_approximation(curve)
    @test IS.is_convex(result)
    # With merge_colinear=true (default), colinear segments may be merged
    # The last two segments have slope 10, so they're merged
    @test length(IS.get_points(IS.get_function_data(result))) == 3
    # With merge_colinear=false, convex curve should be returned unchanged
    result_no_merge =
        IS.increasing_curve_convex_approximation(curve; merge_colinear = false)
    @test result_no_merge === curve

    # Test with length weighting (merge_colinear=false to verify pooled slopes)
    linear_data = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 2.0, y = 20.0),  # slope = 10, length = 2
        (x = 3.0, y = 25.0),  # slope = 5, length = 1
        (x = 6.0, y = 70.0),  # slope = 15, length = 3
    ])
    curve = IS.InputOutputCurve(linear_data)
    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :length,
            anchor = :first,
            merge_colinear = false,
        )
    @test IS.is_convex(convex_curve)

    # Check the pooled slope value
    new_slopes = IS.get_slopes(IS.get_function_data(convex_curve))
    expected_pooled = (10.0 * 2.0 + 5.0 * 1.0) / 3.0  # 25/3
    @test new_slopes[1] ≈ expected_pooled
    @test new_slopes[2] ≈ expected_pooled

    # Test invalid anchor
    @test_throws ArgumentError IS.increasing_curve_convex_approximation(
        curve;
        anchor = :invalid,
    )
end

@testset "Test approximation_error" begin
    # Test PiecewiseStepData error
    original = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 15.0])
    approximated = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [7.5, 7.5, 15.0])

    # L2 error with uniform weights
    err_l2 =
        IS.approximation_error(original, approximated; metric = :L2, weights = :uniform)
    diff = [10.0 - 7.5, 5.0 - 7.5, 15.0 - 15.0]
    expected_l2 = sqrt(sum(diff .^ 2) / 3)
    @test err_l2 ≈ expected_l2

    # L1 error
    err_l1 =
        IS.approximation_error(original, approximated; metric = :L1, weights = :uniform)
    expected_l1 = sum(abs.(diff)) / 3
    @test err_l1 ≈ expected_l1

    # Linf error
    err_linf =
        IS.approximation_error(original, approximated; metric = :Linf, weights = :uniform)
    @test err_linf ≈ 2.5  # max(|2.5|, |-2.5|, |0|)

    # Test with length weighting
    original = IS.PiecewiseStepData([0.0, 2.0, 3.0, 6.0], [10.0, 5.0, 15.0])
    approximated = IS.PiecewiseStepData([0.0, 2.0, 3.0, 6.0], [8.0, 8.0, 15.0])
    err = IS.approximation_error(original, approximated; metric = :L2, weights = :length)
    # Weights: [2, 1, 3]
    diff = [10.0 - 8.0, 5.0 - 8.0, 15.0 - 15.0]
    expected = sqrt((4.0 * 2 + 9.0 * 1 + 0.0 * 3) / 6)
    @test err ≈ expected

    # Test invalid metric
    @test_throws ArgumentError IS.approximation_error(
        original,
        approximated;
        metric = :invalid,
    )

    # Test PiecewiseLinearData error (based on slopes)
    # Use merge_colinear=false so dimensions match for error computation
    original = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 1.0, y = 10.0),
        (x = 2.0, y = 15.0),
        (x = 3.0, y = 30.0),
    ])
    curve = IS.InputOutputCurve(original)
    convex_curve =
        IS.increasing_curve_convex_approximation(
            curve;
            weights = :uniform,
            anchor = :first,
            merge_colinear = false,
        )
    convex = IS.get_function_data(convex_curve)
    err = IS.approximation_error(original, convex; weights = :uniform)
    @test err >= 0.0  # Error should be non-negative
end

@testset "Test convex approximation edge cases" begin
    # Test with two points (single segment) via InputOutputCurve
    linear_data = IS.PiecewiseLinearData([(0.0, 0.0), (1.0, 10.0)])
    curve = IS.InputOutputCurve(linear_data)
    @test IS.is_convex(curve)
    @test IS.increasing_curve_convex_approximation(curve) === curve

    step_data = IS.PiecewiseStepData([0.0, 1.0], [5.0])
    step_curve = IS.IncrementalCurve(step_data, 0.0)
    @test IS.is_convex(step_curve)
    @test IS.increasing_curve_convex_approximation(step_curve) == step_curve

    # Test with equal slopes (colinear segments should be merged)
    linear_data = IS.PiecewiseLinearData([(0.0, 0.0), (1.0, 5.0), (2.0, 10.0), (3.0, 15.0)])
    curve = IS.InputOutputCurve(linear_data)
    @test IS.is_convex(curve)
    result = IS.increasing_curve_convex_approximation(curve)
    @test IS.is_convex(result)
    # Colinear segments are merged, so we get 2 points instead of 4
    @test length(IS.get_points(IS.get_function_data(result))) == 2
    # With merge_colinear=false, should return unchanged
    result_no_merge =
        IS.increasing_curve_convex_approximation(curve; merge_colinear = false)
    @test result_no_merge === curve

    # Test severe violation (all slopes need to pool)
    step_data = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 1.0])
    step_curve = IS.IncrementalCurve(step_data, 0.0)
    convex_curve = IS.increasing_curve_convex_approximation(step_curve; weights = :uniform)
    @test IS.is_convex(convex_curve)
    # All should pool to average: (10 + 5 + 1) / 3 ≈ 5.33
    new_y = IS.get_y_coords(IS.get_function_data(convex_curve))
    @test all(y ≈ 16.0 / 3.0 for y in new_y)

    # Use NullLogger to suppress expected @error logs from is_valid_data()
    Logging.with_logger(Logging.NullLogger()) do
        # Test with negative values - throws error because curve is not strictly increasing
        step_data_neg = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [-5.0, -10.0, -3.0])
        step_curve_neg = IS.IncrementalCurve(step_data_neg, 0.0)
        @test_throws ErrorException IS.increasing_curve_convex_approximation(step_curve_neg)

        # Test with large values - throws error due to data validation (excessive slope)
        step_data_large = IS.PiecewiseStepData([0.0, 1.0, 2.0], [1e10, 1e5])
        step_curve_large = IS.IncrementalCurve(step_data_large, 0.0)
        @test_throws ErrorException IS.increasing_curve_convex_approximation(
            step_curve_large,
        )

        # Test with excessively large negative values - throws error (abs value check)
        step_data_large_neg = IS.PiecewiseStepData([0.0, 1.0, 2.0], [-1e10, -1e5])
        step_curve_large_neg = IS.IncrementalCurve(step_data_large_neg, 0.0)
        @test_throws ErrorException IS.increasing_curve_convex_approximation(
            step_curve_large_neg,
        )
    end

    # Test approximation_error returns zero for identical data
    original = IS.PiecewiseStepData([0.0, 1.0, 2.0], [5.0, 10.0])
    @test IS.approximation_error(original, original) ≈ 0.0
end

@testset "Test convex approximation consistency" begin
    # Test that increasing_curve_convex_approximation is idempotent (second call returns same object)
    linear_data = IS.PiecewiseLinearData([
        (x = 0.0, y = 0.0),
        (x = 1.0, y = 10.0),
        (x = 2.0, y = 15.0),
        (x = 3.0, y = 30.0),
    ])
    curve = IS.InputOutputCurve(linear_data)
    convex1 = IS.increasing_curve_convex_approximation(curve)
    convex2 = IS.increasing_curve_convex_approximation(convex1)
    # After colinearity cleanup + convexification, result is already clean
    # So second call should produce equivalent result  
    @test IS.is_convex(convex1)
    @test IS.is_convex(convex2)
    # Check structural equality (both should be convex and cleaned)
    @test IS.get_function_data(convex2) == IS.get_function_data(convex1)

    # Test with step data
    step_data = IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 15.0])
    step_curve = IS.IncrementalCurve(step_data, 0.0)
    convex1 = IS.increasing_curve_convex_approximation(step_curve)
    convex2 = IS.increasing_curve_convex_approximation(convex1)
    @test IS.is_convex(convex1)
    @test IS.is_convex(convex2)
    # Check structural equality
    @test IS.get_function_data(convex2) == IS.get_function_data(convex1)
end

@testset "Test convex approximation with random data" begin
    rng = Random.Xoshiro(42)
    n_tests = 20
    n_points = 10

    for _ in 1:n_tests
        # Generate random piecewise linear data with positive slopes (valid cost curve)
        rand_x = sort(rand(rng, n_points))
        # Cumsum of positive values ensures monotonically increasing y (non-negative slopes)
        rand_y = cumsum(rand(rng, n_points) * 10)
        pointwise = IS.PiecewiseLinearData(collect(zip(rand_x, rand_y)))

        # Make convex via InputOutputCurve
        curve = IS.InputOutputCurve(pointwise)
        convex_curve =
            IS.increasing_curve_convex_approximation(curve; merge_colinear = false)
        @test convex_curve !== nothing
        convex = IS.get_function_data(convex_curve)
        @test IS.is_convex(convex)
        @test IS.get_x_coords(convex) == IS.get_x_coords(pointwise)

        # Generate random step data with positive marginal rates (valid cost curve)
        rand_x_step = sort(rand(rng, n_points))
        rand_y_step = rand(rng, n_points - 1) * 100  # Positive marginal rates
        stepwise = IS.PiecewiseStepData(rand_x_step, rand_y_step)

        # Make convex via IncrementalCurve
        step_curve = IS.IncrementalCurve(stepwise, 0.0)
        convex_step_curve = IS.increasing_curve_convex_approximation(step_curve)
        @test convex_step_curve !== nothing
        convex_step = IS.get_function_data(convex_step_curve)
        @test IS.is_convex(convex_step)
    end
end

@testset "Test piecewise domain checking" begin
    pwl = IS.PiecewiseStepData([1, 3, 5], [8, 10])

    # floating point inputs
    @test_throws ArgumentError pwl(0.5)
    @test_throws ArgumentError pwl(5.5)
    pwl(2.5)

    # non floating point inputs
    @test_throws ArgumentError pwl(1 // 2)
    @test_throws ArgumentError pwl(5 + 1 // 2)
    pwl(5 // 2)

    # floating point precision edge cases (should not error)
    @assert isapprox(1 - eps() / 2, 1)
    @assert isapprox(5 + eps() / 2, 5)
    pwl(1 - eps() / 2)
    pwl(5 + eps() / 2)
end

# =============================================================================
# INCREASING_CURVE_CONVEX_APPROXIMATION TESTS FOR VALUE CURVES
# =============================================================================

@testset "Test increasing_curve_convex_approximation for PiecewisePointCurve" begin
    # Non-convex piecewise curve (slopes decrease then increase)
    ppc = IS.PiecewisePointCurve([
        (0.0, 0.0),
        (1.0, 10.0),   # slope = 10
        (2.0, 15.0),   # slope = 5 <- violation
        (3.0, 30.0),   # slope = 15
    ])
    @test !IS.is_convex(ppc)

    convex_ppc = IS.increasing_curve_convex_approximation(ppc; merge_colinear = false)
    @test IS.is_convex(convex_ppc)
    @test convex_ppc isa IS.PiecewisePointCurve
    @test IS.get_x_coords(convex_ppc) == IS.get_x_coords(ppc)

    # Already convex - should return same object
    ppc_convex = IS.PiecewisePointCurve([(0.0, 0.0), (1.0, 1.0), (2.0, 3.0)])
    @test IS.is_convex(ppc_convex)
    result = IS.increasing_curve_convex_approximation(ppc_convex)
    @test result === ppc_convex

    # With input_at_zero - should be preserved
    ppc_iaz = IS.InputOutputCurve(
        IS.PiecewiseLinearData([(0.0, 0.0), (1.0, 10.0), (2.0, 15.0)]),
        100.0,
    )
    result_iaz = IS.increasing_curve_convex_approximation(ppc_iaz)
    @test IS.get_input_at_zero(result_iaz) == 100.0

    # Test with different anchor options
    convex_last = IS.increasing_curve_convex_approximation(ppc; anchor = :last)
    @test IS.is_convex(convex_last)
    @test IS.get_points(convex_last)[end] == IS.get_points(ppc)[end]

    convex_centroid = IS.increasing_curve_convex_approximation(ppc; anchor = :centroid)
    @test IS.is_convex(convex_centroid)

    # Test with different weight options
    convex_uniform = IS.increasing_curve_convex_approximation(ppc; weights = :uniform)
    @test IS.is_convex(convex_uniform)

    convex_length = IS.increasing_curve_convex_approximation(ppc; weights = :length)
    @test IS.is_convex(convex_length)
end

@testset "Test increasing_curve_convex_approximation for PiecewiseIncrementalCurve" begin
    # Non-convex: slopes decrease then increase [10, 5, 15]
    pic = IS.PiecewiseIncrementalCurve(0.0, [0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 15.0])
    @test !IS.is_convex(pic)

    convex_pic = IS.increasing_curve_convex_approximation(pic; merge_colinear = false)
    @test IS.is_convex(convex_pic)
    @test convex_pic isa IS.PiecewiseIncrementalCurve
    @test IS.get_x_coords(convex_pic) == IS.get_x_coords(pic)

    # Already convex - should return equivalent curve
    pic_convex = IS.PiecewiseIncrementalCurve(0.0, [0.0, 1.0, 2.0], [5.0, 10.0])
    @test IS.is_convex(pic_convex)
    result = IS.increasing_curve_convex_approximation(pic_convex)
    @test result == pic_convex

    # With input_at_zero - should be preserved
    pic_iaz = IS.IncrementalCurve(
        IS.PiecewiseStepData([0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 15.0]),
        0.0,
        200.0,
    )
    result_iaz = IS.increasing_curve_convex_approximation(pic_iaz)
    @test IS.is_convex(result_iaz)
    @test IS.get_input_at_zero(result_iaz) == 200.0

    # Test with different weight options
    convex_uniform = IS.increasing_curve_convex_approximation(pic; weights = :uniform)
    @test IS.is_convex(convex_uniform)

    convex_length = IS.increasing_curve_convex_approximation(pic; weights = :length)
    @test IS.is_convex(convex_length)
end

@testset "Test increasing_curve_convex_approximation for PiecewiseAverageCurve" begin
    # Non-convex average rate curve (but with valid positive slopes after conversion)
    # Use average rates that produce non-convex but positive-slope curves
    pac = IS.PiecewiseAverageCurve(0.0, [0.0, 1.0, 2.0, 3.0], [5.0, 3.0, 6.0])
    @test !IS.is_convex(pac)

    convex_pac = IS.increasing_curve_convex_approximation(pac)
    @test convex_pac !== nothing
    @test IS.is_convex(convex_pac)
    @test convex_pac isa IS.PiecewiseAverageCurve

    # Already convex - should return equivalent object (not necessarily same reference)
    pac_convex = IS.PiecewiseAverageCurve(0.0, [0.0, 1.0, 2.0], [5.0, 10.0])
    @test IS.is_convex(pac_convex)
    result = IS.increasing_curve_convex_approximation(pac_convex)
    @test result == pac_convex

    # Test with different options
    convex_uniform = IS.increasing_curve_convex_approximation(pac; weights = :uniform)
    @test convex_uniform !== nothing
    @test IS.is_convex(convex_uniform)

    convex_last = IS.increasing_curve_convex_approximation(pac; anchor = :last)
    @test convex_last !== nothing
    @test IS.is_convex(convex_last)

    # Use NullLogger to suppress expected @error logs from is_valid_data()
    Logging.with_logger(Logging.NullLogger()) do
        # Test that data with negative slopes throws error (not strictly increasing)
        pac_with_neg =
            IS.PiecewiseAverageCurve(6.0, [1.0, 2.0, 3.0, 4.0], [10.0, 5.0, 15.0])
        @test_throws ErrorException IS.increasing_curve_convex_approximation(pac_with_neg)

        # Test that data with excessively large slopes also throws error
        pac_invalid =
            IS.PiecewiseAverageCurve(6.0, [1.0, 2.0, 3.0, 4.0], [1e10, 5.0, 15.0])
        @test_throws ErrorException IS.increasing_curve_convex_approximation(pac_invalid)
    end
end

@testset "Test increasing_curve_convex_approximation idempotency for ValueCurves" begin
    # Test that applying increasing_curve_convex_approximation twice returns the same object on second call
    # Note: IncrementalCurve{LinearFunctionData} and AverageRateCurve{LinearFunctionData}
    # are intentionally not included - increasing_curve_convex_approximation is not defined for these types.
    # Note: LinearCurve and QuadraticCurve are not supported by increasing_curve_convex_approximation

    # Use non-convex data with valid (positive, reasonable) costs that produce positive slopes
    curves = [
        IS.PiecewisePointCurve([(0.0, 0.0), (1.0, 10.0), (2.0, 15.0), (3.0, 30.0)]),
        IS.PiecewiseIncrementalCurve(0.0, [0.0, 1.0, 2.0, 3.0], [10.0, 5.0, 8.0]),  # Non-convex (10 > 5) but all positive
        IS.PiecewiseAverageCurve(6.0, [1.0, 2.0, 3.0, 4.0], [6.0, 5.0, 6.0]),  # Non-convex but produces positive slopes
    ]

    for curve in curves
        convex1 = IS.increasing_curve_convex_approximation(curve)
        @test convex1 !== nothing
        @test IS.is_convex(convex1)
        convex2 = IS.increasing_curve_convex_approximation(convex1)
        @test convex2 == convex1  # Second call should return equivalent object
    end
end

@testset "Test increasing_curve_convex_approximation consistency across curve representations" begin
    # Create equivalent curves in different representations and verify
    # that increasing_curve_convex_approximation produces consistent results

    # Non-convex PiecewisePointCurve
    ppc = IS.PiecewisePointCurve([
        (1.0, 6.0),
        (3.0, 16.0),   # slope = 5
        (5.0, 21.0),   # slope = 2.5 <- violation
    ])

    # Equivalent IncrementalCurve
    pic = IS.IncrementalCurve(ppc)

    # Equivalent AverageRateCurve
    pac = IS.AverageRateCurve(ppc)

    # All should be non-convex
    @test !IS.is_convex(ppc)
    @test !IS.is_convex(pic)
    @test !IS.is_convex(pac)

    # Make convex
    convex_ppc = IS.increasing_curve_convex_approximation(ppc)
    convex_pic = IS.increasing_curve_convex_approximation(pic)
    convex_pac = IS.increasing_curve_convex_approximation(pac)

    # All should now be convex
    @test IS.is_convex(convex_ppc)
    @test IS.is_convex(convex_pic)
    @test IS.is_convex(convex_pac)

    # Convert all to InputOutputCurve and verify they're all convex
    @test IS.is_convex(IS.InputOutputCurve(convex_pic))
    @test IS.is_convex(IS.InputOutputCurve(convex_pac))
end
