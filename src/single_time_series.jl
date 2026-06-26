"""
    struct SingleTimeSeries{T, N} <: StaticTimeSeries
        name::String
        initial_timestamp::Dates.DateTime
        resolution::Dates.Period
        data::Array{T, N}
    end

A single column of time series data for a particular data field in a Component.

In contrast with a forecast, this can represent one continual time series,
such as a series of historical measurements or realizations or a single scenario
(e.g. a weather year or different input assumptions).

The values are stored as a plain `Array{T, N}` (dimension 1 is time) together with
an explicit `initial_timestamp` and `resolution`; the timestamps are derived from
`(initial_timestamp, resolution, size(data, 1))`. `SingleTimeSeries` is regular by
contract; irregular series are represented by `NonSequentialTimeSeries`.

`T` is the in-memory value element type (`Float64` or a domain type such as
`LinearFunctionData`); `N` is the rank of the value array (`N == 1` is the
scalar-per-step case, `N >= 2` is multidimensional per-step values).

# Arguments

  - `name::String`: user-defined name
  - `initial_timestamp::Dates.DateTime`: timestamp of the first value
  - `resolution::Dates.Period`: Time duration between steps in the time series. The resolution must be the same throughout the time series
  - `data::Array{T, N}`: value array (dimension 1 is time)
"""
struct SingleTimeSeries{T, N} <: StaticTimeSeries
    "user-defined name"
    name::String
    "timestamp of the first value"
    initial_timestamp::Dates.DateTime
    "resolution of the time series. The resolution cannot change during the time series."
    resolution::Dates.Period
    "value array; dimension 1 is time (`N == 1` scalar-per-step, `N >= 2` multidimensional per-step)."
    data::Array{T, N}
end

# Derive the regular timestamp range from the stored metadata.
_get_timestamps(ts::SingleTimeSeries) =
    range(ts.initial_timestamp; step = ts.resolution, length = size(ts.data, 1))

# Validate that user-provided timestamps are regular at `resolution`, raising the
# same helpful message as the legacy `check_time_series_data` when they are not.
function _validate_single_resolution(timestamps, resolution::Dates.Period)
    try
        check_resolution(timestamps, resolution)
    catch e
        if e isa ConflictingInputsError
            throw(
                ConflictingInputsError(
                    "The resolution in the time series is inconsistent. If the intended " *
                    "resolution is irregular, such as with Dates.Month and Dates.Year, pass " *
                    "the resolution as a keyword argument to the SingleTimeSeries constructor.",
                ),
            )
        end
        rethrow()
    end
end

# The element/rank parameters `{T, N}` are inferred from the value array so callers
# never have to spell them out. `SingleTimeSeries{T, N}(...)` (the inner
# constructor) remains available for explicit typing. Views/ranges are normalized
# to a concrete `Array` (copy-free when already one).
function SingleTimeSeries(
    name,
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period,
    data::AbstractArray,
)
    arr = data isa Array ? data : Array(data)
    return SingleTimeSeries{eltype(arr), ndims(arr)}(
        String(name),
        initial_timestamp,
        resolution,
        arr,
    )
end

function SingleTimeSeries(;
    name,
    data,
    initial_timestamp::Union{Nothing, Dates.DateTime} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    normalization_factor = 1.0,
)
    if data isa TimeSeries.TimeArray
        if isnothing(resolution)
            resolution = get_resolution(data)
        end
        data = handle_normalization_factor(data, normalization_factor)
        # Regularity is validated here (while the original timestamps are still
        # available); only `initial_timestamp` survives on the struct.
        _validate_single_resolution(TimeSeries.timestamp(data), resolution)
        return SingleTimeSeries(
            name,
            TimeSeries.timestamp(data)[1],
            resolution,
            TimeSeries.values(data),
        )
    else
        # Plain-array form (e.g. deserialization, internal reconstruction):
        # `initial_timestamp` and `resolution` must be supplied explicitly.
        isnothing(initial_timestamp) && throw(
            ArgumentError("initial_timestamp is required when data is not a TimeArray"),
        )
        isnothing(resolution) &&
            throw(ArgumentError("resolution is required when data is not a TimeArray"))
        arr = handle_normalization_factor(collect(data), normalization_factor)
        return SingleTimeSeries(name, initial_timestamp, resolution, arr)
    end
end

"""
Return the value element type of a `SingleTimeSeries` as a string, e.g.
`"Float64"` or `"...LinearFunctionData"`. This is the `T` of `SingleTimeSeries{T, N}`
(`N` is ignored).
"""
get_data_type(::SingleTimeSeries{T, N}) where {T, N} = string(T)

