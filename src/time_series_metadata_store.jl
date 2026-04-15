const ASSOCIATIONS_TABLE_NAME = "time_series_associations"
const METADATA_TABLE_NAME = "time_series_metadata"
const KEY_VALUE_TABLE_NAME = "key_value_store"
const DB_FILENAME = "time_series_metadata.db"
# This version is also used in the Python package infrasys.
const TS_METADATA_FORMAT_VERSION = "1.1.0"
const TS_DB_INDEXES = Dict(
    "by_c_n_tst_features" => [
        "owner_uuid",
        "time_series_type",
        "name",
        "resolution",
        "interval",
        "features",
    ],
    "by_ts_uuid" => ["time_series_uuid"],
)

@kwdef struct HasMetadataQueryKey
    has_name::Bool
    num_possible_types::Int
    has_resolution::Bool
    has_interval::Bool
    has_features::Bool
    feature_filter::Union{Nothing, String} = nothing
end

mutable struct TimeSeriesMetadataStore
    db::SQLite.DB
    # Caching compiled SQL statements saves 3-4 us per query query.
    # DBInterface.jl does something similar with @prepare.
    # We need this to be tied to our connection.
    cached_statements::Dict{String, SQLite.Stmt}
    # This caching allows the code to skip some string interpolations.
    # It is experimental for PowerSimulations, which calls has_metadata frequently.
    # It may not be necessary. Savings are minimal.
    has_metadata_statements::Dict{HasMetadataQueryKey, SQLite.Stmt}
    metadata_uuids::Dict{Base.UUID, TimeSeriesMetadata}
    # If you add any fields, ensure they are managed in deepcopy_internal below.
end

"""
Construct a new TimeSeriesMetadataStore with an in-memory database.
"""
function TimeSeriesMetadataStore()
    # This metadata is not expected to exceed system memory, so create an in-memory
    # database so that it is faster. This could be changed.
    store = TimeSeriesMetadataStore(
        SQLite.DB(),
        Dict{String, SQLite.Stmt}(),
        Dict{HasMetadataQueryKey, SQLite.Stmt}(),
        Dict{Base.UUID, TimeSeriesMetadata}(),
    )
    _create_associations_table!(store)
    _create_key_value_table!(store)
    _create_indexes!(store)
    @debug "Initialized new time series metadata table" _group = LOG_GROUP_TIME_SERIES
    return store
end

"""
Load a TimeSeriesMetadataStore from a saved database into an in-memory database.
"""
function TimeSeriesMetadataStore(filename::AbstractString)
    src = SQLite.DB(filename)
    db = SQLite.DB()
    backup(db, src)
    store = TimeSeriesMetadataStore(
        db,
        Dict{String, SQLite.Stmt}(),
        Dict{HasMetadataQueryKey, SQLite.Stmt}(),
        Dict{Base.UUID, TimeSeriesMetadata}(),
    )
    _process_migrations_if_needed(store)
    _load_metadata_into_memory!(store)
    _create_indexes!(store)
    @debug "Loaded time series metadata from file" _group = LOG_GROUP_TIME_SERIES filename
    return store
end

function _process_migrations_if_needed(store::TimeSeriesMetadataStore)
    if _needs_migration_from_v2_3(store.db)
        _migrate_from_v2_3(store)
    elseif _needs_migration_from_v2_4(store.db)
        _migrate_from_v2_4(store)
    end
end

function _load_metadata_into_memory!(store::TimeSeriesMetadataStore)
    stmt = SQLite.Stmt(
        store.db,
        "SELECT * FROM $ASSOCIATIONS_TABLE_NAME",
    )
    exclude_keys = Set((:metadata_uuid, :owner_uuid, :time_series_type))
    for row in Tables.rowtable(SQLite.DBInterface.execute(stmt))
        time_series_type = TIME_SERIES_STRING_TO_TYPE[row.time_series_type]
        metadata_type = time_series_data_to_metadata(time_series_type)
        fields = Set(fieldnames(metadata_type))
        data = Dict{Symbol, Any}(
            :internal =>
                InfrastructureSystemsInternal(; uuid = Base.UUID(row.metadata_uuid)),
        )
        if time_series_type <: Forecast
            # Special case because the table column does not match the field name.
            data[:count] = row.window_count
        end
        if time_series_type <: AbstractDeterministic
            data[:time_series_type] = time_series_type
        end
        for field in keys(row)
            if !in(field, fields) || field in exclude_keys
                continue
            end
            val = getproperty(row, field)
            if field == :initial_timestamp
                data[field] = Dates.DateTime(val)
            elseif field == :resolution
                data[field] = from_iso_8601(val)
            elseif field == :horizon || field == :interval
                if !ismissing(val)
                    data[field] = from_iso_8601(val)
                end
            elseif field == :time_series_uuid
                data[field] = Base.UUID(val)
            elseif field == :features
                features_array = JSON3.read(val, Array)
                features_dict = Dict{String, Union{Bool, Int, String}}()
                for obj in features_array
                    length(obj) != 1 && error("Invalid features: $obj")
                    key = first(keys(obj))
                    key in keys(features_dict) && error("Duplicate features: $key")
                    features_dict[key] = obj[key]
                end
                data[field] = features_dict
            elseif field == :scaling_factor_multiplier
                if !ismissing(val)
                    val2 = JSON3.read(val, Dict{String, Any})
                    data[field] = deserialize(Function, val2)
                end
            else
                data[field] = val
            end
        end
        metadata = metadata_type(; data...)
        store.metadata_uuids[get_uuid(metadata)] = metadata
    end
end

# This function can be deleted when we no long support deserialization from <= 2.6.
function _load_metadata_into_memory_legacy!(store::TimeSeriesMetadataStore)
    metadata_uuids = Dict{Base.UUID, TimeSeriesMetadata}()
    stmt =
        SQLite.Stmt(store.db, "SELECT json(metadata) AS metadata FROM $METADATA_TABLE_NAME")
    for metadata_as_str in Tables.columntable(SQLite.DBInterface.execute(stmt)).metadata
        metadata = _deserialize_metadata(metadata_as_str)
        internal = get_internal(metadata)
        if !isnothing(internal.ext) && !isempty(internal.ext)
            @warn "ext is no longer supported on a time series metadata instance and will be dropped: $(internal.ext)"
        end
        if !isnothing(internal.units_info)
            @warn "units_info is no longer supported on a time series metadata instance and will be dropped: $(internal.units_info)"
        end
        uuid = get_uuid(metadata)
        if haskey(store.metadata_uuids, uuid)
            error("Bug: duplicate metadata UUID $(uuid)")
        end
        metadata_uuids[uuid] = metadata
    end

    SQLite.DBInterface.execute(store.db, "DROP TABLE $METADATA_TABLE_NAME")
    return metadata_uuids
end

