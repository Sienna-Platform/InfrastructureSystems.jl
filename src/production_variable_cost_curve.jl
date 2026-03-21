abstract type ProductionVariableCostCurve{T <: ValueCurve} end

serialize(val::ProductionVariableCostCurve) = serialize_struct(val)
deserialize(T::Type{<:ProductionVariableCostCurve}, val::Dict) =
    deserialize_struct(T, val)

"Get the underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
get_value_curve(cost::ProductionVariableCostCurve) = cost.value_curve
"Get the variable operation and maintenance cost in currency/(power_units h)"
get_vom_cost(cost::ProductionVariableCostCurve) = cost.vom_cost
"Get the units for the x-axis of the curve"
get_power_units(cost::ProductionVariableCostCurve) = cost.power_units
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
"Check if the cost curve is backed by time series data"
is_time_series_backed(cost::ProductionVariableCostCurve) =
    is_time_series_backed(get_value_curve(cost))
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

    CostCurve(value_curve, power_units, vom_cost)
    CostCurve(; value_curve, power_units, vom_cost)

Direct representation of the variable operation cost of a power plant in currency. Composed
of a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate
data. The default units for the x-axis are MW and can be specified with
`power_units`.
"""
@kwdef struct CostCurve{T <: ValueCurve} <: ProductionVariableCostCurve{T}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "(default: natural units (MW)) The units for the x-axis of the curve"
    power_units::UnitSystem = UnitSystem.NATURAL_UNITS
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in
    \$/(power_unit h), represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve = LinearCurve(0.0)
end

CostCurve(value_curve) = CostCurve(; value_curve)
CostCurve(value_curve, vom_cost::LinearCurve) =
    CostCurve(; value_curve, vom_cost = vom_cost)
CostCurve(value_curve, power_units::UnitSystem) =
    CostCurve(; value_curve, power_units = power_units)

Base.:(==)(a::CostCurve, b::CostCurve) =
    (get_value_curve(a) == get_value_curve(b)) &&
    (get_power_units(a) == get_power_units(b)) &&
    (get_vom_cost(a) == get_vom_cost(b))

"Get a `CostCurve` representing zero variable cost"
Base.zero(::Union{CostCurve, Type{CostCurve}}) = CostCurve(zero(ValueCurve))

"""
$(TYPEDEF)
$(TYPEDFIELDS)

    FuelCurve(value_curve, power_units, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(value_curve, fuel_cost)
    FuelCurve(value_curve, fuel_cost, startup_fuel_offtake, vom_cost)
    FuelCurve(value_curve, power_units, fuel_cost)
    FuelCurve(; value_curve, power_units, fuel_cost, startup_fuel_offtake, vom_cost)

Representation of the variable operation cost of a power plant in terms of fuel (MBTU,
liters, m^3, etc.), coupled with a conversion factor between fuel and currency. Composed of
a [`ValueCurve`](@ref) that may represent input-output, incremental, or average rate data.
The default units for the x-axis are MW and can be specified with `power_units`.
"""
@kwdef struct FuelCurve{T <: ValueCurve} <: ProductionVariableCostCurve{T}
    "The underlying `ValueCurve` representation of this `ProductionVariableCostCurve`"
    value_curve::T
    "(default: natural units (MW)) The units for the x-axis of the curve"
    power_units::UnitSystem = UnitSystem.NATURAL_UNITS
    "Either a fixed value for fuel cost or the [`TimeSeriesKey`](@ref) to a fuel cost time series"
    fuel_cost::Union{Float64, TimeSeriesKey}
    "(default of 0) Fuel consumption at the unit startup proceedure. Additional cost to the startup costs and related only to the initial fuel required to start the unit.
    represented as a [`LinearCurve`](@ref)"
    startup_fuel_offtake::LinearCurve = LinearCurve(0.0)
    "(default of 0) Additional proportional Variable Operation and Maintenance Cost in \$/(power_unit h)
    represented as a [`LinearCurve`](@ref)"
    vom_cost::LinearCurve = LinearCurve(0.0)
end

function FuelCurve(
    value_curve::ValueCurve,
    power_units::UnitSystem,
    fuel_cost::Real,
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
)
    return FuelCurve(
        value_curve,
        power_units,
        Float64(fuel_cost),
        startup_fuel_offtake,
        vom_cost,
    )
end

function FuelCurve(value_curve, fuel_cost)
    FuelCurve(; value_curve, fuel_cost)
end

function FuelCurve(
    value_curve,
    fuel_cost::Union{Float64, TimeSeriesKey},
    startup_fuel_offtake::LinearCurve,
    vom_cost::LinearCurve,
)
    return FuelCurve(;
        value_curve,
        fuel_cost,
        startup_fuel_offtake = startup_fuel_offtake,
        vom_cost = vom_cost,
    )
end

function FuelCurve(
    value_curve,
    power_units::UnitSystem,
    fuel_cost::Union{Float64, TimeSeriesKey},
)
    FuelCurve(; value_curve, power_units = power_units, fuel_cost = fuel_cost)
end

Base.:(==)(a::FuelCurve, b::FuelCurve) =
    (get_value_curve(a) == get_value_curve(b)) &&
    (get_power_units(a) == get_power_units(b)) &&
    (get_fuel_cost(a) == get_fuel_cost(b)) &&
    (get_startup_fuel_offtake(a) == get_startup_fuel_offtake(b)) &&
    (get_vom_cost(a) == get_vom_cost(b))

"Get a `FuelCurve` representing zero fuel usage and zero fuel cost"
Base.zero(::Union{FuelCurve, Type{FuelCurve}}) = FuelCurve(zero(ValueCurve), 0.0)

"Get the fuel cost or the name of the fuel cost time series"
get_fuel_cost(cost::FuelCurve) = cost.fuel_cost
"Get the function for the fuel consumption at startup"
get_startup_fuel_offtake(cost::FuelCurve) = cost.startup_fuel_offtake

Base.show(io::IO, m::MIME"text/plain", curve::ProductionVariableCostCurve) =
    (get(io, :compact, false)::Bool ? _show_compact : _show_expanded)(io, m, curve)

# The strategy here is to put all the short stuff on the first line, then break and let the value_curve take more space
function _show_compact(io::IO, ::MIME"text/plain", curve::CostCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(curve.power_units), vom_cost $(curve.vom_cost), and value_curve:\n  ",
    )
    vc_printout = sprint(show, "text/plain", curve.value_curve; context = io)  # Capture the value_curve `show` so we can indent it
    print(io, replace(vc_printout, "\n" => "\n  "))
end

function _show_compact(io::IO, ::MIME"text/plain", curve::FuelCurve)
    print(
        io,
        "$(nameof(typeof(curve))) with power_units $(curve.power_units), fuel_cost $(curve.fuel_cost), startup_fuel_offtake $(curve.startup_fuel_offtake), vom_cost $(curve.vom_cost), and value_curve:\n  ",
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
end
