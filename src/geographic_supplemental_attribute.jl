"""
    GeographicInfo <: SupplementalAttribute

Supplemental attribute to store geographic information about system components in GeoJSON format.

# Arguments
 - `geo_json::Dict{String, Any}`: dictionary containing GeoJSON data representing the geographic
   information of the component
 - `internal::InfrastructureSystemsInternal`: internal infrastructure systems data for managing
   metadata and UUID tracking
"""
struct GeographicInfo <: SupplementalAttribute
    geo_json::Dict{String, Any}
    internal::InfrastructureSystemsInternal

    function GeographicInfo(geo_json::Dict{String, <:Any}, internal)
        validate_geo_json(geo_json)
        return new(geo_json, internal)
    end
end

"""
Whether a parsed GeoJSON object carries the member its type requires.

Parsing alone does not establish this: `GeoJSON.read` accepts `{"type": "Point"}` with no
`coordinates` at all, and `{"type": "Feature"}` with no `geometry`, returning an object whose
required member is `nothing` rather than raising. Both are structurally invalid GeoJSON, so
they are rejected here instead of reaching a consumer that then has to cope with a geometry
that has no coordinates.

Dispatched per shape rather than branching on `type`, so each accessor is only ever applied
to the object it is defined for. The fallback is `true` — parsing succeeded and the shape is
one this function does not have a rule for, which is not grounds to reject it.
"""
_geo_json_complete(x::GeoJSON.AbstractGeometry) = !isnothing(GeoJSON.coordinates(x))
_geo_json_complete(x::GeoJSON.GeometryCollection) = !isnothing(GeoJSON.geometry(x))
_geo_json_complete(x::GeoJSON.Feature) = !isnothing(GeoJSON.geometry(x))
_geo_json_complete(x::GeoJSON.AbstractFeatureCollection) = !isnothing(GeoJSON.features(x))
_geo_json_complete(::Any) = true

"""
Check that `geo_json` is actually GeoJSON, by parsing it and confirming it is structurally
complete.

An empty dictionary passes: it is the documented default and means no geographic information
was recorded, which is different from recording something malformed. Anything else must parse
as a GeoJSON object *and* carry the member its type requires, so a typo'd `type`, a coordinate
list of the wrong shape, and a geometry missing its coordinates outright are all caught where
they are introduced rather than surfacing much later in whatever consumes the geometry.

The parse result is discarded — `GeoJSON` reads coordinates as `Float32`, and the stored
value stays the caller's own dictionary rather than a lossy round-trip of it.
"""
function validate_geo_json(geo_json::Dict{String, <:Any})
    isempty(geo_json) && return nothing
    parsed = try
        GeoJSON.read(JSON.json(geo_json))
    catch e
        throw(
            ArgumentError(
                "GeographicInfo.geo_json is not valid GeoJSON: $(sprint(showerror, e)). " *
                "Pass an empty dictionary to record no geographic information.",
            ),
        )
    end
    _geo_json_complete(parsed) || throw(
        ArgumentError(
            "GeographicInfo.geo_json parses as $(nameof(typeof(parsed))) but is missing the " *
            "member that type requires (`coordinates` for a geometry, `geometry` for a " *
            "Feature, `features` for a FeatureCollection). Pass an empty dictionary to " *
            "record no geographic information.",
        ),
    )
    return nothing
end

"""
    GeographicInfo(; geo_json, internal)

Construct a [`GeographicInfo`](@ref) supplemental attribute.

# Arguments
 - `geo_json::Dict{String, Any}`: dictionary containing GeoJSON data. Defaults to an empty
   dictionary if not provided
 - `internal::InfrastructureSystemsInternal`: internal infrastructure systems data. Defaults to
   a new InfrastructureSystemsInternal instance if not provided

# Example
```julia
# Create with default empty geo_json
geo_info = GeographicInfo()

# Create with specific geo_json data
geo_data = Dict("type" => "Point", "coordinates" => [1.0, 2.0])
geo_info = GeographicInfo(geo_json = geo_data)
```
"""
function GeographicInfo(;
    geo_json::Dict{String, <:Any} = Dict{String, Any}(),
    internal = InfrastructureSystemsInternal(),
)
    return GeographicInfo(geo_json, internal)
end

"""
    get_geo_json(geo::GeographicInfo)

Get the GeoJSON dictionary from a [`GeographicInfo`](@ref) attribute.

# Arguments
 - `geo::GeographicInfo`: the [`GeographicInfo`](@ref) attribute
"""
get_geo_json(geo::GeographicInfo) = geo.geo_json

"""
    get_internal(geo::GeographicInfo)

Get the internal infrastructure systems data from a [`GeographicInfo`](@ref) attribute.

# Arguments
 - `geo::GeographicInfo`: the [`GeographicInfo`](@ref) attribute
"""
get_internal(geo::GeographicInfo) = geo.internal