function _list_columns(db::SQLite.DB, table_name::String)
    return Tables.columntable(
        SQLite.DBInterface.execute(
            db,
            "SELECT name FROM pragma_table_info('$table_name')",
        ),
    )[1]
end

function _needs_migration_from_v2_3(db::SQLite.DB)
    return "time_series_uuid" in _list_columns(db, METADATA_TABLE_NAME)
end

function _needs_migration_from_v2_4(db::SQLite.DB)
    tables = Tables.columntable(
        SQLite.DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table'"),
    )
    return !in(KEY_VALUE_TABLE_NAME, tables.name)
end

function _migrate_from_v2_3(store::TimeSeriesMetadataStore)
    # This schema was present in IS v2.3, which was supported by PSY 4.4.
    # The function can be deleted once upgrades from this version is not supported
    # (once we are at PSY 5).
    #
    # The schema had one table where the metadata column was a JSON string.
    # The new schema has two tables where the metadata is split out into a separate table.
    # There was a previously-inconsequential bug where DeterministicSingleTimeSeries
    # metadata had the same UUID as its shared SingleTimeSeries metadata.
    # Those need new UUIDs to make the new schema work.
    @info "Start migration of one-table time series metadata to v1.0.0."
    for index in ("by_c_n_tst_features", "by_ts_uuid")
        SQLite.DBInterface.execute(store.db, "DROP INDEX IF EXISTS $index")
    end
    new_rows = Tuple[]
    unique_metadata = Dict{String, String}()
    for row in Tables.rowtable(
        SQLite.DBInterface.execute(
            store.db,
            """
                SELECT
                    id
                    ,time_series_type
                    ,owner_uuid
                    ,owner_type
                    ,owner_category
                    ,features
                    ,json(metadata) as metadata
                FROM $METADATA_TABLE_NAME
            """),
    )
        metadata = _deserialize_metadata(row.metadata)
        if occursin("DeterministicSingleTimeSeries", row.metadata)
            assign_new_uuid_internal!(metadata)
        end
        metadata_uuid = string(get_uuid(metadata))
        if haskey(unique_metadata, metadata_uuid)
            if row.metadata != unique_metadata[metadata_uuid]
                error(
                    "Bug: Unexpected mismatch in metadata JSON text: " *
                    "first = $(row.metadata) second = $(unique_metadata[metadata_uuid])",
                )
            end
        else
            unique_metadata[metadata_uuid] = row.metadata
        end
        new_row = _create_migrated_row(metadata, row)
        push!(new_rows, new_row)
    end
    _execute(store, "DROP TABLE $METADATA_TABLE_NAME")
    _add_migrated_rows!(store, new_rows)
end

function _migrate_from_v2_4(store::TimeSeriesMetadataStore)
    metadata_uuids = _load_metadata_into_memory_legacy!(store)

    # The original schema had all Dates.Period columns stored as integers in units of ms
    # The current schema stores them as strings.
    @debug "Start migration of schema to time series metadata format v1.0.0."
    for index in ("by_c_n_tst_features", "by_ts_uuid")
        SQLite.DBInterface.execute(store.db, "DROP INDEX IF EXISTS $index")
    end
    new_rows = Tuple[]
    for row in Tables.rowtable(
        SQLite.DBInterface.execute(
            store.db,
            """
                SELECT
                    id
                    ,time_series_type
                    ,owner_uuid
                    ,owner_type
                    ,owner_category
                    ,features
                    ,metadata_uuid
                FROM $ASSOCIATIONS_TABLE_NAME
            """),
    )
        metadata = metadata_uuids[Base.UUID(row.metadata_uuid)]
        new_row = _create_migrated_row(metadata, row)
        push!(new_rows, new_row)
    end
    SQLite.DBInterface.execute(store.db, "DROP TABLE $ASSOCIATIONS_TABLE_NAME")
    _add_migrated_rows!(store, new_rows)
end

function _create_migrated_row(metadata::SingleTimeSeriesMetadata, row)
    sfm = get_scaling_factor_multiplier(metadata)
    return (
        row.id,
        string(get_time_series_uuid(metadata)),
        row.time_series_type,
        string(get_initial_timestamp(metadata)),
        _serialize_period(get_resolution(metadata)),
        missing,
        missing,
        missing,
        get_length(metadata),
        get_name(metadata),
        row.owner_uuid,
        row.owner_type,
        row.owner_category,
        row.features,
        isnothing(sfm) ? missing : JSON3.write(serialize(sfm)),
        get_uuid(metadata),
        missing,
    )
end

function _create_migrated_row(metadata::ForecastMetadata, row)
    sfm = get_scaling_factor_multiplier(metadata)
    new_row = (
        row.id,
        string(get_time_series_uuid(metadata)),
        row.time_series_type,
        string(get_initial_timestamp(metadata)),
        _serialize_period(get_resolution(metadata)),
        _serialize_period(get_horizon(metadata)),
        _serialize_period(get_interval(metadata)),
        get_count(metadata),
        missing,
        get_name(metadata),
        row.owner_uuid,
        row.owner_type,
        row.owner_category,
        row.features,
        isnothing(sfm) ? missing : JSON3.write(serialize(sfm)),
        get_uuid(metadata),
        missing,
    )
end

function _add_migrated_rows!(store::TimeSeriesMetadataStore, rows)
    _create_associations_table!(store)
    _add_rows!(
        store.db,
        rows,
        (
            "id",
            "time_series_uuid",
            "time_series_type",
            "initial_timestamp",
            "resolution",
            "horizon",
            "interval",
            "window_count",
            "length",
            "name",
            "owner_uuid",
            "owner_type",
            "owner_category",
            "features",
            "scaling_factor_multiplier",
            "metadata_uuid",
            "units",
        ),
        ASSOCIATIONS_TABLE_NAME,
    )
    _create_key_value_table!(store)
    @debug "Migrated time series assocations table to v1.0.0."
end

"""
Load a TimeSeriesMetadataStore from an HDF5 file into an in-memory database.
"""
function from_h5_file(::Type{TimeSeriesMetadataStore}, src::AbstractString, directory)
    data = HDF5.h5open(src, "r") do file
        file[HDF5_TS_METADATA_ROOT_PATH][:]
    end

    filename, io = mktemp(isnothing(directory) ? tempdir() : directory)
    write(io, data)
    close(io)
    return TimeSeriesMetadataStore(filename)
end

