const SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME = "supplemental_attributes"

# Design note:
# Supplemental attributes and time series are stored in independent SQLite databases.
# Ideally, they would be different tables in the same database. This is not practical
# because of requirements set by the team for serialization output files.
#
# Background:
#   - Time series metadata is always persisted as a SQLite file during serialization.
#   - That SQLite file is written as an HDF5 dataset in the time series data file.
#   - The result of serialization is system.json, system_metadata.json, and
#     system_time_series.h5.
#   - If there is no time series in the system, then there is no extra file: only
#     system.json and system_metadata.json.
#
# If we persist supplemental attribute associations to a SQLite file and there is no time
# series, serialization would produce an extra file. The team was strongly opposed to this
# and set a requirement that those associations must be written to the system JSON file.
#
# Rather than try to manage the complexities of temporarily sharing a database across
# serialization and deepcopy operations, this design keeps them separate in order to
# simplifiy the code. The supplemental attribute database is always ephemeral.

mutable struct SupplementalAttributeAssociations
    db::SQLite.DB
    # If we don't cache SQL statements, there is a cost of 3-4 us on every query.
    cached_statements::Dict{String, SQLite.Stmt}
    # If you add any fields, ensure they are managed in deepcopy_internal below.
end

"""
SQLite-backed store linking [`SupplementalAttribute`](@ref)s to
[`InfrastructureSystemsComponent`](@ref)s.

Owned by [`SupplementalAttributeManager`](@ref). Associations are serialized into the
system JSON file rather than a separate sidecar database.

See also: [`add_supplemental_attribute!`](@ref), [`list_associated_component_ids`](@ref)
"""
SupplementalAttributeAssociations

"""
Construct a new SupplementalAttributeAssociations with an in-memory database.
"""
function SupplementalAttributeAssociations(; create_indexes = true)
    associations =
        SupplementalAttributeAssociations(SQLite.DB(), Dict{String, SQLite.Stmt}())
    _create_attribute_associations_table!(associations)
    if create_indexes
        _create_indexes!(associations)
    end
    @debug "Initialized new supplemental attributes association table" _group =
        LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    return associations
end

function _create_attribute_associations_table!(
    associations::SupplementalAttributeAssociations,
)
    schema = [
        "attribute_id INTEGER NOT NULL",
        "attribute_type TEXT NOT NULL",
        "component_id INTEGER NOT NULL",
        "component_type TEXT NOT NULL",
    ]
    schema_text = join(schema, ",")
    _execute(
        associations,
        "CREATE TABLE $(SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME)($(schema_text))",
    )
    @debug "Created supplemental attribute association table" schema _group =
        LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    return
end

function _create_indexes!(associations::SupplementalAttributeAssociations)
    SQLite.createindex!(
        associations.db,
        SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        "by_attribute",
        [
            "attribute_id",
            "component_id",
            "component_type",
        ];
        unique = false,
    )
    SQLite.createindex!(
        associations.db,
        SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        "by_component",
        [
            "component_id",
            "attribute_id",
            "attribute_type",
        ];
        unique = false,
    )

    optimize_database!(associations)
    return
end

function Base.deepcopy_internal(val::SupplementalAttributeAssociations, dict::IdDict)
    if haskey(dict, val)
        return dict[val]
    end
    new_db = SQLite.DB()
    backup(new_db, val.db)
    new_associations =
        SupplementalAttributeAssociations(new_db, Dict{String, SQLite.Stmt}())
    dict[val] = new_associations
    return new_associations
end

const _QUERY_INSERT_C_ATTR_ASSOCIATION = StringTemplates.@template """
    INSERT INTO $table_name
    VALUES($placeholder)
"""

