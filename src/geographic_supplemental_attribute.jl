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
Check that `geo_json` is actually GeoJSON, by parsing it.

An empty dictionary passes: it is the documented default and means no geographic information
was recorded, which is different from recording something malformed. Anything else must parse
as a GeoJSON object, so a typo'd `type` or a coordinate list of the wrong shape is caught
where it is introduced rather than surfacing much later in whatever consumes the geometry.

The parse result is discarded — `GeoJSON` reads coordinates as `Float32`, and the stored
value stays the caller's own dictionary rather than a lossy round-trip of it.
"""
function validate_geo_json(geo_json::Dict{String, <:Any})
    isempty(geo_json) && return nothing
    try
        GeoJSON.read(JSON.json(geo_json))
    catch e
        throw(
            ArgumentError(
                "GeographicInfo.geo_json is not valid GeoJSON: $(sprint(showerror, e)). " *
                "Pass an empty dictionary to record no geographic information.",
            ),
        )
    end
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

"""
    get_uuid(geo::GeographicInfo)

Get the UUID from a [`GeographicInfo`](@ref) attribute.

# Arguments
 - `geo::GeographicInfo`: the [`GeographicInfo`](@ref) attribute
"""
get_uuid(geo::GeographicInfo) = get_uuid(get_internal(geo))
