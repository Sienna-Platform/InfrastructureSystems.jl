# Merge the results_full_*.csv outputs of bench_full_{branch,is4}.jl and print
# markdown tables comparing the two branches per (kind, eltype, op).
# Usage: julia benchmark/make_full_report.jl [dir]
dir = isempty(ARGS) ? @__DIR__ : ARGS[1]

struct Row
    branch::String
    kind::String
    eltype::String
    op::String
    n::Int
    total_s::Float64
    us_per_op::Float64
    bytes::Int
    status::String
end

rows = Row[]
for f in readdir(dir; join = true)
    occursin(r"^results_full_.*\.csv$", basename(f)) || continue
    for line in readlines(f)
        parts = split(line, ","; limit = 9)
        (length(parts) == 9 && parts[1] != "branch") || continue
        push!(rows, Row(parts[1], parts[2], parts[3], parts[4],
            parse(Int, parts[5]),
            parse(Float64, parts[6]), parse(Float64, parts[7]),
            parse(Int, parts[8]), parts[9]))
    end
end

key(r) = (r.kind, r.eltype, r.op)
bybranch = Dict{String, Dict{Any, Row}}()
for r in rows
    d = get!(() -> Dict{Any, Row}(), bybranch, r.branch)
    haskey(d, key(r)) && r != d[key(r)] &&
        @warn "duplicate row differs" key(r) r.branch
    d[key(r)] = r
end

inf = get(bybranch, "infrastore", Dict{Any, Row}())
is4 = get(bybranch, "is4", Dict{Any, Row}())

const KIND_ORDER = ["sts", "nst", "det", "prob", "scen", "has_ts"]
const ELTYPE_ORDER = ["float64", "ntuple2", "linear", "quadratic", "pwl"]
const OP_ORDER = ["bulk_add", "get_full", "get_sliced", "get_window",
    "read_by_timestamp", "read_by_window", "has_hit", "has_miss",
    "store_disk_bytes"]

ordkeys = sort!(collect(union(keys(inf), keys(is4)));
    by = k -> (findfirst(==(k[1]), KIND_ORDER), findfirst(==(k[2]), ELTYPE_ORDER),
        findfirst(==(k[3]), OP_ORDER)))

fmt(x) = x >= 100 ? string(round(Int, x)) : string(round(x; sigdigits = 3))

function cell(r)
    isnothing(r) && return "—"
    r.status == "ok" || return startswith(r.status, "error") ? "unsupported" : r.status
    return fmt(r.us_per_op)
end

println("| kind | eltype | op | n | infrastore (µs/op) | is4 (µs/op) | speedup |")
println("|---|---|---|---:|---:|---:|---:|")
for k in ordkeys
    k[3] == "store_disk_bytes" && continue
    a = get(inf, k, nothing)
    b = get(is4, k, nothing)
    n = something(a, b).n
    speedup = if !isnothing(a) && !isnothing(b) && a.status == "ok" && b.status == "ok"
        fmt(b.us_per_op / a.us_per_op) * "×"
    else
        "—"
    end
    println("| $(k[1]) | $(k[2]) | $(k[3]) | $n | $(cell(a)) | $(cell(b)) | $speedup |")
end

println()
println("| kind | eltype | infrastore disk (MB) | is4 disk (MB) |")
println("|---|---|---:|---:|")
mb(r) = isnothing(r) ? "—" : fmt(r.bytes / 1024^2)
for k in ordkeys
    k[3] == "store_disk_bytes" || continue
    println("| $(k[1]) | $(k[2]) | $(mb(get(inf, k, nothing))) | $(mb(get(is4, k, nothing))) |")
end
