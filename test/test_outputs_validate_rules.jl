# Tests that `validate_document` and `read_outputs_document` reject each violation of the
# outputs schema and of the cross-reference rules of IS.

_sim_meta() = IS.read_outputs_document(outputs_fixture("simulation"))
_pf_meta() = IS.read_outputs_document(outputs_fixture("power_flow"))

# A cross-reference rule of IS rejects `m`.
function _expect_invalid(m::IS.OutputsDocument, rx::Regex)
    @test_throws ArgumentError IS.validate_document(m)
    @test_throws rx IS.validate_document(m)
    return
end

# The label describes the case at the call site.
_expect_invalid(::String, m::IS.OutputsDocument, rx::Regex) =
    _expect_invalid(m, rx)

function _set_dataset!(m, model, i, d)
    outputs_model(m, model).datasets[i] = d
    return m
end

function _set_entry(m, model; kw...)
    i = outputs_model_index(m, model)
    m.models[i] = _with(m.models[i]; kw...)
    return m
end

# Reading the JSON file at `path` throws an `ArgumentError` that `rx` matches.
function _expect_read_invalid(path::AbstractString, rx::Regex)
    @test_throws ArgumentError IS.read_outputs_document(path)
    @test_throws rx IS.read_outputs_document(path)
    return
end

# The first dataset, axis, or table column of model UC in the raw simulation fixture.
_raw_uc(raw) = raw["models"][1]
_raw_ds(raw) = _raw_uc(raw)["datasets"][1]
_raw_axis(raw, kind) = first(a for a in _raw_uc(raw)["axes"] if a["kind"] == kind)
_raw_model(raw, name) = first(m for m in raw["models"] if m["name"] == name)
_raw_model_axis(raw, model, kind) =
    first(a for a in _raw_model(raw, model)["axes"] if a["kind"] == kind)
_raw_column(raw, i) = _raw_uc(raw)["tables"][1]["columns"][i]

@testset "validate_document: dataset field rules" begin
    ds(m) = outputs_model(m, "UC").datasets[1]
    path =
        outputs_fixture_with(
            raw -> (_raw_ds(raw)["quantity_kind"] = "active power"),
            "simulation",
        )
    expect_schema_invalid(path, r"/quantity_kind: pattern")
    for fill in ("Inf", "nan", "1.5")
        expect_schema_invalid(
            _set_dataset!(_sim_meta(), "UC", 1, _with(ds(_sim_meta()); fill_value = fill)),
            r"/fill_value: anyOf",
        )
    end
    expect_schema_invalid(
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(ds(_sim_meta()); dtype = "i32", fill_value = 2^40),
        ),
        r"/fill_value: maximum",
    )
    for (dtype, fill) in (
        ("bool", 0), ("bool", 1.0), ("bool", "NaN"), ("f64", true), ("f32", false),
        ("i64", true), ("i32", false), ("i64", "NaN"), ("f64", "Inf"),
    )
        expect_schema_invalid(
            _set_dataset!(
                _sim_meta(), "UC", 1,
                _with(ds(_sim_meta()); dtype = dtype, fill_value = fill),
            ),
            r"/fill_value: ",
        )
    end
    for (dtype, fill) in (
        ("bool", false), ("bool", true), ("f64", 0), ("f64", 1.5), ("f64", "NaN"),
        ("i64", -3), ("i32", 7), ("i64", 2.0), ("f32", "NaN"),
    )
        m = _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(ds(_sim_meta()); dtype = dtype, fill_value = fill),
        )
        @test IS.validate_document(m) === nothing
    end
    d = ds(_sim_meta())
    for (label, chunks) in (("chunk of zero", [1, 0, 48]), ("negative chunk", [1, 76, -3]))
        expect_schema_invalid(
            _set_dataset!(
                _sim_meta(), "UC", 1,
                _with(d; chunks = chunks),
            ),
            r"/chunks/\d: minimum",
        )
    end
    expect_schema_invalid(
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; axes = ["execution", "ThermalStandard", "ThermalStandard"]),
        ),
        r"/axes: uniqueItems",
    )
    expect_schema_invalid(
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; axes = String[]),
        ),
        r"/axes: minItems",
    )
    expect_schema_invalid(
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(
                d;
                unit_system = IS.NU,
                units = "",
            ),
        ),
        r"/units: minLength",
    )
    expect_schema_invalid(
        _set_dataset!(_sim_meta(), "UC", 1, _with(d; units = "MW")),
        r"/units: const",
    )
    expect_schema_invalid(
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; filters = ["deflate:10"]),
        ),
        r"/filters/0: pattern",
    )
