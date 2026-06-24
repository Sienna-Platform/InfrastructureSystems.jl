#=
This file is auto-generated. Do not edit.
=#

#! format: off

"""
    mutable struct SingleTimeSeriesMetadata <: StaticTimeSeriesMetadata
        name::String
        resolution::Dates.Period
        initial_timestamp::Dates.DateTime
        length::Int
        features::Dict{String, Union{Bool, Int, String}}
        internal::InfrastructureSystemsInternal
    end

A TimeSeries Data object in contigous form.

# Arguments
- `name::String`: user-defined name
- `resolution::Dates.Period`:
- `initial_timestamp::Dates.DateTime`: time series availability time
- `length::Int`: length of this time series
- `features::Dict{String, Union{Bool, Int, String}}`: (default: `Dict{String, Any}()`) User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years.
- `internal::InfrastructureSystemsInternal`:
"""
mutable struct SingleTimeSeriesMetadata <: StaticTimeSeriesMetadata
    "user-defined name"
    name::String
    resolution::Dates.Period
    "time series availability time"
    initial_timestamp::Dates.DateTime
    "length of this time series"
    length::Int
    "User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years."
    features::Dict{String, Union{Bool, Int, String}}
    internal::InfrastructureSystemsInternal
end

function SingleTimeSeriesMetadata(name, resolution, initial_timestamp, length, features=Dict{String, Any}(), )
    SingleTimeSeriesMetadata(name, resolution, initial_timestamp, length, features, InfrastructureSystemsInternal(), )
end

function SingleTimeSeriesMetadata(; name, resolution, initial_timestamp, length, features=Dict{String, Any}(), internal=InfrastructureSystemsInternal(), )
    SingleTimeSeriesMetadata(name, resolution, initial_timestamp, length, features, internal, )
end

"""Get [`SingleTimeSeriesMetadata`](@ref) `name`."""
get_name(value::SingleTimeSeriesMetadata) = value.name
"""Get [`SingleTimeSeriesMetadata`](@ref) `resolution`."""
get_resolution(value::SingleTimeSeriesMetadata) = value.resolution
"""Get [`SingleTimeSeriesMetadata`](@ref) `initial_timestamp`."""
get_initial_timestamp(value::SingleTimeSeriesMetadata) = value.initial_timestamp
"""Get [`SingleTimeSeriesMetadata`](@ref) `length`."""
get_length(value::SingleTimeSeriesMetadata) = value.length
"""Get [`SingleTimeSeriesMetadata`](@ref) `features`."""
get_features(value::SingleTimeSeriesMetadata) = value.features
"""Get [`SingleTimeSeriesMetadata`](@ref) `internal`."""
get_internal(value::SingleTimeSeriesMetadata) = value.internal

"""Set [`SingleTimeSeriesMetadata`](@ref) `name`."""
set_name!(value::SingleTimeSeriesMetadata, val) = value.name = val
"""Set [`SingleTimeSeriesMetadata`](@ref) `resolution`."""
set_resolution!(value::SingleTimeSeriesMetadata, val) = value.resolution = val
"""Set [`SingleTimeSeriesMetadata`](@ref) `initial_timestamp`."""
set_initial_timestamp!(value::SingleTimeSeriesMetadata, val) = value.initial_timestamp = val
"""Set [`SingleTimeSeriesMetadata`](@ref) `length`."""
set_length!(value::SingleTimeSeriesMetadata, val) = value.length = val
"""Set [`SingleTimeSeriesMetadata`](@ref) `features`."""
set_features!(value::SingleTimeSeriesMetadata, val) = value.features = val
"""Set [`SingleTimeSeriesMetadata`](@ref) `internal`."""
set_internal!(value::SingleTimeSeriesMetadata, val) = value.internal = val
