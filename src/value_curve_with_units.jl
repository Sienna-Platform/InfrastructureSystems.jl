"""
Supertype for curve representations that carry their own unit system.

Parameterized by a [`ValueCurve`](@ref) type `T` and an
[`AbstractUnitSystem`](@ref) type `U`: the unit system in which this curve's *power axes*
are expressed. The x-axis is always power, so `U` always governs it. Whether `U` also
governs the y-axis depends on the family and is given by the
[`y_axis_power_dimension`](@ref) trait: the y-axis of a [`CostCurve`](@ref) or
[`FuelCurve`](@ref) is currency or fuel and carries no power units, while the y-axis of a
[`LossCurve`](@ref) is power in the same base as x.

Subtypes are [`ProductionVariableCostCurve`](@ref) (costs) and
[`LossCurve`](@ref) (losses). Methods common to both belong here; methods that
require a `vom_cost` belong on `ProductionVariableCostCurve`.
"""
abstract type ValueCurveWithUnits{T <: ValueCurve, U <: AbstractUnitSystem} end

"Get the underlying `ValueCurve` representation of this curve"
get_value_curve(curve::ValueCurveWithUnits) = curve.value_curve
"""
Get the units marker for the power axes of the curve as an instance of the
second type parameter (e.g. `NaturalUnit()`, `SystemBaseUnit()`,
`DeviceBaseUnit()`). Always the units of the x-axis; also the units of the y-axis when
[`y_axis_power_dimension`](@ref) is nonzero, as it is for a [`LossCurve`](@ref).
"""
get_power_units(::ValueCurveWithUnits{T, U}) where {T, U} = U()
"Get the `FunctionData` representation of this curve's `ValueCurve`"
get_function_data(curve::ValueCurveWithUnits) = get_function_data(get_value_curve(curve))
"Get the `initial_input` field of this curve's `ValueCurve` (not defined for input-output data)"
get_initial_input(curve::ValueCurveWithUnits) = get_initial_input(get_value_curve(curve))

"Calculate the convexity of the underlying data"
function is_convex(curve::ValueCurve{T}) where {T <: TimeSeriesFunctionData}
    throw(
        ArgumentError(
            "Convexity is not defined for time-series-backed ValueCurve; use time-series specific analysis instead.",
        ),
    )
end
is_convex(curve::ValueCurveWithUnits) = is_convex(get_value_curve(curve))
"Calculate the concavity of the underlying data"
function is_concave(curve::ValueCurve{T}) where {T <: TimeSeriesFunctionData}
    throw(
        ArgumentError(
            "Concavity is not defined for time-series-backed ValueCurve; use time-series specific analysis instead.",
        ),
    )
end
is_concave(curve::ValueCurveWithUnits) = is_concave(get_value_curve(curve))

"Check if the curve is backed by time series data"
is_time_series_backed(curve::ValueCurveWithUnits) =
    is_time_series_backed(get_value_curve(curve))

"Get the `TimeSeriesKey` from the underlying `ValueCurve` of a time-series-backed curve."
# `FuelCurve` shadows this: it has a second, independently TS-backed field.
get_time_series_key(
    curve::ValueCurveWithUnits{<:ValueCurve{<:TimeSeriesFunctionData}},
) = get_time_series_key(get_value_curve(curve))

"Fallback: throw a clear `ArgumentError` when `get_time_series_key` is called on a non-TS-backed curve."
get_time_series_key(curve::ValueCurveWithUnits) = throw(
    ArgumentError(
        "$(nameof(typeof(curve))) is not time-series-backed; get_time_series_key is undefined",
    ),
)

Base.:(==)(a::T, b::T) where {T <: ValueCurveWithUnits} = double_equals_from_fields(a, b)

Base.isequal(a::T, b::T) where {T <: ValueCurveWithUnits} = isequal_from_fields(a, b)

Base.hash(a::ValueCurveWithUnits, h::UInt) = hash_from_fields(a, h)

# ── Units of the y-axis, and conversion between bases ─────────────────────────

"""
    y_axis_power_dimension(::Type{<:ValueCurveWithUnits}) -> Val

How many powers of the unit base the y-axis of a curve family carries. `Val(0)` for
[`CostCurve`](@ref) and [`FuelCurve`](@ref), whose y-axes are currency or fuel and are
untouched by a change of power base; `Val(1)` for [`LossCurve`](@ref), whose y-axis is
power in the same base as its x-axis.

This one number is the whole difference between the families under a change of base. With
`ρ` the ratio between the two bases, the converted curve represents

    f_to(x) = f_from(ρ * x) / ρ^p

where `p` is this dimension: `ρ^0 = 1` recovers the x-only rescaling of a cost curve.

Returned as a `Val` rather than an `Int` so the exponent is part of the type: the
conversion below dispatches on it, so the branch is resolved at compile time and the
arithmetic folds to a multiply or a divide, never a call to `^`.
"""
function y_axis_power_dimension end

# `f_to(x) = f_from(ρ * x) / ρ^p`, one method per `p`, so `^` never appears.
@inline _convert_curve_axes(vc::ValueCurve, ratio::Real, ::Val{0}) = scale_x(vc, ratio)
@inline _convert_curve_axes(vc::ValueCurve, ratio::Real, ::Val{1}) =
    inv(ratio) * scale_x(vc, ratio)

"""
Rescale the value curve of `curve` by `ratio`, applying the change of base to whichever
axes the family's units govern. `ratio` comes from [`_cost_coeff_ratio`](@ref), the same
dispatch table that backs `convert_cost_coefficient`, so no new conversion math is
introduced here.
"""
@inline _convert_value_curve(curve::C, ratio::Real) where {C <: ValueCurveWithUnits} =
    _convert_curve_axes(get_value_curve(curve), ratio, y_axis_power_dimension(C))

# ── Serialization ─────────────────────────────────────────────────────────────
# `U` has no corresponding field, so it is serialized under a "power_units" key.

_unit_system_instance(name::AbstractString) = _unit_system_instance(String(name))
function _unit_system_instance(name::String)
    name == "NaturalUnit" && return NaturalUnit()
    name == "SystemBaseUnit" && return SystemBaseUnit()
    name == "DeviceBaseUnit" && return DeviceBaseUnit()
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

function deserialize(::Type{T}, data::Dict) where {T <: ValueCurveWithUnits}
    vals = Dict{Symbol, Any}(
        Symbol(k) => _deserialize_curve_field(Val(Symbol(k)), v)
        for (k, v) in data if k != METADATA_KEY && k != "power_units"
    )
    return T(; vals..., power_units = _unit_system_instance(data["power_units"]))
end

Base.show(io::IO, m::MIME"text/plain", curve::ValueCurveWithUnits) =
    (get(io, :compact, false)::Bool ? _show_compact : _show_expanded)(io, m, curve)

function _show_expanded(io::IO, ::MIME"text/plain", curve::ValueCurveWithUnits)
    print(io, "$(nameof(typeof(curve))):")
    for field_name in fieldnames(typeof(curve))
        val = getproperty(curve, field_name)
        val_printout =
            replace(sprint(show, "text/plain", val; context = io), "\n" => "\n  ")
        print(io, "\n  $(field_name): $val_printout")
    end
    print(io, "\n  power_units: $(get_power_units(curve))")
end
