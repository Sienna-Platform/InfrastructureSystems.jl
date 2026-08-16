"""
    mutable struct DataSource <: SupplementalAttribute

A supplemental attribute recording the provenance of component data: the publishing
organization, dataset, URL, version (vintage), publication and retrieval timestamps,
confidence, the user/agent that recorded the value, and the component field names the
record applies to. Attach one instance to many components to avoid repeated entries.

# Arguments
$(DocStringExtensions.TYPEDFIELDS)
"""
mutable struct DataSource <: SupplementalAttribute
    "Publishing organization (required), e.g. \"U.S. Energy Information Administration\"."
    organization::String
    "When the data was retrieved (required)."
    retrieved_at::Dates.DateTime
    "Dataset identifier, e.g. \"EIA-860 2023, Schedule 3\"."
    dataset::String
    "Source URL."
    url::String
    "Data version / vintage, e.g. \"2023 final\"."
    version::String
    "When the source published the data; `nothing` if unknown."
    published_at::Union{Nothing, Dates.DateTime}
    "Confidence qualifier, e.g. \"high\", \"medium\"."
    confidence::String
    "User or agent that recorded the value; `nothing` if unrecorded."
    recorded_by::Union{Nothing, String}
    "Component field names this record applies to (no meaning is attached by IS)."
    fields::Vector{String}
    "Escape hatch for additional, evolving provenance keys."
    extra::Dict{String, Any}
    internal::InfrastructureSystemsInternal
end

function DataSource(;
    organization::String,
    retrieved_at::Dates.DateTime,
    fields::Vector{String},
    dataset::String = "",
    url::String = "",
    version::String = "",
    published_at::Union{Nothing, Dates.DateTime} = nothing,
    confidence::String = "",
    recorded_by::Union{Nothing, String} = nothing,
    extra::Dict{String, Any} = Dict{String, Any}(),
    internal::InfrastructureSystemsInternal = InfrastructureSystemsInternal(),
)
    return DataSource(
        organization,
        retrieved_at,
        dataset,
        url,
        version,
        published_at,
        confidence,
        recorded_by,
        fields,
        extra,
        internal,
    )
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the publishing organization.
"""
get_organization(ds::DataSource) = ds.organization

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the publishing organization.
"""
function set_organization!(ds::DataSource, val::String)
    ds.organization = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the retrieval timestamp.
"""
get_retrieved_at(ds::DataSource) = ds.retrieved_at

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the retrieval timestamp.
"""
function set_retrieved_at!(ds::DataSource, val::Dates.DateTime)
    ds.retrieved_at = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the dataset identifier.
"""
get_dataset(ds::DataSource) = ds.dataset

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the dataset identifier.
"""
function set_dataset!(ds::DataSource, val::String)
    ds.dataset = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the source URL.
"""
get_url(ds::DataSource) = ds.url

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the source URL.
"""
function set_url!(ds::DataSource, val::String)
    ds.url = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the data version (vintage).
"""
get_version(ds::DataSource) = ds.version

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the data version (vintage).
"""
function set_version!(ds::DataSource, val::String)
    ds.version = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the confidence qualifier.
"""
get_confidence(ds::DataSource) = ds.confidence

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the confidence qualifier.
"""
function set_confidence!(ds::DataSource, val::String)
    ds.confidence = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the component field names this record applies to.
"""
get_fields(ds::DataSource) = ds.fields

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the component field names this record applies to.
"""
function set_fields!(ds::DataSource, val::Vector{String})
    ds.fields = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Append a component field name to `fields`.
"""
function add_field!(ds::DataSource, name::String)
    push!(ds.fields, name)
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the extra provenance dictionary.
"""
get_extra(ds::DataSource) = ds.extra

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the extra provenance dictionary.
"""
function set_extra!(ds::DataSource, val::Dict{String, Any})
    ds.extra = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return `true` if `published_at` is set.
"""
has_published_at(ds::DataSource) = _has_published_at(ds.published_at)
_has_published_at(::Nothing) = false
_has_published_at(::Dates.DateTime) = true

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the publication timestamp. Guard with [`has_published_at`](@ref) — throws if unset.
"""
get_published_at(ds::DataSource) = _get_published_at(ds.published_at)
_get_published_at(val::Dates.DateTime) = val
function _get_published_at(::Nothing)
    throw(
        ArgumentError(
            "published_at is not set on this DataSource; guard with has_published_at",
        ),
    )
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the publication timestamp.
"""
function set_published_at!(ds::DataSource, val::Dates.DateTime)
    ds.published_at = val
    return nothing
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return `true` if `recorded_by` is set.
"""
has_recorded_by(ds::DataSource) = _has_recorded_by(ds.recorded_by)
_has_recorded_by(::Nothing) = false
_has_recorded_by(::String) = true

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Return the recorder. Guard with [`has_recorded_by`](@ref) — throws if unset.
"""
get_recorded_by(ds::DataSource) = _get_recorded_by(ds.recorded_by)
_get_recorded_by(val::String) = val
function _get_recorded_by(::Nothing)
    throw(
        ArgumentError(
            "recorded_by is not set on this DataSource; guard with has_recorded_by",
        ),
    )
end

"""
$(DocStringExtensions.TYPEDSIGNATURES)
Set the recorder.
"""
function set_recorded_by!(ds::DataSource, val::String)
    ds.recorded_by = val
    return nothing
end

get_internal(ds::DataSource) = ds.internal
get_uuid(ds::DataSource) = get_uuid(get_internal(ds))
