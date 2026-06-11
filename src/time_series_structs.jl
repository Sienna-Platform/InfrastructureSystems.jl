const TimeSeriesOwners = Union{InfrastructureSystemsComponent, SupplementalAttribute}

"""
Supertype for keys that can be used to access a desired time series dataset

Concrete subtypes:
- [`StaticTimeSeriesKey`](@ref)
- [`ForecastKey`](@ref)

Required methods:
- `get_name`
- `get_resolution`
- `get_time_series_type`
The default methods rely on the field names `name` and `time_series_type`.
"""
abstract type TimeSeriesKey <: InfrastructureSystemsType end

get_name(key::TimeSeriesKey) = key.name
get_resolution(key::TimeSeriesKey) = key.resolution
get_time_series_type(key::TimeSeriesKey) = key.time_series_type

function deserialize_struct(T::Type{<:TimeSeriesKey}, data::Dict)
    vals = Dict{Symbol, Any}()
    for (field_name, field_type) in zip(fieldnames(T), fieldtypes(T))
        val = data[string(field_name)]
        if field_type <: Type{<:TimeSeriesData}
            metadata = get_serialization_metadata(val)
            val = get_type_from_serialization_metadata(metadata)
        else
            val = deserialize(field_type, val)
        end
        vals[field_name] = val
    end
    return T(; vals...)
end

"""
A unique key to identify and retrieve a [`StaticTimeSeries`](@ref)

See: [`get_time_series_keys`](@ref) and [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
@kwdef struct StaticTimeSeriesKey <: TimeSeriesKey
    time_series_type::Type{<:StaticTimeSeries}
    name::String
    initial_timestamp::Dates.DateTime
    resolution::Dates.Period
    length::Int
    features::Dict{String, Any}
end

function make_time_series_key(metadata::StaticTimeSeriesMetadata)
    return StaticTimeSeriesKey(;
        time_series_type = time_series_metadata_to_data(metadata),
        name = get_name(metadata),
        initial_timestamp = get_initial_timestamp(metadata),
        resolution = get_resolution(metadata),
        length = get_length(metadata),
        features = get_features(metadata),
    )
end

"""
A unique key to identify and retrieve a [`Forecast`](@ref)

See: [`get_time_series_keys`](@ref) and [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
@kwdef struct ForecastKey <: TimeSeriesKey
    time_series_type::Type{<:Forecast}
    name::String
    initial_timestamp::Dates.DateTime
    resolution::Dates.Period
    horizon::Dates.Period
    interval::Dates.Period
    count::Int
    features::Dict{String, Any}
end

# All concrete key types, for use in struct fields: a `Union` of concrete types
# union-splits (no boxing / dynamic dispatch in per-timestep paths), unlike the
# abstract `TimeSeriesKey`.
const ConcreteTimeSeriesKey = Union{StaticTimeSeriesKey, ForecastKey}

function make_time_series_key(metadata::ForecastMetadata)
    return ForecastKey(;
        time_series_type = time_series_metadata_to_data(metadata),
        name = get_name(metadata),
        initial_timestamp = get_initial_timestamp(metadata),
        resolution = get_resolution(metadata),
        horizon = get_horizon(metadata),
        interval = get_interval(metadata),
        count = get_count(metadata),
        features = get_features(metadata),
    )
end

"""
Provides counts of time series including attachments to components and supplemental
attributes.
"""
@kwdef struct TimeSeriesCounts
    components_with_time_series::Int
    supplemental_attributes_with_time_series::Int
    static_time_series_count::Int
    forecast_count::Int
end

"""
Defines an association between a time series owner (component or supplemental attribute)
and the time series metadata.

# Examples
```julia
association1 = TimeSeriesAssociation(component, time_series)
association2 = TimeSeriesAssociation(component, time_series, scenario = "high")
```
"""
struct TimeSeriesAssociation
    owner::TimeSeriesOwners
    time_series::TimeSeriesData
    features::Dict{Symbol, Any}
end

function TimeSeriesAssociation(owner, time_series; features...)
    return TimeSeriesAssociation(owner, time_series, features)
end

function TimeSeriesAssociation(owner, time_series, features::Dict{String, Any})
    return TimeSeriesAssociation(
        owner,
        time_series,
        Dict{Symbol, Any}(Symbol(k) => v for (k, v) in features),
    )
end