end

@testset "validate_document: axis rules" begin
    ax(m, key) = outputs_axis(outputs_model(m, "UC"), key)
    function set_axis!(m, key, a)
        set_outputs_axis!(outputs_model(m, "UC"), key, a)
        return m
    end
    function set_em_time!(m; kw...)
        em = outputs_model(m, "EM")
        set_outputs_axis!(em, "time", _with(outputs_axis(em, "time"); kw...))
        return m
    end
    # An IS value holds a duration, so a bad duration string needs the raw JSON.
    for bad in ("1h", "PT", "P1DT", "", "P-1D", "PT9999999999M")
        path = outputs_fixture_with(
            raw -> (_raw_axis(raw, "execution")["interval"] = bad),
            "simulation",
        )
        expect_schema_invalid(path, r"/axes/\d: oneOf")
    end
    path = outputs_fixture_with(
        raw -> (_raw_axis(raw, "horizon")["resolution"] = "1h"),
        "simulation",
    )
    expect_schema_invalid(path, r"/axes/\d: oneOf")
    path = outputs_fixture_with(
        raw -> (_raw_model_axis(raw, "EM", "time")["resolution"] = "5min"),
        "simulation",
    )
    expect_schema_invalid(path, r"/axes/\d: oneOf")
    for n in (0, -2)
        expect_schema_invalid(
            set_axis!(
                _sim_meta(),
                "execution",
                _with(ax(_sim_meta(), "execution"); count = n),
            ),
            r"/count: minimum",
        )
    end
    expect_schema_invalid(
        set_axis!(
            _sim_meta(),
            "horizon",
            _with(ax(_sim_meta(), "horizon"); horizon_count = 0),
        ),
        r"/horizon_count: minimum",
    )
    expect_schema_invalid(set_em_time!(_sim_meta(); length = 0), r"/length: minimum")
    # An IS value derives its group, so a wrong group needs the raw JSON.
    path = outputs_fixture_with(
        raw -> (_raw_axis(raw, "execution")["group"] = "/UC/axes/other"),
        "simulation",
    )
    _expect_read_invalid(path, r"group \"/UC/axes/other\"")
    path = outputs_fixture_with(
        raw -> (_raw_model_axis(raw, "EM", "time")["group"] = "/UC/axes/time"),
        "simulation",
    )
    _expect_read_invalid(path, r"expected \"/EM/axes/time\"")
    # The schema checks the form of a timestamp, IS checks that the date exists.
    path = outputs_fixture_with(
        raw ->
            (_raw_axis(raw, "execution")["initial_timestamp"] = "2024-13-01T00:00:00"),
        "simulation",
    )
    _expect_read_invalid(
        path,
        r"initial_timestamp \"2024-13-01T00:00:00\" is not a valid date",
    )
    thermal = ax(_sim_meta(), "ThermalStandard")
    path = outputs_fixture_with(
        raw -> (_raw_axis(raw, "component")["group"] = "/UC/axes/x"),
        "simulation",
    )
    _expect_read_invalid(path, r"group")
    expect_schema_invalid(
        set_axis!(
            _sim_meta(), "ThermalStandard",
            _with(
                thermal;
                columns = IS.ComponentAxisColumn[],
                subset = "s",
            ),
        ),
        r"/columns: minItems",
    )
    expect_schema_invalid(
        set_axis!(
            _sim_meta(), "ThermalStandard",
            _with(
                thermal;
                columns = [
                    IS.ComponentAxisColumn("bad name", true),
                ],
            ),
        ),
        r"/component_type: pattern",
    )
    expect_schema_invalid(
        set_axis!(_sim_meta(), "ThermalStandard", _with(thermal; length = -1)),
        r"/length: minimum",
    )

    labels(m) = outputs_axis(outputs_model(m, "model"), "winding")
    pf = _pf_meta()
    set_outputs_axis!(
        outputs_model(pf, "model"),
        "winding",
        _with(labels(pf); labels = String[]),
    )
    expect_schema_invalid(pf, r"/labels: minItems")
    pf = _pf_meta()
    set_outputs_axis!(
        outputs_model(pf, "model"), "winding", _with(labels(pf); labels = ["a", "a"]),
    )
    expect_schema_invalid(pf, r"/labels: uniqueItems")
