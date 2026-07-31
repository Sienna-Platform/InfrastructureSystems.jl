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

# Normalize a user-supplied units label to the stored `Union{Nothing, String}`.
_maybe_units(::Nothing) = nothing
_maybe_units(units::AbstractString) = String(units)

"""
Return the user-declared units label of a time series (e.g. `"MW"`), or `nothing` when it
carries none.

The label is set at construction, is returned unchanged on read, and is immutable —
there is deliberately no setter. It describes the values, so a constructor that shares
another instance's data carries it over. IS neither interprets nor validates it: there is
no units vocabulary in IS, and `nothing` may mean either "unknown" or "dimensionless" —
that is the caller's convention to establish.

It is **not** part of a time series' identity: it never appears in a [`TimeSeriesKey`](@ref),
never filters a query, and is never an argument to `get_time_series`. Two series that
differ only in their label are the same series, and adding both is a duplicate.

Not to be confused with the unit *system* concept in [`RelativeUnits`](@ref) (`SU`/`DU`/`NU`),
which selects a per-unit normalization base rather than naming a physical dimension. The two
are independent: a series labeled `"MW"` may still be read against any normalization base.
"""
get_units(value::TimeSeriesData) = value.units
