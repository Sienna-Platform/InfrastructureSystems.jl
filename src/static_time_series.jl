"""
Supertype for static time series, which has one value per time point

Current concrete subtypes are:
- [`SingleTimeSeries`](@ref)

See also: [`Forecast`](@ref)
"""
abstract type StaticTimeSeries <: TimeSeriesData end

Base.length(ts::StaticTimeSeries) = length(get_data(ts))
get_initial_timestamp(ts::StaticTimeSeries) = TimeSeries.timestamp(get_data(ts))[1]
get_interval(::StaticTimeSeries) = nothing
get_count(ts::StaticTimeSeries) = 1
