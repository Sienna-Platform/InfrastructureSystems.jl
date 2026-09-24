# Per-unit values as Unitful quantities. Callers write the generic `u"CU"`, `u"SU"` or
# `u"NU"`; a domain package registers one Unitful dimension per per-unitized base
# (PowerSystems: component and system base power, component base voltage) and passes each
# field's units to `resolve_per_unit`, so per-unit values of different kinds get different
# dimensions. Nothing here may name a domain quantity. Separate from `RelativeUnits`, which
# binds `CU`/`SU`/`NU` to the unit-system markers.

"""
The generic units `u"CU"`, `u"SU"` and `u"NU"`, and [`resolve_per_unit`](@ref), which
replaces them with the units a field is per-unitized on (or its natural unit).

Unitful's `u"..."` macro only searches unit modules bound by name in the calling module,
so code that writes `u"CU"` needs `using InfrastructureSystems: PerUnit` (or a package
that re-exports `PerUnit`).
"""
module PerUnit

import Unitful
using Unitful: @dimension, @refunit

# Own dimensions: no conversion to natural units, and the three don't mix.
@dimension 𝐂𝐔 "𝐂𝐔" GenericComponentBase
@dimension 𝐒𝐔 "𝐒𝐔" GenericSystemBase
@dimension 𝐍𝐔 "𝐍𝐔" GenericNatural
@refunit CU "CU" CU 𝐂𝐔 false
@refunit SU "SU" SU 𝐒𝐔 false
@refunit NU "NU" NU 𝐍𝐔 false

# Promotions recorded during precompilation don't persist; restore them at load (per
# Unitful's docs for packages that define dimensions).
const _LOCAL_PROMOTION = copy(Unitful.promotion)

function __init__()
    merge!(Unitful.promotion, _LOCAL_PROMOTION)
    Unitful.register(PerUnit)
    return
end

# `Val((k_cu, k_su, k_nu))`, the exponents of `CU`, `SU`, `NU` in `units`, computed from the type in
# the generator so `resolve_per_unit` folds by dispatch rather than relying on const-prop.
# Whole exponents become `Int`s to match the `_resolve` methods; fractional ones stay
# `Rational` and hit the error method.
@generated function _generic_exponents(::Unitful.Units{N, D}) where {N, D}
    dims = typeof(D).parameters[1]
    exponent(name) =
        sum((d.power for d in dims if d isa Unitful.Dimension{name}); init = 0)
    whole(x) = isinteger(x) ? Int(x) : x
    k_cu = whole(exponent(:GenericComponentBase))
    k_su = whole(exponent(:GenericSystemBase))
    k_nu = whole(exponent(:GenericNatural))
    return :(Val(($k_cu, $k_su, $k_nu)))
end

_resolve(::Val{(0, 0, 0)}, units, _, _, _) = units
_resolve(::Val{(1, 0, 0)}, units, component_base, _, _) = component_base * (units / CU)
_resolve(::Val{(0, 1, 0)}, units, _, system_base, _) = system_base * (units / SU)
_resolve(::Val{(0, 0, 1)}, units, _, _, natural) = natural * (units / NU)
_resolve(::Val, units, _, _, _) = throw(
    ArgumentError(
        "cannot resolve target $units: write one of `CU`, `SU`, `NU` exactly once, to " *
        "the first power (e.g. `u\"CU\"`, `u\"SU/hr\"`)",
    ),
)

"""
    resolve_per_unit(units, component_base, system_base, natural) -> Unitful.Units

Replace a generic `u"CU"`, `u"SU"` or `u"NU"` in `units` with `component_base`,
`system_base` or `natural`, keeping whatever else the caller wrote. Units with none of them
are returned unchanged, so an explicit target like `u"MW"` passes through.

The three are the domain's units for one field: what one per-unit of that field's quantity
is on each base, and the natural unit of the same quantity. The caller never has to know
them, which is why a getter can take a bare `u"CU"` or `u"NU"` for any field.

```julia
resolve_per_unit(u"CU/hr", cu_base, su_base, natural)   # == cu_base / u"hr"
resolve_per_unit(u"NU", cu_base, su_base, natural)      # == natural
resolve_per_unit(u"MW", cu_base, su_base, natural)      # == u"MW"
```

Throws an `ArgumentError` for a generic unit raised to a power other than one, or for more
than one in an expression: neither says which units the field is in.
"""
resolve_per_unit(
    units::Unitful.Units,
    component_base::Unitful.Units,
    system_base::Unitful.Units,
    natural::Unitful.Units,
) = _resolve(_generic_exponents(units), units, component_base, system_base, natural)

end # module PerUnit
