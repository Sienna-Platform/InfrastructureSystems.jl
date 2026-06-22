# This is an abstraction of a Set in order to enable de-serialization of supplemental
# attributes.

"""
Set-like storage of component integer ids attached to a [`SupplementalAttribute`](@ref).

Supplemental attribute subtypes include a `ComponentIDs` field so associations can be
tracked and serialized without storing full component references.
"""
struct ComponentIDs <: InfrastructureSystemsType
    ids::Set{Int}

    function ComponentIDs(ids = Set{Int}())
        new(ids)
    end
end

Base.copy(x::ComponentIDs) = copy(x.ids)
Base.delete!(x::ComponentIDs, id) = delete!(x.ids, id)
Base.empty!(x::ComponentIDs) = empty!(x.ids)
Base.filter!(f, x::ComponentIDs) = filter!(f, x.ids)
Base.in(x, y::ComponentIDs) = in(x, y.ids)
Base.isempty(x::ComponentIDs) = isempty(x.ids)
Base.iterate(x::ComponentIDs, args...) = iterate(x.ids, args...)
Base.length(x::ComponentIDs) = length(x.ids)
Base.pop!(x::ComponentIDs) = pop!(x.ids)
Base.pop!(x::ComponentIDs, y) = pop!(x.ids, y)
Base.pop!(x::ComponentIDs, y, default) = pop!(x.ids, y, default)
Base.push!(x::ComponentIDs, y) = push!(x.ids, y)
Base.setdiff!(x::ComponentIDs, y::ComponentIDs) = setdiff!(x.ids, y.ids)
Base.sizehint!(x::ComponentIDs, newsz) = sizehint!(x.ids, newsz)

function deserialize(::Type{ComponentIDs}, data::Dict)
    ids = Set{Int}()
    for id in data["ids"]
        push!(ids, Int(id))
    end
    return ComponentIDs(ids)
end
