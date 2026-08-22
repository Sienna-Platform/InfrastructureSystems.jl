# Entry point for the InfraStore branch (feat/rust-time-series-store).
# Run: INFRASTORE_LIB=... julia --project=test benchmark/bench_full_branch.jl
const BRANCH_LABEL = get(ENV, "BENCH_LABEL", "infrastore")
using Dates
using InfrastructureSystems
const ISB = InfrastructureSystems

make_sts(name, t0, resolution, vals) = ISB.SingleTimeSeries(name, t0, resolution, vals)

const SUPPORTS_NST = true
make_nst(name, timestamps, vals) = ISB.NonSequentialTimeSeries(name, timestamps, vals)

make_det(name, data, resolution, interval) =
    ISB.Deterministic(name, data, resolution, interval)

make_prob(name, data, percentiles, resolution, interval) =
    ISB.Probabilistic(name, data, percentiles, resolution, interval)

make_scen(name, data, scenario_count, resolution, interval) =
    ISB.Scenarios(name, data, scenario_count, resolution, interval)

# Recommended batched-add path on this branch: stage adds on the transaction's
# AddBatch and commit once.
function bulk_add!(f::Function, sys)
    ISB.time_series_transaction(sys) do txn
        f((c, ts; feat...) -> ISB.add_time_series!(txn, c, ts; feat...))
    end
end

# By-timestamp reads over every component via the StaticTimeSeriesReader: one
# columnar storage read per timestamp serves all entries.
function sweep_static!(sys, comps, name, resolution, t0, len)
    reader = ISB.build_static_time_series_reader(sys; resolution = resolution, name = name)
    nentries = length(reader)
    acc = 0.0
    for k in 0:(len - 1)
        ISB.read_static_time_series_values!(reader, t0 + resolution * k)
        for i in 1:nentries
            acc += ISB.get_static_time_series_value(reader, i)::Float64
        end
    end
    isfinite(acc) || error("unexpected non-finite sweep sum")
    return nentries * len
end

# By-window reads over every component via the ForecastReader.
function sweep_forecast!(ttype, sys, comps, name, resolution, interval, t0, count)
    reader = ISB.build_forecast_reader(sys, ttype;
        resolution = resolution, name = name)
    nentries = length(reader)
    nwindows = 0
    for k in 0:(count - 1)
        ISB.read_forecast_window!(reader, t0 + interval * k)
        for i in 1:nentries
            window = ISB.get_forecast_window(reader, i)
            length(window) == 0 && error("empty forecast window")
            nwindows += 1
        end
    end
    return nwindows
end

include(joinpath(@__DIR__, "bench_full_common.jl"))
