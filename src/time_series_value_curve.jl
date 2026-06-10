"""
    TimeSeriesInputOutputCurve{T <: TimeSeriesFunctionData} <: ValueCurve{T}

A time-series-backed input-output curve, directly relating the production quantity to the
cost: `y = f(x)`. Mirrors [`InputOutputCurve`](@ref) but the function data comes from a
time series referenced by a [`TimeSeriesKey`](@ref).
"""
@kwdef struct TimeSeriesInputOutputCurve{
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{QuadraticFunctionData},
        TimeSeriesFunctionData{PiecewiseLinearData},
    },
} <: ValueCurve{T}
    "The underlying `TimeSeriesFunctionData` representation of this `ValueCurve`"
    function_data::T
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, Float64} = nothing
end

TimeSeriesInputOutputCurve(function_data) =
    TimeSeriesInputOutputCurve(function_data, nothing)
TimeSeriesInputOutputCurve{T}(
    function_data,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{QuadraticFunctionData},
        TimeSeriesFunctionData{PiecewiseLinearData},
    },
} = TimeSeriesInputOutputCurve{T}(function_data, nothing)

"""
    TimeSeriesIncrementalCurve{T <: TimeSeriesFunctionData} <: ValueCurve{T}

A time-series-backed incremental (or 'marginal') curve, relating the production quantity to
the derivative of cost: `y = f'(x)`. Mirrors [`IncrementalCurve`](@ref) but the function
data comes from a time series referenced by a [`TimeSeriesKey`](@ref).

Structurally identical to [`TimeSeriesAverageRateCurve`](@ref); the separate type exists so
downstream packages can dispatch on incremental vs average-rate semantics when interpreting
retrieved time series data.
"""
@kwdef struct TimeSeriesIncrementalCurve{
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} <: ValueCurve{T}
    "The underlying `TimeSeriesFunctionData` representation of this `ValueCurve`"
    function_data::T
    "The initial input value, either a TimeSeriesKey or nothing"
    initial_input::Union{Nothing, ConcreteTimeSeriesKey}
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, ConcreteTimeSeriesKey} = nothing
end

TimeSeriesIncrementalCurve(function_data, initial_input) =
    TimeSeriesIncrementalCurve(function_data, initial_input, nothing)
TimeSeriesIncrementalCurve{T}(
    function_data,
    initial_input,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesIncrementalCurve{T}(function_data, initial_input, nothing)

"""
    TimeSeriesAverageRateCurve{T <: TimeSeriesFunctionData} <: ValueCurve{T}

A time-series-backed average rate curve, relating the production quantity to the average
cost rate from the origin: `y = f(x)/x`. Mirrors [`AverageRateCurve`](@ref) but the
function data comes from a time series referenced by a [`TimeSeriesKey`](@ref).

Structurally identical to [`TimeSeriesIncrementalCurve`](@ref); the separate type exists so
downstream packages can dispatch on incremental vs average-rate semantics when interpreting
retrieved time series data.
"""
@kwdef struct TimeSeriesAverageRateCurve{
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} <: ValueCurve{T}
    "The underlying `TimeSeriesFunctionData` representation of this `ValueCurve`"
    function_data::T
    "The initial input value, either a TimeSeriesKey or nothing"
    initial_input::Union{Nothing, ConcreteTimeSeriesKey}
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, ConcreteTimeSeriesKey} = nothing
end

TimeSeriesAverageRateCurve(function_data, initial_input) =
    TimeSeriesAverageRateCurve(function_data, initial_input, nothing)
TimeSeriesAverageRateCurve{T}(
    function_data,
    initial_input,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesAverageRateCurve{T}(function_data, initial_input, nothing)

# ACCESSOR EXTENSIONS
"Get the `initial_input` field of a time-series-backed `ValueCurve` (returns a `TimeSeriesKey` or `nothing`, unlike the static variant which returns `Float64`)"
get_initial_input(
    curve::Union{TimeSeriesIncrementalCurve, TimeSeriesAverageRateCurve},
) = curve.initial_input

# TIME-SERIES FORWARDING — delegates to the FunctionData level so adding new TS
# ValueCurve types does not require updating a Union here.
"Check if a `ValueCurve` is backed by time series data."
is_time_series_backed(curve::ValueCurve) =
    is_time_series_backed(get_function_data(curve))

"Get the `TimeSeriesKey` from the underlying function data of a time-series-backed `ValueCurve`."
get_time_series_key(curve::ValueCurve{<:TimeSeriesFunctionData}) =
    get_time_series_key(get_function_data(curve))

# GENERIC CONSTRUCTORS (Julia #35053 workaround)
TimeSeriesInputOutputCurve(
    function_data::T,
    input_at_zero,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{QuadraticFunctionData},
        TimeSeriesFunctionData{PiecewiseLinearData},
    },
} = TimeSeriesInputOutputCurve{T}(function_data, input_at_zero)

