const BRANCH_LABEL = "infrastore"
using Dates
using InfrastructureSystems
make_ts(name, t0, resolution, vals) =
    InfrastructureSystems.SingleTimeSeries(name, t0, resolution, vals)
include(joinpath(@__DIR__, "bench_common.jl"))
