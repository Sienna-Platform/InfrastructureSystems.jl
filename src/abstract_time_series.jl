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

# Same, for the quantity-kind label.
_maybe_quantity_kind(::Nothing) = nothing
_maybe_quantity_kind(kind::AbstractString) = String(kind)

# The unit system is stored as one of the `RelativeUnits` marker instances
# (`DU`/`SU`/`NU`), not a string, so it dispatches like every other unit-system
# value in IS rather than becoming a second, stringly-typed vocabulary.
_maybe_unit_system(::Nothing) = nothing
_maybe_unit_system(unit_system::AbstractUnitSystem) = unit_system

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

Not to be confused with [`get_unit_system`](@ref), which names the per-unit normalization
base the values are already expressed in rather than naming a physical dimension. The two
are independent: a series labeled `"MW"` may still be read against any normalization base.
"""
get_units(value::TimeSeriesData) = value.units

"""
Return the kind of physical quantity a time series measures (e.g. `"ActivePower"`), or
`nothing` when it declares none.

This sits *above* [`get_units`](@ref) rather than duplicating it. A units library's
dimensional analysis cannot separate active from reactive power — both are `[M L^2 T^-3]` —
but a quantity kind can. And when [`get_unit_system`](@ref) is a per-unit base the values
are dimensionless, so this is the only surviving record of what they measure.

IS neither interprets nor validates the string; the recommended vocabulary is a
[QUDT](https://www.qudt.org/pages/QUDToverviewPage.html) `QuantityKind` local name. Like the
units label it is immutable, is carried over by data-sharing constructors, and is never part
of a time series' identity.
"""
get_quantity_kind(value::TimeSeriesData) = value.quantity_kind

"""
Return the unit system a time series' values are **already expressed in** — one of the
[`RelativeUnits`](@ref) markers `NU` (natural units), `DU` (device base), or `SU` (system
base) — or `nothing` when the series declares none.

Note the direction: `SU`/`DU`/`NU` are used elsewhere in IS as a *target* to convert
**to**, whereas here the marker records the basis the stored values are **in**. It is a
declaration, not a conversion: IS rescales nothing on the strength of it, and converting
per-unit values back to natural units needs the base that lives on the owning component
(see [`get_base_value`](@ref)).

`nothing` means *unspecified*, which is deliberately not the same as `NU`: a series that
never declared a basis must not be read as though someone had said its values were natural.

Like the units label it is immutable, is carried over by data-sharing constructors, and is
never part of a time series' identity.

!!! note

    The backing store represents only `NU` and `DU`. A series declaring `SU` is rejected
    when it is added — see [`get_time_series`](@ref) and the store adapter — rather than
    being silently downgraded.
"""
get_unit_system(value::TimeSeriesData) = value.unit_system
