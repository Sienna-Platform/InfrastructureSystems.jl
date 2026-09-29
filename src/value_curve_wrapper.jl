"""
Supertype for curves that wrap a [`ValueCurve`](@ref) and give its axes physical meaning:
costs ([`ProductionVariableCostCurve`](@ref), always in natural units) and losses
([`LossCurve`](@ref), via [`ValueCurveWithUnits`](@ref)).

Methods that only read the wrapped curve live here.
"""
abstract type ValueCurveWrapper{T <: ValueCurve} end

"""
A `ValueCurveWrapper` that carries its own unit system `U <: AbstractUnitSystem`
for its power axes. `U` governs both axes; [`y_axis_power_dimension`](@ref) gives the
power of the base the y-axis carries.

The subtype is [`LossCurve`](@ref), whose axes are both power in base `U`. Cost curves are
always in natural units (MW) and are not `ValueCurveWithUnits`.
"""
abstract type ValueCurveWithUnits{T <: ValueCurve, U <: AbstractUnitSystem} <:
              ValueCurveWrapper{T} end

"Get the underlying `ValueCurve` representation of this curve"
get_value_curve(curve::ValueCurveWrapper) = curve.value_curve
"""
Get the unit system of the power axes of the curve as an instance of the second type
parameter (e.g. `NaturalUnit()`, `SystemBaseUnit()`, `ComponentBaseUnit()`).
"""
get_power_units(::ValueCurveWithUnits{T, U}) where {T, U} = U()
"Get the `FunctionData` representation of this curve's `ValueCurve`"
get_function_data(curve::ValueCurveWrapper) = get_function_data(get_value_curve(curve))
"Get the `initial_input` field of this curve's `ValueCurve` (not defined for input-output data)"
get_initial_input(curve::ValueCurveWrapper) = get_initial_input(get_value_curve(curve))

"Calculate the convexity of the underlying data"
function is_convex(curve::ValueCurve{T}) where {T <: TimeSeriesFunctionData}
    throw(
        ArgumentError(
            "Convexity is not defined for time-series-backed ValueCurve; use time-series specific analysis instead.",
        ),
    )
end
is_convex(curve::ValueCurveWrapper) = is_convex(get_value_curve(curve))
"Calculate the concavity of the underlying data"
function is_concave(curve::ValueCurve{T}) where {T <: TimeSeriesFunctionData}
    throw(
        ArgumentError(
            "Concavity is not defined for time-series-backed ValueCurve; use time-series specific analysis instead.",
        ),
    )
end
is_concave(curve::ValueCurveWrapper) = is_concave(get_value_curve(curve))

"Check if the curve is backed by time series data"
is_time_series_backed(curve::ValueCurveWrapper) =
    is_time_series_backed(get_value_curve(curve))

"Get the `TimeSeriesKey` from the underlying `ValueCurve` of a time-series-backed curve."
# `FuelCurve` shadows this: it has a second, independently TS-backed field.
get_time_series_key(
    curve::ValueCurveWrapper{<:ValueCurve{<:TimeSeriesFunctionData}},
) = get_time_series_key(get_value_curve(curve))

"Fallback: throw a clear `ArgumentError` when `get_time_series_key` is called on a non-TS-backed curve."
get_time_series_key(curve::ValueCurveWrapper) = throw(
    ArgumentError(
        "$(nameof(typeof(curve))) is not time-series-backed; get_time_series_key is undefined",
    ),
)

Base.:(==)(a::T, b::T) where {T <: ValueCurveWrapper} = double_equals_from_fields(a, b)

Base.isequal(a::T, b::T) where {T <: ValueCurveWrapper} = isequal_from_fields(a, b)

Base.hash(a::ValueCurveWrapper, h::UInt) = hash_from_fields(a, h)

# ── Units of the y-axis, and conversion between bases ─────────────────────────

"""
    y_axis_power_dimension(::Type{<:ValueCurveWithUnits}) -> Val

How many powers of the unit base the y-axis of a curve family carries: `Val(1)` for
[`LossCurve`](@ref), whose y-axis is power in the same base as its x-axis. With `ρ` the
ratio between the two bases, the converted curve represents

    f_to(x) = f_from(ρ * x) / ρ^p

where `p` is this dimension.

Returned as a `Val` rather than an `Int` so the conversion dispatches on it and never
calls `^`. Only `Val(1)` has a conversion method.
"""
function y_axis_power_dimension end

# `f_to(x) = f_from(ρ * x) / ρ`, the `p = 1` case.
@inline _convert_curve_axes(vc::ValueCurve, ratio::Real, ::Val{1}) =
    inv(ratio) * scale_x(vc, ratio)

"""
Rescale the value curve of `curve` by `ratio`, applying the change of base to both axes.
`ratio` is the x-axis ratio between the two bases (`x_from = ratio * x_to`), resolved by
the caller: `InfrastructureSystems` has no component or base power to derive it from.
"""
@inline _convert_value_curve(curve::C, ratio::Real) where {C <: ValueCurveWithUnits} =
    _convert_curve_axes(get_value_curve(curve), ratio, y_axis_power_dimension(C))

# ── Serialization ─────────────────────────────────────────────────────────────
# A wrapper serializes its fields. `ValueCurveWithUnits` adds its `U`, which has no
# field, under a "power_units" key.

serialize(val::ValueCurveWrapper) = serialize_struct(val)

_unit_system_instance(name::AbstractString) = _unit_system_instance(String(name))
function _unit_system_instance(name::String)
    name == "NaturalUnit" && return NaturalUnit()
    name == "SystemBaseUnit" && return SystemBaseUnit()
    name == "ComponentBaseUnit" && return ComponentBaseUnit()
    throw(ArgumentError("$name is not a known AbstractUnitSystem"))
end

function serialize(val::ValueCurveWithUnits)
    data = serialize_struct(val)
    data["power_units"] = string(nameof(typeof(get_power_units(val))))
    return data
end

# Per-field deserializers, keyed on the serialized field name. A key with no method here
# fails loudly rather than being silently dropped.
_deserialize_curve_field(::Val{:value_curve}, raw::AbstractDict) =
    deserialize(get_type_from_serialization_data(raw), raw)

# Keyword arguments for the curve's constructor. "power_units" is not a field; each
# family reads it itself.
_deserialize_curve_fields(data::Dict) = Dict{Symbol, Any}(
    Symbol(k) => _deserialize_curve_field(Val(Symbol(k)), v)
    for (k, v) in data if k != METADATA_KEY && k != "power_units"
)

deserialize(::Type{T}, data::Dict) where {T <: ValueCurveWithUnits} = T(;
    _deserialize_curve_fields(data)...,
    power_units = _unit_system_instance(data["power_units"]),
)

Base.show(io::IO, m::MIME"text/plain", curve::ValueCurveWrapper) =
    (get(io, :compact, false)::Bool ? _show_compact : _show_expanded)(io, m, curve)

function _show_expanded(io::IO, ::MIME"text/plain", curve::ValueCurveWrapper)
    print(io, "$(nameof(typeof(curve))):")
    for field_name in fieldnames(typeof(curve))
        val = getproperty(curve, field_name)
        val_printout =
            replace(sprint(show, "text/plain", val; context = io), "\n" => "\n  ")
        print(io, "\n  $(field_name): $val_printout")
    end
    _show_power_units(io, curve)
end

# Only a curve that carries its own unit system prints one.
_show_power_units(::IO, ::ValueCurveWrapper) = nothing
_show_power_units(io::IO, curve::ValueCurveWithUnits) =
    print(io, "\n  power_units: $(get_power_units(curve))")
