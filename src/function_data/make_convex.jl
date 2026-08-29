# CONVEX APPROXIMATION UTILS
# Functions for transforming non-convex curves into convex approximations.

# ============================================================================
# COLINEARITY CLEANUP UTILS
# Functions for removing artificial segmentation from piecewise curves.
# ============================================================================

const CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE = 0.1
const _COLINEARITY_TOLERANCE = 1e-6

"""
    merge_colinear_segments(curve::ValueCurve, ε::Float64 = _COLINEARITY_TOLERANCE, device_name::Union{String, Nothing} = nothing) -> ValueCurve

Merge consecutive colinear segments in a piecewise curve.

Colinear segments are identified by grouping: starting from the first segment in a group,
all subsequent segments whose slope differs from the group's first slope by less than ε
are merged. This cleanup step removes artificial segmentation that can cause false
non-convex detections, unnecessary curve complexity, and unstable numerical behavior.

# Arguments
- `curve`: A piecewise `ValueCurve` to clean up
- `ε`: Tolerance for comparing slopes (default: `$(_COLINEARITY_TOLERANCE)`)
- `device_name`: Optional device name for logging (default: `nothing`)

# Returns
A new curve with colinear segments merged. Endpoints are preserved exactly.
Returns the original curve unchanged if no colinear segments are found.
When segments are merged, an `@info` log is printed indicating the merge occurred.

# Supported curve types
- `PiecewisePointCurve` (InputOutputCurve{PiecewiseLinearData})
- `PiecewiseIncrementalCurve` (IncrementalCurve{PiecewiseStepData})
- `PiecewiseAverageCurve` (AverageRateCurve{PiecewiseStepData})
"""
function merge_colinear_segments end

"""
    merge_colinear_segments(curve::PiecewisePointCurve, ε::Float64 = _COLINEARITY_TOLERANCE, device_name::Union{String, Nothing} = nothing) -> PiecewisePointCurve

Merge colinear segments in a `PiecewisePointCurve` (InputOutputCurve{PiecewiseLinearData}).

Algorithm:
1. Compute slopes between consecutive points
2. Identify groups of consecutive segments with slopes within tolerance ε
3. For each colinear group, keep only the first and last points
4. Preserve first and last endpoints exactly
"""
function merge_colinear_segments(
    curve::InputOutputCurve{PiecewiseLinearData},
    ε::Float64 = _COLINEARITY_TOLERANCE,
    device_name::Union{String, Nothing} = nothing,
)
    fd = get_function_data(curve)
    points = get_points(fd)
    n_points = length(points)

    # Edge cases: 0, 1, or 2 points - no segments to merge
    n_points <= 2 && return curve

    slopes = get_slopes(fd)
    n_slopes = length(slopes)

    # Build list of point indices to keep
    # Always keep first point
    keep_indices = Int[1]

    i = 1
    while i < n_slopes
        # Find the end of the current colinear group
        current_slope = slopes[i]
        j = i
        while j < n_slopes && abs(slopes[j + 1] - current_slope) <= ε
            j += 1
        end

        # Keep the endpoint of this group (which is also the start of the next)
        push!(keep_indices, j + 1)
        i = j + 1
    end

    # Always ensure last point is included
    if keep_indices[end] != n_points
        push!(keep_indices, n_points)
    end

    # If no reduction, return original
    length(keep_indices) == n_points && return curve

    # Log the merge
    gen_msg = isnothing(device_name) ? "" : " for generator $(device_name)"
    @info "Merged colinear segments$(gen_msg)"

    # Build new points array
    new_points = [points[i] for i in keep_indices]

    return InputOutputCurve(PiecewiseLinearData(new_points), get_input_at_zero(curve))
end

