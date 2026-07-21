
import UUIDs

@scoped_enum(UnitSystem, SYSTEM_BASE = 0, DEVICE_BASE = 1, NATURAL_UNITS = 2,)

@doc """
Unit system for component data values.

# Values
- `SYSTEM_BASE`: Per-unit values on the system base power
- `DEVICE_BASE`: Per-unit values on the device base power
- `NATURAL_UNITS`: Values in natural units (e.g., MW, MVAR)
""" UnitSystem

@kwdef struct SharedSystemReferences <: InfrastructureSystemsType
    supplemental_attribute_manager::Union{Nothing, AbstractSupplementalAttributeManager} =
        nothing
    time_series_manager::Union{Nothing, AbstractTimeSeriesManager} = nothing
end

"""
Sentinel value for the integer `id` of a component or supplemental attribute that has not
yet been attached to a [`SystemData`](@ref). Assigned IDs start at 1.
"""
const UNASSIGNED_ID = 0

"""
Internal storage common to [`InfrastructureSystemsType`](@ref)s.

Components and supplemental attributes are identified by an integer `id` assigned by the
owning [`SystemData`](@ref) when they are attached (see [`get_id`](@ref)); it is
[`UNASSIGNED_ID`](@ref) until then. Each instance also holds optional
[`SharedSystemReferences`](@ref) when attached to a system, optional unit metadata, and an
optional user extension dictionary accessed through [`get_ext`](@ref).
"""
mutable struct InfrastructureSystemsInternal <: InfrastructureSystemsType
    id::Int
    shared_system_references::Union{Nothing, SharedSystemReferences}
    base_value::Union{Nothing, Float64}
    ext::Union{Nothing, Dict{String, Any}}
end

"""
Creates InfrastructureSystemsInternal with an unassigned integer id.
"""
InfrastructureSystemsInternal(;
    id = UNASSIGNED_ID,
    shared_system_references = nothing,
    base_value = nothing,
    ext = nothing,
) =
    InfrastructureSystemsInternal(id, shared_system_references, base_value, ext)

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

get_id(internal::InfrastructureSystemsInternal) = internal.id
set_id!(internal::InfrastructureSystemsInternal, id::Int) = internal.id = id

function set_shared_system_references!(
    internal::InfrastructureSystemsInternal,
    refs::Union{Nothing, SharedSystemReferences},
)
    internal.shared_system_references = refs
    return
end

get_base_value(internal::InfrastructureSystemsInternal) = internal.base_value
set_base_value!(internal::InfrastructureSystemsInternal, val) = internal.base_value = val

"""
Generic accessor for the base-value units anchor: works for anything implementing
`get_internal`. Types that store their own anchor directly (rather than through an
`InfrastructureSystemsInternal`) should add a concrete method instead.
"""
get_base_value(x::InfrastructureSystemsType) = get_base_value(get_internal(x))
set_base_value!(x::InfrastructureSystemsType, val) = set_base_value!(get_internal(x), val)

"""
Gets the integer id of a component or supplemental attribute. Returns [`UNASSIGNED_ID`](@ref)
if the object has not been attached to a [`SystemData`](@ref).
"""
function get_id(obj::InfrastructureSystemsType)
    return get_internal(obj).id
end

"""
Sets the integer id of a component or supplemental attribute.
"""
function set_id!(obj::InfrastructureSystemsType, id::Int)
    set_id!(get_internal(obj), id)
    return
end

function serialize(internal::InfrastructureSystemsInternal)
    data = Dict{String, Any}()

    for field in fieldnames(InfrastructureSystemsInternal)
        val = getproperty(internal, field)
        # base_value is resolved against the system the component is added to, later, at
        # deserialization time - never serialize the live value.
        if field == :base_value
            val = nothing
        elseif field == :shared_system_references
            continue
        else
            val = serialize(val)
        end
        if field == :ext
            if !is_ext_valid_for_serialization(val)
                error(
                    "system or component with id=$(internal.id) has a value in ext " *
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
        if name in exclude || (name == :id && !compare_uuids) ||
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
