"""
Supertype for production variable cost curve representations.

A [`ValueCurveWrapper`](@ref) that additionally carries a `vom_cost`. Cost curves are
always in natural units: the x-axis is power in MW.

Concrete subtypes are [`CostCurve`](@ref) and [`FuelCurve`](@ref).
"""
abstract type ProductionVariableCostCurve{T <: ValueCurve} <: ValueCurveWrapper{T} end

"Get the variable operation and maintenance cost in currency/MWh"
get_vom_cost(cost::ProductionVariableCostCurve) = cost.vom_cost

# ── Bridge: legacy `power_units` arguments ───────────────────────────────────
# Temporary, remove once downstream packages stop passing units to cost curves.
# `NaturalUnit()` still works with a deprecation warning; other unit systems throw.

_natural_units_only(::NaturalUnit) = nothing
_natural_units_only(units) = throw(
    ArgumentError(
        "cost curves are natural units only (x axis in MW); got power_units $units",
    ),
)

_deprecated_power_units(::Nothing, ::Symbol) = nothing
function _deprecated_power_units(units::AbstractUnitSystem, caller::Symbol)
    _natural_units_only(units)
    Base.depwarn(
        "power_units is deprecated: cost curves are always natural units (MW); " *
        "drop the argument",
        caller,
    )
    return
end

# Downstream calls this per device per time step, and `--depwarn=yes` pays for a
# backtrace on every `depwarn`, so warn once per session. Set after `depwarn` returns,
# so `--depwarn=error` still throws on every call.
const _POWER_UNITS_DEPWARNED = Threads.Atomic{Bool}(false)

@noinline function _depwarn_get_power_units()
    Base.depwarn(
        "get_power_units is deprecated for cost curves: they are always natural units (MW)",
        :get_power_units,
    )
    _POWER_UNITS_DEPWARNED[] = true
    return
end

"Deprecated: cost curves are always in natural units (MW). Returns `NaturalUnit()`."
function get_power_units(::ProductionVariableCostCurve)
    _POWER_UNITS_DEPWARNED[] || _depwarn_get_power_units()
    return NaturalUnit()
end

"""
$(TYPEDEF)
$(TYPEDFIELDS)

    CostCurve(value_curve)
    CostCurve(value_curve, vom_cost)
    CostCurve(; value_curve, vom_cost)

Direct representation of the variable operation cost of a power plant in currency. Composed
of a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate
data. The x-axis is always power in natural units (MW).
"""
struct CostCurve{T <: ValueCurve} <: ProductionVariableCostCurve{T}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in
    \$/MWh, represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve
end

CostCurve(value_curve::ValueCurve) = CostCurve(value_curve, LinearCurve(0.0))

function CostCurve(;
    value_curve::ValueCurve,
    vom_cost::LinearCurve = LinearCurve(0.0),
    power_units::Union{Nothing, AbstractUnitSystem} = nothing,  # bridge
)
    _deprecated_power_units(power_units, :CostCurve)
    return CostCurve(value_curve, vom_cost)
end

# Bridge: positional `power_units`. Each method warns itself, so the warning names the
# caller's line rather than another bridge method.
function CostCurve(value_curve::ValueCurve, power_units::AbstractUnitSystem)
    _deprecated_power_units(power_units, :CostCurve)
    return CostCurve(value_curve)
end
function CostCurve(
    value_curve::ValueCurve,
    power_units::AbstractUnitSystem,
    vom_cost::LinearCurve,
)
    _deprecated_power_units(power_units, :CostCurve)
    return CostCurve(value_curve, vom_cost)
end

"Get a `CostCurve` representing zero variable cost"
Base.zero(::Union{CostCurve, Type{CostCurve}}) = CostCurve(zero(ValueCurve))

"""
$(TYPEDEF)
$(TYPEDFIELDS)

    FuelCurve(value_curve, fuel_cost)
    FuelCurve(value_curve, fuel_cost_time_series)
    FuelCurve(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(; value_curve, fuel_cost, fuel_cost_time_series, startup_fuel_offtake, vom_cost)

Representation of the variable operation cost of a power plant in terms of fuel (MBTU,
liters, m^3, etc.), coupled with a conversion factor between fuel and currency. Composed of
a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate data.
The x-axis is always power in natural units (MW).
Exactly one of `fuel_cost` or `fuel_cost_time_series` must be provided.
"""
struct FuelCurve{T <: ValueCurve} <: ProductionVariableCostCurve{T}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "A fixed value for fuel cost; mutually exclusive with `fuel_cost_time_series`"
    fuel_cost::Union{Nothing, Float64}
    "The [`TimeSeriesKey`](@ref) to a fuel cost time series; mutually exclusive with `fuel_cost`"
    fuel_cost_time_series::Union{Nothing, ScalarTimeSeriesKey}
    "(default of 0) Fuel consumption at the unit startup proceedure. Additional cost to the startup costs and related only to the initial fuel required to start the unit.
    represented as a [`LinearCurve`](@ref)"
    startup_fuel_offtake::LinearCurve
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in \$/MWh
    represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve

    function FuelCurve{T}(
        value_curve::T,
        fuel_cost::Union{Nothing, Float64},
        fuel_cost_time_series::Union{Nothing, TimeSeriesKey},
        startup_fuel_offtake::LinearCurve,
        vom_cost::LinearCurve,
    ) where {T}
        if isnothing(fuel_cost) == isnothing(fuel_cost_time_series)
            throw(
                ArgumentError(
                    "FuelCurve requires exactly one of fuel_cost (fixed) or " *
                    "fuel_cost_time_series (time-varying); got " *
                    "fuel_cost=$fuel_cost, fuel_cost_time_series=$fuel_cost_time_series",
                ),
            )
        end
        return new{T}(value_curve, fuel_cost, fuel_cost_time_series,
            startup_fuel_offtake, vom_cost)
    end
