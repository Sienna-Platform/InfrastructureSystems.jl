"""
Supertype for production variable cost curve representations.

A [`ValueCurveWithUnits`](@ref) that additionally carries a `vom_cost`.

Concrete subtypes are [`CostCurve`](@ref), [`FuelCurve`](@ref) and
[`DualFuelCurve`](@ref).
"""
abstract type ProductionVariableCostCurve{
    T <: ValueCurve,
    U <: AbstractUnitSystem,
    Y <: Unitful.Units,
} <: ValueCurveWithUnits{T, U, _MW, Y} end

"Get the variable operation and maintenance cost in currency/(power_units h)"
get_vom_cost(cost::ProductionVariableCostCurve) = cost.vom_cost

"""
$(TYPEDEF)
$(TYPEDFIELDS)

    CostCurve(value_curve)
    CostCurve(value_curve, power_units)
    CostCurve(value_curve, vom_cost)
    CostCurve(value_curve, power_units, vom_cost)
    CostCurve(; value_curve, power_units, vom_cost)

Direct representation of the variable operation cost of a power plant in currency. Composed
of a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate
data. The x-axis is power, stored on the basis given by the second type parameter
`U <: AbstractUnitSystem`; `power_units` at construction is the singleton instance `U()`
(default `NaturalUnit()`). The y-axis is currency per hour (`USD/h`), which has no basis.
"""
struct CostCurve{T <: ValueCurve, U <: AbstractUnitSystem} <:
       ProductionVariableCostCurve{T, U, _USD_PER_HOUR}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in
    \$/(power_unit h), represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve

    CostCurve{T, U}(value_curve::T, vom_cost::LinearCurve) where {T, U} =
        new{T, U}(value_curve, vom_cost)
end

CostCurve{T, U}(;
    value_curve::T,
    vom_cost::LinearCurve = LinearCurve(0.0),
) where {T, U} = CostCurve{T, U}(value_curve, vom_cost)

# Outer constructors — default U = NaturalUnit when not specified
CostCurve(value_curve::T) where {T <: ValueCurve} =
    CostCurve{T, NaturalUnit}(; value_curve)
CostCurve(value_curve::T, vom_cost::LinearCurve) where {T <: ValueCurve} =
    CostCurve{T, NaturalUnit}(; value_curve, vom_cost)
CostCurve(
    value_curve::T,
    power_units::U,
) where {T <: ValueCurve, U <: AbstractUnitSystem} =
    CostCurve{T, U}(; value_curve)
CostCurve(
    value_curve::T,
    power_units::U,
    vom_cost::LinearCurve,
) where {T <: ValueCurve, U <: AbstractUnitSystem} =
    CostCurve{T, U}(; value_curve, vom_cost)

# Keyword-based constructor exposing `power_units`, replacing the former field default.
function CostCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    return CostCurve{typeof(value_curve), typeof(power_units)}(; value_curve, vom_cost)
end

"Get a `CostCurve` representing zero variable cost (NaturalUnit)"
Base.zero(::Type{CostCurve}) = CostCurve(zero(ValueCurve))
"Get a `CostCurve` representing zero variable cost, preserving the unit system of `c`"
Base.zero(::CostCurve{T, U}) where {T, U} = CostCurve(zero(ValueCurve), U())

"""
`CostCurve{T}` with any unit system. Equivalent to `CostCurve{T, U} where U`;
use at `isa` sites where the unit-system parameter doesn't matter.
"""
const AnyCostCurve{T} = CostCurve{T, U} where {U <: AbstractUnitSystem}

