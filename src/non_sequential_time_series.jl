"""
    struct NonSequentialTimeSeries{T, N} <: StaticTimeSeries
        name::String
        timestamps::Vector{Dates.DateTime}
        data::Array{T, N}
    end

A single column of static time series data recorded at explicit, irregular
timestamps.

`NonSequentialTimeSeries` is the irregular counterpart of [`SingleTimeSeries`](@ref):
it stores one value per timestamp, but the timestamps are arbitrary (strictly
increasing) rather than a regular `(initial_timestamp, resolution)` grid. Use it
for event-like measurements that do not fall on a fixed cadence.

The values are stored as a plain `Array{T, N}` (dimension 1 is time) alongside an
explicit `timestamps` vector with one entry per row of `data`. There is no
`resolution`; [`get_resolution`](@ref) returns `nothing`.

`T` is the in-memory value element type (`Float64` or a domain type such as
`LinearFunctionData`); `N` is the rank of the value array (`N == 1` is the
scalar-per-step case, `N >= 2` is multidimensional per-step values).

# Arguments

  - `name::String`: user-defined name
  - `timestamps::Vector{Dates.DateTime}`: strictly-increasing timestamps, one per value
  - `data::Array{T, N}`: value array (dimension 1 is time)
"""
struct NonSequentialTimeSeries{T, N} <: StaticTimeSeries
    "user-defined name"
    name::String
    "strictly-increasing timestamps; one per value (`length == size(data, 1)`)."
    timestamps::Vector{Dates.DateTime}
    "value array; dimension 1 is time (`N == 1` scalar-per-step, `N >= 2` multidimensional per-step)."
    data::Array{T, N}

    # An explicit inner constructor (validating the timestamp/value count) suppresses
    # Julia's auto-generated default constructor, so every construction path funnels
    # through this check regardless of how concrete the argument types are.
    function NonSequentialTimeSeries{T, N}(
        name,
        timestamps::Vector{Dates.DateTime},
        data::Array{T, N},
    ) where {T, N}
        length(timestamps) == size(data, 1) || throw(
            ConflictingInputsError(
                "timestamp count $(length(timestamps)) must match data length $(size(data, 1))",
            ),
        )
        return new{T, N}(String(name), timestamps, data)
    end
end

# The element/rank parameters `{T, N}` are inferred from the value array so callers
# never have to spell them out. Views/ranges are normalized to a concrete `Array`
# (copy-free when already one).
function NonSequentialTimeSeries(
    name,
    timestamps::AbstractVector,
    data::AbstractArray,
)
    arr = data isa Array ? data : Array(data)
    stamps = if timestamps isa Vector{Dates.DateTime}
        timestamps
    else
        collect(Dates.DateTime, timestamps)
    end
    return NonSequentialTimeSeries{eltype(arr), ndims(arr)}(String(name), stamps, arr)
end

function NonSequentialTimeSeries(;
    name,
    data,
    normalization_factor = 1.0,
)
    if data isa TimeSeries.TimeArray
        norm = handle_normalization_factor(data, normalization_factor)
        return NonSequentialTimeSeries(
            name,
            collect(TimeSeries.timestamp(norm)),
            TimeSeries.values(norm),
        )
    else
        throw(
            ArgumentError(
                "NonSequentialTimeSeries(; name, data) requires data to be a TimeArray; " *
                "pass NonSequentialTimeSeries(name, timestamps, data) for raw arrays",
            ),
        )
    end
end

"""
Return the value element type of a `NonSequentialTimeSeries` as a string, e.g.
`"Float64"` or `"...LinearFunctionData"`. This is the `T` of
`NonSequentialTimeSeries{T, N}` (`N` is ignored).
"""
get_data_type(::NonSequentialTimeSeries{T, N}) where {T, N} = string(T)

"""
Construct a `NonSequentialTimeSeries` that shares the data from an existing
instance under a different `name`.
"""
function NonSequentialTimeSeries(
    src::NonSequentialTimeSeries,
    name::AbstractString,
)
    return NonSequentialTimeSeries(name, src.timestamps, src.data)
