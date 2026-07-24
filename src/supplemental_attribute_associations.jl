# Design note:
# Supplemental attribute associations live in Castore, in its
# `supplemental_attribute_associations` table, alongside the time series catalog. They
# used to be kept in a separate in-memory SQLite database owned by this package and
# serialized into the system JSON; both are gone.
#
# Consequences worth knowing:
#   - Associations are persisted by the store's `<path>.nc` / `<path>.sqlite` pair, so a
#     system with supplemental attributes but no time series now produces a storage
#     artifact where it previously produced none. `isempty(::Store)`
#     accounts for association rows so `serialize` writes that artifact.
#   - The store enforces uniqueness on the `(component_id, attribute_id)` pair. The old
#     table had no constraint and relied on callers checking first; callers still check,
#     so the error message can name the objects, but a missed check is now caught.
#   - There is no reader for the `associations` key older system JSON carries. A system
#     serialized before this change does not load, matching the equivalent break in
#     ../infrasys; regenerate it with a build from before the move if you need the data.

"""
Tracks which supplemental attributes are attached to which components.

This is the adapter over the Castore store: it keeps InfrastructureSystems' dispatch-based
API — the `Type`-taking overloads, and the expansion of an abstract type into the
concrete subtype names the store filters on — and forwards everything else.

Abstract-type expansion deliberately stays on this side. The store filters on lists of
concrete type-name strings and knows nothing about the Julia type hierarchy, so
`get_all_subtype_names` is applied here before any query is issued.
"""
struct SupplementalAttributeAssociations
    store::Store
end

# The store handle the queries below run against.
_assoc_store(associations::SupplementalAttributeAssociations) = associations.store.inner

# Render a type filter the way the store wants it: a vector of concrete type names, or
# `nothing` for "no filter". An abstract type with no concrete subtypes yields an empty
# vector, which the store treats as "match nothing" — the same answer the old
# `IN ()`-avoiding special case produced.
_type_names(::Nothing) = nothing
_type_names(type::Type{<:InfrastructureSystemsType}) =
    isabstracttype(type) ? get_all_subtype_names(type) : [string(nameof(type))]

"""
Add an association between a component and a supplemental attribute.

Throws `ArgumentError` if either object has an unassigned ID. The store rejects a repeat
of the same `(component_id, attribute_id)` pair; callers wanting a domain-specific
message check [`has_association`](@ref) first.
"""
function add_association!(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    component_id = get_id(component)
    attribute_id = get_id(attribute)
    if component_id == UNASSIGNED_ID
        throw(ArgumentError("$(summary(component)) does not have an ID assigned"))
    end
    if attribute_id == UNASSIGNED_ID
        throw(ArgumentError("$(summary(attribute)) does not have an ID assigned"))
    end

    Castore.add_supplemental_attribute_association!(
        _assoc_store(associations),
        Castore.SupplementalAttributeAssociation(
            component_id,
            string(nameof(typeof(component))),
            attribute_id,
            string(nameof(typeof(attribute))),
        ),
    )
    return
end

"""
Return a `Vector{OrderedDict}` of attribute counts by type, with keys `"type"` and
`"count"`.
"""
function get_attribute_counts_by_type(associations::SupplementalAttributeAssociations)
    return [
        OrderedDict{String, Any}("type" => row.type, "count" => row.count)
        for row in Castore.supplemental_attribute_counts_by_type(_assoc_store(associations))
    ]
end

"""
Return a `DataFrame` of association counts by attribute type and component type.
"""
function get_attribute_summary_table(associations::SupplementalAttributeAssociations)
    rows = Castore.supplemental_attribute_summary(_assoc_store(associations))
    return DataFrame(;
        attribute_type = [r.attribute_type for r in rows],
        component_type = [r.component_type for r in rows],
        count = [r.count for r in rows],
    )
end

"""
Return the number of distinct supplemental attributes with associations.
"""
get_num_attributes(associations::SupplementalAttributeAssociations) =
    Castore.count_supplemental_attributes(_assoc_store(associations))

"""
Return the number of distinct components with supplemental attributes.
"""
get_num_components_with_attributes(associations::SupplementalAttributeAssociations) =
    Castore.count_components_with_attributes(_assoc_store(associations))

"""
Return true if there is at least one association matching the arguments.
"""
function has_association(
    associations::SupplementalAttributeAssociations,
    attribute::SupplementalAttribute,
)
    return Castore.has_supplemental_attribute_association(
        _assoc_store(associations);
        attribute_id = get_id(attribute),
    )
end

function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    return Castore.has_supplemental_attribute_association(
        _assoc_store(associations);
        component_id = get_id(component),
        attribute_id = get_id(attribute),
    )
end

function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
)
    return Castore.has_supplemental_attribute_association(
        _assoc_store(associations);
        component_id = get_id(component),
    )
end

function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute_type::Type{<:SupplementalAttribute},
)
    return Castore.has_supplemental_attribute_association(
        _assoc_store(associations);
        component_id = get_id(component),
        attribute_types = _type_names(attribute_type),
    )
end

