const TimeSeriesOwners = Union{InfrastructureSystemsComponent, SupplementalAttribute}

"""
    TimeSeriesKey{T <: TimeSeriesData}

A reference to one stored time series association: its store-minted
`association_id`, with the stored time series type as the type parameter.

The id is the whole content. Everything else a caller might want — name,
resolution, initial timestamp, horizon, interval, count, owner, features — lives
in the catalog, and a key that also carried a copy could only disagree with it.
`rename_time_series!` and a reassignment both change catalog columns while
preserving the id, so a cached copy goes stale where the id cannot. Ask the store
when you need those: [`list_metadata`](@ref) for a set of rows, or
[`get_time_series_metadata`](@ref) for one.

`T` is the exception, because it is the one fact that *cannot* drift: a stored
association's time series type is part of its identity in the store and is never
rewritten. Carrying it as a type parameter costs nothing at runtime (a key is an
8-byte `isbits` value) and lets callers dispatch on it —
`f(key::TimeSeriesKey{<:Forecast})`.

Keys are produced by IS (`add_time_series!`, `list_metadata`), never constructed
by users. Two keys are equal exactly when they name the same association.
"""
struct TimeSeriesKey{T <: TimeSeriesData}
    association_id::Int64

    # Inner, so the widening happens in one place and `new` cannot recurse into
    # it: an outer method taking `Integer` would call itself for an `Int64`.
    TimeSeriesKey{T}(association_id::Integer) where {T <: TimeSeriesData} =
        new{T}(Int64(association_id))
end

"The store-minted surrogate id of the association this key names."
get_association_id(key::TimeSeriesKey) = key.association_id

"The stored time series type this key names."
get_time_series_type(::TimeSeriesKey{T}) where {T} = T
get_time_series_type(::Type{TimeSeriesKey{T}}) where {T} = T

# Two keys naming the same association are the same key, and hash alike. `T` is a
# function of the id — the store decides what an id names — so letting it into
# either would reintroduce exactly the failure the old all-fields comparison had:
# two spellings of one series that compare unequal and miss each other in a Dict.
Base.:(==)(a::TimeSeriesKey, b::TimeSeriesKey) =
    get_association_id(a) == get_association_id(b)
Base.hash(key::TimeSeriesKey, h::UInt) =
    hash(get_association_id(key), hash(TimeSeriesKey, h))

# Module-qualified names would triple the width of every key in a table, and the
# element type is worth the two extra words now that it is what a
# `TimeSeriesFunctionData` is bound by.
function Base.show(io::IO, key::TimeSeriesKey{T}) where {T}
    print(io, "TimeSeriesKey{", nameof(T))
    element = eltype(T)
    element === Any || print(io, "{", nameof(element), "}")
    print(io, "}(", get_association_id(key), ")")
    return
end

"""
A key serializes to its `association_id`, its time series kind, and the value
element type — `{"association_id": 7, "time_series_type": "SingleTimeSeries",
"element_type": "Float64"}`.

All three are immutable facts about the association: the store never rewrites
any of them, so none can fall out of step with the catalog the way a cached
`name` or `resolution` would. Carrying them is what lets a key deserialize
*without a store* — the id alone would leave the type parameter unrecoverable for
a field declared as the abstract `TimeSeriesKey`, and the kind alone would lose
the element type a `TimeSeriesFunctionData` is bound by.
"""
function serialize(key::TimeSeriesKey{T}) where {T}
    return Dict{String, Any}(
        "association_id" => get_association_id(key),
        "time_series_type" => string(nameof(T)),
        "element_type" => _key_element_name(eltype(T)),
    )
end

# The wire name of a key's value element type: the bare type name, so the
# spelling does not carry a module prefix that a rename would invalidate. A tuple
# element type has no useful `nameof` (every arity is `Tuple`), so it is spelled
# out with its arity.
_key_element_name(T::Type) = string(nameof(T))
_key_element_name(T::Type{<:Tuple}) = "NTuple{$(length(T.parameters)),Float64}"

"""
Rebuild a key from what it serialized to.

An `element_type` this version does not know leaves the kind unparameterized
rather than guessing: a key whose element type cannot be named still addresses
its series, and a read resolves the values from the catalog either way.
"""
function deserialize(::Type{<:TimeSeriesKey}, data::AbstractDict)
    kind = _time_series_type_from_name(data["time_series_type"])
    element = _key_element_type_from_name(get(data, "element_type", nothing))
    T = isnothing(element) ? kind : kind{element}
    return TimeSeriesKey{T}(data["association_id"])
end

