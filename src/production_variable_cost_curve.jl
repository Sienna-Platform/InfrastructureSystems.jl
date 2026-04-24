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

# Keyword-based constructor exposing `power_units`, replacing the former field default
function CostCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    return CostCurve{typeof(value_curve), typeof(power_units)}(; value_curve, vom_cost)
end

"Get a `CostCurve` representing zero variable cost"
Base.zero(::Union{CostCurve, Type{CostCurve}}) = CostCurve(zero(ValueCurve))

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
    fuel_cost = fuel_cost isa Real ? Float64(fuel_cost) : fuel_cost,
    startup_fuel_offtake,
    vom_cost,
)

FuelCurve(
    value_curve::T,
    power_units::U,
    fuel_cost::Union{Real, TimeSeriesKey},
) where {T <: ValueCurve, U <: AbstractUnitSystem} = FuelCurve{T, U}(;
    value_curve,
    fuel_cost = fuel_cost isa Real ? Float64(fuel_cost) : fuel_cost,
)

FuelCurve(
    value_curve::T,
    power_units::U,
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
) where {T <: ValueCurve, U <: AbstractUnitSystem} = FuelCurve{T, U}(;
    value_curve,
    fuel_cost = fuel_cost isa Real ? Float64(fuel_cost) : fuel_cost,
    startup_fuel_offtake,
    vom_cost,
)

# Keyword-based constructor exposing `power_units`
function FuelCurve(;
    value_curve,
    power_units::AbstractUnitSystem = NaturalUnit(),
    fuel_cost::Union{Real, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0),
    vom_cost::LinearCurve = LinearCurve(0.0),
)
    fc = fuel_cost isa Real ? Float64(fuel_cost) : fuel_cost
    return FuelCurve{typeof(value_curve), typeof(power_units)}(;
        value_curve,
        fuel_cost = fc,
        startup_fuel_offtake,
        vom_cost,
    )
end

"Get a `FuelCurve` representing zero fuel usage and zero fuel cost"
Base.zero(::Union{FuelCurve, Type{FuelCurve}}) = FuelCurve(zero(ValueCurve), 0.0)

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

# ── Serialization ─────────────────────────────────────────────────────────────
# The U type parameter has no corresponding field, so we serialize it under the
# conventional "power_units" key (preserving the field name from the previous
# schema) and reconstruct it at deserialize time.

_unit_system_instance(name::AbstractString) =
    _unit_system_instance(Symbol(name))
function _unit_system_instance(name::Symbol)
    T = getproperty(@__MODULE__, name)
    T <: AbstractUnitSystem ||
        throw(ArgumentError("$name is not a subtype of AbstractUnitSystem"))
    return T()
end

function serialize(val::ProductionVariableCostCurve)
    data = serialize_struct(val)
    data["power_units"] = string(nameof(typeof(get_power_units(val))))
    return data
end

function deserialize(::Type{CostCurve}, data::Dict)
    vc_data = data["value_curve"]
    vc_type = get_type_from_serialization_data(vc_data)
    value_curve = deserialize(vc_type, vc_data)
    vom_cost = deserialize(LinearCurve, data["vom_cost"])
    power_units = _unit_system_instance(data["power_units"])
    return CostCurve(value_curve, power_units, vom_cost)
end

function deserialize(::Type{FuelCurve}, data::Dict)
    vc_data = data["value_curve"]
    vc_type = get_type_from_serialization_data(vc_data)
    value_curve = deserialize(vc_type, vc_data)
    startup = deserialize(LinearCurve, data["startup_fuel_offtake"])
    vom = deserialize(LinearCurve, data["vom_cost"])
    fuel_cost_raw = data["fuel_cost"]
    fuel_cost = if fuel_cost_raw isa Dict
        deserialize(TimeSeriesKey, fuel_cost_raw)
    else
        Float64(fuel_cost_raw)
    end
    power_units = _unit_system_instance(data["power_units"])
    return FuelCurve(value_curve, power_units, fuel_cost, startup, vom)
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
