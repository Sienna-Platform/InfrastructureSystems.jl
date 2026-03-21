# These will get encoded into each dictionary when a struct is serialized.
const METADATA_KEY = "__metadata__"
const TYPE_KEY = "type"
const MODULE_KEY = "module"
const PARAMETERS_KEY = "parameters"
const CONSTRUCT_WITH_PARAMETERS_KEY = "construct_with_parameters"
const FUNCTION_KEY = "function"

"""
Serializes a InfrastructureSystemsType to a JSON file.
"""
function to_json(
    obj::T,
    filename::AbstractString;
    force = false,
    pretty = false,
) where {T <: InfrastructureSystemsType}
    if !force && isfile(filename)
        error("$filename already exists. Set force=true to overwrite.")
    end
    result = open(filename, "w") do io
        return to_json(io, obj; pretty = pretty)
    end

    @info "Serialized $T to $filename"
    return result
end

"""
Serializes a InfrastructureSystemsType to a JSON string.
"""
function to_json(obj::T; pretty = false, indent = 2) where {T <: InfrastructureSystemsType}
    try
        if pretty
            io = IOBuffer()
            JSON3.pretty(io, serialize(obj), JSON3.AlignmentContext(; indent = indent))
            return take!(io)
        else
            return JSON3.write(serialize(obj))
        end
    catch e
        @error "Failed to serialize $(summary(obj))"
        rethrow(e)
    end
end

function to_json(
    io::IO,
    obj::T;
    pretty = false,
    indent = 2,
) where {T <: InfrastructureSystemsType}
    data = serialize(obj)
    if pretty
        res = JSON3.pretty(io, data, JSON3.AlignmentContext(; indent = indent))
    else
        res = JSON3.write(io, data)
    end

    return res
end

"""
Deserializes a InfrastructureSystemsType from a JSON filename.
"""
function from_json(::Type{T}, filename::String) where {T <: InfrastructureSystemsType}
    return open(filename) do io
        from_json(io, T)
    end
end

"""
Deserializes a InfrastructureSystemsType from String or IO.
"""
function from_json(io::Union{IO, String}, ::Type{T}) where {T <: InfrastructureSystemsType}
    return deserialize(T, JSON3.read(io, Dict))
end

"""
Serialize the Julia value into standard types that can be converted to non-Julia formats,
such as JSON. In cases where val is an instance of a struct, return a Dict. In cases where
val is a scalar value, return that value.
"""
function serialize(val::T) where {T <: InfrastructureSystemsType}
    @debug "serialize InfrastructureSystemsType" _group = LOG_GROUP_SERIALIZATION val T
    return serialize_struct(val)
end

function serialize(vals::Vector{T}) where {T <: InfrastructureSystemsType}
    @debug "serialize Vector{InfrastructureSystemsType}" _group = LOG_GROUP_SERIALIZATION vals T
    return serialize_struct.(vals)
end

function serialize(func::Function)
    return Dict{String, Any}(
        METADATA_KEY => Dict{String, Any}(
            FUNCTION_KEY => string(nameof(func)),
            MODULE_KEY => string(parentmodule(func)),
        ),
    )
end

function serialize_struct(val::T) where {T}
    @debug "serialize_struct" _group = LOG_GROUP_SERIALIZATION val T
    data = Dict{String, Any}(
        string(name) => serialize(getproperty(val, name)) for name in fieldnames(T)
    )
    add_serialization_metadata!(data, T)
    return data
end

"""
Add type information to the dictionary that can be used to deserialize the value.
"""
function add_serialization_metadata!(data::Dict, ::Type{T}) where {T}
    data[METADATA_KEY] = Dict{String, Any}(
        TYPE_KEY => string(nameof(T)),
        MODULE_KEY => string(parentmodule(T)),
    )
    if !isempty(T.parameters)
        data[METADATA_KEY][PARAMETERS_KEY] = [string(nameof(x)) for x in T.parameters]
    end

    return
end

