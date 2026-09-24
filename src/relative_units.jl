###############################
# Relative (per-unit) unit-system markers.
#
# These types are domain-agnostic — they express "component base" / "system base"
# / "natural unit" without assuming any particular physical domain. Downstream
# packages (e.g. PowerSystems) attach domain-specific meaning via categories
# and conversions.
#
# The markers name a unit system as a type parameter or dispatch target (the `U` in
# `CostCurve{T, U}`); per-unit *values* are Unitful quantities (`per_unit.jl`).
#
# Wrapped in a submodule so the unit-system surface area is namespaced
# separately from the rest of IS. The parent module brings the public names
# back into its own scope via `using .RelativeUnits: ...` so existing
# downstream call sites (`IS.SU`, `IS._strip_units`, …) keep working.
###############################

"""
Relative (per-unit) unit-system markers. Domain-agnostic: expresses "component base" /
"system base" / "natural unit" without assuming any particular physical domain. Downstream
packages (e.g. PowerSystems) attach domain-specific meaning via categories and conversions.
"""
module RelativeUnits

import Unitful

export AbstractUnitSystem, AbstractRelativeUnit
export ComponentBaseUnit, SystemBaseUnit, NaturalUnit
export CU, SU, NU
export display_units_arg
export unitful_variant
export display_string

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
Component base per-unit. Values are normalized to the component's own base.
"""
struct ComponentBaseUnit <: AbstractRelativeUnit end

"""
System base per-unit. Values are normalized to the system's base.
"""
struct SystemBaseUnit <: AbstractRelativeUnit end

"""
Natural units. When used as a target, returns the value with the
domain-appropriate unit attached (e.g. MW for power, Ω for impedance).
Deliberately *not* `<: AbstractRelativeUnit`, but a peer under
`AbstractUnitSystem`.
"""
struct NaturalUnit <: AbstractUnitSystem end

const CU = ComponentBaseUnit()
const SU = SystemBaseUnit()
const NU = NaturalUnit()

# `0.6 * CU` was the pre-Unitful spelling; point callers at `0.6u"CU"`.
_marker_product_error(m) = throw(
    ArgumentError(
        "multiplying a number by the unit-system marker $m no longer tags it; write a " *
        "per-unit value as a Unitful quantity, e.g. `0.6u\"$m\"`",
    ),
)
Base.:*(::Number, m::AbstractRelativeUnit) = _marker_product_error(m)
Base.:*(m::AbstractRelativeUnit, ::Number) = _marker_product_error(m)

"""
    _strip_units(x)

Drop the unit wrapper and return the bare numeric value. Used by generated
unit-aware getters so `get_X(c, units)` returns a `Float64` while
`get_X_unitful(c, units)` keeps the wrapper. The fallback returns its argument
unchanged; domain packages with their own quantity wrapper types MUST extend
`_strip_units` for them, otherwise `get_X` returns the wrapper rather than a bare number.
"""
_strip_units(x) = x
_strip_units(q::Unitful.Quantity) = Unitful.ustrip(q)
_strip_units(t::NamedTuple) = map(_strip_units, t)

# Display
Base.show(io::IO, ::ComponentBaseUnit) = print(io, "CU")
Base.show(io::IO, ::SystemBaseUnit) = print(io, "SU")
Base.show(io::IO, ::NaturalUnit) = print(io, "NU")

# Markers broadcast as scalars (`get_rating.(components, CU)`), not as containers.
Base.Broadcast.broadcastable(u::AbstractUnitSystem) = Ref(u)

"""
    display_string(x) -> String

Render `x` for human-facing display, spelling a per-unit value's base out in full
("0.6 p.u. in component base") where `show` prints a terse unit. Driven by two hooks a
domain package extends: [`display_base_label`](@ref) and [`display_value`](@ref).

Recurses into `NamedTuple`s so compound fields (e.g. `(min = …, max = …)`) are rendered
element-wise; when every element shares one base, it is stated once after the tuple:
`(min = 0.0 p.u., max = 2.5 p.u.) in system base`.

