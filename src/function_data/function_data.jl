"""
Raw mathematical function data — numbers with no units or interpretation attached.

`FunctionData` stores the coefficients or point tables that define a mathematical function
`f(x)`. It carries no information about *what* `x` and `y` represent (cost? fuel? marginal
rate?). That semantic layer lives in the [`ValueCurve`](@ref) that wraps this.

Pick the subtype that matches how your source data is shaped:

| Type | Function shape | y stores |
|---|---|---|
| [`LinearFunctionData`](@ref) | `f(x) = m·x + b` | values |
| [`QuadraticFunctionData`](@ref) | `f(x) = q·x² + m·x + b` | values |
| [`PiecewiseLinearData`](@ref) | piecewise linear through (x, y) points | **absolute values** at each x |
| [`PiecewiseStepData`](@ref) | piecewise constant between x endpoints | **slopes** over each segment |

The [`TimeSeriesFunctionData`](@ref) subtypes mirror these but hold a
[`TimeSeriesKey`](@ref) reference instead of the numbers directly.
"""
abstract type FunctionData end

"""
    StaticFunctionData <: FunctionData

Abstract supertype for `FunctionData` variants that hold their numerical data inline
(as opposed to [`TimeSeriesFunctionData`](@ref), which holds a time series reference).
"""
abstract type StaticFunctionData <: FunctionData end

"""
Data for a linear function: `f(x) = proportional_term * x + constant_term`.

# Arguments
- `proportional_term::Float64`: slope of the function
- `constant_term::Float64`: intercept. Defaults to `0.0`.
"""
@kwdef struct LinearFunctionData <: StaticFunctionData
    proportional_term::Float64
    constant_term::Float64
end

LinearFunctionData(proportional_term) = LinearFunctionData(proportional_term, 0.0)

get_proportional_term(fd::LinearFunctionData) = fd.proportional_term
get_constant_term(fd::LinearFunctionData) = fd.constant_term

function _transform_linear_vector_for_hdf(data::Vector{LinearFunctionData})
    transfd_data = Vector{NTuple{2, Float64}}(undef, length(data))
    for (ix, fd) in enumerate(data)
        transfd_data[ix] = (get_proportional_term(fd), get_constant_term(fd))
    end
    return transfd_data
end

function transform_array_for_hdf(data::Vector{LinearFunctionData})
    return transform_array_for_hdf(_transform_linear_vector_for_hdf(data))
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, Vector{LinearFunctionData}},
)
    transfd_data =
        sizehint!(SortedDict{Dates.DateTime, Vector{NTuple{2, Float64}}}(), length(data))
    for (k, fd) in data
        transfd_data[k] = _transform_linear_vector_for_hdf(fd)
    end
    return transform_array_for_hdf(transfd_data)
end

function Base.show(io::IO, ::MIME"text/plain", fd::LinearFunctionData)
    get(io, :compact, false)::Bool || print(io, "$(typeof(fd)) representing function ")
    print(io, "f(x) = $(fd.proportional_term) x + $(fd.constant_term)")
end

"""
Data for a quadratic function: `f(x) = quadratic_term * x^2 + proportional_term * x + constant_term`.

# Arguments
- `quadratic_term::Float64`: quadratic coefficient (≥ 0 for a convex function)
- `proportional_term::Float64`: linear coefficient
- `constant_term::Float64`: constant term
"""
@kwdef struct QuadraticFunctionData <: StaticFunctionData
    quadratic_term::Float64
    proportional_term::Float64
    constant_term::Float64
end

get_quadratic_term(fd::QuadraticFunctionData) = fd.quadratic_term
get_proportional_term(fd::QuadraticFunctionData) = fd.proportional_term
get_constant_term(fd::QuadraticFunctionData) = fd.constant_term

function _transform_quadratic_vector_for_hdf(data::Vector{QuadraticFunctionData})
    transfd_data = Vector{NTuple{3, Float64}}(undef, length(data))
    for (ix, fd) in enumerate(data)
        transfd_data[ix] =
            (get_quadratic_term(fd), get_proportional_term(fd), get_constant_term(fd))
    end
    return transfd_data
