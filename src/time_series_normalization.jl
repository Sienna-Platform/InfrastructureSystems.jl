@scoped_enum NormalizationTypes MAX = 1

@doc """
Types of normalization that can be applied to time series data.

# Values
- `MAX`: Normalize by the maximum value in the time series
""" NormalizationTypes

const NormalizationFactor = Union{Float64, NormalizationTypes}

function handle_normalization_factor(
    data::AbstractDict,
    normalization_factor::NormalizationFactor,
)
    for (k, v) in data
        data[k] = handle_normalization_factor(v, normalization_factor)
    end
    return data
end

get_max_value(ta::TimeSeries.TimeArray) = maximum(TimeSeries.values(ta))
get_max_value(ta::Vector) = maximum(ta)

function handle_normalization_factor(
    ta::Union{TimeSeries.AbstractTimeSeries, AbstractArray},
    normalization_factor::NormalizationTypes,
)
    if normalization_factor != NormalizationTypes.MAX
        error("support for normalization_factor=$normalization_factor not implemented")
    end
    max_value = get_max_value(ta)
    if iszero(max_value)
        error("normalization_factor = max with a max value of 0.0 is not supported")
    end
    return ta ./ max_value
end

function handle_normalization_factor(
    ta::Union{TimeSeries.AbstractTimeSeries, AbstractArray},
    normalization_factor::Float64,
)
    if iszero(normalization_factor)
        error("A normalization_factor of 0.0 is not supported.")
    end
    isone(normalization_factor) && return ta
    return ta ./ normalization_factor
end