"""
    merge_colinear_segments(curve::PiecewiseIncrementalCurve, ε::Float64 = _COLINEARITY_TOLERANCE, device_name::Union{String, Nothing} = nothing) -> PiecewiseIncrementalCurve

Merge colinear segments in a `PiecewiseIncrementalCurve` (IncrementalCurve{PiecewiseStepData}).

For step data, slopes are directly stored as y-coordinates.
Consecutive steps with y-values within tolerance ε are merged.
"""
function merge_colinear_segments(
    curve::IncrementalCurve{PiecewiseStepData},
    ε::Float64 = _COLINEARITY_TOLERANCE,
    device_name::Union{String, Nothing} = nothing,
)
    fd = get_function_data(curve)
    x_coords = get_x_coords(fd)
    y_coords = get_y_coords(fd)  # These are the slopes/marginal rates

    n_segments = length(y_coords)

    # Edge cases: 0 or 1 segment - nothing to merge
    n_segments <= 1 && return curve

    # Build merged x and y coordinates
    new_x = Float64[x_coords[1]]
    new_y = Float64[]

    i = 1
    while i <= n_segments
        current_slope = y_coords[i]
        j = i

        # Find the end of the current colinear group
        while j < n_segments && abs(y_coords[j + 1] - current_slope) <= ε
            j += 1
        end

        # Add the merged segment
        push!(new_x, x_coords[j + 1])  # End x-coordinate of the merged segment
        push!(new_y, current_slope)    # Use the first slope of the group

        i = j + 1
    end

    # If no reduction, return original
    length(new_y) == n_segments && return curve

    # Log the merge
    gen_msg = isnothing(device_name) ? "" : " for generator $(device_name)"
    @info "Merged colinear segments$(gen_msg)"

    return IncrementalCurve(
        PiecewiseStepData(new_x, new_y),
        get_initial_input(curve),
        get_input_at_zero(curve),
    )
end

"""
    merge_colinear_segments(curve::PiecewiseAverageCurve, ε, device_name) -> PiecewiseAverageCurve

Merge colinear segments in a `PiecewiseAverageCurve` (AverageRateCurve{PiecewiseStepData}).

For step data, average rates are directly stored as y-coordinates.
Consecutive steps with y-values within tolerance ε are merged.
"""
function merge_colinear_segments(
    curve::AverageRateCurve{PiecewiseStepData},
    ε::Float64 = _COLINEARITY_TOLERANCE,
    device_name::Union{String, Nothing} = nothing,
)
    fd = get_function_data(curve)
    x_coords = get_x_coords(fd)
    y_coords = get_y_coords(fd)  # These are the average rates

    n_segments = length(y_coords)

    # Edge cases: 0 or 1 segment - nothing to merge
    n_segments <= 1 && return curve

    # Build merged x and y coordinates
    new_x = Float64[x_coords[1]]
    new_y = Float64[]

    i = 1
    while i <= n_segments
        current_rate = y_coords[i]
        j = i

        # Find the end of the current colinear group
        while j < n_segments && abs(y_coords[j + 1] - current_rate) <= ε
            j += 1
        end

        # Add the merged segment
        push!(new_x, x_coords[j + 1])  # End x-coordinate of the merged segment
        push!(new_y, current_rate)     # Use the first rate of the group

        i = j + 1
    end

    # If no reduction, return original
    length(new_y) == n_segments && return curve

    # Log the merge
    gen_msg = isnothing(device_name) ? "" : " for generator $(device_name)"
    @info "Merged colinear segments$(gen_msg)"

    return AverageRateCurve(
        PiecewiseStepData(new_x, new_y),
        get_initial_input(curve),
        get_input_at_zero(curve),
    )
end

# ============================================================================
# CONVEXIFICATION UTILITIES
# ============================================================================

