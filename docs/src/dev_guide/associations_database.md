# Associations Database Schema

!!! note "For Maintainers and Contributors"
    
    This page documents the internal database schemas used by InfrastructureSystems.jl to manage associations between components and their time series data and supplemental attributes. This information is intended for maintainers and contributors working on the codebase. **End users should not need to interact with these databases directly.**

## Overview

InfrastructureSystems.jl uses SQLite databases to efficiently track associations between:

  - **Components** and **Time Series data**
  - **Components** and **Supplemental Attributes**

These associations are managed under the hood to enable:

  - Fast lookups of time series and attributes attached to components
  - Efficient querying and filtering
  - Proper lifecycle management (adding, removing, updating references)
  - Serialization and deserialization support

The package maintains two separate databases:

 1. **Time Series Metadata Store** - tracks time series associations
 2. **Supplemental Attribute Associations** - tracks supplemental attribute associations

## Design Rationale

### Why Separate Databases?

Time series metadata and supplemental attribute associations are stored in independent SQLite databases rather than different tables in the same database. This design decision is driven by serialization requirements:

**Background:**

  - Time series metadata is always persisted as a SQLite file during serialization
  - The SQLite file is written as an HDF5 dataset in the time series data file
  - Serialization produces: `system.json`, `system_metadata.json`, and `system_time_series.h5`
  - If there is no time series in the system, only `system.json` and `system_metadata.json` are produced

**The Problem:**
If supplemental attribute associations were in the same database as time series metadata, and the system had supplemental attributes but no time series, serialization would produce an extra file. The team required that supplemental attribute associations be written to the system JSON file when there is no time series data.

**The Solution:**
Keeping them as separate databases simplifies the code by avoiding the complexity of temporarily sharing a database across serialization and deepcopy operations. The supplemental attribute database is always ephemeral (in-memory only), while the time series metadata can be persisted.

## Time Series Metadata Store

The `TimeSeriesMetadataStore` manages associations between time series data and components/supplemental attributes. It uses an in-memory SQLite database for fast access.

### Database Tables

#### 1. `time_series_associations` Table

This is the primary table that stores the associations between time series data and owners (components or supplemental attributes).

**Schema:**

