# Load-zone distribution factors: one series per bus against one matrix series.
#
#   julia --project=test benchmark/matrix_bench.jl > matrix.csv   # every case, fresh process each
#   julia --project=test benchmark/matrix_bench.jl M2              # one case, rows only
#
# Sizes: MATRIX_BUSES (50000), MATRIX_ZONES (8), MATRIX_STEPS (24). See README.md.
include(joinpath(@__DIR__, "bench.jl"))  # helpers only; its own run is guarded

const TS_NAME = "distribution_factor"
const CASES = ("B0-Det", "B0-DST", "M1", "M2", "M2-DST")
const READ_REPEATS = parse(Int, get(ENV, "MATRIX_READ_REPEATS", "3"))

struct Fixture
    nzone::Int
    nbus::Int
    steps::Int
    members::Vector{Vector{Int}}      # bus numbers per zone, ascending
    factors::Vector{Matrix{Float64}}  # (steps, members) per zone; each row sums to 1
end

# Bus b sits in zone mod1(b, nzone). Factors are smooth in time, distinct per bus so the
# store cannot deduplicate them, and normalized within each zone at every step.
function Fixture(nzone, nbus, steps)
    members = [collect(z:nzone:nbus) for z in 1:nzone]
    factors = map(members) do buses
        raw = [1.0 + 0.5 * sinpi(2 * (t + b) / steps) + 1e-6 * b for t in 1:steps, b in buses]
        raw ./ sum(raw; dims = 2)
    end
    return Fixture(nzone, nbus, steps, members, factors)
end

# ---- payloads (built outside the timed write) ----------------------------------

per_bus(fx, make) =
    [
        (z, b, make(fx.factors[z][:, j])) for z in 1:(fx.nzone) for
        (j, b) in enumerate(fx.members[z])
    ]

m1_payload(fx) = [
    IS.SingleTimeSeries(TS_NAME, T0, RES, fx.factors[z];
        value_axes = [IS.TimeSeriesAxis("bus", fx.members[z])])
    for z in 1:(fx.nzone)
]

# One (steps, zone, bus) array over every bus; 0 where a bus is outside the zone.
function m2_payload(fx, zones)
    a = zeros(fx.steps, fx.nzone, fx.nbus)
    for z in 1:(fx.nzone), (j, b) in enumerate(fx.members[z])
        a[:, z, b] .= view(fx.factors[z], :, j)
    end
    value_axes = [
        IS.TimeSeriesAxis("zone", IS.get_name.(zones)),
        IS.TimeSeriesAxis("bus", collect(1:(fx.nbus))),
    ]
    return IS.SingleTimeSeries(TS_NAME, T0, RES, a; value_axes = value_axes)
end

function make_payload(case, fx, zones)
    case == "B0-Det" &&
        return per_bus(fx, v -> IS.Deterministic(TS_NAME, SortedDict(T0 => v), RES))
    case == "B0-DST" && return per_bus(fx, v -> IS.SingleTimeSeries(TS_NAME, T0, RES, v))
    case == "M1" && return m1_payload(fx)
    return m2_payload(fx, zones)
end

# ---- writes --------------------------------------------------------------------

function write_case!(case, sys, zones, items, fx)
    if case in ("B0-Det", "B0-DST")
        IS.time_series_transaction(sys) do txn
            for (z, b, ts) in items
                IS.add_time_series!(
                    txn,
                    zones[z],
                    ts;
                    features = Dict{String, Any}("bus" => b),
                )
            end
        end
    elseif case == "M1"
        IS.time_series_transaction(sys) do txn
            for (zone, ts) in zip(zones, items)
                IS.add_time_series!(txn, zone, ts)
            end
        end
    else
        IS.add_time_series!(sys, zones, items)  # one array, one row per zone
    end
    case in ("B0-DST", "M2-DST") && IS.transform_single_time_series!(
        sys, IS.DeterministicSingleTimeSeries, Hour(fx.steps), Hour(fx.steps),
    )
    return
end

# ---- reads: each returns (bus numbers, (steps, buses) factors) for one zone -----

# PowerOperationsModels cc12092: one catalog pass, then one window read per member bus.
function read_zone_per_bus(fx, zone, z)
    keys = Dict{Int, IS.TimeSeriesKey}()
    for md in IS.list_time_series_metadata(
        zone; time_series_type = IS.Deterministic, name = TS_NAME,
    )
        keys[IS.get_features(md)["bus"]] = IS.get_time_series_key(md)
    end
    buses = fx.members[z]
    out = Matrix{Float64}(undef, fx.steps, length(buses))
    for (j, b) in enumerate(buses)
        out[:, j] =
            IS.get_time_series_values(zone, keys[b]; start_time = T0, len = fx.steps)
    end
    return buses, out