end

@testset "validate_document: model and document rules" begin
    entry(m) = outputs_model(m, "UC")
    for p in (0.0, -100.0)
        expect_schema_invalid(
            _set_entry(_sim_meta(), "UC"; base_power = p),
            r"/base_power: exclusiveMinimum",
        )
    end
    # The schema validation accepts NaN.
    _expect_invalid(
        "base_power NaN",
        _set_entry(_sim_meta(), "UC"; base_power = NaN),
        r"base_power",
    )
    m = _sim_meta()
    m.systems["not-a-uuid"] = "bundle"
    expect_schema_invalid(m, r"/not-a-uuid: pattern")
    m = _sim_meta()
    upper = uppercase(entry(m).system_uuid)
    m.systems[upper] = "bundle"
    expect_schema_invalid(_set_entry(m, "UC"; system_uuid = upper), r": pattern")
    m = _sim_meta()
    m.systems["abc"] = "bundle"
    expect_schema_invalid(_set_entry(m, "UC"; system_uuid = "abc"), r": pattern")
    m = _set_entry(_sim_meta(), "UC"; system_uuid = "00000000-0000-0000-0000-000000000000")
    @test !isempty(m.systems)
    _expect_invalid(
        m,
        r"system_uuid \"00000000-0000-0000-0000-000000000000\" is not in systems",
    )
    for v in ([1, 2], Dict("a" => 1), nothing)
        expect_schema_invalid(
            _set_entry(_sim_meta(), "UC"; settings = Dict{String, Any}("x" => v)),
            r"/x: not",
        )
    end
    for ok in ("a", 1, 2.5, true)
        s = Dict{String, Any}("x" => ok)
        @test IS.validate_document(_set_entry(_sim_meta(), "UC"; settings = s)) === nothing
    end
    for bad in (
        "yesterday", "2026-11-03T18:00:00", "2026-11-03 18:00:00Z",
        "2026-11-03T18:00:00.1234Z", "2026-11-03t18:00:00z", "2026-11-03T18:00:00+0530",
    )
        path = outputs_fixture_with(raw -> (raw["created_at"] = bad), "simulation")
        expect_schema_invalid(path, r"/created_at: pattern")
    end
    for ok in (
        "2026-11-03T18:00:00Z",
        "2026-11-03T18:00:00.123+05:30",
        "2026-11-03T18:00:00-08:00",
    )
        path = outputs_fixture_with(raw -> (raw["created_at"] = ok), "simulation")
        @test IS.validate_document(IS.read_outputs_document(path)) === nothing
    end
    m = _sim_meta()
    uuid = first(keys(m.systems))
    m.systems[uuid] = ""
    expect_schema_invalid(m, Regex("/$uuid: pattern"))
    m = _sim_meta()
    empty!(m.systems)
    expect_schema_invalid(m, r": minProperties")
    m = _sim_meta()
    empty!(m.models)
    expect_schema_invalid(
        _with(
            m;
            simulation = IS.Simulation.NoSimulation(),
            kind = "single",
        ),
        r"/models: minItems",
    )
end