| Column Name                 | Type    | Description                                                                                 |
|:--------------------------- |:------- |:------------------------------------------------------------------------------------------- |
| `id`                        | INTEGER | Primary key, auto-incremented                                                               |
| `time_series_uuid`          | TEXT    | UUID of the time series data array                                                          |
| `time_series_type`          | TEXT    | Type name of the time series (e.g., "SingleTimeSeries", "Deterministic")                    |
| `initial_timestamp`         | TEXT    | ISO 8601 formatted initial timestamp                                                        |
| `resolution`                | TEXT    | Resolution encoded as [ISO 8601 duration](https://en.wikipedia.org/wiki/ISO_8601#Durations) |
| `horizon`                   | TEXT    | ISO 8601 formatted forecast horizon (NULL for static time series)                           |
| `interval`                  | TEXT    | ISO 8601 formatted forecast interval (NULL for static time series)                          |
| `window_count`              | INTEGER | Number of forecast windows (NULL for static time series)                                    |
| `length`                    | INTEGER | Length of static time series (NULL for forecasts)                                           |
| `name`                      | TEXT    | User-defined name for the time series                                                       |
| `owner_uuid`                | TEXT    | UUID of the component or supplemental attribute that owns this                              |
| `owner_type`                | TEXT    | Type name of the owner                                                                      |
| `owner_category`            | TEXT    | Either "Component" or "SupplementalAttribute"                                               |
| `features`                  | TEXT    | JSON string of feature key-value pairs for filtering                                        |
| `scaling_factor_multiplier` | JSON    | Optional function for scaling (NULL if not used)                                            |
| `metadata_uuid`             | TEXT    | UUID of the metadata object                                                                 |
| `units`                     | TEXT    | Optional units specification (NULL if not used)                                             |

**Indexes:**

  - `by_c_n_tst_features`: Composite index on `(owner_uuid, time_series_type, name, resolution, features)` - optimized for lookups by component with specific time series parameters
  - `by_ts_uuid`: Index on `(time_series_uuid)` - optimized for finding all owners of a specific time series

**Design Notes:**

  - The table supports both static time series and forecasts. Forecast-specific columns (`horizon`, `interval`, `window_count`) are NULL for static time series.
  - The `features` column stores a JSON string of key-value pairs that can be used for flexible filtering and querying.
  - All `Dates.Period` values are stored as ISO 8601 strings for portability.
  - The `metadata_uuid` allows multiple associations to reference the same metadata object (stored in memory).

#### 2. `key_value_store` Table

Stores metadata about the database itself.

**Schema:**

| Column Name | Type | Description |
|:----------- |:---- |:----------- |
| `key`       | TEXT | Primary key |
| `value`     | JSON | JSON value  |

**Current Keys:**

  - `version`: Stores the time series metadata format version (currently "1.0.0")

### Common Queries

The following types of queries are optimized by the indexes:

 1. **Find all time series for a component:**
    
    ```sql
    SELECT * FROM time_series_associations WHERE owner_uuid = ?
    ```

 2. **Find specific time series by name and type:**
    
    ```sql
    SELECT * FROM time_series_associations 
    WHERE owner_uuid = ? AND name = ? AND time_series_type = ?
    ```
 3. **Find time series with specific features:**
    
    ```sql
    SELECT * FROM time_series_associations 
    WHERE owner_uuid = ? AND features LIKE ?
    ```
 4. **Find all owners of a time series:**
    
    ```sql
    SELECT DISTINCT owner_uuid FROM time_series_associations 
    WHERE time_series_uuid = ?
    ```

### Migrations

The database schema has evolved over time. Migration code handles upgrading from older formats:

  - **v2.3 Migration**: Converted from a single metadata table with JSON columns to the current two-table structure
  - **v2.4 Migration**: Converted period storage from integer milliseconds to ISO 8601 strings

Migration functions (`_migrate_from_v2_3`, `_migrate_from_v2_4`) are maintained in `time_series_metadata_store.jl` for backward compatibility.

## Supplemental Attribute Associations

The `SupplementalAttributeAssociations` manages associations between supplemental attributes and components. It uses an in-memory SQLite database that is always ephemeral.

### Database Table

#### `supplemental_attributes` Table

**Schema:**

| Column Name      | Type | Description                             |
|:---------------- |:---- |:--------------------------------------- |
| `attribute_uuid` | TEXT | UUID of the supplemental attribute      |
| `attribute_type` | TEXT | Type name of the supplemental attribute |
| `component_uuid` | TEXT | UUID of the component                   |
| `component_type` | TEXT | Type name of the component              |

**Indexes:**

  - `by_attribute`: Composite index on `(attribute_uuid, component_uuid, component_type)` - optimized for finding components associated with an attribute
  - `by_component`: Composite index on `(component_uuid, attribute_uuid, attribute_type)` - optimized for finding attributes associated with a component

**Design Notes:**

  - The schema is simpler than the time series associations because supplemental attributes have less metadata
  - Both attribute and component information is stored to enable bidirectional lookups
  - The indexes support fast queries in both directions (attribute → components and component → attributes)

### Common Queries

 1. **Find all attributes for a component:**
    
    ```sql
    SELECT DISTINCT attribute_uuid FROM supplemental_attributes 
    WHERE component_uuid = ?
    ```

 2. **Find attributes of a specific type for a component:**
    
    ```sql
    SELECT DISTINCT attribute_uuid FROM supplemental_attributes 
    WHERE component_uuid = ? AND attribute_type = ?
    ```
 3. **Find all components with an attribute:**
    
    ```sql
    SELECT DISTINCT component_uuid FROM supplemental_attributes 
    WHERE attribute_uuid = ?
    ```
 4. **Check if an association exists:**
    
    ```sql
    SELECT attribute_uuid FROM supplemental_attributes 
    WHERE attribute_uuid = ? AND component_uuid = ? 
    LIMIT 1
    ```

## Performance Considerations

### Statement Caching

Both database implementations cache compiled SQL statements to avoid the overhead of re-parsing queries. This saves approximately 3-4 microseconds per query.

  - `TimeSeriesMetadataStore` maintains a `cached_statements` dictionary
  - `SupplementalAttributeAssociations` maintains a `cached_statements` dictionary
  - Frequently-used queries benefit most from caching

### Index Strategy

**Time Series Metadata:**

 1. Optimize for user queries by component/attribute UUID with name, type, and resolution
 2. Optimize for deduplication checks during `add_time_series!`
 3. Optimize for metadata retrieval by time series UUID

**Supplemental Attributes:**

 1. Optimize for bidirectional lookups (attribute ↔ component)
 2. Support filtering by type in both directions

### Database Location

  - Both databases are in-memory (`SQLite.DB()`) for performance
  - The time series metadata database can be backed up to disk for serialization
  - The supplemental attribute database is never persisted (associations are stored in JSON during serialization)

## Serialization Behavior

### Time Series Metadata

During serialization:

 1. The in-memory database is backed up to a temporary file
 2. Indexes are dropped from the backup (to reduce file size)
 3. The database file is written as an HDF5 dataset in `system_time_series.h5`

During deserialization:

 1. The SQLite database is extracted from the HDF5 file
 2. It's loaded into an in-memory database
 3. Indexes are recreated for performance
 4. Metadata objects are reconstructed and cached in memory

### Supplemental Attribute Associations

During serialization:

 1. All associations are extracted as records (tuples of UUIDs and types)
 2. Records are written to the JSON file

During deserialization:

 1. Records are read from the JSON file
 2. A new in-memory database is created
 3. Records are bulk-inserted using `executemany` for efficiency
 4. Indexes are created

## Implementation Files

  - **Time Series Metadata Store**: [`src/time_series_metadata_store.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/time_series_metadata_store.jl)
  - **Supplemental Attribute Associations**: [`src/supplemental_attribute_associations.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/supplemental_attribute_associations.jl)
  - **SQLite Utilities**: [`src/utils/sqlite.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/utils/sqlite.jl)

## Debugging and Inspection

### Querying the Databases

Both stores provide a `sql()` function for running custom queries:

```julia
# Query time series associations
df = InfrastructureSystems.sql(
    store,
    "SELECT * FROM time_series_associations WHERE owner_type = 'Generator'",
)

# Query supplemental attribute associations  
df = InfrastructureSystems.sql(
    associations,
    "SELECT * FROM supplemental_attributes WHERE component_type = 'Bus'",
)
```

### Viewing as DataFrames

```julia
# Time series associations as DataFrame
df = InfrastructureSystems.to_dataframe(store)

# Supplemental attributes as records
records = InfrastructureSystems.to_records(associations)
```

### Summary Functions

Both stores provide summary functions:

```julia
# Time series summaries
counts = InfrastructureSystems.get_time_series_counts(store)
summary_table = InfrastructureSystems.get_forecast_summary_table(store)

# Supplemental attribute summaries
summary_table = InfrastructureSystems.get_attribute_summary_table(associations)
num_attrs = InfrastructureSystems.get_num_attributes(associations)
```

## Best Practices for Developers

 1. **Use Transactions**: When making multiple related changes, wrap them in a SQLite transaction for atomicity and performance

 2. **Leverage Indexes**: Design queries to take advantage of the existing indexes. Check query plans if performance is a concern.
 3. **Cache Statements**: For frequently-executed queries, use the cached statement methods (`_execute_cached`) rather than creating new statements each time
 4. **Validate Migrations**: When modifying the schema, ensure migration code is added and tested with data from older versions
 5. **Test with Large Datasets**: Performance characteristics can change significantly with large numbers of associations. Test with realistic data sizes.
 6. **Handle Edge Cases**: Consider abstract types, subtypes, and empty result sets in query logic
 7. **Maintain Consistency**: When adding/removing associations, ensure both the database and any in-memory caches (like `metadata_uuids` in TimeSeriesMetadataStore) are updated together

## Future Considerations

Potential areas for enhancement:

  - **Query Optimization**: Profile and optimize hot paths, especially for large systems
  - **Schema Versioning**: Maintain a clear versioning strategy as the schema evolves
  - **Partial Indexes**: Consider partial indexes for common filtered queries
  - **Bulk Operations**: Optimize bulk insert/delete operations for large datasets
  - **Foreign Keys**: Currently not used; could add foreign key constraints for data integrity if needed
  - **Full-Text Search**: For advanced filtering on text fields like `name` or `features`
