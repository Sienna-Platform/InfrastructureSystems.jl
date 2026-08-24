"""
    struct SingleTimeSeries{T, N} <: StaticTimeSeries{T}
        name::String
        initial_timestamp::Dates.DateTime
        resolution::Dates.Period
        data::Array{T, N}
        units::Union{Nothing, String}
        quantity_kind::Union{Nothing, String}
        unit_system::Union{Nothing, AbstractUnitSystem}
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
  - `units::Union{Nothing, String}`: optional user-declared units label for the values
    (e.g. `"MW"`)
  - `quantity_kind::Union{Nothing, String}`: optional label for the kind of physical
    quantity the values measure (e.g. `"ActivePower"`)
  - `unit_system::Union{Nothing, AbstractUnitSystem}`: optional declaration of the basis
    the values are already expressed in (`NU`, `DU`, or `SU`)

See [`get_units`](@ref), [`get_quantity_kind`](@ref), [`get_unit_system`](@ref).
"""
struct SingleTimeSeries{T, N} <: StaticTimeSeries{T}
    "user-defined name"
    name::String
    "timestamp of the first value"
    initial_timestamp::Dates.DateTime
    "resolution of the time series. The resolution cannot change during the time series."
    resolution::Dates.Period
    "value array; dimension 1 is time (`N == 1` scalar-per-step, `N >= 2` multidimensional per-step)."
    data::Array{T, N}
    "user-declared units label for the values (e.g. `\"MW\"`), or `nothing`"
    units::Union{Nothing, String}
    "kind of physical quantity the values measure (e.g. `\"ActivePower\"`), or `nothing`"
    quantity_kind::Union{Nothing, String}
    "unit system the values are already expressed in (`NU`/`DU`/`SU`), or `nothing`"
    unit_system::Union{Nothing, AbstractUnitSystem}
end

# Derive the regular timestamp range from the stored metadata.
_get_timestamps(ts::SingleTimeSeries) =
    range(ts.initial_timestamp; step = ts.resolution, length = size(ts.data, 1))

