# Thin wrappers over InfraStore's own OpenAPI-row serde: the store owns every column mapping
# and wire spelling, so this file only bridges `SystemData`/`Store` to the store handle and
# parses the store's JSON into the generated OpenAPI model types.

"""
$(TYPEDSIGNATURES)

A [`TimeSeriesMetadata`](@ref) row for every time series in a store matching the given
(all-optional, independent) filters — the same keywords as `InfraStore.list_metadata`.

Also callable on a `Store` directly, for a writer staging series before any `SystemData`
exists. `time_series_type` and the returned rows use IS's own vocabulary, translated from
InfraStore's.
"""
list_time_series_metadata(store::Store; kwargs...) =
    _infrastore_list_metadata(store; kwargs...)

list_time_series_metadata(data::SystemData; kwargs...) =
    list_time_series_metadata(get_data_store(data); kwargs...)

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

# `JSON.parse` yields `AbstractDict{String, Any}` rows, which `decode` takes as-is. A oneOf
# wrapper picks its concrete member type from the row's own discriminator field, so no
# dispatch is needed here.
function _openapi_rows(::Type{T}, json::AbstractString) where {T}
    return T[
        InfrastructureCoreOpenAPIModels.decode(T, row) for row in JSON.parse(json)
    ]
end

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
    openapi_time_series_association_json(get_data_store(data); kwargs...)

"""
$(TYPEDSIGNATURES)

The rows of [`openapi_time_series_association_json`](@ref), deserialized into
`InfrastructureTimeSeriesOpenAPIModels.TimeSeriesAssociation` — the oneOf wrapper whose
`.value` picks its concrete per-type struct (`SingleTimeSeries`, `Deterministic`, ...) from
each row's own `time_series_type` discriminator.
"""
function openapi_time_series_association_rows(store::Store; kwargs...)
    return _openapi_rows(
        InfrastructureTimeSeriesOpenAPIModels.TimeSeriesAssociation,
        openapi_time_series_association_json(store; kwargs...),
    )
end

openapi_time_series_association_rows(data::SystemData; kwargs...) =
    openapi_time_series_association_rows(get_data_store(data); kwargs...)

"""
$(TYPEDSIGNATURES)

The raw JSON array InfraStore's `openapi` module produces for the whole
`supplemental_attribute_associations` table, sorted by `(component_id, attribute_id)`. See
[`openapi_supplemental_attribute_association_rows`](@ref) for the typed form.
"""
openapi_supplemental_attribute_association_json(store::Store) =
    InfraStore.export_supplemental_attribute_associations_openapi(store.inner)

openapi_supplemental_attribute_association_json(data::SystemData) =
    openapi_supplemental_attribute_association_json(
        get_data_store(data.supplemental_attribute_manager),
    )

"""
$(TYPEDSIGNATURES)

The rows of [`openapi_supplemental_attribute_association_json`](@ref), deserialized into
`InfrastructureCoreOpenAPIModels.SupplementalAttributeAssociation`.
"""
function openapi_supplemental_attribute_association_rows(store::Store)
    return _openapi_rows(
        InfrastructureCoreOpenAPIModels.SupplementalAttributeAssociation,
        openapi_supplemental_attribute_association_json(store),
    )
end

openapi_supplemental_attribute_association_rows(data::SystemData) =
    openapi_supplemental_attribute_association_rows(
        get_data_store(data.supplemental_attribute_manager),
    )

"""
$(TYPEDSIGNATURES)

Bulk-ingest a JSON array of time-series association OpenAPI rows into the store's
`time_series_associations` table in one all-or-nothing transaction; returns the number of
rows inserted. Each row must name an array the store already holds and keeps the
`association_id` the document recorded, so existing document references stay valid.
"""
import_time_series_association_rows!(store::Store, json::AbstractString) =
    InfraStore.import_time_series_associations_openapi!(store.inner, json)

import_time_series_association_rows!(data::SystemData, json::AbstractString) =
    import_time_series_association_rows!(get_data_store(data), json)

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
        get_data_store(data.supplemental_attribute_manager), json,
    )
