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

Base.iterate(ts::StaticTimeSeries, n = 1) = iterate(get_array(ts), n)

Base.first(ts::StaticTimeSeries) = head(ts, 1)

Base.last(ts::StaticTimeSeries) = tail(ts, 1)

"""
Refer to TimeSeries.when(). Underlying data is copied.
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
