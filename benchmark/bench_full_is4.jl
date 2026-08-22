# Entry point for the IS4 branch (HDF5 + SQLite backend).
# Run: julia --project=<is4-env> benchmark/bench_full_is4.jl
const BRANCH_LABEL = "is4"
using Dates, TimeSeries
using DataStructures: SortedDict
using InfrastructureSystems
const ISB = InfrastructureSystems

make_sts(name, t0, resolution, vals) =
    ISB.SingleTimeSeries(
        name,
        TimeSeries.TimeArray(
            collect(range(t0; step = resolution, length = length(vals))),
            vals,
        ),
    )

# IS4 has no NonSequentialTimeSeries; the driver records the gap.
const SUPPORTS_NST = false

make_det(name, data, resolution, interval) =
    ISB.Deterministic(name, data, resolution; interval = interval)

make_prob(name, data, percentiles, resolution, interval) =
    ISB.Probabilistic(;
        name = name, data = data, percentiles = percentiles,
        resolution = resolution, interval = interval,
    )

make_scen(name, data, scenario_count, resolution, interval) =
    ISB.Scenarios(;
        name = name, data = data, scenario_count = scenario_count,
        resolution = resolution, interval = interval,
    )

# Recommended batched-add path on IS4: keep the HDF5 store open and wrap the
# metadata writes in one SQLite transaction.
function bulk_add!(f::Function, sys)
    mgr = ISB.get_time_series_manager(sys)
    ISB.begin_time_series_update(mgr) do
        f((c, ts; feat...) -> ISB.add_time_series!(sys, c, ts; feat...))
    end
end

# By-timestamp reads over every component via IS4's recommended path: one
# StaticTimeSeriesCache per component, one get_next_time_series_array! per step.
function sweep_static!(sys, comps, name, resolution, t0, len)
    acc = 0.0
    for c in comps
        cache = ISB.StaticTimeSeriesCache(ISB.SingleTimeSeries, c, name)
        for _ in 1:len
            ta = ISB.get_next_time_series_array!(cache)
            acc += sum(TimeSeries.values(ta))
        end
    end
    isfinite(acc) || error("unexpected non-finite sweep sum")
    return length(comps) * len
end

# By-window reads via IS4's ForecastCache, one per component.
function sweep_forecast!(ttype, sys, comps, name, resolution, interval, t0, count)
    nwindows = 0
    for c in comps
        cache = ISB.ForecastCache(ttype, c, name)
        for _ in 1:count
            ta = ISB.get_next_time_series_array!(cache)
            length(ta) == 0 && error("empty forecast window")
            nwindows += 1
        end
    end
    return nwindows
end

include(joinpath(@__DIR__, "bench_full_common.jl"))