end

"""
Construct a `NonSequentialTimeSeries` from a TimeArray or DataFrame. The
timestamps are taken as-is (no regularity is assumed).

# Arguments

  - `name::AbstractString`: user-defined name
  - `data::Union{TimeSeries.TimeArray, DataFrames.DataFrame}`: time series data
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
  - `timestamp::Symbol = :timestamp`: If a DataFrame is passed then this must be the column name
    that contains timestamps.
"""
function NonSequentialTimeSeries(
    name::AbstractString,
    data::Union{TimeSeries.TimeArray, DataFrames.DataFrame};
    normalization_factor::NormalizationFactor = 1.0,
    timestamp::Symbol = :timestamp,
)
    if data isa DataFrames.DataFrame
        ta = TimeSeries.TimeArray(data; timestamp = timestamp)
    elseif data isa TimeSeries.TimeArray
        ta = data
    else
        error("fatal: $(typeof(data))")
    end
    # TimeArray's table integration returns a Matrix even for a single column; slice
    # to the lone column to obtain the appropriate Vector value (mirrors SingleTimeSeries).
    length(TimeSeries.colnames(ta)) == 1 || throw(
        ArgumentError("The input data should have a single column other than $(timestamp)"),
    )
    ta = ta[first(TimeSeries.colnames(ta))]

    return NonSequentialTimeSeries(;
        name = name,
        data = ta,
        normalization_factor = normalization_factor,
    )
end

"""
Creates a new NonSequentialTimeSeries from an existing instance and a subset of data.
"""
function NonSequentialTimeSeries(
    time_series::NonSequentialTimeSeries,
    data::TimeSeries.TimeArray,
)
    return NonSequentialTimeSeries(
        get_name(time_series),
        collect(TimeSeries.timestamp(data)),
        TimeSeries.values(data),
    )
end

function check_time_series_data(ts::NonSequentialTimeSeries)
    len = size(ts.data, 1)
    len < 2 && throw(ArgumentError("data array length must be at least 2: $len"))
    timestamps = ts.timestamps
    for i in 2:len
        timestamps[i] > timestamps[i - 1] || throw(
            ConflictingInputsError(
                "NonSequentialTimeSeries timestamps must be strictly increasing: " *
                "t$(i - 1) = $(timestamps[i - 1]) t$(i) = $(timestamps[i])",
            ),
        )
    end
    return
end

"""
Get [`NonSequentialTimeSeries`](@ref) `name`.
"""
get_name(value::NonSequentialTimeSeries) = value.name

"""
Return the raw value array `data::Array{T, N}` of a [`NonSequentialTimeSeries`](@ref).

This is the preferred accessor for internal code; it never builds a `TimeArray`.
"""
get_array(value::NonSequentialTimeSeries) = value.data

"""
Return the explicit `timestamps` vector of a [`NonSequentialTimeSeries`](@ref).
"""
get_timestamps(value::NonSequentialTimeSeries) = value.timestamps

"""
Build a fresh `TimeSeries.TimeArray` from a [`NonSequentialTimeSeries`](@ref)'s
`(timestamps, data)`.

Defined for `N in (1, 2)` (a `TimeArray` is at most matrix-valued); for `N > 2` it
throws and callers should use [`get_array`](@ref).
"""
function get_time_array(value::NonSequentialTimeSeries{T, N}) where {T, N}
    N <= 2 || throw(
        ArgumentError(
            "get_time_array is only defined for 1- or 2-D values (got N = $N); use get_array",
        ),
    )
    return TimeSeries.TimeArray(value.timestamps, value.data)
end

"""
Get [`NonSequentialTimeSeries`](@ref) `data` as a `TimeArray`.

!!! warning "Deprecated"
    `get_data` is a temporary back-compatibility alias of [`get_time_array`](@ref).
    Prefer [`get_array`](@ref) (raw `Array`) or [`get_time_array`](@ref) (built
    `TimeArray`) in new code.
"""
get_data(value::NonSequentialTimeSeries) = get_time_array(value)