TimeSeriesIncrementalCurve(
    function_data::T,
    initial_input,
    input_at_zero,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesIncrementalCurve{T}(function_data, initial_input, input_at_zero)

TimeSeriesAverageRateCurve(
    function_data::T,
    initial_input,
    input_at_zero,
) where {
    T <: Union{
        TimeSeriesFunctionData{LinearFunctionData},
        TimeSeriesFunctionData{PiecewiseStepData},
    },
} = TimeSeriesAverageRateCurve{T}(function_data, initial_input, input_at_zero)

# ============================================================================
# RESOLVE TO STATIC CURVE(S)
# Each time-series-backed curve type pairs with its static counterpart via the
# `static_curve_type` trait; one generic `build_static_curve` resolves a single
# timestep and `build_static_curves` resolves a window with one storage read
# per time-series-backed field.
# ============================================================================

"Union of the time-series-backed `ValueCurve` types."
const TimeSeriesValueCurve = Union{
    TimeSeriesInputOutputCurve,
    TimeSeriesIncrementalCurve,
    TimeSeriesAverageRateCurve,
}

"The static `ValueCurve` counterpart of a time-series-backed curve type."
static_curve_type(::Type{<:TimeSeriesInputOutputCurve}) = InputOutputCurve
static_curve_type(::Type{<:TimeSeriesIncrementalCurve}) = IncrementalCurve
static_curve_type(::Type{<:TimeSeriesAverageRateCurve}) = AverageRateCurve

_static_function_data_type(
    ::ValueCurve{TimeSeriesFunctionData{T}},
) where {T <: StaticFunctionData} = T

"""
Resolve a scalar `TimeSeriesKey` to the `Float64` values over a window,
or pass through `nothing`.
"""
_resolve_scalar_key_window(
    ::TimeSeriesOwners,
    ::Nothing,
    ::Dates.DateTime,
    len::Int,
) = nothing

function _resolve_scalar_key_window(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
    start_time::Dates.DateTime,
    len::Int,
)
    return get_time_series_values(
        owner, key; start_time = start_time, len = len)::AbstractVector{Float64}
end

_window_element(::Nothing, ::Int) = nothing
_window_element(vals::AbstractVector, i::Int) = vals[i]

# Per-curve-kind extra constructor arguments, resolved for the whole window.
_static_curve_args_window(
    curve::TimeSeriesInputOutputCurve,
    ::TimeSeriesOwners,
    ::Dates.DateTime,
    len::Int,
) = (fill(get_input_at_zero(curve), len),)

function _static_curve_args_window(
    curve::Union{TimeSeriesIncrementalCurve, TimeSeriesAverageRateCurve},
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
    len::Int,
)
    initial_key = get_initial_input(curve)
    zero_key = get_input_at_zero(curve)
    initial_input = _resolve_scalar_key_window(owner, initial_key, start_time, len)
    # Merge the read when both scalars reference the same series.
    input_at_zero = if zero_key !== nothing && zero_key == initial_key
        initial_input
    else
        _resolve_scalar_key_window(owner, zero_key, start_time, len)
    end
    return (initial_input, input_at_zero)
end

"""
    build_static_curves(curve, owner, start_time, len) -> Vector{<:ValueCurve}

Resolve a time-series-backed `ValueCurve` over a window of `len` timesteps
starting at `start_time`, returning the corresponding static `ValueCurve`s with
all time series references replaced by their values. Issues one storage read
per time-series-backed field for the entire window.
"""
function build_static_curves(
    curve::TimeSeriesValueCurve,
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
    len::Int,
)
    len >= 1 || throw(ArgumentError("len must be positive, got $len"))
    T = _static_function_data_type(curve)
    fds = get_time_series_values(
        owner, get_time_series_key(curve); start_time = start_time, len = len)
    args = _static_curve_args_window(curve, owner, start_time, len)
    S = static_curve_type(typeof(curve))
    return [
        S(fds[i]::T, (_window_element(a, i) for a in args)...) for i in 1:len
    ]
end

"""
    build_static_curve(curve, owner, start_time) -> ValueCurve

Resolve a time-series-backed `ValueCurve` at a specific timestep, returning the
corresponding static `ValueCurve` with all time series references replaced by
their values at `start_time`.

Per-timestep resolution issues one storage read per time-series-backed field
(the function data plus each of `initial_input`/`input_at_zero` when
TS-backed). Hot-loop consumers should resolve a window at a time through
[`build_static_curves`](@ref) or a `TimeSeriesCache` rather than calling this
per component per timestep.
"""
build_static_curve(
    curve::TimeSeriesValueCurve,
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
) = only(build_static_curves(curve, owner, start_time, 1))
