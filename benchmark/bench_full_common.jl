# Shared driver for the full time-series benchmark matrix:
#   - bulk-add N series per (time series type × element type)
#   - full-array reads, sliced/window reads
#   - by-timestamp / by-window sweeps over every component
#     (reader on the InfraStore branch, TimeSeriesCache on IS4)
#   - has_time_series with name + resolution + features at 10 series/component
#
# The including script defines the branch adapter:
#   BRANCH_LABEL::String
#   SUPPORTS_NST::Bool
#   make_sts(name, t0, resolution, vals)
#   make_nst(name, timestamps, vals)                    (only if SUPPORTS_NST)
#   make_det(name, data::SortedDict, resolution, interval)
#   make_prob(name, data::SortedDict, percentiles, resolution, interval)
#   make_scen(name, data::SortedDict, scenario_count, resolution, interval)
#   bulk_add!(f, sys)      f receives addfn(owner, ts; features...); adds are batched
#   sweep_static!(sys, comps, name, resolution, t0, len) -> values read
#   sweep_forecast!(sys, comps, name, resolution, interval, t0, count) -> windows read
using Dates, Random, Printf
using DataStructures: SortedDict
using InfrastructureSystems
const IS = InfrastructureSystems

const N = parse(Int, get(ENV, "BENCH_N", "100000"))
const LEN = parse(Int, get(ENV, "BENCH_LEN", "24"))          # STS/NST length
const NP = parse(Int, get(ENV, "BENCH_NP", "5"))             # points per PWL curve
const NWIN = parse(Int, get(ENV, "BENCH_WINDOWS", "12"))     # forecast windows
const HORIZON = parse(Int, get(ENV, "BENCH_HORIZON", "12"))  # steps per window
const NPCT = 5                                               # Probabilistic percentiles
const NSCEN = 5                                              # Scenarios count
const T0 = DateTime(2024, 1, 1)
const RES = Hour(1)
const INTERVAL = Hour(1)
const PERCENTILES = [10.0, 25.0, 50.0, 75.0, 90.0]

# Which sections and element types to run (comma lists), so long runs can be
# split across processes.
const KINDS = split(
    get(ENV, "BENCH_KINDS", "sts,nst,det,prob,scen,sweep,has,dst,shared,serialize,remove"),
    ",")
const ELTYPES =
    split(get(ENV, "BENCH_ELTYPES", "float64,ntuple2,linear,quadratic,pwl"), ",")

make_val_float64(rng) = rand(rng)
make_val_ntuple2(rng) = (rand(rng), rand(rng))
make_val_linear(rng) = IS.LinearFunctionData(rand(rng), rand(rng))
make_val_quadratic(rng) = IS.QuadraticFunctionData(rand(rng), rand(rng), rand(rng))
# x-coordinates must be strictly increasing; only y varies.
make_val_pwl(rng) = IS.PiecewiseLinearData([(Float64(j - 1), rand(rng)) for j in 1:NP])

const VAL_MAKERS = Dict(
    "float64" => make_val_float64,
    "ntuple2" => make_val_ntuple2,
    "linear" => make_val_linear,
    "quadratic" => make_val_quadratic,
    "pwl" => make_val_pwl,
)

# Each system gets its own (auto-cleaned) directory so the on-disk footprint of
# its time series store can be measured branch-agnostically.
function build_system(n)
    dir = mktempdir()
    sys = IS.SystemData(; time_series_directory = dir)
    comps = Vector{IS.TestComponent}(undef, n)
    for i in 1:n
        c = IS.TestComponent("c$i", i)
        IS.add_component!(sys, c)
        comps[i] = c
    end
    return sys, comps, dir
end

function report(kind, eltype, op, n, t, b, status)
    @printf("%s,%s,%s,%s,%d,%.3f,%.3f,%d,%s\n", BRANCH_LABEL, kind, eltype, op,
        n, t, 1e6 * t / n, b, status)
    flush(stdout)
end

error_status(e) = "error: " * replace(first(sprint(showerror, e), 200), r"[,\n]" => ";")

# Times f() with GC quiesced first; one CSV row per call. Failures (unsupported
# type/eltype combos on a branch) are recorded, not fatal.
function timed_op(kind, eltype, op, n, f)
    GC.gc()
    try
        stats = @timed f()
        report(kind, eltype, op, n, stats.time, stats.bytes, "ok")
        return true
    catch e
        report(kind, eltype, op, n, NaN, 0, error_status(e))
        return false
    end
end

