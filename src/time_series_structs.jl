const TimeSeriesOwners = Union{InfrastructureSystemsComponent, SupplementalAttribute}

"""
Supertype for keys that can be used to access a desired time series dataset

The concrete subtypes are a closed set — [`StaticTimeSeriesKey`](@ref),
[`NonSequentialTimeSeriesKey`](@ref), and [`ForecastKey`](@ref), collected in
`ConcreteTimeSeriesKey`. Keys are produced by IS (e.g. `add_time_series!`,
`get_time_series_keys`), never constructed by users, and key-carrying structs
store the `ConcreteTimeSeriesKey` union, so a foreign subtype cannot flow
through the key-addressed paths (reads, removal, copy, hashing).

Every concrete key implements the interface below, which generic key-consuming
code may call on any key:
- `get_name`
- `get_resolution` — `nothing` for a key with no regular resolution
- `get_time_series_type`
- `get_interval` — `nothing` for a key that is not a forecast
- `get_features`
- `get_initial_timestamp` — `nothing` for a key with no regular initial timestamp
- `get_count`, `Base.length`

The default methods rely on the field names `name`, `time_series_type`,
`resolution`, `initial_timestamp`, and `features`; each concrete key defines
the methods its fields don't cover (as [`NonSequentialTimeSeriesKey`](@ref)
does).
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
non-sequential key in the InfraStore backend.

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

# All concrete key types, for use in struct fields: a `Union` of concrete types
# union-splits (no boxing / dynamic dispatch in per-timestep paths), unlike the
# abstract `TimeSeriesKey`.
const ConcreteTimeSeriesKey =
    Union{StaticTimeSeriesKey, NonSequentialTimeSeriesKey, ForecastKey}

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
