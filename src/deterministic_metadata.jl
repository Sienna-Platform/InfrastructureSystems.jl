function DeterministicMetadata(ts::AbstractDeterministic; features...)
    return DeterministicMetadata(
        get_name(ts),
        get_resolution(ts),
        get_initial_timestamp(ts),
        get_interval(ts),
        get_count(ts),
        get_horizon(ts),
        typeof(ts),
        Dict{String, Any}(string(k) => v for (k, v) in features),
    )
end

function serialize(::Type{T}) where {T <: TimeSeriesData}
    # This currently cannot be done for all InfrastructureSystemsTypes.
    # Some are encoded directly as strings.
    @debug "serialize" _group = LOG_GROUP_SERIALIZATION T
    data = Dict{String, Any}()
    add_serialization_metadata!(data, T)
    return data
end

function deserialize_to_dict(::Type{T}, data::Dict) where {T <: DeterministicMetadata}
    # This is custom because of time_series_type.
    # Duplicated from src/serialization.jl
    vals = Dict{Symbol, Any}()
    for (field_name, field_type) in zip(fieldnames(T), fieldtypes(T))
        val = data[string(field_name)]
        if val isa Dict && haskey(val, METADATA_KEY)
            metadata = get_serialization_metadata(val)
            if haskey(metadata, FUNCTION_KEY)
                vals[field_name] = deserialize(Function, val)
            else
                type = get_type_from_serialization_metadata(metadata)
                if field_name == :time_series_type
                    vals[field_name] = type
                else
                    vals[field_name] = deserialize(type, val)
                end
            end
        else
            vals[field_name] = deserialize(field_type, val)
        end
    end
    return vals
end
