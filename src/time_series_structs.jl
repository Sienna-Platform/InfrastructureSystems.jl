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
- `get_owner_id`
- `get_owner_category`
- `get_association_id` — the store-minted surrogate id of the stored association
- `get_name`
- `get_resolution` — `nothing` for a key with no regular resolution
- `get_time_series_type`
- `get_interval` — `nothing` for a key that is not a forecast
- `get_features`
- `get_initial_timestamp` — `nothing` for a key with no regular initial timestamp
- `get_count`, `Base.length`

The default methods rely on the field names `owner_id`, `owner_category`,
`association_id`, `name`, `time_series_type`, `resolution`,
`initial_timestamp`, `features`, and `length`, and default to a single window
with no interval; each concrete key defines the methods its fields don't cover
(as [`NonSequentialTimeSeriesKey`](@ref) does).
"""
abstract type TimeSeriesKey <: InfrastructureSystemsType end

get_owner_id(key::TimeSeriesKey) = key.owner_id
get_owner_category(key::TimeSeriesKey) = key.owner_category
get_association_id(key::TimeSeriesKey) = key.association_id
get_name(key::TimeSeriesKey) = key.name
get_resolution(key::TimeSeriesKey) = key.resolution
get_time_series_type(key::TimeSeriesKey) = key.time_series_type
get_initial_timestamp(key::TimeSeriesKey) = key.initial_timestamp
get_features(key::TimeSeriesKey) = key.features

"""
Return the number of values one window of the series holds, so `get_length` and
`Base.length` agree for every key type. A [`ForecastKey`](@ref) has no `length` field: for
it this is the horizon count (the per-window length), **not** the number of windows — use
[`get_count`](@ref) for that.
"""
get_length(key::TimeSeriesKey) = key.length

# A key represents a single window unless it is a forecast.
get_interval(::TimeSeriesKey) = nothing
get_count(::TimeSeriesKey) = 1
Base.length(key::TimeSeriesKey) = get_length(key)

# The store a deserialization resolves association ids against. A key travels as its
# association id alone, so rebuilding one needs the catalog that minted it; the
# `deserialize` signatures are fixed by callers outside IS, so the store arrives out of
# band rather than as an argument.
const DESERIALIZATION_STORE = Base.ScopedValues.ScopedValue{Store}()

"Whether a store is bound for the current deserialization scope."
has_deserialization_store() =
    !isnothing(Base.ScopedValues.get(DESERIALIZATION_STORE))

"The store bound by the innermost enclosing [`with_deserialization_store`](@ref)."
get_deserialization_store() = DESERIALIZATION_STORE[]

"""
    with_deserialization_store(f, store::Store)

Run `f()` with `store` bound as the catalog that [`TimeSeriesKey`](@ref)
deserialization resolves association ids against, and return its result.

A serialized key is nothing but its `association_id`, so anything that
deserializes a key-carrying struct — a component with a time-series-backed cost
curve, a supplemental attribute — has to run inside this block. `deserialize` of a
[`SystemData`](@ref) binds the store it just opened around its own work; a parent
package that deserializes components itself must wrap that pass in this function.
"""
function with_deserialization_store(f, store::Store)
    return Base.ScopedValues.with(f, DESERIALIZATION_STORE => store)
end

"""
A key serializes to its `association_id` alone. The id is the store-minted surrogate
for the whole association, so every other field of the key is a copy of something the
catalog already holds; writing them out invites the two to disagree.
"""
serialize(key::TimeSeriesKey) = get_association_id(key)

"""
Rebuild a key from the association id it serialized to, against the store bound by
[`with_deserialization_store`](@ref).
"""
function deserialize(::Type{<:TimeSeriesKey}, association_id::Integer)
    has_deserialization_store() || throw(
        ArgumentError(
            "Deserializing a TimeSeriesKey needs the store that minted " *
            "association_id=$association_id; run the deserialization inside " *
            "`with_deserialization_store`.",
        ),
    )
    return get_time_series_key(get_deserialization_store(), Int(association_id))
end

"""
A unique key to identify and retrieve a [`StaticTimeSeries`](@ref)

