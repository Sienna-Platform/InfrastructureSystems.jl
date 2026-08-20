# Design note:
# Supplemental attribute associations live in InfraStore, in its
# `supplemental_attribute_associations` table, alongside the time series catalog. They
# used to be kept in a separate in-memory SQLite database owned by this package and
# serialized into the system JSON; both are gone.
#
# Consequences worth knowing:
#   - Associations are persisted by the store's `<path>.h5` / `<path>.sqlite` pair, so a
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

This is the adapter over the InfraStore store: it keeps InfrastructureSystems' dispatch-based
API — the `Type`-taking overloads, and the expansion of an abstract type into the
concrete subtype names the store filters on — and forwards everything else.

Abstract-type expansion deliberately stays on this side. The store filters on lists of
concrete type-name strings and knows nothing about the Julia type hierarchy, so
`get_all_subtype_names` is applied here before any query is issued.
"""
struct SupplementalAttributeAssociations
    store::Store
    # Deferred-insert buffer for `begin_association_batch`. Empty and inactive otherwise;
    # `pending_pairs` mirrors `pending` so the duplicate probe stays O(1) without re-scanning.
    pending::Vector{InfraStore.SupplementalAttributeAssociation}
    pending_pairs::Set{Tuple{Int, Int}}
    deferring::Base.RefValue{Bool}
end

SupplementalAttributeAssociations(store::Store) = SupplementalAttributeAssociations(
    store,
    InfraStore.SupplementalAttributeAssociation[],
    Set{Tuple{Int, Int}}(),
    Ref(false),
)

# The store handle the queries below run against.
_assoc_store(associations::SupplementalAttributeAssociations) = associations.store.inner

# Render a type filter the way the store wants it: a vector of concrete type names, or
# `nothing` for "no filter". An abstract type with no concrete subtypes yields an empty
# vector, which the store treats as "match nothing" — the same answer the old
# `IN ()`-avoiding special case produced.
#
# The two ROOT abstract types are answered with "no filter" rather than by expansion. Every
# stored row matches them by definition, so the filter would be a no-op — but building it
# means an `InteractiveUtils.subtypes` walk of the whole hierarchy plus a fresh
# `Vector{String}` on EVERY call, and these are exactly the shapes the per-component
# accessors use (`get_supplemental_attributes(component)` passes `SupplementalAttribute`).
# Callers that need every row at once should use `list_supplemental_attribute_association_rows`
# instead of one query per component.
_type_names(::Nothing) = nothing
_type_names(::Type{SupplementalAttribute}) = nothing
_type_names(::Type{InfrastructureSystemsComponent}) = nothing
function _type_names(type::Type{<:InfrastructureSystemsType})
    isabstracttype(type) && return get_all_subtype_names(type)
    return [string(nameof(type))]
end

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

    row = InfraStore.SupplementalAttributeAssociation(
        component_id,
        string(nameof(typeof(component))),
        attribute_id,
        string(nameof(typeof(attribute))),
    )
    if associations.deferring[]
        push!(associations.pending, row)
        push!(associations.pending_pairs, (component_id, attribute_id))
        return
    end
    InfraStore.add_supplemental_attribute_association!(_assoc_store(associations), row)
    return
end

"""
Defer association inserts until `func` returns, then write them all in one store call.

Attaching an attribute normally costs two store round trips: a [`has_association`](@ref)
probe so the caller can raise a domain-specific error, and the insert itself. Replaying a
document's whole association table pays that per row. Inside this block the probe reads the
pending buffer as well as the store, and every buffered row lands in a single
`add_supplemental_attribute_associations!`.

WRITE-ONLY while open: counts, listings, and comparisons
([`get_num_associations`](@ref), [`_association_rows`](@ref), …) read the store alone and do
not see buffered rows. Nor do ordinary component-level queries —
[`get_supplemental_attributes`](@ref), `has_supplemental_attributes`,
[`list_associated_supplemental_attribute_ids`](@ref), and every [`has_association`](@ref)
shape OTHER than the exact `(component, attribute)` pair — they too read the store alone and
will not see rows buffered in an open batch. Only the `(component, attribute)` pair overload
of `has_association` also checks the pending buffer, because it is the probe
`add_supplemental_attribute!` calls before every attach.

