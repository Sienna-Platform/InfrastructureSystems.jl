#=
This file is auto-generated. Do not edit.
=#

#! format: off

"""
    mutable struct ScenariosMetadata <: ForecastMetadata
        name::String
        resolution::Dates.Period
        initial_timestamp::Dates.DateTime
        interval::Dates.Period
        scenario_count::Int64
        count::Int
        horizon::Dates.Period
        features::Dict{String, Union{Bool, Int, String}}
        internal::InfrastructureSystemsInternal
    end

A Discrete Scenario Based time series for a particular data field in a Component.

# Arguments
- `name::String`: user-defined name
- `resolution::Dates.Period`:
- `initial_timestamp::Dates.DateTime`: time series availability time
- `interval::Dates.Period`: time step between forecast windows
- `scenario_count::Int64`: Number of scenarios
- `count::Int`: number of forecast windows
- `horizon::Dates.Period`: length of this time series
- `features::Dict{String, Union{Bool, Int, String}}`: (default: `Dict{String, Any}()`) User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years.
- `internal::InfrastructureSystemsInternal`:
"""
mutable struct ScenariosMetadata <: ForecastMetadata
    "user-defined name"
    name::String
    resolution::Dates.Period
    "time series availability time"
    initial_timestamp::Dates.DateTime
    "time step between forecast windows"
    interval::Dates.Period
    "Number of scenarios"
    scenario_count::Int64
    "number of forecast windows"
    count::Int
    "length of this time series"
    horizon::Dates.Period
    "User-defined tags that differentiate multiple time series arrays that represent the same component attribute, such as different arrays for different scenarios or years."
    features::Dict{String, Union{Bool, Int, String}}
    internal::InfrastructureSystemsInternal
end

function ScenariosMetadata(name, resolution, initial_timestamp, interval, scenario_count, count, horizon, features=Dict{String, Any}(), )
    ScenariosMetadata(name, resolution, initial_timestamp, interval, scenario_count, count, horizon, features, InfrastructureSystemsInternal(), )
end

function ScenariosMetadata(; name, resolution, initial_timestamp, interval, scenario_count, count, horizon, features=Dict{String, Any}(), internal=InfrastructureSystemsInternal(), )
    ScenariosMetadata(name, resolution, initial_timestamp, interval, scenario_count, count, horizon, features, internal, )
end

"""Get [`ScenariosMetadata`](@ref) `name`."""
get_name(value::ScenariosMetadata) = value.name
"""Get [`ScenariosMetadata`](@ref) `resolution`."""
get_resolution(value::ScenariosMetadata) = value.resolution
"""Get [`ScenariosMetadata`](@ref) `initial_timestamp`."""
get_initial_timestamp(value::ScenariosMetadata) = value.initial_timestamp
"""Get [`ScenariosMetadata`](@ref) `interval`."""
get_interval(value::ScenariosMetadata) = value.interval
"""Get [`ScenariosMetadata`](@ref) `scenario_count`."""
get_scenario_count(value::ScenariosMetadata) = value.scenario_count
"""Get [`ScenariosMetadata`](@ref) `count`."""
get_count(value::ScenariosMetadata) = value.count
"""Get [`ScenariosMetadata`](@ref) `horizon`."""
get_horizon(value::ScenariosMetadata) = value.horizon
"""Get [`ScenariosMetadata`](@ref) `features`."""
get_features(value::ScenariosMetadata) = value.features
"""Get [`ScenariosMetadata`](@ref) `internal`."""
get_internal(value::ScenariosMetadata) = value.internal

"""Set [`ScenariosMetadata`](@ref) `name`."""
set_name!(value::ScenariosMetadata, val) = value.name = val
"""Set [`ScenariosMetadata`](@ref) `resolution`."""
set_resolution!(value::ScenariosMetadata, val) = value.resolution = val
"""Set [`ScenariosMetadata`](@ref) `initial_timestamp`."""
set_initial_timestamp!(value::ScenariosMetadata, val) = value.initial_timestamp = val
"""Set [`ScenariosMetadata`](@ref) `interval`."""
set_interval!(value::ScenariosMetadata, val) = value.interval = val
"""Set [`ScenariosMetadata`](@ref) `scenario_count`."""
set_scenario_count!(value::ScenariosMetadata, val) = value.scenario_count = val
"""Set [`ScenariosMetadata`](@ref) `count`."""
set_count!(value::ScenariosMetadata, val) = value.count = val
"""Set [`ScenariosMetadata`](@ref) `horizon`."""
set_horizon!(value::ScenariosMetadata, val) = value.horizon = val
"""Set [`ScenariosMetadata`](@ref) `features`."""
set_features!(value::ScenariosMetadata, val) = value.features = val
"""Set [`ScenariosMetadata`](@ref) `internal`."""
set_internal!(value::ScenariosMetadata, val) = value.internal = val
