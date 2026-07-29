# Shared benchmark driver for cost-function (FunctionData) time series payloads.
# The including script defines:
#   BRANCH_LABEL::String
#   make_ts(name, t0, resolution, vals) -> SingleTimeSeries (branch-specific ctor)
#   make_forecast(name, data::SortedDict, resolution, interval) -> Deterministic
#   bulk_add!(sys, f) -> runs f(addfn) inside the branch's recommended batched-add
#       context, where addfn(component, ts) stages one addition.
using Dates, Random, Printf
using DataStructures: SortedDict
using InfrastructureSystems
const IS = InfrastructureSystems

const N = parse(Int, get(ENV, "BENCH_N", "10000"))
const LEN = parse(Int, get(ENV, "BENCH_LEN", "24"))          # STS length
const NP = parse(Int, get(ENV, "BENCH_NP", "5"))             # points per PWL curve
const NWIN = parse(Int, get(ENV, "BENCH_WINDOWS", "12"))     # forecast windows
const HORIZON = parse(Int, get(ENV, "BENCH_HORIZON", "12"))  # steps per window
const T0 = DateTime(2024, 1, 1)
const RES = Hour(1)
const INTERVAL = Hour(1)

make_linear(rng) = IS.LinearFunctionData(rand(rng), rand(rng))
make_quadratic(rng) = IS.QuadraticFunctionData(rand(rng), rand(rng), rand(rng))
# x-coordinates must be strictly increasing; only y varies.
make_pwl(rng) = IS.PiecewiseLinearData([(Float64(j - 1), rand(rng)) for j in 1:NP])

const PAYLOADS = Dict(
    "linear" => make_linear,
    "quadratic" => make_quadratic,
    "pwl" => make_pwl,
)
const PAYLOAD_KEYS = split(get(ENV, "BENCH_PAYLOADS", "linear,quadratic,pwl"), ",")

function build_system(n)
    sys = IS.SystemData()
    comps = Vector{IS.TestComponent}(undef, n)
    for i in 1:n
        c = IS.TestComponent("c$i", i)
        IS.add_component!(sys, c)
        comps[i] = c
    end
    return sys, comps
end

# Returns (seconds, bytes_allocated) for f().
function timeit(f)
    GC.gc()
    stats = @timed f()
    return (stats.time, stats.bytes)
end

function report(payload, kind, scenario, op, n, t, b)
    @printf("%s,%s,%s,%s,%s,%d,%.3f,%.2f,%d\n", BRANCH_LABEL, payload, kind,
        scenario, op, n, t, 1e6 * t / n, b)
    flush(stdout)
end

function run_sts_scenario(payload, make_val, scenario, shared::Bool, n)
    sys, comps = build_system(n)
    rng = Random.Xoshiro(1234)
    tss = if shared
        one = make_ts("val", T0, RES, [make_val(rng) for _ in 1:LEN])
        fill(one, n)
    else
        [make_ts("val", T0, RES, [make_val(rng) for _ in 1:LEN]) for _ in 1:n]
    end

    t_add, b_add = timeit() do
        bulk_add!(sys) do addfn
            for i in 1:n
                addfn(comps[i], tss[i])
            end
        end
    end
    report(payload, "sts", scenario, "bulk_add", n, t_add, b_add)

    t_get, b_get = timeit() do
        for i in 1:n
            IS.get_time_series(IS.SingleTimeSeries, comps[i], "val")
        end
    end
    report(payload, "sts", scenario, "get_full", n, t_get, b_get)

    # Sliced read: middle window of half the series.
    st = T0 + RES * (LEN ÷ 4)
    slice_len = LEN ÷ 2
    t_gs, b_gs = timeit() do
        for i in 1:n
            IS.get_time_series(IS.SingleTimeSeries, comps[i], "val";
                start_time = st, len = slice_len)
        end
    end
    report(payload, "sts", scenario, "get_sliced", n, t_gs, b_gs)
    return
end

function make_forecast_data(make_val, rng)
    return SortedDict{DateTime, Vector{typeof(make_val(rng))}}(
        T0 + INTERVAL * (w - 1) => [make_val(rng) for _ in 1:HORIZON] for w in 1:NWIN
    )
end

function run_det_scenario(payload, make_val, scenario, shared::Bool, n)
    sys, comps = build_system(n)
    rng = Random.Xoshiro(1234)
    fcs = if shared
        one = make_forecast("fc", make_forecast_data(make_val, rng), RES, INTERVAL)
        fill(one, n)
    else
        [make_forecast("fc", make_forecast_data(make_val, rng), RES, INTERVAL) for _ in 1:n]
    end

    t_add, b_add = timeit() do
        bulk_add!(sys) do addfn
            for i in 1:n
                addfn(comps[i], fcs[i])
            end
        end
    end
    report(payload, "det", scenario, "bulk_add", n, t_add, b_add)

    t_get, b_get = timeit() do
        for i in 1:n
            IS.get_time_series(IS.Deterministic, comps[i], "fc")
        end
    end
    report(payload, "det", scenario, "get_full", n, t_get, b_get)

    # Single-window read: the second window.
    st = T0 + INTERVAL
    t_gw, b_gw = timeit() do
        for i in 1:n
            IS.get_time_series(IS.Deterministic, comps[i], "fc";
                start_time = st, count = 1)
        end
    end
    report(payload, "det", scenario, "get_window", n, t_gw, b_gw)
    return
end

function run_all(n)
    for key in PAYLOAD_KEYS
        make_val = PAYLOADS[key]
        run_sts_scenario(key, make_val, "nonshared", false, n)
        run_sts_scenario(key, make_val, "shared", true, n)
        run_det_scenario(key, make_val, "nonshared", false, n)
        run_det_scenario(key, make_val, "shared", true, n)
    end
end

println("branch,payload,kind,scenario,op,n,total_s,us_per_op,bytes")
# Warmup (JIT) on a small system.
redirect_stdout(devnull) do
    run_all(20)
end
run_all(N)
println("DONE $BRANCH_LABEL costs")