# TimeSeriesFunctionData{T} is parametric — ensure the type parameter is reconstructed
# during deserialization by setting CONSTRUCT_WITH_PARAMETERS_KEY.
function add_serialization_metadata!(
    data::Dict,
    ::Type{TimeSeriesFunctionData{T}},
) where {T <: StaticFunctionData}
    data[METADATA_KEY] = Dict{String, Any}(
        TYPE_KEY => string(nameof(TimeSeriesFunctionData)),
        MODULE_KEY => string(parentmodule(TimeSeriesFunctionData)),
        PARAMETERS_KEY => [string(nameof(T))],
        CONSTRUCT_WITH_PARAMETERS_KEY => true,
    )
    return
end

"""
Return the type information for the serialized struct.
"""
get_serialization_metadata(data::Dict) = data[METADATA_KEY]

function get_type_from_serialization_data(data::Dict)
    return get_type_from_serialization_metadata(get_serialization_metadata(data))
end

function get_type_from_serialization_metadata(metadata::Dict)
    _module = get_module(metadata[MODULE_KEY])
    base_type = getproperty(_module, Symbol(metadata[TYPE_KEY]))
    if !get(metadata, CONSTRUCT_WITH_PARAMETERS_KEY, false)
        return base_type
    end

    # This has several limitations and is only a workaround for PSY.Reserve subtypes.
    # - each parameter must be in _module
    # - does not support nested parametrics.
    # Reserves should be fixed and then we can remove this hack.
    parameters = [getproperty(_module, Symbol(x)) for x in metadata[PARAMETERS_KEY]]
    return base_type{parameters...}
end

serialize(val::Base.RefValue{T}) where {T} = serialize(val[])

# The default implementation allows any scalar type (or collection of scalar types) to
# work. The JSON library must be able to encode and decode anything passed here.

serialize(val::T) where {T} = deepcopy(val)

"""
Deserialize an object from standard types stored in non-Julia formats, such as JSON, into
Julia types.
"""
function deserialize(::Type{T}, data::Dict) where {T <: InfrastructureSystemsType}
    @debug "deserialize InfrastructureSystemsType" _group = LOG_GROUP_SERIALIZATION T data
    return deserialize_struct(T, data)
end

function deserialize_to_dict(::Type{T}, data::Dict) where {T}
    # Note: mostly duplicated in src/deterministic_metadata.jl
    vals = Dict{Symbol, Any}()
    for (field_name, field_type) in zip(fieldnames(T), fieldtypes(T))
        name_str = string(field_name)
        # Some types may not serialize optional fields.
        !haskey(data, name_str) && continue
        val = data[name_str]
        if val isa Dict && haskey(val, METADATA_KEY)
            metadata = get_serialization_metadata(val)
            if haskey(metadata, FUNCTION_KEY)
                vals[field_name] = deserialize(Function, val)
            else
                vals[field_name] =
                    deserialize(get_type_from_serialization_metadata(metadata), val)
            end
        else
            vals[field_name] = deserialize(field_type, val)
        end
    end
    return vals
end

function deserialize_struct(::Type{T}, data::Dict) where {T}
    vals = deserialize_to_dict(T, data)
    return T(; vals...)
end

function deserialize(::Type{Function}, data::Dict)
    metadata = data[METADATA_KEY]
    return get_type_from_strings(metadata[MODULE_KEY], metadata[FUNCTION_KEY])
end

function deserialize(::Type{T}, data::Any) where {T}
    @debug "deserialize Any" _group = LOG_GROUP_SERIALIZATION T data
    return deepcopy(data)
end

function deserialize(::Type{T}, data::Array) where {T <: Tuple}
    return tuple(data...)
end

function deserialize(::Type{T}, data::Any) where {T <: AbstractFloat}
    return T(data)
end

function deserialize(::Type{T}, data::Dict{String, U}) where {T <: NamedTuple, U}
    value_data = U[data[string(key)] for key in fieldnames(T)]
    return T(value_data)
end

