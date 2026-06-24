#=
This file is auto-generated. Do not edit.
=#

#! format: off

"""
    mutable struct DeterministicMetadata <: ForecastMetadata
        name::String
        resolution::Dates.Period
        initial_timestamp::Dates.DateTime
        interval::Dates.Period
        count::Int
        horizon::Dates.Period
        time_series_type::Type{<:AbstractDeterministic}
        features::Dict{String, Union{Bool, Int, String}}
        internal::InfrastructureSystemsInternal
    end

A deterministic forecast for a particular data field in a Component.

# Arguments
- `name::String`: user-defined name
- `resolution::Dates.Period`:
- `initial_timestamp::Dates.DateTime`: time series availability time
- `interval::Dates.Period`: time step between forecast windows
- `count::Int`: number of forecast windows
- `horizon::Dates.Period`: length of this time series
- `time_series_type::Type{<:AbstractDeterministic}`: Type of the time series data associated with this metadata.
- `features::Dict{String, Union{Bool, Int, String}}`: (default: `Dict{String, Any}()`) User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years.
- `internal::InfrastructureSystemsInternal`:
"""
mutable struct DeterministicMetadata <: ForecastMetadata
    "user-defined name"
    name::String
    resolution::Dates.Period
    "time series availability time"
    initial_timestamp::Dates.DateTime
    "time step between forecast windows"
    interval::Dates.Period
    "number of forecast windows"
    count::Int
    "length of this time series"
    horizon::Dates.Period
    "Type of the time series data associated with this metadata."
    time_series_type::Type{<:AbstractDeterministic}
    "User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years."
    features::Dict{String, Union{Bool, Int, String}}
    internal::InfrastructureSystemsInternal
end

function DeterministicMetadata(name, resolution, initial_timestamp, interval, count, horizon, time_series_type, features=Dict{String, Any}(), )
    DeterministicMetadata(name, resolution, initial_timestamp, interval, count, horizon, time_series_type, features, InfrastructureSystemsInternal(), )
end

function DeterministicMetadata(; name, resolution, initial_timestamp, interval, count, horizon, time_series_type, features=Dict{String, Any}(), internal=InfrastructureSystemsInternal(), )
    DeterministicMetadata(name, resolution, initial_timestamp, interval, count, horizon, time_series_type, features, internal, )
end

"""Get [`DeterministicMetadata`](@ref) `name`."""
get_name(value::DeterministicMetadata) = value.name
"""Get [`DeterministicMetadata`](@ref) `resolution`."""
get_resolution(value::DeterministicMetadata) = value.resolution
"""Get [`DeterministicMetadata`](@ref) `initial_timestamp`."""
get_initial_timestamp(value::DeterministicMetadata) = value.initial_timestamp
"""Get [`DeterministicMetadata`](@ref) `interval`."""
get_interval(value::DeterministicMetadata) = value.interval
"""Get [`DeterministicMetadata`](@ref) `count`."""
get_count(value::DeterministicMetadata) = value.count
"""Get [`DeterministicMetadata`](@ref) `horizon`."""
get_horizon(value::DeterministicMetadata) = value.horizon
"""Get [`DeterministicMetadata`](@ref) `time_series_type`."""
get_time_series_type(value::DeterministicMetadata) = value.time_series_type
"""Get [`DeterministicMetadata`](@ref) `features`."""
get_features(value::DeterministicMetadata) = value.features
"""Get [`DeterministicMetadata`](@ref) `internal`."""
get_internal(value::DeterministicMetadata) = value.internal

"""Set [`DeterministicMetadata`](@ref) `name`."""
set_name!(value::DeterministicMetadata, val) = value.name = val
"""Set [`DeterministicMetadata`](@ref) `resolution`."""
set_resolution!(value::DeterministicMetadata, val) = value.resolution = val
"""Set [`DeterministicMetadata`](@ref) `initial_timestamp`."""
set_initial_timestamp!(value::DeterministicMetadata, val) = value.initial_timestamp = val
"""Set [`DeterministicMetadata`](@ref) `interval`."""
set_interval!(value::DeterministicMetadata, val) = value.interval = val
"""Set [`DeterministicMetadata`](@ref) `count`."""
set_count!(value::DeterministicMetadata, val) = value.count = val
"""Set [`DeterministicMetadata`](@ref) `horizon`."""
set_horizon!(value::DeterministicMetadata, val) = value.horizon = val
"""Set [`DeterministicMetadata`](@ref) `time_series_type`."""
set_time_series_type!(value::DeterministicMetadata, val) = value.time_series_type = val
"""Set [`DeterministicMetadata`](@ref) `features`."""
set_features!(value::DeterministicMetadata, val) = value.features = val
"""Set [`DeterministicMetadata`](@ref) `internal`."""
set_internal!(value::DeterministicMetadata, val) = value.internal = val
