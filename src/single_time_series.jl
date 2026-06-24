"""
    mutable struct SingleTimeSeries <: StaticTimeSeries
        name::String
        data::TimeSeries.TimeArray
        internal::InfrastructureSystemsInternal
    end

A single column of time series data for a particular data field in a Component.

In contrast with a forecast, this can represent one continual time series,
such as a series of historical measurements or realizations or a single scenario
(e.g. a weather year or different input assumptions).

# Arguments

  - `name::String`: user-defined name
  - `data::TimeSeries.TimeArray`: timestamp - scalingfactor
  - `resolution::Dates.Period`: Time duration between steps in the time series. The resolution must be the same throughout the time series
  - `internal::InfrastructureSystemsInternal`
"""
mutable struct SingleTimeSeries{T} <: StaticTimeSeries
    "user-defined name"
    name::String
    "timestamp - scalingfactor"
    data::TimeSeries.TimeArray
    "resolution of the time series. The resolution cannot change during the time series."
    resolution::Dates.Period
    internal::InfrastructureSystemsInternal
end

# The element type parameter `T` is the value eltype; infer it from the data so
# callers never have to spell it out. `SingleTimeSeries{T}(...)` (the inner
# constructor) remains available for explicit typing.
function SingleTimeSeries(
    name,
    data::TimeSeries.TimeArray,
    resolution,
    internal::InfrastructureSystemsInternal,
)
    return SingleTimeSeries{eltype(TimeSeries.values(data))}(
        name,
        data,
        resolution,
        internal,
    )
end

function SingleTimeSeries(;
    name,
    data,
    resolution::Union{Nothing, Dates.Period} = nothing,
    normalization_factor = 1.0,
    internal = InfrastructureSystemsInternal(),
)
    if isnothing(resolution)
        resolution = get_resolution(data)
    end
    data = handle_normalization_factor(data, normalization_factor)
    return SingleTimeSeries(
        name,
        data,
        resolution,
        internal,
    )
end

"""
Return the value element type of a `SingleTimeSeries` as a string, e.g.
`"Float64"` or `"...LinearFunctionData"`. This is the `T` of `SingleTimeSeries{T}`.
"""
get_data_type(::SingleTimeSeries{T}) where {T} = string(T)

