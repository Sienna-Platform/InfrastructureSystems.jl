# Time series benchmark suite for InfrastructureSystems.jl.
#
# Default run is sized to finish in well under two minutes:
#
#   INFRASTORE_LIB=/path/to/libinfrastore_ffi.dylib \
#       julia --project=test benchmark/bench.jl > benchmark/results.csv
#
# One CSV row per (kind, eltype, op). Sections are selectable with BENCH_KINDS
# (comma list) and element types with BENCH_ELTYPES; see README.md.
using Dates, Random, Printf
using DataStructures: SortedDict
using InfrastructureSystems
const IS = InfrastructureSystems

# Ingest matrix and capability sections. Cost is linear in N, so 10k is enough
# to see a throughput regression; `scaling` guards the superlinear case.
const N = parse(Int, get(ENV, "BENCH_N", "10000"))
# Simulation inner loop: read every component at one timestamp/window. Run at
# production scale, where the columnar readers have to earn their keep.
const SWEEP_N = parse(Int, get(ENV, "BENCH_SWEEP_N", "100000"))
# Upper point of the scaling canary; the lower point is N.
const SCALING_N = parse(Int, get(ENV, "BENCH_SCALING_N", "100000"))

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

# `shared` (deduplicated ingest) is out of the default set; add it explicitly.
const KINDS = split(
    get(
        ENV,
        "BENCH_KINDS",
        "ingest,sweep,has,reads,dst,serialize,remove,scaling",
    ),
    ",",
)
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
# its time series store can be measured.
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

# Batched adds: stage on the transaction's AddBatch and commit once.
function bulk_add!(f::Function, sys)
    IS.time_series_transaction(sys) do txn
        f((c, ts; features = nothing) ->
            IS.add_time_series!(txn, c, ts; features = features))
    end
end

function report(kind, eltype, op, n, t, b, status)
    @printf("%s,%s,%s,%d,%.3f,%.3f,%d,%s\n", kind, eltype, op,
        n, t, 1e6 * t / n, b, status)
    flush(stdout)
end

error_status(e) = "error: " * replace(first(sprint(showerror, e), 200), r"[,\n]" => ";")

# Times f() with GC quiesced first; one CSV row per call. Failures are recorded,
# not fatal, so one bad combo does not abort the run.
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
# the first combo attributes cleanly; later rows are upper bounds.
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
# sweep-only section does not duplicate the ingest matrix; `sweep = true`
# appends the by-timestamp sweep; `reads = true` appends the read canary.
function run_static_kind(kind, eltype, n;
    shared::Bool = false, sweep::Bool = false, reads::Bool = false,
    main_ops::Bool = true)
    make_val = VAL_MAKERS[eltype]
    sys, comps, dir = build_system(n)
    rng = Random.Xoshiro(1234)
    is_sts = startswith(kind, "sts")
    make_one =
        () -> if is_sts
            IS.SingleTimeSeries("val", T0, RES, [make_val(rng) for _ in 1:LEN])
        else
            IS.NonSequentialTimeSeries("val", irregular_timestamps(rng, LEN),
                [make_val(rng) for _ in 1:LEN])
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

    if reads
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

    if sweep
        # Reader construction is a one-time O(entries) catalog query, not part of
        # the per-value read cost — a simulation builds one reader and sweeps
        # thousands of timesteps through it. Timed as its own row so that both
        # costs stay visible and neither hides the other.
        reader = Ref{Any}(nothing)
        built = timed_op(kind, eltype, "build_static_reader", n,
            () ->
                reader[] = IS.build_static_time_series_reader(sys;
                    resolution = RES, name = "val"))
        io_time = Ref(0.0)
        swept =
            built && timed_op(kind, eltype, "read_by_timestamp", n * LEN,
                () -> sweep_static!(reader[], RES, T0, LEN, io_time))
        # µs per actual storage read, against µs per value in the row above.
        swept && report(kind, eltype, "timestamp_storage_read", LEN, io_time[], 0, "ok")
    end
    return
end

