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
Abstract type for time series stored in the system.
Components reference this data through a [`TimeSeriesKey`](@ref); the data itself is held
by the `time-series-store` backend so it can reside on storage media instead of memory.
"""
abstract type TimeSeriesData <: InfrastructureSystemsType end

# Subtypes must implement
# - Base.length
# - check_time_series_data
# - get_resolution
# - make_time_array
# - eltype_data
