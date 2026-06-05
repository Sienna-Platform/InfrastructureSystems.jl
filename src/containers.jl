"""
Parent abstract type for top-level containers stored in a [`SystemData`](@ref) instance.

Concrete subtypes include [`ComponentContainer`](@ref) (for components) and
[`SupplementalAttributeManager`](@ref) (for supplemental attributes). Containers expose
their members through package-specific query methods rather than direct field access.
"""
abstract type InfrastructureSystemsContainer <: InfrastructureSystemsType end

get_display_string(x::InfrastructureSystemsContainer) = string(nameof(typeof(x)))

"""
Iterates over all data in the container.
"""
function iterate_container(container::InfrastructureSystemsContainer)
    return (y for x in values(container.data) for y in values(x))
end

function get_num_members(container::InfrastructureSystemsContainer)
    return mapreduce(length, +, values(container.data); init = 0)
end