end

function transform_array_for_hdf(data::Vector{QuadraticFunctionData})
    return transform_array_for_hdf(_transform_quadratic_vector_for_hdf(data))
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, Vector{QuadraticFunctionData}},
)
    transfd_data =
        sizehint!(SortedDict{Dates.DateTime, Vector{NTuple{3, Float64}}}(), length(data))
    for (k, fd) in data
        transfd_data[k] = _transform_quadratic_vector_for_hdf(fd)
    end
    return transform_array_for_hdf(transfd_data)
end

function _validate_piecewise_x(x_coords::Vector)
    (length(x_coords) < 2) &&
        throw(ArgumentError("Must specify at least two x-coordinates"))
    # This could be generalized to allow NaNs in more places
    if !(issorted(x_coords) || (isnan(first(x_coords)) && issorted(x_coords[2:end])))
        throw(ArgumentError("Piecewise x-coordinates must be ascending, got $x_coords"))
    end
end

function Base.show(io::IO, ::MIME"text/plain", fd::QuadraticFunctionData)
    get(io, :compact, false)::Bool || print(io, "$(typeof(fd)) representing function ")
    print(
        io,
        "f(x) = $(fd.quadratic_term) x^2 + $(fd.proportional_term) x + $(fd.constant_term)",
    )
end

"""
Data for a piecewise linear function defined by (x, y) **value** points.

The function linearly interpolates between consecutive points. **The y-values are
absolute values, not slopes.** Two points define one segment, three define two, etc.

If your data gives per-segment rates between breakpoints rather than values at each
point, use [`PiecewiseStepData`](@ref) instead.

# Arguments
- `points::Vector{@NamedTuple{x::Float64, y::Float64}}`: (input, output) pairs in ascending
  x order
"""
@kwdef struct PiecewiseLinearData <: StaticFunctionData
    points::Vector{XY_COORDS}

    function PiecewiseLinearData(points::Vector{<:NamedTuple{(:x, :y)}})
        _validate_piecewise_x(first.(points))
        return new(points)
    end
end

function PiecewiseLinearData(points::Vector{<:NamedTuple})
    throw(
        ArgumentError(
            "If constructing PiecewiseLinearData with NamedTuples, points must have type Vector{<:NamedTuple{(:x, :y)}}; got $(typeof(points))",
        ),
    )
end

function _convert_to_xy_coords(point)
    # Need to be able to handle dicts for deserialization
    if point isa AbstractDict
        (keys(point) == Set(["x", "y"])) && return (x = point["x"], y = point["y"])
        throw(
            ArgumentError(
                "If constructing PiecewiseLinearData with dictionaries, keys must be [\"x\", \"y\"]; got $(collect(keys(point)))",
            ),
        )
    end
    return NamedTuple{(:x, :y)}(point)
end

function PiecewiseLinearData(points::AbstractVector)
    PiecewiseLinearData(_convert_to_xy_coords.(points))
end

"Get the points that define the piecewise data"
get_points(data::PiecewiseLinearData) = data.points

"Get the x-coordinates of the points that define the piecewise data"
get_x_coords(data::PiecewiseLinearData) = [p.x for p in get_points(data)]

"Get the y-coordinates of the points that define the PiecewiseLinearData"
get_y_coords(data::PiecewiseLinearData) = [p.y for p in get_points(data)]

function _get_slopes(vc::Vector{XY_COORDS})
    slopes = Vector{Float64}(undef, length(vc) - 1)
    (prev_x, prev_y) = vc[1]
    for (i, (comp_x, comp_y)) in enumerate(vc[2:end])
        slopes[i] = (comp_y - prev_y) / (comp_x - prev_x)
        (prev_x, prev_y) = (comp_x, comp_y)
    end
    return slopes
end

_get_x_lengths(x_coords) = x_coords[2:end] .- x_coords[1:(end - 1)]

