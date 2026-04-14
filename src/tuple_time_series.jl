"""
    TupleTimeSeries{T <: NamedTuple}

A time-series-backed wrapper for fixed-arity `NamedTuple` values with `Float64` fields. It
mirrors the [`TimeSeriesFunctionData`](@ref) / [`TimeSeriesInputOutputCurve`](@ref) pattern:
the struct holds a [`TimeSeriesKey`](@ref) pointing to a time series of
`NTuple{N, Float64}` values, while the type parameter `T` carries the `NamedTuple` shape
(field names + arity) used when the tuple is resolved at a specific timestep.

Use these in place of a bare `TimeSeriesKey` field whenever a tuple-shaped quantity
(e.g. start-up stages, min/max limits) can vary over time. Use
[`build_static_tuple`](@ref) to resolve the time series at a chosen `start_time`.

`T` must be a concrete `NamedTuple` type whose values are `NTuple{N, Float64}` for some
`N`; the inner constructor rejects other shapes.

# Example
```julia
const StartUpStages = NamedTuple{(:hot, :warm, :cold), NTuple{3, Float64}}
tts = TupleTimeSeries{StartUpStages}(ts_key)
stages = build_static_tuple(tts, component, start_time)  # returns a StartUpStages
```
"""
struct TupleTimeSeries{T <: NamedTuple} <: InfrastructureSystemsType
    time_series_key::TimeSeriesKey

    function TupleTimeSeries{T}(
        time_series_key::TimeSeriesKey,
    ) where {T <: NamedTuple}
        _validate_tuple_time_series_type(T)
        return new{T}(time_series_key)
    end
end

TupleTimeSeries{T}(; time_series_key::TimeSeriesKey) where {T <: NamedTuple} =
    TupleTimeSeries{T}(time_series_key)

# Arity-specialized validators. These are no-ops for the two arities IS commits to
# supporting as first-class shapes; PSY precompiles against these to keep the hot
# construction path branchless. The generic fallback below handles any other arity
# by validating at runtime.
_validate_tuple_time_series_type(
    ::Type{T},
) where {Names, T <: NamedTuple{Names, NTuple{2, Float64}}} = nothing

_validate_tuple_time_series_type(
    ::Type{T},
) where {Names, T <: NamedTuple{Names, NTuple{3, Float64}}} = nothing

function _validate_tuple_time_series_type(::Type{T}) where {T}
    T <: NamedTuple || throw(
        ArgumentError(
            "TupleTimeSeries type parameter must be a NamedTuple, got $T",
        ),
    )
    isconcretetype(T) || throw(
        ArgumentError(
            "TupleTimeSeries type parameter must be a concrete NamedTuple type, got $T",
        ),
    )
    all(ft === Float64 for ft in fieldtypes(T)) || throw(
        ArgumentError(
            "TupleTimeSeries NamedTuple field types must all be Float64, got $(fieldtypes(T))",
        ),
    )
    return nothing
end

"""
    get_time_series_key(tts::TupleTimeSeries) -> TimeSeriesKey

Return the `TimeSeriesKey` that references the underlying time series data.
"""
get_time_series_key(tts::TupleTimeSeries) = tts.time_series_key

"""
    get_underlying_namedtuple_type(::Type{TupleTimeSeries{T}}) -> Type{T}

Return the concrete `NamedTuple` type that the stored tuple values correspond to.
"""
get_underlying_namedtuple_type(::Type{TupleTimeSeries{T}}) where {T} = T
get_underlying_namedtuple_type(tts::TupleTimeSeries) =
    get_underlying_namedtuple_type(typeof(tts))

is_time_series_backed(::TupleTimeSeries) = true

function Base.show(io::IO, ::MIME"text/plain", tts::TupleTimeSeries)
    T = get_underlying_namedtuple_type(tts)
    ts_key = get_time_series_key(tts)
    print(
        io,
        "TupleTimeSeries{$T} backed by time series \"$(get_name(ts_key))\"",
    )
end

"""
    build_static_tuple(
        tts::TupleTimeSeries{T},
        owner::TimeSeriesOwners,
        start_time::Dates.DateTime,
    ) -> T

Resolve the time series referenced by `tts` at `start_time` and return the single
`NamedTuple` value of type `T`. The stored time series must contain `NTuple{N, Float64}`
values whose arity matches `T`; the `NamedTuple` constructor is applied to reinterpret
the raw tuple with the field names carried by `T`.
"""
function build_static_tuple(
    tts::TupleTimeSeries{T},
    owner::TimeSeriesOwners,
    start_time::Dates.DateTime,
) where {T <: NamedTuple}
    key = get_time_series_key(tts)
    vals = get_time_series_values(owner, key; start_time = start_time, len = 1)
    raw = vals[1]
    return T(raw)::T
end

# ── Serialization ────────────────────────────────────────────────────────────

function add_serialization_metadata!(
    data::Dict,
    ::Type{TupleTimeSeries{T}},
) where {T <: NamedTuple}
    data[METADATA_KEY] = Dict{String, Any}(
        TYPE_KEY => "TupleTimeSeries",
        MODULE_KEY => string(parentmodule(TupleTimeSeries)),
        "namedtuple_fields" => [string(n) for n in fieldnames(T)],
    )
    return
end

function deserialize(::Type{TupleTimeSeries}, data::Dict)
    metadata = get_serialization_metadata(data)
    field_names = Tuple(Symbol.(metadata["namedtuple_fields"]))
    N = length(field_names)
    T = NamedTuple{field_names, NTuple{N, Float64}}
    key_data = data["time_series_key"]
    key_metadata = get_serialization_metadata(key_data)
    key_type = get_type_from_serialization_metadata(key_metadata)
    key = deserialize(key_type, key_data)
    return TupleTimeSeries{T}(key)
end