"""
Add a supplemental attribute association to the associations. The caller must check for
duplicates.
"""
function add_association!(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "add supplemental attribute association" begin
        attribute_id = get_id(attribute)
        component_id = get_id(component)
        if attribute_id == UNASSIGNED_ID || component_id == UNASSIGNED_ID
            throw(
                ArgumentError(
                    "cannot associate $(summary(attribute)) with $(summary(component)): " *
                    "both must have assigned IDs (attach them to `SystemData` first).",
                ),
            )
        end
        row = (
            attribute_id,
            string(nameof(typeof(attribute))),
            component_id,
            string(nameof(typeof(component))),
        )
        placeholder = chop(repeat("?,", length(row)))
        _execute_cached(
            associations,
            StringTemplates.render(
                _QUERY_INSERT_C_ATTR_ASSOCIATION;
                table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
                placeholder = placeholder,
            ),
            row,
        )
        @debug "Added association bewteen $(summary(attribute)) and $(summary(component))"
        LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    end
    return
end

const _QUERY_DROP_ATTR_TABLE = "DROP TABLE IF EXISTS $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME"

const _QUERY_GET_ATTRIBUTE_COUNTS_BY_TYPE = """
    SELECT
        attribute_type
        ,count(*) AS count
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    GROUP BY
        attribute_type
    ORDER BY
        attribute_type
"""

"""
Return a Vector of OrderedDict of stored time series counts by type.
"""
function get_attribute_counts_by_type(associations::SupplementalAttributeAssociations)
    table = Tables.rowtable(_execute(associations, _QUERY_GET_ATTRIBUTE_COUNTS_BY_TYPE))
    return [
        OrderedDict("type" => x.attribute_type, "count" => x.count) for x in table
    ]
end

const _QUERY_GET_ATTRIBUTE_SUMMARY_TABLE = """
    SELECT
        attribute_type
        ,component_type
        ,count(*) AS count
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    GROUP BY
        attribute_type
        ,component_type
    ORDER BY
        attribute_type
        ,component_type
"""

"""
Return a DataFrame with the number of supplemental attributes by type for components.
"""
function get_attribute_summary_table(associations::SupplementalAttributeAssociations)
    return DataFrame(_execute(associations, _QUERY_GET_ATTRIBUTE_SUMMARY_TABLE))
end

const _QUERY_GET_NUM_ATTRIBUTES = """
    SELECT COUNT(DISTINCT attribute_id) AS count
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
"""

"""
Return the number of supplemental attributes.
"""
function get_num_attributes(associations::SupplementalAttributeAssociations)
    return _execute_count(associations, _QUERY_GET_NUM_ATTRIBUTES)
end

const _QUERY_GET_NUM_COMPONENTS_WITH_ATTRIBUTES = """
    SELECT COUNT(DISTINCT component_id) AS count
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
"""

"""
Return the number of components with supplemental attributes.
"""
function get_num_components_with_attributes(associations::SupplementalAttributeAssociations)
    return _execute_count(associations, _QUERY_GET_NUM_COMPONENTS_WITH_ATTRIBUTES)
end

"""
Update database statistics for optimal query planning.
Call this after bulk operations or significant data changes.
"""
function optimize_database!(associations::SupplementalAttributeAssociations)
    # Run ANALYZE to update query planner statistics
    SQLite.DBInterface.execute(associations.db, "ANALYZE")
    @debug "Optimized database statistics" _group = LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    return
end

const _QUERY_HAS_ASSOCIATION_BY_ATTRIBUTE = """
    SELECT attribute_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE attribute_id = ?
    LIMIT 1
"""

"""
Return true if there is at least one association matching the inputs.
"""
function has_association(
    associations::SupplementalAttributeAssociations,
    attribute::SupplementalAttribute,
)
    # Note: Unlike the other has_association methods, this is not covered by an index.
    params = (get_id(attribute),)
    return !isempty(
        Tables.rowtable(
            _execute_cached(associations, _QUERY_HAS_ASSOCIATION_BY_ATTRIBUTE, params),
        ),
    )
end

const _QUERY_HAS_ASSOCIATION_BY_COMPONENT_ATTRIBUTE = """
    SELECT attribute_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE attribute_id = ? AND component_id = ?
    LIMIT 1
"""
function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    params = (get_id(attribute), get_id(component))
    return !isempty(
        _execute_cached(
            associations,
            _QUERY_HAS_ASSOCIATION_BY_COMPONENT_ATTRIBUTE,
            params,
        ),
    )
end

const _QUERY_HAS_ASSOCIATION_BY_COMPONENT = """
    SELECT attribute_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE component_id = ?
    LIMIT 1
"""
function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
)
    params = (get_id(component),)
    return !isempty(
        Tables.rowtable(
            _execute_cached(associations, _QUERY_HAS_ASSOCIATION_BY_COMPONENT, params),
        ),
    )
