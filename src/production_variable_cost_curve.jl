"""
Supertype for production variable cost curve representations.

A [`ValueCurveWithUnits`](@ref) that additionally carries a `vom_cost`.

Concrete subtypes are [`CostCurve`](@ref) and [`FuelCurve`](@ref).
"""
abstract type ProductionVariableCostCurve{T <: ValueCurve, U <: AbstractUnitSystem} <:
              ValueCurveWithUnits{T, U} end

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
data. The x-axis units are encoded as the second type parameter `U <: AbstractUnitSystem`;
`power_units` at construction is the singleton instance `U()` (default `NaturalUnit()`).
"""
struct CostCurve{T <: ValueCurve, U <: AbstractUnitSystem} <:
       ProductionVariableCostCurve{T, U}
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

    FuelCurve(value_curve, fuel_cost)
    FuelCurve(value_curve, fuel_cost_time_series)
    FuelCurve(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(value_curve, power_units, fuel_cost)
    FuelCurve(value_curve, power_units, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(; value_curve, power_units, fuel_cost, fuel_cost_time_series, startup_fuel_offtake, vom_cost)

Representation of the variable operation cost of a power plant in terms of fuel (MBTU,
liters, m^3, etc.), coupled with a conversion factor between fuel and currency. Composed of
a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate data.
The x-axis units are encoded as the second type parameter `U <: AbstractUnitSystem`;
`power_units` at construction is the singleton instance `U()` (default `NaturalUnit()`).
Exactly one of `fuel_cost` or `fuel_cost_time_series` must be provided.
"""
struct FuelCurve{T <: ValueCurve, U <: AbstractUnitSystem} <:
       ProductionVariableCostCurve{T, U}
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

    function FuelCurve{T, U}(
        value_curve::T,
        fuel_cost::Union{Nothing, Float64},
        fuel_cost_time_series::Union{Nothing, TimeSeriesKey},
        startup_fuel_offtake::LinearCurve,
        vom_cost::LinearCurve,
    ) where {T, U}
        if isnothing(fuel_cost) == isnothing(fuel_cost_time_series)
            throw(
                ArgumentError(
                    "FuelCurve requires exactly one of fuel_cost (fixed) or " *
                    "fuel_cost_time_series (time-varying); got " *
                    "fuel_cost=$fuel_cost, fuel_cost_time_series=$fuel_cost_time_series",
                ),
            )
        end
        return new{T, U}(value_curve, fuel_cost, fuel_cost_time_series,
            startup_fuel_offtake, vom_cost)
    end
end

FuelCurve{T, U}(;
    value_curve::T,
    fuel_cost::Union{Nothing, Float64} = nothing,
    fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
) where {T, U} =
    FuelCurve{T, U}(value_curve, fuel_cost, fuel_cost_time_series,
        startup_fuel_offtake, vom_cost)

_normalize_fuel_cost(::Nothing) = nothing
_normalize_fuel_cost(x::Real) = Float64(x)

# Which field a positionally supplied fuel cost lands in: the fixed value and the
# time series key are separate fields, so the routing is dispatched, not branched.
_fuel_cost_kwargs(fuel_cost::Real) = (; fuel_cost = _normalize_fuel_cost(fuel_cost))
_fuel_cost_kwargs(fuel_cost::TimeSeriesKey) = (; fuel_cost_time_series = fuel_cost)

# Outer constructors — mirror the CostCurve style
FuelCurve(
    value_curve::T,
    fuel_cost::Union{Real, TimeSeriesKey},
) where {T <: ValueCurve} =
    FuelCurve{T, NaturalUnit}(; value_curve, _fuel_cost_kwargs(fuel_cost)...)

FuelCurve(
    value_curve::T,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve} = FuelCurve{T, NaturalUnit}(;
    value_curve,
    _fuel_cost_kwargs(fuel_cost)...,
    startup_fuel_offtake,
    vom_cost,
)

FuelCurve(
    value_curve::T,
    power_units::U,
    fuel_cost::Union{Real, TimeSeriesKey},
) where {T <: ValueCurve, U <: AbstractUnitSystem} = FuelCurve{T, U}(;
    value_curve,
    _fuel_cost_kwargs(fuel_cost)...,
)

