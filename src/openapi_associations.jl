# ---- OpenAPI-row association serde -----------------------------------------
#
# Thin wrappers over InfraStore's own OpenAPI-row serde
# (`infrastore_core::openapi`, exposed by `InfraStore.jl`'s
# `export_time_series_associations_openapi` / `export_supplemental_attribute_associations_openapi`
# / `import_supplemental_attribute_associations_openapi!` /
# `reconcile_time_series_associations_openapi!`). The store owns every column mapping and wire
# spelling now (id/owner_id, `owner_category`, ISO durations, plain-scalar features,
# `unit_system` labels, per-type timing columns, sort order); this file only bridges
# `SystemData`/`Store` to the store handle they already hold and parses the store's JSON into
# the generated OpenAPI model types, the same way `PowerOpenAPIModels.document_from_json` does
# (`OpenAPI.from_json` on the raw row dict; the oneOf wrapper picks its concrete member type
# from the row's own discriminator field, so no dispatch is needed here).

"""
$(TYPEDSIGNATURES)

Metadata for every time series in a store matching the (all-optional, independent) filters —
the same filter keywords as `InfraStore.list_time_series`/`InfraStore.list_keys` — in one
catalog query.

Takes the store directly as well as a `SystemData`, because a writer that stages series into
a scratch store — a parser building a document, say — needs the same rows before any
`SystemData` exists.
"""
function list_time_series_metadata(
    store::Store;
    owner_id = nothing,
    owner_category = nothing,
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features = Dict{String, Any}(),
    component_field = nothing,
)
    return InfraStore.list_time_series(
        store.inner;
        owner_id = owner_id,
        owner_category = owner_category,
        time_series_type = time_series_type,
        name = name,
        resolution = resolution,
        interval = interval,
        features = features,
        component_field = component_field,
    )
end

list_time_series_metadata(data::SystemData; kwargs...) =
    list_time_series_metadata(data.time_series_manager.data_store; kwargs...)

"""
$(TYPEDSIGNATURES)

Every `(component_id, component_type, attribute_id, attribute_type)` association row in
`data`, in one catalog query.

The counterpart of [`list_time_series_metadata`](@ref) for the attachment table. Callers
building a document group these by `component_id` instead of asking the store once per
component.
"""
list_supplemental_attribute_association_rows(data::SystemData) =
    _association_rows(data.supplemental_attribute_manager.associations)

# ── typed OpenAPI rows ──────────────────────────────────────────────────────────

"""
$(TYPEDSIGNATURES)

The raw, already schema-conformant JSON array InfraStore's `openapi` module produces for
`time_series_associations` matching the filter (the same filter keywords as
[`list_time_series_metadata`](@ref)), each row stamped with the store's own `uri` and
`data_hash`. For a caller that embeds the JSON verbatim (into a document, say) rather than
round-tripping it through the generated model types; see
[`openapi_time_series_association_rows`](@ref) for that.
"""
function openapi_time_series_association_json(store::Store; kwargs...)
    return InfraStore.export_time_series_associations_openapi(store.inner; kwargs...)
end

openapi_time_series_association_json(data::SystemData; kwargs...) =
    openapi_time_series_association_json(data.time_series_manager.data_store; kwargs...)

"""
$(TYPEDSIGNATURES)

The rows of [`openapi_time_series_association_json`](@ref), deserialized into
`PowerTimeSeriesOpenAPIModels.TimeSeriesAssociation` — the oneOf wrapper whose `.value` picks
its concrete per-type struct (`SingleTimeSeries`, `Deterministic`, ...) from each row's own
`time_series_type` discriminator, via `OpenAPI.from_json`. This is the same mechanism
`PowerOpenAPIModels.document_from_json` uses to build a `SystemDocument`'s own
`time_series_associations`.
"""
function openapi_time_series_association_rows(store::Store; kwargs...)
    json = openapi_time_series_association_json(store; kwargs...)
    return PowerTimeSeriesOpenAPIModels.TimeSeriesAssociation[
        OpenAPI.from_json(
            PowerTimeSeriesOpenAPIModels.TimeSeriesAssociation, Dict{String, Any}(row),
        ) for row in JSON.parse(json)
    ]
end

openapi_time_series_association_rows(data::SystemData; kwargs...) =
    openapi_time_series_association_rows(data.time_series_manager.data_store; kwargs...)

"""
$(TYPEDSIGNATURES)

The raw JSON array InfraStore's `openapi` module produces for the whole
`supplemental_attribute_associations` table, sorted by `(component_id, attribute_id)`. See
[`openapi_supplemental_attribute_association_rows`](@ref) for the typed form.
"""
openapi_supplemental_attribute_association_json(store::Store) =
    InfraStore.export_supplemental_attribute_associations_openapi(store.inner)

openapi_supplemental_attribute_association_json(data::SystemData) =
    openapi_supplemental_attribute_association_json(data.time_series_manager.data_store)

"""
$(TYPEDSIGNATURES)

The rows of [`openapi_supplemental_attribute_association_json`](@ref), deserialized into
`PowerCoreOpenAPIModels.SupplementalAttributeAssociation` via `OpenAPI.from_json`.
"""
function openapi_supplemental_attribute_association_rows(store::Store)
    json = openapi_supplemental_attribute_association_json(store)
    return PowerCoreOpenAPIModels.SupplementalAttributeAssociation[
        OpenAPI.from_json(
            PowerCoreOpenAPIModels.SupplementalAttributeAssociation, Dict{String, Any}(row),
        ) for row in JSON.parse(json)
    ]
end

openapi_supplemental_attribute_association_rows(data::SystemData) =
    openapi_supplemental_attribute_association_rows(data.time_series_manager.data_store)

"""
$(TYPEDSIGNATURES)

Bulk-ingest a JSON array of supplemental-attribute association OpenAPI rows into the store's
`supplemental_attribute_associations` table in one all-or-nothing transaction. Passthrough to
`InfraStore.import_supplemental_attribute_associations_openapi!`; returns the number of rows
inserted.
"""
import_supplemental_attribute_association_rows!(store::Store, json::AbstractString) =
    InfraStore.import_supplemental_attribute_associations_openapi!(store.inner, json)

import_supplemental_attribute_association_rows!(data::SystemData, json::AbstractString) =
    import_supplemental_attribute_association_rows!(
        data.time_series_manager.data_store, json,
    )

"""
$(TYPEDSIGNATURES)

Reconcile a JSON array of time-series association OpenAPI rows against the store's catalog:
match by identity, apply `policy` (`:strict` or `:update_descriptive`) to any descriptive
drift, and throw `InfraStore.ReconcileConflictError` for anything neither policy can resolve.
Each row's `uri`/`data_hash` are informational and never checked. Passthrough to
`InfraStore.reconcile_time_series_associations_openapi!`; see there for the full policy
semantics.
"""
function reconcile_time_series_association_rows!(
    store::Store,
    json::AbstractString;
    policy::Symbol = :strict,
)
    return InfraStore.reconcile_time_series_associations_openapi!(
        store.inner, json; policy = policy,
    )
end

function reconcile_time_series_association_rows!(
    data::SystemData,
    json::AbstractString;
    policy::Symbol = :strict,
)
    return reconcile_time_series_association_rows!(
        data.time_series_manager.data_store, json; policy = policy,
    )
end