# Some types that definitely won't be deserialized from raw Dicts
const _NOT_FROM_DICT = Union{Nothing, Real, AbstractString, TimeSeriesKey}

# If deserializing into a Union of some _NOT_FROM_DICT and something else (e.g., a
# NamedTuple) and we are given a Dict as input data, pick the something else. NOTE: it would
# be great to do this purely using the type system. I found ways to do subsets of the task
# this way that worked, but they all made `detect_unbound_args` complain. I'm not convinced
# this isn't a bug/incompleteness in `detect_unbound_args`.
function deserialize(T::Union, data::Dict)
    # This seems to be the least sketchy way to get all the types in a Union, at least
    # better than the also undocumented T.a and T.b, see
    # https://github.com/JuliaLang/julia/issues/53193
    types_within = Base.uniontypes(T)
    maybe_from_dict = filter(x -> !(x <: _NOT_FROM_DICT), types_within)
    (length(maybe_from_dict) == 1) && (return deserialize(first(maybe_from_dict), data))
    throw(ArgumentError("Cannot pick which of union type $T to deserialize to"))
end

function deserialize(::Type{T}, data::Array) where {T <: Vector{<:Tuple}}
    return [tuple(x...) for x in data]
end

# Enables JSON serialization of Dates.Period.
# The default implementation fails because the field is defined as abstract.
# Encode the type when serializing so that the correct value can be deserialized.
function serialize(resolution::Dates.Period)
    return Dict(
        "value" => resolution.value,
        TYPE_KEY => string(nameof(typeof(resolution))),
    )
end

function deserialize(::Type{Dates.Period}, data::Dict)
    return getproperty(Dates, Symbol(data[TYPE_KEY]))(data["value"])
end

deserialize(::Type{Dates.DateTime}, val::AbstractString) = Dates.DateTime(val)

# The next methods fix serialization of UUIDs. The underlying type of a UUID is a UInt128.
# JSON tries to encode this as a number in JSON. Encoding integers greater than can
# be stored in a signed 64-bit integer sometimes does not work - at least when using
# JSON3. The number gets converted to a float in scientific notation, and so
# the UUID is truncated and essentially lost. These functions cause JSON to encode UUIDs as
# strings and then convert them back during deserialization.

serialize(uuid::Base.UUID) = Dict("value" => string(uuid))
serialize(uuids::Vector{Base.UUID}) = serialize.(uuids)
serialize(uuids::Set{Base.UUID}) = serialize.(uuids)
deserialize(::Type{Base.UUID}, data::Dict) = Base.UUID(data["value"])

serialize(value::Complex) = Dict("real" => real(value), "imag" => imag(value))
deserialize(::Type{Complex}, data::Dict) = Complex(data["real"], data["imag"])
deserialize(::Type{Complex{T}}, data::Dict) where {T} =
    Complex(T(data["real"]), T(data["imag"]))

deserialize(::Type{Vector{Symbol}}, data::Vector) = Symbol.(data)
serialize(value::Vector{Complex{T}}) where {T} =
    [Dict("real" => real(x), "imag" => imag(x)) for x in value]
deserialize(::Type{Vector{Complex{T}}}, data::Array) where {T} =
    [Complex(T(x["real"]), T(x["imag"])) for x in data]

function serialize_julia_info()
    data = Dict{String, Any}("julia_version" => string(VERSION))
    data["package_info"] = Pkg.dependencies()
    return data
end

"""
Perform a test to see if JSON3 can convert this value so that the code can give the user a
a comprehensible corrective action.
"""
function is_ext_valid_for_serialization(value)
    isnothing(value) && return true
    is_valid = true
    try
        JSON3.write(value)
    catch
        is_valid = false
    end

    if !is_valid
        @error "Failed to serialize an 'ext' value. Please ensure that the " *
               "contents follow the rules provided in the documentation. Generally, only " *
               "basic types are allowed - strings and numbers and arrays, dictionaries, and " *
               "structs of those." value
    end

    return is_valid
end
