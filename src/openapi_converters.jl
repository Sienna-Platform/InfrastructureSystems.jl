# OpenAPI serde for the supplemental attributes InfrastructureSystems itself owns.
#
# `GeographicInfo` and `DataSource` are IS types, so their field mapping belongs here rather
# than in a domain package: PowerSystems previously carried the `GeographicInfo` pair only
# because it happened to own the document walk, which meant a second domain package wanting
# the same attribute would have had to duplicate it.
#
# These take no `OpenAPIRefs`. That registry lives in the domain package because it carries
# the document's `unit_system` and `base_power` — power-domain state IS has no notion of —
# so the export direction takes the id its caller already resolved. Neither type has a
# unit-bearing field, so there is nothing else the domain layer would need to supply.

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
    GeographicInfo(; geo_json = po.geo_json)

to_openapi(geo::GeographicInfo, id::Int) =
    InfrastructureCoreOpenAPIModels.GeographicInfo(; id = id, geo_json = get_geo_json(geo))

# ── DataSource ──────────────────────────────────────────────────────────────────
#
# The document states both timestamps as `ZonedDateTime` while `DataSource` stores plain
# `DateTime`, so import drops the offset after normalizing to UTC and export re-attaches
# UTC. Normalizing rather than discarding the zone matters: two documents recording the same
# instant in different zones must import to the same `DateTime`, which `DateTime(zdt)` alone
# would not give.
#
# `extra` widens `Dict{String, String}` to the `Dict{String, Any}` the field declares; on the
# way out, values are stringified, since the schema types that map as strings.

_datasource_utc(zdt) = Dates.DateTime(TimeZones.astimezone(zdt, TimeZones.tz"UTC"))
_datasource_utc(::Nothing) = nothing

_datasource_zoned(dt::Dates.DateTime) = TimeZones.ZonedDateTime(dt, TimeZones.tz"UTC")

# `published_at`/`recorded_by` are absence-by-predicate, not absence-by-`nothing`: their
# accessors error rather than return a sentinel, so the export path asks first. An absent
# field is written as `null`, which the schema marks optional.
function _datasource_published_at(ds::DataSource)
    has_published_at(ds) || return nothing
    return _datasource_zoned(get_published_at(ds))
end

function _datasource_recorded_by(ds::DataSource)
    has_recorded_by(ds) || return nothing
    return get_recorded_by(ds)
end

_datasource_fields(::Nothing) = String[]
_datasource_fields(v) = collect(String, v)

_datasource_extra(::Nothing) = Dict{String, Any}()
_datasource_extra(d) = Dict{String, Any}(k => v for (k, v) in d)

function from_openapi(po::InfrastructureCoreOpenAPIModels.DataSource)
    return DataSource(;
        organization = po.organization,
        retrieved_at = _datasource_utc(po.retrieved_at),
        dataset = po.dataset,
        url = po.url,
        version = po.version,
        published_at = _datasource_utc(po.published_at),
        confidence = po.confidence,
        recorded_by = po.recorded_by,
        fields = _datasource_fields(po.fields),
        extra = _datasource_extra(po.extra),
    )
end

function to_openapi(ds::DataSource, id::Int)
    return InfrastructureCoreOpenAPIModels.DataSource(;
        id = id,
        organization = get_organization(ds),
        retrieved_at = _datasource_zoned(get_retrieved_at(ds)),
        dataset = get_dataset(ds),
        url = get_url(ds),
        version = get_version(ds),
        published_at = _datasource_published_at(ds),
        confidence = get_confidence(ds),
        recorded_by = _datasource_recorded_by(ds),
        fields = get_fields(ds),
        extra = Dict{String, String}(k => string(v) for (k, v) in get_extra(ds)),
    )
end
