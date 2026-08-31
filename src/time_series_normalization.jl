@scoped_enum NormalizationTypes MAX = 1

@doc """
Types of normalization that can be applied to time series data.

# Values
- `MAX`: Normalize by the maximum value in the time series
""" NormalizationTypes

const NormalizationFactor = Union{Float64, NormalizationTypes}

get_max_value(ta::TimeSeries.TimeArray) = maximum(TimeSeries.values(ta))
get_max_value(ta::AbstractArray) = maximum(ta)

"""
Divide every window of `data` by `factor`, returning a new `SortedDict`. The caller's
dictionary is never modified.
"""
function _divide_windows(data::AbstractDict, factor::Float64)
    isempty(data) && return SortedDict{Dates.DateTime, valtype(data)}()
    entries = [k => v ./ factor for (k, v) in data]
    # The quotient's type, not the input's: dividing an integer window yields floats, and
    # the result dict has to be able to hold them.
    V = typeof(first(entries).second)
    return SortedDict{Dates.DateTime, V}(entries)
end

"""
Normalize forecast window data by the maximum value across *all* windows, matching the
[`SingleTimeSeries`](@ref) semantics. Returns a new dictionary.
"""
function handle_normalization_factor(
    data::AbstractDict,
    normalization_factor::NormalizationTypes,
)
    if normalization_factor != NormalizationTypes.MAX
        throw(
            ArgumentError(
                "support for normalization_factor=$normalization_factor not implemented",
            ),
        )
    end
    isempty(data) && throw(ArgumentError("Forecast data cannot be empty"))
    max_value = maximum(get_max_value(v) for v in values(data))
    if iszero(max_value)
        throw(
            ArgumentError(
                "normalization_factor = max with a max value of 0.0 is not supported",
            ),
        )
    end
    return _divide_windows(data, max_value)
end

function handle_normalization_factor(data::AbstractDict, normalization_factor::Float64)
    if iszero(normalization_factor)
        throw(ArgumentError("A normalization_factor of 0.0 is not supported."))
    end
    isone(normalization_factor) && return data
    return _divide_windows(data, normalization_factor)
end

function handle_normalization_factor(
    ta::Union{TimeSeries.AbstractTimeSeries, AbstractArray},
    normalization_factor::NormalizationTypes,
)
    if normalization_factor != NormalizationTypes.MAX
        throw(
            ArgumentError(
                "support for normalization_factor=$normalization_factor not implemented",
            ),
        )
    end
    max_value = get_max_value(ta)
    if iszero(max_value)
        throw(
            ArgumentError(
                "normalization_factor = max with a max value of 0.0 is not supported",
            ),
        )
    end
    return ta ./ max_value
end

function handle_normalization_factor(
    ta::Union{TimeSeries.AbstractTimeSeries, AbstractArray},
    normalization_factor::Float64,
)
    if iszero(normalization_factor)
        throw(ArgumentError("A normalization_factor of 0.0 is not supported."))
    end
    isone(normalization_factor) && return ta
    return ta ./ normalization_factor
end
