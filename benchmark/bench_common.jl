# Shared benchmark driver for both branches. The including script defines:
#   make_ts(name, t0, resolution, vals) -> SingleTimeSeries (branch-specific ctor)
#   BRANCH_LABEL::String
using Dates, Random, Printf
using InfrastructureSystems
const IS = InfrastructureSystems

const N = parse(Int, get(ENV, "BENCH_N", "100000"))
const LEN = parse(Int, get(ENV, "BENCH_LEN", "24"))
const T0 = DateTime(2024, 1, 1)
const RES = Hour(1)

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

function run_scenario(label, shared::Bool, n)
    sys, comps = build_system(n)
    Random.seed!(1234)
    tss = if shared
        one = make_ts("val", T0, RES, rand(LEN))
        fill(one, n)
    else
        [make_ts("val", T0, RES, rand(LEN)) for _ in 1:n]
    end

    t_add, b_add = timeit() do
        for i in 1:n
            IS.add_time_series!(sys, comps[i], tss[i])
        end
    end
    @printf("%s,%s,add,%d,%.3f,%.2f,%d\n", BRANCH_LABEL, label, n, t_add,
        1e6 * t_add / n, b_add)
    flush(stdout)

    t_get, b_get = timeit() do
        for i in 1:n
            IS.get_time_series(IS.SingleTimeSeries, comps[i], "val")
        end
    end
    @printf("%s,%s,get_full,%d,%.3f,%.2f,%d\n", BRANCH_LABEL, label, n, t_get,
        1e6 * t_get / n, b_get)
    flush(stdout)

    # Sliced read: middle window of 12 steps.
    st = T0 + RES * 6
    t_gs, b_gs = timeit() do
        for i in 1:n
            IS.get_time_series(IS.SingleTimeSeries, comps[i], "val";
                start_time = st, len = 12)
        end
    end
    @printf("%s,%s,get_sliced,%d,%.3f,%.2f,%d\n", BRANCH_LABEL, label, n, t_gs,
        1e6 * t_gs / n, b_gs)
    flush(stdout)
    return
end

println("branch,scenario,op,n,total_s,us_per_op,bytes")
# Warmup (JIT) on a small system.
redirect_stdout(devnull) do
    run_scenario("warmup", false, 50)
    run_scenario("warmup", true, 50)
end
run_scenario("nonshared", false, N)
run_scenario("shared", true, N)
println("DONE $BRANCH_LABEL")