end

_normalize_fuel_cost(::Nothing) = nothing
_normalize_fuel_cost(x::Real) = Float64(x)

# Which field a positionally supplied fuel cost lands in: the fixed value and the
# time series key are separate fields, so the routing is dispatched, not branched.
_fuel_cost_kwargs(fuel_cost::Real) = (; fuel_cost = _normalize_fuel_cost(fuel_cost))
_fuel_cost_kwargs(fuel_cost::TimeSeriesKey) = (; fuel_cost_time_series = fuel_cost)

function FuelCurve(;
    value_curve::ValueCurve,
    fuel_cost::Union{Nothing, Real} = nothing,
    fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
    power_units::Union{Nothing, AbstractUnitSystem} = nothing,  # bridge
)
    _deprecated_power_units(power_units, :FuelCurve)
    return FuelCurve{typeof(value_curve)}(
        value_curve,
        _normalize_fuel_cost(fuel_cost),
        fuel_cost_time_series,
        startup_fuel_offtake,
        vom_cost,
    )
end

FuelCurve(value_curve::ValueCurve, fuel_cost::Union{Real, TimeSeriesKey}) =
    FuelCurve(; value_curve, _fuel_cost_kwargs(fuel_cost)...)

FuelCurve(
    value_curve::ValueCurve,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) = FuelCurve(;
    value_curve,
    _fuel_cost_kwargs(fuel_cost)...,
    startup_fuel_offtake,
    vom_cost,
)

# Bridge: positional `power_units`.
function FuelCurve(
    value_curve::ValueCurve,
    power_units::AbstractUnitSystem,
    fuel_cost::Union{Real, TimeSeriesKey},
)
    _deprecated_power_units(power_units, :FuelCurve)
    return FuelCurve(value_curve, fuel_cost)
end
function FuelCurve(
    value_curve::ValueCurve,
    power_units::AbstractUnitSystem,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
)
    _deprecated_power_units(power_units, :FuelCurve)
    return FuelCurve(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)
end

"Get a `FuelCurve` representing zero fuel usage and zero fuel cost"
Base.zero(::Union{FuelCurve, Type{FuelCurve}}) = FuelCurve(zero(ValueCurve), 0.0)

"Get the fixed fuel cost, or `nothing` if it is time-series-backed"
get_fuel_cost(cost::FuelCurve) = cost.fuel_cost
"Get the fuel cost time series key, or `nothing` if it is a fixed value"
get_fuel_cost_time_series(cost::FuelCurve) = cost.fuel_cost_time_series
"Get the function for the fuel consumption at startup"
get_startup_fuel_offtake(cost::FuelCurve) = cost.startup_fuel_offtake

is_time_series_backed(::TimeSeriesKey) = true
is_time_series_backed(::Union{Nothing, Float64}) = false
# FuelCurve's fuel_cost and fuel_cost_time_series are orthogonal fields - check the value
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
        "are independently time-series-backed - resolve explicitly via " *
        "get_time_series_key(get_value_curve(c)) or get_fuel_cost_time_series(c)",
    ),
)
get_time_series_key(::FuelCurve) = _fuel_curve_no_ts_key()
get_time_series_key(::FuelCurve{<:ValueCurve{<:TimeSeriesFunctionData}}) =
    _fuel_curve_no_ts_key()

# ── FuelCurve → CostCurve ─────────────────────────────────────────────────────

# A time-series-backed FuelCurve stores `nothing` as its fixed fuel cost.
_scalar_fuel_cost(fuel_cost::Float64) = fuel_cost
_scalar_fuel_cost(::Nothing) = throw(
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
[`CostCurve`](@ref) by multiplying the value curve through by the fuel cost. The
(already-in-currency) `vom_cost` carries over unchanged.

Throws an `ArgumentError` if the fuel cost is time-series-backed rather than a scalar, or
if `startup_fuel_offtake` is nonzero, since a `CostCurve` cannot represent it.
"""
function CostCurve(curve::FuelCurve)
    fuel_cost = _scalar_fuel_cost(get_fuel_cost(curve))
    _check_no_startup_fuel(get_startup_fuel_offtake(curve))
    return CostCurve(fuel_cost * get_value_curve(curve), get_vom_cost(curve))
end

# ── Serialization ─────────────────────────────────────────────────────────────
# `serialize` and the value_curve field live in value_curve_wrapper.jl, shared with
# LossCurve. Cost curves write no "power_units" key.

# Data written before cost curves dropped their unit system carries "power_units".
# "NaturalUnit" is what they are now, so it is ignored; any other value is refused.
_check_legacy_power_units(::Nothing) = nothing
_check_legacy_power_units(name) = name == "NaturalUnit" || _natural_units_only(name)

function deserialize(::Type{T}, data::Dict) where {T <: ProductionVariableCostCurve}
    _check_legacy_power_units(get(data, "power_units", nothing))
    return T(; _deserialize_curve_fields(data)...)
end

# Per-field deserializers for the cost-curve-specific fields, keyed on the serialized
# field name.
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
        "$(nameof(typeof(curve))) with vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)  # Capture the value_curve `show` so we can indent it
    print(io, replace(vc_printout, "\n" => "\n  "))
end

function _show_compact(io::IO, ::MIME"text/plain", curve::FuelCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with fuel_cost $(curve.fuel_cost), fuel_cost_time_series $(curve.fuel_cost_time_series), startup_fuel_offtake $(curve.startup_fuel_offtake), vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end
