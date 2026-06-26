"""
    mutable struct Probabilistic <: Forecast
        name::String
        resolution::Dates.Period
        interval::Dates.Period
        percentiles::Vector{Float64}
        data::SortedDict
        internal::InfrastructureSystemsInternal
    end

A Probabilistic forecast for a particular data field in a Component.

# Arguments

  - `name::String`: user-defined name
  - `resolution::Dates.Period`: forecast resolution
  - `interval::Dates.Period`: forecast interval
  - `percentiles::Vector{Float64}`: Percentiles for the probabilistic forecast
  - `data::SortedDict`: timestamp - scalingfactor
  - `internal::InfrastructureSystemsInternal`
"""
struct Probabilistic{T, N} <: Forecast
    "user-defined name"
    name::String
    "timestamp - scalingfactor (per-window arrays of rank `N`)"
    data::SortedDict{Dates.DateTime, Array{T, N}}
    "Percentiles for the probabilistic forecast"
    percentiles::Vector{Float64}
    "forecast resolution"
    resolution::Dates.Period
    "forecast interval"
    interval::Dates.Period
end

# Infer `{T, N}` — element type and per-window array rank — from the data.
function Probabilistic(
    name::AbstractString,
    data::AbstractDict{Dates.DateTime},
    percentiles,
    resolution::Dates.Period,
    interval::Dates.Period,
)
    sorted = data isa SortedDict ? data : SortedDict(data...)
    return Probabilistic{_window_eltype(sorted), _window_ndims(sorted)}(
        String(name),
        sorted,
        Vector{Float64}(percentiles),
        resolution,
        interval,
    )
end

function Probabilistic(;
    name,
    data::SortedDict{Dates.DateTime, Matrix{Float64}},
    resolution::Dates.Period,
    interval::Union{Nothing, Dates.Period} = nothing,
    percentiles,
    normalization_factor = 1.0,
)
    data = handle_normalization_factor(convert_data(data), normalization_factor)
    quantile_count = size(first(values(data)))[2]
    if quantile_count != length(percentiles)
        throw(
            ArgumentError(
                "The amount of elements in the data doesn't match the length of the percentiles",
            ),
        )
    end

    if isnothing(interval)
        interval = get_interval_from_initial_times(get_sorted_keys(data))
    end

    return Probabilistic(
        name,
        data,
        percentiles,
        resolution,
        interval,
    )
end