end

const _QUERY_HAS_ASSOCIATION_BY_COMP_ATTR_TYPE = """
    SELECT attribute_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE component_id = ? AND attribute_type = ?
    LIMIT 1
"""
function has_association(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute_type::Type{<:SupplementalAttribute},
)
    params = (get_id(component), string(nameof(attribute_type)))
    return !isempty(
        Tables.rowtable(
            _execute_cached(associations, _QUERY_HAS_ASSOCIATION_BY_COMP_ATTR_TYPE, params),
        ),
    )
end

# component ids from attribute
const _QUERY_LIST_ASSOCIATED_COMP_IDS = """
    SELECT DISTINCT component_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE attribute_id = ?
"""

"""
Return the distinct component ids associated with the attribute.
"""
function list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute::SupplementalAttribute,
    ::Nothing,
)
    params = (get_id(attribute),)
    table = Tables.columntable(
        _execute_cached(associations, _QUERY_LIST_ASSOCIATED_COMP_IDS, params),
    )
    return collect(Int, table.component_id)
end

# attribute ids from component
const _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS = """
    SELECT DISTINCT attribute_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE component_id = ?
"""

"""
Return the distinct attribute ids associated with the component.
"""
function list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    ::Nothing,
)
    params = (get_id(component),)
    table = Tables.columntable(
        _execute_cached(
            associations,
            _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS,
            params,
        ),
    )
    return collect(Int, table.attribute_id)
end

list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
) = list_associated_supplemental_attribute_ids(associations, component, nothing)

# component ids from attribute plus component type
const _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_C_TYPE = StringTemplates.@template """
    SELECT DISTINCT component_id
    FROM $table_name
    WHERE attribute_id = ? AND $component_type_clause
"""

"""
Return the distinct component ids associated with the attribute, filter by component type.
"""
function list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute::SupplementalAttribute,
    component_type::Type{<:InfrastructureSystemsComponent},
)
    params = Any[get_id(attribute)]
    component_type_clause = _get_type_clause!(params, component_type, "component_type")
    query = StringTemplates.render(
        _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_C_TYPE;
        table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        component_type_clause = component_type_clause,
    )
    table = Tables.columntable(
        _execute_cached(associations, query, params),
    )
    return collect(Int, table.component_id)
end

# attribute ids from component plus attribute type
const _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_A_TYPE =
    StringTemplates.@template """
    SELECT DISTINCT attribute_id
    FROM $table_name
    WHERE component_id = ? AND $attribute_type_clause
"""

"""
Return the distinct attribute ids associated with the component, filter by attribute type.
"""
function list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute_type::Type{<:SupplementalAttribute},
)
    params = Any[get_id(component)]
    attribute_type_clause = _get_type_clause!(params, attribute_type, "attribute_type")
    query = StringTemplates.render(
        _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_A_TYPE;
        table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        attribute_type_clause = attribute_type_clause,
    )
    table = Tables.columntable(
        _execute_cached(associations, query, params),
    )
    return collect(Int, table.attribute_id)
end

# component ids from attribute type driver function
"""
Return the distinct component ids associated with the attribute type.
"""
function list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute_type::Type{<:SupplementalAttribute},
    ::Nothing,
)
    if isconcretetype(attribute_type)
        return _list_associated_component_ids(associations, (attribute_type,))
    end

    subtypes = get_all_concrete_subtypes(attribute_type)
    return _list_associated_component_ids(associations, subtypes)
end