See: [`get_time_series_keys`](@ref) and [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
@kwdef struct StaticTimeSeriesKey <: TimeSeriesKey
    owner_id::Int
    owner_category::InfraStore.OwnerCategory
    association_id::Int
    time_series_type::Type{<:StaticTimeSeries}
    name::String
    initial_timestamp::Dates.DateTime
    resolution::Dates.Period
    length::Int
    features::Dict{String, Any}
end

"""
A unique key to identify and retrieve a [`NonSequentialTimeSeries`](@ref)

Unlike [`StaticTimeSeriesKey`](@ref), a non-sequential series is irregular: it has
no `resolution` and no regular `initial_timestamp` (its timestamps are stored with
the data), so the key carries only its `length`. This mirrors the dedicated
non-sequential key in the InfraStore backend.

See: [`get_time_series_keys`](@ref) and [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
@kwdef struct NonSequentialTimeSeriesKey <: TimeSeriesKey
    owner_id::Int
    owner_category::InfraStore.OwnerCategory
    association_id::Int
    time_series_type::Type{<:NonSequentialTimeSeries}
    name::String
    length::Int
    features::Dict{String, Any}
end

# A non-sequential key is irregular: it has neither field.
get_resolution(::NonSequentialTimeSeriesKey) = nothing
get_initial_timestamp(::NonSequentialTimeSeriesKey) = nothing

"""
A unique key to identify and retrieve a [`Forecast`](@ref)

See: [`get_time_series_keys`](@ref) and [`get_time_series(::TimeSeriesOwners, ::TimeSeriesKey)`](@ref).
"""
@kwdef struct ForecastKey <: TimeSeriesKey
    owner_id::Int
    owner_category::InfraStore.OwnerCategory
    association_id::Int
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
# A ForecastKey has no `length` field; its per-window length is the horizon count.
get_length(key::ForecastKey) = get_horizon_count(key)
Base.length(key::ForecastKey) = get_horizon_count(key)

# Keys are values: two keys naming the same stored association are equal, whatever
# spelling their periods arrived in (`Hour(1)` from a constructor, `Millisecond(3600000)`
# back from the catalog — `==` and `hash` on `Period` already agree across those).
function Base.:(==)(a::T, b::T) where {T <: TimeSeriesKey}
    return all(getfield(a, f) == getfield(b, f) for f in fieldnames(T))
end

function Base.hash(key::T, h::UInt) where {T <: TimeSeriesKey}
    h = hash(T, h)
    for f in fieldnames(T)
        h = hash(getfield(key, f), h)
    end
    return h
end

# All concrete key types, for use in struct fields: a `Union` of concrete types
# union-splits (no boxing / dynamic dispatch in per-timestep paths), unlike the
# abstract `TimeSeriesKey`.
const ConcreteTimeSeriesKey =
    Union{StaticTimeSeriesKey, NonSequentialTimeSeriesKey, ForecastKey}

"""
Everything a [`TimeSeriesKey`](@ref) needs except its `association_id`, held for the
span between staging an addition onto a batch and the store writing it.

The catalog mints the id on insert, so a staged addition does not have one yet — and
a key is a value, immutable, never patched after the fact. Staging therefore produces
this instead, and [`build_key`](@ref) turns it into the real key once the write hands
back the id it was filed under. `K` is the concrete key type the fields belong to, so
the built key's type is known from the staged one alone.
"""
struct StagedKey{K <: TimeSeriesKey, NT <: NamedTuple}
    fields::NT
end

StagedKey{K}(fields::NT) where {K <: TimeSeriesKey, NT <: NamedTuple} =
    StagedKey{K, NT}(fields)

"""
    build_key(staged::StagedKey, association_id) -> ConcreteTimeSeriesKey

The key `staged` describes, filed under `association_id` — the id the store minted for
its row.
"""
build_key(staged::StagedKey{K}, association_id::Integer) where {K} =
    K(; staged.fields..., association_id = Int(association_id))

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
