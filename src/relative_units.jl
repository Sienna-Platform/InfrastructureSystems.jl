###############################
# Relative (per-unit) markers and RelativeQuantity wrapper.
#
# These types are domain-agnostic — they express "device base" / "system base"
# / "natural unit" without assuming any particular physical domain. Downstream
# packages (e.g. PowerSystems) attach domain-specific meaning via categories
# and conversions.
###############################

"""
Supertype of per-unit (relative) unit markers.
"""
abstract type AbstractRelativeUnit end

"""
Device base per-unit. Values are normalized to the component's own base.
"""
struct DeviceBaseUnit <: AbstractRelativeUnit end

"""
System base per-unit. Values are normalized to the system's base.
"""
struct SystemBaseUnit <: AbstractRelativeUnit end

"""
Natural units. When used as a target, returns the value with the
domain-appropriate unit attached (e.g. MW for power, Ω for impedance).
Deliberately *not* `<: AbstractRelativeUnit` — "convert to NU" yields a
`Unitful.Quantity`, not a `RelativeQuantity`.
"""
struct NaturalUnit end

const DU = DeviceBaseUnit()
const SU = SystemBaseUnit()
const NU = NaturalUnit()

"""
    RelativeQuantity{T<:Number, U<:AbstractRelativeUnit} <: Number

A quantity tagged with a per-unit marker.

# Examples
```julia
0.6 * DU  # 0.6 per-unit on device base
0.3 * SU  # 0.3 per-unit on system base
```
"""
struct RelativeQuantity{T <: Number, U <: AbstractRelativeUnit} <: Number
    value::T
    unit::U
end

# Construction via multiplication
Base.:*(a::Number, b::AbstractRelativeUnit) = RelativeQuantity(a, b)
Base.:*(b::AbstractRelativeUnit, a::Number) = RelativeQuantity(a, b)

# Arithmetic — same unit type only
Base.:+(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(a.value + b.value, a.unit)
Base.:-(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(a.value - b.value, a.unit)
Base.:-(a::RelativeQuantity{T, U}) where {T, U} = RelativeQuantity(-a.value, a.unit)

# Scalar mul/div (Real to avoid ambiguity with unit-bearing types)
Base.:*(a::Real, b::RelativeQuantity{T, U}) where {T, U} =
    RelativeQuantity(a * b.value, b.unit)
Base.:*(a::RelativeQuantity{T, U}, b::Real) where {T, U} =
    RelativeQuantity(a.value * b, a.unit)
Base.:/(a::RelativeQuantity{T, U}, b::Real) where {T, U} =
    RelativeQuantity(a.value / b, a.unit)

# Comparisons
Base.:(==)(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    a.value == b.value
Base.:(<)(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    a.value < b.value
Base.:(<=)(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    a.value <= b.value
Base.isless(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    isless(a.value, b.value)
Base.isapprox(
    a::RelativeQuantity{T, U},
    b::RelativeQuantity{S, U};
    kwargs...,
) where {T, S, U} = isapprox(a.value, b.value; kwargs...)

"""
    ustrip(q::RelativeQuantity)

Extract the numeric value from a `RelativeQuantity`.
"""
ustrip(q::RelativeQuantity) = q.value

# Type conversions
Base.convert(::Type{RelativeQuantity{T, U}}, q::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(convert(T, q.value), q.unit)
Base.promote_rule(
    ::Type{RelativeQuantity{T, U}},
    ::Type{RelativeQuantity{S, U}},
) where {T, S, U} = RelativeQuantity{promote_type(T, S), U}

# Display
Base.show(io::IO, q::RelativeQuantity{T, DeviceBaseUnit}) where {T} =
    print(io, q.value, " DU")
Base.show(io::IO, q::RelativeQuantity{T, SystemBaseUnit}) where {T} =
    print(io, q.value, " SU")
Base.show(io::IO, ::DeviceBaseUnit) = print(io, "DU")
Base.show(io::IO, ::SystemBaseUnit) = print(io, "SU")
Base.show(io::IO, ::NaturalUnit) = print(io, "NU")

Base.zero(::Type{RelativeQuantity{T, U}}) where {T, U} = RelativeQuantity(zero(T), U())
Base.one(::Type{RelativeQuantity{T, U}}) where {T, U} = RelativeQuantity(one(T), U())

"""
    display_units_arg(f, ::Type{T}) -> Union{AbstractRelativeUnit, Missing}

Trait returning the units argument a getter `f` expects when called on a
component of type `T` for display/tabular output, or `missing` if the getter
takes no units argument. Keyed on both function and type because the same
getter name can appear on both unit-bearing and non-unit-bearing structs
(e.g. `get_b` on `Line` vs. `DynamicExponentialLoad`). Downstream packages
set this per-struct (typically via the struct-generator template); consumers
like `show_components` dispatch on the result to avoid runtime method
introspection.
"""
display_units_arg(_, ::Type) = missing