@testset "validate_document: simulation and table rules" begin
    sim(m) = IS.get_simulation(m)
    with_sim(; kw...) = _with(_sim_meta(); simulation = _with(sim(_sim_meta()); kw...))
    path = outputs_fixture_with(
        raw -> (raw["simulation"]["step_resolution"] = "1d"),
        "simulation",
    )
    expect_schema_invalid(path, r"/step_resolution: pattern")
    for n in (-1, 0)
        expect_schema_invalid(with_sim(; num_steps = n), r"/num_steps: minimum")
    end
    expect_schema_invalid(
        with_sim(; execution_order = String[]),
        r"/execution_order: minItems",
    )
    path = outputs_fixture_with(
        raw -> (raw["simulation"]["initial_time"] = "2024-01-32T00:00:00"),
        "simulation",
    )
    _expect_read_invalid(
        path,
        r"initial_time \"2024-01-32T00:00:00\" is not a valid date",
    )
    path = outputs_fixture_with(
        raw -> (raw["simulation"]["step_resolution"] = "PT9999999999M"),
        "simulation",
    )
    expect_schema_invalid(path, r"/step_resolution: pattern")
    # a single document that carries a simulation object, as the schema forbids
    sim_obj = JSON.parse(read(outputs_fixture("simulation"), String))["simulation"]
    path = outputs_fixture_with(raw -> (raw["simulation"] = sim_obj), "single")
    expect_schema_invalid(path, r": not")
    single = IS.read_outputs_document(outputs_fixture("single"))
    expect_schema_invalid(_with(single; simulation = sim(_sim_meta())), r": not")

    table(m) = outputs_model(m, "UC").tables[1]
    set_table!(m, t) = (outputs_model(m, "UC").tables[1] = t; m)
    t = table(_sim_meta())
    expect_schema_invalid(
        set_table!(_sim_meta(), _with(t; length = -1)),
        r"/length: minimum",
    )
    expect_schema_invalid(
        set_table!(_sim_meta(), _with(t; columns = IS.OutputColumn[])),
        r"/columns: minItems",
    )
    cols = copy(t.columns)
    cols[1] = _with(cols[1]; name = "")
    expect_schema_invalid(
        set_table!(_sim_meta(), _with(t; columns = cols)),
        r"/name: pattern",
    )
    function unit_column!(raw; kw...)
        c = _raw_column(raw, 2)
        c["quantity_kind"] = "Dimensionless"
        c["unit_system"] = "SYSTEM_BASE"
        c["units"] = "pu"
        for (k, v) in kw
            c[string(k)] = v
        end
        return
    end
    path = outputs_fixture_with(
        raw -> unit_column!(raw; quantity_kind = "active power"),
        "simulation",
    )
    expect_schema_invalid(path, r"/quantity_kind: pattern")
    path = outputs_fixture_with(
        raw -> unit_column!(raw; units = "MW"),
        "simulation",
    )
    expect_schema_invalid(path, r"/units: const")
end

@testset "read_outputs_document: timestamps are naive" begin
    for suffix in ("Z", "+02:00", "-05:00")
        path = outputs_fixture_with("simulation") do raw
            _raw_axis(raw, "execution")["initial_timestamp"] = "2024-01-01T00:00:00$suffix"
        end
        expect_schema_invalid(path, r"/axes/0: oneOf")
    end
    path = outputs_fixture_with("simulation") do raw
        raw["simulation"]["initial_time"] = "2024-01-01T00:00:00Z"
    end
    expect_schema_invalid(path, r"/simulation/initial_time: pattern")
    path = outputs_fixture_with("simulation") do raw
        _raw_axis(raw, "execution")["initial_timestamp"] = "2024-01-01T00:00:00.250"
    end
    m = IS.read_outputs_document(path)
    @test IS.validate_document(m) === nothing
    @test outputs_axis(outputs_model(m, "UC"), "execution").initial_timestamp ==
          DateTime(2024, 1, 1, 0, 0, 0, 250)
end

@testset "ISO duration predicate" begin
    @test IS.is_iso_duration("PT1H") && IS.is_iso_duration("P2DT30M")
    @test IS.is_iso_duration("PT0M") && IS.is_iso_duration("P1D")
    for bad in (
        "", "P", "PT", "P1DT", "1h", "P-1D", "PT1.5H", "P1W", "PT9999999999M", "P1DT\n",
        "P1D\n", "PT30S", "PT1M30S", "PT0S",
    )
        @test !IS.is_iso_duration(bad)
        @test_throws ArgumentError IS.parse_iso_duration(bad)
    end
    for bad in ("P1Y", "P1M", "P1W", "PT30S")
        @test_throws r"accepts days, hours, and minutes.*not accept seconds, years, months, or weeks" IS.parse_iso_duration(
            bad,
        )
    end
end