"""
Return the IDs of components associated with the given attribute or attribute type,
optionally restricted to a component type. Both types may be abstract.
"""
function list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute::SupplementalAttribute,
    component_type::Union{Nothing, Type{<:InfrastructureSystemsComponent}},
)
    return Castore.list_components_with_attributes(
        _assoc_store(associations);
        attribute_id = get_id(attribute),
        component_types = _type_names(component_type),
    )
end

function list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute_type::Type{<:SupplementalAttribute},
    component_type::Union{Nothing, Type{<:InfrastructureSystemsComponent}},
)
    return Castore.list_components_with_attributes(
        _assoc_store(associations);
        attribute_types = _type_names(attribute_type),
        component_types = _type_names(component_type),
    )
end

"""
Return the IDs of supplemental attributes associated with the given component or
component type, optionally restricted to an attribute type. Both types may be abstract.
"""
function list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute_type::Union{Nothing, Type{<:SupplementalAttribute}},
)
    return Castore.list_supplemental_attribute_ids(
        _assoc_store(associations);
        component_id = get_id(component),
        attribute_types = _type_names(attribute_type),
    )
end

list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
) = list_associated_supplemental_attribute_ids(associations, component, nothing)

function list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component_type::Type{<:InfrastructureSystemsComponent},
    attribute_type::Union{Nothing, Type{<:SupplementalAttribute}},
)
    return Castore.list_supplemental_attribute_ids(
        _assoc_store(associations);
        component_types = _type_names(component_type),
        attribute_types = _type_names(attribute_type),
    )
end

"""
Return the `(component_id, attribute_id)` pairs for the given attribute and component
types. Both types may be abstract.
"""
function list_associated_pair_ids(
    associations::SupplementalAttributeAssociations,
    attribute_type::Type{<:SupplementalAttribute},
    component_type::Type{<:InfrastructureSystemsComponent},
)
    rows = Castore.list_supplemental_attribute_associations(
        _assoc_store(associations);
        attribute_types = _type_names(attribute_type),
        component_types = _type_names(component_type),
    )
    return [(row.component_id, row.attribute_id) for row in rows]
end

"""
Remove the association between one component and one supplemental attribute.
"""
function remove_association!(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    num_deleted = Castore.remove_supplemental_attribute_associations!(
        _assoc_store(associations);
        component_id = get_id(component),
        attribute_id = get_id(attribute),
    )
    if num_deleted != 1
        error("Bug: unexpected number of deletions: $num_deleted")
    end
    return
end

"""
Remove all associations of the given supplemental attribute type. The type may be
abstract.
"""
function remove_associations!(
    associations::SupplementalAttributeAssociations,
    type::Type{<:SupplementalAttribute},
)
    num_deleted = Castore.remove_supplemental_attribute_associations!(
        _assoc_store(associations);
        attribute_types = _type_names(type),
    )
    @debug "Deleted $num_deleted supplemental attribute associations" _group =
        LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    return
end

"""
Replace all occurrences of `old_id` in the component column with `new_id`.
"""
function replace_component_id!(
    associations::SupplementalAttributeAssociations,
    old_id::Int,
    new_id::Int,
)
    Castore.replace_supplemental_attribute_component_id!(
        _assoc_store(associations),
        old_id,
        new_id,
    )
    return
end

# The raw store rows. Used for the rollback snapshot and for comparison; callers that
# just want a count should use `get_num_associations`.
_association_rows(associations::SupplementalAttributeAssociations) =
    Castore.list_supplemental_attribute_associations(_assoc_store(associations))

"""
Return the total number of association rows.

Distinct from [`get_num_attributes`](@ref), which counts distinct attributes: one
attribute attached to three components is one attribute but three rows.
"""
get_num_associations(associations::SupplementalAttributeAssociations) =
    Castore.count_supplemental_attribute_associations(_assoc_store(associations))

"""
Replace every association row with `rows`.

This is the rollback primitive for [`begin_supplemental_attributes_update`](@ref): the
store has no transaction, so a failed update restores the rows captured on entry.
Unlike undoing only the newly added rows, this also puts back rows the update removed.
"""
function restore_associations!(
    associations::SupplementalAttributeAssociations,
    rows::AbstractVector,
)
    clear_associations!(associations)
    isempty(rows) && return
    Castore.add_supplemental_attribute_associations!(_assoc_store(associations), rows)
    return
end

"""
Copy every association row from `src` into `dst`.
"""
function copy_associations!(
    dst::SupplementalAttributeAssociations,
    src::SupplementalAttributeAssociations,
)
    rows = Castore.list_supplemental_attribute_associations(_assoc_store(src))
    isempty(rows) && return
    Castore.add_supplemental_attribute_associations!(_assoc_store(dst), rows)
    return
end

"""
Remove every association row.
"""
function clear_associations!(associations::SupplementalAttributeAssociations)
    Castore.remove_supplemental_attribute_associations!(_assoc_store(associations))
    return
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::SupplementalAttributeAssociations,
    y::SupplementalAttributeAssociations;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    !compare_uuids && return true
    sort_key = row -> (row.attribute_id, row.component_id)
    table_x = sort(_association_rows(x); by = sort_key)
    table_y = sort(_association_rows(y); by = sort_key)
    match_fn = _fetch_match_fn(match_fn)
    return match_fn(table_x, table_y)
end
