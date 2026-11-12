"""
$(TYPEDEF)
$(TYPEDFIELDS)

    TwoTierFuelCurve(; first_tier_curve, second_tier_curve, tier_threshold, fuel_units,
        power_units, first_tier_fuel_cost, second_tier_fuel_cost,
        second_tier_fuel_cost_time_series, vom_cost)

Fuel use of a unit whose output comes from two sources stacked along the power axis, each
with its own [`ValueCurve`](@ref) and fuel price. Output up to `tier_threshold` follows the
first tier and output above it follows the second. A combined cycle steam turbine is the
motivating case: recovered exhaust heat first, duct firing above it.

Both tiers are required; a unit with one tier uses a [`FuelCurve`](@ref). `T` is the second
tier's curve type and `F` the first tier's. The second tier's value at the threshold has no
meaning: consumers price only its increase above the threshold. A `first_tier_fuel_cost` of
`0.0` means the first tier's fuel is paid for elsewhere.
"""
struct TwoTierFuelCurve{
    T <: ValueCurve,
    F <: ValueCurve,
    U <: AbstractUnitSystem,
    Y <: Unitful.Units,
} <: ProductionVariableCostCurve{T, U, Y}
    "Fuel use against output for output up to `tier_threshold`"
    first_tier_curve::F
    "Fuel use against output for output above `tier_threshold`"
    second_tier_curve::T
    "Output, in the curve's power units, where the second tier starts"
    tier_threshold::Float64
    "(default of 0) Price of first tier fuel; `0.0` means it is paid for elsewhere"
    first_tier_fuel_cost::Float64
    "A fixed price for second tier fuel; mutually exclusive with `second_tier_fuel_cost_time_series`"
    second_tier_fuel_cost::Union{Nothing, Float64}
    "The [`TimeSeriesKey`](@ref) to a second tier fuel price time series"
    second_tier_fuel_cost_time_series::Union{Nothing, ScalarTimeSeriesKey}
    "(default of 0) Variable operation and maintenance cost, a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve

    function TwoTierFuelCurve{T, F, U, Y}(
        first_tier_curve::F,
        second_tier_curve::T,
        tier_threshold::Float64,
        first_tier_fuel_cost::Float64,
        second_tier_fuel_cost::Union{Nothing, Float64},
        second_tier_fuel_cost_time_series::Union{Nothing, TimeSeriesKey},
        vom_cost::LinearCurve,
    ) where {T, F, U, Y}
        if isnothing(second_tier_fuel_cost) == isnothing(second_tier_fuel_cost_time_series)
            throw(
                ArgumentError(
                    "TwoTierFuelCurve requires exactly one of second_tier_fuel_cost or " *
                    "second_tier_fuel_cost_time_series; got " *
                    "second_tier_fuel_cost=$second_tier_fuel_cost, " *
                    "second_tier_fuel_cost_time_series=$second_tier_fuel_cost_time_series",
                ),
            )
        end
        if !isfinite(tier_threshold) || tier_threshold < 0.0
            throw(
                ArgumentError(
                    "tier_threshold must be finite and not negative; got $tier_threshold",
                ),
            )
        end
        if !isfinite(first_tier_fuel_cost) || first_tier_fuel_cost < 0.0
            throw(
                ArgumentError(
                    "first_tier_fuel_cost must be finite and not negative; got $first_tier_fuel_cost",
                ),
            )
        end
        _check_tier_meets_threshold(
            first_tier_curve,
            last,
            tier_threshold,
            "first tier ends",
        )
        _check_tier_meets_threshold(
            second_tier_curve,
            first,
            tier_threshold,
            "second tier starts",
        )
        return new{T, F, U, Y}(first_tier_curve, second_tier_curve, tier_threshold,
            first_tier_fuel_cost, second_tier_fuel_cost, second_tier_fuel_cost_time_series,
            vom_cost)
    end
end

# A piecewise tier must end (first) or start (second) at the threshold; other curves have
# no x range to check.
_check_tier_meets_threshold(::ValueCurve, _, ::Float64, ::String) = nothing
function _check_tier_meets_threshold(
    curve::Union{PiecewisePointCurve, PiecewiseIncrementalCurve, PiecewiseAverageCurve},
    pick,
    threshold::Float64,
    what::String,
)
    x = pick(get_x_coords(get_function_data(curve)))
    isapprox(x, threshold) ||
        throw(ArgumentError("the $what at $x but tier_threshold is $threshold"))
    return
end

