const TimeSeriesOwners = Union{InfrastructureSystemsComponent, SupplementalAttribute}

"""
Supertype for keys that can be used to access a desired time series dataset

Concrete subtypes:
- [`StaticTimeSeriesKey`](@ref)
- [`NonSequentialTimeSeriesKey`](@ref)
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
get_initial_timestamp(key::TimeSeriesKey) = key.initial_timestamp
get_features(key::TimeSeriesKey) = key.features

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

# A static key has no forecast interval and represents a single window.
get_length(key::StaticTimeSeriesKey) = key.length
get_interval(::StaticTimeSeriesKey) = nothing
get_count(::StaticTimeSeriesKey) = 1
Base.length(key::StaticTimeSeriesKey) = get_length(key)

"""
A unique key to identify and retrieve a [`NonSequentialTimeSeries`](@ref)

Unlike [`StaticTimeSeriesKey`](@ref), a non-sequential series is irregular: it has
no `resolution` and no regular `initial_timestamp` (its timestamps are stored with
the data), so the key carries only its `length`. This mirrors the dedicated
non-sequential key in the time-series-store backend.

See: [`get_time_series_keys`](@ref) and [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
@kwdef struct NonSequentialTimeSeriesKey <: TimeSeriesKey
    time_series_type::Type{<:NonSequentialTimeSeries}
    name::String
    length::Int
    features::Dict{String, Any}
end

# A non-sequential key is irregular: no resolution, no regular initial timestamp,
# no forecast interval; it represents a single window.
get_length(key::NonSequentialTimeSeriesKey) = key.length
get_resolution(::NonSequentialTimeSeriesKey) = nothing
get_initial_timestamp(::NonSequentialTimeSeriesKey) = nothing
get_interval(::NonSequentialTimeSeriesKey) = nothing
get_count(::NonSequentialTimeSeriesKey) = 1
Base.length(key::NonSequentialTimeSeriesKey) = get_length(key)

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

get_horizon(key::ForecastKey) = key.horizon
get_interval(key::ForecastKey) = key.interval
get_count(key::ForecastKey) = key.count
get_horizon_count(key::ForecastKey) =
    get_horizon_count(get_horizon(key), get_resolution(key))
Base.length(key::ForecastKey) = get_horizon_count(key)

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
