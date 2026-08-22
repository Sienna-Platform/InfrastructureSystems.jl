# Compare a benchmark run against the committed baseline and print a markdown
# table of per-op deltas.
#
#   julia benchmark/bench.jl > /tmp/results.csv
#   julia benchmark/report.jl /tmp/results.csv
#
# Usage: julia benchmark/report.jl [current.csv] [baseline.csv] [threshold]
# `threshold` is the fractional slowdown that counts as a regression (default
# 0.40, sized for the write-heavy ops' cross-session variance -- see README).
# Exits 1 if any op regressed past it, or if an op failed in the current run but
# not the baseline, so this can gate CI.
const DIR = @__DIR__
current_path = length(ARGS) >= 1 ? ARGS[1] : joinpath(DIR, "results.csv")
baseline_path = length(ARGS) >= 2 ? ARGS[2] : joinpath(DIR, "baseline.csv")
threshold = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) : 0.40

struct Row
    kind::String
    eltype::String
    op::String
    n::Int
    total_s::Float64
    us_per_op::Float64
    bytes::Int
    status::String
end

function read_rows(path)
    isfile(path) || error("no such results file: $path")
    rows = Dict{Tuple{String, String, String}, Row}()
    for line in readlines(path)
        parts = split(line, ","; limit = 8)
        (length(parts) == 8 && parts[1] != "kind") || continue
        r = Row(
            parts[1],
            parts[2],
            parts[3],
            parse(Int, parts[4]),
            parse(Float64, parts[5]),
            parse(Float64, parts[6]),
            parse(Int, parts[7]),
            parts[8],
        )
        rows[(r.kind, r.eltype, r.op)] = r
    end
    isempty(rows) && error("no data rows in $path")
    return rows
end

cur = read_rows(current_path)
base = read_rows(baseline_path)

const KIND_ORDER = [
    "sts",
    "nst",
    "det",
    "prob",
    "scen",
    "dst",
    "sts_shared",
    "det_shared",
    "has_ts",
    "serialize",
    "remove",
    "scaling",
]
const ELTYPE_ORDER = ["float64", "ntuple2", "linear", "quadratic", "pwl"]
const OP_ORDER = [
    "bulk_add",
    "bulk_add_associations",
    "transform",
    "get_full",
    "get_sliced",
    "get_window",
    "build_static_reader",
    "read_by_timestamp",
    "timestamp_storage_read",
    "build_forecast_reader",
    "read_by_window",
    "window_storage_read",
    "has_hit",
    "has_miss",
    "to_json",
    "from_json",
    "reload_read_one",
    "remove_all",
    "maxrss",
    "store_disk_bytes",
]

rank(x, order) = something(findfirst(==(x), order), length(order) + 1)
ordkeys = sort!(
    collect(union(keys(cur), keys(base)));
    by = k -> (rank(k[1], KIND_ORDER), rank(k[2], ELTYPE_ORDER), rank(k[3], OP_ORDER)),
)

fmt(x) = x >= 100 ? string(round(Int, x)) : string(round(x; sigdigits = 3))
ok(r) = !isnothing(r) && r.status == "ok"

function cell(r)
    isnothing(r) && return "—"
    r.status == "ok" || return "**failed**"
    return fmt(r.us_per_op)
end

regressions = Tuple{Any, Float64}[]
failures = Any[]
# Ops the baseline has that this run did not produce at all. A subset run
# (BENCH_KINDS=scaling, say) legitimately omits most rows, so these are reported
# but do not gate -- an op that ran and broke emits an `error:` row instead, and
# lands in `failures`.
not_run = Any[]

println("Current:  $current_path")
println("Baseline: $baseline_path")
println()
println("| kind | eltype | op | n | baseline (µs/op) | current (µs/op) | delta |")
println("|---|---|---|---:|---:|---:|---:|")
for k in ordkeys
    k[3] in ("store_disk_bytes", "maxrss") && continue
    b = get(base, k, nothing)
    c = get(cur, k, nothing)
    n = something(c, b).n
    if ok(b) && !ok(c)
        push!(isnothing(c) ? not_run : failures, k)
    end
    delta = if ok(b) && ok(c) && b.us_per_op > 0
        d = c.us_per_op / b.us_per_op - 1
        # Single-op rows (reload_read_one) are one sample and swing ±20%; they
        # are reported but do not gate.
        d > threshold && n >= 100 && push!(regressions, (k, d))
        flag = d > threshold && n >= 100 ? " ⚠️" : ""
        string(d >= 0 ? "+" : "", round(100 * d; digits = 1), "%", flag)
    else
        "—"
    end
    println("| $(k[1]) | $(k[2]) | $(k[3]) | $n | $(cell(b)) | $(cell(c)) | $delta |")
end

println()
println("| kind | eltype | baseline disk (MB) | current disk (MB) |")
println("|---|---|---:|---:|")
mb(r) = isnothing(r) ? "—" : fmt(r.bytes / 1024^2)
for k in ordkeys
    k[3] == "store_disk_bytes" || continue
    println(
        "| $(k[1]) | $(k[2]) | $(mb(get(base, k, nothing))) | $(mb(get(cur, k, nothing))) |",
    )
end

# Scaling canary: per-op ingest cost must not grow with store size.
scaling = sort!([(k, r) for (k, r) in cur if k[1] == "scaling" && r.status == "ok"];
    by = kr -> kr[2].n)
if length(scaling) == 2
    small, large = scaling[1][2], scaling[2][2]
    ratio = large.us_per_op / small.us_per_op
    println()
    println(
        "Scaling canary: $(fmt(small.us_per_op)) µs/op at n=$(small.n) → " *
        "$(fmt(large.us_per_op)) µs/op at n=$(large.n) " *
        "($(round(ratio; digits = 2))× per-op cost)",
    )
    if ratio > 1 + threshold
        println("  ⚠️  per-op ingest cost grows with store size")
        push!(regressions, (("scaling", "float64", "per_op_ratio"), ratio - 1))
    end
end

println()
if !isempty(not_run)
    println(
        "$(length(not_run)) op(s) in the baseline were not run here " *
        "(subset run?); not counted as failures:",
    )
    for k in not_run
        println("  - $(k[1])/$(k[2])/$(k[3])")
    end
end
if !isempty(failures)
    println("$(length(failures)) op(s) failed that passed in the baseline:")
    for k in failures
        println("  - $(k[1])/$(k[2])/$(k[3]): $(cur[k].status)")
    end
end
if !isempty(regressions)
    println("$(length(regressions)) regression(s) past $(round(Int, 100 * threshold))%:")
    for (k, d) in sort!(regressions; by = kd -> -kd[2])
        println("  - $(k[1])/$(k[2])/$(k[3]): +$(round(100 * d; digits = 1))%")
    end
end
if isempty(failures) && isempty(regressions)
    println("No regressions past $(round(Int, 100 * threshold))%.")
else
    exit(1)
end
