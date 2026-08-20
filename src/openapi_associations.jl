# OpenAPI serde for the time series and supplemental-attribute association catalogs.
#
# Both tables live in one InfraStore store, and both are read here in BULK: one catalog
# query returns every row, rather than one query per owner. That is not only a speed
# choice. `TimeSeriesAssociation` requires `element_type`, `element_shape`, and `address`,
# and none of the three is reachable from a `TimeSeriesKey` — `element_type` is derived by
# InfraStore from the stored array on write, and duplicating that derivation here would put
# a second source of truth behind the one field the schema says the writing package owns.
# The catalog row carries all three, so the row IS the document row.
#
# Reading them per owner also meant materializing every series: `units`, `quantity_kind`
# and `unit_system` are declared on the `TimeSeriesData` object, so a caller walking keys
# had to load each array out of HDF5 to reach three scalar labels the catalog already
# stores as columns.
#
# Document ids are supplied by the caller, matching `to_openapi(::GeographicInfo, ::Int)`:
# the counter belongs to the document, which is a domain-package concern.

"""
Metadata for every time series in a store, in one catalog query.

Takes the store directly as well as a `SystemData`, because a writer that stages series into
a scratch store — a parser building a document, say — needs the same rows before any
`SystemData` exists.

The rows carry the columns [`to_openapi`](@ref) needs to emit a `TimeSeriesAssociation`
without reading a single stored array.
"""
list_time_series_metadata(store::Store) = InfraStore.list_time_series(store.inner)
list_time_series_metadata(data::SystemData) =
    list_time_series_metadata(data.time_series_manager.data_store)

"""
Every `(component_id, component_type, attribute_id, attribute_type)` association row in
`data`, in one catalog query.

The counterpart of [`list_time_series_metadata`](@ref) for the attachment table. Callers
building a document group these by `component_id` instead of asking the store once per
component.
"""
list_supplemental_attribute_association_rows(data::SystemData) =
    _association_rows(data.supplemental_attribute_manager.associations)

# ── column conversions ──────────────────────────────────────────────────────────

"""ISO 8601 duration for a stored period.

Dispatches on the period's kind rather than branching on its value, mirroring InfraStore's
own encoder (`InfraStore._period_to_iso` / `_fixed_ms_to_iso`) so a round trip through the
document is byte-identical to what the store would emit for the same period. Fixed spans
(`Week`/`Day`/`Hour`/`Minute`/`Second`/`Millisecond`) go through milliseconds, emitting
whole-second `PT<n>S` or fractional-second `PT<n>.<frac>S` down to the one-millisecond floor
the schema allows; calendar spans (`Month`/`Year`, and `Quarter` as a multiple of `Month`)
emit their own calendar spelling. Anything else is not a period the store or the schema can
represent, and errors rather than silently truncating."""
_openapi_duration(period::Dates.FixedPeriod) = _openapi_fixed_duration(Dates.toms(period))
_openapi_duration(period::Dates.Year) = string("P", Dates.value(period), "Y")
_openapi_duration(period::Dates.Month) = string("P", Dates.value(period), "M")
_openapi_duration(period::Dates.Quarter) = string("P", 3 * Dates.value(period), "M")
_openapi_duration(period::Dates.Period) =
    error("no ISO-8601 duration mapping for period $period ($(typeof(period)))")

# Millisecond -> ISO-8601 "PT<seconds>S", matching `InfraStore._fixed_ms_to_iso`'s spelling
# exactly (including the no-trailing-zero fractional form) so both sides agree byte-for-byte.
function _openapi_fixed_duration(ms::Integer)
    iszero(ms % 1000) && return string("PT", ms ÷ 1000, "S")
    whole = ms ÷ 1000
    frac = rstrip(lpad(ms % 1000, 3, '0'), '0')
    return string("PT", whole, ".", frac, "S")
end