"""
$(TYPEDEF)
$(TYPEDFIELDS)

    FuelCurve(value_curve, fuel_units, fuel_cost)
    FuelCurve(value_curve, fuel_units, fuel_cost_time_series)
    FuelCurve(value_curve, fuel_units, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(value_curve, power_units, fuel_units, fuel_cost)
    FuelCurve(value_curve, power_units, fuel_units, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(; value_curve, power_units, fuel_units, fuel_cost, fuel_cost_time_series, startup_fuel_offtake, vom_cost)

Representation of the variable operation cost of a power plant in terms of fuel, coupled
with a conversion factor between fuel and currency. Composed of a [`ValueCurve`](@ref) that
may represent input-output, incremental, or average rate data.

The x-axis is power, stored on the basis given by the second type parameter
`U <: AbstractUnitSystem`; `power_units` at construction is the singleton instance `U()`
(default `NaturalUnit()`). The y-axis is fuel per hour, which has no basis: `fuel_units` names the fuel
quantity (`u"MMBtu"`, `u"GJ"`, `u"L"`, ...) and has no default, since an unstated fuel unit
is ambiguous. `fuel_cost` is currency per `fuel_units`.
Exactly one of `fuel_cost` or `fuel_cost_time_series` must be provided.
"""
struct FuelCurve{T <: ValueCurve, U <: AbstractUnitSystem, Y <: Unitful.Units} <:
       ProductionVariableCostCurve{T, U, Y}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "A fixed value for fuel cost; mutually exclusive with `fuel_cost_time_series`"
    fuel_cost::Union{Nothing, Float64}
    "The [`TimeSeriesKey`](@ref) to a fuel cost time series; mutually exclusive with `fuel_cost`"
    fuel_cost_time_series::Union{Nothing, ScalarTimeSeriesKey}
    "(default of 0) Fuel consumption at the unit startup proceedure. Additional cost to the startup costs and related only to the initial fuel required to start the unit.
    represented as a [`LinearCurve`](@ref)"
    startup_fuel_offtake::LinearCurve
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in \$/(power_unit h)
    represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve

    function FuelCurve{T, U, Y}(
        value_curve::T,
        fuel_cost::Union{Nothing, Float64},
        fuel_cost_time_series::Union{Nothing, TimeSeriesKey},
        startup_fuel_offtake::LinearCurve,
        vom_cost::LinearCurve,
    ) where {T, U, Y}
        if isnothing(fuel_cost) == isnothing(fuel_cost_time_series)
            throw(
                ArgumentError(
                    "FuelCurve requires exactly one of fuel_cost (fixed) or " *
                    "fuel_cost_time_series (time-varying); got " *
                    "fuel_cost=$fuel_cost, fuel_cost_time_series=$fuel_cost_time_series",
                ),
            )
        end
        return new{T, U, Y}(value_curve, fuel_cost, fuel_cost_time_series,
            startup_fuel_offtake, vom_cost)
    end
end

FuelCurve{T, U, Y}(;
    value_curve::T,
    fuel_cost::Union{Nothing, Float64} = nothing,
    fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
) where {T, U, Y} =
    FuelCurve{T, U, Y}(value_curve, fuel_cost, fuel_cost_time_series,
        startup_fuel_offtake, vom_cost)

# The y-axis is fuel per hour; callers name the fuel quantity.
_fuel_rate_type(fuel_units::Unitful.Units) = typeof(fuel_units / Unitful.hr)

_normalize_fuel_cost(::Nothing) = nothing
_normalize_fuel_cost(x::Real) = Float64(x)

# Which field a positionally supplied fuel cost lands in: the fixed value and the
# time series key are separate fields, so the routing is dispatched, not branched.
_fuel_cost_kwargs(fuel_cost::Real) = (; fuel_cost = _normalize_fuel_cost(fuel_cost))
_fuel_cost_kwargs(fuel_cost::TimeSeriesKey) = (; fuel_cost_time_series = fuel_cost)

# Outer constructors — mirror the CostCurve style
FuelCurve(
    value_curve::T,
    fuel_units::Unitful.Units,
    fuel_cost::Union{Real, TimeSeriesKey},
) where {T <: ValueCurve} = FuelCurve(value_curve, NaturalUnit(), fuel_units, fuel_cost)

FuelCurve(
    value_curve::T,
    fuel_units::Unitful.Units,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve} = FuelCurve(
    value_curve, NaturalUnit(), fuel_units, fuel_cost, startup_fuel_offtake, vom_cost)

FuelCurve(
    value_curve::T,
    ::U,
    fuel_units::Unitful.Units,
    fuel_cost::Union{Real, TimeSeriesKey},
) where {T <: ValueCurve, U <: AbstractUnitSystem} =
    FuelCurve{T, U, _fuel_rate_type(fuel_units)}(;
        value_curve,
        _fuel_cost_kwargs(fuel_cost)...,
    )

FuelCurve(
    value_curve::T,
    ::U,
    fuel_units::Unitful.Units,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve, U <: AbstractUnitSystem} =
    FuelCurve{T, U, _fuel_rate_type(fuel_units)}(;
        value_curve,
        _fuel_cost_kwargs(fuel_cost)...,
        startup_fuel_offtake,
        vom_cost,
    )

function FuelCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
    fuel_units::Unitful.Units,
    fuel_cost::Union{Nothing, Real} = nothing,
    fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    return FuelCurve{
        typeof(value_curve),
        typeof(power_units),
        _fuel_rate_type(fuel_units),
    }(;
        value_curve,
        fuel_cost = _normalize_fuel_cost(fuel_cost),
        fuel_cost_time_series,
        startup_fuel_offtake,
        vom_cost,
    )