Anything without a base label renders exactly as `print` would.
"""
display_string(x) = _display_string(display_base_label(x), x)
_display_string(::Nothing, x) = string(x)
_display_string(label, x) = string(display_value(x), " in ", label)

function display_string(t::NamedTuple)
    shared = _shared_label(map(display_base_label, values(t)))
    isnothing(shared) &&
        return string(
            "(",
            join(("$k = $(display_string(v))" for (k, v) in pairs(t)), ", "),
            ")",
        )
    return string(
        "(", join(("$k = $(display_value(v))" for (k, v) in pairs(t)), ", "), ") in ",
        shared)
end

# The one base label every element carries, or `nothing` (empty, mixed, or unlabeled).
_shared_label(::Tuple{}) = nothing
function _shared_label(labels::Tuple)
    label = first(labels)
    return !isnothing(label) && all(==(label), labels) ? label : nothing
end

"""
    display_base_label(x) -> Union{Nothing, String}

The base a per-unit value is on, for [`display_string`](@ref) (e.g. `"system base"`), or
`nothing` for anything that is not per-unit. Domain packages extend it for their units.
"""
display_base_label(_) = nothing

"""
    display_value(x) -> String

`x` rendered without its base, for [`display_string`](@ref) (e.g. `"0.6 p.u."`). Only
called when [`display_base_label`](@ref) returns a label.
"""
display_value(x) = string(x)

"""
    convert_cost_coefficient(value, ratio, exponent::Int = 1) → Float64

Convert a cost coefficient (e.g. \$/MW for `exponent=1`, \$/MW² for `exponent=2`) between
unit systems, given the x-axis `ratio` between them: if `obj = c · x_from` and
`x_from = ratio · x_to`, the equivalent coefficient under `x_to` is `c · ratio^exponent`.

`InfrastructureSystems` has no notion of components or base powers, so it does not resolve
the ratio itself — the base arithmetic lives in the domain package that owns the bases
(in the Sienna stack, `PowerSystems`, whose units engine derives it per component and
physical category). Deliberately not exported.
"""
convert_cost_coefficient(value::Float64, ratio::Float64, exponent::Int = 1) =
    value * ratio^exponent

"""
    display_units_arg(f, ::Type{T})

Trait returning a units argument accepted by getter `f` when called on a
component of type `T` for display/tabular output (e.g. `SU`), or `missing`
if the getter takes no units argument. The returned value may be an
`AbstractRelativeUnit` (defined in IS, e.g. `SU`) or a domain-provided units
object (e.g. `u"MW"`); callers should not assume it is an `AbstractRelativeUnit`.
Keyed on both function and type because the same getter name can appear on both
unit-bearing and non-unit-bearing structs (e.g. `get_b` on `Line` vs.
`DynamicExponentialLoad`). Downstream packages set this per-struct (typically via
the struct-generator template); consumers like `show_components` dispatch on the
result to avoid runtime method introspection.
"""
display_units_arg(_, ::Type) = missing

"""
    unitful_variant(f::Function)

Resolve the unit-bearing companion of getter `f` — a function returning the
same value but unit-tagged (a `Unitful.Quantity`) instead of a bare number —
following the `\$(f)_unitful` naming convention the struct-generator template
emits alongside every converted getter (see `generate_structs.jl`). Falls back to
`f` itself when no such companion exists (hand-written getters that don't provide
one). Display/tabular code should resolve through this trait rather than
re-deriving the naming convention.
"""
function unitful_variant(f::Function)
    name = Symbol(string(nameof(f)), "_unitful")
    mod = parentmodule(f)
    # `isdefined`, not `hasproperty`: the latter is backed by `propertynames`,
    # which for a `Module` defaults to only its *exported* names, and a
    # `_unitful` companion need not be exported to be a valid resolution
    # target.
    return isdefined(mod, name) ? getproperty(mod, name) : f
end

end # module RelativeUnits