"""
Get [`NonSequentialTimeSeries`](@ref) `resolution`. A non-sequential series is
irregular, so this is always `nothing`.
"""
get_resolution(::NonSequentialTimeSeries) = nothing

eltype_data(ts::NonSequentialTimeSeries) = eltype(get_array(ts))

get_initial_timestamp(time_series::NonSequentialTimeSeries) = time_series.timestamps[1]

Base.length(time_series::NonSequentialTimeSeries) = size(time_series.data, 1)

function get_array_for_hdf(ts::NonSequentialTimeSeries)
    return transform_array_for_hdf(get_array(ts))
end

function Base.getindex(time_series::NonSequentialTimeSeries, args...)
    return NonSequentialTimeSeries(
        time_series,
        getindex(get_time_array(time_series), args...),
    )
end

Base.first(time_series::NonSequentialTimeSeries) = head(time_series, 1)

Base.last(time_series::NonSequentialTimeSeries) = tail(time_series, 1)

Base.firstindex(time_series::NonSequentialTimeSeries) =
    firstindex(get_time_array(time_series))

Base.lastindex(time_series::NonSequentialTimeSeries) =
    lastindex(get_time_array(time_series))

Base.lastindex(time_series::NonSequentialTimeSeries, d) =
    lastindex(get_time_array(time_series), d)

Base.eachindex(time_series::NonSequentialTimeSeries) =
    eachindex(get_time_array(time_series))

Base.iterate(time_series::NonSequentialTimeSeries, n = 1) =
    iterate(get_time_array(time_series), n)

"""
Refer to TimeSeries.when(). Underlying data is copied.
"""
function when(time_series::NonSequentialTimeSeries, period::Function, t::Integer)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.when(get_time_array(time_series), period, t),
    )
end

"""
Return a time_series truncated starting with timestamp.
"""
function from(time_series::NonSequentialTimeSeries, timestamp)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.from(get_time_array(time_series), timestamp),
    )
end

"""
Return a time_series truncated after timestamp.
"""
function to(time_series::NonSequentialTimeSeries, timestamp)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.to(get_time_array(time_series), timestamp),
    )
end

"""
Return a time_series with only the first num values.
"""
function head(time_series::NonSequentialTimeSeries)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.head(get_time_array(time_series)),
    )
end

function head(time_series::NonSequentialTimeSeries, num)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.head(get_time_array(time_series), num),
    )
end

"""
Return a time_series with only the ending num values.
"""
function tail(time_series::NonSequentialTimeSeries)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.tail(get_time_array(time_series)),
    )
end

function tail(time_series::NonSequentialTimeSeries, num)
    return NonSequentialTimeSeries(
        time_series,
        TimeSeries.tail(get_time_array(time_series), num),
    )
end

function make_time_array(
    time_series::NonSequentialTimeSeries,
    start_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
)
    timestamps = time_series.timestamps
    n = size(time_series.data, 1)
    if start_time == timestamps[1] && (len === nothing || len == n)
        return get_time_array(time_series)
    end

    # Timestamps are strictly increasing, so a binary search resolves the start.
    start_index = searchsortedfirst(timestamps, start_time)
    (start_index <= n && timestamps[start_index] == start_time) || throw(
        ArgumentError("start_time=$start_time is not a timestamp in the series"),
    )
    count = isnothing(len) ? n - start_index + 1 : len
    end_index = start_index + count - 1
    end_index <= n || throw(
        ArgumentError(
            "requested len=$count from start_time=$start_time exceeds the series",
        ),
    )
    colons = ntuple(_ -> Colon(), ndims(time_series.data) - 1)
    sub = time_series.data[start_index:end_index, colons...]
    return TimeSeries.TimeArray(timestamps[start_index:end_index], sub)
end
