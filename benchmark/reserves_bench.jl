# Linked reserve offers: one Int64 link matrix per device, (blocks x products) per hour.
#
#   julia --project=test benchmark/reserves_bench.jl > reserves.csv   # every case, fresh process each
#   julia --project=test benchmark/reserves_bench.jl R-dev             # one case, rows only
#
# Sizes: RESERVE_DEVICES (4500), RESERVE_STEPS (24), RESERVE_MAX_BLOCKS (10); repeats come
# from MATRIX_REPEATS (3). See README.md.
include(joinpath(@__DIR__, "matrix_bench.jl"))  # helpers only; its own run is guarded

const LINK_NAME = "linked_offers"
const RESERVE_CASES = ("R-dev", "R-fixed", "R-tuple")
const PRODUCTS =
    ["REGUP", "REGDN", "RRS_PFR", "RRS_FFR", "RRS_UFR", "ECRS_SD", "ECRS_MD", "NSPIN"]

# links[d] is device d's (steps, blocks, products) matrix, rows padded to its busiest hour.
# An entry is the step the block became in that product's curve that hour; 0 = not priced.
struct ReserveFixture
    ndev::Int
    steps::Int
    maxb::Int
    links::Vector{Array{Int64, 3}}
end

# Each device offers 2-8 products and has 1-maxb blocks in its busiest hour; other hours
# hold 0 to that many. A product's priced blocks get steps 1..n in a random price order.
function ReserveFixture(ndev, steps, maxb)
    rng = Random.Xoshiro(11)
    nprod = length(PRODUCTS)
    links = map(1:ndev) do _
        nb = rand(rng, 1:maxb)
        offered = Random.shuffle(rng, 1:nprod)[1:rand(rng, 2:nprod)]
        busiest = rand(rng, 1:steps)
        a = zeros(Int64, steps, nb, nprod)
        for t in 1:steps
            k = t == busiest ? nb : rand(rng, 0:nb)
            for p in offered
                rows = [b for b in 1:k if rand(rng) < 0.7]
                a[t, rows, p] .= Random.randperm(rng, length(rows))
            end
        end
        a
    end
    return ReserveFixture(ndev, steps, maxb, links)
end

block_axes(nb) =
    [IS.TimeSeriesAxis("block", collect(1:nb)), IS.TimeSeriesAxis("product", PRODUCTS)]

# R-dev: rows padded to the device's busiest hour, so shapes differ across devices.
dev_series(a, fx) =
    IS.SingleTimeSeries(LINK_NAME, T0, RES, a; value_axes = block_axes(size(a, 2)))

# R-fixed: every device padded to maxb rows, so all share one element shape.
function fixed_series(a, fx)
    padded = zeros(Int64, fx.steps, fx.maxb, length(PRODUCTS))
    padded[:, 1:size(a, 2), :] .= a
    return IS.SingleTimeSeries(LINK_NAME, T0, RES, padded; value_axes = block_axes(fx.maxb))
end

# R-tuple: one Float64 tuple per hour (column-major blocks x products), the form IS4
# already stores and forecasts without value axes. Width differs per device.
tuple_series(a, fx) = IS.SingleTimeSeries(
    LINK_NAME, T0, RES, [Tuple(Float64.(vec(a[t, :, :]))) for t in 1:(fx.steps)],
)

function reserve_payload(case, fx)
    make = case == "R-dev" ? dev_series : case == "R-fixed" ? fixed_series : tuple_series
    return [make(a, fx) for a in fx.links]
end

function write_reserves!(sys, devices, items, fx)
    IS.time_series_transaction(sys) do txn
        for (device, ts) in zip(devices, items)
            IS.add_time_series!(txn, device, ts)
        end
    end
    IS.transform_single_time_series!(
        sys, IS.DeterministicSingleTimeSeries, Hour(fx.steps), Hour(fx.steps),
    )
    return
end

# A read window back to the fixture's (steps, blocks, products) Int64 layout.
decode(window::AbstractArray{<:Real, 3}, nb) = Int64.(window[:, 1:nb, :])
function decode(window::AbstractVector{<:Tuple}, nb)
    np = length(PRODUCTS)
    return permutedims(
        reshape(Int64.(reduce(vcat, collect.(window))), nb, np, length(window)),
        (3, 1, 2),
    )
end

# POM's pattern: one forecast-window read per device.
function read_each(fx, devices)
    return map(enumerate(devices)) do (d, device)
        det = IS.get_time_series(
            IS.Deterministic, device, LINK_NAME; start_time = T0, len = fx.steps,
        )
        only(values(IS.get_data(det)))
    end
end