"""
The document's `owner_category` spelling.

Not dispatched, and deliberately not: `InfraStore.OwnerCategory` is an `@enum`, whose values
are instances of ONE type, so there is nothing for multiple dispatch to select on. The two
ways to fake it are both worse than this comparison — returning the owner's abstract type
makes the result infer as `Type`, and `Val(category)` on a runtime value is a dynamic
dispatch. Every branch here returns a `String`, so the function is type-stable as written.
"""
function _openapi_owner_category(category::InfraStore.OwnerCategory)
    category === InfraStore.Component && return "Component"
    category === InfraStore.SupplementalAttribute && return "SupplementalAttribute"
    throw(ArgumentError("unrecognized store owner category: $category"))
end

"""The document's `unit_system` spelling.

`nothing` stays `nothing`: unspecified is deliberately not `NATURAL_UNITS`, and asserting a
basis nobody declared would be worse than omitting the field. There is no system-base
spelling on either side — per-unit data historically on the system base records that base in
the component's own `base_power` and rides as `COMPONENT_BASE`, which is also why no
`SystemBaseUnit` method exists: a read cannot produce one."""
_openapi_unit_system(::Nothing) = nothing
_openapi_unit_system(::NaturalUnit) = "NATURAL_UNITS"
_openapi_unit_system(::DeviceBaseUnit) = "COMPONENT_BASE"

"""`features` as the schema's `{name: value}` map."""
function _openapi_features(features::AbstractDict)
    return Dict{String, Any}(
        String(k) => PowerTimeSeriesOpenAPIModels.TimeSeriesFeatureValue(v)
        for (k, v) in features
    )
end

"""
A total ordering key for the catalog rows, so a document written twice from the same store
lists its series in the same order.

The series' full identity, not just `(owner, name)`: two series on one owner may share a
name and differ only by resolution, interval, or a feature value.
"""
function openapi_row_sort_key(meta::InfraStore.TimeSeriesMetadata)
    return (
        meta.owner_id,
        meta.name,
        string(nameof(meta.time_series_type)),
        string(meta.resolution),
        string(meta.interval),
        sort!([string(k) => string(v) for (k, v) in meta.features]),
    )
end

# The columns every association type carries, whatever its timing shape.
function _openapi_common(
    meta::InfraStore.TimeSeriesMetadata,
    id::Int,
    owner_id::Int,
    address::AbstractString,
)
    return (;
        id = id,
        owner_id = owner_id,
        owner_type = meta.owner_type,
        owner_category = _openapi_owner_category(meta.owner_category),
        name = meta.name,
        features = _openapi_features(meta.features),
        address = String(address),
        element_type = meta.element_type,
        element_shape = collect(Int64, meta.element_shape),
        units = meta.units,
        quantity_kind = meta.quantity_kind,
        unit_system = _openapi_unit_system(_from_store_unit_system(meta.unit_system)),
        component_field = meta.component_field,
        application_data = meta.application_data,
    )
end

# The forecast window geometry, shared by all four forecast types.
function _openapi_forecast_columns(meta::InfraStore.TimeSeriesMetadata)
    return (;
        initial_timestamp = TimeZones.ZonedDateTime(
            meta.initial_timestamp, TimeZones.TimeZone("UTC"),
        ),
        resolution = _openapi_duration(meta.resolution),
        horizon = _openapi_duration(meta.horizon),
        interval = _openapi_duration(meta.interval),
        count = meta.count,
    )
end

# ── per-type rows ───────────────────────────────────────────────────────────────
#
# One method per stored type rather than one row with every field nullable: the type
# decides which timing columns exist, which is exactly why the schemas are six documents
# and not one. `meta.time_series_type` is the InfraStore type, so these dispatch on it.
#
# `meta.length` is `size(array, 1)`, which each type spends differently: the timestep count
# for a static series, the horizon count for a `Deterministic`, the percentile count for a
# `Probabilistic`, and the scenario count for a `Scenarios`. Only the readings the schema
# asks for are emitted.