If `func` throws, this store-only form drops the buffer without writing it — no rollback is
needed here because nothing was ever written. That is NOT the same as leaving no trace: by
the time a duplicate-pair throw reaches here, `add_supplemental_attribute!` has already
attached the attribute to the manager's `mgr.data` (attaching happens before the association
is buffered), so calling this form directly on a `SupplementalAttributeAssociations` can leave
an orphaned, attached-but-unassociated attribute behind. Callers that need the manager rolled
back too — which is almost always what's wanted — should use the `SystemData`-level
[`begin_association_batch`](@ref), which wraps this one inside
[`begin_supplemental_attributes_update`](@ref) for exactly that reason.

Not reentrant: a nested call errors rather than silently flattening two scopes into one.
"""
function begin_association_batch(
    func::Function,
    associations::SupplementalAttributeAssociations,
)
    associations.deferring[] && error(
        "begin_association_batch: already inside a batch; nesting is not supported",
    )
    associations.deferring[] = true
    try
        func()
        isempty(associations.pending) && return
        InfraStore.add_supplemental_attribute_associations!(
            _assoc_store(associations), associations.pending,
        )
    finally
        associations.deferring[] = false
        empty!(associations.pending)
        empty!(associations.pending_pairs)
    end
    return
end

"""
Return a `Vector{OrderedDict}` of attribute counts by type, with keys `"type"` and
`"count"`.
"""
function get_attribute_counts_by_type(associations::SupplementalAttributeAssociations)
    return [
        OrderedDict{String, Any}("type" => row.attribute_type, "count" => row.count)
        for
        row in InfraStore.supplemental_attribute_counts_by_type(_assoc_store(associations))
    ]
end

"""
Return a `DataFrame` of association counts by attribute type and component type.
"""
function get_attribute_summary_table(associations::SupplementalAttributeAssociations)
    rows = InfraStore.supplemental_attribute_summary(_assoc_store(associations))
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
    InfraStore.count_supplemental_attributes(_assoc_store(associations))

"""
Return the number of distinct components with supplemental attributes.
"""
get_num_components_with_attributes(associations::SupplementalAttributeAssociations) =
    InfraStore.count_components_with_attributes(_assoc_store(associations))

# Each query below selects rows by some mix of a component, an attribute, and
# their types; every such argument maps to exactly one store filter keyword, so
# the queries just splat whatever they were given. `nothing` contributes no
# filter, which is how the optional type arguments stay optional.
_assoc_filters(::Nothing) = ()
_assoc_filters(component::InfrastructureSystemsComponent) =
    (:component_id => get_id(component),)
_assoc_filters(attribute::SupplementalAttribute) = (:attribute_id => get_id(attribute),)
_assoc_filters(component_type::Type{<:InfrastructureSystemsComponent}) =
    (:component_types => _type_names(component_type),)
_assoc_filters(attribute_type::Type{<:SupplementalAttribute}) =
    (:attribute_types => _type_names(attribute_type),)

# The store filter keywords implied by a query's positional arguments.
_assoc_query(args...) = (p for arg in args for p in _assoc_filters(arg))

"""
Return true if there is at least one association matching the arguments: a component,
an attribute, both, or a component together with an attribute type (which may be
abstract).

Reads the store alone. Inside an open [`begin_association_batch`](@ref) this does NOT see
rows buffered but not yet flushed — only the exact `(component, attribute)` pair overload,
below, checks the pending buffer too.
"""
has_association(associations::SupplementalAttributeAssociations, args...) =
    InfraStore.has_supplemental_attribute_association(
        _assoc_store(associations); _assoc_query(args...)...)

"""
The exact `(component, attribute)` probe, which also sees rows buffered by
[`begin_association_batch`](@ref).

