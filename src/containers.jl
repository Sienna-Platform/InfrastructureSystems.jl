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

"""
Return the internal dict mapping each stored type to its member dict.
Use this in the owning file and in display utilities; do not add new callers elsewhere.
"""
function get_members_by_type(container::InfrastructureSystemsContainer)
    return container.data
end
