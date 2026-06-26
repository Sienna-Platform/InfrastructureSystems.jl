"""
    mutable struct Deterministic <: AbstractDeterministic
        name::String
        data::SortedDict
        resolution::Dates.Period
        interval::Dates.Period
        internal::InfrastructureSystemsInternal
    end

A deterministic forecast for a particular data field in a Component.

# Arguments

  - `name::String`: user-defined name
  - `data::SortedDict`: timestamp - scalingfactor
  - `resolution::Dates.Period`: forecast resolution
  - `interval::Dates.Period`: forecast interval
  - `internal::InfrastructureSystemsInternal`
"""
struct Deterministic{T, N} <: AbstractDeterministic
    "user-defined name"
    name::String
    "timestamp - scalingfactor (per-window arrays of rank `N`)"
    data::SortedDict{Dates.DateTime, Array{T, N}}
    "forecast resolution"
    resolution::Dates.Period
    "forecast interval"
    interval::Dates.Period

    # Inner constructor validates HDF-storability on every construction (including
    # the inferring outer constructor below), so unsupported element types are
    # rejected early.
    function Deterministic{T, N}(
        name::AbstractString,
        data::SortedDict{Dates.DateTime, Array{T, N}},
        resolution::Dates.Period,
        interval::Dates.Period,
    ) where {T, N}
        validate_time_series_data_for_hdf(data)
        return new{T, N}(String(name), data, resolution, interval)
    end
end

# Infer `{T, N}` — element type and per-window array rank — from the data; the
# inner constructor performs validation. `data` is normalized to a typed `SortedDict`.
function Deterministic(
    name::AbstractString,
    data::AbstractDict{Dates.DateTime},
    resolution::Dates.Period,
    interval::Dates.Period,
)
    sorted = data isa SortedDict ? data : SortedDict(data...)
    return Deterministic{_window_eltype(sorted), _window_ndims(sorted)}(
        String(name),
        sorted,
        resolution,
        interval,
    )
end

function Deterministic(;
    name,
    data,
    resolution,
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor = 1.0,
)
    if isnothing(interval)
        interval = get_interval_from_initial_times(get_sorted_keys(data))
    end
    converted_data = convert_data(data)
    data = handle_normalization_factor(converted_data, normalization_factor)
    return Deterministic(
        name,
        data,
        resolution,
        interval,
    )
end

