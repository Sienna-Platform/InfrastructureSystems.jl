"""
Abstract type for time series stored in the system.
Components reference this data through a [`TimeSeriesKey`](@ref); the data itself is held
by the `InfraStore` backend so it can reside on storage media instead of memory.

`T` is the value element type (`Float64` or a domain type such as `LinearFunctionData`).
Because it is a parameter of the abstract type, callers can dispatch on the payload type
directly — `f(ts::TimeSeriesData{<:PiecewiseStepData})` — rather than querying it and
branching on `<:`.
"""
abstract type TimeSeriesData{T} <: InfrastructureSystemsType end

"""
Return the value element type of a time series, i.e. the `T` of `TimeSeriesData{T}`.
"""
Base.eltype(::TimeSeriesData{T}) where {T} = T

# Subtypes must implement
# - Base.length
# - check_time_series_data
# - get_resolution
# - make_time_array