"""
Construct Probabilistic from a SortedDict of Arrays.

# Arguments

  - `name::AbstractString`: user-defined name
  - `data::AbstractDict{Dates.DateTime, Matrix{Float64}}`: time series data.
  - `percentiles`: Percentiles represented in the probabilistic forecast
  - `resolution::Dates.Period`: The resolution of the forecast in Dates.Period`
  - `interval::Union{Nothing, Dates.Period}`: If nothing, infer interval from the
    data. Otherwise, it must be the difference in time between the start of each window.
    Interval is required if the type is irregular, such as with Dates.Month or Dates.Year.
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
"""
function Probabilistic(
    name::AbstractString,
    data::SortedDict{Dates.DateTime, Matrix{Float64}},
    percentiles::Vector,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    return Probabilistic(;
        name = name,
        data = data,
        percentiles = percentiles,
        resolution = resolution,
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

function Probabilistic(
    name::AbstractString,
    data::AbstractDict{Dates.DateTime, Matrix{Float64}},
    percentiles::Vector,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    return Probabilistic(
        name,
        SortedDict(data...),
        percentiles,
        resolution;
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

"""
Construct Probabilistic from a Dict of TimeArrays.

# Arguments

  - `name::AbstractString`: user-defined name
  - `input_data::AbstractDict{Dates.DateTime, TimeSeries.TimeArray}`: time series data.
  - `percentiles`: Percentiles represented in the probabilistic forecast
  - `resolution::Union{Nothing, Dates.Period} = nothing`: If nothing, infer resolution from the
    data. Otherwise, this must be the difference between each consecutive timestamps. This is
    required if the resolution is irregular, such as Dates.Month or Dates.Year.
  - `interval::Union{Nothing, Dates.Period} = nothing`: If nothing, infer interval from the
    data. Otherwise, it must be the difference in time between the start of each window.
    Interval is required if the type is irregular, such as with Dates.Month or Dates.Year.
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
  - `timestamp = :timestamp`: If the values are DataFrames is passed then this must be the column name that
    contains timestamps.
"""
function Probabilistic(
    name::AbstractString,
    input_data::AbstractDict{Dates.DateTime, <:TimeSeries.TimeArray},
    percentiles::Vector{Float64};
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    data, res = convert_forecast_input_time_arrays(input_data; resolution = resolution)
    return Probabilistic(;
        name = name,
        data = data,
        percentiles = percentiles,
        resolution = res,
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

"""
Construct Deterministic from RawTimeSeries.
"""
function Probabilistic(
    name::AbstractString,
    series_data::RawTimeSeries,
    percentiles::Vector,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
)
    return Probabilistic(;
        name = name,
        data = series_data.data,
        percentiles = percentiles,
        resolution = resolution,
        interval = interval,
        normalization_factor = normalization_factor,
    )
end

# Note: interval is not support in this workflow.

function Probabilistic(info::TimeSeriesParsedInfo)
    return Probabilistic(;
        name = info.name,
        data = info.data,
        percentiles = info.percentiles,
        resolution = info.resolution,
        normalization_factor = info.normalization_factor,
    )
end

"""
Construct a Probabilistic that shares the data from an existing instance.

This is useful in cases where you want a component to use the same time series data for
two different attributes.
"""
function Probabilistic(
    src::Probabilistic,
    name::AbstractString,
)
    # units and ext are not copied. No shared UUID under the key-centric model.
    return Probabilistic(
        name,
        src.data,
        src.percentiles,
        src.resolution,
        src.interval,
    )
end

convert_data(
    data::AbstractDict{<:Any, Matrix{T}},
) where {T <: Union{CONSTANT, FunctionData}} =
    SortedDict{Dates.DateTime, Matrix{T}}(data...)
convert_data(
    data::SortedDict{Dates.DateTime, Matrix{T}},
) where {T <: Union{CONSTANT, FunctionData}} = data

"""
Get [`Probabilistic`](@ref) `name`.
"""
get_name(value::Probabilistic) = value.name
"""
Get [`Probabilistic`](@ref) `resolution`.
"""
get_resolution(value::Probabilistic) = value.resolution
"""
Get [`Probabilistic`](@ref) `interval`.
"""
get_interval(value::Probabilistic) = value.interval
"""
Get [`Probabilistic`](@ref) `percentiles`.
"""
get_percentiles(value::Probabilistic) = value.percentiles
"""
Get [`Probabilistic`](@ref) `data`.
"""
get_data(value::Probabilistic) = value.data

function get_array_for_hdf(forecast::Probabilistic)
    interval_count = get_count(forecast)
    percentile_count = length(get_percentiles(forecast))
    horizon_count = get_horizon_count(forecast)
    data = get_data(forecast)

    data_for_hdf = Array{Float64, 3}(undef, percentile_count, horizon_count, interval_count)
    for (ix, f) in enumerate(values(data))
        data_for_hdf[:, :, ix] = transpose(f)
    end
    return data_for_hdf
end

# TODO see Deterministic
eltype_data(forecast::Probabilistic) = eltype_data_common(forecast)
get_initial_times(forecast::Probabilistic) = get_initial_times_common(forecast)
get_initial_timestamp(forecast::Probabilistic) = get_initial_timestamp_common(forecast)
get_window(f::Probabilistic, initial_time::Dates.DateTime; len = nothing) =
    get_window_common(f, initial_time; len = len)

"""
Iterate over the windows in a forecast

# Examples
```julia
for window in iterate_windows(forecast)
    @show values(maximum(window))
end
```
"""
iterate_windows(forecast::Probabilistic) = iterate_windows_common(forecast)