# The simulation pattern: every device's window at one timestamp through the reader.
function read_reader(reader, devices)
    IS.read_forecast_window!(reader, T0)
    entries = IS.get_forecast_reader_entries(reader)
    slot = Dict(e.owner => i for (i, e) in enumerate(entries))
    return [IS.get_forecast_window(reader, slot[device]) for device in devices]
end

function check_windows(case, op, fx, windows)
    report_check(case, op, "links differ from the fixture") do
        !isnothing(windows) && all(1:(fx.ndev)) do d
            nb = size(fx.links[d], 2)
            decode(windows[d], nb) == fx.links[d]
        end
    end
end

function check_reserve_store(case, sys, devices, store)
    original = IS.get_data_store(sys)
    report_check(case, "de_openapi", "store differs") do
        all(devices) do device
            all(IS.list_time_series_metadata(device; name = LINK_NAME)) do md
                key = IS.get_time_series_key(md)
                a, b = IS.get_time_series(store, key), IS.get_time_series(original, key)
                series_values(a) == series_values(b) &&
                    IS.get_value_axes(a) == IS.get_value_axes(b)
            end
        end
    end
end

function timed_reserve_write(case, fx)
    sys, devices, dir = build_system(fx.ndev)
    items = reserve_payload(case, fx)
    timed_op(
        case,
        "int64",
        "write",
        fx.ndev,
        () -> write_reserves!(sys, devices, items, fx),
    )
    return sys, devices, dir
end

function run_reserve_case(case, fx)
    n = fx.ndev
    for _ in 2:REPEATS
        timed_reserve_write(case, fx)
    end
    sys, devices, dir = timed_reserve_write(case, fx)
    report_files(case, "store", dir)

    got = Ref{Any}(nothing)
    for _ in 1:REPEATS
        timed_op(case, "int64", "read_each", n, () -> got[] = read_each(fx, devices))
    end
    check_windows(case, "read_each", fx, got[])

    reader = Ref{Any}(nothing)
    for _ in 1:REPEATS
        timed_op(
            case,
            "int64",
            "reader_build",
            n,
            () ->
                reader[] = IS.build_forecast_reader(
                    sys, IS.Deterministic; resolution = RES, name = LINK_NAME,
                ),
        )
    end
    got[] = nothing
    for _ in 1:REPEATS
        timed_op(case, "int64", "reader_window", n,
            () -> got[] = read_reader(reader[], devices))
    end
    check_windows(case, "reader_window", fx, got[])

    for r in 1:REPEATS
        legacy_dir = mktempdir()
        path = Ref{String}()
        timed_op(case, "int64", "ser_legacy", n, () -> path[] = ser_legacy(sys, legacy_dir))
        r == 1 && report_files(case, "legacy", legacy_dir)
        sys2 = Ref{Any}(nothing)
        timed_op(case, "int64", "de_legacy", n, () -> sys2[] = de_legacy(path[]))
        isnothing(sys2[]) || check_windows(
            case,
            "de_legacy",
            fx,
            read_each(
                fx,
                [
                    IS.get_component(IS.TestComponent, sys2[], IS.get_name(d)) for
                    d in devices
                ],
            ),
        )
    end

    for r in 1:REPEATS
        api_dir = mktempdir()
        timed_op(case, "int64", "ser_openapi", n, () -> ser_openapi(sys, api_dir))
        r == 1 && report_files(case, "openapi", api_dir)
        store2 = Ref{Any}(nothing)
        timed_op(case, "int64", "de_openapi", n, () -> store2[] = de_openapi(api_dir))
        isnothing(store2[]) || check_reserve_store(case, sys, devices, store2[])
    end

    report_maxrss(case, "int64")
    return
end

function reserves_main(args)
    if isempty(args)
        println("kind,eltype,op,n,total_s,us_per_op,bytes,status")
        flush(stdout)  # children write to the same fd; keep the header first
        for case in RESERVE_CASES
            # A fresh process per case, so its maxrss row belongs to that case alone.
            cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(@__FILE__) $case`
            success(pipeline(cmd; stdout = stdout, stderr = stderr)) ||
                report(case, "int64", "process", 1, NaN, 0, "error: case process failed")
        end
        println("DONE")
        return
    end
    case = only(args)
    case in RESERVE_CASES ||
        error("unknown case $case; expected one of $(join(RESERVE_CASES, ", "))")
    steps = parse(Int, get(ENV, "RESERVE_STEPS", "24"))
    maxb = parse(Int, get(ENV, "RESERVE_MAX_BLOCKS", "10"))
    # JIT warmup on a small fixture, so the timed rows measure the run, not compilation.
    redirect_stdout(devnull) do
        run_reserve_case(case, ReserveFixture(40, steps, maxb))
    end
    fx = ReserveFixture(parse(Int, get(ENV, "RESERVE_DEVICES", "4500")), steps, maxb)
    run_reserve_case(case, fx)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    reserves_main(ARGS)
end