function _openapi_association(
    ::Type{InfraStore.SingleTimeSeries},
    meta::InfraStore.TimeSeriesMetadata,
    common::NamedTuple,
)
    return PowerTimeSeriesOpenAPIModels.SingleTimeSeries(;
        common...,
        initial_timestamp = TimeZones.ZonedDateTime(
            meta.initial_timestamp, TimeZones.TimeZone("UTC"),
        ),
        resolution = _openapi_duration(meta.resolution),
        length = meta.length,
    )
end

function _openapi_association(
    ::Type{InfraStore.NonSequentialTimeSeries},
    meta::InfraStore.TimeSeriesMetadata,
    common::NamedTuple,
)
    # No grid columns at all: an irregular series has no `initial + k * resolution` to
    # describe, and its explicit timestamp vector stays in the store.
    return PowerTimeSeriesOpenAPIModels.NonSequentialTimeSeries(;
        common...,
        length = meta.length,
    )
end

function _openapi_association(
    ::Type{InfraStore.Deterministic},
    meta::InfraStore.TimeSeriesMetadata,
    common::NamedTuple,
)
    return PowerTimeSeriesOpenAPIModels.Deterministic(;
        common..., _openapi_forecast_columns(meta)...,
    )
end

function _openapi_association(
    ::Type{InfraStore.DeterministicSingleTimeSeries},
    meta::InfraStore.TimeSeriesMetadata,
    common::NamedTuple,
)
    return PowerTimeSeriesOpenAPIModels.DeterministicSingleTimeSeries(;
        common..., _openapi_forecast_columns(meta)...,
    )
end

function _openapi_association(
    ::Type{InfraStore.Probabilistic},
    meta::InfraStore.TimeSeriesMetadata,
    common::NamedTuple,
)
    return PowerTimeSeriesOpenAPIModels.Probabilistic(;
        common...,
        _openapi_forecast_columns(meta)...,
        percentiles = meta.percentiles,
    )
end

function _openapi_association(
    ::Type{InfraStore.Scenarios},
    meta::InfraStore.TimeSeriesMetadata,
    common::NamedTuple,
)
    return PowerTimeSeriesOpenAPIModels.Scenarios(;
        common...,
        _openapi_forecast_columns(meta)...,
        scenario_count = meta.length,
    )
end

"""
Convert one attachment row into its `SupplementalAttributeAssociation`.

The counterpart of the `TimeSeriesMetadata` method below, and the same contract: `attribute_id`
and `component_id` are the DOCUMENT's ids, which only the caller holds, so neither is read off
the row.

`attribute_type` and `component_type` ARE taken from the row. The store recorded both when the
attachment was made, so they are the same strings on both sides by construction; re-deriving
them from the objects would be a second source of truth for columns the store already answers.
"""
function to_openapi(
    row::InfraStore.SupplementalAttributeAssociation;
    attribute_id::Int,
    component_id::Int,
)
    return PowerCoreOpenAPIModels.SupplementalAttributeAssociation(;
        component_id = component_id,
        component_type = row.component_type,
        attribute_id = attribute_id,
        attribute_type = row.attribute_type,
    )
end

"""
Convert one catalog metadata row into its `TimeSeriesAssociation`.

`id` and `owner_id` are the DOCUMENT's ids, not the store's: the document numbers every
component and attribute from one counter, and only the caller holds that mapping. `address`
names the store the values live in — for a Sienna bundle, the sidecar's basename.
"""
function to_openapi(
    meta::InfraStore.TimeSeriesMetadata;
    id::Int,
    owner_id::Int,
    address::AbstractString,
)
    return PowerTimeSeriesOpenAPIModels.TimeSeriesAssociation(
        _openapi_association(
            meta.time_series_type,
            meta,
            _openapi_common(meta, id, owner_id, address),
        ),
    )
end
