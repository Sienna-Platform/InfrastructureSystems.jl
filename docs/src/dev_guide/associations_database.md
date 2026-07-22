# Associations Database Schema

!!! note "For Maintainers and Contributors"

    This page documents the internal databases used by InfrastructureSystems.jl to manage associations between components and their time series data and supplemental attributes. This information is intended for maintainers and contributors working on the codebase. **End users should not need to interact with these databases directly.**

## Overview

InfrastructureSystems.jl tracks two kinds of associations, and **both live in the
`time-series-store` Rust backend** (wrapped by `TimeSeriesStore.jl`). IS.jl maintains no
database of its own:

 1. **Components/supplemental attributes ↔ time series data** — the backend's time series
    catalog. Both the numerical arrays and the catalog live there. See
    [Time Series Data](@ref) for the on-disk artifact and catalog model.
 2. **Components ↔ supplemental attributes** — the backend's
    `supplemental_attribute_associations` table, reached through
    `SupplementalAttributeAssociations`, which is now a thin adapter rather than a database.

!!! note "This changed"

    Supplemental attribute associations used to live in a separate in-memory SQLite database
    owned by IS.jl and were serialized into the system JSON. They now share the backend's
    `.nc` / `.sqlite` artifact with the time series catalog. One consequence: a system with
    supplemental attributes but no time series now writes a storage artifact where it
    previously wrote none.

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
    is identified by its array content hash. Use a [`TimeSeriesKey`](@ref) to address a specific
    time series (see [Time Series Data](@ref)).

## Supplemental Attribute Associations

`SupplementalAttributeAssociations` is the adapter over the backend's
`supplemental_attribute_associations` table. It keeps the dispatch-based IS.jl API — the
`Type`-taking overloads of `has_association`, `list_associated_component_ids`, and friends —
and forwards each call to `TimeSeriesStore.jl`.

**Row shape:** `component_id`, `component_type`, `attribute_id`, `attribute_type`.

**Identity** is the `(component_id, attribute_id)` pair. The type columns are denormalized
labels carried for filtering, so re-attaching the same pair under different type names is a
duplicate and is rejected by the store. Callers still check `has_association` first so the
error message can name the objects.

The backend indexes the pair for lookups keyed on the component and carries a second index
for the reverse direction, so both `component → attributes` and `attribute → components` are
fast.

### Abstract-type expansion stays in Julia

The store filters on lists of **concrete** type-name strings and knows nothing about the
Julia type hierarchy. `_type_names` applies `get_all_subtype_names` before any query is
issued, so an abstract type is expanded here and handed over as a `Vector{String}`. An
abstract type with no concrete subtypes expands to an empty vector, which the store treats as
"match nothing".

### Rollback

`begin_supplemental_attributes_update` used to wrap a SQLite transaction. The store exposes
no transaction primitive, so the manager snapshots the association rows on entry and restores
them wholesale on failure. Rows are small metadata, so a full clear-and-reload is cheap — and
unlike a diff of newly added rows it also undoes removals, matching the previous semantics.

## Serialization Behavior

### Time Series

Time series data and its association catalog are persisted by the `time-series-store` backend
as the `<path>.nc` / `<path>.sqlite` pair described above. See [Time Series Data](@ref).

### Supplemental Attribute Associations

Associations are persisted by the backend, in the same `.sqlite` sidecar as the time series
catalog, so `serialize` writes no `associations` key into the system JSON. Systems written
before this change still carry that key; `deserialize` loads it into the store when present.

Because the artifact now carries associations, `isempty(::RustTimeSeriesStore)` counts
association rows as well as time series — otherwise `serialize` would skip writing the
artifact for an attribute-only system and silently drop them.

## Implementation Files

  - **Time Series (Rust backend) glue**: [`src/rust_time_series_store.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/rust_time_series_store.jl)
  - **Supplemental Attribute Associations**: [`src/supplemental_attribute_associations.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl/blob/main/src/supplemental_attribute_associations.jl)

## Best Practices for Developers

 1. **Batch related changes** through `begin_supplemental_attributes_update`, for atomicity
    and performance.
 2. **Expand abstract types once**, at the IS.jl boundary, and pass concrete name vectors down.
 3. **Maintain consistency**: when adding or removing associations, ensure the store and the
    manager's in-memory attribute dicts are updated together.
 4. **Test with large datasets**: performance characteristics can change significantly with
    large numbers of associations.
