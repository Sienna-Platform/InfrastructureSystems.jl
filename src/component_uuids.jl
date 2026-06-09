# This is an abstraction of a Set in order to enable de-serialization of supplemental
# attributes.

"""
Set-like storage of component UUIDs attached to a [`SupplementalAttribute`](@ref).

Supplemental attribute subtypes include a `ComponentUUIDs` field so associations can be
tracked and serialized without storing full component references.
"""
struct ComponentUUIDs <: InfrastructureSystemsType
    uuids::Set{Base.UUID}

    function ComponentUUIDs(uuids = Set{Base.UUID}())
        new(uuids)
    end
end

Base.copy(x::ComponentUUIDs) = copy(x.uuids)
Base.delete!(x::ComponentUUIDs, uuid) = delete!(x.uuids, uuid)
Base.empty!(x::ComponentUUIDs) = empty!(x.uuids)
Base.filter!(f, x::ComponentUUIDs) = filter!(f, x.uuids)
Base.in(x, y::ComponentUUIDs) = in(x, y.uuids)
Base.isempty(x::ComponentUUIDs) = isempty(x.uuids)
Base.iterate(x::ComponentUUIDs, args...) = iterate(x.uuids, args...)
Base.length(x::ComponentUUIDs) = length(x.uuids)
Base.pop!(x::ComponentUUIDs) = pop!(x.uuids)
Base.pop!(x::ComponentUUIDs, y) = pop!(x.uuids, y)
Base.pop!(x::ComponentUUIDs, y, default) = pop!(x.uuids, y, default)
Base.push!(x::ComponentUUIDs, y) = push!(x.uuids, y)
Base.setdiff!(x::ComponentUUIDs, y::ComponentUUIDs) = setdiff!(x.uuids, y.uuids)
Base.sizehint!(x::ComponentUUIDs, newsz) = sizehint!(x.uuids, newsz)

function deserialize(::Type{ComponentUUIDs}, data::Dict)
    uuids = Set{Base.UUID}()
    for uuid in data["uuids"]
        push!(uuids, deserialize(Base.UUID, uuid))
    end
    return ComponentUUIDs(uuids)
end
