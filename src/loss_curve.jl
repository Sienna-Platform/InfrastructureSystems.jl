"""
$(TYPEDEF)
$(TYPEDFIELDS)

    LossCurve(value_curve)
    LossCurve(value_curve, power_units)
    LossCurve(; value_curve, power_units)

Representation of the losses of a component as a function of its flow or current, composed
of a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate
data.

The x-axis units are encoded as the second type parameter `U <: AbstractUnitSystem`;
`power_units` at construction is the singleton instance `U()` (default `NaturalUnit()`).
"""
struct LossCurve{T <: ValueCurve, U <: AbstractUnitSystem} <: ValueCurveWithUnits{T, U}
    "The underlying `ValueCurve` representation of this `LossCurve`"
    value_curve::T

    LossCurve{T, U}(value_curve::T) where {T, U} = new{T, U}(value_curve)
end

LossCurve{T, U}(; value_curve::T) where {T, U} = LossCurve{T, U}(value_curve)

LossCurve(value_curve::T) where {T <: ValueCurve} = LossCurve{T, NaturalUnit}(value_curve)
LossCurve(
    value_curve::T,
    power_units::U,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = LossCurve{T, U}(value_curve)

function LossCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
)
    return LossCurve{typeof(value_curve), typeof(power_units)}(value_curve)
end

"""
`LossCurve{T}` with any unit system. Equivalent to `LossCurve{T, U} where U`;
use at `isa` sites where the unit-system parameter doesn't matter.
"""
const AnyLossCurve{T} = LossCurve{T, U} where {U <: AbstractUnitSystem}

"Get a `LossCurve` representing zero loss (NaturalUnit)"
Base.zero(::Type{LossCurve}) = LossCurve(zero(ValueCurve))
"Get a `LossCurve` representing zero loss, preserving the unit system of `c`"
Base.zero(::LossCurve{T, U}) where {T, U} = LossCurve(zero(ValueCurve), U())

function _show_compact(io::IO, ::MIME"text/plain", curve::LossCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end