end

function read_zone_m1(fx, zone)
    ts = IS.get_time_series(
        IS.SingleTimeSeries,
        zone,
        TS_NAME;
        start_time = T0,
        len = fx.steps,
    )
    return only(IS.get_value_axes(ts)).labels, IS.get_array(ts)
end

# A zone's slice of a (steps, zone, bus) array: its buses are the nonzero columns.
function zone_slice(values, value_axes, zone)
    zone_axis, bus_axis = value_axes
    zi = findfirst(==(IS.get_name(zone)), zone_axis.labels)
    cols = findall(!iszero, view(values, 1, zi, :))
    return bus_axis.labels[cols], values[:, zi, cols]
end

function read_zone_m2(fx, zone)
    ts = IS.get_time_series(
        IS.SingleTimeSeries,
        zone,
        TS_NAME;
        start_time = T0,
        len = fx.steps,
    )
    return zone_slice(IS.get_array(ts), IS.get_value_axes(ts), zone)
end

function read_zone_m2_dst(fx, zone)
    det =
        IS.get_time_series(IS.Deterministic, zone, TS_NAME; start_time = T0, len = fx.steps)
    return zone_slice(only(values(IS.get_data(det))), IS.get_value_axes(det), zone)
end

function read_zone(case, fx, zone, z)
    case in ("B0-Det", "B0-DST") && return read_zone_per_bus(fx, zone, z)
    case == "M1" && return read_zone_m1(fx, zone)
    case == "M2" && return read_zone_m2(fx, zone)
    return read_zone_m2_dst(fx, zone)
end

# Group zones by the array behind their row and read each array once. M2's rows share
# their labels as well as their array, so the first row's axes serve every zone.
function read_all_m2(fx, zones)
    hashes = IS.get_time_series_hashes(zones, IS.SingleTimeSeries, TS_NAME)
    arrays = Dict{String, IS.SingleTimeSeries}()
    return map(zones) do zone
        ts = get!(arrays, hashes[IS.get_id(zone)]) do
            IS.get_time_series(
                IS.SingleTimeSeries,
                zone,
                TS_NAME;
                start_time = T0,
                len = fx.steps,
            )
        end
        zone_slice(IS.get_array(ts), IS.get_value_axes(ts), zone)
    end
end

# The forecast reader reads a shared array once per window; labels come from the row.
function read_all_m2_dst(sys, zones)
    reader =
        IS.build_forecast_reader(sys, IS.Deterministic; resolution = RES, name = TS_NAME)
    IS.read_forecast_window!(reader, T0)
    entries = IS.get_forecast_reader_entries(reader)
    return map(zones) do zone
        i = findfirst(e -> e.owner === zone, entries)
        md = only(
            IS.list_time_series_metadata(
                zone; time_series_type = IS.Deterministic, name = TS_NAME,
            ),
        )
        zone_slice(IS.get_forecast_window(reader, i), IS.get_value_axes(md), zone)
    end
end

read_all(case, fx, sys, zones) =
    case == "M2" ? read_all_m2(fx, zones) : read_all_m2_dst(sys, zones)

# ---- serialization -------------------------------------------------------------

function ser_legacy(sys, dir)
    path = joinpath(dir, "system.json")
    IS.prepare_for_serialization_to_file!(sys, path; force = true)
    open(io -> IS.JSON.json(io, IS.serialize(sys)), path, "w")
    return path
end

# Component deserialization is normally directed by the parent package; replicate it.
function de_legacy(path)
    data = open(io -> IS.JSON.parse(io; dicttype = Dict{String, Any}), path)
    return cd(dirname(path)) do
        sys2 = IS.deserialize(IS.SystemData, data)
        for component in data["components"]
            type = IS.get_type_from_serialization_data(component)
            IS.add_component!(
                sys2, IS.deserialize(type, component); allow_existing_time_series = true,
            )
        end
        sys2
    end
end

function ser_openapi(sys, dir)
    write(joinpath(dir, "rows.json"), IS.openapi_time_series_association_json(sys))
    IS.serialize_arrays(IS.get_data_store(sys), joinpath(dir, "arrays.h5"))
    return
end

function de_openapi(dir)
    store = IS.deserialize_arrays(joinpath(dir, "arrays.h5"))
    IS.import_time_series_association_rows!(store, read(joinpath(dir, "rows.json"), String))
    return store
end

# ---- checks and sizes ----------------------------------------------------------

function check(case, op, fx, got)
    ok = !isnothing(got) && all(1:(fx.nzone)) do z
        buses, values = got[z]
        buses == fx.members[z] && values == fx.factors[z]
    end
    status = ok ? "ok" : "error: factors differ from the fixture"
    report(case, "float64", "check_" * op, 1, 0.0, 0, status)