# Validate that user-provided timestamps are regular at `resolution`, pointing at the
# keyword-argument escape hatch for irregular periods when they are not.
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
# never have to spell them out.
function SingleTimeSeries(
    name,
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period,
    data::AbstractArray;
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    arr = _ensure_array(data)
    return SingleTimeSeries{eltype(arr), ndims(arr)}(
        String(name),
        initial_timestamp,
        resolution,
        arr,
        _maybe_string(units),
        _maybe_string(quantity_kind),
        unit_system,
    )
end

# Normalize the `data` keyword to `(initial_timestamp, resolution, values)`. A
# `TimeArray` carries its own timestamps; a plain array requires both explicitly.
function _single_time_series_args(
    data::TimeSeries.TimeArray,
    initial_timestamp,
    resolution,
    normalization_factor,
)
    if isnothing(resolution)
        resolution = get_resolution(data)
    end
    normalized = handle_normalization_factor(data, normalization_factor)
    # Validated here, while the original timestamps are still available; only
    # `initial_timestamp` survives on the struct.
    _validate_single_resolution(TimeSeries.timestamp(normalized), resolution)
    return (
        TimeSeries.timestamp(normalized)[1],
        resolution,
        TimeSeries.values(normalized),
    )
end

function _single_time_series_args(data, initial_timestamp, resolution, normalization_factor)
    isnothing(initial_timestamp) && throw(
        ArgumentError("initial_timestamp is required when data is not a TimeArray"),
    )
    isnothing(resolution) &&
        throw(ArgumentError("resolution is required when data is not a TimeArray"))
    return (
        initial_timestamp,
        resolution,
        handle_normalization_factor(collect(data), normalization_factor),
    )
end

function SingleTimeSeries(;
    name,
    data,
    initial_timestamp::Union{Nothing, Dates.DateTime} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    normalization_factor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    first_timestamp, res, arr = _single_time_series_args(
        data,
        initial_timestamp,
        resolution,
        normalization_factor,
    )
    return SingleTimeSeries(
        name, first_timestamp, res, arr;
        units = units, quantity_kind = quantity_kind, unit_system = unit_system,
    )
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
"""
function SingleTimeSeries(
    src::SingleTimeSeries,
    name::AbstractString,
)
    return SingleTimeSeries(
        name,
        src.initial_timestamp,
        src.resolution,
        src.data;
        units = src.units,
        quantity_kind = src.quantity_kind,
        unit_system = src.unit_system,
    )
end

"""
Construct SingleTimeSeries from a TimeArray.

# Arguments

  - `name::AbstractString`: user-defined name
  - `data::TimeSeries.TimeArray`: time series data
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
    data::TimeSeries.TimeArray;
    normalization_factor::NormalizationFactor = 1.0,
    timestamp::Symbol = :timestamp,
    resolution::Union{Nothing, Dates.Period} = nothing,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    # TimeArray's table integration (correctly) returns a Matrix as values, even if size in column dimension is 1 (julia +1.13)
    # As the rest expects a single valued timeseries, we slice to the only columns available to obtain the appropriate Vector value
    length(TimeSeries.colnames(data)) == 1 || throw(
        ArgumentError("The input data should have a single column other than $(timestamp)"),
    )
    return SingleTimeSeries(;
        name = name,
        data = data[first(TimeSeries.colnames(data))],
        resolution = resolution,
        normalization_factor = normalization_factor,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
    )
end

"""
Construct SingleTimeSeries from a DataFrame whose `timestamp` column holds the timestamps.
"""
function SingleTimeSeries(
    name::AbstractString,
    data::DataFrames.DataFrame;
    normalization_factor::NormalizationFactor = 1.0,
    timestamp::Symbol = :timestamp,
    resolution::Union{Nothing, Dates.Period} = nothing,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    return SingleTimeSeries(
        name,
        TimeSeries.TimeArray(data; timestamp = timestamp);
        normalization_factor = normalization_factor,
        timestamp = timestamp,
        resolution = resolution,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
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
    time_steps::Int;
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    return SingleTimeSeries(
        name, initial_time, resolution, ones(time_steps);
        units = units, quantity_kind = quantity_kind, unit_system = unit_system,
    )
end

function SingleTimeSeries(time_series::AbstractVector{<:SingleTimeSeries})
    @assert !isempty(time_series)
    src = first(time_series)
    resolution = get_resolution(src)
    # The segments must join into one regular series; validate before discarding
    # the per-segment timestamps.
    _validate_single_resolution(
        collect(Iterators.flatten(_get_timestamps(x) for x in time_series)),
        resolution,
    )
    concatenated = SingleTimeSeries(
        get_name(src),
        get_initial_timestamp(src),
        resolution,
        collect(Iterators.flatten(get_array(x) for x in time_series));
        units = get_units(src),
        quantity_kind = get_quantity_kind(src),
        unit_system = get_unit_system(src),
    )
    @debug "concatenated time_series" LOG_GROUP_TIME_SERIES concatenated
    return concatenated
end

function check_time_series_data(ts::SingleTimeSeries)
    len = size(ts.data, 1)
    len < 2 && throw(ArgumentError("data array length must be at least 2: $len"))
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

An alias of [`get_time_array`](@ref). Prefer [`get_array`](@ref) (raw `Array`) when a
`TimeArray` is not needed.
"""
get_data(value::SingleTimeSeries) = get_time_array(value)

"""
Get [`SingleTimeSeries`](@ref) `resolution`.
"""
get_resolution(value::SingleTimeSeries) = value.resolution

get_initial_timestamp(time_series::SingleTimeSeries) = time_series.initial_timestamp

"""
Creates a new SingleTimeSeries from an existing instance and a subset of data.
"""
function SingleTimeSeries(time_series::SingleTimeSeries, data::TimeSeries.TimeArray)
    return SingleTimeSeries(
        get_name(time_series),
        TimeSeries.timestamp(data)[1],
        get_resolution(time_series),
        TimeSeries.values(data);
        units = get_units(time_series),
        quantity_kind = get_quantity_kind(time_series),
        unit_system = get_unit_system(time_series),
    )
end

# Hook for the shared `StaticTimeSeries` slicing methods.
_from_time_array(ts::SingleTimeSeries, data::TimeSeries.TimeArray) =
    SingleTimeSeries(ts, data)

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

    # Period arithmetic, so a calendar resolution (`Month`) indexes like a fixed one.
    resolution = get_resolution(time_series)
    start_index = compute_time_array_index(first_time, start_time, resolution)
    # `compute_time_array_index` already rejects a `start_time` before `first_time`;
    # catch one past the end here so `len` is derived from a valid index.
    start_index <= n || throw(
        ArgumentError(
            "start_time=$start_time is past the end of the series " *
            "(length $n from $first_time through $(first_time + resolution * (n - 1)))",
        ),
    )
    # `len = nothing` means "to the end", per the accessor docstrings.
    isnothing(len) && (len = n - start_index + 1)
    end_index = start_index + len - 1
    (len >= 1 && end_index <= n) || throw(
        ArgumentError(
            "requested len=$len from start_time=$start_time exceeds the series " *
            "(length $n from $first_time)",
        ),
    )
    colons = ntuple(_ -> Colon(), ndims(time_series.data) - 1)
    sub = time_series.data[start_index:end_index, colons...]
    timestamps = range(start_time; step = resolution, length = len)
    return TimeSeries.TimeArray(collect(timestamps), sub)
end
