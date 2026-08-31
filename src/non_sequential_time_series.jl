"""
    struct NonSequentialTimeSeries{T, N} <: StaticTimeSeries{T}
        name::String
        timestamps::Vector{Dates.DateTime}
        data::Array{T, N}
        units::Union{Nothing, String}
        quantity_kind::Union{Nothing, String}
        unit_system::Union{Nothing, AbstractUnitSystem}
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
  - `units::Union{Nothing, String}`: optional user-declared units label for the values
    (e.g. `"MW"`)
  - `quantity_kind::Union{Nothing, String}`: optional label for the kind of physical
    quantity the values measure (e.g. `"ActivePower"`)
  - `unit_system::Union{Nothing, AbstractUnitSystem}`: optional declaration of the basis
    the values are already expressed in (`NU`, `DU`, or `SU`)

See [`get_units`](@ref), [`get_quantity_kind`](@ref), [`get_unit_system`](@ref).
"""
struct NonSequentialTimeSeries{T, N} <: StaticTimeSeries{T}
    "user-defined name"
    name::String
    "strictly-increasing timestamps; one per value (`length == size(data, 1)`)."
    timestamps::Vector{Dates.DateTime}
    "value array; dimension 1 is time (`N == 1` scalar-per-step, `N >= 2` multidimensional per-step)."
    data::Array{T, N}
    "user-declared units label for the values (e.g. `\"MW\"`), or `nothing`"
    units::Union{Nothing, String}
    "kind of physical quantity the values measure (e.g. `\"ActivePower\"`), or `nothing`"
    quantity_kind::Union{Nothing, String}
    "unit system the values are already expressed in (`NU`/`DU`/`SU`), or `nothing`"
    unit_system::Union{Nothing, AbstractUnitSystem}

    # An explicit inner constructor (validating the timestamp/value count) suppresses
    # Julia's auto-generated default constructor, so every construction path funnels
    # through this check regardless of how concrete the argument types are.
    function NonSequentialTimeSeries{T, N}(
        name,
        timestamps::Vector{Dates.DateTime},
        data::Array{T, N},
        units::Union{Nothing, AbstractString} = nothing,
        quantity_kind::Union{Nothing, AbstractString} = nothing,
        unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
    ) where {T, N}
        length(timestamps) == size(data, 1) || throw(
            ConflictingInputsError(
                "timestamp count $(length(timestamps)) must match data length $(size(data, 1))",
            ),
        )
        return new{T, N}(
            String(name),
            timestamps,
            data,
            _maybe_string(units),
            _maybe_string(quantity_kind),
            unit_system,
        )
    end
end

# The element/rank parameters `{T, N}` are inferred from the value array so callers
# never have to spell them out.
function NonSequentialTimeSeries(
    name,
    timestamps::AbstractVector,
    data::AbstractArray;
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    arr = _ensure_array(data)
    return NonSequentialTimeSeries{eltype(arr), ndims(arr)}(
        String(name),
        _ensure_datetime_vector(timestamps),
        arr,
        units,
        quantity_kind,
        unit_system,
    )
end

# Normalize the `data` keyword to `(timestamps, values)`. Only a `TimeArray` carries
# its own timestamps; raw arrays must go through the positional constructor.
function _non_sequential_args(data::TimeSeries.TimeArray, normalization_factor)
    normalized = handle_normalization_factor(data, normalization_factor)
    return collect(TimeSeries.timestamp(normalized)), TimeSeries.values(normalized)
end

function _non_sequential_args(data, normalization_factor)
    throw(
        ArgumentError(
            "NonSequentialTimeSeries(; name, data) requires data to be a TimeArray; " *
            "pass NonSequentialTimeSeries(name, timestamps, data) for raw arrays",
        ),
    )
end

function NonSequentialTimeSeries(;
    name,
    data,
    normalization_factor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    timestamps, vals = _non_sequential_args(data, normalization_factor)
    return NonSequentialTimeSeries(
        name, timestamps, vals;
        units = units, quantity_kind = quantity_kind, unit_system = unit_system,
    )
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
    return NonSequentialTimeSeries(
        name, src.timestamps, src.data;
        units = src.units, quantity_kind = src.quantity_kind, unit_system = src.unit_system,
    )
end

"""
Construct a `NonSequentialTimeSeries` from a TimeArray. The timestamps are taken
as-is (no regularity is assumed).

# Arguments

  - `name::AbstractString`: user-defined name
  - `data::TimeSeries.TimeArray`: time series data
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
  - `timestamp::Symbol = :timestamp`: If a DataFrame is passed then this must be the column name
    that contains timestamps.
"""
function NonSequentialTimeSeries(
    name::AbstractString,
    data::TimeSeries.TimeArray;
    normalization_factor::NormalizationFactor = 1.0,
    timestamp::Symbol = :timestamp,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    # TimeArray's table integration returns a Matrix even for a single column; slice
    # to the lone column to obtain the appropriate Vector value (mirrors SingleTimeSeries).
    length(TimeSeries.colnames(data)) == 1 || throw(
        ArgumentError("The input data should have a single column other than $(timestamp)"),
    )
    return NonSequentialTimeSeries(;
        name = name,
        data = data[first(TimeSeries.colnames(data))],
        normalization_factor = normalization_factor,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
    )
end

"""
Construct a `NonSequentialTimeSeries` from a DataFrame whose `timestamp` column holds
the timestamps.
"""
function NonSequentialTimeSeries(
    name::AbstractString,
    data::DataFrames.DataFrame;
    normalization_factor::NormalizationFactor = 1.0,
    timestamp::Symbol = :timestamp,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    return NonSequentialTimeSeries(
        name,
        TimeSeries.TimeArray(data; timestamp = timestamp);
        normalization_factor = normalization_factor,
        timestamp = timestamp,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
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
        TimeSeries.values(data);
        units = get_units(time_series),
        quantity_kind = get_quantity_kind(time_series),
        unit_system = get_unit_system(time_series),
    )
end

# Hook for the shared `StaticTimeSeries` slicing methods.
_from_time_array(ts::NonSequentialTimeSeries, data::TimeSeries.TimeArray) =
    NonSequentialTimeSeries(ts, _check_non_empty_subset(data))

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

An alias of [`get_time_array`](@ref). Prefer [`get_array`](@ref) (raw `Array`) when a
`TimeArray` is not needed.
"""
get_data(value::NonSequentialTimeSeries) = get_time_array(value)

"""
Get [`NonSequentialTimeSeries`](@ref) `resolution`. A non-sequential series is
irregular, so this is always `nothing`.
"""
get_resolution(::NonSequentialTimeSeries) = nothing

get_initial_timestamp(time_series::NonSequentialTimeSeries) = time_series.timestamps[1]

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
    count >= 1 || throw(ArgumentError("len must be >= 1; got $count"))
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
