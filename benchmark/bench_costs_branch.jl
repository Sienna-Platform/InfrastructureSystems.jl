const BRANCH_LABEL = get(ENV, "BENCH_LABEL", "infrastore")
using Dates
using InfrastructureSystems

make_ts(name, t0, resolution, vals) =
    InfrastructureSystems.SingleTimeSeries(name, t0, resolution, vals)

make_forecast(name, data, resolution, interval) =
    InfrastructureSystems.Deterministic(name, data, resolution, interval)

# Recommended batched-add path on this branch: stage adds on the transaction's
# AddBatch and commit once.
function bulk_add!(f::Function, sys)
    InfrastructureSystems.time_series_transaction(sys) do txn
        f((c, ts) -> InfrastructureSystems.add_time_series!(txn, c, ts))
    end
end

include(joinpath(@__DIR__, "bench_costs_common.jl"))