# Constructs a combo's payload vector; a constructor rejecting the eltype is an
# unsupported combo, recorded against its bulk_add row.
function try_construct(kind, eltype, n, f)
    try
        return f()
    catch e
        report(kind, eltype, "bulk_add", n, NaN, 0, error_status(e))
        return nothing
    end
end

report_disk(kind, eltype, dir) = report(kind, eltype, "store_disk_bytes", 1, 0.0,
    sum(filesize(joinpath(dir, f)) for f in readdir(dir); init = 0), "ok")

# Process-lifetime peak RSS after an ingest. Monotone across a process, so only
# the first combo in a process attributes cleanly; later rows are upper bounds.
report_maxrss(kind, eltype) = report(kind, eltype, "maxrss", 1, 0.0, Sys.maxrss(), "ok")

# ---- STS / NST -------------------------------------------------------------

function irregular_timestamps(rng, len)
    stamps = Vector{DateTime}(undef, len)
    t = T0
    for i in 1:len
        t += Minute(rand(rng, 1:180))
        stamps[i] = t
    end
    return stamps
end

# `shared` adds one instance to every component (deduplicated storage).
# `main_ops = false` skips the add/read rows (the add still runs, un-timed) so a
# sweep-only process doesn't duplicate the main matrix; `sweep = true` appends
# the by-timestamp sweep.
function run_static_kind(kind, eltype, n;
    shared::Bool = false, sweep::Bool = false, main_ops::Bool = true)
    make_val = VAL_MAKERS[eltype]
    sys, comps, dir = build_system(n)
    rng = Random.Xoshiro(1234)
    is_sts = startswith(kind, "sts")
    make_one =
        () -> if is_sts
            make_sts("val", T0, RES, [make_val(rng) for _ in 1:LEN])
        else
            make_nst("val", irregular_timestamps(rng, LEN), [make_val(rng) for _ in 1:LEN])
        end
    tss = try_construct(kind, eltype, n,
        () -> shared ? fill(make_one(), n) : [make_one() for _ in 1:n])
    isnothing(tss) && return
    ttype = is_sts ? IS.SingleTimeSeries : IS.NonSequentialTimeSeries

    do_add = () -> bulk_add!(sys) do addfn
        for i in 1:n
            addfn(comps[i], tss[i])
        end
    end
    if main_ops
        timed_op(kind, eltype, "bulk_add", n, do_add) || return
        report_maxrss(kind, eltype)
        report_disk(kind, eltype, dir)
    else
        do_add()
    end
    tss = nothing

    if main_ops
        timed_op(
            kind,
            eltype,
            "get_full",
            n,
            () -> for i in 1:n
                IS.get_time_series(ttype, comps[i], "val")
            end,
        )

        # Sliced read: middle half of the series (regular-grid types only).
        if is_sts
            st = T0 + RES * (LEN ÷ 4)
            slice_len = LEN ÷ 2
            timed_op(
                kind,
                eltype,
                "get_sliced",
                n,
                () -> for i in 1:n
                    IS.get_time_series(ttype, comps[i], "val";
                        start_time = st, len = slice_len)
                end,
            )
        end
    end

    sweep && timed_op(kind, eltype, "read_by_timestamp", n * LEN,
        () -> sweep_static!(sys, comps, "val", RES, T0, LEN))
    return
end

# ---- Forecasts -------------------------------------------------------------

window_starts() = [T0 + INTERVAL * (w - 1) for w in 1:NWIN]

make_det_data(make_val, rng) = SortedDict{DateTime, Vector{typeof(make_val(rng))}}(
    t => [make_val(rng) for _ in 1:HORIZON] for t in window_starts()
)

make_matrix_data(rng, width) = SortedDict{DateTime, Matrix{Float64}}(
    t => rand(rng, HORIZON, width) for t in window_starts()
)