@testset "validate_document: the schema rejects each duration that IS rejects" begin
    # An IS value holds a duration, so each spelling goes into the raw JSON. The schema
    # reports a bad axis duration at the axis `oneOf`.
    fields = (
        (
            "/axes/\\d: oneOf",
            "P000000001D",
            (raw, v) -> (_raw_axis(raw, "execution")["interval"] = v),
        ),
        (
            "/axes/\\d: oneOf",
            "PT000000001H",
            (raw, v) -> (_raw_axis(raw, "horizon")["resolution"] = v),
        ),
        (
            "/axes/\\d: oneOf", "PT000000005M",
            (raw, v) -> (_raw_model_axis(raw, "EM", "time")["resolution"] = v),
        ),
        (
            "/step_resolution: pattern",
            "P000000001D",
            (raw, v) -> (raw["simulation"]["step_resolution"] = v),
        ),
    )
    for (pattern, ok, set!) in fields
        path = outputs_fixture_with(raw -> set!(raw, ok), "simulation")
        @test IS.validate_document(IS.read_outputs_document(path)) === nothing
        for bad in (
            "", "P", "PT", "P1DT", "1h", "P-1D", "PT1.5H", "P1W", "P1M", "P1Y",
            "PT9999999999M", "PT0000000001M", "PT30S", "PT1M30S", "P1DT\n", "PT1H\n",
        )
            @test !IS.is_iso_duration(bad)
            path = outputs_fixture_with(raw -> set!(raw, bad), "simulation")
            expect_schema_invalid(path, Regex(pattern))
        end
    end
end

@testset "validate_document: model, axis, table, and meta names are path segments" begin
    for bad in ("", "a/b")
        m = _sim_meta()
        i = outputs_model_index(m, "EM")
        # The derived group of the EM time axis breaks the pattern first.
        m.models[i] = _with(m.models[i]; name = bad)
        expect_schema_invalid(m, r"(Model\s+/name|TimeAxis\s+/group): pattern")
        m = _sim_meta()
        push!(outputs_model(m, "UC").axes, IS.LabelAxis(bad, ["x"]))
        expect_schema_invalid(m, r"LabelAxis\s+/name: pattern")
        m = _sim_meta()
        t = outputs_model(m, "UC").tables[1]
        outputs_model(m, "UC").tables[1] = _with(t; name = bad)
        expect_schema_invalid(m, r"Table\s+/(name|group): pattern")
    end
    m = _sim_meta()
    d = outputs_model(m, "UC").datasets[1]
    outputs_model(m, "UC").datasets[1] = _with(d; meta = "a/b")
    expect_schema_invalid(m, r"/meta: not")
end

@testset "outputs document: simulation presence follows the document" begin
    m = _sim_meta()
    @test IS.has_simulation(m)
    gone = _with(m; simulation = IS.Simulation.NoSimulation())
    @test !IS.has_simulation(gone)
    expect_schema_invalid(gone, r": required")
    @test_throws ErrorException IS.get_simulation(gone)
    path = outputs_fixture_with(raw -> delete!(raw, "simulation"), "simulation")
    expect_schema_invalid(path, r": required")
    # a "present" key is an unknown field
    path = outputs_fixture_with(raw -> (raw["simulation"]["present"] = false), "simulation")
    expect_schema_invalid(path, r"/simulation/present: schema")
end

@testset "validate_document: supports_realized_values_post_calculation" begin
    @test outputs_model(_sim_meta(), "UC").supports_realized_values_post_calculation
    @test IS.validate_document(_sim_meta()) === nothing

    m = _sim_meta()
    delete_outputs_axis!(outputs_model(m, "UC"), "horizon")
    expect_schema_invalid(m, r"/axes: contains")

    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "UC"),
        "execution",
        _with(
            outputs_axis(outputs_model(m, "UC"), "execution");
            interval = Dates.Minute(90),
        ),
    )
    _expect_invalid("interval not a multiple", m, r"model UC: .*whole multiple")

    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "UC"),
        "execution",
        _with(outputs_axis(outputs_model(m, "UC"), "execution"); interval = Dates.Day(3)),
    )
    _expect_invalid("interval above horizon", m, r"model UC: .*at most the horizon")

    path = outputs_fixture_with("single") do raw
        delete!(raw["models"][1], "supports_realized_values_post_calculation")
    end
    expect_schema_invalid(path, r"/models/0: required")
