"""
    DeterministicSingleTimeSeries{T, N}

Type marker for a deterministic forecast that the store derives from a
[`SingleTimeSeries`](@ref).

Created by `transform_single_time_series!`: the store records the forecast window
parameters (initial timestamp, interval, count, horizon) against the existing
`SingleTimeSeries` array instead of materializing the overlapping windows, avoiding
large data duplication. Use this to treat historical data as a perfect forecast when
real forecast data is unavailable.

This type is never instantiated — it exists only to name the stored type in queries
(`get_time_series`, `has_time_series`, `remove_time_series!`, the
`list_metadata` filters) and in the rows it returns. Reads always
materialize the shared array into a regular [`Deterministic`](@ref).
"""
struct DeterministicSingleTimeSeries{T, N} <: AbstractDeterministic{T} end
