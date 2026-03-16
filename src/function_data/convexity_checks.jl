# CONVEXITY CHECKING UTILITIES
# Functions for analyzing convexity properties of FunctionData and ValueCurve types.

const _STRICT_SLOPE_COMPARISON_ATOL = 1e-10

# ============================================================================
# DATA QUALITY VALIDATION
# Functions for detecting fundamentally invalid curve data.
# ============================================================================

# Configurable thresholds for data quality checks
const _MAX_REASONABLE_SLOPE = 1e8      # Maximum reasonable slope
const _MAX_REASONABLE_COST = 1e10      # Maximum reasonable cost value
const _MIN_REASONABLE_COST = -1e6      # Allow small negative costs for edge cases, but flag large negatives

"""
    is_valid_data(data::FunctionData) -> Bool
    is_valid_data(curve::ValueCurve) -> Bool

Check whether the data contains reasonable values. Returns `false` and logs an error
when issues are detected (e.g., non-ascending x-coordinates, unreasonably large slopes
or values, large negative values).

Does not check slope direction — use [`is_strictly_increasing`](@ref) /
[`is_strictly_decreasing`](@ref) for that.
"""
function is_valid_data end

# LinearFunctionData - check proportional term (slope) and constant term
function is_valid_data(fd::LinearFunctionData)
    slope = get_proportional_term(fd)
    constant = get_constant_term(fd)

    if abs(slope) > _MAX_REASONABLE_SLOPE
        @error "Data quality issue: unreasonably large slope detected" slope max_allowed =
            _MAX_REASONABLE_SLOPE
        return false
    end

    if constant < _MIN_REASONABLE_COST
        @error "Data quality issue: negative cost detected" constant
        return false
    end

    if abs(constant) > _MAX_REASONABLE_COST
        @error "Data quality issue: unreasonable cost magnitude detected"
        return false
    end

    return true
end

# QuadraticFunctionData - check quadratic term, proportional term, and constant
function is_valid_data(fd::QuadraticFunctionData)
    quadratic = get_quadratic_term(fd)
    proportional = get_proportional_term(fd)
    constant = get_constant_term(fd)

    # Check for excessive quadratic term (translates to very steep curves)
    if abs(quadratic) > _MAX_REASONABLE_SLOPE
        @error "Data quality issue: unreasonably large quadratic term detected" quadratic max_allowed =
            _MAX_REASONABLE_SLOPE
        return false
    end

    # Check for excessive proportional term
    if abs(proportional) > _MAX_REASONABLE_SLOPE
        @error "Data quality issue: unreasonably large proportional term detected" proportional max_allowed =
            _MAX_REASONABLE_SLOPE
        return false
    end

    if constant < _MIN_REASONABLE_COST
        @error "Data quality issue: negative constant cost detected" constant
        return false
    end

    if abs(constant) > _MAX_REASONABLE_COST
        @error "Data quality issue: unreasonable cost magnitude detected" constant max_allowed =
            _MAX_REASONABLE_COST
        return false
    end

    return true
end

# Helper to check x-coordinates are strictly ascending
function _check_x_coords_ascending(x_coords::Vector{Float64})
    for i in 1:(length(x_coords) - 1)
        if x_coords[i] >= x_coords[i + 1]
            @error "Data quality issue: x-coordinates not in ascending order" x_i =
                x_coords[i] x_next = x_coords[i + 1] index = i
            return false
        end
    end
    return true
end

# PiecewiseLinearData - check x-coords ordering, slopes, and y-values
function is_valid_data(fd::PiecewiseLinearData)
    x_coords = get_x_coords(fd)
    slopes = get_slopes(fd)
    y_coords = get_y_coords(fd)

    # Check x-coordinates are ascending
    if !_check_x_coords_ascending(x_coords)
        return false
    end

    # Check for excessive slopes (using abs to handle both positive and negative)
    for (i, slope) in enumerate(slopes)
        if abs(slope) > _MAX_REASONABLE_SLOPE
            @error "Data quality issue: unreasonably large slope detected in segment $i" slope max_allowed =
                _MAX_REASONABLE_SLOPE segment = i
            return false
        end
    end

    # Check for negative costs (y-values)
    for (i, y) in enumerate(y_coords)
        if y < _MIN_REASONABLE_COST
            @error "Data quality issue: negative cost detected at point $i" cost = y point =
                i
            return false
        end
    end

    # Check for excessive cost magnitudes
    for (i, y) in enumerate(y_coords)
        if abs(y) > _MAX_REASONABLE_COST
            @error "Data quality issue: unreasonable cost magnitude at point $i" cost =
                y max_allowed = _MAX_REASONABLE_COST point = i
            return false
        end
    end

    return true
end