"""
Construct SingleTimeSeries that shares the data from an existing instance.

This is useful in cases where you want a component to use the same time series data for
two different attribtues.
"""
function SingleTimeSeries(
    src::SingleTimeSeries,
    name::AbstractString,
)
    # units and ext are not copied
    internal = InfrastructureSystemsInternal(; uuid = get_uuid(src))
    return SingleTimeSeries(
        name,
        src.data,
        src.resolution,
        internal,
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
        internal = InfrastructureSystemsInternal(),
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
Construct SingleTimeSeries after constructing a TimeArray from `initial_time` and
`time_steps`.
"""
function SingleTimeSeries(
    name::String,
    resolution::Dates.Period,
    initial_time::Dates.DateTime,
    time_steps::Int,
)
    data = TimeSeries.TimeArray(
        initial_time:resolution:(initial_time + resolution * (time_steps - 1)),
        ones(time_steps),
    )
    return SingleTimeSeries(; name = name, data = data)
end

function SingleTimeSeries(time_series::Vector{SingleTimeSeries})
    @assert !isempty(time_series)
    timestamps =
        collect(Iterators.flatten((TimeSeries.timestamp(get_data(x)) for x in time_series)))
    data = collect(Iterators.flatten((TimeSeries.values(get_data(x)) for x in time_series)))
    ta = TimeSeries.TimeArray(timestamps, data)

    time_series = SingleTimeSeries(;
        name = get_name(time_series[1]),
        data = ta,
    )
    @debug "concatenated time_series" LOG_GROUP_TIME_SERIES time_series
    return time_series
end

function SingleTimeSeries(ts_metadata::SingleTimeSeriesMetadata, data::TimeSeries.TimeArray)
    return SingleTimeSeries(
        get_name(ts_metadata),
        data,
        get_resolution(ts_metadata),
        InfrastructureSystemsInternal(),
    )
end

# The deserialize path calls `T(metadata, data)` with the concrete parametric
# type (e.g. `SingleTimeSeries{Float64}`); forward to the eltype-inferring path.
SingleTimeSeries{T}(
    ts_metadata::SingleTimeSeriesMetadata,
    data::TimeSeries.TimeArray,
) where {T} = SingleTimeSeries(ts_metadata, data)

function SingleTimeSeriesMetadata(ts::SingleTimeSeries; features...)
    return SingleTimeSeriesMetadata(
        get_name(ts),
        get_resolution(ts),
        get_initial_timestamp(ts),
        length(ts),
        Dict{String, Any}(string(k) => v for (k, v) in features),
    )
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
    len = length(ts.data)
    len < 2 && throw(ArgumentError("data array length must be at least 2: $len"))
    try
        check_resolution(TimeSeries.timestamp(ts.data), ts.resolution)
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
    return
end

"""
Get [`SingleTimeSeries`](@ref) `name`.
"""
get_name(value::SingleTimeSeries) = value.name
"""
Get [`SingleTimeSeries`](@ref) `data`.
"""
get_data(value::SingleTimeSeries) = value.data
"""
Get [`SingleTimeSeries`](@ref) `resolution`.
"""
get_resolution(value::SingleTimeSeries) = value.resolution
"""
Get [`SingleTimeSeries`](@ref) `internal`.
"""
get_internal(value::SingleTimeSeries) = value.internal

"""
Set [`SingleTimeSeries`](@ref) `name`.
"""
set_name!(value::SingleTimeSeries, val) = value.name = val
"""
Set [`SingleTimeSeries`](@ref) `data`.
"""
set_data!(value::SingleTimeSeries, val) = value.data = val
"""
Set [`SingleTimeSeries`](@ref) `internal`.
"""
set_internal!(value::SingleTimeSeries, val) = value.internal = val

eltype_data(ts::SingleTimeSeries) = eltype(TimeSeries.values(ts.data))

get_initial_timestamp(time_series::SingleTimeSeries) =
    TimeSeries.timestamp(get_data(time_series))[1]

function get_array_for_hdf(ts::SingleTimeSeries)
    return transform_array_for_hdf(TimeSeries.values(ts.data))
end

function Base.getindex(time_series::SingleTimeSeries, args...)
    return SingleTimeSeries(time_series, getindex(get_data(time_series), args...))
end

Base.first(time_series::SingleTimeSeries) = head(time_series, 1)

Base.last(time_series::SingleTimeSeries) = tail(time_series, 1)

Base.firstindex(time_series::SingleTimeSeries) = firstindex(get_data(time_series))

Base.lastindex(time_series::SingleTimeSeries) = lastindex(get_data(time_series))

Base.lastindex(time_series::SingleTimeSeries, d) = lastindex(get_data(time_series), d)

Base.eachindex(time_series::SingleTimeSeries) = eachindex(get_data(time_series))

Base.iterate(time_series::SingleTimeSeries, n = 1) = iterate(get_data(time_series), n)

"""
Refer to TimeSeries.when(). Underlying data is copied.
"""
function when(time_series::SingleTimeSeries, period::Function, t::Integer)
    return SingleTimeSeries(time_series, TimeSeries.when(get_data(time_series), period, t))
end

"""
Return a time_series truncated starting with timestamp.
"""
function from(time_series::SingleTimeSeries, timestamp)
    return SingleTimeSeries(;
        name = get_name(time_series),
        data = TimeSeries.from(get_data(time_series), timestamp),
    )
end

"""
Return a time_series truncated after timestamp.
"""
function to(time_series::SingleTimeSeries, timestamp)
    return SingleTimeSeries(;
        name = get_name(time_series),
        data = TimeSeries.to(get_data(time_series), timestamp),
    )
end

"""
Return a time_series with only the first num values.
"""
function head(time_series::SingleTimeSeries)
    return SingleTimeSeries(time_series, TimeSeries.head(get_data(time_series)))
end

function head(time_series::SingleTimeSeries, num)
    return SingleTimeSeries(time_series, TimeSeries.head(get_data(time_series), num))
end

"""
Return a time_series with only the ending num values.
"""
function tail(time_series::SingleTimeSeries)
    return SingleTimeSeries(time_series, TimeSeries.tail(get_data(time_series)))
end

function tail(time_series::SingleTimeSeries, num)
    return SingleTimeSeries(time_series, TimeSeries.tail(get_data(time_series), num))
end

"""
Creates a new SingleTimeSeries from an existing instance and a subset of data.
"""
function SingleTimeSeries(time_series::SingleTimeSeries, data::TimeSeries.TimeArray)
    vals = []
    for (fname, ftype) in zip(fieldnames(SingleTimeSeries), fieldtypes(SingleTimeSeries))
        if ftype <: TimeSeries.TimeArray
            val = data
        elseif ftype <: InfrastructureSystemsInternal
            # Need to create a new UUID.
            val = InfrastructureSystemsInternal()
        else
            val = getproperty(time_series, fname)
        end

        push!(vals, val)
    end

    return SingleTimeSeries(vals...)
end

get_columns(::Type{<:TimeSeriesMetadata}, ta::TimeSeries.TimeArray) = nothing

function make_time_array(
    time_series::SingleTimeSeries,
    start_time::Dates.DateTime;
    len::Union{Nothing, Int} = nothing,
)
    ta = get_data(time_series)
    first_time = first(TimeSeries.timestamp(ta))
    if start_time == first_time && (len === nothing || len == length(ta))
        return ta
    end

    resolution = Dates.Millisecond(get_resolution(ta))
    start_index = Int((start_time - first_time) / resolution) + 1
    end_index = start_index + len - 1
    return ta[start_index:end_index]
end

function SingleTimeSeriesMetadata(ts_metadata::DeterministicMetadata)
    return SingleTimeSeriesMetadata(;
        name = get_name(ts_metadata),
        resolution = get_resolution(ts_metadata),
        initial_timestamp = get_initial_timestamp(ts_metadata),
        length = get_count(ts_metadata) * get_horizon_count(ts_metadata),
        internal = get_internal(ts_metadata),
    )
end
