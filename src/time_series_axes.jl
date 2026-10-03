"""
    TimeSeriesAxis(name, labels)

Names one non-time dimension of a time series value and labels each of its entries,
e.g. `TimeSeriesAxis("bus", [101, 102])`. Labels are integers or strings and must be
unique within the axis. See [`get_value_axes`](@ref).
"""
struct TimeSeriesAxis
    name::String
    labels::Union{Vector{Int64}, Vector{String}}

    TimeSeriesAxis(name::AbstractString, labels::AbstractVector{<:Integer}) =
        new(String(name), Vector{Int64}(labels))
    TimeSeriesAxis(name::AbstractString, labels::AbstractVector{<:AbstractString}) =
        new(String(name), Vector{String}(labels))
    TimeSeriesAxis(name::AbstractString, labels::AbstractVector) = throw(
        ArgumentError(
            "value axis '$name' labels must be integers or strings; got $(eltype(labels))",
        ),
    )
end

Base.:(==)(a::TimeSeriesAxis, b::TimeSeriesAxis) = a.name == b.name && a.labels == b.labels
Base.hash(a::TimeSeriesAxis, h::UInt) =
    hash(a.labels, hash(a.name, hash(:TimeSeriesAxis, h)))

"""
    get_value_axes(x)

Return the labeled non-time axes of a time series' values, in dimension order, or
`nothing` when the values are unlabeled.
"""
function get_value_axes end

# Each non-time dimension of a value gets exactly one axis, sized to that dimension.
_check_value_axes(::Nothing, _value_dims::Tuple) = nothing

function _check_value_axes(value_axes::Vector{TimeSeriesAxis}, value_dims::Tuple)
    length(value_axes) == length(value_dims) || throw(
        ArgumentError(
            "value_axes names $(length(value_axes)) axes, but each value has " *
            "$(length(value_dims)) dimensions $(value_dims)",
        ),
    )
    names = [axis.name for axis in value_axes]
    allunique(names) || throw(ArgumentError("value_axes names are not unique: $names"))
    for (axis, n) in zip(value_axes, value_dims)
        length(axis.labels) == n || throw(
            ArgumentError(
                "value axis '$(axis.name)' has $(length(axis.labels)) labels, but its " *
                "dimension has size $n",
            ),
        )
        allunique(axis.labels) ||
            throw(ArgumentError("value axis '$(axis.name)' has duplicate labels"))
    end
    return nothing
end

# Kept in the association row's `application_data` under this key; the store carries
# that string to DST rows and OpenAPI rows without interpreting it.
const _VALUE_AXES_KEY = "value_axes"

_label_type(::Vector{Int64}) = "int"
_label_type(::Vector{String}) = "string"

_value_axes_application_data(::Nothing) = nothing
_value_axes_application_data(value_axes::Vector{TimeSeriesAxis}) = JSON.json(
    Dict(
        _VALUE_AXES_KEY => [
            Dict(
                "name" => axis.name,
                "label_type" => _label_type(axis.labels),
                "labels" => axis.labels,
            ) for axis in value_axes
        ],
    ),
)

_value_axes_from_application_data(::Nothing) = nothing

function _value_axes_from_application_data(application_data::AbstractString)
    parsed = try
        JSON.parse(application_data; dicttype = Dict{String, Any})
    catch e
        # Exception inspection inside catch: another client's payload need not be JSON.
        e isa ArgumentError || rethrow()
        return nothing
    end
    return _value_axes_from_parsed(parsed)
end

# Valid JSON that is not IS's object belongs to another client and carries no axes.
_value_axes_from_parsed(_parsed) = nothing

function _value_axes_from_parsed(parsed::Dict{String, Any})
    raw = get(parsed, _VALUE_AXES_KEY, nothing)
    isnothing(raw) && return nothing
    return _decode_axes_list(raw)
end

_decode_axes_list(::Nothing) = nothing

function _decode_axes_list(axes::AbstractVector)
    return TimeSeriesAxis[_decode_axis(axis) for axis in axes]
end

_decode_axes_list(axes) =
    throw(ArgumentError("value_axes must be a list; got $(typeof(axes))"))

_decode_axis(axis::Dict{String, Any}) = TimeSeriesAxis(
    _fetch_required_string_key(axis, "name"),
    _decode_labels(
        _fetch_required_string_key(axis, "label_type"),
        _fetch_required_key(axis, "labels"),
    ),
)

_decode_axis(axis) =
    throw(ArgumentError("value axis must be a dict; got $(typeof(axis))"))

function _fetch_required_key(dict::Dict, key::String)
    haskey(dict, key) ||
        throw(ArgumentError("value axis missing required key '$key'"))
    return dict[key]
end

function _fetch_required_string_key(dict::Dict, key::String)
    val = _fetch_required_key(dict, key)
    val isa AbstractString || throw(
        ArgumentError(
            "value axis field '$key' must be a string; got $(typeof(val))",
        ),
    )
    return String(val)
end

function _decode_labels(label_type::AbstractString, labels::AbstractVector)
    label_type == "int" &&
        return Int64[_int_label(label, label_type) for label in labels]
    label_type == "string" &&
        return String[_string_label(label, label_type) for label in labels]
    throw(ArgumentError("unknown value axis label_type '$label_type'"))
end

_int_label(label::Integer, ::AbstractString) = Int64(label)
_int_label(label, label_type) = throw(
    ArgumentError(
        "value axis with label_type '$label_type' has label of type $(typeof(label)); " *
        "expected Integer",
    ),
)

_string_label(label::AbstractString, ::AbstractString) = String(label)
_string_label(label, label_type) = throw(
    ArgumentError(
        "value axis with label_type '$label_type' has label of type $(typeof(label)); " *
        "expected AbstractString",
    ),
)
