"""
    mutable struct Scenarios <: Forecast
        name::String
        resolution::Dates.Period
        interval::Dates.Period
        scenario_count::Int
        data::SortedDict
        units::Union{Nothing, String}
        quantity_kind::Union{Nothing, String}
        unit_system::Union{Nothing, AbstractUnitSystem}
        internal::InfrastructureSystemsInternal
    end

A Discrete Scenario Based time series for a particular data field in a Component.

# Arguments

  - `name::String`: user-defined name
  - `resolution::Dates.Period`: forecast resolution
  - `interval::Dates.Period`: forecast interval
  - `scenario_count::Int`: Number of scenarios
  - `data::SortedDict`: timestamp - scalingfactor
  - `units::Union{Nothing, String}`: optional user-declared units label for the values
    (e.g. `"MW"`)
  - `quantity_kind::Union{Nothing, String}`: optional label for the kind of physical
    quantity the values measure (e.g. `"ActivePower"`)
  - `unit_system::Union{Nothing, AbstractUnitSystem}`: optional declaration of the basis
    the values are already expressed in (`NU`, `DU`, or `SU`)
  - `internal::InfrastructureSystemsInternal`

See [`get_units`](@ref), [`get_quantity_kind`](@ref), [`get_unit_system`](@ref).
"""
struct Scenarios{T, N} <: Forecast{T}
    "user-defined name"
    name::String
    "timestamp - scalingfactor (per-window arrays of rank `N`)"
    data::SortedDict{Dates.DateTime, Array{T, N}}
    "Number of scenarios"
    scenario_count::Int
    "forecast resolution"
    resolution::Dates.Period
    "forecast interval"
    interval::Dates.Period
    "user-declared units label for the values (e.g. `\"MW\"`), or `nothing`"
    units::Union{Nothing, String}
    "kind of physical quantity the values measure (e.g. `\"ActivePower\"`), or `nothing`"
    quantity_kind::Union{Nothing, String}
    "unit system the values are already expressed in (`NU`/`DU`/`SU`), or `nothing`"
    unit_system::Union{Nothing, AbstractUnitSystem}
end

# Infer `{T, N}` — element type and per-window array rank — from the data.
function Scenarios(
    name::AbstractString,
    data::AbstractDict{Dates.DateTime},
    scenario_count::Int,
    resolution::Dates.Period,
    interval::Dates.Period;
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    sorted = _ensure_sorted_dict(data)
    return Scenarios{_window_eltype(sorted), _window_ndims(sorted)}(
        String(name),
        sorted,
        scenario_count,
        resolution,
        interval,
        _maybe_string(units),
        _maybe_string(quantity_kind),
        unit_system,
    )
end

function Scenarios(;
    name::AbstractString,
    data::SortedDict{Dates.DateTime, Matrix{Float64}},
    scenario_count::Int,
    resolution::Dates.Period,
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    data = handle_normalization_factor(convert_data(data), normalization_factor)

    if isnothing(interval)
        interval = get_interval_from_initial_times(get_sorted_keys(data))
    end

    return Scenarios(
        name,
        data,
        scenario_count,
        resolution,
        interval;
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
    )
end

"""
Construct Scenarios from a SortedDict of Arrays.

# Arguments

  - `name::AbstractString`: user-defined name
  - `input_data::SortedDict{Dates.DateTime, Matrix{Float64}}`: time series data.
  - `resolution::Dates.Period`: The resolution of the forecast in `Dates.Period`
  - `interval::Union{Nothing, Dates.Period}`: If nothing, infer interval from the
    data. Otherwise, this must be the difference in time between the start of each window.
    Interval is required if the type is irregular, such as with Dates.Month or Dates.Year.
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
"""
function Scenarios(
    name::AbstractString,
    data::SortedDict{Dates.DateTime, Matrix{Float64}},
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    return Scenarios(;
        name = name,
        data = data,
        scenario_count = size(first(values(data)))[2],
        resolution = resolution,
        interval = interval,
        normalization_factor = normalization_factor,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
    )
end

function Scenarios(
    name::AbstractString,
    data::AbstractDict{Dates.DateTime, Matrix{Float64}},
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    return Scenarios(
        name,
        _ensure_sorted_dict(data),
        resolution;
        interval = interval,
        normalization_factor = normalization_factor,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
    )
end

"""
Construct Scenarios from a Dict of TimeArrays.

# Arguments

  - `name::AbstractString`: user-defined name
  - `input_data::AbstractDict{Dates.DateTime, TimeSeries.TimeArray}`: time series data.
  - `resolution::Union{Nothing, Dates.Period} = nothing`: If nothing, infer resolution from
    the data. Otherwise, it must be the difference between each consecutive timestamps.
    Resolution is required if the type is irregular, such as with Dates.Month or Dates.Year.
  - `interval::Union{Nothing, Dates.Period} = nothing`: If nothing, infer interval from the
    data. Otherwise, it must be the difference in time between the start of each window.
    Interval is required if the type is irregular, such as with Dates.Month or Dates.Year.
  - `normalization_factor::NormalizationFactor = 1.0`: optional normalization factor to apply
    to each data entry
  - `timestamp = :timestamp`: If the values are DataFrames is passed then this must be the column name that
    contains timestamps.
"""
function Scenarios(
    name::AbstractString,
    input_data::AbstractDict{Dates.DateTime, <:TimeSeries.TimeArray};
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
)
    data, res = convert_forecast_input_time_arrays(input_data; resolution = resolution)
    return Scenarios(;
        name = name,
        data = data,
        resolution = res,
        interval = interval,
        scenario_count = size(first(values(input_data)))[2],
        normalization_factor = normalization_factor,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
    )
end

"""
Construct Scenarios that shares the data from an existing instance.

This is useful in cases where you want a component to use the same time series data for
two different attributes.
"""
function Scenarios(
    src::Scenarios,
    name::AbstractString,
)
    return Scenarios(
        name,
        src.data,
        src.scenario_count,
        src.resolution,
        src.interval;
        units = src.units,
        quantity_kind = src.quantity_kind,
        unit_system = src.unit_system,
    )
end

"""
Get [`Scenarios`](@ref) `name`.
"""
get_name(value::Scenarios) = value.name
"""
Get [`Scenarios`](@ref) `resolution`.
"""
get_resolution(value::Scenarios) = value.resolution
"""
Get [`Scenarios`](@ref) `interval`.
"""
get_interval(value::Scenarios) = value.interval
"""
Get [`Scenarios`](@ref) `scenario_count`.
"""
get_scenario_count(value::Scenarios) = value.scenario_count
"""
Get [`Scenarios`](@ref) `data`.
"""
get_data(value::Scenarios) = value.data

get_initial_times(forecast::Scenarios) = get_initial_times_common(forecast)
get_initial_timestamp(forecast::Scenarios) = get_initial_timestamp_common(forecast)
get_window(f::Scenarios, initial_time::Dates.DateTime; len = nothing) =
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
iterate_windows(forecast::Scenarios) = iterate_windows_common(forecast)
