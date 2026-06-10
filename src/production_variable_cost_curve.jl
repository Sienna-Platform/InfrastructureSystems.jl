"""
Supertype for production variable cost curve representations.

Parameterized by a [`ValueCurve`](@ref) type `T` and an
[`AbstractUnitSystem`](@ref) type `U`. `U` is a compile-time marker for the
`power_units` of the x-axis; it replaces the old `power_units::UnitSystem`
runtime field. This lets unit-dependent operations dispatch directly on the
type parameter rather than going through a stateful runtime check plus
`Val`-wrapping, eliminating a class of type instabilities downstream.

Concrete subtypes include [`CostCurve`](@ref) and [`FuelCurve`](@ref).
"""
abstract type ProductionVariableCostCurve{T <: ValueCurve, U <: AbstractUnitSystem} end

"Get the underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
get_value_curve(cost::ProductionVariableCostCurve) = cost.value_curve
"Get the variable operation and maintenance cost in currency/(power_units h)"
get_vom_cost(cost::ProductionVariableCostCurve) = cost.vom_cost
"""
Get the units marker for the x-axis of the curve as an instance of the
second type parameter (e.g. `NaturalUnit()`, `SystemBaseUnit()`,
`DeviceBaseUnit()`).
"""
get_power_units(::ProductionVariableCostCurve{T, U}) where {T, U} = U()
"Get the `FunctionData` representation of this `ProductionVariableCostCurve`'s `ValueCurve`"
get_function_data(cost::ProductionVariableCostCurve) =
    get_function_data(get_value_curve(cost))
"Get the `initial_input` field of this `ProductionVariableCostCurve`'s `ValueCurve` (not defined for input-output data)"
get_initial_input(cost::ProductionVariableCostCurve) =
    get_initial_input(get_value_curve(cost))
"Calculate the convexity of the underlying data"
function is_convex(curve::ValueCurve{T}) where {T <: TimeSeriesFunctionData}
    throw(
        ArgumentError(
            "Convexity is not defined for time-series-backed ValueCurve; use time-series specific analysis instead.",
        ),
    )
end
is_convex(cost::ProductionVariableCostCurve) = is_convex(get_value_curve(cost))
"Calculate the concavity of the underlying data"
function is_concave(curve::ValueCurve{T}) where {T <: TimeSeriesFunctionData}
    throw(
        ArgumentError(
            "Concavity is not defined for time-series-backed ValueCurve; use time-series specific analysis instead.",
        ),
    )
end
is_concave(cost::ProductionVariableCostCurve) = is_concave(get_value_curve(cost))
"Get the `TimeSeriesKey` from the underlying `ValueCurve` of a time-series-backed `ProductionVariableCostCurve`."
get_time_series_key(
    cost::ProductionVariableCostCurve{<:ValueCurve{<:TimeSeriesFunctionData}},
) = get_time_series_key(get_value_curve(cost))

"Fallback: throw a clear `ArgumentError` when `get_time_series_key` is called on a non-TS-backed curve."
get_time_series_key(cost::ProductionVariableCostCurve) = throw(
    ArgumentError(
        "$(nameof(typeof(cost))) is not time-series-backed; get_time_series_key is undefined",
    ),
)

Base.:(==)(a::T, b::T) where {T <: ProductionVariableCostCurve} =
    double_equals_from_fields(a, b)

Base.isequal(a::T, b::T) where {T <: ProductionVariableCostCurve} =
    isequal_from_fields(a, b)

