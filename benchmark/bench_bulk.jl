# Post-fix benchmark: batched adds via time_series_transaction (AddBatch path)
# + reads at 100k.
using Dates, Random, Printf
using InfrastructureSystems
const IS = InfrastructureSystems

const N = parse(Int, get(ENV, "BENCH_N", "100000"))
const LEN = 24
const T0 = DateTime(2024, 1, 1)

function run_bulk(label, shared, n)
    sys = IS.SystemData()
    comps = Vector{IS.TestComponent}(undef, n)
    for i in 1:n
        c = IS.TestComponent("c$i", i)
        IS.add_component!(sys, c)
        comps[i] = c
    end
    Random.seed!(1234)
    tss = if shared
        one = IS.SingleTimeSeries("val", T0, Hour(1), rand(LEN))
        fill(one, n)
    else
        [IS.SingleTimeSeries("val", T0, Hour(1), rand(LEN)) for _ in 1:n]
    end
    GC.gc()
    t_add = @elapsed IS.time_series_transaction(sys.time_series_manager) do context
        for i in 1:n
            IS.add_time_series!(
                sys.time_series_manager,
                comps[i],
                tss[i];
                context = context,
            )
        end
    end
    @printf("%s,bulk_add,%d,%.3f,%.2f\n", label, n, t_add, 1e6 * t_add / n)
    GC.gc()
    t_get = @elapsed for i in 1:n
        IS.get_time_series(IS.SingleTimeSeries, comps[i], "val")
    end
    @printf("%s,get_full,%d,%.3f,%.2f\n", label, n, t_get, 1e6 * t_get / n)
    st = T0 + Hour(6)
    GC.gc()
    t_gs = @elapsed for i in 1:n
        IS.get_time_series(IS.SingleTimeSeries, comps[i], "val";
            start_time = st, len = 12)
    end
    @printf("%s,get_sliced,%d,%.3f,%.2f\n", label, n, t_gs, 1e6 * t_gs / n)
    flush(stdout)
end

println("scenario,op,n,total_s,us_per_op")
run_bulk("warmup", false, 50)
run_bulk("nonshared", false, N)
run_bulk("shared", true, N)
println("DONE bulk")
