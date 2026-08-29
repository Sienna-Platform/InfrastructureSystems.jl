"""
Supertype for static time series, which has one value per time point

Current concrete subtypes are:
- [`SingleTimeSeries`](@ref)
- [`NonSequentialTimeSeries`](@ref)

See also: [`Forecast`](@ref)
"""
abstract type StaticTimeSeries{T} <: TimeSeriesData{T} end

get_initial_timestamp(ts::StaticTimeSeries) = TimeSeries.timestamp(get_time_array(ts))[1]
get_interval(::StaticTimeSeries) = nothing
get_count(ts::StaticTimeSeries) = 1

# The methods below are shared by every static series. Concrete subtypes provide
# three hooks: `get_array` (the stored value array), `get_time_array` (a freshly
# built `TimeArray`), and `_from_time_array(ts, ta)`, which rebuilds the same
# concrete type from a `TimeArray` subset.
#
# The array-like methods read `get_array` directly: `get_time_array` materializes
# timestamps and allocates a `TimeArray` on every call, which would make iteration
# quadratic.
Base.length(ts::StaticTimeSeries) = size(get_array(ts), 1)

Base.getindex(ts::StaticTimeSeries, args...) = getindex(get_array(ts), args...)

Base.firstindex(ts::StaticTimeSeries) = firstindex(get_array(ts))

Base.lastindex(ts::StaticTimeSeries) = lastindex(get_array(ts))

Base.lastindex(ts::StaticTimeSeries, d) = lastindex(get_array(ts), d)

Base.eachindex(ts::StaticTimeSeries) = eachindex(get_array(ts))

# Iteration yields one *value* per step, so it is only well defined for a 1-D series:
# `length` counts rows (dimension 1 is time), while iterating an N-D array would walk
# every element in column-major order and disagree with it. The concrete types carry the
# rank parameter and define the `N == 1` methods in their own files (they are not yet
# defined here); this is the N >= 2 fallback.
Base.iterate(ts::StaticTimeSeries, n = 1) = throw(
    ArgumentError(
        "iteration over a $(ndims(get_array(ts)))-dimensional $(nameof(typeof(ts))) is " *
        "ambiguous: length(ts) counts timesteps but the values are per-step arrays. " *
        "Iterate eachslice(get_array(ts); dims = 1) for one row per timestep, or " *
        "get_array(ts) for the raw elements.",
    ),
)

Base.first(ts::StaticTimeSeries) = head(ts, 1)

Base.last(ts::StaticTimeSeries) = tail(ts, 1)

# Every slicing method below can select an empty subset (an out-of-range `from`/`to`
# bound, `head(ts, 0)`). Rebuilding a series from an empty `TimeArray` would index into
# an empty timestamp vector, so reject it here with an actionable message.
function _check_non_empty_subset(data::TimeSeries.TimeArray)
    isempty(TimeSeries.timestamp(data)) &&
        throw(ArgumentError("the selected range is empty"))
    return data
end

"""
Refer to TimeSeries.when(). Underlying data is copied.

The result carries only the selected timestamps, which a calendar predicate generally
leaves non-contiguous, so it is always a [`NonSequentialTimeSeries`](@ref) — including
for a [`SingleTimeSeries`](@ref) input (see that method).
"""
function when(ts::StaticTimeSeries, period::Function, t::Integer)
    return _from_time_array(ts, TimeSeries.when(get_time_array(ts), period, t))
end

"""
Return a time_series truncated starting with timestamp.
"""
function from(ts::StaticTimeSeries, timestamp)
    return _from_time_array(ts, TimeSeries.from(get_time_array(ts), timestamp))
end

"""
Return a time_series truncated after timestamp.
"""
function to(ts::StaticTimeSeries, timestamp)
    return _from_time_array(ts, TimeSeries.to(get_time_array(ts), timestamp))
end

"""
Return a time_series with only the first num values.
"""
function head(ts::StaticTimeSeries)
    return _from_time_array(ts, TimeSeries.head(get_time_array(ts)))
end

function head(ts::StaticTimeSeries, num)
    return _from_time_array(ts, TimeSeries.head(get_time_array(ts), num))
end

"""
Return a time_series with only the ending num values.
"""
function tail(ts::StaticTimeSeries)
    return _from_time_array(ts, TimeSeries.tail(get_time_array(ts)))
end

function tail(ts::StaticTimeSeries, num)
    return _from_time_array(ts, TimeSeries.tail(get_time_array(ts), num))
end
