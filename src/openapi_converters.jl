# OpenAPI serde for the supplemental attributes InfrastructureSystems itself owns.
#
# `GeographicInfo` and `DataSource` are IS types, so their field mapping belongs here rather
# than in a domain package: a second domain package wanting the same attribute does not have
# to duplicate it.
#
# These take no `OpenAPIRefs`: that registry carries power-domain state (`unit_system`,
# `base_power`) IS has no notion of, so the export direction takes the id its caller already
# resolved.

"""
Convert an OpenAPI-model instance into the matching Sienna type.

Declared here, extended by domain packages: `PowerSystems` adds a method per component and
per attribute it owns, so `from_openapi` stays one function across the stack rather than one
per package.
"""
function from_openapi end

"""
Convert a Sienna component or attribute into its OpenAPI-model representation.

The counterpart of [`from_openapi`](@ref); the same extension rule applies.
"""
function to_openapi end

# ── GeographicInfo ──────────────────────────────────────────────────────────────

from_openapi(po::InfrastructureCoreOpenAPIModels.GeographicInfo) =
    GeographicInfo(; geo_json = po.geo_json.additional_properties)

to_openapi(geo::GeographicInfo, id::Int) =
    InfrastructureCoreOpenAPIModels.GeographicInfo(;
        id = id,
        geo_json = InfrastructureCoreOpenAPIModels.GeographicInfoGeoJson(;
            additional_properties = get_geo_json(geo),
        ),
    )

# ── DataSource ──────────────────────────────────────────────────────────────────
#
# Both timestamps are plain `Dates.DateTime` on both sides (IS treats them as UTC wall
# clocks; the document carries no offset), so `retrieved_at`/`published_at` pass straight
# through with no zone conversion.
#
# `extra` widens `Dict{String, String}` to the `Dict{String, Any}` the field declares; on the
# way out, values are stringified, since the schema types that map as strings.

# `organization`/`dataset`/`url`/`version`/`confidence` are optional in the document
# (unset decodes to `ABSENT`) but IS's own `DataSource` declares them as plain, defaulted
# `String` fields, so both "unset" spellings normalize to `""`.
_datasource_required_string(s::AbstractString) = s
_datasource_required_string(::Nothing) = ""
_datasource_required_string(::OpenAPI.Runtime.Absent) = ""

# `recorded_by`/`published_at` are nullable on both sides; only the document's extra
# "unset" spelling needs folding into the one IS already accepts.
_datasource_nullable(x) = x
_datasource_nullable(::OpenAPI.Runtime.Absent) = nothing

# `published_at`/`recorded_by` are absence-by-predicate, not absence-by-`nothing`: their
# accessors error rather than return a sentinel, so the export path asks first. An absent
# field is written as `null`, which the schema marks optional.
function _datasource_published_at(ds::DataSource)
    has_published_at(ds) || return nothing
    return get_published_at(ds)
end

function _datasource_recorded_by(ds::DataSource)
    has_recorded_by(ds) || return nothing
    return get_recorded_by(ds)
end

_datasource_fields(::Nothing) = String[]
_datasource_fields(v) = collect(String, v)

_datasource_extra(::Nothing) = Dict{String, Any}()
_datasource_extra(::OpenAPI.Runtime.Absent) = Dict{String, Any}()
_datasource_extra(d::InfrastructureCoreOpenAPIModels.DataSourceExtra) =
    Dict{String, Any}(k => v for (k, v) in d.additional_properties)

function from_openapi(po::InfrastructureCoreOpenAPIModels.DataSource)
    return DataSource(;
        organization = _datasource_required_string(po.organization),
        retrieved_at = po.retrieved_at,
        dataset = _datasource_required_string(po.dataset),
        url = _datasource_required_string(po.url),
        version = _datasource_required_string(po.version),
        published_at = _datasource_nullable(po.published_at),
        confidence = _datasource_required_string(po.confidence),
        recorded_by = _datasource_nullable(po.recorded_by),
        fields = _datasource_fields(po.fields),
        extra = _datasource_extra(po.extra),
    )
end

function to_openapi(ds::DataSource, id::Int)
    return InfrastructureCoreOpenAPIModels.DataSource(;
        id = id,
        organization = get_organization(ds),
        retrieved_at = get_retrieved_at(ds),
        dataset = get_dataset(ds),
        url = get_url(ds),
        version = get_version(ds),
        published_at = _datasource_published_at(ds),
        confidence = get_confidence(ds),
        recorded_by = _datasource_recorded_by(ds),
        fields = get_fields(ds),
        extra = InfrastructureCoreOpenAPIModels.DataSourceExtra(;
            additional_properties = Dict{String, String}(
                k => string(v) for (k, v) in get_extra(ds)
            ),
        ),
    )
end
