"""
Metadata describing a time series attached to a [`TimeSeriesOwners`](@ref) instance.

Users do not construct metadata directly. It is created by [`add_time_series!`](@ref) and
used internally to locate [`TimeSeriesData`](@ref) in [`TimeSeriesStorage`](@ref).

See also: [`ForecastMetadata`](@ref), [`StaticTimeSeriesMetadata`](@ref)
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

"""
Metadata for forecast (multi-window) time series.

Concrete subtypes are generated from descriptors (for example,
[`DeterministicMetadata`](@ref), [`ScenariosMetadata`](@ref)).

See also: [`TimeSeriesMetadata`](@ref), [`Forecast`](@ref)
"""
abstract type ForecastMetadata <: TimeSeriesMetadata end

"""
Metadata for static (single-window) time series.

See also: [`TimeSeriesMetadata`](@ref), [`StaticTimeSeries`](@ref),
[`SingleTimeSeriesMetadata`](@ref)
"""
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
Abstract type for time series arrays stored outside component structs.

Components and [`SupplementalAttribute`](@ref)s hold [`TimeSeriesMetadata`](@ref)
references so large arrays can live in [`TimeSeriesStorage`](@ref) instead of memory.

Required interface for subtypes:
  - `Base.length`
  - `check_time_series_data`
  - `get_resolution`
  - `make_time_array`
  - `eltype_data`

See also: [`TimeSeriesManager`](@ref), [`get_time_series`](@ref), [`Forecast`](@ref),
[`StaticTimeSeries`](@ref)
"""
abstract type TimeSeriesData <: InfrastructureSystemsType end

# Subtypes must implement
# - Base.length
# - check_time_series_data
# - get_resolution
# - make_time_array
# - eltype_data