function _create_associations_table!(store::TimeSeriesMetadataStore)
    # TODO: SQLite createtable!() doesn't provide a way to create a primary key.
    # https://github.com/JuliaDatabases/SQLite.jl/issues/286
    # We can use that function if they ever add the feature.
    schema = [
        "id INTEGER PRIMARY KEY",
        "time_series_uuid TEXT NOT NULL",
        "time_series_type TEXT NOT NULL",
        "initial_timestamp TEXT NOT NULL",
        "resolution TEXT NOT NULL",
        "horizon TEXT",
        "interval TEXT",
        "window_count INTEGER",
        "length INTEGER",
        "name TEXT NOT NULL",
        "owner_uuid TEXT NOT NULL",
        "owner_type TEXT NOT NULL",
        "owner_category TEXT NOT NULL",
        "features TEXT NOT NULL",
        "scaling_factor_multiplier JSON NULL",
        "metadata_uuid TEXT NOT NULL",
        "units TEXT NULL",
    ]
    schema_text = join(schema, ",")
    SQLite.DBInterface.execute(
        store.db,
        "CREATE TABLE $(ASSOCIATIONS_TABLE_NAME)($(schema_text))",
    )
    @debug "Created time series associations table" schema _group = LOG_GROUP_TIME_SERIES
    return
end

function _create_key_value_table!(store::TimeSeriesMetadataStore)
    schema = [
        "key TEXT PRIMARY KEY",
        "value JSON NOT NULL",
    ]
    schema_text = join(schema, ",")
    SQLite.DBInterface.execute(
        store.db,
        "CREATE TABLE $(KEY_VALUE_TABLE_NAME)($(schema_text))",
    )
    @debug "Created key-value table" schema _group = LOG_GROUP_TIME_SERIES
    SQLite.DBInterface.execute(
        store.db,
        "INSERT INTO $(KEY_VALUE_TABLE_NAME) VALUES(?,?)",
        ("version", TS_METADATA_FORMAT_VERSION),
    )
    return
end

function _create_indexes!(store::TimeSeriesMetadataStore)
    # Index strategy:
    # 1. Optimize for these user queries with indexes:
    #    1a. all time series attached to one component/attribute
    #    1b. time series for one component/attribute + name + type + resolution
    #    1c. time series for one component/attribute + name + type + resolution + interval
    #    1d. time series for one component/attribute with all features
    # 2. Optimize for checks at system.add_time_series. Use all fields and features.
    # 3. Optimize for returning all metadata for a time series UUID.
    # Note: interval is NULL for static time series. SQLite treats each NULL as distinct
    # in unique indexes, so SQL-level uniqueness for static time series is enforced by the
    # application-level check in add_time_series! rather than this index.

    _drop_all_indexes!(store.db)
    SQLite.createindex!(
        store.db,
        ASSOCIATIONS_TABLE_NAME,
        "by_c_n_tst_features",
        TS_DB_INDEXES["by_c_n_tst_features"];
        unique = true,
        ifnotexists = true,
    )
    SQLite.createindex!(
        store.db,
        ASSOCIATIONS_TABLE_NAME,
        "by_ts_uuid",
        TS_DB_INDEXES["by_ts_uuid"];
        unique = false,
        ifnotexists = true,
    )

    optimize_database!(store)
    return
end

function _drop_all_indexes!(db::SQLite.DB)
    for index_name in keys(TS_DB_INDEXES)
        SQLite.dropindex!(db, index_name; ifexists = true)
    end
end

function Base.deepcopy_internal(store::TimeSeriesMetadataStore, dict::IdDict)
    if haskey(dict, store)
        return dict[store]
    end

    new_db = SQLite.DB()
    backup(new_db, store.db)
    new_store = TimeSeriesMetadataStore(
        new_db,
        Dict{String, SQLite.Stmt}(),
        Dict{HasMetadataQueryKey, SQLite.Stmt}(),
        deepcopy(store.metadata_uuids),
    )
    dict[store] = new_store
    return new_store
end

"""
Add metadata to the store. The caller must check if there are duplicates.
"""
function add_metadata!(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners,
    metadata::TimeSeriesMetadata,
)
    owner_category = _get_owner_category(owner)
    time_series_type = time_series_metadata_to_data(metadata)
    features = make_features_string(metadata.features)
    sfm = get_scaling_factor_multiplier(metadata)
    internal = get_internal(metadata)
    if !isnothing(internal.ext) && !isempty(internal.ext)
        error("ext cannot be set on a time series metadata instance: $(internal.ext)")
    end
    if !isnothing(internal.units_info)
        error(
            "units_info cannot be set on a time series metadata instance: $(internal.units_info)",
        )
    end
    vals = _create_row(
        metadata,
        owner,
        owner_category,
        _convert_ts_type_to_string(time_series_type),
        features,
        isnothing(sfm) ? missing : JSON3.write(serialize(sfm)),
    )
    params = chop(repeat("?,", length(vals)))
    _execute_cached(
        store,
        "INSERT INTO $ASSOCIATIONS_TABLE_NAME VALUES($params)",
        vals,
    )
    metadata_uuid = get_uuid(metadata)
    if !haskey(store.metadata_uuids, metadata_uuid)
        store.metadata_uuids[metadata_uuid] = metadata
    end
    @debug "Added metadata = $metadata to $(summary(owner))" _group =
        LOG_GROUP_TIME_SERIES
    return
end

function _add_rows!(
    db::SQLite.DB,
    rows::Vector,
    columns,
    table_name::String,
)
    num_rows = length(rows)
    num_columns = length(columns)
    data = OrderedDict(x => Vector{Any}(undef, num_rows) for x in columns)
    for (i, row) in enumerate(rows)
        for (j, column) in enumerate(columns)
            data[column][i] = row[j]
        end
    end

    placeholder = chop(repeat("?,", num_columns))

    # Note: executemany automatically wraps operations in a transaction for performance
    # No need for explicit BEGIN/COMMIT as SQLite.jl handles this internally
    SQLite.DBInterface.executemany(
        db,
        "INSERT INTO $table_name VALUES($placeholder)",
        NamedTuple(Symbol(k) => v for (k, v) in data),
    )
    @debug "Added $num_rows rows to table = $table_name" _group = LOG_GROUP_TIME_SERIES
    return
end

"""
Backup the database to a file on the temporary filesystem and return that filename.
"""
function backup_to_temp(store::TimeSeriesMetadataStore)
    filename, io = mktemp()
    close(io)
    dst = SQLite.DB(filename)
    try
        backup(dst, store.db)
        dst = SQLite.DB(filename)
        _drop_all_indexes!(dst)
    finally
        close(dst)
    end
    return filename
end

"""
Clear all time series metadata from the store.
"""
function clear_metadata!(store::TimeSeriesMetadataStore)
    _execute(store, "DELETE FROM $ASSOCIATIONS_TABLE_NAME")
end

"""
Update database statistics for optimal query planning.
Call this after bulk operations or significant data changes.
"""
function optimize_database!(store::TimeSeriesMetadataStore)
    # Run ANALYZE to update query planner statistics
    SQLite.DBInterface.execute(store.db, "ANALYZE")
    # Run VACUUM to reclaim space and defragment (optional, can be slow)
    # SQLite.DBInterface.execute(store.db, "VACUUM")
    @debug "Optimized database statistics" _group = LOG_GROUP_TIME_SERIES
    return
