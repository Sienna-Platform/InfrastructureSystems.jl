# Associations Database Schema

!!! note "For Maintainers and Contributors"
    
    This page documents the internal databases used by InfrastructureSystems.jl to manage associations between components and their time series data and supplemental attributes. This information is intended for maintainers and contributors working on the codebase. **End users should not need to interact with these databases directly.**

## Overview

InfrastructureSystems.jl tracks two kinds of associations, each with its own storage:

 1. **Components/supplemental attributes ↔ time series data** — managed by the
    `time-series-store` Rust backend (wrapped by `TimeSeriesStore.jl`). Both the numerical
    arrays and the association catalog live there; IS.jl does not maintain its own time series
    metadata database. See [Time Series Data](@ref) for the on-disk artifact and catalog model.
 2. **Components ↔ supplemental attributes** — managed by IS.jl in an in-memory SQLite
    database (`SupplementalAttributeAssociations`).

These associations enable fast lookups, efficient filtering, proper lifecycle management
(add/remove/update), and serialization/deserialization.

## Time Series Associations (Rust backend)

Time series associations are stored by the `time-series-store` backend, not by an
IS.jl-managed SQLite database. The on-disk artifact is a NetCDF file (`<path>.nc`) for the
arrays plus a sibling SQLite catalog (`<path>.sqlite`) for the associations; the two files are
one logical unit and must be moved, copied, and deleted together. Each association is
identified by the owner (`owner_id` + `owner_category`), `name`, `resolution`, `features`, and
the concrete `time_series_type`, together with the array's SHA-256 content hash (which provides
automatic de-duplication).

For the on-disk layout, the catalog columns and indexes, and the `DATA_FORMAT_VERSION`
compatibility contract, see [Time Series Data](@ref) and the `time-series-store` repository's
file-format reference. The IS.jl glue lives in
[`src/rust_time_series_store.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/rust_time_series_store.jl).

!!! note "Component and time series identifiers"
    
    Components and supplemental attributes are identified by integer IDs, and time series data
    is identified by its array content hash. There is no `time_series_uuid` — to address a
    specific time series use its [`TimeSeriesKey`](@ref) (see [Time Series Data](@ref)).

## Supplemental Attribute Associations

`SupplementalAttributeAssociations` manages associations between supplemental attributes and
components in an in-memory SQLite database that is always ephemeral (never persisted as a
database file; associations are serialized to the system JSON instead).

### Database Table

#### `supplemental_attributes` Table

**Schema:**

| Column Name      | Type    | Description                             |
|:---------------- |:------- |:--------------------------------------- |
| `attribute_id`   | INTEGER | ID of the supplemental attribute        |
| `attribute_type` | TEXT    | Type name of the supplemental attribute |
| `component_id`   | INTEGER | ID of the component                     |
| `component_type` | TEXT    | Type name of the component              |

**Indexes:**

  - `by_attribute`: Composite index on `(attribute_id, component_id, component_type)` — optimized for finding components associated with an attribute.
  - `by_component`: Composite index on `(component_id, attribute_id, attribute_type)` — optimized for finding attributes associated with a component.

**Design Notes:**

  - Both attribute and component information is stored to enable bidirectional lookups.
  - The indexes support fast queries in both directions (attribute → components and component → attributes).

### Common Queries

 1. **Find all attributes for a component:**
    
    ```sql
    SELECT DISTINCT attribute_id FROM supplemental_attributes
    WHERE component_id = ?
    ```

 2. **Find attributes of a specific type for a component:**
    
    ```sql
    SELECT DISTINCT attribute_id FROM supplemental_attributes
    WHERE component_id = ? AND attribute_type = ?
    ```
 3. **Find all components with an attribute:**
    
    ```sql
    SELECT DISTINCT component_id FROM supplemental_attributes
    WHERE attribute_id = ?
    ```
 4. **Check if an association exists:**
    
    ```sql
    SELECT attribute_id FROM supplemental_attributes
    WHERE attribute_id = ? AND component_id = ?
    LIMIT 1
    ```

## Serialization Behavior

### Time Series

Time series data and its association catalog are persisted by the `time-series-store` backend
as the `<path>.nc` / `<path>.sqlite` pair described above. See [Time Series Data](@ref).

### Supplemental Attribute Associations

The supplemental attribute database is in-memory and ephemeral. During serialization the
associations are extracted as records and written to the system JSON file; during
deserialization the records are read back and bulk-inserted into a fresh in-memory database,
then indexed.

## Implementation Files

  - **Time Series (Rust backend) glue**: [`src/rust_time_series_store.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/rust_time_series_store.jl)
  - **Supplemental Attribute Associations**: [`src/supplemental_attribute_associations.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/supplemental_attribute_associations.jl)
  - **SQLite Utilities**: [`src/utils/sqlite.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/utils/sqlite.jl)

## Best Practices for Developers

 1. **Use transactions** when making multiple related changes, for atomicity and performance.
 2. **Leverage indexes**: design queries to take advantage of the existing indexes.
 3. **Cache statements** for frequently-executed queries rather than re-creating them.
 4. **Maintain consistency**: when adding or removing associations, ensure the database and any
    in-memory caches are updated together.
 5. **Test with large datasets**: performance characteristics can change significantly with
    large numbers of associations.
