"""
Supertype for forecast time series
Current concrete subtypes are:
- [`Deterministic`](@ref)
- [`Scenarios`](@ref)
- [`Probabilistic`](@ref)
- [`DeterministicSingleTimeSeries`](@ref) — a query-only marker; reads materialize a
  [`Deterministic`](@ref)

Instantiable subtypes of Forecast must implement:
- `get_horizon_count`
- `get_initial_times`
- `get_initial_timestamp`
- `get_name`
- `get_window`
- `iterate_windows`
"""
abstract type Forecast{T} <: TimeSeriesData{T} end

Base.length(ts::Forecast) = get_count(ts)

"""
Supertype for all deterministic forecast time series.

Concrete subtypes are [`Deterministic`](@ref) and the query-only marker
[`DeterministicSingleTimeSeries`](@ref).
"""
abstract type AbstractDeterministic{T} <: Forecast{T} end

function check_time_series_data(forecast::Forecast)
    _check_forecast_data(forecast)
    _check_forecast_interval(forecast)
end

function _check_forecast_data(forecast::Forecast)
    data = get_data(forecast)
    isempty(data) && throw(ArgumentError("Forecast data cannot be empty"))
    # Dimension 1 is time for every window shape; `length` would count the members of a
    # (horizon, member) Probabilistic/Scenarios matrix instead of its horizon.
    required_horizon = size(first(values(data)), 1)
    required_horizon < 2 &&
        throw(ArgumentError("Forecast arrays must have a length of at least 2."))
    horizons = Set((size(x, 1) for x in values(data)))
    length(horizons) != 1 &&
        throw(DimensionMismatch("All forecast windows must have the same horizon"))
    return
end

function _check_forecast_interval(forecast::Forecast)
    initial_times = collect(get_initial_times(forecast))
    # Perhaps this should be an error...unfortunately, a lot of tests depend on it.
    length(initial_times) == 1 && return

    try
        check_resolution(initial_times, get_interval(forecast))
    catch e
        if e isa ConflictingInputsError
            throw(
                ConflictingInputsError(
                    "The interval in the forecast is inconsistent. If the intended interval is " *
                    "irregular, such as with Dates.Month and Dates.Year, " *
                    "pass the interval as a keyword argument to the forecast constructor.",
                ),
            )
        end
        rethrow()
    end
end

# Element type and per-window array rank of a forecast's window dict, used to infer
# the `{T, N}` parameters of the concrete forecast structs.
_window_eltype(data::AbstractDict) = eltype(valtype(data))
_window_ndims(data::AbstractDict) = ndims(valtype(data))

# Normalize a window dict to a `SortedDict`; copy-free when it already is one.
_ensure_sorted_dict(data::SortedDict) = data
_ensure_sorted_dict(data::AbstractDict) = SortedDict(data)

# This method requires that the forecast type implement a `get_data` method like
# Deterministic.
function get_count(forecast::Forecast)
    return length(get_data(forecast))
end

function get_horizon(forecast::Forecast)
    return get_horizon_count(forecast) * get_resolution(forecast)
end

function get_horizon_count(data::AbstractDict)
    return size(first(values(data)))[1]
end

get_horizon_count(forecast::Forecast) = get_horizon_count(get_data(forecast))

"""
Return the initial times in the forecast.
"""
function get_initial_times(f::Forecast)
    return get_initial_times(get_initial_timestamp(f), get_count(f), get_interval(f))
end

# This method requires that the forecast type implement a `get_data` method like
# Deterministic. Allows for optimized execution.
function get_initial_times_common(forecast::Forecast)
    return keys(get_data(forecast))
end

"""
Return the total period covered by the forecast: from its first timestamp to the last
timestamp of its last window.
"""
function get_total_period(f::Forecast)
    return get_total_period(
        get_initial_timestamp(f),
        get_count(f),
        get_interval(f),
        get_horizon(f),
        get_resolution(f),
    )
end

function get_horizon_count(horizon::Dates.Period, resolution::Dates.Period)
    if horizon % resolution != Dates.Millisecond(0)
        error(
            "horizon is not evenly divisible by resolution: horizon = $horizon " *
            "resolution = $resolution",
        )
    end
    return horizon ÷ resolution