"""
    increasing_curve_convex_approximation(
        curve::ValueCurve;
        weights::Symbol = :length,
        anchor::Symbol = :first,
        merge_colinear::Bool = true,
        device_name::Union{String, Nothing} = nothing,
        negative_slope_atol::Float64 = CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE,
    ) -> ValueCurve

Transform a strictly increasing `ValueCurve` into a convex form, with data quality validation.

This function first validates that the curve data is reasonable and physically meaningful
using [`is_valid_data`](@ref). It also checks that the curve is strictly increasing using
[`is_strictly_increasing`](@ref). If either check fails, the function throws an error.

If the data passes validation and is already convex, returns the original curve
(optionally with colinear segments merged).

If the data passes validation but is non-convex, applies isotonic regression to
produce a convex approximation.

# Supported curve types
- `InputOutputCurve{PiecewiseLinearData}`: Isotonic regression on slopes (core implementation)
- `IncrementalCurve{PiecewiseStepData}`: Converts to IO curve, makes convex, converts back
- `AverageRateCurve{PiecewiseStepData}`: Converts to IO curve, makes convex, converts back
- `CostCurve`: Delegates to underlying ValueCurve, preserves all other fields
- `FuelCurve`: Delegates to underlying ValueCurve, preserves all other fields

Note 1: `IncrementalCurve{LinearFunctionData}` and `AverageRateCurve{LinearFunctionData}` are
intentionally NOT supported. These represent derivatives of quadratic functions and rarely
appear in real data. The arbitrary projection approach used for quadratics is not appropriate.
Note 2: `InputOutputCurve{LinearFunctionData}` is not supported because it never presents convexity issues.
Note 3: `InputOutputCurve{QuadraticFunctionData}` is not supported given that it represents a significant change on the curve

# Arguments
- `curve`: The curve to transform (or `cost` for CostCurve/FuelCurve methods)

# Keyword Arguments
- `weights::Symbol`: Weighting scheme for isotonic regression (default: `:length`)
  - `:length`: weight segments by x-extent (wider segments have more influence)
  - `:uniform`: all segments equally weighted
- `anchor::Symbol`: Point preservation strategy for reconstructing points from new slopes (default: `:first`)
  - `:first`: preserve first point, propagate forward
  - `:last`: preserve last point, propagate backward
  - `:centroid`: minimize total vertical displacement
- `merge_colinear::Bool`: Whether to merge colinear segments before and after convexification (default: `true`).
  Merging before removes artificial segmentation that can affect weighting; merging after cleans up
  any new colinear segments produced by isotonic regression.
- `device_name::Union{String, Nothing}`: Optional device name for logging (default: `nothing`)
- `negative_slope_atol::Float64`: Tolerance for negative slope detection (default: `$CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE`)

# Returns
- The convex curve (original or approximation) if validation passes
- Throws an error if validation fails (with message indicating reason and device name if provided)
"""
function increasing_curve_convex_approximation end

"""
    _validate_increasing_curve(curve, device_name, negative_slope_atol) -> Union{String, Nothing}

Internal helper to validate that a curve has valid data and is strictly increasing.
Returns `nothing` if validation passes, or an error message string if it fails.

# Arguments
- `curve`: The curve to validate
- `device_name::Union{String, Nothing}`: Optional device name for error messages
- `negative_slope_atol::Float64`: Tolerance for negative slope detection
"""
function _validate_increasing_curve(
    curve,
    device_name::Union{String, Nothing},
    negative_slope_atol::Float64,
)
    gen_msg = isnothing(device_name) ? "" : " for generator $(device_name)"

    if !is_valid_data(curve)
        return "Invalid curve data$(gen_msg): data quality validation failed"
    end

    if !is_strictly_increasing(curve, negative_slope_atol)
        return "Invalid curve data$(gen_msg): curve is not strictly increasing"
    end

    return nothing
end

"""
    increasing_curve_convex_approximation(curve::InputOutputCurve{PiecewiseLinearData}; kwargs...)

Core implementation for piecewise linear curves. Applies isotonic regression on slopes
to produce a convex approximation. Other curve types delegate to this method.

When `merge_colinear=true`, colinear segments are merged both before and after convexification:
- Before: removes artificial segmentation that can affect weighting and produce suboptimal results
- After: cleans up any new colinear segments produced by isotonic regression
"""
function increasing_curve_convex_approximation(
    curve::InputOutputCurve{PiecewiseLinearData};
    weights::Symbol = :length,
    anchor::Symbol = :first,
    merge_colinear::Bool = true,
    device_name::Union{String, Nothing} = nothing,
    negative_slope_atol::Float64 = CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE,
)
    gen_msg = isnothing(device_name) ? "" : " for generator $(device_name)"

    # Validate data quality and monotonicity
    validation_error =
        _validate_increasing_curve(curve, device_name, negative_slope_atol)
    if !isnothing(validation_error)
        error(validation_error)
    end

    # Optionally merge colinear segments before processing
    # This removes artificial segmentation that can affect weighting
    working_curve = if merge_colinear
        merge_colinear_segments(curve, _COLINEARITY_TOLERANCE, device_name)
    else
        curve
    end

    # If already convex, return
    if is_convex(working_curve)
        return working_curve
    end

    fd = get_function_data(working_curve)
    points = get_points(fd)
    x_coords = get_x_coords(fd)
    slopes = get_slopes(fd)

    w = _compute_convex_weights(x_coords, weights)
    new_slopes = isotonic_regression(slopes, w)
    new_points = _reconstruct_points(points, new_slopes, anchor)

    @info "Transformed non-convex InputOutputCurve to convex approximation$(gen_msg)"
    result =
        InputOutputCurve(PiecewiseLinearData(new_points), get_input_at_zero(working_curve))

    # Clean up any colinear segments produced by isotonic regression
    if merge_colinear
        return merge_colinear_segments(result, _COLINEARITY_TOLERANCE, device_name)
    else
        return result
    end