# The value element types a key's parameter can name: the physical dtypes the
# store holds, plus the function-data types IS decodes them into. Names, not
# types, because the function-data types are defined after this file is included;
# resolving by name at call time keeps this table free of include ordering.
#
# An allowlist rather than a bare `getfield`: a name off the wire must not be able
# to reach for an arbitrary binding in this module.
const _KEY_ELEMENT_TYPE_NAMES = Set{String}([
    "Float64", "Float32", "Int64", "Int32", "Int16", "Int8",
    "UInt64", "UInt32", "UInt16", "UInt8", "Bool",
    "LinearFunctionData", "QuadraticFunctionData",
    "PiecewiseLinearData", "PiecewiseStepData",
])

const _NTUPLE_ELEMENT = r"^(?:NTuple\{(\d+), *Float64\}|Tuple\{(?:Float64(?:, *)?)+\})$"

function _key_element_type_from_name(name)
    isnothing(name) && return nothing
    s = String(name)
    s in _KEY_ELEMENT_TYPE_NAMES && return getfield(@__MODULE__, Symbol(s))
    m = match(_NTUPLE_ELEMENT, s)
    isnothing(m) && return nothing
    isnothing(m.captures[1]) && return NTuple{count(==(','), s) + 1, Float64}
    return NTuple{parse(Int, m.captures[1]), Float64}
end

"""
    TimeSeriesMetadata{T <: TimeSeriesData}

One catalog row: everything the store records about a time series association
except its values. Returned by [`list_metadata`](@ref).

This is where the descriptive attributes live now that a [`TimeSeriesKey`](@ref)
carries only its id. Reading them from a row rather than a key is the whole point
— the row is a snapshot the caller asked for and knows the age of, where a key
that cached them could hand back a name the catalog had since changed.

Fields a row's type does not use are `nothing`: `resolution` and
`initial_timestamp` on a `NonSequentialTimeSeries` (its timestamps are irregular
and stored with the data), `horizon` / `interval` / `count` on a static series,
`length` on a forecast, whose per-window length is its horizon count.
"""
struct TimeSeriesMetadata{T <: TimeSeriesData}
    key::TimeSeriesKey{T}
    owner_id::Int
    owner_category::InfraStore.OwnerCategory
    name::String
    initial_timestamp::Union{Nothing, Dates.DateTime}
    resolution::Union{Nothing, Dates.Period}
    horizon::Union{Nothing, Dates.Period}
    interval::Union{Nothing, Dates.Period}
    count::Union{Nothing, Int}
    length::Union{Nothing, Int}
    features::Dict{String, Any}
end

"The [`TimeSeriesKey`](@ref) that addresses the association this row describes."
get_time_series_key(md::TimeSeriesMetadata) = md.key
get_association_id(md::TimeSeriesMetadata) = get_association_id(md.key)
get_time_series_type(::TimeSeriesMetadata{T}) where {T} = T
get_owner_id(md::TimeSeriesMetadata) = md.owner_id
get_owner_category(md::TimeSeriesMetadata) = md.owner_category
get_name(md::TimeSeriesMetadata) = md.name
get_initial_timestamp(md::TimeSeriesMetadata) = md.initial_timestamp
get_resolution(md::TimeSeriesMetadata) = md.resolution
get_horizon(md::TimeSeriesMetadata) = md.horizon
get_interval(md::TimeSeriesMetadata) = md.interval
get_count(md::TimeSeriesMetadata) = md.count
get_features(md::TimeSeriesMetadata) = md.features

"""
The number of values one window of the series holds. A forecast row has no
`length` of its own: for it this is the horizon count (the per-window length),
**not** the number of windows — use [`get_count`](@ref) for that.
"""
get_length(md::TimeSeriesMetadata) = md.length
get_length(md::TimeSeriesMetadata{<:Forecast}) = get_horizon_count(md)
Base.length(md::TimeSeriesMetadata) = get_length(md)

"The number of time steps in one window of a forecast row."
get_horizon_count(md::TimeSeriesMetadata{<:Forecast}) =
    get_horizon_count(get_horizon(md), get_resolution(md))

function Base.show(io::IO, md::TimeSeriesMetadata{T}) where {T}
    print(io, "TimeSeriesMetadata{", nameof(T), "}(", repr(md.name),
        ", association_id=", get_association_id(md), ", owner_id=", md.owner_id, ")")
end

"""
The time series type of an addition staged onto a batch, held for the span between
staging and the store writing it.

The catalog mints the id on insert, so a staged addition does not have one yet, and a
key is immutable. Staging therefore produces this — the one thing a key needs besides
the id — and [`build_key`](@ref) turns it into the real key once the write hands back
the id it was filed under.
"""
struct StagedKey{T <: TimeSeriesData} end

"""
    build_key(staged::StagedKey, association_id) -> TimeSeriesKey

The key `staged` describes, filed under `association_id` — the id the store minted for
its row.
"""
build_key(::StagedKey{T}, association_id::Integer) where {T} =
    TimeSeriesKey{T}(association_id)

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
