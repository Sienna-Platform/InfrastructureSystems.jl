function serialize(::Type{T}) where {T <: TimeSeriesData}
    # This currently cannot be done for all InfrastructureSystemsTypes.
    # Some are encoded directly as strings.
    @debug "serialize" _group = LOG_GROUP_SERIALIZATION T
    data = Dict{String, Any}()
    add_serialization_metadata!(data, T)
    return data
end