end

"""
    increasing_curve_convex_approximation(curve::IncrementalCurve{PiecewiseStepData}; kwargs)

Converts to `InputOutputCurve`, applies convexification, and converts back.
"""
function increasing_curve_convex_approximation(
    curve::IncrementalCurve{PiecewiseStepData};
    weights::Symbol = :length,
    anchor::Symbol = :first,
    merge_colinear::Bool = true,
    device_name::Union{String, Nothing} = nothing,
    negative_slope_atol::Float64 = CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE,
)
    io_curve = InputOutputCurve(curve)
    convex_io = increasing_curve_convex_approximation(
        io_curve;
        weights = weights,
        anchor = anchor,
        merge_colinear = merge_colinear,
        device_name = device_name,
        negative_slope_atol = negative_slope_atol,
    )
    return IncrementalCurve(convex_io)
end

"""
    increasing_curve_convex_approximation(curve::AverageRateCurve{PiecewiseStepData}; kwargs...)

Converts to `InputOutputCurve`, applies convexification, and converts back.
"""
function increasing_curve_convex_approximation(
    curve::AverageRateCurve{PiecewiseStepData};
    weights::Symbol = :length,
    anchor::Symbol = :first,
    merge_colinear::Bool = true,
    device_name::Union{String, Nothing} = nothing,
    negative_slope_atol::Float64 = CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE,
)
    io_curve = InputOutputCurve(curve)
    convex_io = increasing_curve_convex_approximation(
        io_curve;
        weights = weights,
        anchor = anchor,
        merge_colinear = merge_colinear,
        device_name = device_name,
        negative_slope_atol = negative_slope_atol,
    )
    return AverageRateCurve(convex_io)
end

# ProductionVariableCostCurve methods (CostCurve, FuelCurve)
# These delegate to the underlying ValueCurve and reconstruct the wrapper.
"""
    increasing_curve_convex_approximation(cost::CostCurve; kwargs...)

Delegates to underlying ValueCurve. Preserves `power_units` and `vom_cost`.
"""
function increasing_curve_convex_approximation(
    cost::CostCurve;
    weights::Symbol = :length,
    anchor::Symbol = :first,
    merge_colinear::Bool = true,
    device_name::Union{String, Nothing} = nothing,
    negative_slope_atol::Float64 = CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE,
)
    convex_vc = increasing_curve_convex_approximation(
        get_value_curve(cost);
        weights = weights,
        anchor = anchor,
        merge_colinear = merge_colinear,
        device_name = device_name,
        negative_slope_atol = negative_slope_atol,
    )
    return CostCurve(convex_vc, get_power_units(cost), get_vom_cost(cost))
end

"""
    increasing_curve_convex_approximation(cost::FuelCurve; kwargs...)

Delegates to underlying ValueCurve. Preserves `power_units`, `fuel_cost`, `startup_fuel_offtake`, `vom_cost`.
"""
function increasing_curve_convex_approximation(
    cost::FuelCurve;
    weights::Symbol = :length,
    anchor::Symbol = :first,
    merge_colinear::Bool = true,
    device_name::Union{String, Nothing} = nothing,
    negative_slope_atol::Float64 = CONVEXIFICATION_NEGATIVE_SLOPE_TOLERANCE,
)
    convex_vc = increasing_curve_convex_approximation(
        get_value_curve(cost);
        weights = weights,
        anchor = anchor,
        merge_colinear = merge_colinear,
        device_name = device_name,
        negative_slope_atol = negative_slope_atol,
    )
    return FuelCurve(;
        value_curve = convex_vc,
        power_units = get_power_units(cost),
        fuel_cost = cost.fuel_cost,
        fuel_cost_time_series = cost.fuel_cost_time_series,
        startup_fuel_offtake = cost.startup_fuel_offtake,
        vom_cost = get_vom_cost(cost),
    )
end