# attribute ids from component type driver function
"""
Return the distinct attribute ids associated with the component type.
"""
function list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component_type::Type{<:InfrastructureSystemsComponent},
    ::Nothing,
)
    if isconcretetype(component_type)
        return _list_associated_supplemental_attribute_ids(
            associations,
            (component_type,),
        )
    end

    subtypes = get_all_concrete_subtypes(component_type)
    return _list_associated_supplemental_attribute_ids(associations, subtypes)
end

# component ids from attribute type plus component type
const _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_TYPES = StringTemplates.@template """
    SELECT DISTINCT component_id
    FROM $table_name
    WHERE $attribute_type_clause AND $component_type_clause
"""

"""
Return the distinct component ids associated with the attribute type, filter by
component_type.
"""
function list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute_type::Type{<:SupplementalAttribute},
    component_type::Type{<:InfrastructureSystemsComponent},
)
    params = String[]
    attribute_type_clause = _get_type_clause!(params, attribute_type, "attribute_type")
    component_type_clause = _get_type_clause!(params, component_type, "component_type")
    query = StringTemplates.render(
        _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_TYPES;
        table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        attribute_type_clause = attribute_type_clause,
        component_type_clause = component_type_clause,
    )
    table = Tables.columntable(_execute_cached(associations, query, params))
    return collect(Int, table.component_id)
end

# attribute ids from attribute type plus component type
const _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_TYPES =
    StringTemplates.@template """
    SELECT DISTINCT attribute_id
    FROM $table_name
    WHERE $attribute_type_clause AND $component_type_clause
"""

"""
Return the distinct attribute ids associated with the component type, filter by
attribute_type.
"""
function list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component_type::Type{<:InfrastructureSystemsComponent},
    attribute_type::Type{<:SupplementalAttribute},
)
    params = String[]
    attribute_type_clause = _get_type_clause!(params, attribute_type, "attribute_type")
    component_type_clause = _get_type_clause!(params, component_type, "component_type")
    query = StringTemplates.render(
        _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_TYPES;
        table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        attribute_type_clause = attribute_type_clause,
        component_type_clause = component_type_clause,
    )
    table = Tables.columntable(_execute_cached(associations, query, params))
    return collect(Int, table.attribute_id)
end

const _QUERY_LIST_ASSOCIATED_PAIR_IDS = StringTemplates.@template """
    SELECT DISTINCT component_id, attribute_id
    FROM $table_name
    WHERE $component_type_clause AND $attribute_type_clause
"""

"""
Return the component and attribute ids that are associated with the given types.
"""
function list_associated_pair_ids(
    associations::SupplementalAttributeAssociations,
    attribute_type::Type{<:SupplementalAttribute},
    component_type::Type{<:InfrastructureSystemsComponent},
)
    params = String[]
    component_type_clause = _get_type_clause!(params, component_type, "component_type")
    attribute_type_clause = _get_type_clause!(params, attribute_type, "attribute_type")
    query = StringTemplates.render(
        _QUERY_LIST_ASSOCIATED_PAIR_IDS;
        table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
        component_type_clause = component_type_clause,
        attribute_type_clause = attribute_type_clause,
    )
    table = Tables.rowtable(_execute_cached(associations, query, params))
    return [(Int(row.component_id), Int(row.attribute_id)) for row in table]
end

function _get_type_clause!(
    params::Vector,
    type::Type{<:InfrastructureSystemsType},
    column::String,
)
    if isabstracttype(type)
        subtypes = [string(nameof(x)) for x in get_all_concrete_subtypes(type)]
        type_clause = if length(subtypes) == 1
            "$column = ?"
        else
            placeholder = chop(repeat("?,", length(subtypes)))
            "$column IN ($placeholder)"
        end
        for subtype in subtypes
            push!(params, subtype)
        end
    else
        type_clause = "$column = ?"
        push!(params, string(nameof(type)))
    end

    return type_clause
end

# component ids from attribute type implementation
const _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_ONE_TYPE = """
    SELECT DISTINCT component_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE attribute_type = ?
"""