end

series_values(ts::IS.SingleTimeSeries) = IS.get_array(ts)
series_values(ts::IS.Deterministic) = collect(values(IS.get_data(ts)))

# Association ids survive the OpenAPI path, so every original key must read the same.
function check_store(case, sys, zones, store)
    original = IS.get_data_store(sys)
    ok = all(zones) do zone
        all(IS.list_time_series_metadata(zone; name = TS_NAME)) do md
            key = IS.get_time_series_key(md)
            a, b = IS.get_time_series(store, key), IS.get_time_series(original, key)
            series_values(a) == series_values(b) &&
                IS.get_value_axes(a) == IS.get_value_axes(b)
        end
    end
    report(
        case,
        "float64",
        "check_de_openapi",
        1,
        0.0,
        0,
        ok ? "ok" : "error: store differs",
    )
end

# Bytes per file extension (.h5, .sqlite, .json) under `dir`.
function report_files(case, prefix, dir)
    sizes = Dict{String, Int}()
    for f in readdir(dir)
        ext = last(splitext(f))
        sizes[ext] = get(sizes, ext, 0) + filesize(joinpath(dir, f))
    end
    for (ext, bytes) in sort!(collect(sizes))
        report(case, "float64", "$(prefix)_bytes$(ext)", 1, 0.0, bytes, "ok")
    end
end

# ---- one case ------------------------------------------------------------------

function run_case(case, fx)
    sys, zones, dir = build_system(fx.nzone)
    n = fx.nbus
    items = make_payload(case, fx, zones)
    timed_op(case, "float64", "write", n, () -> write_case!(case, sys, zones, items, fx))
    items = nothing
    report_files(case, "store", dir)

    # Reads leave the store as it was, so they repeat; the report takes each op's median.
    got = Ref{Any}(nothing)
    for _ in 1:READ_REPEATS
        timed_op(case, "float64", "read_zone", n,
            () -> got[] = [read_zone(case, fx, zone, z) for (z, zone) in enumerate(zones)])
    end
    check(case, "read_zone", fx, got[])
    if case in ("M2", "M2-DST")
        got[] = nothing
        for _ in 1:READ_REPEATS
            timed_op(case, "float64", "read_all_once", n,
                () -> got[] = read_all(case, fx, sys, zones))
        end
        check(case, "read_all_once", fx, got[])
    end

    legacy_dir = mktempdir()
    path = Ref{String}()
    timed_op(case, "float64", "ser_legacy", n, () -> path[] = ser_legacy(sys, legacy_dir))
    report_files(case, "legacy", legacy_dir)
    sys2 = Ref{Any}(nothing)
    timed_op(case, "float64", "de_legacy", n, () -> sys2[] = de_legacy(path[]))
    if !isnothing(sys2[])
        zones2 = [IS.get_component(IS.TestComponent, sys2[], IS.get_name(z)) for z in zones]
        check(
            case,
            "de_legacy",
            fx,
            [read_zone(case, fx, zone, z) for (z, zone) in enumerate(zones2)],
        )
    end

    api_dir = mktempdir()
    timed_op(case, "float64", "ser_openapi", n, () -> ser_openapi(sys, api_dir))
    report_files(case, "openapi", api_dir)
    store2 = Ref{Any}(nothing)
    timed_op(case, "float64", "de_openapi", n, () -> store2[] = de_openapi(api_dir))
    isnothing(store2[]) || check_store(case, sys, zones, store2[])

    report_maxrss(case, "float64")
    return
end

# ---- driver --------------------------------------------------------------------

function main(args)
    fx = Fixture(
        parse(Int, get(ENV, "MATRIX_ZONES", "8")),
        parse(Int, get(ENV, "MATRIX_BUSES", "50000")),
        parse(Int, get(ENV, "MATRIX_STEPS", "24")),
    )
    if isempty(args)
        println("kind,eltype,op,n,total_s,us_per_op,bytes,status")
        flush(stdout)  # children write to the same fd; keep the header first
        for case in CASES
            # A fresh process per case, so its maxrss row belongs to that case alone.
            cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(@__FILE__) $case`
            success(pipeline(cmd; stdout = stdout, stderr = stderr)) ||
                report(case, "float64", "process", 1, NaN, 0, "error: case process failed")
        end
        println("DONE")
        return
    end
    case = only(args)
    case in CASES || error("unknown case $case; expected one of $(join(CASES, ", "))")
    # JIT warmup on a small fixture, so the timed rows measure the run, not compilation.
    redirect_stdout(devnull) do
        run_case(case, Fixture(fx.nzone, 16 * fx.nzone, fx.steps))
    end
    run_case(case, fx)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