function run_forecast_kind(kind, eltype, n;
    shared::Bool = false, sweep::Bool = false, main_ops::Bool = true)
    sys, comps, dir = build_system(n)
    rng = Random.Xoshiro(1234)
    make_val = VAL_MAKERS[eltype]
    is_det = startswith(kind, "det")
    make_one =
        () -> if is_det
            make_det("fc", make_det_data(make_val, rng), RES, INTERVAL)
        elseif kind == "prob"
            make_prob("fc", make_matrix_data(rng, NPCT), PERCENTILES, RES, INTERVAL)
        else
            make_scen("fc", make_matrix_data(rng, NSCEN), NSCEN, RES, INTERVAL)
        end
    fcs = try_construct(kind, eltype, n,
        () -> shared ? fill(make_one(), n) : [make_one() for _ in 1:n])
    isnothing(fcs) && return
    ttype = is_det ? IS.Deterministic :
            kind == "prob" ? IS.Probabilistic : IS.Scenarios

    do_add = () -> bulk_add!(sys) do addfn
        for i in 1:n
            addfn(comps[i], fcs[i])
        end
    end
    if main_ops
        timed_op(kind, eltype, "bulk_add", n, do_add) || return
        report_maxrss(kind, eltype)
        report_disk(kind, eltype, dir)
    else
        do_add()
    end
    fcs = nothing

    if main_ops
        timed_op(
            kind,
            eltype,
            "get_full",
            n,
            () -> for i in 1:n
                IS.get_time_series(ttype, comps[i], "fc")
            end,
        )

        # Single-window read: the second window.
        st = T0 + INTERVAL
        timed_op(
            kind,
            eltype,
            "get_window",
            n,
            () -> for i in 1:n
                IS.get_time_series(ttype, comps[i], "fc"; start_time = st, count = 1)
            end,
        )
    end

    sweep && timed_op(kind, eltype, "read_by_window", n * NWIN,
        () -> sweep_forecast!(ttype, sys, comps, "fc", RES, INTERVAL, T0, NWIN))
    return
end

# ---- DeterministicSingleTimeSeries (transform_single_time_series!) ---------
# 100k SingleTimeSeries transformed in place to DST forecasts, then read window
# by window — the standard PowerSimulations feed path.

