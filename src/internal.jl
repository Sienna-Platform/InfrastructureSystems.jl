
import UUIDs

abstract type UnitsData end

@scoped_enum(UnitSystem, SYSTEM_BASE = 0, DEVICE_BASE = 1, NATURAL_UNITS = 2,)

@doc """
Unit system for component data values.

# Values
- `SYSTEM_BASE`: Per-unit values on the system base power
- `DEVICE_BASE`: Per-unit values on the device base power
- `NATURAL_UNITS`: Values in natural units (e.g., MW, MVAR)
""" UnitSystem

@kwdef mutable struct SystemUnitsSettings <: UnitsData
    base_value::Float64
    unit_system::UnitSystem
end

serialize(val::SystemUnitsSettings) = serialize_struct(val)
deserialize(T::Type{<:SystemUnitsSettings}, val::Dict) = deserialize_struct(T, val)

@kwdef struct SharedSystemReferences <: InfrastructureSystemsType
    supplemental_attribute_manager::Any = nothing
    time_series_manager::Any = nothing
end

"""
Internal storage common to InfrastructureSystems types.
"""
mutable struct InfrastructureSystemsInternal <: InfrastructureSystemsType
    uuid::Base.UUID
    shared_system_references::Union{Nothing, SharedSystemReferences}
    units_info::Union{Nothing, SystemUnitsSettings}
    ext::Union{Nothing, Dict{String, Any}}
end

"""
Creates InfrastructureSystemsInternal with a new UUID.
"""
InfrastructureSystemsInternal(;
    uuid = make_uuid(),
    shared_system_references = nothing,
    units_info = nothing,
    ext = nothing,
) =
    InfrastructureSystemsInternal(uuid, shared_system_references, units_info, ext)

"""
Creates InfrastructureSystemsInternal with an existing UUID.
"""
InfrastructureSystemsInternal(u::Base.UUID) =
    InfrastructureSystemsInternal(u, nothing, nothing, nothing)

"""
Return a user-modifiable dictionary to store extra information.
"""
function get_ext(obj::InfrastructureSystemsInternal)
    if isnothing(obj.ext)
        obj.ext = Dict{String, Any}()
    end

    return obj.ext
end

"""
Clear any value stored in ext.
"""
function clear_ext!(obj::InfrastructureSystemsInternal)
    obj.ext = nothing
    return
end

get_uuid(internal::InfrastructureSystemsInternal) = internal.uuid
set_uuid!(internal::InfrastructureSystemsInternal, uuid) = internal.uuid = uuid

function set_shared_system_references!(
    internal::InfrastructureSystemsInternal,
    refs::Union{Nothing, SharedSystemReferences},
)
    internal.shared_system_references = refs
    return
end

get_units_info(internal::InfrastructureSystemsInternal) = internal.units_info
set_units_info!(internal::InfrastructureSystemsInternal, val) = internal.units_info = val

"""
Gets the UUID for any InfrastructureSystemsType.
"""
function get_uuid(obj::InfrastructureSystemsType)
    return get_internal(obj).uuid
end

"""
Assign a new UUID.
"""
function assign_new_uuid_internal!(obj::InfrastructureSystemsType)
    get_internal(obj).uuid = make_uuid()
    return
end

function serialize(internal::InfrastructureSystemsInternal)
    data = Dict{String, Any}()

    for field in fieldnames(InfrastructureSystemsInternal)
        val = getproperty(internal, field)
        # reset the units data since this is a struct related to the system the components is
        # added which is resolved later in the de-serialization.
        if val isa UnitsData
            val = nothing
        elseif field == :shared_system_references
            continue
        else
            val = serialize(val)
        end
        if field == :ext
            if !is_ext_valid_for_serialization(val)
                error(
                    "system or component with uuid=$(internal.uuid) has a value in ext " *
                    "that cannot be serialized",
                )
            end
        end
        data[string(field)] = val
    end

    return data
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::InfrastructureSystemsInternal,
    y::InfrastructureSystemsInternal;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    match = true
    for name in fieldnames(InfrastructureSystemsInternal)
        if name in exclude || (name == :uuid && !compare_uuids) ||
           name == :shared_system_references
            continue
        end
        if name == :ext
            val1 = getproperty(x, name)
            if val1 isa Dict && isempty(val1)
                val1 = nothing
            end
            val2 = getproperty(y, name)
            if val2 isa Dict && isempty(val2)
                val2 = nothing
            end
            if isnothing(val1) && val2 isa Dict &&
               collect(keys(val2)) == [SERIALIZATION_METADATA_KEY]
                continue
            end
            if !compare_values(
                match_fn,
                val1,
                val2;
                compare_uuids = compare_uuids,
                exclude = exclude,
            )
                @error "ext does not match" val1 val2
                match = false
            end
        elseif !compare_values(
            match_fn,
            getproperty(x, name),
            getproperty(y, name);
            compare_uuids = compare_uuids,
            exclude = exclude,
        )
            @error "InfrastructureSystemsInternal field=$name does not match"
            match = false
        end
    end

    return match
end

make_uuid() = UUIDs.uuid4()
