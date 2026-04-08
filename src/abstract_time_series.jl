"""
Abstract type for time_series that are stored in a system.
Users never create them or get access to them.
Stores references to TimeSeriesData.
"""
abstract type TimeSeriesMetadata <: InfrastructureSystemsType end

function make_unique_owner_metadata_identifer(owner, metadata::TimeSeriesMetadata)
    return (
        summary(owner),
        strip_module_name(time_series_metadata_to_data(metadata)),
        get_name(metadata),
        make_features_string(metadata.features),
    )
end

function make_features_string(features::Dict{String, Union{Bool, Int, String}})
    key_names = sort!(collect(keys(features)))
    data = [Dict(k => features[k]) for k in key_names]
    return JSON3.write(data)
end

function make_features_string(; features...)
    key_names = sort!(collect(string.(keys(features))))
    data = [Dict(k => features[Symbol(k)]) for (k) in key_names]
    return JSON3.write(data)
end

abstract type ForecastMetadata <: TimeSeriesMetadata end

abstract type StaticTimeSeriesMetadata <: TimeSeriesMetadata end

get_interval(::StaticTimeSeriesMetadata) = nothing
get_count(ts::StaticTimeSeriesMetadata) = 1
get_initial_timestamp(ts::StaticTimeSeriesMetadata) = get_initial_timestamp(ts)
Base.length(ts::StaticTimeSeriesMetadata) = get_length(ts)
Base.length(ts::ForecastMetadata) = get_horizon_count(ts)

function get_horizon_count(metadata::ForecastMetadata)
    return get_horizon_count(get_horizon(metadata), get_resolution(metadata))
end

"""
Abstract type for time series stored in the system.
Components store references to these through TimeSeriesMetadata values so that data can
reside on storage media instead of memory.
"""
abstract type TimeSeriesData <: InfrastructureSystemsType end

# Subtypes must implement
# - Base.length
# - check_time_series_data
# - get_resolution
# - make_time_array
# - eltype_data
