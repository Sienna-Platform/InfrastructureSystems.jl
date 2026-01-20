time_period_conversion(time_period::Union{Dates.TimePeriod, Dates.DatePeriod}) =
    convert(Dates.Millisecond, time_period)
time_period_conversion(time_periods::Dict{String, <:Dates.Period}) =
    convert(Dict{String, Dates.Millisecond}, time_periods)

###############################
# Power Systems Unit Types
###############################

using Unitful: @u_str, @unit, Quantity, Units, uconvert
import Unitful: ustrip
import Unitful

# Define power system-specific units (same dimension as MW, different display)
# These are registered with Unitful in __init__() below
@unit Mvar "Mvar" Mvar 1u"MW" false
@unit MVA "MVA" MVA 1u"MW" false

# Re-export common Unitful units for power systems
const MW = u"MW"
const kV = u"kV"
const OHMS = u"Ω"
const SIEMENS = u"S"

# Note: Unitful.register() is called in InfrastructureSystems.__init__()

# Relative unit types (for per-unit values)
abstract type AbstractRelativeUnit end

"""
Device base per-unit. Values are normalized to the device's own base power.
"""
struct DeviceBaseUnit <: AbstractRelativeUnit end

"""
System base per-unit. Values are normalized to the system's base power.
"""
struct SystemBaseUnit <: AbstractRelativeUnit end

const DU = DeviceBaseUnit()
const SU = SystemBaseUnit()

"""
    RelativeQuantity{T<:Number, U<:AbstractRelativeUnit} <: Number

A quantity with relative (per-unit) units, either device base (DU) or system base (SU).

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

# Arithmetic operations - same unit type only
Base.:+(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(a.value + b.value, a.unit)
Base.:-(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(a.value - b.value, a.unit)
Base.:-(a::RelativeQuantity{T, U}) where {T, U} =
    RelativeQuantity(-a.value, a.unit)

# Scalar multiplication/division
Base.:*(a::Number, b::RelativeQuantity{T, U}) where {T, U} =
    RelativeQuantity(a * b.value, b.unit)
Base.:*(a::RelativeQuantity{T, U}, b::Number) where {T, U} =
    RelativeQuantity(a.value * b, a.unit)
Base.:/(a::RelativeQuantity{T, U}, b::Number) where {T, U} =
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
) where {T, S, U} =
    isapprox(a.value, b.value; kwargs...)

# Value extraction
"""
    ustrip(q::RelativeQuantity)

Extract the numeric value from a RelativeQuantity.
"""
ustrip(q::RelativeQuantity) = q.value

# Type conversions
Base.convert(::Type{RelativeQuantity{T, U}}, q::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(convert(T, q.value), q.unit)
Base.promote_rule(
    ::Type{RelativeQuantity{T, U}},
    ::Type{RelativeQuantity{S, U}},
) where {T, S, U} =
    RelativeQuantity{promote_type(T, S), U}

# Display
Base.show(io::IO, q::RelativeQuantity{T, DeviceBaseUnit}) where {T} =
    print(io, q.value, " DU")
Base.show(io::IO, q::RelativeQuantity{T, SystemBaseUnit}) where {T} =
    print(io, q.value, " SU")
Base.show(io::IO, ::DeviceBaseUnit) = print(io, "DU")
Base.show(io::IO, ::SystemBaseUnit) = print(io, "SU")

# Zero/one for numeric operations
Base.zero(::Type{RelativeQuantity{T, U}}) where {T, U} = RelativeQuantity(zero(T), U())
Base.one(::Type{RelativeQuantity{T, U}}) where {T, U} = RelativeQuantity(one(T), U())