# By-timestamp reads over every component via a prebuilt StaticTimeSeriesReader:
# one columnar storage read per timestamp serves all entries. `io_time`
# accumulates the storage reads alone, so the per-value figure below cannot be
# mistaken for the cost of a read: there are `len` reads here, not `len` x
# entries. Timing them inline (rather than in a separate pass) keeps every read
# a first touch, which is the simulation access pattern -- each timestep is read
# once, never re-read.
function sweep_static!(reader, resolution, t0, len, io_time)
    nentries = length(reader)
    nread = 0
    for k in 0:(len - 1)
        io_time[] += @elapsed IS.read_static_time_series_values!(reader,
            t0 + resolution * k)
        for i in 1:nentries
            # Structured payloads decode to a FunctionData here, scalars to a
            # Float64; touching the result keeps the decode from being elided.
            IS.get_static_time_series_value(reader, i) === nothing &&
                error("missing value at entry $i")
            nread += 1
        end
    end
    return nread
end

# By-window reads over every component via a prebuilt ForecastReader. See
# `sweep_static!` on `io_time`: one storage read per window serves every entry.
function sweep_forecast!(reader, interval, t0, count, io_time)
    nentries = length(reader)
    nwindows = 0
    for k in 0:(count - 1)
        io_time[] += @elapsed IS.read_forecast_window!(reader, t0 + interval * k)
        for i in 1:nentries
            window = IS.get_forecast_window(reader, i)
            length(window) == 0 && error("empty forecast window")
            nwindows += 1
        end
    end
    return nwindows
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
    shared::Bool = false, sweep::Bool = false, reads::Bool = false,
    main_ops::Bool = true)
    sys, comps, dir = build_system(n)
    rng = Random.Xoshiro(1234)
    make_val = VAL_MAKERS[eltype]
    is_det = startswith(kind, "det")
    make_one =
        () -> if is_det
            IS.Deterministic("fc", make_det_data(make_val, rng), RES, INTERVAL)
        elseif kind == "prob"
            IS.Probabilistic("fc", make_matrix_data(rng, NPCT), PERCENTILES, RES, INTERVAL)
        else
            IS.Scenarios("fc", make_matrix_data(rng, NSCEN), NSCEN, RES, INTERVAL)
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

    if reads
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

    if sweep
        reader = Ref{Any}(nothing)
        built = timed_op(kind, eltype, "build_forecast_reader", n,
            () ->
                reader[] = IS.build_forecast_reader(sys, ttype;
                    resolution = RES, name = "fc"))
        io_time = Ref(0.0)
        swept =
            built && timed_op(kind, eltype, "read_by_window", n * NWIN,
                () -> sweep_forecast!(reader[], INTERVAL, T0, NWIN, io_time))
        swept && report(kind, eltype, "window_storage_read", NWIN, io_time[], 0, "ok")
    end
    return
end

# ---- DeterministicSingleTimeSeries (transform_single_time_series!) ---------
# SingleTimeSeries transformed in place to DST forecasts, then read window by
# window — the standard PowerSimulations feed path.