end

# There is no `zero(::Type{FuelCurve})`: it would have to pick a fuel unit.
"Get a `FuelCurve` representing zero fuel usage and zero fuel cost, preserving the units of `c`"
Base.zero(c::FuelCurve{T, U}) where {T, U} =
    FuelCurve(zero(ValueCurve), U(), get_fuel_units(c), 0.0)

"Get the units of the fuel quantity, e.g. `u\"MMBtu\"`; `fuel_cost` is currency per one of these"
get_fuel_units(c::FuelCurve) = get_y_units(c) * Unitful.hr

_free_axis_units(curve::FuelCurve) = (; fuel_units = get_fuel_units(curve))
_deserialize_curve_field(::Val{:fuel_units}, raw::AbstractString) = _parse_units(raw)

"Get the fixed fuel cost, or `nothing` if it is time-series-backed"
get_fuel_cost(cost::FuelCurve) = cost.fuel_cost
"Get the fuel cost time series key, or `nothing` if it is a fixed value"
get_fuel_cost_time_series(cost::FuelCurve) = cost.fuel_cost_time_series
"Get the function for the fuel consumption at startup"
get_startup_fuel_offtake(cost::FuelCurve) = cost.startup_fuel_offtake

is_time_series_backed(::TimeSeriesKey) = true
is_time_series_backed(::Union{Nothing, Float64}) = false
"Check if the cost curve is backed by time series data"
is_time_series_backed(cost::ProductionVariableCostCurve) =
    is_time_series_backed(get_value_curve(cost))
# FuelCurve's fuel_cost and fuel_cost_time_series are orthogonal fields — check the value
# curve and fuel_cost_time_series.
is_time_series_backed(cost::FuelCurve) =
    is_time_series_backed(get_value_curve(cost)) ||
    !isnothing(get_fuel_cost_time_series(cost))

# `get_time_series_key` is intentionally undefined for `FuelCurve`: its value curve and
# `fuel_cost` are independently time-series-backed, so a single accessor would be
# ambiguous. Callers resolve explicitly via `get_time_series_key(get_value_curve(c))` or
# `get_fuel_cost_time_series(c)`. These throwing methods shadow the generic TS method above for every
# `FuelCurve` (the second is needed to resolve dispatch ambiguity with that generic
# method when the value curve is TS-backed).
_fuel_curve_no_ts_key() = throw(
    ArgumentError(
        "get_time_series_key is not defined for FuelCurve; its value curve and fuel_cost " *
        "are independently time-series-backed — resolve explicitly via " *
        "get_time_series_key(get_value_curve(c)) or get_fuel_cost_time_series(c)",
    ),
)
get_time_series_key(::FuelCurve) = _fuel_curve_no_ts_key()
get_time_series_key(::FuelCurve{<:ValueCurve{<:TimeSeriesFunctionData}}) =
    _fuel_curve_no_ts_key()

# ── Unit conversion ───────────────────────────────────────────────────────────
# These families' y-axes (\$/h, MMBtu/h) have no per-unit base, so `y_ratio` is 1 and only
# x moves. `scale_x` still changes the stored y *data* of an
# `IncrementalCurve`/`AverageRateCurve`: those y-axes are rates per unit of x (\$/MWh), so
# that factor is the chain rule inside `scale_x`, not a y-scaling.

"""
$(TYPEDSIGNATURES)

Convert `curve` to the `to` unit system, returning a curve of the same outer type whose
`U` parameter is `typeof(to)`.

`x_ratio` and `y_ratio` are the ratios between the two bases on each axis:
`x_from = x_ratio * x_to`, likewise for y. They are passed in rather than derived here
because `InfrastructureSystems` has no notion of a component or a base power to derive them
from -- the base arithmetic belongs to the domain package that owns the bases (in the
Sienna stack, `PowerSystems`, which resolves them per component from [`get_x_units`](@ref)
and [`get_y_units`](@ref) and provides the component-aware accessors on top of this). An
axis with no per-unit base, like this family's y-axis, has a ratio of 1.

The `fuel_cost` of a [`FuelCurve`](@ref) is in currency per unit of fuel and is left
alone. Time-series-backed value curves cannot be rescaled and raise an `ArgumentError`.
"""
convert_power_units(
    curve::CostCurve{T, U},
    to::V,
    x_ratio::Real,
    y_ratio::Real,
) where {T <: ValueCurve, U <: AbstractUnitSystem, V <: AbstractUnitSystem} =
    CostCurve(
        _convert_value_curve(curve, x_ratio, y_ratio),
        to,
        inv(y_ratio) * scale_x(get_vom_cost(curve), x_ratio),
    )

