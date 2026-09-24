# Per-unit values as Unitful quantities. Callers write the generic `u"CU"`/`u"SU"`; a domain
# package registers one Unitful dimension per per-unitized base (PowerSystems: component and
# system base power, component base voltage) and passes each field's base units to
# `resolve_per_unit`, so per-unit values of different kinds get different dimensions. Nothing
# here may name a domain quantity. Separate from `RelativeUnits`, which binds `CU`/`SU` to the
# unit-system markers.

"""
The generic per-unit units `u"CU"` and `u"SU"`, and [`resolve_per_unit`](@ref), which
replaces them with the base units a field is per-unitized on.

Unitful's `u"..."` macro only searches unit modules bound by name in the calling module,
so code that writes `u"CU"` needs `using InfrastructureSystems: PerUnit` (or a package
that re-exports `PerUnit`).
"""
module PerUnit

import Unitful
using Unitful: @dimension, @refunit

# Own dimensions: no conversion to natural units, and CU and SU don't mix.
@dimension 𝐂𝐔 "𝐂𝐔" GenericComponentBase
@dimension 𝐒𝐔 "𝐒𝐔" GenericSystemBase
@refunit CU "CU" CU 𝐂𝐔 false
@refunit SU "SU" SU 𝐒𝐔 false

# Promotions recorded during precompilation don't persist; restore them at load (per
# Unitful's docs for packages that define dimensions).
const _LOCAL_PROMOTION = copy(Unitful.promotion)

function __init__()
    merge!(Unitful.promotion, _LOCAL_PROMOTION)
    Unitful.register(PerUnit)
    return
end

# `Val((k_cu, k_su))`, the exponents of `CU` and `SU` in `units`, computed from the type in
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
    return :(Val(($k_cu, $k_su)))
end

_resolve(::Val{(0, 0)}, units, _, _) = units
_resolve(::Val{(1, 0)}, units, component_base, _) = component_base * (units / CU)
_resolve(::Val{(0, 1)}, units, _, system_base) = system_base * (units / SU)
_resolve(::Val, units, _, _) = throw(
    ArgumentError(
        "cannot resolve per-unit target $units: write `CU` or `SU` exactly once, to " *
        "the first power (e.g. `u\"CU\"`, `u\"SU/hr\"`)",
    ),
)

"""
    resolve_per_unit(units, component_base, system_base) -> Unitful.Units

Replace a generic `u"CU"` or `u"SU"` in `units` with `component_base` or `system_base`,
keeping whatever else the caller wrote. Units with neither are returned unchanged, so a
natural target like `u"MW"` passes through.

`component_base` and `system_base` are the domain's units for one field: what one
per-unit of that field's quantity is on each base. The caller never has to know them,
which is why a getter can take a bare `u"CU"` for any field.

```julia
resolve_per_unit(u"CU/hr", cu_base, su_base)   # == cu_base / u"hr"
resolve_per_unit(u"MW", cu_base, su_base)      # == u"MW"
```

Throws an `ArgumentError` for `CU` or `SU` raised to a power other than one, or for
both in one expression: neither says which base the field is per-unit on.
"""
resolve_per_unit(
    units::Unitful.Units,
    component_base::Unitful.Units,
    system_base::Unitful.Units,
) = _resolve(_generic_exponents(units), units, component_base, system_base)

end # module PerUnit
