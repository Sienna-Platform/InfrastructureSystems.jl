"""
Units for the non-power axes of [`CostCurve`](@ref) and [`FuelCurve`](@ref): `USD`, and
`MMBtu` (Unitful has `btu` but no prefixed forms of it).

Unitful's `u"..."` macro only searches unit modules bound by name in the calling module,
so code that writes `u"USD"` needs `using InfrastructureSystems: CommodityUnits` (or a
package that re-exports it).
"""
module CommodityUnits

import Unitful
using Unitful: @dimension, @refunit, @unit

# Currency is its own base dimension: there is no existing unit to scale it from.
@dimension 𝐂 "𝐂" Currency
@refunit USD "USD" USD 𝐂 false
@unit MMBtu "MMBtu" MillionBtu (10^6) * Unitful.btu false

# Promotions recorded during precompilation don't persist; restore them at load (per
# Unitful's docs for packages that define dimensions).
const _LOCAL_PROMOTION = copy(Unitful.promotion)

function __init__()
    merge!(Unitful.promotion, _LOCAL_PROMOTION)
    Unitful.register(CommodityUnits)
    return
end

end # module CommodityUnits