"""
Construct SingleTimeSeries that shares the data from an existing instance.

This is useful in cases where you want a component to use the same time series data for
two different attribtues.

Under the key-centric model the time-series identity is the array content hash, so
no UUID is shared; the new instance simply reuses the data with a different `name`.
"""
function SingleTimeSeries(
    src::SingleTimeSeries,
    name::AbstractString,
)
    return SingleTimeSeries(
        name,
        src.initial_timestamp,
        src.resolution,
        src.data,
    )
end

"""
Construct SingleTimeSeries from a TimeArray or DataFrame.

# Arguments

  - `name::AbstractString`: user-defined name
  - `data::Union{TimeSeries.TimeArray, DataFrames.DataFrame}`: time series data
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
  - `timestamp::Symbol = :timestamp`: If a DataFrame is passed then this must be the column name that
    contains timestamps.
  - `resolution::Union{Nothing, Dates.Period} = nothing`: If nothing, infer resolution from
    the data. Otherwise, it must be the difference between each consecutive timestamps.
    Resolution is required if the resolution is irregular, such as with Dates.Month or
    Dates.Year.
"""
function SingleTimeSeries(
    name::AbstractString,
    data::Union{TimeSeries.TimeArray, DataFrames.DataFrame};
    normalization_factor::NormalizationFactor = 1.0,
    timestamp::Symbol = :timestamp,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    if data isa DataFrames.DataFrame
        ta = TimeSeries.TimeArray(data; timestamp = timestamp)
    elseif data isa TimeSeries.TimeArray
        ta = data
    else
        error("fatal: $(typeof(data))")
    end
    # TimeArray's table integration (correctly) returns a Matrix as values, even if size in column dimension is 1 (julia +1.13)
    # As the rest expects a single valued timeseries, we slice to the only columns available to obtain the appropriate Vector value
    length(TimeSeries.colnames(ta)) == 1 || throw(
        ArgumentError("The input data should have a single column other than $(timestamp)"),
    )
    ta = ta[first(TimeSeries.colnames(ta))]

    return SingleTimeSeries(;
        name = name,
        data = ta,
        resolution = resolution,
        normalization_factor = normalization_factor,
    )
end

"""
Construct SingleTimeSeries from a CSV file. The file must have a column that is the name of the
component.

# Arguments

  - `name::AbstractString`: user-defined name
  - `filename::AbstractString`: name of CSV file containing data
  - `component::InfrastructureSystemsComponent`: component associated with the data
  - `resolution::Dates.Period`: resolution of the time series
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
"""
function SingleTimeSeries(
    name::AbstractString,
    filename::AbstractString,
    component::InfrastructureSystemsComponent,
    resolution::Dates.Period;
    normalization_factor::NormalizationFactor = 1.0,
)
    component_name = get_name(component)
    raw = read_time_series(SingleTimeSeries, filename, component_name)
    ta = make_time_array(raw, component_name, resolution)
    return SingleTimeSeries(;
        name = name,
        data = ta,
        normalization_factor = normalization_factor,
    )
end

"""
Construct SingleTimeSeries of constant `1.0` values from `initial_time` and
`time_steps`.
"""
function SingleTimeSeries(
    name::String,
    resolution::Dates.Period,
    initial_time::Dates.DateTime,
    time_steps::Int,
)
    return SingleTimeSeries(name, initial_time, resolution, ones(time_steps))
end

function SingleTimeSeries(time_series::AbstractVector{<:SingleTimeSeries})
    @assert !isempty(time_series)
    timestamps =
        collect(Iterators.flatten((collect(_get_timestamps(x)) for x in time_series)))
    data = collect(Iterators.flatten((x.data for x in time_series)))
    ta = TimeSeries.TimeArray(timestamps, data)

    time_series = SingleTimeSeries(;
        name = get_name(time_series[1]),
        data = ta,
    )
    @debug "concatenated time_series" LOG_GROUP_TIME_SERIES time_series
    return time_series
end

function SingleTimeSeries(info::TimeSeriesParsedInfo)
    data = make_time_array(info)
    return SingleTimeSeries(;
        name = info.name,
        data = data,
        normalization_factor = info.normalization_factor,
    )
end

function check_time_series_data(ts::SingleTimeSeries)
    len = size(ts.data, 1)
    len < 2 && throw(ArgumentError("data array length must be at least 2: $len"))
    # Regularity is enforced at construction (against the original timestamps);
    # the stored `(initial_timestamp, resolution)` are regular by construction.
    return
end

"""
Get [`SingleTimeSeries`](@ref) `name`.
"""
get_name(value::SingleTimeSeries) = value.name

"""
Return the raw value array `data::Array{T, N}` of a [`SingleTimeSeries`](@ref).

This is the preferred accessor for internal code; it never builds a `TimeArray`.
"""
get_array(value::SingleTimeSeries) = value.data

"""
Build a fresh `TimeSeries.TimeArray` from a [`SingleTimeSeries`](@ref)'s
`(initial_timestamp, resolution, data)`.

Defined for `N in (1, 2)` (a `TimeArray` is at most matrix-valued); for `N > 2` it
throws and callers should use [`get_array`](@ref).
"""
function get_time_array(value::SingleTimeSeries{T, N}) where {T, N}
    N <= 2 || throw(
        ArgumentError(
            "get_time_array is only defined for 1- or 2-D values (got N = $N); use get_array",
        ),
    )
    return TimeSeries.TimeArray(collect(_get_timestamps(value)), value.data)
end

"""
Get [`SingleTimeSeries`](@ref) `data` as a `TimeArray`.

!!! warning "Deprecated"
    `get_data` is a temporary back-compatibility alias of [`get_time_array`](@ref).
    Prefer [`get_array`](@ref) (raw `Array`) or [`get_time_array`](@ref) (built
    `TimeArray`) in new code.
"""
get_data(value::SingleTimeSeries) = get_time_array(value)

"""
Get [`SingleTimeSeries`](@ref) `resolution`.
"""
get_resolution(value::SingleTimeSeries) = value.resolution

eltype_data(ts::SingleTimeSeries) = eltype(get_array(ts))

get_initial_timestamp(time_series::SingleTimeSeries) = time_series.initial_timestamp

Base.length(time_series::SingleTimeSeries) = size(time_series.data, 1)

function get_array_for_hdf(ts::SingleTimeSeries)
    return transform_array_for_hdf(get_array(ts))
end

function Base.getindex(time_series::SingleTimeSeries, args...)
    return SingleTimeSeries(time_series, getindex(get_time_array(time_series), args...))
end

Base.first(time_series::SingleTimeSeries) = head(time_series, 1)

Base.last(time_series::SingleTimeSeries) = tail(time_series, 1)

Base.firstindex(time_series::SingleTimeSeries) = firstindex(get_time_array(time_series))

Base.lastindex(time_series::SingleTimeSeries) = lastindex(get_time_array(time_series))

Base.lastindex(time_series::SingleTimeSeries, d) = lastindex(get_time_array(time_series), d)

Base.eachindex(time_series::SingleTimeSeries) = eachindex(get_time_array(time_series))

Base.iterate(time_series::SingleTimeSeries, n = 1) = iterate(get_time_array(time_series), n)

"""
Refer to TimeSeries.when(). Underlying data is copied.
"""
function when(time_series::SingleTimeSeries, period::Function, t::Integer)
    return SingleTimeSeries(
        time_series,
        TimeSeries.when(get_time_array(time_series), period, t),
    )
end

"""
Return a time_series truncated starting with timestamp.
"""
function from(time_series::SingleTimeSeries, timestamp)
    return SingleTimeSeries(
        time_series,
        TimeSeries.from(get_time_array(time_series), timestamp),
    )
end

"""
Return a time_series truncated after timestamp.
"""
function to(time_series::SingleTimeSeries, timestamp)
    return SingleTimeSeries(
        time_series,
        TimeSeries.to(get_time_array(time_series), timestamp),
    )
end

"""
Return a time_series with only the first num values.
"""
function head(time_series::SingleTimeSeries)
    return SingleTimeSeries(time_series, TimeSeries.head(get_time_array(time_series)))
end

function head(time_series::SingleTimeSeries, num)
    return SingleTimeSeries(time_series, TimeSeries.head(get_time_array(time_series), num))
end

"""
Return a time_series with only the ending num values.
"""
function tail(time_series::SingleTimeSeries)
    return SingleTimeSeries(time_series, TimeSeries.tail(get_time_array(time_series)))
end

function tail(time_series::SingleTimeSeries, num)
    return SingleTimeSeries(time_series, TimeSeries.tail(get_time_array(time_series), num))
end

"""
Creates a new SingleTimeSeries from an existing instance and a subset of data.
"""
function SingleTimeSeries(time_series::SingleTimeSeries, data::TimeSeries.TimeArray)
    return SingleTimeSeries(
        get_name(time_series),
        TimeSeries.timestamp(data)[1],
        get_resolution(time_series),
        TimeSeries.values(data),
    )
end

function make_time_array(
    time_series::SingleTimeSeries,
    start_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
)
    first_time = get_initial_timestamp(time_series)
    n = size(time_series.data, 1)
    if start_time == first_time && (len === nothing || len == n)
        return get_time_array(time_series)
    end

    resolution = Dates.Millisecond(get_resolution(time_series))
    start_index = Int((start_time - first_time) / resolution) + 1
    end_index = start_index + len - 1
    colons = ntuple(_ -> Colon(), ndims(time_series.data) - 1)
    sub = time_series.data[start_index:end_index, colons...]
    timestamps = range(start_time; step = get_resolution(time_series), length = len)
    return TimeSeries.TimeArray(collect(timestamps), sub)
end
