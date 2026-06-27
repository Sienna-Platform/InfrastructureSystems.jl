const TIME_SERIES_STRING_TO_TYPE = Dict(
    "Deterministic" => Deterministic,
    "DeterministicSingleTimeSeries" => DeterministicSingleTimeSeries,
    "NonSequentialTimeSeries" => NonSequentialTimeSeries,
    "Probabilistic" => Probabilistic,
    "Scenarios" => Scenarios,
    "SingleTimeSeries" => SingleTimeSeries,
)

"""
Check if the timestamps have a constant resolution.
Handles constant periods like Second and Minute as well as irregular periods like Month and Year.
Relies on the _calendrical_ arithmetic of the Julia's Dates library.
https://docs.julialang.org/en/v1/stdlib/Dates/#TimeType-Period-Arithmetic

# Arguments
- `timestamps`: An indexable sequence of DateTime values
- `resolution`: a Dates.Period value
"""
function check_resolution(timestamps, resolution::Dates.Period)
    if length(timestamps) < 2
        throw(ArgumentError("At least two timestamps are required"))
    end
    # Note this behavior in Julia:
    # julia> DateTime("2020-02-01T00:00:00") + Month(1)
    # 2020-03-01T00:00:00
    for i in 2:length(timestamps)
        if timestamps[i] != timestamps[i - 1] + resolution
            throw(
                ConflictingInputsError(
                    "resolution mismatch: t$(i - 1) = $(timestamps[i - 1]) t$(i) = $(timestamps[i]) " *
                    "resolution = $(Dates.canonicalize(resolution))",
                ),
            )
        end
    end
end

function get_initial_timestamp(data::TimeSeries.TimeArray)
    return TimeSeries.timestamp(data)[1]
end

function get_initial_times(
    initial_timestamp::Dates.DateTime,
    count::Int,
    interval::Dates.Period,
)
    if count == 0
        return []
    elseif interval == Dates.Second(0)
        return [initial_timestamp]
    end

    return range(initial_timestamp; length = count, step = interval)
end

"""
Given a series of timestamps that start with initial_time and increment by resolution,
return the index of other time in the array of timestamps.

# Examples
```julia
julia> compute_time_array_index(
    DateTime("2024-01-01T00:00:00"),
    DateTime("2024-01-01T05:00:00"),
    Hour(1),
)
6
julia> compute_time_array_index(
    DateTime("2024-01-01T00:00:00"),
    DateTime("2024-04-01T00:00:00"),
    Month(1),
)
4
julia> compute_time_array_index(
    DateTime("2024-01-01T00:00:00"),
    DateTime("2028-01-01T00:00:00"),
    Year(1),
)
5
```
"""
function compute_time_array_index(
    initial_time::Dates.DateTime,
    other_time::Dates.DateTime,
    resolution::Dates.Period,
)
    initial_time == other_time && return 1
    num_periods = compute_periods_between(initial_time, other_time, resolution)
    index = num_periods + 1
    return index
end

"""
Given a series of timestamps that increment by period, return the number of periods
between t1 and t2.

t2 must be greater than or equal to t1.
There must be an even number of periods between t1 and t2.
period can be regular (e.g., Hour) or irregular (e.g., Month).

# Arguments
- `t1`: The initial timestamp.
- `t2`: The second timestamp.
- `period`: The period to use for the index.

# Examples
```julia
julia> compute_periods_between(
    DateTime("2024-01-01T00:00:00"),
    DateTime("2024-01-01T05:00:00"),
    Hour(1),
)
5
julia> compute_period_index(
    DateTime("2024-02-01T00:00:00"),
    DateTime("2024-04-01T00:00:00"),
    Month(1),
)
2
julia> compute_period_index(
    DateTime("2024-01-01T00:00:00"),
    DateTime("2028-01-01T00:00:00"),
    Year(1),
)
4
```
"""
function compute_periods_between(
    t1::Dates.DateTime,
    t2::Dates.DateTime,
    period::Dates.Period,
)
    time_diff = t2 - t1
    return _compute_periods_between_common(t1, t2, period, time_diff, Dates.Millisecond(0))
end

function compute_periods_between(
    t1::Dates.DateTime,
    t2::Dates.DateTime,
    period::Dates.Month,
)
    year1, month1 = Dates.yearmonth(t1)
    year2, month2 = Dates.yearmonth(t2)
    time_diff = (year2 - year1) * 12 + (month2 - month1)
    return _compute_periods_between_common(t1, t2, Dates.value(period), time_diff, 0)
end

function compute_periods_between(
    t1::Dates.DateTime,
    t2::Dates.DateTime,
    period::Dates.Quarter,
)
    year1 = Dates.year(t1)
    quarter1 = Dates.quarter(t1)
    year2 = Dates.year(t2)
    quarter2 = Dates.quarter(t2)
    time_diff = (year2 - year1) * 4 + (quarter2 - quarter1)
    return _compute_periods_between_common(t1, t2, Dates.value(period), time_diff, 0)
