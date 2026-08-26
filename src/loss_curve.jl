"""
$(TYPEDEF)
$(TYPEDFIELDS)

    LossCurve(value_curve, power_units)
    LossCurve(; value_curve, power_units)

Representation of the losses of a component as a function of its flow or current, composed
of a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate
data.

Unlike a [`CostCurve`](@ref) or [`FuelCurve`](@ref), **both** axes of a `LossCurve` are
power, and both are in the unit system given by the second type parameter
`U <: AbstractUnitSystem`: x is the flow through the component and y is the loss incurred
at that flow, in the same base. See [`y_axis_power_dimension`](@ref).

`power_units` has deliberately **no default**: an unstated base is exactly the ambiguity
this type exists to remove, so every construction site must name the base it means.

Note that the proportional term of a linear loss curve (loss per unit of flow) is
dimensionless, and so is numerically the same in every unit system — only the constant
term, the piecewise breakpoints, and any quadratic term move under a change of base.
"""
struct LossCurve{T <: ValueCurve, U <: AbstractUnitSystem} <: ValueCurveWithUnits{T, U}
    "The underlying `ValueCurve` representation of this `LossCurve`"
    value_curve::T

    LossCurve{T, U}(value_curve::T) where {T, U} = new{T, U}(value_curve)
end

LossCurve{T, U}(; value_curve::T) where {T, U} = LossCurve{T, U}(value_curve)

LossCurve(
    value_curve::T,
    power_units::U,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = LossCurve{T, U}(value_curve)

LossCurve(;
    value_curve::T,
    power_units::U,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = LossCurve{T, U}(value_curve)

"""
`LossCurve{T}` with any unit system. Equivalent to `LossCurve{T, U} where U`;
use at `isa` sites where the unit-system parameter doesn't matter.
"""
const AnyLossCurve{T} = LossCurve{T, U} where {U <: AbstractUnitSystem}

# There is no `zero(::Type{LossCurve})`: a bare `LossCurve` has no unit system to give the
# result, and picking one silently is the ambiguity this type exists to remove. Callers
# who want a zero curve name the base, as they do at every other construction site.
"Get a `LossCurve` representing zero loss, preserving the unit system of `c`"
Base.zero(::LossCurve{T, U}) where {T, U} = LossCurve(zero(ValueCurve), U())

# Both axes are power in base `U`, so y carries one power of the base.
y_axis_power_dimension(::Type{<:LossCurve}) = Val(1)

"""
$(TYPEDSIGNATURES)

Convert `curve` to the `to` unit system. Both axes are power, so the y-axis rescales along
with the x-axis: the result represents `f_to(x) = f_from(ρ * x) / ρ`, where `ρ` is the
ratio between the two bases.
"""
function convert_power_units(
    curve::LossCurve{T, U},
    to::V,
    system_base_power::Float64,
    device_base_power::Float64,
) where {T <: ValueCurve, U <: AbstractUnitSystem, V <: AbstractUnitSystem}
    ratio = _cost_coeff_ratio(U(), to, system_base_power, device_base_power)
    return LossCurve(_convert_value_curve(curve, ratio), to)
end

# Converting to the unit system the curve already carries is the identity, dispatched
# rather than branched.
convert_power_units(
    curve::LossCurve{T, U},
    ::U,
    ::Float64,
    ::Float64,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = curve

function _show_compact(io::IO, ::MIME"text/plain", curve::LossCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end