const _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_MULTIPLE_TYPES = StringTemplates.@template """
    SELECT DISTINCT component_id
    FROM $table_name
    WHERE attribute_type IN ($placeholder)
"""

function _list_associated_component_ids(
    associations::SupplementalAttributeAssociations,
    attribute_types,
)
    len = length(attribute_types)
    if len == 0
        # This would require an abstract type with no subtypes. Just here for completeness.
        return Int[]
    elseif len == 1
        query = _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_ONE_TYPE
        params = (string(nameof(first(attribute_types))),)
    else
        placeholder = chop(repeat("?,", length(attribute_types)))
        params = Tuple(string(nameof(type)) for type in attribute_types)
        query = StringTemplates.render(
            _QUERY_LIST_ASSOCIATED_COMP_IDS_BY_MULTIPLE_TYPES;
            table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
            placeholder = placeholder,
        )
    end

    table = Tables.columntable(_execute_cached(associations, query, params))
    return collect(Int, table.component_id)
end

# attribute ids from component type implementation
const _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_ONE_TYPE = """
    SELECT DISTINCT attribute_id
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    WHERE component_type = ?
"""

const _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_MULTIPLE_TYPES =
    StringTemplates.@template """
    SELECT DISTINCT attribute_id
    FROM $table_name
    WHERE component_type IN ($placeholder)
"""

function _list_associated_supplemental_attribute_ids(
    associations::SupplementalAttributeAssociations,
    component_types,
)
    len = length(component_types)
    if len == 0
        # This would require an abstract type with no subtypes. Just here for completeness.
        return Int[]
    elseif len == 1
        query = _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_ONE_TYPE
        params = (string(nameof(first(component_types))),)
    else
        placeholder = chop(repeat("?,", length(component_types)))
        params = Tuple(string(nameof(type)) for type in component_types)
        query = StringTemplates.render(
            _QUERY_LIST_ASSOCIATED_SUPPLEMENTAL_ATTRIBUTE_IDS_BY_MULTIPLE_TYPES;
            table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
            placeholder = placeholder,
        )
    end

    table = Tables.columntable(_execute_cached(associations, query, params))
    return collect(Int, table.attribute_id)
end

"""
Remove the association between the attribute and component.
"""
function remove_association!(
    associations::SupplementalAttributeAssociations,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute,
)
    where_clause = "WHERE attribute_id = ? AND component_id = ?"
    params = (get_id(attribute), get_id(component))
    num_deleted = _remove_associations!(associations, where_clause, params)
    if num_deleted != 1
        error("Bug: unexpected number of deletions: $num_deleted. Should have been 1.")
    end
end

"""
Remove all associations of the given type.
"""
function remove_associations!(
    associations::SupplementalAttributeAssociations,
    type::Type{<:SupplementalAttribute},
)
    where_clause = "WHERE attribute_type = ?"
    params = (string(nameof(type)),)
    num_deleted = _remove_associations!(associations, where_clause, params)
    @debug "Deleted $num_deleted supplemental attribute associations" _group =
        LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    return
end

const _QUERY_REPLACE_COMP_ID_SA = """
    UPDATE $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
    SET component_id = ?
    WHERE component_id = ?
"""

"""
Replace the component id in the table.
"""
function replace_component_id!(
    associations::SupplementalAttributeAssociations,
    old_id::Int,
    new_id::Int,
)
    params = (new_id, old_id)
    _execute_cached(associations, _QUERY_REPLACE_COMP_ID_SA, params)
    return
end

"""
Run a query and return the results in a DataFrame.
"""
function sql(
    associations::SupplementalAttributeAssociations,
    query::String,
    params = nothing,
)
    return DataFrames.DataFrame(_execute(associations, query, params))
end

const _QUERY_TO_RECORDS = """
    SELECT *
    FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
"""
"""
Return all rows in the table as dictionaries.
"""
function to_records(associations::SupplementalAttributeAssociations)
    return Tables.rowtable(_execute(associations, _QUERY_TO_RECORDS))
end

