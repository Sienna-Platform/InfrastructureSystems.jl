const BRANCH_LABEL = "is4"
using Dates, TimeSeries
using InfrastructureSystems
make_ts(name, t0, resolution, vals) =
    InfrastructureSystems.SingleTimeSeries(
        name,
        TimeSeries.TimeArray(collect(range(t0; step = resolution, length = length(vals))), vals),
    )
include(joinpath(@__DIR__, "bench_common.jl"))
