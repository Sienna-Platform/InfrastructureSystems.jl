# Chunked-timing characterization of add_time_series!/get_time_series scaling on
# the InfraStore branch. Prints marginal cost per chunk so the growth curve is visible
# without waiting for a full 100k O(N^2) run.
using Dates, Random, Printf
using InfrastructureSystems
const IS = InfrastructureSystems

const N = parse(Int, get(ENV, "BENCH_N", "20000"))
const CHUNK = parse(Int, get(ENV, "BENCH_CHUNK", "1000"))
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

function run_scenario(label, shared::Bool, n)
    sys, comps = build_system(n)
    Random.seed!(1234)
    tss = if shared
        one = IS.SingleTimeSeries("val", T0, RES, rand(LEN))
        fill(one, n)
    else
        [IS.SingleTimeSeries("val", T0, RES, rand(LEN)) for _ in 1:n]
    end

    println("scenario,op,store_size,chunk_us_per_op")
    GC.gc()
    for c0 in 1:CHUNK:n
        c1 = min(c0 + CHUNK - 1, n)
        t = @elapsed for i in c0:c1
            IS.add_time_series!(sys, comps[i], tss[i])
        end
        @printf("%s,add,%d,%.1f\n", label, c1, 1e6 * t / (c1 - c0 + 1))
        flush(stdout)
    end

    GC.gc()
    for c0 in 1:CHUNK:n
        c1 = min(c0 + CHUNK - 1, n)
        t = @elapsed for i in c0:c1
            IS.get_time_series(IS.SingleTimeSeries, comps[i], "val")
        end
        @printf("%s,get_full,%d,%.1f\n", label, c1, 1e6 * t / (c1 - c0 + 1))
        flush(stdout)
    end
    return
end

# Warmup
redirect_stdout(devnull) do
    run_scenario("warmup", false, 50)
end
run_scenario("nonshared", false, N)
run_scenario("shared", true, N)
println("DONE scaling")