"""
    _reconstruct_points(original_points, new_slopes, anchor) -> Vector{XY_COORDS}

Reconstruct points from new slopes, preserving the anchor point.

After isotonic regression modifies the slopes, we need to reconstruct the y-coordinates.
The `anchor` parameter determines which point to preserve exactly:
- `:first` - preserve first point, propagate forward using new slopes
- `:last` - preserve last point, propagate backward using new slopes
- `:centroid` - minimize total vertical displacement from original points
"""
function _reconstruct_points(
    original_points::Vector{XY_COORDS},
    new_slopes::Vector{Float64},
    anchor::Symbol,
)
    n = length(original_points)

    if anchor === :first
        new_points = Vector{XY_COORDS}(undef, n)
        new_points[1] = original_points[1]
        for i in 2:n
            dx = original_points[i].x - original_points[i - 1].x
            new_y = new_points[i - 1].y + new_slopes[i - 1] * dx
            new_points[i] = (x = original_points[i].x, y = new_y)
        end

    elseif anchor === :last
        new_points = Vector{XY_COORDS}(undef, n)
        new_points[n] = original_points[n]
        for i in (n - 1):-1:1
            dx = original_points[i + 1].x - original_points[i].x
            new_y = new_points[i + 1].y - new_slopes[i] * dx
            new_points[i] = (x = original_points[i].x, y = new_y)
        end

    elseif anchor === :centroid
        forward_points = _reconstruct_points(original_points, new_slopes, :first)
        shift = 0.0
        for i in 1:n
            shift += original_points[i].y - forward_points[i].y
        end
        shift /= n
        new_points = XY_COORDS[(x = p.x, y = p.y + shift) for p in forward_points]
    else
        throw(ArgumentError("anchor must be :first, :last, or :centroid"))
    end

    return new_points
end

"""
    approximation_error(original, convexified; metric=:L2, weights=:length) -> Float64

Compute the error between original piecewise data and its convex approximation.

This is useful for assessing the quality of a convexification: a lower error means
the convex approximation is closer to the original non-convex curve.

Both arguments must have the same number of segments (same x-coordinates). When using
`increasing_curve_convex_approximation`, pass `merge_colinear=false` to preserve segment count for error computation.

# Arguments
- `original`: original `PiecewiseStepData` or `PiecewiseLinearData`
- `convexified`: the convex approximation (same type and same x-coordinates as original)
- `metric`: error metric to use
  - `:L2` (default): weighted root mean square error
  - `:L1`: weighted mean absolute error
  - `:Linf`: maximum absolute error (unweighted)
- `weights::Symbol`: weighting scheme for the error computation
  - `:length` (default): weight by segment x-extent
  - `:uniform`: equal weights for all segments

# Returns
The computed error as a `Float64`. Returns `0.0` if the curves are identical.
"""
function approximation_error end

function approximation_error(
    original::PiecewiseStepData,
    convexified::PiecewiseStepData;
    metric::Symbol = :L2,
    weights::Symbol = :length,
)
    y_orig = get_y_coords(original)
    y_convex = get_y_coords(convexified)
    length(y_orig) == length(y_convex) || throw(
        ArgumentError(
            "original and convexified must have the same number of segments " *
            "(got $(length(y_orig)) and $(length(y_convex))). " *
            "Use increasing_curve_convex_approximation with merge_colinear=false to preserve segment count.",
        ),
    )
    w = _compute_convex_weights(get_x_coords(original), weights)

    diff = y_orig .- y_convex

    if metric === :L2
        return norm(sqrt.(w) .* diff) / sqrt(sum(w))
    elseif metric === :L1
        return dot(w, abs.(diff)) / sum(w)
    elseif metric === :Linf
        return norm(diff, Inf)
    else
        throw(ArgumentError("metric must be :L2, :L1, or :Linf"))
    end
end

function approximation_error(
    original::PiecewiseLinearData,
    convexified::PiecewiseLinearData;
    metric::Symbol = :L2,
    weights::Symbol = :length,
)
    # For PiecewiseLinearData, compare slopes since that's what convexification modifies
    slopes_orig = get_slopes(original)
    slopes_convex = get_slopes(convexified)
    length(slopes_orig) == length(slopes_convex) || throw(
        ArgumentError(
            "original and convexified must have the same number of segments " *
            "(got $(length(slopes_orig)) and $(length(slopes_convex))). " *
            "Use increasing_curve_convex_approximation with merge_colinear=false to preserve segment count.",
        ),
    )
    w = _compute_convex_weights(get_x_coords(original), weights)

    diff = slopes_orig .- slopes_convex

    if metric === :L2
        return norm(sqrt.(w) .* diff) / sqrt(sum(w))
    elseif metric === :L1
        return dot(w, abs.(diff)) / sum(w)
    elseif metric === :Linf
        return norm(diff, Inf)
    else
        throw(ArgumentError("metric must be :L2, :L1, or :Linf"))
    end
end