"""
Calculates the slopes of the line segments defined by the PiecewiseLinearData,
returning one fewer slope than the number of underlying points.
"""
function get_slopes(pwl::PiecewiseLinearData)
    return _get_slopes(get_points(pwl))
end

function _transform_pwl_linear_vector_for_hdf(data::Vector{PiecewiseLinearData})
    transfd_data = Vector{Vector{NTuple{2, Float64}}}(undef, length(data))
    for (ix, fd) in enumerate(data)
        transfd_data[ix] = NTuple{2, Float64}.(get_points(fd))
    end
    return transfd_data
end

function transform_array_for_hdf(data::Vector{PiecewiseLinearData})
    return transform_array_for_hdf(_transform_pwl_linear_vector_for_hdf(data))
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, Vector{PiecewiseLinearData}},
)
    transfd_data = sizehint!(
        SortedDict{Dates.DateTime, Vector{Vector{Tuple{Float64, Float64}}}}(),
        length(data),
    )
    for (k, fd) in data
        transfd_data[k] = _transform_pwl_linear_vector_for_hdf(fd)
    end
    return transform_array_for_hdf(transfd_data)
end

function Base.show(io::IO, ::MIME"text/plain", fd::PiecewiseLinearData)
    if get(io, :compact, false)::Bool
        print(io, "piecewise linear ")
    else
        print(io, "$(typeof(fd)) representing piecewise linear function ")
    end
    print(io, "y = f(x) connecting points:")
    for point in fd.points
        print(io, "\n  $point")
    end
end

"""
Data for a step function (piecewise constant) defined by endpoint x-coordinates and
per-segment y-values.

Each y-value is constant over a segment. **The y-values are per-segment rates, not
absolute values.** Two x-coordinates and one y-coordinate define one segment; three
x-coordinates and two y-coordinates define two, etc.

If your data gives absolute values at each point, use [`PiecewiseLinearData`](@ref) instead.

# Arguments
- `x_coords::Vector{Float64}`: x-coordinates of the segment endpoints, must be ascending
  with at least 2 elements
- `y_coords::Vector{Float64}`: y-value for each segment. Must have exactly
  `length(x_coords) - 1` elements.
"""
@kwdef struct PiecewiseStepData <: StaticFunctionData
    x_coords::Vector{Float64}
    y_coords::Vector{Float64}

    function PiecewiseStepData(x_coords, y_coords)
        if length(y_coords) == length(x_coords)
            # To make the lengths match for HDF serialization, we prepend NaN to y_coords
            isnan(first(y_coords)) && return PiecewiseStepData(x_coords, y_coords[2:end])
            # To leave x_coords[1] undefined, must explicitly pass in NaN
        end
        _validate_piecewise_x(x_coords)
        (length(y_coords) != length(x_coords) - 1) &&
            throw(ArgumentError("Must specify one fewer y-coordinates than x-coordinates"))
        return new(x_coords, y_coords)
    end
end

# For HDF deserialization
PiecewiseStepData(data::AbstractMatrix) = PiecewiseStepData(data[:, 1], data[:, 2])

"Get the x-coordinates of the points that define the piecewise data"
get_x_coords(data::PiecewiseStepData) = data.x_coords

"Get the y-coordinates of the segments in the PiecewiseStepData"
get_y_coords(data::PiecewiseStepData) = data.y_coords

function running_sum(data::PiecewiseStepData)
    slopes = get_y_coords(data)
    x_coords = get_x_coords(data)
    points = Vector{XY_COORDS}(undef, length(x_coords))
    running_y = 0.0
    points[1] = (x = x_coords[1], y = running_y)
    for (i, (prev_slope, this_x, dx)) in
        enumerate(zip(slopes, x_coords[2:end], get_x_lengths(data)))
        running_y += prev_slope * dx
        points[i + 1] = (x = this_x, y = running_y)
    end
    return points
end