FuelCurve(
    value_curve::T,
    power_units::U,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = FuelCurve{T, U}(;
    value_curve,
    _fuel_cost_kwargs(fuel_cost)...,
    startup_fuel_offtake,
    vom_cost,
)

# Keyword-based constructor exposing `power_units`.
function FuelCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
    fuel_cost::Union{Nothing, Real} = nothing,
    fuel_cost_time_series::Union{Nothing, TimeSeriesKey} = nothing,
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    return FuelCurve{typeof(value_curve), typeof(power_units)}(;
        value_curve,
        fuel_cost = _normalize_fuel_cost(fuel_cost),
        fuel_cost_time_series,
        startup_fuel_offtake,
        vom_cost,
    )
end

"Get a `FuelCurve` representing zero fuel usage and zero fuel cost (NaturalUnit)"
Base.zero(::Type{FuelCurve}) = FuelCurve(zero(ValueCurve), 0.0)
"Get a `FuelCurve` representing zero fuel usage and zero fuel cost, preserving the unit system of `c`"
Base.zero(::FuelCurve{T, U}) where {T, U} = FuelCurve(zero(ValueCurve), U(), 0.0)

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
# A change of power units rescales the x-axis: if `ρ` is the ratio such that
# `x_from = ρ * x_to`, the converted curve represents `f_to(x_to) = f_from(ρ * x_to)`,
# which is exactly `scale_x(curve, ρ)`. `ρ` comes from the same `_cost_coeff_ratio`
# dispatch table that backs `convert_cost_coefficient`.
#
# Only the x-axis moves. These y-axes are absolute currency or fuel rates (\$/h, MBTU/h)
# that carry no power units, so nothing rescales them. Note that `scale_x` still changes
# the stored y *data* of an `IncrementalCurve`/`AverageRateCurve` — those y-axes are rates
# per unit of x (\$/MWh), so x's units sit in the denominator and must convert with it.
# That factor is the chain rule inside `scale_x`, not a y-scaling of the curve.

"""
$(TYPEDSIGNATURES)

Convert `curve` to the `to` unit system, returning a curve of the same outer type whose
`U` parameter is `typeof(to)`. `system_base_power` and `device_base_power` supply the
conversion factors; `InfrastructureSystems` has no notion of components, so callers pass
them explicitly (domain packages are expected to add a component-aware convenience
method).

The `fuel_cost` of a [`FuelCurve`](@ref) is in currency per unit of fuel and is left
alone. Time-series-backed value curves cannot be rescaled and raise an `ArgumentError`.
"""
function convert_power_units(
    curve::CostCurve{T, U},
    to::AbstractUnitSystem,
    system_base_power::Float64,
    device_base_power::Float64,
) where {T, U}
    ratio = _cost_coeff_ratio(U(), to, system_base_power, device_base_power)
    return CostCurve(
        scale_x(get_value_curve(curve), ratio),
        to,
        scale_x(get_vom_cost(curve), ratio),
    )
end

"""
$(TYPEDSIGNATURES)

Convert a [`FuelCurve`](@ref) to the `to` unit system. Only the value curve and `vom_cost`
are rescaled — both are functions of the production quantity on the x-axis.

`fuel_cost` is currency per unit of fuel, and `startup_fuel_offtake` is fuel consumed as a
function of *downtime*: its x-axis is a duration and its y-axis is a fuel quantity, so a
change of power units touches neither. Both carry over unchanged.
"""
function convert_power_units(
    curve::FuelCurve{T, U},
    to::AbstractUnitSystem,
    system_base_power::Float64,
    device_base_power::Float64,
) where {T, U}
    ratio = _cost_coeff_ratio(U(), to, system_base_power, device_base_power)
    # `startup_fuel_offtake` is fuel vs. downtime — neither axis is in power units.
    return FuelCurve(
        scale_x(get_value_curve(curve), ratio),
        to,
        get_fuel_cost(curve),
        get_startup_fuel_offtake(curve),
        scale_x(get_vom_cost(curve), ratio),
    )
end

# Converting to the unit system a curve is already in is the identity, dispatched rather
# than branched. Written per concrete type to stay unambiguous against the methods above.
convert_power_units(curve::CostCurve{T, U}, ::U, ::Float64, ::Float64) where {T, U} = curve
convert_power_units(curve::FuelCurve{T, U}, ::U, ::Float64, ::Float64) where {T, U} = curve

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
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), fuel_cost $(curve.fuel_cost), fuel_cost_time_series $(curve.fuel_cost_time_series), startup_fuel_offtake $(curve.startup_fuel_offtake), vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end