end

function check_params_compatibility(
    store::TimeSeriesMetadataStore,
    metadata::ForecastMetadata,
)
    params = ForecastParameters(;
        count = get_count(metadata),
        horizon = get_horizon(metadata),
        initial_timestamp = get_initial_timestamp(metadata),
        interval = get_interval(metadata),
        resolution = get_resolution(metadata),
    )
    check_params_compatibility(store, params)
    return
end

check_params_compatibility(
    store::TimeSeriesMetadataStore,
    metadata::StaticTimeSeriesMetadata,
) = nothing
check_params_compatibility(
    store::TimeSeriesMetadataStore,
    params::StaticTimeSeriesParameters,
) = nothing

function check_params_compatibility(
    store::TimeSeriesMetadataStore,
    params::ForecastParameters,
)
    store_params = get_forecast_parameters(
        store;
        resolution = params.resolution,
        interval = params.interval,
    )
    isnothing(store_params) && return
    check_params_compatibility(store_params, params)
    return
end

# These are guaranteed to be consistent already.
check_consistency(::TimeSeriesMetadataStore, ::Type{<:Forecast}) = nothing

"""
Throw InvalidValue if the SingleTimeSeries arrays have different initial times or lengths.
Return the initial timestamp and length as a tuple.
"""
function check_consistency(store::TimeSeriesMetadataStore, ::Type{SingleTimeSeries})
    query = """
        SELECT
            DISTINCT initial_timestamp
            ,length
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE time_series_type = 'SingleTimeSeries'
    """
    table = Tables.rowtable(_execute(store, query))
    len = length(table)
    if len == 0
        return Dates.DateTime(Dates.Minute(0)), 0
    elseif len > 1
        throw(
            InvalidValue(
                "There are more than one sets of SingleTimeSeries initial times and lengths: $table",
            ),
        )
    end

    row = table[1]
    return Dates.DateTime(row.initial_timestamp), row.length
end

# check_consistency is not implemented on StaticTimeSeries because new types may have
# different requirments than SingleTimeSeries. Let future developers make that decision.