function _transform_pwl_step_vector_hdf(data::Vector{PiecewiseStepData})
    transfd_data = Vector{Matrix{Float64}}(undef, length(data))
    for (ix, fd) in enumerate(data)
        x_coords = get_x_coords(fd)
        y_coords = vcat(NaN, get_y_coords(fd))
        transfd_data[ix] = hcat(x_coords, y_coords)
    end
    return transfd_data
end

function transform_array_for_hdf(data::Vector{PiecewiseStepData})
    return transform_array_for_hdf(_transform_pwl_step_vector_hdf(data))
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, Vector{PiecewiseStepData}},
)
    transfd_data = sizehint!(
        SortedDict{Dates.DateTime, Vector{Matrix{Float64}}}(),
        length(data),
    )
    for (k, fd) in data
        transfd_data[k] = _transform_pwl_step_vector_hdf(fd)
    end
    return transform_array_for_hdf(transfd_data)
end

function Base.show(io::IO, ::MIME"text/plain", fd::PiecewiseStepData)
    get(io, :compact, false)::Bool ||
        print(io, "$(typeof(fd)) representing step (piecewise constant) function ")
    print(io, "f(x) =")
    for (y, x1, x2) in zip(fd.y_coords, fd.x_coords[1:(end - 1)], fd.x_coords[2:end])
        print(io, "\n  $y for x in [$x1, $x2)")
    end
end

"""
Calculates the x-length of each segment of a piecewise curve.
"""
function get_x_lengths(pwl::Union{PiecewiseLinearData, PiecewiseStepData})
    return _get_x_lengths(get_x_coords(pwl))
end

Base.length(pwl::Union{PiecewiseLinearData, PiecewiseStepData}) =
    length(get_x_coords(pwl)) - 1

Base.getindex(pwl::PiecewiseLinearData, ix::Int) =
    getindex(get_points(pwl), ix)

Base.:(==)(a::T, b::T) where {T <: FunctionData} = double_equals_from_fields(a, b)

Base.isequal(a::T, b::T) where {T <: FunctionData} = isequal_from_fields(a, b)

Base.hash(a::FunctionData, h::UInt) = hash_from_fields(a, h)

# CONVEX APPROXIMATION FUNCTIONS

"""
    isotonic_regression(values::Vector{Float64}, weights::Vector{Float64}) -> Vector{Float64}

Pool Adjacent Violators Algorithm (PAVA) for weighted isotonic regression.
Returns the closest (weighted L2) non-decreasing sequence to `values`.

This is an O(n) algorithm that finds the optimal monotonically non-decreasing
approximation to the input values.
"""
function isotonic_regression(values::Vector{Float64}, weights::Vector{Float64})
    n = length(values)
    n == 0 && return Float64[]
    length(weights) != n &&
        throw(ArgumentError("values and weights must have the same length"))

    # Initialize: each element is its own block
    # Store tuples of (start_index, end_index, weighted_sum, total_weight)
    blocks = Vector{Tuple{Int, Int, Float64, Float64}}(undef, n)
    for i in 1:n
        blocks[i] = (i, i, values[i] * weights[i], weights[i])
    end

    # Merge blocks that violate monotonicity
    num_blocks = n
    i = 1
    while i < num_blocks
        # Get weighted averages
        avg_curr = blocks[i][3] / blocks[i][4]
        avg_next = blocks[i + 1][3] / blocks[i + 1][4]

        if avg_curr > avg_next  # Violation: merge blocks
            # Merge blocks[i] and blocks[i+1]
            merged = (
                blocks[i][1],                          # start
                blocks[i + 1][2],                      # end
                blocks[i][3] + blocks[i + 1][3],       # sum of weighted values
                blocks[i][4] + blocks[i + 1][4],       # sum of weights
            )

            # Shift blocks down
            blocks[i] = merged
            for j in (i + 1):(num_blocks - 1)
                blocks[j] = blocks[j + 1]
            end
            num_blocks -= 1

            # Step back to check if previous block now violates
            i = max(1, i - 1)
        else
            i += 1
        end
    end

    # Expand blocks back to full result
    result = Vector{Float64}(undef, n)
    for block_idx in 1:num_blocks
        start_idx = blocks[block_idx][1]
        end_idx = blocks[block_idx][2]
        avg = blocks[block_idx][3] / blocks[block_idx][4]
        for j in start_idx:end_idx
            result[j] = avg
        end
    end

    return result