end

@testset "validate_document: axis names bind to axis kinds" begin
    m = _sim_meta()
    push!(
        outputs_model(m, "UC").axes,
        outputs_axis(outputs_model(m, "EM"), "time"),
    )
    expect_schema_invalid(m, r"/axes: not")

    for (model, key) in (("UC", "time"), ("EM", "execution"), ("EM", "horizon"))
        m = _sim_meta()
        push!(outputs_model(m, model).axes, IS.LabelAxis(key, ["x"]))
        expect_schema_invalid(m, r"LabelAxis\s+/name: not")
    end
end

@testset "validate_document: one field changed in a valid document" begin
    single() = IS.read_outputs_document(outputs_fixture("single"))
    edit_dataset(m, model, i; kw...) =
        _set_dataset!(m, model, i, _with(outputs_model(m, model).datasets[i]; kw...))

    m = single()
    d = outputs_model(m, "model").datasets[1]
    _expect_invalid(
        "dataset axis that does not exist",
        edit_dataset(m, "model", 1; axes = [d.axes[1], "Nope", d.axes[3]]),
        r"uses axis \"Nope\" absent from the model axes",
    )
    path = outputs_fixture_with(raw -> (_raw_ds(raw)["container"] = ""), "single")
    expect_schema_invalid(path, r"/container: enum")
    expect_schema_invalid(
        edit_dataset(single(), "model", 1; units = "MW"),
        r"/units: const",
    )
    expect_schema_invalid(edit_dataset(single(), "model", 1; meta = "a__b"), r"/meta: not")
    expect_schema_invalid(
        edit_dataset(single(), "model", 2; dtype = "i64", fill_value = 1.5),
        r"/fill_value: type",
    )
    # A column value has all of its unit fields or none, so the raw JSON drops one.
    path =
        outputs_fixture_with(raw -> delete!(_raw_column(raw, 2), "quantity_kind"), "single")
    expect_schema_invalid(path, r": dependentRequired")
    m = single()
    d = outputs_model(m, "model").datasets[1]
    entry = outputs_model(m, "model")
    entry.datasets[1] = _with(
        d; axes = ["ThermalStandard", "horizon"],
        chunks = [76, 48],
    )
    expect_schema_invalid(m, r"/axes: contains")
    path = outputs_fixture_with(raw -> (raw["kind"] = "GasFlow"), "single")
    expect_schema_invalid(path, r"/kind: pattern")
    expect_schema_invalid(
        _with(single(); schema_version = "0.2.0"),
        r"/schema_version: const",
    )
    m = _sim_meta()
    _set_entry(m, "EM"; supports_realized_values_post_calculation = true)
    expect_schema_invalid(m, r"/axes: contains")
end

@testset "validate_document: a chunk is not longer than its axis" begin
    single() = IS.read_outputs_document(outputs_fixture("single"))
    m = single()
    d = outputs_model(m, "model").datasets[1]
    _set_dataset!(m, "model", 1, _with(d; chunks = [2, 76, 48]))
    _expect_invalid(
        m,
        r"model model: dataset .* chunk 2 on axis \"execution\".* axis length 1",
    )
    @test IS.validate_document(single()) === nothing
    m = single()
    entry = outputs_model(m, "model")
    set_outputs_axis!(
        entry, "ThermalStandard", _with(outputs_axis(entry, "ThermalStandard"); length = 0),
    )
    @test outputs_model(m, "model").datasets[1].chunks == [1, 76, 48]
    @test IS.validate_document(m) === nothing
end

@testset "validate_document: table and column names are unique" begin
    m = _sim_meta()
    t = outputs_model(m, "UC").tables[1]
    cols = copy(t.columns)
    cols[2] = _with(cols[1]; dtype = "f64")
    outputs_model(m, "UC").tables[1] = _with(t; columns = cols)
    _expect_invalid(
        m,
        r"model UC: table optimizer_stats has a duplicate column name \"execution\"",
    )
    m = _sim_meta()
    push!(outputs_model(m, "UC").tables, outputs_model(m, "UC").tables[1])
    _expect_invalid(
        m,
        r"model UC: duplicate table name \"optimizer_stats\"",
    )
    m = _sim_meta()
    @test outputs_model(m, "UC").tables[1].name == outputs_model(m, "ED").tables[1].name
    @test IS.validate_document(m) === nothing