function run_dst_kind(n)
    sys, comps, _ = build_system(n)
    rng = Random.Xoshiro(1234)
    tss = [make_sts("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
    bulk_add!(sys) do addfn
        for i in 1:n
            addfn(comps[i], tss[i])
        end
    end
    tss = nothing

    horizon = RES * HORIZON
    timed_op("dst", "float64", "transform", n,
        () -> IS.transform_single_time_series!(
            sys, IS.DeterministicSingleTimeSeries, horizon, INTERVAL))

    # Single-window read: the second window.
    st = T0 + INTERVAL
    timed_op(
        "dst",
        "float64",
        "get_window",
        n,
        () -> for i in 1:n
            IS.get_time_series(IS.DeterministicSingleTimeSeries, comps[i], "val";
                start_time = st, count = 1)
        end,
    )

    nwin = Dates.Millisecond(RES * (LEN - HORIZON)) ÷ Dates.Millisecond(INTERVAL) + 1
    timed_op("dst", "float64", "read_by_window", n * nwin,
        () -> sweep_forecast!(IS.DeterministicSingleTimeSeries, sys, comps, "val",
            RES, INTERVAL, T0, nwin))
    return
end

# ---- Serialization round-trip ----------------------------------------------
# to_json / from_json of a system holding n Float64 SingleTimeSeries, including
# the time series store artifacts; the reload is verified with one read.

function run_serialize_kind(n)
    sys, comps, _ = build_system(n)
    rng = Random.Xoshiro(1234)
    tss = [make_sts("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
    bulk_add!(sys) do addfn
        for i in 1:n
            addfn(comps[i], tss[i])
        end
    end
    tss = nothing

    outdir = mktempdir()
    filename = joinpath(outdir, "system.json")
    JSONmod = IS.JSON
    timed_op(
        "serialize",
        "float64",
        "to_json",
        n,
        () -> begin
            IS.prepare_for_serialization_to_file!(sys, filename; force = true)
            data = IS.serialize(sys)
            open(filename, "w") do io
                JSONmod.json(io, data)
            end
        end,
    )
    report_maxrss("serialize", "float64")
    report_disk("serialize", "float64", outdir)

    sys2 = Ref{Any}(nothing)
    timed_op(
        "serialize",
        "float64",
        "from_json",
        n,
        () -> begin
            data = open(filename) do io
                JSONmod.parse(io; dicttype = Dict{String, Any})
            end
            orig = pwd()
            try
                # Relative time series paths resolve against the working directory.
                cd(outdir)
                s2 = IS.deserialize(IS.SystemData, data)
                # Component deserialization is normally directed by the parent
                # package (PowerSystems); replicate that step here.
                for component in data["components"]
                    type = IS.get_type_from_serialization_data(component)
                    comp = IS.deserialize(type, component)
                    IS.add_component!(s2, comp; allow_existing_time_series = true)
                end
                sys2[] = s2
            finally
                cd(orig)
            end
        end,
    )

    isnothing(sys2[]) && return
    timed_op(
        "serialize",
        "float64",
        "reload_read_one",
        1,
        () -> begin
            c = IS.get_component(IS.TestComponent, sys2[].components, "c1")
            ts = IS.get_time_series(IS.SingleTimeSeries, c, "val")
            length(IS.get_data(ts)) == LEN || error("reloaded series has wrong length")
        end,
    )
    return
end

# ---- Removal at scale ------------------------------------------------------

function run_remove_kind(n)
    sys, comps, _ = build_system(n)
    rng = Random.Xoshiro(1234)
    tss = [make_sts("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
    bulk_add!(sys) do addfn
        for i in 1:n
            addfn(comps[i], tss[i])
        end
    end
    tss = nothing

    timed_op(
        "remove",
        "float64",
        "remove_all",
        n,
        () -> for i in 1:n
            IS.remove_time_series!(sys, IS.SingleTimeSeries, comps[i], "val")
        end,
    )
    return
end

# ---- has_time_series -------------------------------------------------------
# n series spread over n ÷ 10 components (10 per component: 2 names × 5
# feature combos, each association carrying 2 features). Queries pass the full
# identity: type, name, resolution, and both features.

function run_has_kind(n)
    ncomp = max(n ÷ 10, 1)
    sys, comps, _ = build_system(ncomp)
    rng = Random.Xoshiro(1234)
    # 10 shared instances; both branches deduplicate the repeated arrays.
    base = [make_sts("ts$a", T0, RES, rand(rng, LEN)) for a in 1:2]
    names = [("ts$(mod1(j, 2))", "s$(div(j - 1, 2) + 1)") for j in 1:10]

    nq = ncomp * 10
    timed_op(
        "has_ts",
        "float64",
        "bulk_add",
        nq,
        () -> bulk_add!(sys) do addfn
            for c in comps, (j, (name, scen)) in enumerate(names)
                addfn(c, base[mod1(j, 2)]; scenario = scen, model_year = "2030")
            end
        end,
    )

    hits = Ref(0)
    ok = timed_op(
        "has_ts",
        "float64",
        "has_hit",
        nq,
        () -> begin
            for c in comps, (name, scen) in names
                hits[] += IS.has_time_series(c, IS.SingleTimeSeries, name;
                    resolution = RES, scenario = scen, model_year = "2030")
            end
        end,
    )
    ok && hits[] != nq && error("has_hit returned $(hits[]) of $nq expected trues")

    misses = Ref(0)
    ok = timed_op(
        "has_ts",
        "float64",
        "has_miss",
        nq,
        () -> begin
            for c in comps, (name, _) in names
                misses[] += IS.has_time_series(c, IS.SingleTimeSeries, name;
                    resolution = RES, scenario = "s99", model_year = "2030")
            end
        end,
    )
    ok && misses[] != 0 && error("has_miss returned $(misses[]) unexpected trues")
    return
end

# ---- top level -------------------------------------------------------------

function run_all(n)
    for eltype in ELTYPES
        "sts" in KINDS && run_static_kind("sts", eltype, n)
        if "nst" in KINDS
            if SUPPORTS_NST
                run_static_kind("nst", eltype, n)
            else
                report("nst", eltype, "bulk_add", n, NaN, 0, "not_supported_on_branch")
            end
        end
        "det" in KINDS && run_forecast_kind("det", eltype, n)
    end
    "prob" in KINDS && run_forecast_kind("prob", "float64", n)
    "scen" in KINDS && run_forecast_kind("scen", "float64", n)
    if "sweep" in KINDS
        run_static_kind("sts", "float64", n; sweep = true, main_ops = false)
        run_forecast_kind("det", "float64", n; sweep = true, main_ops = false)
    end
    "has" in KINDS && run_has_kind(n)
    "dst" in KINDS && run_dst_kind(n)
    if "shared" in KINDS
        run_static_kind("sts_shared", "float64", n; shared = true, sweep = true)
        run_forecast_kind("det_shared", "float64", n; shared = true, sweep = true)
    end
    "serialize" in KINDS && run_serialize_kind(n)
    "remove" in KINDS && run_remove_kind(n)
    return
end

println("branch,kind,eltype,op,n,total_s,us_per_op,bytes,status")
# Warmup (JIT) on a small system.
redirect_stdout(devnull) do
    run_all(40)
end
run_all(N)
println("DONE $BRANCH_LABEL full")