end

"""
Compute weights for isotonic regression based on the weighting scheme.

# Arguments
- `x_coords::Vector{Float64}`: x-coordinates of the piecewise data
- `weights::Symbol`: weighting scheme
  - `:uniform` - all segments weighted equally
  - `:length` - segments weighted by their x-length (default)
"""
function _compute_convex_weights(x_coords::Vector{Float64}, weights::Symbol)
    n_segments = length(x_coords) - 1
    if weights === :uniform
        return ones(n_segments)
    elseif weights === :length
        return _get_x_lengths(x_coords)
    else
        throw(ArgumentError("weights must be :uniform or :length"))
    end
end

serialize(val::FunctionData) = serialize_struct(val)

deserialize(T::Type{<:FunctionData}, val::Dict) = deserialize_struct(T, val)

deserialize(::Type{FunctionData}, val::Dict) =
    throw(ArgumentError("FunctionData is abstract, must specify a concrete subtype"))

# FunctionData support fetching "raw data" to support cases where we might want to store
# their data in a different container in its most purely numerical form, such as in
# PowerSimulations.

"""
Get from a subtype or instance of FunctionData the type of data its `get_raw_data` method
returns
"""
function get_raw_data_type end
get_raw_data_type(::Union{LinearFunctionData, Type{LinearFunctionData}}) =
    NTuple{2, Float64}
get_raw_data_type(::Union{QuadraticFunctionData, Type{QuadraticFunctionData}}) =
    NTuple{3, Float64}
get_raw_data_type(::Union{PiecewiseLinearData, Type{PiecewiseLinearData}}) =
    Vector{Tuple{Float64, Float64}}
get_raw_data_type(::Union{PiecewiseStepData, Type{PiecewiseStepData}}) =
    Matrix{Float64}

"Losslessly convert `LinearFunctionData` to `QuadraticFunctionData`"
QuadraticFunctionData(data::LinearFunctionData) =
    QuadraticFunctionData(0, get_proportional_term(data), get_constant_term(data))

"Losslessly convert `LinearFunctionData` to `QuadraticFunctionData`"
Base.convert(::Type{QuadraticFunctionData}, data::LinearFunctionData) =
    QuadraticFunctionData(data)

# GET_DOMAIN
"Get the domain of the function represented by the `LinearFunctionData` or `QuadraticFunctionData` (always `(-Inf, Inf)` for these types)."
get_domain(::Union{LinearFunctionData, QuadraticFunctionData}) = (-Inf, Inf)

"Get the domain of the function represented by the `PiecewiseLinearData`."
get_domain(fd::PiecewiseLinearData) =
    (first(get_points(fd)).x, last(get_points(fd)).x)  # avoiding get_x_coords to avoid extra allocation

"Get the domain of the function represented by the `PiecewiseStepData`."
get_domain(fd::PiecewiseStepData) =
    (first(get_x_coords(fd)), last(get_x_coords(fd)))

# ZERO
"Get a `LinearFunctionData` representing the function `f(x) = 0`"
Base.zero(::Union{LinearFunctionData, Type{LinearFunctionData}}) = LinearFunctionData(0, 0)

"Get a `QuadraticFunctionData` representing the function `f(x) = 0`"
Base.zero(::Union{QuadraticFunctionData, Type{QuadraticFunctionData}}) =
    QuadraticFunctionData(0, 0, 0)

"Get a `PiecewiseLinearData` representing the function `f(x) = 0`; optionally specify `domain` tuple to set the x-coordinates of the endpoints"
Base.zero(::Type{PiecewiseLinearData}; domain::Tuple{Real, Real} = (-Inf, Inf)) =
    PiecewiseLinearData([(first(domain), 0), (last(domain), 0)])

