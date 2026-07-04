"""
Assign a new UUID to a detached component.

Do not call this directly on a component attached to a `SystemData` — the UUID index and
the time-series / supplemental-attribute mappings would become stale. Use
`assign_new_uuid!(data, component)` instead, which keeps all three in sync.
"""
function assign_new_uuid_internal!(component::InfrastructureSystemsComponent)
    if !isnothing(get_shared_system_references(component))
        error(
            "Cannot call assign_new_uuid_internal! on $(summary(component)) while it is " *
            "attached to a system. Use assign_new_uuid!(data, component) instead.",
        )
    end
    old_uuid = get_uuid(component)
    new_uuid = make_uuid()
    mgr = get_time_series_manager(component)
    if !isnothing(mgr)
        replace_component_uuid!(mgr.metadata_store, old_uuid, new_uuid)
    end
    associations = _get_supplemental_attribute_associations(component)
    if !isnothing(associations)
        replace_component_uuid!(associations, old_uuid, new_uuid)
    end
    set_uuid!(get_internal(component), new_uuid)
    return
end

"""
Return true if the component has supplemental attributes of the given type.
"""
function has_supplemental_attributes(
    component::InfrastructureSystemsComponent,
    ::Type{T},
) where {T <: SupplementalAttribute}
    associations = _get_supplemental_attribute_associations(component)
    isnothing(associations) && return false
    return has_association(associations, component, T)
end

has_supplemental_attributes(
    T::Type{<:SupplementalAttribute},
    x::InfrastructureSystemsComponent,
) = has_supplemental_attributes(x, T)

"""
Return true if the component has supplemental attributes.
"""
function has_supplemental_attributes(component::InfrastructureSystemsComponent)
    associations = _get_supplemental_attribute_associations(component)
    isnothing(associations) && return false
    return has_association(associations, component)
end

function clear_supplemental_attributes!(component::InfrastructureSystemsComponent)
    mgr = _get_supplemental_attributes_manager(component)
    isnothing(mgr) && return
    for uuid in list_associated_supplemental_attribute_uuids(mgr.associations, component)
        attribute = get_supplemental_attribute(mgr, uuid)
        remove_supplemental_attribute!(mgr, component, attribute)
    end
    @debug "Cleared attributes in $(summary(component))."
    return
end

"""
Return a Vector of supplemental_attributes. T can be concrete or abstract.

# Arguments

  - `T`: supplemental_attribute type
  - `supplemental_attributes::SupplementalAttributes`: SupplementalAttributes in the system
  - `filter_func::Union{Nothing, Function} = nothing`: Optional function that accepts a component
    of type T and returns a Bool. Apply this function to each component and only return components
    where the result is true.
"""
function get_supplemental_attributes(
    ::Type{T},
    component::InfrastructureSystemsComponent,
) where {T <: SupplementalAttribute}
    return _get_supplemental_attributes(T, component)
end

function get_supplemental_attributes(component::InfrastructureSystemsComponent)
    return _get_supplemental_attributes(SupplementalAttribute, component)
end

function _get_supplemental_attributes(
    supplemental_attribute_type::Type{<:SupplementalAttribute},
    component::InfrastructureSystemsComponent,
)
    mgr = _get_supplemental_attributes_manager(component)
    isnothing(mgr) && return supplemental_attribute_type[]
    return supplemental_attribute_type[
        get_supplemental_attribute(mgr, x) for
        x in list_associated_supplemental_attribute_uuids(
            mgr.associations,
            component,
            supplemental_attribute_type,
        )
    ]
end

function get_supplemental_attributes(
    filter_func::Function,
    ::Type{T},
    component::InfrastructureSystemsComponent,
) where {T <: SupplementalAttribute}
    return _get_supplemental_attributes(filter_func, T, component)
end

function get_supplemental_attributes(
    filter_func::Function,
    component::InfrastructureSystemsComponent,
)
    return _get_supplemental_attributes(filter_func, SupplementalAttribute, component)
end

function _get_supplemental_attributes(
    filter_func::Function,
    supplemental_attribute_type::Type{<:SupplementalAttribute},
    component::InfrastructureSystemsComponent,
)
    mgr = _get_supplemental_attributes_manager(component)
    isnothing(mgr) && return [supplemental_attribute_type]
    attrs = Vector{supplemental_attribute_type}()
    for uuid in list_associated_supplemental_attribute_uuids(
        mgr.associations,
        component,
        supplemental_attribute_type,
    )
        attribute = get_supplemental_attribute(mgr, uuid)
        if filter_func(attribute)
            push!(attrs, attribute)
        end
    end

    return attrs
end

function get_supplemental_attribute(
    component::InfrastructureSystemsComponent,
    uuid::Base.UUID,
)
    mgr = _get_supplemental_attributes_manager(component)
    isnothing(mgr) &&
        error("$(summary(component)) does not have supplemental attributes")
    return get_supplemental_attribute(mgr, uuid)
end

function _get_supplemental_attributes_manager(component::InfrastructureSystemsComponent)
    !supports_supplemental_attributes(component) && return nothing
    isnothing(get_internal(component).shared_system_references) && return nothing
    return get_internal(component).shared_system_references.supplemental_attribute_manager
end

function _get_supplemental_attribute_associations(component::InfrastructureSystemsComponent)
    mgr = _get_supplemental_attributes_manager(component)
    isnothing(mgr) && return nothing
    return mgr.associations
end