# PiecewiseStepData - y-coords are slopes/rates
function is_valid_data(fd::PiecewiseStepData)
    x_coords = get_x_coords(fd)
    y_coords = get_y_coords(fd)  # These are marginal rates/slopes

    # Check x-coordinates are ascending
    if !_check_x_coords_ascending(x_coords)
        return false
    end

    # Check for excessive slopes (using abs to handle both positive and negative)
    for (i, slope) in enumerate(y_coords)
        if abs(slope) > _MAX_REASONABLE_SLOPE
            @error "Data quality issue: unreasonably large marginal rate in segment $i" rate =
                slope max_allowed = _MAX_REASONABLE_SLOPE segment = i
            return false
        end
    end

    return true
end

"""
    is_valid_data(curve::ValueCurve) -> Bool

Delegates to the underlying `FunctionData`. For `AverageRateCurve`, converts to
`InputOutputCurve` first since average rates are not the same as slopes.
"""
is_valid_data(curve::InputOutputCurve) = is_valid_data(get_function_data(curve))
is_valid_data(curve::IncrementalCurve) = is_valid_data(get_function_data(curve))

# AverageRateCurve: average rates != slopes, so convert to get actual slope information
function is_valid_data(curve::AverageRateCurve)
    # Convert to InputOutputCurve to get actual cost values and slopes
    io_curve = InputOutputCurve(curve)
    return is_valid_data(io_curve)
end

# ============================================================================
# MONOTONICITY HELPER METHODS
# Functions for checking if curves are strictly increasing or decreasing.
# Note: QuadraticFunctionData is excluded as slope sign varies with x.
# ============================================================================

"""
    is_strictly_increasing(data::FunctionData, atol=$(_STRICT_SLOPE_COMPARISON_ATOL)) -> Bool
    is_strictly_increasing(curve::ValueCurve, atol=$(_STRICT_SLOPE_COMPARISON_ATOL)) -> Bool

Returns `true` if all slopes are non-negative (>= -atol).

Defined for `LinearFunctionData`, `PiecewiseLinearData`, `PiecewiseStepData`, and
their `ValueCurve` wrappers. Not defined for `QuadraticFunctionData` (slope varies
with x). `AverageRateCurve` converts to `InputOutputCurve` first.
"""
function is_strictly_increasing end

# FunctionData implementations
# LinearFunctionData uses fixed small tolerance - atol parameter ignored
is_strictly_increasing(
    fd::LinearFunctionData,
    atol::Float64 = _STRICT_SLOPE_COMPARISON_ATOL,
) =
    get_proportional_term(fd) >= -_STRICT_SLOPE_COMPARISON_ATOL

# PiecewiseLinearData and PiecewiseStepData use configurable tolerance
is_strictly_increasing(
    fd::PiecewiseLinearData,
    atol::Float64 = _STRICT_SLOPE_COMPARISON_ATOL,
) =
    all(s -> s >= -atol, get_slopes(fd))

is_strictly_increasing(
    fd::PiecewiseStepData,
    atol::Float64 = _STRICT_SLOPE_COMPARISON_ATOL,
) =
    all(r -> r >= -atol, get_y_coords(fd))

# ValueCurve implementations
is_strictly_increasing(
    curve::InputOutputCurve,
    atol::Float64 = _STRICT_SLOPE_COMPARISON_ATOL,
) =
    is_strictly_increasing(get_function_data(curve), atol)

is_strictly_increasing(
    curve::IncrementalCurve,
    atol::Float64 = _STRICT_SLOPE_COMPARISON_ATOL,
) =
    is_strictly_increasing(get_function_data(curve), atol)

is_strictly_increasing(
    curve::AverageRateCurve,
    atol::Float64 = _STRICT_SLOPE_COMPARISON_ATOL,
) =
    is_strictly_increasing(InputOutputCurve(curve), atol)

"""
    is_strictly_decreasing(data::FunctionData) -> Bool
    is_strictly_decreasing(curve::ValueCurve) -> Bool

Returns `true` if all slopes are non-positive (<= atol).

Same type coverage as [`is_strictly_increasing`](@ref).
"""
function is_strictly_decreasing end

# FunctionData implementations
is_strictly_decreasing(fd::LinearFunctionData) =
    get_proportional_term(fd) <= _STRICT_SLOPE_COMPARISON_ATOL

is_strictly_decreasing(fd::PiecewiseLinearData) =
    all(s -> s <= _STRICT_SLOPE_COMPARISON_ATOL, get_slopes(fd))

is_strictly_decreasing(fd::PiecewiseStepData) =
    all(r -> r <= _STRICT_SLOPE_COMPARISON_ATOL, get_y_coords(fd))

# ValueCurve implementations
is_strictly_decreasing(curve::InputOutputCurve) =
    is_strictly_decreasing(get_function_data(curve))

is_strictly_decreasing(curve::IncrementalCurve) =
    is_strictly_decreasing(get_function_data(curve))

is_strictly_decreasing(curve::AverageRateCurve) =
    is_strictly_decreasing(InputOutputCurve(curve))

# ============================================================================
# CONVEXITY CHECKING
# ============================================================================

function _slope_convexity_check(slopes::Vector{Float64})
    for ix in 1:(length(slopes) - 1)
        if slopes[ix] > slopes[ix + 1] + _STRICT_SLOPE_COMPARISON_ATOL
            @debug slopes
            return false
        end
    end
    return true