"Get a `PiecewiseStepData` representing the function `f(x) = 0`; optionally specify `domain` tuple to set the x-coordinates of the endpoints"
Base.zero(::Type{PiecewiseStepData}; domain::Tuple{Real, Real} = (-Inf, Inf)) =
    PiecewiseStepData([domain...], [0])

"Get a `PiecewiseLinearData` with the same x-coordinates as `fd` but y-coordinates equal to zero"
Base.zero(fd::PiecewiseLinearData) =
    PiecewiseLinearData([(p.x, 0.0) for p in get_points(fd)])

"Get a `PiecewiseStepData` with the same x-coordinates as `fd` and y-coordinates equal to zero"
Base.zero(fd::PiecewiseStepData) =
    PiecewiseStepData(get_x_coords(fd), zeros(length(get_y_coords(fd))))

"Get a `FunctionData` representing the function `f(x) = 0`"
Base.zero(::Union{FunctionData, Type{FunctionData}}) = Base.zero(LinearFunctionData)

# SCALAR MULTIPLICATION
"Multiply the `LinearFunctionData` by a scalar: (c * f)(x) = c * f(x)"
Base.:*(c::Real, fd::LinearFunctionData) =
    LinearFunctionData(
        c * get_proportional_term(fd),
        c * get_constant_term(fd),
    )

"Multiply the `QuadraticFunctionData` by a scalar: (c * f)(x) = c * f(x)"
Base.:*(c::Real, fd::QuadraticFunctionData) =
    QuadraticFunctionData(
        c * get_quadratic_term(fd),
        c * get_proportional_term(fd),
        c * get_constant_term(fd),
    )

"Multiply the `PiecewiseLinearData` by a scalar: (c * f)(x) = c * f(x)"
Base.:*(c::Real, fd::PiecewiseLinearData) =
    PiecewiseLinearData(
        [(p.x, c * p.y) for p in get_points(fd)],
    )

"Multiply the `PiecewiseStepData` by a scalar: (c * f)(x) = c * f(x)"
function Base.:*(c::Real, fd::PiecewiseStepData)
    y_coords = get_y_coords(fd)
    new_y = Vector{Float64}(undef, length(y_coords))
    for i in eachindex(y_coords, new_y)
        new_y[i] = c * y_coords[i]
    end
    return PiecewiseStepData(get_x_coords(fd), new_y)
end

# commutativity
"Multiply the `FunctionData` by a scalar: (f * c)(x) = (c * f)(x) = c * f(x)"
Base.:*(fd::FunctionData, c::Real) = c * fd

# SCALAR ADDITION
"Add a scalar to the `LinearFunctionData`: (f + c)(x) = f(x) + c"
Base.:+(fd::LinearFunctionData, c::Real) =
    LinearFunctionData(
        get_proportional_term(fd),
        get_constant_term(fd) + c,
    )

"Add a scalar to the `QuadraticFunctionData`: (f + c)(x) = f(x) + c"
Base.:+(fd::QuadraticFunctionData, c::Real) =
    QuadraticFunctionData(
        get_quadratic_term(fd),
        get_proportional_term(fd),
        get_constant_term(fd) + c,
    )

"Add a scalar to the `PiecewiseLinearData`: (f + c)(x) = f(x) + c"
Base.:+(fd::PiecewiseLinearData, c::Real) =
    PiecewiseLinearData(
        [(p.x, p.y + c) for p in get_points(fd)],
    )

"Add a scalar to the `PiecewiseStepData`: (f + c)(x) = f(x) + c"
function Base.:+(fd::PiecewiseStepData, c::Real)
    y_coords = get_y_coords(fd)
    new_y = Vector{Float64}(undef, length(y_coords))
    for i in eachindex(y_coords, new_y)
        new_y[i] = y_coords[i] + c
    end
    return PiecewiseStepData(get_x_coords(fd), new_y)
end

# commutativity
"Add a scalar to the `FunctionData`: (c + f)(x) = (f + c)(x) = f(x) + c"
Base.:+(c::Real, fd::FunctionData) = fd + c