end

@testset "validate_document: two datasets do not share a path" begin
    single() = IS.read_outputs_document(outputs_fixture("single"))
    m = single()
    d = outputs_model(m, "model").datasets[1]
    other = _with(
        d;
        component_type = "",
        meta = "ThermalStandard",
        axes = ["execution", "horizon"],
        chunks = [1, 48],
    )
    @test IS.dataset_key(other) != IS.dataset_key(d)
    push!(outputs_model(m, "model").datasets, other)
    _expect_invalid(
        m,
        r"model model: datasets .* resolve to the same path \"/model/datasets/ActivePowerVariable__ThermalStandard\"",
    )
    m = single()
    push!(
        outputs_model(m, "model").datasets,
        _with(other; meta = "Other"),
    )
    @test IS.validate_document(m) === nothing
end

@testset "validate_document: realized values with extreme horizon durations" begin
    function with_uc!(m; interval, resolution, horizon_count = 48)
        uc = outputs_model(m, "UC")
        set_outputs_axis!(
            uc, "execution", _with(outputs_axis(uc, "execution"); interval = interval),
        )
        set_outputs_axis!(
            uc,
            "horizon",
            _with(
                outputs_axis(uc, "horizon");
                resolution = resolution,
                horizon_count = horizon_count,
            ),
        )
        return m
    end
    _expect_invalid(
        with_uc!(_sim_meta(); interval = Dates.Day(1), resolution = Dates.Minute(0)),
        r"model UC: .*whole multiple",
    )
    m = with_uc!(
        _sim_meta(); interval = Dates.Day(999999999), resolution = Dates.Day(999999999),
        horizon_count = 107,
    )
    @test IS.validate_document(m) === nothing
    @test_throws OverflowError IS.get_horizon(
        outputs_axis(outputs_model(m, "UC"), "horizon"),
    )
    m = with_uc!(
        _sim_meta(); interval = Dates.Day(999999999), resolution = Dates.Day(999999999),
        horizon_count = 1,
    )
    @test IS.get_horizon(outputs_axis(outputs_model(m, "UC"), "horizon")) ==
          Dates.Millisecond(Dates.Day(999999999))
end

@testset "validate_document: bundle directory names" begin
    second = "00000000-0000-0000-0000-000000000001"
    m = _sim_meta()
    uuid, name = first(m.systems)
    m.systems[second] = name
    _expect_invalid(
        m,
        Regex(
            "systems ($uuid and $second|$second and $uuid) use the same bundle directory \"$name\"",
        ),
    )
    m = _sim_meta()
    m.systems[second] = "other-bundle"
    @test IS.validate_document(m) === nothing
    for bad in ("C:foo", "c:")
        m = _sim_meta()
        m.systems[uuid] = bad
        _expect_invalid(
            m,
            Regex("system $uuid: bundle directory \"$bad\" .*drive"),
        )
    end
    m = _sim_meta()
    m.systems[uuid] = "C:\\foo"
    expect_schema_invalid(m, Regex("/$uuid: pattern"))
    m = _sim_meta()
    m.systems[uuid] = "ab:c"
    @test IS.validate_document(m) === nothing
    for bad in ("outputs.json", "outputs.h5", "OUTPUTS.JSON", "outputs.json.tmp")
        m = _sim_meta()
        m.systems[uuid] = bad
        _expect_invalid(
            m,
            Regex(
                "system $uuid: bundle directory \"$bad\" is the name of an artifact file",
            ),
        )
    end
    m = _sim_meta()
    m.systems[uuid] = "outputs"
    @test IS.validate_document(m) === nothing
end

@testset "a document in the two-value form is rejected" begin
    path = outputs_fixture_with("single") do raw
        dataset = _raw_ds(raw)
        dataset["unit_system"] = "COMPONENT_BASE"
        dataset["base_reference"] = "system"
    end
    expect_schema_invalid(path, r"base_reference")
end