"""
$(TYPEDSIGNATURES)

Convert a [`FuelCurve`](@ref) to the `to` unit system. Only the value curve and `vom_cost`
are rescaled — both are functions of the production quantity on the x-axis.

`fuel_cost` is currency per unit of fuel, and `startup_fuel_offtake` is fuel consumed as a
function of *downtime*: its x-axis is a duration and its y-axis is a fuel quantity, so a
change of power units touches neither. Both carry over unchanged, as does a
time-series-backed `fuel_cost_time_series`.
"""
function convert_power_units(
    curve::FuelCurve{T, U, Y},
    to::V,
    x_ratio::Real,
    y_ratio::Real,
) where {T <: ValueCurve, U <: AbstractUnitSystem, Y, V <: AbstractUnitSystem}
    # `startup_fuel_offtake` is fuel vs. downtime — neither axis is in power units.
    value_curve = _convert_value_curve(curve, x_ratio, y_ratio)
    # `fuel_cost` and `fuel_cost_time_series` are mutually exclusive, and neither is in
    # power units. Forward both by keyword: the positional constructor takes only the
    # fixed `fuel_cost`, so a time-series-backed curve would either fail to construct
    # (`fuel_cost` is `nothing`) or silently lose its fuel-cost series.
    return FuelCurve{typeof(value_curve), V, Y}(;
        value_curve = value_curve,
        fuel_cost = get_fuel_cost(curve),
        fuel_cost_time_series = get_fuel_cost_time_series(curve),
        startup_fuel_offtake = get_startup_fuel_offtake(curve),
        # `vom_cost` is currency, so the fuel axis's `y_ratio` doesn't apply.
        vom_cost = scale_x(get_vom_cost(curve), x_ratio),
    )
end

