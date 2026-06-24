#=
This file is auto-generated. Do not edit.
=#

#! format: off

"""
    mutable struct ProbabilisticMetadata <: ForecastMetadata
        name::String
        initial_timestamp::Dates.DateTime
        resolution::Dates.Period
        interval::Dates.Period
        count::Int
        percentiles::Vector{Float64}
        horizon::Dates.Period
        features::Dict{String, Union{Bool, Int, String}}
        internal::InfrastructureSystemsInternal
    end

A Probabilistic forecast for a particular data field in a Component.

# Arguments
- `name::String`: user-defined name
- `initial_timestamp::Dates.DateTime`: time series availability time
- `resolution::Dates.Period`:
- `interval::Dates.Period`: time step between forecast windows
- `count::Int`: number of forecast windows
- `percentiles::Vector{Float64}`: Percentiles for the probabilistic forecast
- `horizon::Dates.Period`: length of this time series
- `features::Dict{String, Union{Bool, Int, String}}`: (default: `Dict{String, Any}()`) User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years.
- `internal::InfrastructureSystemsInternal`:
"""
mutable struct ProbabilisticMetadata <: ForecastMetadata
    "user-defined name"
    name::String
    "time series availability time"
    initial_timestamp::Dates.DateTime
    resolution::Dates.Period
    "time step between forecast windows"
    interval::Dates.Period
    "number of forecast windows"
    count::Int
    "Percentiles for the probabilistic forecast"
    percentiles::Vector{Float64}
    "length of this time series"
    horizon::Dates.Period
    "User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years."
    features::Dict{String, Union{Bool, Int, String}}
    internal::InfrastructureSystemsInternal
end

function ProbabilisticMetadata(name, initial_timestamp, resolution, interval, count, percentiles, horizon, features=Dict{String, Any}(), )
    ProbabilisticMetadata(name, initial_timestamp, resolution, interval, count, percentiles, horizon, features, InfrastructureSystemsInternal(), )
end

function ProbabilisticMetadata(; name, initial_timestamp, resolution, interval, count, percentiles, horizon, features=Dict{String, Any}(), internal=InfrastructureSystemsInternal(), )
    ProbabilisticMetadata(name, initial_timestamp, resolution, interval, count, percentiles, horizon, features, internal, )
end

"""Get [`ProbabilisticMetadata`](@ref) `name`."""
get_name(value::ProbabilisticMetadata) = value.name
"""Get [`ProbabilisticMetadata`](@ref) `initial_timestamp`."""
get_initial_timestamp(value::ProbabilisticMetadata) = value.initial_timestamp
"""Get [`ProbabilisticMetadata`](@ref) `resolution`."""
get_resolution(value::ProbabilisticMetadata) = value.resolution
"""Get [`ProbabilisticMetadata`](@ref) `interval`."""
get_interval(value::ProbabilisticMetadata) = value.interval
"""Get [`ProbabilisticMetadata`](@ref) `count`."""
get_count(value::ProbabilisticMetadata) = value.count
"""Get [`ProbabilisticMetadata`](@ref) `percentiles`."""
get_percentiles(value::ProbabilisticMetadata) = value.percentiles
"""Get [`ProbabilisticMetadata`](@ref) `horizon`."""
get_horizon(value::ProbabilisticMetadata) = value.horizon
"""Get [`ProbabilisticMetadata`](@ref) `features`."""
get_features(value::ProbabilisticMetadata) = value.features
"""Get [`ProbabilisticMetadata`](@ref) `internal`."""
get_internal(value::ProbabilisticMetadata) = value.internal

"""Set [`ProbabilisticMetadata`](@ref) `name`."""
set_name!(value::ProbabilisticMetadata, val) = value.name = val
"""Set [`ProbabilisticMetadata`](@ref) `initial_timestamp`."""
set_initial_timestamp!(value::ProbabilisticMetadata, val) = value.initial_timestamp = val
"""Set [`ProbabilisticMetadata`](@ref) `resolution`."""
set_resolution!(value::ProbabilisticMetadata, val) = value.resolution = val
"""Set [`ProbabilisticMetadata`](@ref) `interval`."""
set_interval!(value::ProbabilisticMetadata, val) = value.interval = val
"""Set [`ProbabilisticMetadata`](@ref) `count`."""
set_count!(value::ProbabilisticMetadata, val) = value.count = val
"""Set [`ProbabilisticMetadata`](@ref) `percentiles`."""
set_percentiles!(value::ProbabilisticMetadata, val) = value.percentiles = val
"""Set [`ProbabilisticMetadata`](@ref) `horizon`."""
set_horizon!(value::ProbabilisticMetadata, val) = value.horizon = val
"""Set [`ProbabilisticMetadata`](@ref) `features`."""
set_features!(value::ProbabilisticMetadata, val) = value.features = val
"""Set [`ProbabilisticMetadata`](@ref) `internal`."""
set_internal!(value::ProbabilisticMetadata, val) = value.internal = val
