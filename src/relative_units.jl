###############################
# Relative (per-unit) markers and RelativeQuantity wrapper.
#
# These types are domain-agnostic — they express "component base" / "system base"
# / "natural unit" without assuming any particular physical domain. Downstream
# packages (e.g. PowerSystems) attach domain-specific meaning via categories
# and conversions.
#
# Wrapped in a submodule so the unit-system surface area is namespaced
# separately from the rest of IS. The parent module brings the public names
# back into its own scope via `using .RelativeUnits: ...` so existing
# downstream call sites (`IS.SU`, `IS._strip_units`, …) keep working.
###############################

"""
Relative (per-unit) markers and the [`RelativeQuantity`](@ref) wrapper. Domain-agnostic:
expresses "device base" / "system base" / "natural unit" without assuming any particular
physical domain. Downstream packages (e.g. PowerSystems) attach domain-specific meaning
via categories and conversions.
"""
module RelativeUnits

export AbstractUnitSystem, AbstractRelativeUnit
export DeviceBaseUnit, SystemBaseUnit, NaturalUnit
export RelativeQuantity
export DU, SU, NU
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
0.6 * DU  # 0.6 per-unit on component base
0.3 * SU  # 0.3 per-unit on system base
```
"""
struct RelativeQuantity{T <: Number, U <: AbstractRelativeUnit} <: Number
    value::T

    # The typed inner constructor replaces the implicit `(value::Any)` one,
    # which is ambiguous against Base's generic Number constructors
    # (TwicePrecision, AbstractChar, identity).
    RelativeQuantity{T, U}(value::Number) where {T <: Number, U <: AbstractRelativeUnit} =
        new{T, U}(convert(T, value))
end

# Disambiguates against Core's identity constructor `(::Type{T})(x::T)`.
RelativeQuantity{T, U}(
    q::RelativeQuantity{T, U},
) where {T <: Number, U <: AbstractRelativeUnit} =
    q

# The unit is carried entirely by the type parameter; the two-argument
# constructor and the `unit` accessor keep the marker-instance API.
RelativeQuantity(value::T, ::U) where {T <: Number, U <: AbstractRelativeUnit} =
    RelativeQuantity{T, U}(value)

"Return the unit marker instance (`DU`/`SU`) of a `RelativeQuantity`."
unit(::RelativeQuantity{<:Any, U}) where {U} = U()

# Construction via multiplication
Base.:*(a::Number, b::AbstractRelativeUnit) = RelativeQuantity(a, b)
Base.:*(b::AbstractRelativeUnit, a::Number) = RelativeQuantity(a, b)

# Guard against double-tagging: more specific methods catch the case where
# the left (or right) operand is already a RelativeQuantity (which is <: Number).
Base.:*(a::RelativeQuantity, b::AbstractRelativeUnit) =
    throw(
        ArgumentError(
            "cannot re-tag an already-tagged quantity: $(unit(a)) value multiplied by $b; strip units first",
        ),
    )
Base.:*(b::AbstractRelativeUnit, a::RelativeQuantity) =
    throw(
        ArgumentError(
            "cannot re-tag an already-tagged quantity: $b multiplied by $(unit(a)) value; strip units first",
        ),
    )

# Arithmetic — same unit type only
Base.:+(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(a.value + b.value, unit(a))
Base.:-(a::RelativeQuantity{T, U}, b::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(a.value - b.value, unit(a))
Base.:-(a::RelativeQuantity{T, U}) where {T, U} = RelativeQuantity(-a.value, unit(a))

# Scalar mul/div (Real to avoid ambiguity with unit-bearing types)
Base.:*(a::Real, b::RelativeQuantity{T, U}) where {T, U} =
    RelativeQuantity(a * b.value, unit(b))
Base.:*(a::RelativeQuantity{T, U}, b::Real) where {T, U} =
    RelativeQuantity(a.value * b, unit(a))
Base.:/(a::RelativeQuantity{T, U}, b::Real) where {T, U} =
    RelativeQuantity(a.value / b, unit(a))

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

# Cross-unit operations: produce a clear error rather than falling into Base
# promotion which yields a cryptic ErrorException.
for op in (:+, :-, :(==), :(<), :(<=), :isless)
    @eval Base.$op(
        a::RelativeQuantity{T, U1},
        b::RelativeQuantity{S, U2},
    ) where {T, S, U1, U2} =
        throw(
            ArgumentError(
                "cannot combine/compare quantities in different unit bases ($(unit(a)) vs $(unit(b))); convert explicitly first",
            ),
        )
end
Base.isapprox(
    a::RelativeQuantity{T, U1},
    b::RelativeQuantity{S, U2};
    kwargs...,
) where {T, S, U1, U2} =
    throw(
        ArgumentError(
            "cannot compare quantities in different unit bases ($(unit(a)) vs $(unit(b))); convert explicitly first",
        ),
    )

# Tagged-vs-untagged mixing: produce a clear error rather than falling into Base
# promotion which yields a cryptic ErrorException.
# Uses `Real` (not `Number`) for the plain-number side: RelativeQuantity <: Number
# but NOT <: Real, so (RQ, Real) and (Real, RQ) cannot conflict with any (RQ, RQ)
# pair — dispatch ordering is clean with no ambiguities.
# Errors are inlined (no shared helper) to avoid a (RQ,b)/(a,RQ) helper ambiguity.
Base.:(==)(a::RelativeQuantity, b::Real) = throw(
    ArgumentError(
        "cannot combine/compare a unit-tagged quantity ($(unit(a))) with an untagged number; " *
        "strip units or tag the number first",
    ),
)
Base.:(==)(a::Real, b::RelativeQuantity) = throw(
    ArgumentError(
        "cannot combine/compare an untagged number with a unit-tagged quantity ($(unit(b))); " *
        "strip units or tag the number first",
    ),
)
Base.:+(a::RelativeQuantity, b::Real) = throw(
    ArgumentError(
        "cannot combine/compare a unit-tagged quantity ($(unit(a))) with an untagged number; " *
        "strip units or tag the number first",
    ),
)
Base.:+(a::Real, b::RelativeQuantity) = throw(
    ArgumentError(
        "cannot combine/compare an untagged number with a unit-tagged quantity ($(unit(b))); " *
        "strip units or tag the number first",
    ),
)
Base.:-(a::RelativeQuantity, b::Real) = throw(
    ArgumentError(
        "cannot combine/compare a unit-tagged quantity ($(unit(a))) with an untagged number; " *
        "strip units or tag the number first",
    ),
)
Base.:-(a::Real, b::RelativeQuantity) = throw(
    ArgumentError(
        "cannot combine/compare an untagged number with a unit-tagged quantity ($(unit(b))); " *
        "strip units or tag the number first",
    ),
)

# Needed because Unitful.jl isn't a dependency of IS — domain packages (e.g.
# PSY) extend `_strip_units` with a method for `Unitful.Quantity`.
"""
    _strip_units(x)

Drop the unit wrapper and return the bare numeric value. Used by generated
unit-aware getters so `get_X(c, units)` returns a `Float64` while
`get_X_unitful(c, units)` keeps the wrapper. The fallback returns its argument
unchanged; domain packages MUST extend `_strip_units` for their own quantity
wrapper types (e.g. `Unitful.Quantity`), otherwise `get_X` returns the wrapper
rather than a bare number.
"""
_strip_units(x) = x
_strip_units(q::RelativeQuantity) = q.value
_strip_units(t::NamedTuple) = map(_strip_units, t)

# Type conversions
Base.convert(::Type{RelativeQuantity{T, U}}, q::RelativeQuantity{S, U}) where {T, S, U} =
    RelativeQuantity(convert(T, q.value), unit(q))
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

"""
    display_string(x) -> String

Render `x` for human-facing display, spelling relative-unit tags out in full
("0.6 p.u. in component base") where `show` prints the terse "0.6 DU". `DU`/`SU`
are convenient to type but are not standard terminology, so verbose output
(e.g. a component's `text/plain` display) spells them out; terse contexts such
as tabular cells keep the short tags.

Recurses into `NamedTuple`s so compound fields (e.g. `(min = …, max = …)`) are spelled
out element-wise. When every element shares one per-unit base — the usual case for a
compound field — the base is stated once after the tuple rather than repeated per
element, which keeps the line readable:
`(min = 0.0 p.u., max = 2.5 p.u.) in system base`.

Anything else renders exactly as `print` would.
"""
display_string(x) = string(x)
display_string(q::RelativeQuantity) =
    string(_per_unit_string(q), " in ", _base_label(unit(q)))

_per_unit_string(q::RelativeQuantity) = string(q.value, " p.u.")
_base_label(::DeviceBaseUnit) = "component base"
_base_label(::SystemBaseUnit) = "system base"

function display_string(t::NamedTuple)
    vals = values(t)
    shared = _shared_relative_unit(vals)
    isnothing(shared) || return string(
        "(",
        join(("$k = $(_per_unit_string(v))" for (k, v) in pairs(t)), ", "),
        ") in ",
        _base_label(shared),
    )
    return string(
        "(",
        join(("$k = $(display_string(v))" for (k, v) in pairs(t)), ", "),
        ")",
    )
end

# The single per-unit marker every value carries, or `nothing` if they are not all
# `RelativeQuantity`s on one base (a mixed or empty tuple has no base to factor out).
function _shared_relative_unit(vals::Tuple)
    isempty(vals) && return nothing
    first(vals) isa RelativeQuantity || return nothing
    u = unit(first(vals))
    all(v -> v isa RelativeQuantity && unit(v) === u, vals) || return nothing
    return u
end

Base.zero(::Type{RelativeQuantity{T, U}}) where {T, U} = RelativeQuantity(zero(T), U())
Base.one(::Type{RelativeQuantity{T, U}}) where {T, U} = RelativeQuantity(one(T), U())
Base.hash(q::RelativeQuantity{T, U}, h::UInt) where {T, U} = hash(q.value, hash(U, h))

# Instance forms: Base's Number fallbacks for these need
# `convert(::Type{<:RelativeQuantity}, ::Real)`, which is deliberately
# undefined — implicit unit-attachment is the bug class this design prevents.
Base.zero(::RelativeQuantity{T, U}) where {T, U} = RelativeQuantity(zero(T), U())
Base.one(::RelativeQuantity{T, U}) where {T, U} = RelativeQuantity(one(T), U())
Base.iszero(q::RelativeQuantity) = iszero(q.value)
Base.isnan(q::RelativeQuantity) = isnan(q.value)
Base.isfinite(q::RelativeQuantity) = isfinite(q.value)
Base.isinf(q::RelativeQuantity) = isinf(q.value)
Base.abs(q::RelativeQuantity) = RelativeQuantity(abs(q.value), unit(q))

# `isequal` must be total — Dict/Set lookups call it on arbitrary key pairs —
# so unlike `==`, mixing bases or tagged/untagged values answers `false`
# rather than erroring.
Base.isequal(
    a::RelativeQuantity{<:Any, U1},
    b::RelativeQuantity{<:Any, U2},
) where {U1, U2} = U1 === U2 && isequal(a.value, b.value)
Base.isequal(::RelativeQuantity, ::Real) = false
Base.isequal(::Real, ::RelativeQuantity) = false

Base.isapprox(a::RelativeQuantity, b::Real; kwargs...) = throw(
    ArgumentError(
        "cannot compare a unit-tagged quantity ($(unit(a))) with an untagged number; " *
        "strip units or tag the number first",
    ),
)
Base.isapprox(a::Real, b::RelativeQuantity; kwargs...) = throw(
    ArgumentError(
        "cannot compare an untagged number with a unit-tagged quantity ($(unit(b))); " *
        "strip units or tag the number first",
    ),
)

# Products/quotients of two tagged quantities have no representable unit
# (this also catches `q^2`, which lowers to `q * q`).
Base.:*(a::RelativeQuantity, b::RelativeQuantity) = throw(
    ArgumentError(
        "cannot multiply two unit-tagged quantities ($(unit(a)) × $(unit(b))); " *
        "strip units first",
    ),
)
Base.:/(a::RelativeQuantity, b::RelativeQuantity) = throw(
    ArgumentError(
        "cannot divide two unit-tagged quantities ($(unit(a)) / $(unit(b))); " *
        "strip units first",
    ),
)

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
object (e.g. `MW` from a Unitful-based package); callers should not assume it
is an `AbstractRelativeUnit`. Keyed on both function and type because the same
getter name can appear on both unit-bearing and non-unit-bearing structs
(e.g. `get_b` on `Line` vs. `DynamicExponentialLoad`). Downstream packages
set this per-struct (typically via the struct-generator template); consumers
like `show_components` dispatch on the result to avoid runtime method
introspection.
"""
display_units_arg(_, ::Type) = missing

"""
    unitful_variant(f::Function)

Resolve the unit-bearing companion of getter `f` — a function returning the
same value but unit-tagged (a `RelativeQuantity` or a domain `Unitful.Quantity`)
instead of a bare number — following the `\$(f)_unitful` naming convention the
struct-generator template emits alongside every converted getter (see
`generate_structs.jl`). Falls back to `f` itself when no such companion exists
(hand-written getters that don't provide one). Display/tabular code should
resolve through this trait rather than re-deriving the naming convention.
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
