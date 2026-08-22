const BRANCH_LABEL = "is4"
using Dates, TimeSeries
using DataStructures: SortedDict
using InfrastructureSystems

make_ts(name, t0, resolution, vals) =
    InfrastructureSystems.SingleTimeSeries(
        name,
        TimeSeries.TimeArray(
            collect(range(t0; step = resolution, length = length(vals))),
            vals,
        ),
    )

make_forecast(name, data, resolution, interval) =
    InfrastructureSystems.Deterministic(name, data, resolution; interval = interval)

# Recommended batched-add path on IS4: keep the HDF5 store open and wrap the
# metadata writes in one SQLite transaction.
function bulk_add!(f::Function, sys)
    mgr = InfrastructureSystems.get_time_series_manager(sys)
    InfrastructureSystems.begin_time_series_update(mgr) do
        f((c, ts) -> InfrastructureSystems.add_time_series!(sys, c, ts))
    end
end

include(joinpath(@__DIR__, "bench_costs_common.jl"))