function Deterministic(
    name::AbstractString,
    data::AbstractDict,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    return Deterministic(;
        name = name,
        data = data,
        resolution = resolution,
        interval = interval,
    )
end

"""
Construct Deterministic from a Dict of TimeArrays.

# Arguments

  - `name::AbstractString`: user-defined name
  - `input_data::AbstractDict{Dates.DateTime, TimeSeries.TimeArray}`: time series data.
  - `resolution::Union{Nothing, Dates.Period} = nothing`: If nothing, infer resolution from
    the data. Otherwise, it must be the difference between each consecutive timestamps.
    Resolution is required if the resolution is irregular, such as with Dates.Month or
    Dates.Year.
  - `interval::Union{Nothing, Dates.Period} = nothing`: If nothing, infer interval from the
    data. Otherwise, it must be the difference in time between the start of each window.
    Interval is required if the interval is irregular, such as with Dates.Month or
    Dates.Year.
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
  - `timestamp = :timestamp`: If the values are DataFrames is passed then this must be the
    column name that contains timestamps.
"""
function Deterministic(
    name::AbstractString,
    input_data::AbstractDict{Dates.DateTime, <:TimeSeries.TimeArray};
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    data, res = convert_forecast_input_time_arrays(input_data; resolution = resolution)
    for (k, v) in input_data
        if length(size(v)) > 1
            throw(ArgumentError("TimeArray with timestamp $k has more than one column)"))
        end
    end

    return Deterministic(;
        name = name,
        data = data,
        resolution = res,
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

"""
Construct Deterministic from a CSV file. The first column must be a timestamp in
DateTime format and the columns the values in the forecast window.

# Arguments

  - `name::AbstractString`: user-defined name
  - `filename::AbstractString`: name of CSV file containing data
  - `component::InfrastructureSystemsComponent`: component associated with the data
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
"""
function Deterministic(
    name::AbstractString,
    filename::AbstractString,
    component::InfrastructureSystemsComponent,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    component_name = get_name(component)
    raw_data = read_time_series(Deterministic, filename, component_name)
    return Deterministic(
        name,
        raw_data,
        resolution;
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

"""
Construct Deterministic from RawTimeSeries.
"""
function Deterministic(
    name::AbstractString,
    series_data::RawTimeSeries,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    return Deterministic(;
        name = name,
        data = series_data.data,
        resolution = resolution,
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

# Note: interval is not supported in this workflow.

function Deterministic(info::TimeSeriesParsedInfo)
    return Deterministic(
        info.name,
        info.data,
        info.resolution;
        normalization_factor = info.normalization_factor,
    )
end

"""
Construct a new Deterministic from an existing instance and a subset of data.
"""
function Deterministic(forecast::Deterministic, data)
    return Deterministic(
        get_name(forecast),
        data,
        get_resolution(forecast),
        get_interval(forecast),
    )
end

"""
Construct Deterministic that shares the data from an existing instance.

This is useful in cases where you want a component to use the same time series data for
two different attributes.

# Examples
```julia
resolution = Dates.Hour(1)
data = Dict(
    DateTime("2020-01-01T00:00:00") => ones(24),
    DateTime("2020-01-01T01:00:00") => ones(24),
)
# Define a Deterministic for the first attribute
forecast_max_active_power = Deterministic(
    "max_active_power",
    data,
    resolution,
)
add_time_series!(sys, generator, forecast_max_active_power)
# Reuse time series for second attribute
forecast_max_reactive_power = Deterministic(
    forecast_max_active_power,
    "max_reactive_power",
)
add_time_series!(sys, generator, forecast_max_reactive_power)
```
"""
function Deterministic(
    src::Deterministic,
    name::AbstractString,
)
    # units and ext are not copied. Under the key-centric model there is no shared
    # UUID; the content-addressed data is simply reused with a different name.
    return Deterministic(
        name,
        src.data,
        src.resolution,
        src.interval,
    )
end

# Workaround for a bug/limitation in SortedDict. If a user tries to construct
# SortedDict(i => ones(2) for i in 1:2)
# it won't discern the types and will return SortedDict{Any,Any,Base.Order.ForwardOrdering}
# https://github.com/JuliaCollections/DataStructures.jl/issues/239
# This will only work for the most common use case of Vector{CONSTANT}.
# For other types the user will need to create SortedDict with explicit key-value types.

# If values are no more specific than Any, assume CONSTANT
convert_data(data::AbstractDict{<:Any, Any}) =
    SortedDict{Dates.DateTime, Vector{CONSTANT}}(data...)

# If values are more specific, don't assume CONSTANT but do upgrade some types
convert_data(data::AbstractDict{<:Any, Vector{T}}) where {T} =
    SortedDict{Dates.DateTime, Vector{T}}(data...)

# If everything is fully specified, pass through
convert_data(data::SortedDict{Dates.DateTime, Vector}) = data

function get_array_for_hdf(forecast::Deterministic)
    return transform_array_for_hdf(forecast.data)
end

"""
Get [`Deterministic`](@ref) `name`.
"""
get_name(value::Deterministic) = value.name

"""
Get [`Deterministic`](@ref) `data`.
"""
get_data(value::Deterministic) = value.data

"""
Get [`Deterministic`](@ref) `resolution`.
"""
get_resolution(value::Deterministic) = value.resolution

"""
Get [`Deterministic`](@ref) `interval`.
"""
get_interval(value::Deterministic) = value.interval

# TODO handle typing here in a more principled fashion
eltype_data(forecast::Deterministic) = eltype_data_common(forecast)
get_initial_times(forecast::Deterministic) = get_initial_times_common(forecast)
get_initial_timestamp(forecast::Deterministic) = get_initial_timestamp_common(forecast)

"""
Iterate over the windows in a forecast

# Examples
```julia
for window in iterate_windows(forecast)
    @show values(maximum(window))
end
```
"""
iterate_windows(forecast::Deterministic) = iterate_windows_common(forecast)

get_window(f::Deterministic, initial_time::Dates.DateTime; len = nothing) =
    get_window_common(f, initial_time; len = len)

function make_time_array(forecast::Deterministic)
    # Artificial limitation to reduce scope.
    @assert_op get_count(forecast) == 1
    timestamps = range(
        get_initial_timestamp(forecast);
        step = get_resolution(forecast),
        length = get_horizon_count(forecast),
    )
    data = first(values(get_data(forecast)))
    return TimeSeries.TimeArray(timestamps, data)
end