# SHIFT BY A SCALAR
"Right shift the `LinearFunctionData` by a scalar: (f >> c)(x) = f(x - c)"
Base.:>>(fd::LinearFunctionData, c::Real) =
    LinearFunctionData(
        get_proportional_term(fd),
        get_constant_term(fd) - get_proportional_term(fd) * c,
    )

"Right shift the `QuadraticFunctionData` by a scalar: (f >> c)(x) = f(x - c)"
Base.:>>(fd::QuadraticFunctionData, c::Real) =
    QuadraticFunctionData(
        get_quadratic_term(fd),
        get_proportional_term(fd) - 2 * get_quadratic_term(fd) * c,
        get_constant_term(fd) +
        get_quadratic_term(fd) * c^2 - get_proportional_term(fd) * c,
    )

"Right shift the `PiecewiseLinearData` by a scalar: (f >> c)(x) = f(x - c)"
Base.:>>(fd::PiecewiseLinearData, c::Real) =
    PiecewiseLinearData(
        [(p.x + c, p.y) for p in get_points(fd)],
    )

"Right shift the `PiecewiseStepData` by a scalar: (f >> c)(x) = f(x - c)"
function Base.:>>(fd::PiecewiseStepData, c::Real)
    x_coords = get_x_coords(fd)
    new_x = Vector{Float64}(undef, length(x_coords))
    for i in eachindex(x_coords, new_x)
        new_x[i] = x_coords[i] + c
    end
    return PiecewiseStepData(new_x, get_y_coords(fd))
end

"Left shift the `FunctionData` by a scalar: (f << c)(x) = (f >> -c)(x) = f(x + c)"
Base.:<<(fd::FunctionData, c::Real) = fd >> -c

# NEGATION
"Negate the `FunctionData`: (-f)(x) = -f(x)"
Base.:-(fd::FunctionData) = -1.0 * fd

# FLIP ABOUT Y-AXIS
"Flip the `LinearFunctionData` about the y-axis: (~f)(x) = f(-x)"
Base.:~(fd::LinearFunctionData) =
    LinearFunctionData(
        -get_proportional_term(fd),
        get_constant_term(fd),
    )

"Flip the `QuadraticFunctionData` about the y-axis: (~f)(x) = f(-x)"
Base.:~(fd::QuadraticFunctionData) =
    QuadraticFunctionData(
        get_quadratic_term(fd),
        -get_proportional_term(fd),
        get_constant_term(fd),
    )

"Flip the `PiecewiseLinearData` about the y-axis: (~f)(x) = f(-x)"
Base.:~(fd::PiecewiseLinearData) =
    PiecewiseLinearData(
        [(-p.x, p.y) for p in reverse(get_points(fd))],
    )

"Flip the `PiecewiseStepData` about the y-axis: (~f)(x) = f(-x)"
Base.:~(fd::PiecewiseStepData) =
    PiecewiseStepData(
        reverse(-get_x_coords(fd)),
        reverse(get_y_coords(fd)),
    )

# ADDITION OF TWO FUNCTIONDATAS
"Add two `LinearFunctionData`s: (f + g)(x) = f(x) + g(x)"
Base.:+(f::LinearFunctionData, g::LinearFunctionData) =
    LinearFunctionData(
        get_proportional_term(f) + get_proportional_term(g),
        get_constant_term(f) + get_constant_term(g),
    )

"Add two `QuadraticFunctionData`s: (f + g)(x) = f(x) + g(x)"
Base.:+(f::QuadraticFunctionData, g::QuadraticFunctionData) =
    QuadraticFunctionData(
        get_quadratic_term(f) + get_quadratic_term(g),
        get_proportional_term(f) + get_proportional_term(g),
        get_constant_term(f) + get_constant_term(g),
    )