function run_dst_kind(n)
    sys, comps, _ = build_system(n)
    rng = Random.Xoshiro(1234)
    tss = [IS.SingleTimeSeries("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
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

    nwin = Dates.Millisecond(RES * (LEN - HORIZON)) ÷ Dates.Millisecond(INTERVAL) + 1
    reader = Ref{Any}(nothing)
    built = timed_op("dst", "float64", "build_forecast_reader", n,
        () ->
            reader[] = IS.build_forecast_reader(sys, IS.DeterministicSingleTimeSeries;
                resolution = RES, name = "val"))
    io_time = Ref(0.0)
    swept =
        built && timed_op("dst", "float64", "read_by_window", n * nwin,
            () -> sweep_forecast!(reader[], INTERVAL, T0, nwin, io_time))
    swept && report("dst", "float64", "window_storage_read", nwin, io_time[], 0, "ok")
    return
end

# ---- Serialization round-trip ----------------------------------------------
# to_json / from_json of a system holding n Float64 SingleTimeSeries, including
# the time series store artifacts; the reload is verified with one read.

function run_serialize_kind(n)
    sys, comps, _ = build_system(n)
    rng = Random.Xoshiro(1234)
    tss = [IS.SingleTimeSeries("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
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
    tss = [IS.SingleTimeSeries("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
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
# n *associations* spread over n ÷ 10 components: 10 per component, from 2 names
# × 5 scenario values, each association also carrying a model_year feature.
# Queries pass the full identity: type, name, resolution, and both features.
#
# Only 2 distinct arrays are ever constructed, and the store deduplicates them
# by content, so the .h5 holds ~9 KB no matter how large n is (the
# store_disk_bytes row below shows it). This section therefore measures
# association and feature-set work, NOT array writes -- which is why its
# per-association add cost is not comparable to the ingest matrix's `bulk_add`,
# where every op writes a distinct array. Hence the distinct op name.

function run_has_kind(n)
    ncomp = max(n ÷ 10, 1)
    sys, comps, dir = build_system(ncomp)
    rng = Random.Xoshiro(1234)
    # 10 shared instances; the store deduplicates the repeated arrays.
    base = [IS.SingleTimeSeries("ts$a", T0, RES, rand(rng, LEN)) for a in 1:2]
    names = [("ts$(mod1(j, 2))", "s$(div(j - 1, 2) + 1)") for j in 1:10]

    nq = ncomp * 10
    added = timed_op(
        "has_ts",
        "float64",
        "bulk_add_associations",
        nq,
        () -> bulk_add!(sys) do addfn
            for c in comps, (j, (name, scen)) in enumerate(names)
                addfn(c, base[mod1(j, 2)];
                    features = Dict("scenario" => scen, "model_year" => "2030"))
            end
        end,
    )
    added && report_disk("has_ts", "float64", dir)

    hits = Ref(0)
    ok = timed_op(
        "has_ts",
        "float64",
        "has_hit",
        nq,
        () -> begin
            for c in comps, (name, scen) in names
                hits[] += IS.has_time_series(c, IS.SingleTimeSeries, name;
                    resolution = RES,
                    features = Dict("scenario" => scen, "model_year" => "2030"))
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
                    resolution = RES,
                    features = Dict("scenario" => "s99", "model_year" => "2030"))
            end
        end,
    )
    ok && misses[] != 0 && error("has_miss returned $(misses[]) unexpected trues")
    return
end

# ---- Scaling canary --------------------------------------------------------
# The same ingest at two store sizes. µs/op must stay flat: a rising ratio means
# a per-op cost that grows with store size (the O(N²) failure mode the storage
# rewrite removed). Compared by report.jl, not asserted here.

function run_scaling_kind(small, large)
    for n in (small, large)
        sys, comps, _ = build_system(n)
        rng = Random.Xoshiro(1234)
        tss = [IS.SingleTimeSeries("val", T0, RES, rand(rng, LEN)) for _ in 1:n]
        timed_op("scaling", "float64", "bulk_add_at_$n", n,
            () -> bulk_add!(sys) do addfn
                for i in 1:n
                    addfn(comps[i], tss[i])
                end
            end)
        tss = nothing
    end
    return
end

# ---- top level -------------------------------------------------------------

function run_all(n, sweep_n, scaling_n)
    # Ingest matrix: every time series type × element type, bulk_add only.
    if "ingest" in KINDS
        for eltype in ELTYPES
            run_static_kind("sts", eltype, n)
            run_static_kind("nst", eltype, n)
            run_forecast_kind("det", eltype, n)
        end
        run_forecast_kind("prob", "float64", n)
        run_forecast_kind("scen", "float64", n)
    end
    # Simulation inner loop, at production scale. float64 is the common case;
    # pwl exercises the structured-payload decode (PSY's time-varying costs) and
    # runs at the smaller n because that decode is the expensive part.
    if "sweep" in KINDS
        run_static_kind("sts", "float64", sweep_n; sweep = true, main_ops = false)
        run_static_kind("sts", "pwl", n; sweep = true, main_ops = false)
        run_forecast_kind("det", "float64", sweep_n; sweep = true, main_ops = false)
    end
    "has" in KINDS && run_has_kind(sweep_n)
    # Per-series read canary: float64 only. The ingest matrix already covers the
    # per-payload encode paths and the sweeps cover the decode paths.
    if "reads" in KINDS
        run_static_kind("sts", "float64", n; reads = true, main_ops = false)
        run_forecast_kind("det", "float64", n; reads = true, main_ops = false)
    end
    "dst" in KINDS && run_dst_kind(n)
    "serialize" in KINDS && run_serialize_kind(n)
    "remove" in KINDS && run_remove_kind(n)
    "scaling" in KINDS && run_scaling_kind(n, scaling_n)
    # Opt-in: one instance added to every component (deduplicated storage).
    if "shared" in KINDS
        run_static_kind("sts_shared", "float64", n;
            shared = true, sweep = true, reads = true)
        run_forecast_kind("det_shared", "float64", n;
            shared = true, sweep = true, reads = true)
    end
    return
end

println("kind,eltype,op,n,total_s,us_per_op,bytes,status")
# Warmup (JIT) on a small system.
redirect_stdout(devnull) do
    run_all(40, 40, 40)
end
run_all(N, SWEEP_N, SCALING_N)
println("DONE")
