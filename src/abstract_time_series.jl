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

# The type-level form. A `TimeSeriesKey{T}` carries the time series type rather
# than an instance of it, so serializing the element type needs this one.
Base.eltype(::Type{<:TimeSeriesData{T}}) where {T} = T

# Subtypes must implement
# - Base.length
# - check_time_series_data
# - get_resolution
# - make_time_array

# Normalize an optional user-supplied label (units, quantity kind) to the stored
# `Union{Nothing, String}`.
_maybe_string(::Nothing) = nothing
_maybe_string(value::AbstractString) = String(value)

# Normalize an arbitrary array (view, range, ...) to a concrete `Array`; copy-free
# when it already is one.
_ensure_array(data::Array) = data
_ensure_array(data::AbstractArray) = Array(data)

_ensure_datetime_vector(timestamps::Vector{Dates.DateTime}) = timestamps
_ensure_datetime_vector(timestamps) = collect(Dates.DateTime, timestamps)

"""
Return the user-declared units label of a time series (e.g. `"MW"`), or `nothing` when it
carries none.

IS neither interprets nor validates the label: there is no units vocabulary in IS, and
`nothing` may mean either "unknown" or "dimensionless" — that is the caller's convention
to establish.

This label, [`get_quantity_kind`](@ref), [`get_unit_system`](@ref), and
[`get_per_unit_of`](@ref) share one contract. All four are set at construction and are
immutable — there is deliberately no setter. They describe the values, so every constructor
that shares another instance's data carries all four over. And none of them is part of a time series' identity: they never appear in a
[`TimeSeriesKey`](@ref), never filter a query, and are never arguments to
`get_time_series`. Two series that differ only in these labels are the same series, and
adding both is a duplicate.

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
[QUDT](https://www.qudt.org/pages/QUDToverviewPage.html) `QuantityKind` local name. See
[`get_units`](@ref) for the immutability and identity contract the labels share.
"""
get_quantity_kind(value::TimeSeriesData) = value.quantity_kind

"""
Return the unit system a time series' values are **already expressed in** — one of the
[`RelativeUnits`](@ref) markers `NU` (natural units), `CU` (component base), or `SU` (system
base) — or `nothing` when the series declares none.

Note the direction: `SU`/`CU`/`NU` are used elsewhere in IS as a *target* to convert
**to**, whereas here the marker records the basis the stored values are **in**. It is a
declaration, not a conversion: IS rescales nothing on the strength of it, and converting
per-unit values back to natural units needs the base that lives on the owning component
(see [`get_base_value`](@ref)).

`nothing` means *unspecified*, which is deliberately not the same as `NU`: a series that
never declared a basis must not be read as though someone had said its values were natural.

See [`get_units`](@ref) for the immutability and identity contract the labels share.

!!! note

    The backing store represents only `NU` and `CU`. A series declaring `SU` is rejected
    when it is added — see [`get_time_series`](@ref) and the store adapter — rather than
    being silently downgraded.
"""
get_unit_system(value::TimeSeriesData) = value.unit_system

"""
Return the name of the field on the owning component that a time series' values are a
fraction of (e.g. `"base_power"`), or `nothing` when it names none.

It completes a per-unit declaration: when [`get_unit_system`](@ref) is `CU`, it says which of
the owner's fields the values are per unit of, so the series can be read without knowing the
owner's conventions. IS neither interprets nor validates it, nor checks it against the unit
system; which fields are legitimate bases is the owning package's rule. See
[`get_units`](@ref) for the immutability and identity contract the labels share.
"""
get_per_unit_of(value::TimeSeriesData) = value.per_unit_of