"Add two `PiecewiseLinearData`s: (f + g)(x) = f(x) + g(x). Errors if the x-coordinates are not the same."
function Base.:+(f::PiecewiseLinearData, g::PiecewiseLinearData)
    f_x_coords = get_x_coords(f)
    g_x_coords = get_x_coords(g)
    all(isapprox.(f_x_coords, g_x_coords)) ||
        throw(
            ArgumentError(
                "Cannot add PiecewiseLinearData with different x-coordinates: " *
                "f x-coords = $f_x_coords, g x-coords = $g_x_coords",
            ),
        )
    new_points = XY_COORDS[
        (x = f_x, y = f_y + g_y) for
        (f_x, f_y, g_y) in zip(f_x_coords, get_y_coords(f), get_y_coords(g))
    ]
    return PiecewiseLinearData(new_points)
end

"Add two `PiecewiseStepData`s: (f + g)(x) = f(x) + g(x). Errors if the x-coordinates are not the same."
function Base.:+(f::PiecewiseStepData, g::PiecewiseStepData)
    f_x_coords = get_x_coords(f)
    g_x_coords = get_x_coords(g)
    all(isapprox.(f_x_coords, g_x_coords)) ||
        throw(
            ArgumentError(
                "Cannot add PiecewiseStepData with different x-coordinates: " *
                "f x-coords = $f_x_coords, g x-coords = $g_x_coords",
            ),
        )
    f_y = get_y_coords(f)
    g_y = get_y_coords(g)
    new_y = Vector{Float64}(undef, length(f_y))
    for i in eachindex(f_y, g_y, new_y)
        new_y[i] = f_y[i] + g_y[i]
    end
    return PiecewiseStepData(f_x_coords, new_y)
end

# FUNCTION EVALUATION
"Evaluate the `LinearFunctionData` at a given x-coordinate"
(fd::LinearFunctionData)(x::Number) =
    get_proportional_term(fd) * x + get_constant_term(fd)

"Evaluate the `QuadraticFunctionData` at a given x-coordinate"
(fd::QuadraticFunctionData)(x::Number) =
    get_quadratic_term(fd) * x^2 + get_proportional_term(fd) * x + get_constant_term(fd)

_eval_fd_impl(
    i::Int64,
    x::Real,
    x_coords::Vector{Float64},
    y_coords::Vector{Float64},
    ::PiecewiseLinearData,
) =
    y_coords[i] +
    (y_coords[i + 1] - y_coords[i]) *
    (x - x_coords[i]) /
    (x_coords[i + 1] - x_coords[i])

_eval_fd_impl(
    i::Int64,
    ::Real,
    ::Vector{Float64},
    y_coords::Vector{Float64},
    ::PiecewiseStepData,
) =
    y_coords[i]

"Evaluate the `PiecewiseLinearData` or `PiecewiseStepData` at a given x-coordinate"
function (fd::PiecewiseLinearData)(x::Real)
    points = get_points(fd)
    lb, ub = points[1].x, points[end].x
    # defend against floating point precision issues at the boundaries.
    ((lb <= x <= ub) || isapprox(x, lb) || isapprox(x, ub)) ||
        throw(ArgumentError("x=$x is outside the domain [$lb, $ub]"))
    x = clamp(x, lb, ub)
    i_leq = searchsortedlast(points, x; by = p -> p isa Real ? p : p.x)  # uses binary search!
    (i_leq == length(points)) && return points[end].y
    begin
        p1 = points[i_leq]
        p2 = points[i_leq + 1]
        return p1.y + (p2.y - p1.y) * (x - p1.x) / (p2.x - p1.x)
    end
end

function (fd::PiecewiseStepData)(x::Real)
    x_coords = get_x_coords(fd)
    lb, ub = x_coords[1], x_coords[end]
    # defend against floating point precision issues at the boundaries.
    ((lb <= x <= ub) || isapprox(x, lb) || isapprox(x, ub)) ||
        throw(ArgumentError("x=$x is outside the domain [$lb, $ub]"))
    x = clamp(x, lb, ub)
    y_coords = get_y_coords(fd)
    i_leq = searchsortedlast(x_coords, x)  # uses binary search!
    (i_leq == length(x_coords)) && return y_coords[end]
    return y_coords[i_leq]
end