This is the shape `add_supplemental_attribute!` calls before every attach, and the only one
a batch has to answer correctly: without it a document naming the same pair twice would be
buffered twice and only rejected at flush, by the store, without naming the objects.
"""
function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    pair = (get_id(component), get_id(attribute))
    associations.deferring[] && pair in associations.pending_pairs && return true
    return InfraStore.has_supplemental_attribute_association(
        _assoc_store(associations);
        component_id = pair[1],
        attribute_id = pair[2],
    )
end

"""
Return the IDs of components associated with the given attribute or attribute type,
optionally restricted to a component type. Both types may be abstract.
"""
list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute::Union{SupplementalAttribute, Type{<:SupplementalAttribute}},
    component_type::Union{Nothing, Type{<:InfrastructureSystemsComponent}},
) = InfraStore.list_components_with_attributes(
    _assoc_store(associations); _assoc_query(attribute, component_type)...)

"""
Return the IDs of supplemental attributes associated with the given component or
component type, optionally restricted to an attribute type. Both types may be abstract.
"""
list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component::Union{
        InfrastructureSystemsComponent, Type{<:InfrastructureSystemsComponent},
    },
    attribute_type::Union{Nothing, Type{<:SupplementalAttribute}} = nothing,
) = InfraStore.list_supplemental_attribute_ids(
    _assoc_store(associations); _assoc_query(component, attribute_type)...)

"""
Return the `(component_id, attribute_id)` pairs for the given attribute and component
types. Both types may be abstract.
"""
function list_associated_pair_ids(
    associations::SupplementalAttributeAssociations,
    attribute_type::Type{<:SupplementalAttribute},
    component_type::Type{<:InfrastructureSystemsComponent},
)
    rows = InfraStore.list_supplemental_attribute_associations(
        _assoc_store(associations);
        _assoc_query(attribute_type, component_type)...,
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
    num_deleted = InfraStore.remove_supplemental_attribute_associations!(
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
    num_deleted = InfraStore.remove_supplemental_attribute_associations!(
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
    InfraStore.replace_supplemental_attribute_component_id!(
        _assoc_store(associations),
        old_id,
        new_id,
    )
    return
end

"""
The raw store rows. Used for the rollback snapshot and for comparison; callers that
just want a count should use [`get_num_associations`](@ref).
"""
_association_rows(associations::SupplementalAttributeAssociations) =
    InfraStore.list_supplemental_attribute_associations(_assoc_store(associations))

"""
Return the total number of association rows.

Distinct from [`get_num_attributes`](@ref), which counts distinct attributes: one
attribute attached to three components is one attribute but three rows.
"""
get_num_associations(associations::SupplementalAttributeAssociations) =
    InfraStore.count_supplemental_attribute_associations(_assoc_store(associations))

"""
Replace every association row with `rows`.

This is the rollback primitive for [`begin_supplemental_attributes_update`](@ref): a failed
update restores the rows captured on entry. Unlike undoing only the newly added rows, this
also puts back rows the update removed.

The clear and the re-add run inside one `InfraStore.transaction`, so a failure partway
through — the re-add throwing, say — cannot leave the store cleared with nothing put back.
`InfraStore.transaction` nests (only the outermost commit/rollback is real), so this is safe
even called from inside another open transaction, and it preserves the error that caused the
rollback rather than replacing it with one about the rollback itself.
"""
function restore_associations!(
    associations::SupplementalAttributeAssociations,
    rows::AbstractVector,
)
    InfraStore.transaction(_assoc_store(associations)) do
        clear_associations!(associations)
        isempty(rows) && return
        InfraStore.add_supplemental_attribute_associations!(
            _assoc_store(associations),
            rows,
        )
    end
    return
end

"""
Copy every association row from `src` into `dst`.
"""
function copy_associations!(
    dst::SupplementalAttributeAssociations,
    src::SupplementalAttributeAssociations,
)
    rows = InfraStore.list_supplemental_attribute_associations(_assoc_store(src))
    isempty(rows) && return
    InfraStore.add_supplemental_attribute_associations!(_assoc_store(dst), rows)
    return
end

"""
Remove every association row.
"""
function clear_associations!(associations::SupplementalAttributeAssociations)
    InfraStore.remove_supplemental_attribute_associations!(_assoc_store(associations))
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