const _QUERY_INSERT_ROWS_INTO_C_ATTR_TABLE = StringTemplates.@template """
    INSERT INTO $table_name
    VALUES($placeholder)
"""

# Records come either as string-keyed dictionaries (deserialized from JSON) or as
# NamedTuples (directly from `to_records`).
_record_value(record::AbstractDict, column::AbstractString) = record[column]
_record_value(record, column::AbstractString) = getproperty(record, Symbol(column))

"""
Add records to the database. Expects output from [`to_records`](@ref).
"""
function from_records(::Type{SupplementalAttributeAssociations}, records)
    associations = SupplementalAttributeAssociations(; create_indexes = false)
    isempty(records) && return associations

    columns = ("attribute_id", "attribute_type", "component_id", "component_type")
    num_columns = length(columns)
    data =
        OrderedDict(x => [_record_value(record, x) for record in records] for x in columns)
    placeholder = chop(repeat("?,", num_columns))

    # Note: executemany automatically wraps operations in a transaction for performance
    # No need for explicit BEGIN/COMMIT as SQLite.jl handles this internally
    SQLite.DBInterface.executemany(
        associations.db,
        StringTemplates.render(
            _QUERY_INSERT_ROWS_INTO_C_ATTR_TABLE;
            table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
            placeholder = placeholder,
        ),
        NamedTuple(Symbol(k) => v for (k, v) in data),
    )
    _create_indexes!(associations)
    return associations
end

const _QUERY_REMOVE_ASSOCIATIONS = StringTemplates.@template """
    DELETE FROM $table_name
    $where_clause
"""

const _QUERY_SELECT_CHANGES = "SELECT CHANGES() AS changes"

function _remove_associations!(
    associations::SupplementalAttributeAssociations,
    where_clause::AbstractString,
    params,
)
    _execute_cached(
        associations,
        StringTemplates.render(
            _QUERY_REMOVE_ASSOCIATIONS;
            table_name = SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME,
            where_clause = where_clause,
        ),
        params,
    )
    table = Tables.rowtable(_execute(associations, _QUERY_SELECT_CHANGES))
    @assert_op length(table) == 1
    @debug "Deleted $(table[1].changes) rows from the time series metadata table" _group =
        LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES
    return table[1].changes
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::SupplementalAttributeAssociations,
    y::SupplementalAttributeAssociations;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    !compare_uuids && return true
    query = """
        SELECT *
        FROM $SUPPLEMENTAL_ATTRIBUTE_TABLE_NAME
        ORDER BY attribute_id, component_id
    """
    table_x = Tables.rowtable(_execute(x, query))
    table_y = Tables.rowtable(_execute(y, query))
    match_fn = _fetch_match_fn(match_fn)
    return match_fn(table_x, table_y)
end

function _make_stmt(associations::SupplementalAttributeAssociations, query::String)
    return get!(
        () -> SQLite.Stmt(associations.db, query),
        associations.cached_statements,
        query,
    )
end

_execute_cached(s::SupplementalAttributeAssociations, q, p = nothing) =
    execute(_make_stmt(s, q), p, LOG_GROUP_TIME_SERIES)
_execute(s::SupplementalAttributeAssociations, q, p = nothing) =
    execute(s.db, q, p, LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES)
function _execute_count(
    associations::SupplementalAttributeAssociations,
    query::String,
    params = nothing,
)
    rows = Tables.rowtable(_execute(associations, query, params))
    if isempty(rows)
        error("$query did not return any rows.")
    end
    return rows[1].count
end

function _get_attribute_type_string!(
    params, attribute_type::Union{Nothing, Type{<:SupplementalAttribute}},
)
    val = if isnothing(attribute_type)
        ""
    elseif isabstracttype(attribute_type)
        count = 0
        for type in get_all_concrete_subtypes(attribute_type)
            push!(params, string(nameof(type)))
            count += 1
        end
        placeholder = chop(repeat("?,", count))
        "attribute_type in ($placeholder)"
    else
        push!(params, string(nameof(attribute_type)))
        "attribute_type = ?"
    end

    return val
end