end

function _slope_concavity_check(slopes::Vector{Float64})
    for ix in 1:(length(slopes) - 1)
        if slopes[ix] < slopes[ix + 1] - _STRICT_SLOPE_COMPARISON_ATOL
            return false
        end
    end
    return true
end

"""
    is_convex(data::FunctionData) -> Bool

Returns `true` if the function data is convex, `false` otherwise.
Linear functions (straight lines) are considered convex.

- `LinearFunctionData`: Always returns `true`
- `QuadraticFunctionData`: Returns `true` if quadratic_term ≥ 0
- `PiecewiseLinearData`: Returns `true` if slopes are non-decreasing
- `PiecewiseStepData`: Returns `true` if y-coordinates are non-decreasing
"""
is_convex(::LinearFunctionData) = true

is_convex(f::QuadraticFunctionData) =
    get_quadratic_term(f) >= -_STRICT_SLOPE_COMPARISON_ATOL

is_convex(pwl::PiecewiseLinearData) =
    _slope_convexity_check(get_slopes(pwl))

is_convex(pwl::PiecewiseStepData) =
    _slope_convexity_check(get_y_coords(pwl))

"""
    is_concave(data::FunctionData) -> Bool

Returns `true` if the function data is concave, `false` otherwise.
Linear functions (straight lines) are considered concave.

- `LinearFunctionData`: Always returns `true`
- `QuadraticFunctionData`: Returns `true` if quadratic_term ≤ 0
- `PiecewiseLinearData`: Returns `true` if slopes are non-increasing
- `PiecewiseStepData`: Returns `true` if y-coordinates are non-increasing
"""
is_concave(::LinearFunctionData) = true

is_concave(f::QuadraticFunctionData) = get_quadratic_term(f) <= 0.0

is_concave(pwl::PiecewiseLinearData) =
    _slope_concavity_check(get_slopes(pwl))

is_concave(pwl::PiecewiseStepData) =
    _slope_concavity_check(get_y_coords(pwl))

"""
    is_convex(curve::ValueCurve) -> Bool

Check if a `ValueCurve` is convex. Delegates to the underlying `FunctionData`.
`AverageRateCurve` converts to `InputOutputCurve` first (average rates ≠ slopes).
"""
is_convex(curve::InputOutputCurve) = is_convex(get_function_data(curve))
is_convex(curve::IncrementalCurve) = is_convex(get_function_data(curve))
is_convex(curve::AverageRateCurve) = is_convex(InputOutputCurve(curve))

"""
    is_concave(curve::ValueCurve) -> Bool

Check if a `ValueCurve` is concave. Delegates to the underlying `FunctionData`.
`AverageRateCurve` converts to `InputOutputCurve` first (average rates ≠ slopes).
"""
is_concave(curve::InputOutputCurve) = is_concave(get_function_data(curve))
is_concave(curve::IncrementalCurve) = is_concave(get_function_data(curve))
is_concave(curve::AverageRateCurve) = is_concave(InputOutputCurve(curve))

# ============================================================================
# TIME-SERIES-BACKED CURVE CONVEXITY CHECKS
# ============================================================================

"""
    is_convex(::TimeSeriesInputOutputCurve, data_at_t::StaticFunctionData) -> Bool
    is_convex(::TimeSeriesIncrementalCurve, data_at_t::StaticFunctionData) -> Bool
    is_convex(::TimeSeriesAverageRateCurve, data_at_t::StaticFunctionData, initial_input::Float64) -> Bool

Check convexity of a time-series-backed curve given the resolved data at a specific
timestep. `TimeSeriesAverageRateCurve` requires `initial_input` to reconstruct the
`AverageRateCurve` for conversion to `InputOutputCurve`.
"""
is_convex(
    ::Union{TimeSeriesInputOutputCurve, TimeSeriesIncrementalCurve},
    data_at_t::StaticFunctionData,
) = is_convex(data_at_t)
function is_convex(
    ::TimeSeriesAverageRateCurve,
    data_at_t::StaticFunctionData,
    initial_input::Float64,
)
    return is_convex(InputOutputCurve(AverageRateCurve(data_at_t, initial_input)))
end

"""
    is_concave(::TimeSeriesInputOutputCurve, data_at_t::StaticFunctionData) -> Bool
    is_concave(::TimeSeriesIncrementalCurve, data_at_t::StaticFunctionData) -> Bool
    is_concave(::TimeSeriesAverageRateCurve, data_at_t::StaticFunctionData, initial_input::Float64) -> Bool

Check concavity of a time-series-backed curve. See [`is_convex`](@ref) for details.
"""
is_concave(
    ::Union{TimeSeriesInputOutputCurve, TimeSeriesIncrementalCurve},
    data_at_t::StaticFunctionData,
) = is_concave(data_at_t)
function is_concave(
    ::TimeSeriesAverageRateCurve,
    data_at_t::StaticFunctionData,
    initial_input::Float64,
)
    return is_concave(InputOutputCurve(AverageRateCurve(data_at_t, initial_input)))
end
