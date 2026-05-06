###############################
# Relative (per-unit) markers and RelativeQuantity wrapper.
#
# These types are domain-agnostic — they express "device base" / "system base"
# / "natural unit" without assuming any particular physical domain. Downstream
# packages (e.g. PowerSystems) attach domain-specific meaning via categories
# and conversions.
###############################

"""
Supertype for all unit-system markers (relative and natural). Used as the
`U` type parameter on `ProductionVariableCostCurve` and related parametric
types so that the unit system can be dispatched on at compile time.
"""
abstract type AbstractUnitSystem end

"""
Supertype of per-unit (relative) unit markers.
"""
abstract type AbstractRelativeUnit <: AbstractUnitSystem end

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
`Unitful.Quantity`, not a `RelativeQuantity` — but it is a peer under
`AbstractUnitSystem`.
"""
struct NaturalUnit <: AbstractUnitSystem end

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

# Needed because Unitful.jl isn't a dependency of IS — domain packages (e.g.
# PSY) extend `_strip_units` with a method for `Unitful.Quantity`.
"""
    _strip_units(x)

Drop the unit wrapper and return the bare numeric value. Used by generated
unit-aware getters so `get_X(c, units)` returns a `Float64` while
`get_X_unitful(c, units)` keeps the wrapper.
"""
_strip_units(x) = x
_strip_units(q::RelativeQuantity) = q.value
_strip_units(t::NamedTuple) = map(_strip_units, t)

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
    convert_cost_coefficient(value, U_from, U_to,
                             system_base_power, device_base_power,
                             exponent::Int = 1) → Float64

Convert a cost coefficient (e.g. \$/MW for `exponent=1`, \$/MW² for
`exponent=2`) between unit systems. The conversion ratio is the inverse of
the corresponding power-value ratio raised to `exponent`, since if
`obj = c · x_from` and `x_from = r · x_to`, then the equivalent coefficient
under `x_to` is `c · r`.
"""
convert_cost_coefficient(
    value::Float64,
    U_from::AbstractUnitSystem,
    U_to::AbstractUnitSystem,
    system_base_power::Float64,
    device_base_power::Float64,
    exponent::Int = 1,
) =
    value * _cost_coeff_ratio(U_from, U_to, system_base_power, device_base_power)^exponent

_cost_coeff_ratio(::SystemBaseUnit, ::SystemBaseUnit, _, _) = 1.0
_cost_coeff_ratio(::DeviceBaseUnit, ::DeviceBaseUnit, _, _) = 1.0
_cost_coeff_ratio(::NaturalUnit, ::NaturalUnit, _, _) = 1.0
_cost_coeff_ratio(::DeviceBaseUnit, ::SystemBaseUnit, sb, db) = sb / db
_cost_coeff_ratio(::SystemBaseUnit, ::DeviceBaseUnit, sb, db) = db / sb
_cost_coeff_ratio(::NaturalUnit, ::SystemBaseUnit, sb, _) = sb
_cost_coeff_ratio(::SystemBaseUnit, ::NaturalUnit, sb, _) = 1 / sb
_cost_coeff_ratio(::NaturalUnit, ::DeviceBaseUnit, _, db) = db
_cost_coeff_ratio(::DeviceBaseUnit, ::NaturalUnit, _, db) = 1 / db

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
