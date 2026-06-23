"""
Assign a new integer ID to the component, drawn from the system counter, and update any
references to its old ID in the time series store, supplemental attribute associations, and
subsystem membership sets.
"""
function assign_new_id_internal!(data, component::InfrastructureSystemsComponent)
    old_id = get_id(component)
    new_id = get_next_component_id!(data)
    mgr = get_time_series_manager(component)
    if !isnothing(mgr)
        _rust_replace_component_id!(mgr.data_store, old_id, new_id)
    end

    associations = _get_supplemental_attribute_associations(component)
    if !isnothing(associations)
        replace_component_id!(associations, old_id, new_id)
    end

    for ids in values(data.subsystems)
        if old_id in ids
            pop!(ids, old_id)
            push!(ids, new_id)
        end
    end

    set_id!(get_internal(component), new_id)
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
    for id in list_associated_supplemental_attribute_ids(mgr.associations, component)
        attribute = get_supplemental_attribute(mgr, id)
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
        x in list_associated_supplemental_attribute_ids(
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
    for id in list_associated_supplemental_attribute_ids(
        mgr.associations,
        component,
        supplemental_attribute_type,
    )
        attribute = get_supplemental_attribute(mgr, id)
        if filter_func(attribute)
            push!(attrs, attribute)
        end
    end

    return attrs
end

function get_supplemental_attribute(
    component::InfrastructureSystemsComponent,
    id::Int,
)
    mgr = _get_supplemental_attributes_manager(component)
    isnothing(mgr) &&
        error("$(summary(component)) does not have supplemental attributes")
    return get_supplemental_attribute(mgr, id)
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