end

"""
Return the forecast window corresponding to a 1-based interval index: `index = 1` is the
first window, `index = get_count(forecast)` is the last.
"""
function get_window(forecast::Forecast, index::Int; len = nothing)
    return get_window(forecast, index_to_initial_time(forecast, index); len = len)
end

function iterate_windows_common(forecast)
    return (get_window(forecast, it) for it in keys(get_data(forecast)))
end

"""
Return the Dates.DateTime corresponding to a 1-based interval index: `index = 1` maps to
the forecast's initial timestamp and `index = get_count(forecast)` to the last window.
"""
function index_to_initial_time(forecast::Forecast, index::Int)
    count = get_count(forecast)
    (index >= 1 && index <= count) || throw(
        ArgumentError(
            "window index=$index is out of range; the forecast has $count windows " *
            "(valid indices are 1 through $count)",
        ),
    )
    return get_initial_timestamp(forecast) + get_interval(forecast) * (index - 1)
end

"""
Return a TimeSeries.TimeArray for one forecast window.
"""
function make_time_array(
    forecast::Forecast,
    start_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
)
    return get_window(forecast, start_time; len = len)
end

function make_timestamps(forecast::Forecast, initial_time::Dates.DateTime, len = nothing)
    if isnothing(len)
        len = get_horizon_count(forecast)
    end

    return range(initial_time; length = len, step = get_resolution(forecast))
end

# This method requires that the forecast type implement a `get_data` method like
# Deterministic. Allows for optimized execution.
function get_initial_timestamp_common(forecast)
    return first(keys(get_data(forecast)))
end

"""
Return the interval by subtracting the first two initial times.
"""
function get_interval_from_initial_times(initial_times::Vector{Dates.DateTime})
    isempty(initial_times) && throw(ArgumentError("Forecast data cannot be empty"))
    if length(initial_times) == 1
        return Dates.Second(0)
    end
    first_it, state = iterate(initial_times)
    second_it, state = iterate(initial_times, state)
    return second_it - first_it
end

function get_interval_from_initial_times(x::Vector{T}) where {T}
    throw(ArgumentError("Cannot compute interval from initial times of type $(T)."))
end

# This method requires that the forecast type implement a `get_data` method like
# Deterministic.
function get_window_common(
    forecast,
    initial_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
)
    horizon_count = get_horizon_count(forecast)
    if isnothing(len)
        len = horizon_count
    end
    (len >= 1 && len <= horizon_count) || throw(
        ArgumentError(
            "requested len=$len is outside the forecast horizon of $horizon_count steps",
        ),
    )

    all_data = get_data(forecast)
    # One tree lookup on the per-window path; the miss branch is cold.
    data = get(all_data, initial_time, nothing)
    if isnothing(data)
        initial_times = collect(keys(all_data))
        throw(
            ArgumentError(
                "start_time=$initial_time is not a forecast window initial time; " *
                "valid windows run from $(first(initial_times)) to " *
                "$(last(initial_times)) every $(get_interval(forecast))",
            ),
        )
    end
    if ndims(data) == 2
        # A Probabilistic / Scenarios window is a (horizon, member) matrix; the time
        # axis is the first dimension either way.
        data = @view data[1:len, :]
    else
        data = @view data[1:len]
    end

    return TimeSeries.TimeArray(make_timestamps(forecast, initial_time, len), data)
end

"""
Convert a Dict of TimeSeries.TimeArray to a SortedDict of Arrays.
Before converting, check that the resolution is consistent in all time arrays.
Return the SortedDict and the resolution.
"""
function convert_forecast_input_time_arrays(
    data::AbstractDict{Dates.DateTime, <:TimeSeries.TimeArray};
    resolution::Union{Dates.Period, Nothing} = nothing,
)
    data_type = typeof(TimeSeries.values(first(values(data))))
    if isnothing(resolution)
        resolution = get_resolution(first(values(data)))
    end
    sorted_data = SortedDict{Dates.DateTime, data_type}()
    for (timestamp, ta) in data
        check_resolution(TimeSeries.timestamp(ta), resolution)
        sorted_data[timestamp] = TimeSeries.values(ta)
    end

    return sorted_data, resolution
end