function get_forecast_initial_times(
    store::TimeSeriesMetadataStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    params = get_forecast_parameters(store; resolution = resolution, interval = interval)
    isnothing(params) && return []
    return get_initial_times(params.initial_timestamp, params.count, params.interval)
end

function get_forecast_parameters(
    store::TimeSeriesMetadataStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    vals = ["horizon IS NOT NULL"]
    params = []
    if !isnothing(resolution)
        push!(vals, "resolution = ?")
        push!(params, _serialize_period(resolution))
    end
    if !isnothing(interval)
        push!(vals, "interval = ?")
        push!(params, _serialize_period(interval))
    end
    where_clause = join(vals, " AND ")
    query = """
        SELECT
            horizon
            ,initial_timestamp
            ,interval
            ,resolution
            ,window_count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE $where_clause
        LIMIT 1
    """
    table = Tables.rowtable(_execute_cached(store, query, params))
    isempty(table) && return nothing
    row = table[1]
    return ForecastParameters(;
        horizon = from_iso_8601(row.horizon),
        initial_timestamp = Dates.DateTime(row.initial_timestamp),
        interval = from_iso_8601(row.interval),
        count = row.window_count,
        resolution = from_iso_8601(row.resolution),
    )
end

function get_forecast_window_count(
    store::TimeSeriesMetadataStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    params = get_forecast_parameters(store; resolution = resolution, interval = interval)
    isnothing(params) && return nothing
    return params.count
end

function get_forecast_horizon(
    store::TimeSeriesMetadataStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    params = get_forecast_parameters(store; resolution = resolution, interval = interval)
    isnothing(params) && return nothing
    return params.horizon
end

function get_forecast_initial_timestamp(
    store::TimeSeriesMetadataStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    params = get_forecast_parameters(store; resolution = resolution, interval = interval)
    isnothing(params) && return nothing
    return params.initial_timestamp
end

function get_forecast_interval(
    store::TimeSeriesMetadataStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    params = get_forecast_parameters(store; resolution = resolution, interval = interval)
    isnothing(params) && return nothing
    return params.interval
end

"""
Return the metadata matching the inputs. Throw an exception if there is more than one
matching input.
"""
function get_metadata(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners,
    time_series_type::Type{<:TimeSeriesData},
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    metadata = _try_get_time_series_metadata_by_full_params(
        store,
        owner,
        time_series_type,
        name;
        resolution = resolution,
        interval = interval,
        features...,
    )
    !isnothing(metadata) && return metadata

    metadata_items = list_metadata(
        store,
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        features...,
    )
    len = length(metadata_items)
    if len == 0
        throw(ArgumentError("No matching metadata is stored."))
    elseif len > 1
        throw(
            ArgumentError(
                "Found more than one matching metadata: $len. Try specifying additional keyword arguments (for example resolution, interval, or features) to disambiguate.",
            ),
        )
    end

    return metadata_items[1]
end

"""
Return the number of unique time series arrays.
"""
function get_num_time_series(store::TimeSeriesMetadataStore)
    return _execute_count(
        store,
        "SELECT COUNT(DISTINCT time_series_uuid) AS count FROM $ASSOCIATIONS_TABLE_NAME",
    )
end

"""
Return an instance of TimeSeriesCounts.
"""
function get_time_series_counts(store::TimeSeriesMetadataStore)
    query_components = """
        SELECT COUNT(DISTINCT owner_uuid) AS count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE owner_category = 'Component'
    """
    query_attributes = """
        SELECT COUNT(DISTINCT owner_uuid) AS count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE owner_category = 'SupplementalAttribute'
    """
    query_sts = """
        SELECT COUNT(DISTINCT time_series_uuid) AS count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE interval IS NULL
    """
    query_forecasts = """
        SELECT COUNT(DISTINCT time_series_uuid) AS count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE interval IS NOT NULL
    """

    count_components = _execute_count(store, query_components)
    count_attributes = _execute_count(store, query_attributes)
    count_sts = _execute_count(store, query_sts)
    count_forecasts = _execute_count(store, query_forecasts)

    return TimeSeriesCounts(;
        components_with_time_series = count_components,
        supplemental_attributes_with_time_series = count_attributes,
        static_time_series_count = count_sts,
        forecast_count = count_forecasts,
    )
end

"""
Return a Vector of OrderedDict of stored time series counts by type.
"""
function get_time_series_counts_by_type(store::TimeSeriesMetadataStore)
    query = """
        SELECT
            time_series_type
            ,count(*) AS count
        FROM $ASSOCIATIONS_TABLE_NAME
        GROUP BY
            time_series_type
        ORDER BY
            time_series_type
    """
    table = Tables.rowtable(_execute(store, query))
    return [
        OrderedDict("type" => x.time_series_type, "count" => x.count) for x in table
    ]
end

"""
Return a DataFrame with the number of static time series for components and supplemental
attributes.
"""
function get_static_time_series_summary_table(store::TimeSeriesMetadataStore)
    category_clause, params = _make_category_clause(StaticTimeSeries)
    query = """
        SELECT
            owner_type
            ,owner_category
            ,name
            ,time_series_type
            ,initial_timestamp
            ,resolution AS resolution
            ,count(*) AS count
            ,length AS time_step_count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE $category_clause
        GROUP BY
            owner_type
            ,owner_category
            ,name
            ,time_series_type
            ,initial_timestamp
            ,resolution
            ,length
        ORDER BY
            owner_category
            ,owner_type
            ,name
            ,time_series_type
            ,initial_timestamp
            ,resolution
            ,length
    """
    query_result = DataFrame(_execute(store, query, params))
    query_result[!, "resolution"] =
        Dates.canonicalize.(from_iso_8601.(query_result[!, "resolution"]))
    return query_result
end

"""
Return a DataFrame with the number of forecasts for components and supplemental
attributes.
"""
function get_forecast_summary_table(store::TimeSeriesMetadataStore)
    category_clause, params = _make_category_clause(Forecast)
    query = """
        SELECT
            owner_type
            ,owner_category
            ,name
            ,time_series_type
            ,initial_timestamp
            ,resolution AS resolution
            ,count(*) AS count
            ,horizon AS horizon
            ,interval AS interval
            ,window_count
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE $category_clause
        GROUP BY
            owner_type
            ,owner_category
            ,name
            ,time_series_type
            ,initial_timestamp
            ,resolution
            ,horizon
            ,interval
            ,window_count
        ORDER BY
            owner_category
            ,owner_type
            ,name
            ,time_series_type
            ,initial_timestamp
            ,resolution
            ,horizon
            ,interval
            ,window_count
    """
    query_result = DataFrame(_execute(store, query, params))
    for col_name in ["resolution", "horizon", "interval"]
        query_result[!, col_name] =
            Dates.canonicalize.(from_iso_8601.(query_result[!, col_name]))
    end
    return query_result
end

function has_metadata(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    params =
        _make_has_metadata_params(owner, time_series_type, name, resolution, interval)
    if isempty(features)
        stmt = _make_has_metadata_statement!(
            store,
            HasMetadataQueryKey(;
                has_name = !isnothing(name),
                num_possible_types = _get_num_possible_types(time_series_type),
                has_resolution = !isnothing(resolution),
                has_interval = !isnothing(interval),
                has_features = false,
            ),
        )
        return _has_metadata(stmt, params)
    end

    # It's worth trying full features first because we can get an index hit and
    # avoid JSON parsing.
    stmt = _make_has_metadata_statement!(
        store,
        HasMetadataQueryKey(;
            has_name = !isnothing(name),
            num_possible_types = _get_num_possible_types(time_series_type),
            has_resolution = !isnothing(resolution),
            has_interval = !isnothing(interval),
            has_features = true,
        ),
    )
    full_features = make_features_string(; features...)
    if _has_metadata(stmt, (params..., full_features))
        return true
    end

    params2 = collect(params)
    feature_filter = _make_feature_filter!(params2; features...)
    stmt = _make_has_metadata_statement!(
        store,
        HasMetadataQueryKey(;
            has_name = !isnothing(name),
            num_possible_types = _get_num_possible_types(time_series_type),
            has_resolution = !isnothing(resolution),
            has_interval = !isnothing(interval),
            has_features = true,
            feature_filter = feature_filter,
        ),
    )
    return _has_metadata(stmt, params2)
end

const _QUERY_HAS_METADATA_BY_TS_UUID = "SELECT id FROM $ASSOCIATIONS_TABLE_NAME WHERE time_series_uuid = ?"

"""
Return True if there is time series matching the UUID.
"""
function has_metadata(store::TimeSeriesMetadataStore, time_series_uuid::Base.UUID)
    params = (string(time_series_uuid),)
    return _has_metadata(store, _QUERY_HAS_METADATA_BY_TS_UUID, params)
end

const _QUERY_BASE_HAS_METADATA = "SELECT id FROM $ASSOCIATIONS_TABLE_NAME WHERE owner_uuid = ?"

function _make_has_metadata_statement!(
    store::TimeSeriesMetadataStore,
    key::HasMetadataQueryKey;
)
    stmt = get(store.has_metadata_statements, key, nothing)
    if !isnothing(stmt)
        return stmt
    end

    where_clauses = String[]
    if key.has_name
        push!(where_clauses, "name = ?")
    end
    if key.num_possible_types == 1
        push!(where_clauses, "time_series_type = ?")
    elseif key.num_possible_types > 1
        val = chop(repeat("?,", key.num_possible_types))
        push!(where_clauses, "time_series_type IN ($val)")
    end
    if key.has_resolution
        push!(where_clauses, "resolution = ?")
    end
    if key.has_interval
        push!(where_clauses, "interval = ?")
    end
    if key.has_features
        if isnothing(key.feature_filter)
            push!(where_clauses, "features = ?")
        else
            push!(where_clauses, "$(key.feature_filter)")
        end
    end

    if isempty(where_clauses)
        final = "$_QUERY_BASE_HAS_METADATA LIMIT 1"
    else
        where_clause = join(where_clauses, " AND ")
        final = "$_QUERY_BASE_HAS_METADATA AND $where_clause LIMIT 1"
    end

    stmt = SQLite.Stmt(store.db, final)
    store.has_metadata_statements[key] = stmt
    return stmt
end

function _make_has_metadata_params(
    owner::TimeSeriesOwners,
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing},
    name::Union{String, Nothing},
    resolution::Union{Dates.Period, Nothing},
    interval::Union{Dates.Period, Nothing} = nothing;
    feature_value::Union{String, Nothing} = nothing,
)
    return (
        string(get_uuid(owner)),
        _get_name_params(name)...,
        _get_ts_type_params(time_series_type)...,
        _get_resolution_param(resolution)...,
        _get_interval_param(interval)...,
        _get_feature_params(feature_value)...,
    )
end

_get_name_params(::Nothing) = ()
_get_name_params(name::String) = (name,)
_get_resolution_param(::Nothing) = ()
_get_resolution_param(x::Dates.Period) =
    (to_iso_8601(is_irregular_period(x) ? x : Dates.Millisecond(x)),)
_get_interval_param(::Nothing) = ()
_get_interval_param(x::Dates.Period) =
    (to_iso_8601(is_irregular_period(x) ? x : Dates.Millisecond(x)),)
_get_ts_type_params(::Nothing) = ()
_get_ts_type_params(ts_type::Type{<:TimeSeriesData}) =
    (_convert_ts_type_to_string(ts_type),)
_get_ts_type_params(ts_type::Type{<:DeterministicSingleTimeSeries}) =
    (_convert_ts_type_to_string(ts_type),)
_get_feature_params(::Nothing) = ()
_get_feature_params(feature::String) = (feature,)

function _get_ts_type_params(::Type{<:AbstractDeterministic})
    return (
        _convert_ts_type_to_string(Deterministic),
        _convert_ts_type_to_string(DeterministicSingleTimeSeries),
    )
end

_get_num_possible_types(::Nothing) = 0
_get_num_possible_types(::Type{<:TimeSeriesData}) = 1
_get_num_possible_types(::Type{<:DeterministicSingleTimeSeries}) = 1
_get_num_possible_types(::Type{<:AbstractDeterministic}) = 2

function _has_metadata(stmt::SQLite.Stmt, params)
    return !isempty(SQLite.DBInterface.execute(stmt, params))
end

function _has_metadata(store::TimeSeriesMetadataStore, query::String, params)
    return !isempty(_execute_cached(store, query, params))
end

"""
Return a sorted Vector of distinct resolutions for all time series of the given type
(or all types).
"""
function get_time_series_resolutions(
    store::TimeSeriesMetadataStore;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
)
    params = []
    if isnothing(time_series_type)
        where_clause = ""
    else
        where_clause = "WHERE time_series_type = ?"
        push!(params, string(nameof(time_series_type)))
    end
    query = """
        SELECT
            DISTINCT resolution
        FROM $ASSOCIATIONS_TABLE_NAME $where_clause
        ORDER BY resolution
    """
    return from_iso_8601.(
        Tables.columntable(_execute(store, query, params)).resolution,
    )
end

"""
Return the time series UUIDs specified in the passed uuids that are already stored.
"""
function list_existing_time_series_uuids(store::TimeSeriesMetadataStore, uuids)
    uuids_str = string.(uuids)
    placeholder = chop(repeat("?,", length(uuids)))
    query = """
        SELECT
            DISTINCT time_series_uuid
            FROM $ASSOCIATIONS_TABLE_NAME
            WHERE time_series_uuid IN ($placeholder)
    """
    table = Tables.columntable(_execute_cached(store, query, uuids_str))
    return Base.UUID.(table.time_series_uuid)
end

const _QUERY_LIST_EXISTING_TS_UUIDS = "SELECT DISTINCT time_series_uuid FROM $ASSOCIATIONS_TABLE_NAME"

function list_existing_time_series_uuids(store::TimeSeriesMetadataStore)
    table = Tables.columntable(_execute_cached(store, _QUERY_LIST_EXISTING_TS_UUIDS))
    return Base.UUID.(table.time_series_uuid)
end

"""
Return the time series UUIDs that match the inputs.
"""
function list_matching_time_series_uuids(
    store::TimeSeriesMetadataStore;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Dates.Period, Nothing} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    where_clause, params = _make_where_clause(;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        features...,
    )
    query = "SELECT DISTINCT time_series_uuid FROM $ASSOCIATIONS_TABLE_NAME $where_clause"
    table = Tables.columntable(_execute(store, query, params))
    return Base.UUID.(table.time_series_uuid)
end

function list_metadata(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Dates.Period, Nothing} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    where_clause, params = _make_where_clause(
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        features...,
    )
    query = """
        SELECT metadata_uuid
        FROM $ASSOCIATIONS_TABLE_NAME
        $where_clause
        ORDER BY time_series_type
    """
    # ORDER BY clause: DeterministicSingleTimeSeries refers to the data of a SingleTimeSeries,
    # so must remove the Deterministic one first, else clear_time_series! errors.
    # D < S, so alphabetical ordering works.
    table = Tables.rowtable(_execute_cached(store, query, params))
    return [store.metadata_uuids[Base.UUID(x.metadata_uuid)] for x in table]
end

"""
Return a Vector of NamedTuple of owner UUID and time series metadata matching the inputs.
"""
function list_metadata_with_owner_uuid(
    store::TimeSeriesMetadataStore,
    owner_type::Type{<:TimeSeriesOwners};
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Dates.Period, Nothing} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    where_clause, params = _make_where_clause(
        owner_type;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        features...,
    )
    query = """
        SELECT owner_uuid, metadata_uuid
        FROM $ASSOCIATIONS_TABLE_NAME
        $where_clause
    """
    table = Tables.rowtable(_execute(store, query, params))
    return [
        (
            owner_uuid = Base.UUID(x.owner_uuid),
            metadata = store.metadata_uuids[Base.UUID(x.metadata_uuid)],
        ) for x in table
    ]
end

function list_owner_uuids_with_time_series(
    store::TimeSeriesMetadataStore,
    owner_type::Type{<:TimeSeriesOwners};
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = _get_owner_category(owner_type)
    vals = ["owner_category = ?"]
    params = Vector{Any}([category])
    if !isnothing(time_series_type)
        push!(vals, "time_series_type = ?")
        push!(params, string(nameof(time_series_type)))
    end
    if !isnothing(resolution)
        push!(vals, "resolution = ?")
        push!(params, _serialize_period(resolution))
    end

    where_clause = join(vals, " AND ")
    query = """
        SELECT
            DISTINCT owner_uuid
        FROM $ASSOCIATIONS_TABLE_NAME
        WHERE $where_clause
    """
    return Base.UUID.(Tables.columntable(_execute(store, query, params)).owner_uuid)
end

"""
Return information about each time series array attached to the owner.
This information can be used to call `get_time_series`.
"""
function get_time_series_keys(store::TimeSeriesMetadataStore, owner::TimeSeriesOwners)
    return [make_time_series_key(x) for x in list_metadata(store, owner)]
end

"""
Remove the matching metadata from the store.
"""
function remove_metadata!(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners,
    metadata::TimeSeriesMetadata,
)
    _check_remove_metadata(store, metadata)
    where_clause, params = _make_where_clause(owner, metadata)
    num_deleted = _remove_metadata!(store, where_clause, params)
    if num_deleted != 1
        error("Bug: unexpected number of deletions: $num_deleted. Should have been 1.")
    end

    _handle_removed_metadata(store, string(get_uuid(metadata)))
end

function remove_metadata!(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Dates.Period, Nothing} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    where_clause, params = _make_where_clause(
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        # TODO/PERF: This can be made faster by attempting search by a full match
        # and then fallback to partial. We likely don't care about this for removing.
        require_full_feature_match = false,
        features...,
    )

    # The metadata in the rows about to be deleted need to be deleted if there are no more
    # associations with them.
    metadata_uuids =
        Tables.columntable(
            _execute(
                store,
                "SELECT metadata_uuid FROM $ASSOCIATIONS_TABLE_NAME $where_clause",
                params,
            ),
        ).metadata_uuid

    for metadata_uuid in metadata_uuids
        metadata = store.metadata_uuids[Base.UUID(metadata_uuid)]
        _check_remove_metadata(store, metadata)
    end

    num_deleted = _remove_metadata!(store, where_clause, params)
    if num_deleted == 0
        @warn "No time series metadata was deleted."
    else
        for metadata_uuid in metadata_uuids
            _handle_removed_metadata(store, metadata_uuid)
        end
    end
end

_check_remove_metadata(::TimeSeriesMetadataStore, ::TimeSeriesMetadata) = nothing

const _QUERY_CHECK_FOR_ATTACHED_DSTS = """
SELECT time_series_uuid
FROM $ASSOCIATIONS_TABLE_NAME
WHERE time_series_uuid = ?
GROUP BY time_series_uuid
HAVING
    SUM(CASE WHEN time_series_type = 'SingleTimeSeries' THEN 1 ELSE 0 END) = 1
    AND SUM(CASE WHEN time_series_type = 'DeterministicSingleTimeSeries' THEN 1 ELSE 0 END) >= 1
"""

function _check_remove_metadata(
    store::TimeSeriesMetadataStore,
    metadata::SingleTimeSeriesMetadata,
)
    ts_uuid = get_time_series_uuid(metadata)
    table = Tables.rowtable(
        _execute(store, _QUERY_CHECK_FOR_ATTACHED_DSTS, (string(ts_uuid),)),
    )
    if length(table) != 0
        # We are adding this block because of unnecessary complexity when
        # serializing/de-serializing time series to/from the SiennaGridDB.
        # There should not be a reason for a user to remove this SingleTimeSeries.
        throw(
            ArgumentError(
                "Cannot remove SingleTimeSeries with UUID = $ts_uuid because it is attached to a " *
                "DeterministicSingleTimeSeries.",
            ),
        )
    end
end

function _handle_removed_metadata(store::TimeSeriesMetadataStore, metadata_uuid::String)
    query = "SELECT COUNT(*) AS count FROM $ASSOCIATIONS_TABLE_NAME WHERE metadata_uuid = ?"
    params = (metadata_uuid,)
    count = _execute_count(store, query, params)
    if count == 0
        pop!(store.metadata_uuids, Base.UUID(metadata_uuid))
    end
end

const _QUERY_REPLACE_COMP_UUID_TS = """
    UPDATE $ASSOCIATIONS_TABLE_NAME
    SET owner_uuid = ?
    WHERE owner_uuid = ?
"""
function replace_component_uuid!(
    store::TimeSeriesMetadataStore,
    old_uuid::Base.UUID,
    new_uuid::Base.UUID,
)
    params = (string(new_uuid), string(old_uuid))
    _execute(store, _QUERY_REPLACE_COMP_UUID_TS, params)
    return
end

"""
Run a query and return the results in a DataFrame.
"""
function sql(store::TimeSeriesMetadataStore, query::String, params = nothing)
    return DataFrames.DataFrame(_execute(store, query, params))
end

"""
Return the table as a DataFrame.
"""
function to_dataframe(store::TimeSeriesMetadataStore; table = ASSOCIATIONS_TABLE_NAME)
    return sql(store, "SELECT * FROM $table")
end

function to_h5_file(store::TimeSeriesMetadataStore, dst::String)
    metadata_path = backup_to_temp(store)
    data = open(metadata_path, "r") do io
        read(io)
    end

    HDF5.h5open(dst, "r+") do file
        if HDF5_TS_METADATA_ROOT_PATH in keys(file)
            HDF5.delete_object(file, HDF5_TS_METADATA_ROOT_PATH)
        end
        file[HDF5_TS_METADATA_ROOT_PATH] = data
    end

    return
end

function _create_row(
    metadata::ForecastMetadata,
    owner,
    owner_category,
    ts_type,
    features,
    scaling_factor_multiplier,
)
    return (
        missing,  # auto-assigned by sqlite
        string(get_time_series_uuid(metadata)),
        ts_type,
        string(get_initial_timestamp(metadata)),
        _serialize_period(get_resolution(metadata)),
        _serialize_period(get_horizon(metadata)),
        _serialize_period(get_interval(metadata)),
        get_count(metadata),
        missing,
        get_name(metadata),
        string(get_uuid(owner)),
        string(nameof(typeof(owner))),
        owner_category,
        features,
        scaling_factor_multiplier,
        string(get_uuid(metadata)),
        missing,
    )
end

function _create_row(
    metadata::StaticTimeSeriesMetadata,
    owner,
    owner_category,
    ts_type,
    features,
    scaling_factor_multiplier,
)
    resolution = get_resolution(metadata)
    if !is_irregular_period(resolution)
        resolution = Dates.Millisecond(resolution)
    end
    return (
        missing,  # auto-assigned by sqlite
        string(get_time_series_uuid(metadata)),
        ts_type,
        string(get_initial_timestamp(metadata)),
        _serialize_period(get_resolution(metadata)),
        missing,
        missing,
        missing,
        get_length(metadata),
        get_name(metadata),
        string(get_uuid(owner)),
        string(nameof(typeof(owner))),
        owner_category,
        features,
        scaling_factor_multiplier,
        string(get_uuid(metadata)),
        missing,
    )
end

function _serialize_period(period::Dates.Period)
    if !is_irregular_period(period)
        period = Dates.Millisecond(period)
    end
    return to_iso_8601(period)
end

function make_stmt(store::TimeSeriesMetadataStore, query::String)
    return get!(() -> SQLite.Stmt(store.db, query), store.cached_statements, query)
end

_execute_cached(s::TimeSeriesMetadataStore, q, p = nothing) =
    execute(make_stmt(s, q), p, LOG_GROUP_TIME_SERIES)
_execute(s::TimeSeriesMetadataStore, q, p = nothing) =
    execute(s.db, q, p, LOG_GROUP_TIME_SERIES)

function _execute_count(
    store::TimeSeriesMetadataStore,
    query::String,
    params::Union{Nothing, Tuple{String}} = nothing,
)
    rows = Tables.rowtable(_execute(store, query, params))
    if isempty(rows)
        error("$query. Did not return any rows.")
    end
    return rows[1].count
end

function _remove_metadata!(
    store::TimeSeriesMetadataStore,
    where_clause::AbstractString,
    params,
)
    _execute(store, "DELETE FROM $ASSOCIATIONS_TABLE_NAME $where_clause", params)
    table = Tables.rowtable(_execute(store, "SELECT CHANGES() AS changes"))
    @assert_op length(table) == 1
    @debug "Deleted $(table[1].changes) rows from the time series associations table" _group =
        LOG_GROUP_TIME_SERIES
    return table[1].changes
end

function _try_get_time_series_metadata_by_full_params(
    store::TimeSeriesMetadataStore,
    owner::TimeSeriesOwners,
    time_series_type::Type{<:TimeSeriesData},
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    where_clause, params = _make_where_clause(
        owner;
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        require_full_feature_match = true,
        features...,
    )
    query = "SELECT metadata_uuid FROM $ASSOCIATIONS_TABLE_NAME $where_clause"
    rows = Tables.rowtable(_execute_cached(store, query, params))
    len = length(rows)
    if len == 0
        return nothing
    elseif len == 1
        return store.metadata_uuids[Base.UUID(rows[1].metadata_uuid)]
    else
        throw(ArgumentError("Found more than one matching time series: $len"))
    end
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::TimeSeriesMetadataStore,
    y::TimeSeriesMetadataStore;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    # Note that we can't compare missing values.
    owner_uuid = compare_uuids ? ", owner_uuid" : ""
    query = """
        SELECT id, metadata_uuid, time_series_uuid $owner_uuid
        FROM $ASSOCIATIONS_TABLE_NAME ORDER BY id
    """
    table_x = Tables.rowtable(_execute(x, query))
    table_y = Tables.rowtable(_execute(y, query))
    match_fn = _fetch_match_fn(match_fn)
    return match_fn(table_x, table_y)
end

### Non-TimeSeriesMetadataStore functions ###

const _DETERMINISTIC_AS_STRING = string(nameof(Deterministic))
const _DETERMINISTIC_STS_AS_STRING = string(nameof(DeterministicSingleTimeSeries))
const _STS_AS_STRING = string(nameof(SingleTimeSeries))
const _PROBABILISTIC_AS_STRING = string(nameof(Probabilistic))
const _SCENARIOS_AS_STRING = string(nameof(Scenarios))

_convert_ts_type_to_string(ts_type::Type{<:TimeSeriesData}) = string(nameof(ts_type))
_convert_ts_type_to_string(::Type{<:Deterministic}) = _DETERMINISTIC_AS_STRING
_convert_ts_type_to_string(::Type{<:DeterministicSingleTimeSeries}) =
    _DETERMINISTIC_STS_AS_STRING
_convert_ts_type_to_string(::Type{<:Probabilistic}) = _PROBABILISTIC_AS_STRING
_convert_ts_type_to_string(::Type{<:Scenarios}) = _SCENARIOS_AS_STRING

function _deserialize_metadata(text::String)
    val = JSON3.read(text, Dict)
    return deserialize(get_type_from_serialization_data(val), val)
end

_get_owner_category(
    ::Union{InfrastructureSystemsComponent, Type{<:InfrastructureSystemsComponent}},
) = "Component"
_get_owner_category(
    ::Union{SupplementalAttribute, Type{<:SupplementalAttribute}},
) = "SupplementalAttribute"

function _make_category_clause(ts_type::Type{<:TimeSeriesData})
    subtypes = [string(nameof(x)) for x in get_all_concrete_subtypes(ts_type)]
    clause = if length(subtypes) == 1
        "time_series_type = ?"
    else
        placeholder = chop(repeat("?,", length(subtypes)))
        "time_series_type IN ($placeholder)"
    end

    return clause, subtypes
end

# Multiple dispatch helpers for feature pattern generation
# Pattern for string values: match key-value pair in JSON structure
_make_feature_pattern(key::String, val::AbstractString) = "%\"$(key)\":\"$(val)\"%"

# Pattern for non-string values (Bool, Int, Float): match key-value pair in JSON structure
_make_feature_pattern(key::String, val::Union{Bool, Int, Float64}) = "%\"$(key)\":$(val)%"

function _make_feature_filter!(params; features...)
    data = _make_sorted_feature_array(; features...)
    strings = []
    for (key, val) in data
        # Optimized: Use json_extract when available (SQLite 3.38.0+) for better performance
        # Fall back to LIKE for compatibility with older SQLite versions
        # Note: json_extract requires features column to be valid JSON
        # For now, keeping LIKE but with more precise patterns to reduce false positives
        push!(strings, "features LIKE ?")
        push!(params, _make_feature_pattern(key, val))
    end
    return join(strings, " AND ")
end

_make_val_str(val::Union{Bool, Int, Float64}) = string(val)
_make_val_str(val::String) = "'$val'"

function _make_sorted_feature_array(; features...)
    key_names = sort!(collect(string.(keys(features))))
    return [(key, features[Symbol(key)]) for key in key_names]
end

function _make_where_clause(
    owner_type::Type{<:TimeSeriesOwners};
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    require_full_feature_match = false,
    features...,
)
    params = Vector{Any}([_get_owner_category(owner_type)])
    return _make_where_clause(;
        owner_clause = "owner_category = ?",
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        require_full_feature_match = require_full_feature_match,
        params = params,
        features...,
    )
end

function _make_where_clause(
    owner::TimeSeriesOwners;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    require_full_feature_match = false,
    params = nothing,
    features...,
)
    if isnothing(params)
        params = []
    end
    push!(params, string(get_uuid(owner)))
    return _make_where_clause(;
        owner_clause = "owner_uuid = ?",
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        require_full_feature_match = require_full_feature_match,
        params = params,
        features...,
    )
end

function _make_where_clause(;
    owner_clause::Union{String, Nothing} = nothing,
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
    name::Union{String, Nothing} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    require_full_feature_match = false,
    params = nothing,
    features...,
)
    if isnothing(params)
        params = []
    end
    vals = String[]
    if !isnothing(owner_clause)
        push!(vals, owner_clause)
    end
    if !isnothing(name)
        push!(vals, "name = ?")
        push!(params, name)
    end
    if !isnothing(resolution)
        push!(vals, "resolution = ?")
        push!(params, _serialize_period(resolution))
    end
    if !isnothing(interval)
        push!(vals, "interval = ?")
        push!(params, _serialize_period(interval))
    end
    num_possible_types = _get_num_possible_types(time_series_type)
    if num_possible_types == 1
        push!(vals, "time_series_type = ?")
        push!(params, _convert_ts_type_to_string(time_series_type))
    elseif num_possible_types > 1
        val = chop(repeat("?,", num_possible_types))
        push!(vals, "time_series_type IN ($val)")
        for val in _get_ts_type_params(time_series_type)
            push!(params, val)
        end
    end
    if !isempty(features)
        if require_full_feature_match
            val = "features = ?"
            push!(params, make_features_string(; features...))
        else
            val = "$(_make_feature_filter!(params; features...))"
        end
        push!(vals, val)
    end

    return (isempty(vals) ? "" : "WHERE (" * join(vals, " AND ") * ")", params)
end

function _make_where_clause(owner::TimeSeriesOwners, metadata::TimeSeriesMetadata)
    features = Dict(Symbol(k) => v for (k, v) in get_features(metadata))
    return _make_where_clause(
        owner;
        time_series_type = time_series_metadata_to_data(metadata),
        name = get_name(metadata),
        resolution = get_resolution(metadata),
        interval = get_interval(metadata),
        features...,
    )
end