Base.hash(a::ProductionVariableCostCurve, h::UInt) = hash_from_fields(a, h)

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
    FuelCurve(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(value_curve, power_units, fuel_cost)
    FuelCurve(value_curve, power_units, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(; value_curve, power_units, fuel_cost, startup_fuel_offtake, vom_cost)

Representation of the variable operation cost of a power plant in terms of fuel (MBTU,
liters, m^3, etc.), coupled with a conversion factor between fuel and currency. Composed of
a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate data.
The x-axis units are encoded as the second type parameter `U <: AbstractUnitSystem`;
`power_units` at construction is the singleton instance `U()` (default `NaturalUnit()`).
"""
struct FuelCurve{T <: ValueCurve, U <: AbstractUnitSystem} <:
       ProductionVariableCostCurve{T, U}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "Either a fixed value for fuel cost or the [`TimeSeriesKey`](@ref) to a fuel cost time series"
    fuel_cost::Union{Float64, TimeSeriesKey}
    "(default of 0) Fuel consumption at the unit startup proceedure. Additional cost to the startup costs and related only to the initial fuel required to start the unit.
    represented as a [`LinearCurve`](@ref)"
    startup_fuel_offtake::LinearCurve
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in \$/(power_unit h)
    represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve

    FuelCurve{T, U}(
        value_curve::T,
        fuel_cost::Union{Float64, TimeSeriesKey},
        startup_fuel_offtake::LinearCurve,
        vom_cost::LinearCurve,
    ) where {T, U} =
        new{T, U}(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)
end

FuelCurve{T, U}(;
    value_curve::T,
    fuel_cost::Union{Float64, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
) where {T, U} =
    FuelCurve{T, U}(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)

_normalize_fuel_cost(x::Real) = Float64(x)
_normalize_fuel_cost(x::TimeSeriesKey) = x

# Outer constructors — mirror the CostCurve style
FuelCurve(value_curve::T, fuel_cost::Real) where {T <: ValueCurve} =
    FuelCurve{T, NaturalUnit}(; value_curve, fuel_cost = Float64(fuel_cost))
FuelCurve(value_curve::T, fuel_cost::TimeSeriesKey) where {T <: ValueCurve} =
    FuelCurve{T, NaturalUnit}(; value_curve, fuel_cost)

FuelCurve(
    value_curve::T,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve} = FuelCurve{T, NaturalUnit}(;
    value_curve,
    fuel_cost = _normalize_fuel_cost(fuel_cost),
    startup_fuel_offtake,
    vom_cost,
)

FuelCurve(
    value_curve::T,
    power_units::U,
    fuel_cost::Union{Real, TimeSeriesKey},
) where {T <: ValueCurve, U <: AbstractUnitSystem} = FuelCurve{T, U}(;
    value_curve,
    fuel_cost = _normalize_fuel_cost(fuel_cost),
)

FuelCurve(
    value_curve::T,
    power_units::U,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = FuelCurve{T, U}(;
    value_curve,
    fuel_cost = _normalize_fuel_cost(fuel_cost),
    startup_fuel_offtake,
    vom_cost,
)

# Keyword-based constructor exposing `power_units`.
function FuelCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    return FuelCurve{typeof(value_curve), typeof(power_units)}(;
        value_curve,
        fuel_cost = _normalize_fuel_cost(fuel_cost),
        startup_fuel_offtake,
        vom_cost,
    )
end

"Get a `FuelCurve` representing zero fuel usage and zero fuel cost (NaturalUnit)"
Base.zero(::Type{FuelCurve}) = FuelCurve(zero(ValueCurve), 0.0)
"Get a `FuelCurve` representing zero fuel usage and zero fuel cost, preserving the unit system of `c`"
Base.zero(::FuelCurve{T, U}) where {T, U} = FuelCurve(zero(ValueCurve), U(), 0.0)

"Get the fuel cost or the name of the fuel cost time series"
get_fuel_cost(cost::FuelCurve) = cost.fuel_cost
"Get the function for the fuel consumption at startup"
get_startup_fuel_offtake(cost::FuelCurve) = cost.startup_fuel_offtake

is_time_series_backed(::TimeSeriesKey) = true
is_time_series_backed(::Union{Nothing, Float64}) = false
"Check if the cost curve is backed by time series data"
is_time_series_backed(cost::ProductionVariableCostCurve) =
    is_time_series_backed(get_value_curve(cost))
# FuelCurve's fuel_cost is Union{Float64, TimeSeriesKey} — check both the value curve and fuel_cost.
is_time_series_backed(cost::FuelCurve) =
    is_time_series_backed(get_value_curve(cost)) ||
    is_time_series_backed(get_fuel_cost(cost))

"""
$(TYPEDSIGNATURES)
Return the `TimeSeriesKey` for a time-series-backed `FuelCurve`. If only the value
curve is TS-backed, returns its key; if only `fuel_cost` is TS-backed, returns the
`fuel_cost` key. If BOTH are TS-backed the key is ambiguous and this throws
`ArgumentError` — resolve via `get_time_series_key(get_value_curve(c))` or
`get_fuel_cost(c)` explicitly.
"""
get_time_series_key(cost::FuelCurve) =
    _fuel_curve_ts_key(get_value_curve(cost), get_fuel_cost(cost))

# Disambiguate: both the generic (constrains value-curve type) and the FuelCurve-generic
# (constrains curve type) match a FuelCurve with a TS-backed value curve — add the
# more-specific method that satisfies both constraints.
get_time_series_key(
    cost::FuelCurve{<:ValueCurve{<:TimeSeriesFunctionData}},
) = _fuel_curve_ts_key(get_value_curve(cost), get_fuel_cost(cost))

_fuel_curve_ts_key(vc::ValueCurve{<:TimeSeriesFunctionData}, ::Float64) =
    get_time_series_key(vc)
_fuel_curve_ts_key(::ValueCurve, fc::TimeSeriesKey) = fc
_fuel_curve_ts_key(vc::ValueCurve{<:TimeSeriesFunctionData}, ::TimeSeriesKey) = throw(
    ArgumentError(
        "FuelCurve has both a time-series-backed value curve and a time-series fuel_cost; " *
        "the key is ambiguous — use get_time_series_key(get_value_curve(c)) or get_fuel_cost(c) explicitly",
    ),
)
_fuel_curve_ts_key(::ValueCurve, ::Float64) = throw(
    ArgumentError(
        "FuelCurve is not time-series-backed; get_time_series_key is undefined",
    ),
)

# ── Serialization ─────────────────────────────────────────────────────────────
# The U type parameter has no corresponding field, so we serialize it under the
# conventional "power_units" key (preserving the field name from the previous
# schema) and reconstruct it at deserialize time.

# Map the serialized `power_units` type name back to its marker instance.
_unit_system_instance(name::AbstractString) = _unit_system_instance(String(name))
function _unit_system_instance(name::String)
    name == "NaturalUnit" && return NaturalUnit()
    name == "SystemBaseUnit" && return SystemBaseUnit()
    name == "DeviceBaseUnit" && return DeviceBaseUnit()
    throw(ArgumentError("$name is not a known AbstractUnitSystem"))
end

function serialize(val::ProductionVariableCostCurve)
    data = serialize_struct(val)
    data["power_units"] = string(nameof(typeof(get_power_units(val))))
    return data
end

# Per-field deserializers, keyed on the serialized field name. Construction
# goes through the kwarg constructor with every data key splatted, so a field
# added to the struct cannot be silently dropped: an unknown key fails loudly
# here (no `_deserialize_pvcc_field` method) or at the constructor.
_deserialize_pvcc_field(::Val{:value_curve}, raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)
_deserialize_pvcc_field(::Val{:vom_cost}, raw) = deserialize(LinearCurve, raw)
_deserialize_pvcc_field(::Val{:startup_fuel_offtake}, raw) = deserialize(LinearCurve, raw)
_deserialize_pvcc_field(::Val{:fuel_cost}, raw) = _deserialize_fuel_cost(raw)

_deserialize_fuel_cost(raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)
_deserialize_fuel_cost(raw::Real) = Float64(raw)
_deserialize_fuel_cost(raw) =
    throw(
        ArgumentError(
            "FuelCurve fuel_cost must be a number or serialized TimeSeriesKey, got $(typeof(raw))",
        ),
    )

function deserialize(::Type{T}, data::Dict) where {T <: Union{CostCurve, FuelCurve}}
    vals = Dict{Symbol, Any}(
        Symbol(k) => _deserialize_pvcc_field(Val(Symbol(k)), v)
        for (k, v) in data if k != METADATA_KEY && k != "power_units"
    )
    return T(; vals..., power_units = _unit_system_instance(data["power_units"]))
end

Base.show(io::IO, m::MIME"text/plain", curve::ProductionVariableCostCurve) =
    (get(io, :compact, false)::Bool ? _show_compact : _show_expanded)(io, m, curve)

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
        "$(nameof(typeof(curve))) with power_units $(get_power_units(curve)), fuel_cost $(curve.fuel_cost), startup_fuel_offtake $(curve.startup_fuel_offtake), vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)
    print(io, replace(vc_printout, "\n" => "\n  "))
end

function _show_expanded(io::IO, ::MIME"text/plain", curve::ProductionVariableCostCurve)
    print(io, "$(nameof(typeof(curve))):")
    for field_name in fieldnames(typeof(curve))
        val = getproperty(curve, field_name)
        val_printout =
            replace(sprint(show, "text/plain", val; context = io), "\n" => "\n  ")
        print(io, "\n  $(field_name): $val_printout")
    end
    # Surface the type-parameter `power_units` even though it isn't a field
    print(io, "\n  power_units: $(get_power_units(curve))")
end