# Converting to the unit system a curve is already in is the identity, dispatched rather
# than branched. Written per concrete type to stay unambiguous against the methods above.
convert_power_units(
    curve::CostCurve{T, U},
    ::U,
    ::Real,
    ::Real,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = curve
convert_power_units(
    curve::FuelCurve{T, U},
    ::U,
    ::Real,
    ::Real,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = curve

# ── FuelCurve → CostCurve ─────────────────────────────────────────────────────

_scalar_fuel_cost(fuel_cost::Float64) = fuel_cost
_scalar_fuel_cost(::TimeSeriesKey) = throw(
    ArgumentError(
        "cannot convert a FuelCurve with a time-series-backed fuel_cost to a CostCurve; " *
        "resolve the fuel cost for the timestep of interest first",
    ),
)

_check_no_startup_fuel(startup::LinearCurve) = _check_no_startup_fuel(
    get_function_data(startup),
)
function _check_no_startup_fuel(fd::LinearFunctionData)
    (iszero(get_proportional_term(fd)) && iszero(get_constant_term(fd))) || throw(
        ArgumentError(
            "cannot convert a FuelCurve with a nonzero startup_fuel_offtake to a " *
            "CostCurve: a CostCurve has nowhere to record startup fuel, so the " *
            "startup cost would be silently lost",
        ),
    )
    return
end

"""
$(TYPEDSIGNATURES)

Convert a [`FuelCurve`](@ref) with a scalar `fuel_cost` into the equivalent
[`CostCurve`](@ref) by multiplying the value curve through by the fuel cost. The unit
system and the (already-in-currency) `vom_cost` carry over unchanged.

Throws an `ArgumentError` if `fuel_cost` is a [`TimeSeriesKey`](@ref) rather than a
scalar, or if `startup_fuel_offtake` is nonzero — a `CostCurve` cannot represent it.
"""
function CostCurve(curve::FuelCurve{T, U}) where {T, U}
    fuel_cost = _scalar_fuel_cost(get_fuel_cost(curve))
    _check_no_startup_fuel(get_startup_fuel_offtake(curve))
    return CostCurve(
        fuel_cost * get_value_curve(curve),
        U(),
        get_vom_cost(curve),
    )
end

# ── Serialization ─────────────────────────────────────────────────────────────
# Per-field deserializers for the FuelCurve-specific fields, keyed on the serialized
# field name. The generic machinery (serialize, the unit-system marker mapping, and the
# value_curve field) lives in value_curve_with_units.jl, shared with LossCurve.
_deserialize_curve_field(::Val{:vom_cost}, raw) = deserialize(LinearCurve, raw)
_deserialize_curve_field(::Val{:startup_fuel_offtake}, raw) = deserialize(LinearCurve, raw)
_deserialize_curve_field(::Val{:fuel_cost}, raw) = _deserialize_fuel_cost(raw)
_deserialize_curve_field(::Val{:fuel_cost_time_series}, raw) =
    _deserialize_fuel_cost_time_series(raw)

_deserialize_fuel_cost(::Nothing) = nothing
_deserialize_fuel_cost(raw::Real) = Float64(raw)
_deserialize_fuel_cost(raw) =
    throw(
        ArgumentError(
            "FuelCurve fuel_cost must be a number or nothing, got $(typeof(raw))",
        ),
    )

_deserialize_fuel_cost_time_series(::Nothing) = nothing
# A key is on the wire as its association id and its stored time series type, so
# it rebuilds itself without the catalog that minted it.
_deserialize_fuel_cost_time_series(raw::AbstractDict) = deserialize(TimeSeriesKey, raw)
_deserialize_fuel_cost_time_series(raw) =
    throw(
        ArgumentError(
            "FuelCurve fuel_cost_time_series must be a serialized time series key or " *
            "nothing, got $(typeof(raw))",
        ),
    )

# The strategy here is to put all the short stuff on the first line, then break and let the value_curve take more space
function _show_compact(io::IO, ::MIME"text/plain", curve::CostCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)  # Capture the value_curve `show` so we can indent it
    print(io, replace(vc_printout, "\n" => "\n  "))
end

function _show_compact(io::IO, ::MIME"text/plain", curve::FuelCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), fuel_units $(get_fuel_units(curve)), fuel_cost $(curve.fuel_cost), fuel_cost_time_series $(curve.fuel_cost_time_series), startup_fuel_offtake $(curve.startup_fuel_offtake), vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end

"""
$(TYPEDEF)
$(TYPEDFIELDS)

    DualFuelCurve(; first_fuel_curve, second_fuel_curve, fuel_units, power_units,
        first_fuel_cost, first_fuel_cost_time_series, second_fuel_cost,
        second_fuel_cost_time_series, second_fuel_share, first_fuel_startup_offtake,
        second_fuel_startup_offtake, vom_cost)

Fuel use of a unit that burns two fuels, each with its own [`ValueCurve`](@ref) and fuel
price. `second_fuel_share` selects the case. Each fuel's price is exactly one of a fixed
value and a time series key.

`T` is the second fuel's curve type and `F` the first's. The supertype
`ProductionVariableCostCurve{T, U, Y}` can name only one curve, so it names the second, and
it does not describe the whole cost. A method that dispatches on
`ProductionVariableCostCurve{<:PiecewiseIncrementalCurve}` matches a stacked curve and then
throws in [`get_value_curve`](@ref); dispatch on `DualFuelCurve` instead.

**Stacked** (`second_fuel_share` is `nothing`): output up to the first x of the second curve
follows the first fuel and output above it follows the second. A combined cycle steam
turbine is the motivating case: recovered exhaust heat first, duct firing above it. The
second curve is a `PiecewiseIncrementalCurve` without `initial_input`, since consumers price
only its increase above the threshold. A piecewise first curve must end at that threshold.
A first curve with no x range, such as a `LinearCurve`, is taken to cover output up to it.
`first_fuel_cost` defaults to `0.0`, meaning the first fuel is paid for elsewhere.
A nonzero `first_fuel_startup_offtake` has no physical meaning here and is stored as given.

**Blended** (`second_fuel_share` between 0 and 1): one output `P` is served by both fuels,
at cost `(1 - share) * first(P) + share * second(P)`. Both curves cover the full output, so
two piecewise curves share their first and last x. The first fuel price is required.
Each curve must give total fuel, so an incremental or average rate curve needs an
`initial_input`; a stacked curve must not set `second_fuel_share`.

A unit with one fuel uses a [`FuelCurve`](@ref).
"""
struct DualFuelCurve{
    T <: ValueCurve,
    F <: ValueCurve,
    U <: AbstractUnitSystem,
    Y <: Unitful.Units,
} <: ProductionVariableCostCurve{T, U, Y}
    "Fuel use against output for the first fuel"
    first_fuel_curve::F
    "Fuel use against output for the second fuel"
    second_fuel_curve::T
    "A fixed price for first fuel; mutually exclusive with `first_fuel_cost_time_series`"
    first_fuel_cost::Union{Nothing, Float64}
    "The [`TimeSeriesKey`](@ref) to a first fuel price time series"
    first_fuel_cost_time_series::Union{Nothing, ScalarTimeSeriesKey}
    "A fixed price for second fuel; mutually exclusive with `second_fuel_cost_time_series`"
    second_fuel_cost::Union{Nothing, Float64}
    "The [`TimeSeriesKey`](@ref) to a second fuel price time series"
    second_fuel_cost_time_series::Union{Nothing, ScalarTimeSeriesKey}
    "`nothing` for stacked fuels; for blended fuels the fixed share of the blend the second fuel supplies, between 0 and 1"
    second_fuel_share::Union{Nothing, Float64}
    "(default of 0) Fuel of the first kind consumed during a startup, a [`LinearCurve`](@ref) in `fuel_units`"
    first_fuel_startup_offtake::LinearCurve
    "(default of 0) Fuel of the second kind consumed during a startup, a [`LinearCurve`](@ref) in `fuel_units`"
    second_fuel_startup_offtake::LinearCurve
    "(default of 0) Variable operation and maintenance cost, a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve

    function DualFuelCurve{T, F, U, Y}(
        first_fuel_curve::F,
        second_fuel_curve::T,
        first_fuel_cost::Union{Nothing, Float64},
        first_fuel_cost_time_series::Union{Nothing, TimeSeriesKey},
        second_fuel_cost::Union{Nothing, Float64},
        second_fuel_cost_time_series::Union{Nothing, TimeSeriesKey},
        second_fuel_share::Union{Nothing, Float64},
        first_fuel_startup_offtake::LinearCurve,
        second_fuel_startup_offtake::LinearCurve,
        vom_cost::LinearCurve,
    ) where {T, F, U, Y}
        _check_fuel_price("first", first_fuel_cost, first_fuel_cost_time_series)
        _check_fuel_price("second", second_fuel_cost, second_fuel_cost_time_series)
        if !isnothing(second_fuel_share) &&
           !(isfinite(second_fuel_share) && 0.0 <= second_fuel_share <= 1.0)
            throw(
                ArgumentError(
                    "second_fuel_share must be finite and between 0 and 1; got $second_fuel_share",
                ),
            )
        end
        _check_dual_fuel_layout(first_fuel_curve, second_fuel_curve, second_fuel_share)
        return new{T, F, U, Y}(first_fuel_curve, second_fuel_curve, first_fuel_cost,
            first_fuel_cost_time_series, second_fuel_cost, second_fuel_cost_time_series,
            second_fuel_share, first_fuel_startup_offtake, second_fuel_startup_offtake,
            vom_cost)
    end
end

function _check_fuel_price(which::String, cost, ts_key)
    if isnothing(cost) == isnothing(ts_key)
        throw(
            ArgumentError(
                "DualFuelCurve requires exactly one of $(which)_fuel_cost or " *
                "$(which)_fuel_cost_time_series; got $(which)_fuel_cost=$cost, " *
                "$(which)_fuel_cost_time_series=$ts_key",
            ),
        )
    end
    if !isnothing(cost) && (!isfinite(cost) || cost < 0.0)
        throw(
            ArgumentError("$(which)_fuel_cost must be finite and not negative; got $cost"),
        )
    end
    return
end

const _PiecewiseCurve =
    Union{PiecewisePointCurve, PiecewiseIncrementalCurve, PiecewiseAverageCurve}

# Curves without an x range are not checked.
_x_range(::ValueCurve) = nothing
function _x_range(curve::_PiecewiseCurve)
    x = get_x_coords(get_function_data(curve))
    return (first(x), last(x))
end

_check_stacked_second_curve(c::PiecewiseIncrementalCurve) =
    isnothing(get_initial_input(c)) ? nothing : _bad_stacked_second_curve(c)
_check_stacked_second_curve(c::ValueCurve) = _bad_stacked_second_curve(c)
_bad_stacked_second_curve(c) = throw(
    ArgumentError(
        "stacked DualFuelCurve requires the second curve to be a " *
        "PiecewiseIncrementalCurve with initial_input = nothing; got $c",
    ),
)

function _check_dual_fuel_layout(first_curve, second_curve, ::Nothing)
    _check_stacked_second_curve(second_curve)
    threshold = first(_x_range(second_curve))
    first_range = _x_range(first_curve)
    if !isnothing(first_range) && !isapprox(last(first_range), threshold)
        throw(
            ArgumentError(
                "the first fuel curve ends at $(last(first_range)) but the second starts at $threshold",
            ),
        )
    end
    return
end

# Only curve families with an `initial_input` can lack total fuel.
_check_blended_curve(::String, ::ValueCurve) = nothing
function _check_blended_curve(
    which::String,
    c::Union{
        IncrementalCurve,
        AverageRateCurve,
        TimeSeriesIncrementalCurve,
        TimeSeriesAverageRateCurve,
    },
)
    isnothing(get_initial_input(c)) || return
    throw(
        ArgumentError(
            "a blended DualFuelCurve needs curves with total fuel, but the $which " *
            "fuel curve has initial_input = nothing; a stacked curve must not set " *
            "second_fuel_share; got $c",
        ),
    )
end

function _check_dual_fuel_layout(first_curve, second_curve, share::Float64)
    _check_blended_curve("first", first_curve)
    _check_blended_curve("second", second_curve)
    r1 = _x_range(first_curve)
    r2 = _x_range(second_curve)
    if !isnothing(r1) && !isnothing(r2) && !isapprox(collect(r1), collect(r2))
        throw(
            ArgumentError(
                "blended DualFuelCurve requires both curves to cover the same output " *
                "range; got $r1 and $r2",
            ),
        )
    end
    return
end

function DualFuelCurve(;
    first_fuel_curve::ValueCurve,
    second_fuel_curve::ValueCurve,
    fuel_units::Unitful.Units,
    power_units::AbstractUnitSystem = NaturalUnit(),
    first_fuel_cost::Union{Nothing, Real} = nothing,
    first_fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    second_fuel_cost::Union{Nothing, Real} = nothing,
    second_fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    second_fuel_share::Union{Nothing, Real} = nothing,
    first_fuel_startup_offtake::LinearCurve = LinearCurve(0.0),
    second_fuel_startup_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    # A stacked curve's first fuel is paid for elsewhere unless priced.
    if isnothing(first_fuel_cost) &&
       isnothing(first_fuel_cost_time_series) &&
       isnothing(second_fuel_share)
        first_fuel_cost = 0.0
    end
    return DualFuelCurve{
        typeof(second_fuel_curve),
        typeof(first_fuel_curve),
        typeof(power_units),
        _fuel_rate_type(fuel_units),
    }(
        first_fuel_curve,
        second_fuel_curve,
        _normalize_fuel_cost(first_fuel_cost),
        first_fuel_cost_time_series,
        _normalize_fuel_cost(second_fuel_cost),
        second_fuel_cost_time_series,
        isnothing(second_fuel_share) ? nothing : Float64(second_fuel_share),
        first_fuel_startup_offtake,
        second_fuel_startup_offtake,
        vom_cost,
    )
end

"Get the curve of the first fuel"
get_first_fuel_curve(c::DualFuelCurve) = c.first_fuel_curve
"Get the curve of the second fuel"
get_second_fuel_curve(c::DualFuelCurve) = c.second_fuel_curve
"Get the fixed price of first fuel, or `nothing` when it is a time series"
get_first_fuel_cost(c::DualFuelCurve) = c.first_fuel_cost
"Get the time series key of the first fuel price, or `nothing` when it is fixed"
get_first_fuel_cost_time_series(c::DualFuelCurve) = c.first_fuel_cost_time_series
"Get the fixed price of second fuel, or `nothing` when it is a time series"
get_second_fuel_cost(c::DualFuelCurve) = c.second_fuel_cost
"Get the time series key of the second fuel price, or `nothing` when it is fixed"
get_second_fuel_cost_time_series(c::DualFuelCurve) = c.second_fuel_cost_time_series
"Get the share of output from the second fuel, or `nothing` for stacked fuels"
get_second_fuel_share(c::DualFuelCurve) = c.second_fuel_share
"Get the function for the first fuel consumption at startup"
get_first_fuel_startup_offtake(c::DualFuelCurve) = c.first_fuel_startup_offtake
"Get the function for the second fuel consumption at startup"
get_second_fuel_startup_offtake(c::DualFuelCurve) = c.second_fuel_startup_offtake
"Whether the two fuels are blended at a fixed share rather than stacked"
is_blended(c::DualFuelCurve) = !isnothing(c.second_fuel_share)

"Get the output where the second fuel starts, the first x of the second curve; stacked curves only"
function get_stacking_threshold(c::DualFuelCurve)
    is_blended(c) && throw(
        ArgumentError("get_stacking_threshold is not defined for a blended DualFuelCurve"),
    )
    return Float64(first(_x_range(c.second_fuel_curve)))
end

get_value_curve(::DualFuelCurve) = throw(
    ArgumentError(
        "get_value_curve is not defined for DualFuelCurve; use get_first_fuel_curve " *
        "or get_second_fuel_curve",
    ),
)
get_fuel_units(c::DualFuelCurve) = get_y_units(c) * Unitful.hr
_free_axis_units(c::DualFuelCurve) = (; fuel_units = get_fuel_units(c))
"""
True when each of the two fuel curves is convex. For a stacked curve the slopes at the
junction of the two curves are not compared.
"""
is_convex(c::DualFuelCurve) =
    is_convex(c.first_fuel_curve) && is_convex(c.second_fuel_curve)
"""
True when each of the two fuel curves is concave. For a stacked curve the slopes at the
junction of the two curves are not compared.
"""
is_concave(c::DualFuelCurve) =
    is_concave(c.first_fuel_curve) && is_concave(c.second_fuel_curve)
get_function_data(::DualFuelCurve) = throw(
    ArgumentError(
        "get_function_data is not defined for DualFuelCurve; use the function data of " *
        "get_first_fuel_curve or get_second_fuel_curve",
    ),
)
get_initial_input(::DualFuelCurve) = throw(
    ArgumentError(
        "get_initial_input is not defined for DualFuelCurve; use the initial input of " *
        "get_first_fuel_curve or get_second_fuel_curve",
    ),
)
is_time_series_backed(c::DualFuelCurve) =
    is_time_series_backed(c.first_fuel_curve) ||
    is_time_series_backed(c.second_fuel_curve) ||
    !isnothing(c.first_fuel_cost_time_series) ||
    !isnothing(c.second_fuel_cost_time_series)
get_time_series_key(::DualFuelCurve) = throw(
    ArgumentError(
        "get_time_series_key is not defined for DualFuelCurve; use " *
        "get_first_fuel_cost_time_series, get_second_fuel_cost_time_series, or the " *
        "time series of get_first_fuel_curve and get_second_fuel_curve",
    ),
)

"""
Convert a [`DualFuelCurve`](@ref) to the `to` unit system. Both curves and `vom_cost` move;
fuel prices, the share and the startup offtakes are not in power units and stay.
"""
function convert_power_units(
    c::DualFuelCurve{T, F, U, Y},
    to::V,
    x_ratio::Real,
    y_ratio::Real,
) where {T, F, U <: AbstractUnitSystem, Y, V <: AbstractUnitSystem}
    first_curve = inv(y_ratio) * scale_x(c.first_fuel_curve, x_ratio)
    second_curve = inv(y_ratio) * scale_x(c.second_fuel_curve, x_ratio)
    return DualFuelCurve{typeof(second_curve), typeof(first_curve), V, Y}(
        first_curve,
        second_curve,
        c.first_fuel_cost,
        c.first_fuel_cost_time_series,
        c.second_fuel_cost,
        c.second_fuel_cost_time_series,
        c.second_fuel_share,
        c.first_fuel_startup_offtake,
        c.second_fuel_startup_offtake,
        scale_x(c.vom_cost, x_ratio),
    )
end
convert_power_units(
    c::DualFuelCurve{T, F, U},
    ::U,
    ::Real,
    ::Real,
) where {T, F, U <: AbstractUnitSystem} = c

_deserialize_curve_field(::Val{:first_fuel_curve}, raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)
_deserialize_curve_field(::Val{:second_fuel_curve}, raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)
_deserialize_curve_field(::Val{:first_fuel_cost}, raw) = _deserialize_fuel_cost(raw)
_deserialize_curve_field(::Val{:second_fuel_cost}, raw) = _deserialize_fuel_cost(raw)
_deserialize_curve_field(::Val{:first_fuel_cost_time_series}, raw) =
    _deserialize_fuel_cost_time_series(raw)
_deserialize_curve_field(::Val{:second_fuel_cost_time_series}, raw) =
    _deserialize_fuel_cost_time_series(raw)
_deserialize_curve_field(::Val{:first_fuel_startup_offtake}, raw) =
    deserialize(LinearCurve, raw)
_deserialize_curve_field(::Val{:second_fuel_startup_offtake}, raw) =
    deserialize(LinearCurve, raw)
_deserialize_curve_field(::Val{:second_fuel_share}, ::Nothing) = nothing
_deserialize_curve_field(::Val{:second_fuel_share}, raw::Real) = Float64(raw)

function _show_compact(io::IO, ::MIME"text/plain", c::DualFuelCurve)
    compact = IOContext(io, :compact => true)
    if is_blended(c)
        print(
            io,
            "$(nameof(typeof(c))) blending ",
            get_second_fuel_share(c),
            " second fuel, first ",
        )
    else
        print(io, "$(nameof(typeof(c))) stacking at $(get_stacking_threshold(c)), first ")
    end
    show(compact, "text/plain", c.first_fuel_curve)
    print(io, ", second ")
    show(compact, "text/plain", c.second_fuel_curve)
end