function TwoTierFuelCurve(;
    first_tier_curve::ValueCurve,
    second_tier_curve::ValueCurve,
    tier_threshold::Real,
    fuel_units::Unitful.Units,
    power_units::AbstractUnitSystem = NaturalUnit(),
    first_tier_fuel_cost::Real = 0.0,
    second_tier_fuel_cost::Union{Nothing, Real} = nothing,
    second_tier_fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    return TwoTierFuelCurve{
        typeof(second_tier_curve),
        typeof(first_tier_curve),
        typeof(power_units),
        _fuel_rate_type(fuel_units),
    }(
        first_tier_curve,
        second_tier_curve,
        Float64(tier_threshold),
        Float64(first_tier_fuel_cost),
        _normalize_fuel_cost(second_tier_fuel_cost),
        second_tier_fuel_cost_time_series,
        vom_cost,
    )
end

"Get the curve of the first tier, output up to the threshold"
get_first_tier_curve(c::TwoTierFuelCurve) = c.first_tier_curve
"Get the curve of the second tier, output above the threshold"
get_second_tier_curve(c::TwoTierFuelCurve) = c.second_tier_curve
"Get the output where the second tier starts, in the curve's power units"
get_tier_threshold(c::TwoTierFuelCurve) = c.tier_threshold
"Get the price of first tier fuel; `0.0` means it is paid for elsewhere"
get_first_tier_fuel_cost(c::TwoTierFuelCurve) = c.first_tier_fuel_cost
"Get the fixed price of second tier fuel, or `nothing` when it is a time series"
get_second_tier_fuel_cost(c::TwoTierFuelCurve) = c.second_tier_fuel_cost
"Get the time series key of the second tier fuel price, or `nothing` when it is fixed"
get_second_tier_fuel_cost_time_series(c::TwoTierFuelCurve) =
    c.second_tier_fuel_cost_time_series
"Whether first tier fuel carries a price"
is_first_tier_priced(c::TwoTierFuelCurve) = c.first_tier_fuel_cost > 0.0

# Generic callers that price a curve get the priced tier.
get_value_curve(c::TwoTierFuelCurve) = c.second_tier_curve
get_fuel_units(c::TwoTierFuelCurve) = get_y_units(c) * Unitful.hr
_free_axis_units(c::TwoTierFuelCurve) = (; fuel_units = get_fuel_units(c))
is_convex(c::TwoTierFuelCurve) =
    is_convex(c.first_tier_curve) && is_convex(c.second_tier_curve)
is_time_series_backed(c::TwoTierFuelCurve) =
    is_time_series_backed(c.first_tier_curve) ||
    is_time_series_backed(c.second_tier_curve) ||
    !isnothing(c.second_tier_fuel_cost_time_series)
get_time_series_key(::TwoTierFuelCurve) = throw(
    ArgumentError(
        "get_time_series_key is not defined for TwoTierFuelCurve; its tiers and its " *
        "second tier price are separate fields",
    ),
)

"""
Convert a [`TwoTierFuelCurve`](@ref) to the `to` unit system. Both tiers, the threshold and
`vom_cost` move; the fuel prices are per unit of fuel and stay.
"""
function convert_power_units(
    c::TwoTierFuelCurve{T, F, U, Y},
    to::V,
    x_ratio::Real,
    y_ratio::Real,
) where {T, F, U <: AbstractUnitSystem, Y, V <: AbstractUnitSystem}
    first_tier = inv(y_ratio) * scale_x(c.first_tier_curve, x_ratio)
    second_tier = inv(y_ratio) * scale_x(c.second_tier_curve, x_ratio)
    return TwoTierFuelCurve{typeof(second_tier), typeof(first_tier), V, Y}(
        first_tier,
        second_tier,
        c.tier_threshold / x_ratio,
        c.first_tier_fuel_cost,
        c.second_tier_fuel_cost,
        c.second_tier_fuel_cost_time_series,
        scale_x(c.vom_cost, x_ratio),
    )
end
convert_power_units(
    c::TwoTierFuelCurve{T, F, U},
    ::U,
    ::Real,
    ::Real,
) where {T, F, U <: AbstractUnitSystem} = c

_deserialize_curve_field(::Val{:first_tier_curve}, raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)
_deserialize_curve_field(::Val{:second_tier_curve}, raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)
_deserialize_curve_field(::Val{:tier_threshold}, raw::Real) = Float64(raw)
_deserialize_curve_field(::Val{:first_tier_fuel_cost}, raw::Real) = Float64(raw)
_deserialize_curve_field(::Val{:second_tier_fuel_cost}, raw) = _deserialize_fuel_cost(raw)
_deserialize_curve_field(::Val{:second_tier_fuel_cost_time_series}, raw) =
    _deserialize_fuel_cost_time_series(raw)

function _show_compact(io::IO, ::MIME"text/plain", c::TwoTierFuelCurve)
    print(io, "$(nameof(typeof(c))) with first tier ")
    show(IOContext(io, :compact => true), "text/plain", c.first_tier_curve)
    print(io, ", second tier ")
    show(IOContext(io, :compact => true), "text/plain", c.second_tier_curve)
    print(io, " above $(c.tier_threshold)")
end