end

function compute_periods_between(t1::Dates.DateTime, t2::Dates.DateTime, period::Dates.Year)
    time_diff = Dates.year(t2) - Dates.year(t1)
    return _compute_periods_between_common(t1, t2, Dates.value(period), time_diff, 0)
end

function _compute_periods_between_common(
    t1::Dates.DateTime,
    t2::Dates.DateTime,
    period,
    time_diff,
    zero_val,
)
    if t1 > t2
        throw(ArgumentError("t1 must be less than t2"))
    end

    if time_diff % period != zero_val
        throw(ArgumentError("$t2 - $t1 is not evenly divisible by $period"))
    end

    return time_diff ÷ period
end

"""
Return the resolution from a TimeArray by subtracting the first two timestamps.
"""
function get_resolution(ts::TimeSeries.TimeArray)
    if length(ts) < 2
        throw(ConflictingInputsError("Resolution can't be inferred from the data."))
    end

    timestamps = TimeSeries.timestamp(ts)
    resolution = timestamps[2] - timestamps[1]
    return resolution
end

get_sorted_keys(x::AbstractDict) = sort(collect(keys(x)))
get_sorted_keys(x::SortedDict) = collect(keys(x))

function get_total_period(
    initial_timestamp::Dates.DateTime,
    count::Int,
    interval::Dates.Period,
    horizon::Dates.Period,
    resolution::Dates.Period,
)
    horizon_count = get_horizon_count(horizon, resolution)
    last_it = initial_timestamp + interval * count
    last_timestamp = last_it + resolution * (horizon_count - 1)
    return last_timestamp - initial_timestamp
end

# These functions allow us to preserve type and value of periods in databases and files.
# We are not using string(period) because the Dates package behaves differently for
# singular vs plural and uses lower case. This is simpler.

function to_iso_8601(period::Dates.Millisecond)
    return @sprintf("P0DT%.3fS", Float64(period.value) / 1000.0)
end

to_iso_8601(period::Dates.Second) = @sprintf("P0DT%dS", period.value)
to_iso_8601(period::Dates.Minute) = @sprintf("P0DT%dM", period.value)
to_iso_8601(period::Dates.Hour) = @sprintf("P0DT%dH", period.value)
to_iso_8601(period::Dates.Day) = @sprintf("P%dD", period.value)
to_iso_8601(period::Dates.Week) = @sprintf("P%dW", period.value)
to_iso_8601(period::Dates.Month) = @sprintf("P%dM", period.value)
to_iso_8601(period::Dates.Quarter) = error("Dates.Quarter is not supported")
# We don't have a way to deserialize this into Dates.Quarter.
# to_iso_8601(period::Dates.Quarter) = @sprintf("P%dM", period.value * 3)
to_iso_8601(period::Dates.Year) = @sprintf("P%dY", period.value)

const REGEX_PERIODS = OrderedDict(
    "milliseconds" => r"^P0DT(\d+\.\d+)S$",
    "seconds" => r"^P0DT(\d+)S$",
    "minutes" => r"^P0DT(\d+)M$",
    "hours" => r"^P0DT(\d+)H$",
    "days" => r"^P(\d+)D$",
    "weeks" => r"^P(\d+)W$",
    "months" => r"^P(\d+)M$",
    "years" => r"^P(\d+)Y$",
)

const PERIOD_NAME_TO_TYPE = Dict(
    "milliseconds" => Dates.Millisecond,
    "seconds" => Dates.Second,
    "minutes" => Dates.Minute,
    "hours" => Dates.Hour,
    "days" => Dates.Day,
    "weeks" => Dates.Week,
    "months" => Dates.Month,
    "years" => Dates.Year,
)

@assert keys(REGEX_PERIODS) == keys(PERIOD_NAME_TO_TYPE)

# this return type annotation saves significant inference time in PSI.
function from_iso_8601(period::String)::Dates.Period
    for (name, regex) in REGEX_PERIODS
        m = match(regex, period)
        if !isnothing(m)
            if name == "milliseconds"
                value = parse(Float64, m.captures[1]) * 1000
                if value % 1 != 0.0
                    throw(
                        ArgumentError("Fractional milliseconds are not supported: $value"),
                    )
                end
            else
                value = parse(Int, m.captures[1])
            end
            return PERIOD_NAME_TO_TYPE[name](value)
        end
    end

    throw(ArgumentError("Unsupported period string: $period"))
end

is_irregular_period(period::Dates.Period) = false
is_irregular_period(period::Dates.Month) = true
is_irregular_period(period::Dates.Year) = true
is_irregular_period(period::Dates.Quarter) = true
