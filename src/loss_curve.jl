"""
$(TYPEDEF)
$(TYPEDFIELDS)

    LossCurve(value_curve, power_units)
    LossCurve(value_curve, power_units, x_units)
    LossCurve(; value_curve, power_units, x_units = u"MW")

Representation of the losses of a component as a function of its flow or current, composed
of a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate
data.

The y-axis is the loss, a power. The x-axis is whatever drives the loss, named by the
natural unit of its quantity in the third type parameter `X`: `MW` (the default) for a loss
that is a function of power flow, `kA` for one that is a function of converter current.
Both axes are stored on the basis `U <: AbstractUnitSystem`, which may be per-unit.

`power_units` has deliberately **no default**: an unstated base is ambiguous.
"""
struct LossCurve{T <: ValueCurve, U <: AbstractUnitSystem, X <: Unitful.Units} <:
       ValueCurveWithUnits{T, U, X, _MW}
    "The underlying `ValueCurve` representation of this `LossCurve`"
    value_curve::T

    LossCurve{T, U, X}(value_curve::T) where {T, U, X} = new{T, U, X}(value_curve)
end

LossCurve{T, U, X}(; value_curve::T) where {T, U, X} = LossCurve{T, U, X}(value_curve)

LossCurve(
    value_curve::T,
    ::U,
    x_units::Unitful.Units = Unitful.MW,
) where {T <: ValueCurve, U <: AbstractUnitSystem} =
    LossCurve{T, U, typeof(x_units)}(value_curve)

# `deserialize` reconstructs through this keyword form.
LossCurve(;
    value_curve::ValueCurve,
    power_units::AbstractUnitSystem,
    x_units::Unitful.Units = Unitful.MW,
) = LossCurve(value_curve, power_units, x_units)

"""
`LossCurve{T}` with any unit system and x-axis. Equivalent to `LossCurve{T, U, X} where {U, X}`;
use at `isa` sites where those parameters don't matter.
"""
const AnyLossCurve{T} =
    LossCurve{T, U, X} where {U <: AbstractUnitSystem, X <: Unitful.Units}

"""
`LossCurve{T}` with any unit system and a converter-current x-axis in `kA`. Use as a field
type where the loss is a function of current, so a power-axis curve can't be stored there.
"""
const CurrentLossCurve{T} =
    LossCurve{T, U, typeof(Unitful.kA)} where {U <: AbstractUnitSystem}

# There is no `zero(::Type{LossCurve})`: a bare `LossCurve` has no unit system to give the
# result, and picking one silently is the ambiguity this type exists to remove. Callers
# who want a zero curve name the base, as they do at every other construction site.
"Get a `LossCurve` representing zero loss, preserving the units of `c`"
Base.zero(::LossCurve{T, U, X}) where {T, U, X} = LossCurve(zero(ValueCurve), U(), X())

_free_axis_units(curve::LossCurve) = (; x_units = get_x_units(curve))
_deserialize_curve_field(::Val{:x_units}, raw::AbstractString) = _parse_units(raw)

"""
$(TYPEDSIGNATURES)

Convert `curve` to the `to` unit system. `x_ratio` and `y_ratio` are the ratios between the
two bases on each axis (`x_from = x_ratio * x_to`, likewise for y): the result represents
`f_to(x) = f_from(x_ratio * x) / y_ratio`.

See [`convert_power_units(::CostCurve, ::Any, ::Real, ::Real)`](@ref) on where the ratios
come from.
"""
convert_power_units(
    curve::LossCurve{T, U, X},
    to::V,
    x_ratio::Real,
    y_ratio::Real,
) where {T <: ValueCurve, U <: AbstractUnitSystem, X, V <: AbstractUnitSystem} =
    LossCurve(_convert_value_curve(curve, x_ratio, y_ratio), to, X())

# Converting to the curve's own unit system is the identity, and needs no ratios.
convert_power_units(
    curve::LossCurve{T, U},
    ::U,
    ::Real,
    ::Real,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = curve

function _show_compact(io::IO, ::MIME"text/plain", curve::LossCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), x_units $(get_x_units(curve)), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end
