# Tests the rules of `validate_metadata` that mirror the outputs JSON schema, and the
# naive-timestamp rule of `read_outputs_metadata`.

_sim_meta() = IS.read_outputs_metadata(
    joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
)
_pf_meta() = IS.read_outputs_metadata(
    joinpath(DATA_DIR, "outputs", "power_flow", "outputs.json"),
)

function _expect_invalid(label::String, m::IS.OutputsMetadata, rx::Regex)
    @test_throws ArgumentError IS.validate_metadata(m)
    @test_throws rx IS.validate_metadata(m)
    return
end

function _set_dataset!(m, model, i, d)
    outputs_model(m, model).datasets[i] = d
    return m
end

function _set_entry(m, model; kw...)
    i = outputs_model_index(m, model)
    m.models[i] = _with(m.models[i]; kw...)
    return m
end

@testset "validate_metadata: dataset field rules" begin
    ds(m) = outputs_model(m, "UC").datasets[1]
    _expect_invalid(
        "quantity_kind outside the enum",
        _set_dataset!(
            _sim_meta(),
            "UC",
            1,
            _with(ds(_sim_meta()); quantity_kind = "Bogus"),
        ),
        r"quantity_kind \"Bogus\"",
    )
    for fill in ("Inf", "nan", "1.5")
        _expect_invalid(
            "fill_value $fill for f64",
            _set_dataset!(_sim_meta(), "UC", 1, _with(ds(_sim_meta()); fill_value = fill)),
            r"fill_value",
        )
    end
    _expect_invalid(
        "fill_value out of range for i32",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(ds(_sim_meta()); dtype = "i32", fill_value = 2^40),
        ),
        r"fill_value",
    )
    for (dtype, fill) in (
        ("bool", 0), ("bool", 1.0), ("bool", "NaN"), ("f64", true), ("f32", false),
        ("i64", true), ("i32", false), ("i64", "NaN"), ("f64", "Inf"),
    )
        _expect_invalid(
            "fill_value $fill for $dtype",
            _set_dataset!(
                _sim_meta(), "UC", 1,
                _with(ds(_sim_meta()); dtype = dtype, fill_value = fill),
            ),
            r"fill_value",
        )
    end
    for (dtype, fill) in (
        ("bool", false), ("bool", true), ("f64", 0), ("f64", 1.5), ("f64", "NaN"),
        ("i64", -3), ("i32", 7), ("i64", 2.0),
    )
        m = _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(ds(_sim_meta()); dtype = dtype, fill_value = fill),
        )
        @test IS.validate_metadata(m) === nothing
    end
    m = _set_dataset!(
        _sim_meta(), "UC", 1, _with(ds(_sim_meta()); dtype = "f32", fill_value = "NaN"),
    )
    @test IS.validate_metadata(m) === nothing
    d = ds(_sim_meta())
    _expect_invalid(
        "chunk of zero",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; layout = IS.DatasetLayout([1, 0, 48], d.layout.filters)),
        ),
        r"chunk is 0",
    )
    _expect_invalid(
        "negative chunk",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; layout = IS.DatasetLayout([1, 76, -3], d.layout.filters)),
        ),
        r"chunk is -3",
    )
    _expect_invalid(
        "repeated dataset axis",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(
                d; axes = ["execution", "ThermalStandard", "ThermalStandard"],
            ),
        ),
        r"repeats an axis",
    )
    _expect_invalid(
        "dataset without axes",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; axes = String[], layout = IS.DatasetLayout(Int[], d.layout.filters)),
        ),
        r"no axes",
    )
    _expect_invalid(
        "empty units",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; unit_system = "NATURAL_UNITS", base_reference = "", units = ""),
        ),
        r"units is empty",
    )
    _expect_invalid(
        "base_reference outside the enum",
        _set_dataset!(_sim_meta(), "UC", 1, _with(d; base_reference = "device")),
        r"base_reference \"device\"",
    )
    _expect_invalid(
        "filter outside the grammar",
        _set_dataset!(
            _sim_meta(), "UC", 1,
            _with(d; layout = IS.DatasetLayout(d.layout.chunks, ["deflate:10"])),
        ),
        r"invalid filter \"deflate:10\"",
    )
end

@testset "validate_metadata: axis rules" begin
    ax(m, key) = outputs_axis(outputs_model(m, "UC"), key)
    function set_axis!(m, key, a)
        set_outputs_axis!(outputs_model(m, "UC"), key, a)
        return m
    end
    for bad in ("1h", "PT", "P1DT", "", "P-1D")
        _expect_invalid(
            "execution interval $bad",
            set_axis!(
                _sim_meta(),
                "execution",
                _with(ax(_sim_meta(), "execution"); interval = bad),
            ),
            r"interval",
        )
    end
    _expect_invalid(
        "horizon resolution",
        set_axis!(
            _sim_meta(),
            "horizon",
            _with(ax(_sim_meta(), "horizon"); resolution = "1h"),
        ),
        r"resolution",
    )
    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "EM"),
        "time",
        _with(outputs_axis(outputs_model(m, "EM"), "time"); resolution = "5min"),
    )
    _expect_invalid("time resolution", m, r"resolution")
    for n in (0, -2)
        _expect_invalid(
            "execution count $n",
            set_axis!(
                _sim_meta(),
                "execution",
                _with(ax(_sim_meta(), "execution"); count = n),
            ),
            r"count is",
        )
    end
    _expect_invalid(
        "horizon_count of zero",
        set_axis!(
            _sim_meta(),
            "horizon",
            _with(ax(_sim_meta(), "horizon"); horizon_count = 0),
        ),
        r"horizon_count is 0",
    )
    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "EM"),
        "time",
        _with(outputs_axis(outputs_model(m, "EM"), "time"); length = 0),
    )
    _expect_invalid("time length of zero", m, r"length is 0")
    _expect_invalid(
        "wrong axis group",
        set_axis!(
            _sim_meta(), "execution",
            _with(ax(_sim_meta(), "execution"); group = "/UC/axes/other"),
        ),
        r"group \"/UC/axes/other\"",
    )
    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "EM"),
        "time",
        _with(outputs_axis(outputs_model(m, "EM"), "time"); group = "/UC/axes/time"),
    )
    _expect_invalid("time group of another model", m, r"expected \"/EM/axes/time\"")
    thermal = ax(_sim_meta(), "ThermalStandard")
    _expect_invalid(
        "component axis group",
        set_axis!(_sim_meta(), "ThermalStandard", _with(thermal; group = "/UC/axes/x")),
        r"group",
    )
    _expect_invalid(
        "component axis without columns",
        set_axis!(
            _sim_meta(), "ThermalStandard",
            _with(thermal; columns = IS.AxisColumn[], subset = "s"),
        ),
        r"has no columns",
    )
    _expect_invalid(
        "component axis column that is no type name",
        set_axis!(
            _sim_meta(), "ThermalStandard",
            _with(thermal; columns = [IS.AxisColumn("bad name", true)]),
        ),
        r"column component_type",
    )
    _expect_invalid(
        "negative component axis length",
        set_axis!(_sim_meta(), "ThermalStandard", _with(thermal; length = -1)),
        r"length is -1",
    )

    pf = _pf_meta()
    labels(m) = outputs_axis(outputs_model(m, "model"), "winding")
    set_outputs_axis!(
        outputs_model(pf, "model"), "winding", _with(labels(pf); labels = String[]),
    )
    _expect_invalid("label axis without labels", pf, r"has no labels")
    pf = _pf_meta()
    set_outputs_axis!(
        outputs_model(pf, "model"), "winding", _with(labels(pf); labels = ["a", "a"]),
    )
    _expect_invalid("label axis with duplicate labels", pf, r"duplicate labels")
end

@testset "validate_metadata: model and document rules" begin
    entry(m) = outputs_model(m, "UC")
    for p in (0.0, -100.0, NaN)
        _expect_invalid(
            "base_power $p",
            _set_entry(_sim_meta(), "UC"; base_power = p),
            r"base_power",
        )
    end
    m = _sim_meta()
    m.systems["not-a-uuid"] = "bundle"
    _expect_invalid("system key that is no UUID", m, r"system key \"not-a-uuid\"")
    m = _sim_meta()
    upper = uppercase(entry(m).system_uuid)
    m.systems[upper] = "bundle"
    _expect_invalid(
        "system_uuid in upper case",
        _set_entry(m, "UC"; system_uuid = upper),
        r"system key|system_uuid",
    )
    m = _sim_meta()
    m.systems["abc"] = "bundle"
    _expect_invalid(
        "system_uuid that is no UUID",
        _set_entry(m, "UC"; system_uuid = "abc"),
        r"system key \"abc\"",
    )
    for (label, v) in (
        ("a vector", [1, 2]),
        ("a dict", Dict("a" => 1)),
        ("nothing", nothing),
    )
        s = Dict{String, Any}("x" => v)
        _expect_invalid(
            "setting that is $label",
            _set_entry(_sim_meta(), "UC"; settings = s),
            r"setting \"x\"",
        )
    end
    for ok in ("a", 1, 2.5, true)
        s = Dict{String, Any}("x" => ok)
        @test IS.validate_metadata(_set_entry(_sim_meta(), "UC"; settings = s)) === nothing
    end
    for bad in (
        "yesterday", "2026-11-03T18:00:00", "2026-11-03 18:00:00Z",
        "2026-11-03T18:00:00.1234Z", "2026-11-03t18:00:00z", "2026-11-03T18:00:00+0530",
    )
        _expect_invalid(
            "created_at $bad",
            _with(_sim_meta(); created_at = bad),
            r"created_at",
        )
    end
    for ok in (
        "2026-11-03T18:00:00Z",
        "2026-11-03T18:00:00.123+05:30",
        "2026-11-03T18:00:00-08:00",
    )
        @test IS.validate_metadata(_with(_sim_meta(); created_at = ok)) === nothing
    end
    uuid = first(keys(_sim_meta().systems))
    _expect_invalid(
        "empty bundle directory name",
        _with(_sim_meta(); systems = Dict(uuid => "")),
        r"plain relative name",
    )
    _expect_invalid(
        "no systems",
        _with(_sim_meta(); systems = Dict{String, String}()),
        r"systems is empty",
    )
    m = _sim_meta()
    empty!(m.models)
    _expect_invalid(
        "no models",
        _with(m; simulation = IS.Simulation.NoSimulation(), kind = "single"),
        r"models is empty",
    )
end

@testset "validate_metadata: simulation and table rules" begin
    sim(m) = IS.get_simulation(m)
    _expect_invalid(
        "step_resolution",
        _with(_sim_meta(); simulation = _with(sim(_sim_meta()); step_resolution = "1d")),
        r"step_resolution",
    )
    _expect_invalid(
        "num_steps below zero",
        _with(_sim_meta(); simulation = _with(sim(_sim_meta()); num_steps = -1)),
        r"num_steps is -1",
    )
    _expect_invalid(
        "num_steps of zero",
        _with(_sim_meta(); simulation = _with(sim(_sim_meta()); num_steps = 0)),
        r"num_steps is 0",
    )
    # a single document that carries a simulation object, as the schema forbids
    text = read(joinpath(DATA_DIR, "outputs", "single", "outputs.json"), String)
    sim_json = read(joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"), String)
    sim_obj = match(r"(?s)\"simulation\": \{.*?\n  \}", sim_json).match
    path = joinpath(mktempdir(), "outputs.json")
    write(path, replace(text, "\"models\":" => sim_obj * ",\n  \"models\":"; count = 1))
    carrying = IS.read_outputs_metadata(path)
    @test IS.has_simulation(carrying)
    _expect_invalid(
        "single kind with a simulation object",
        carrying,
        r"simulation parameters must be present exactly",
    )
    zero_steps = replace(read(path, String), "\"num_steps\": 7" => "\"num_steps\": 0")
    write(path, zero_steps)
    @test IS.has_simulation(IS.read_outputs_metadata(path))
    _expect_invalid(
        "empty execution_order",
        _with(
            _sim_meta();
            simulation = _with(sim(_sim_meta()); execution_order = String[]),
        ),
        r"execution_order is empty",
    )

    table(m) = outputs_model(m, "UC").tables[1]
    set_table!(m, t) = (outputs_model(m, "UC").tables[1] = t; m)
    t = table(_sim_meta())
    _expect_invalid(
        "negative table length",
        set_table!(_sim_meta(), _with(t; length = -1)),
        r"length is -1",
    )
    _expect_invalid(
        "table without columns",
        set_table!(_sim_meta(), _with(t; columns = IS.OutputColumn[])),
        r"has no columns",
    )
    cols = copy(t.columns)
    cols[1] = _with(cols[1]; name = "")
    _expect_invalid(
        "column with an empty name",
        set_table!(_sim_meta(), _with(t; columns = cols)),
        r"empty name",
    )
    cols = copy(t.columns)
    cols[2] = _with(cols[2]; quantity_kind = "Bogus")
    _expect_invalid(
        "table column quantity_kind",
        set_table!(_sim_meta(), _with(t; columns = cols)),
        r"quantity_kind \"Bogus\"",
    )
    cols = copy(t.columns)
    cols[2] = _with(
        cols[2];
        unit_system = "COMPONENT_BASE",
        base_reference = "device",
        units = "pu",
    )
    _expect_invalid(
        "table column base_reference",
        set_table!(_sim_meta(), _with(t; columns = cols)),
        r"base_reference \"device\"",
    )
end

function _meta_with_text(replacements...)
    text = read(joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"), String)
    path = joinpath(mktempdir(), "outputs.json")
    write(path, replace(text, replacements...))
    return path
end

@testset "read_outputs_metadata: timestamps are naive" begin
    ts = "\"initial_timestamp\": \"2024-01-01T00:00:00\""
    for suffix in ("Z", "+02:00", "-05:00")
        path =
            _meta_with_text(ts => "\"initial_timestamp\": \"2024-01-01T00:00:00$suffix\"")
        @test_throws ArgumentError IS.read_outputs_metadata(path)
        @test_throws r"not naive" IS.read_outputs_metadata(path)
    end
    path = _meta_with_text(
        "\"initial_time\": \"2024-01-01T00:00:00\"" => "\"initial_time\": \"2024-01-01T00:00:00Z\"",
    )
    @test_throws r"not naive" IS.read_outputs_metadata(path)
    path = _meta_with_text(ts => "\"initial_timestamp\": \"2024-01-01T00:00:00.250\"")
    m = IS.read_outputs_metadata(path)
    @test outputs_axis(outputs_model(m, "UC"), "execution").initial_timestamp ==
          DateTime(2024, 1, 1, 0, 0, 0, 250)
end

@testset "ISO duration predicate" begin
    @test IS.is_iso_duration("PT1H") && IS.is_iso_duration("P2DT30M")
    @test IS.is_iso_duration("PT0S")
    for bad in ("", "P", "PT", "P1DT", "1h", "P-1D", "PT1.5H", "P1W", "PT9999999999S")
        @test !IS.is_iso_duration(bad)
        @test_throws ArgumentError IS.parse_iso_duration(bad)
    end
end

@testset "validate_metadata: model, axis, table, and meta names are path segments" begin
    for bad in ("", "a/b")
        m = _sim_meta()
        i = outputs_model_index(m, "EM")
        m.models[i] = _with(m.models[i]; name = bad)
        _expect_invalid("model name \"$bad\"", m, r"model name")
        m = _sim_meta()
        push!(outputs_model(m, "UC").axes, IS.LabelAxis("label", bad, ["x"]))
        _expect_invalid("axis name \"$bad\"", m, r"axis name")
        m = _sim_meta()
        t = outputs_model(m, "UC").tables[1]
        outputs_model(m, "UC").tables[1] = _with(t; name = bad, group = "/UC/tables/$bad")
        _expect_invalid("table name \"$bad\"", m, r"table name")
    end
    m = _sim_meta()
    d = outputs_model(m, "UC").datasets[1]
    outputs_model(m, "UC").datasets[1] = _with(d; meta = "a/b", path = d.path * "__a/b")
    _expect_invalid("meta with a slash", m, r"meta \"a/b\" contains")
end

@testset "outputs metadata: simulation presence follows the document" begin
    sim_text = read(joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"), String)
    single_text = read(joinpath(DATA_DIR, "outputs", "single", "outputs.json"), String)
    path = joinpath(mktempdir(), "outputs.json")
    obj = match(r"(?s)\"simulation\": \{.*?\n  \}", sim_text).match
    # kind single plus any simulation object
    write(path, replace(single_text, "\"models\":" => obj * ",\n  \"models\":"; count = 1))
    m = IS.read_outputs_metadata(path)
    @test IS.has_simulation(m)
    _expect_invalid("single with a simulation object", m, r"must be present exactly")
    # kind simulation without the object
    m = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "simulation", "outputs.json"),
    )
    @test IS.has_simulation(m)
    gone = _with(m; simulation = IS.Simulation.NoSimulation())
    @test !IS.has_simulation(gone)
    _expect_invalid("simulation kind without the object", gone, r"must be present exactly")
    @test_throws ErrorException IS.get_simulation(gone)
    write(path, replace(sim_text, r"(?s)  \"simulation\": \{.*?\n  \},\n" => ""))
    @test !IS.has_simulation(IS.read_outputs_metadata(path))
    # a "present" key is an unknown field
    write(
        path,
        replace(sim_text, "\"num_steps\": 7" => "\"num_steps\": 7, \"present\": false"),
    )
    @test_throws Exception IS.read_outputs_metadata(path)
    # the written JSON has no simulation key for NoSimulation and no present key ever
    @test !occursin("\"simulation\":{", IS.JSON.json(gone))
    @test !occursin("present", IS.JSON.json(m))
end

@testset "validate_metadata: supports_realized_values_post_calculation" begin
    @test outputs_model(_sim_meta(), "UC").supports_realized_values_post_calculation
    @test IS.validate_metadata(_sim_meta()) === nothing

    m = _sim_meta()
    delete_outputs_axis!(outputs_model(m, "UC"), "horizon")
    _expect_invalid(
        "flag without horizon",
        m,
        r"model UC: supports_realized_values_post_calculation requires",
    )

    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "UC"),
        "execution",
        _with(outputs_axis(outputs_model(m, "UC"), "execution"); interval = "PT90M"),
    )
    _expect_invalid("interval not a multiple", m, r"model UC: .*whole multiple")

    m = _sim_meta()
    set_outputs_axis!(
        outputs_model(m, "UC"),
        "execution",
        _with(outputs_axis(outputs_model(m, "UC"), "execution"); interval = "P3D"),
    )
    _expect_invalid("interval above horizon", m, r"model UC: .*at most the horizon")

    m = _sim_meta()
    _set_entry(m, "UC"; supports_realized_values_post_calculation = false)
    delete_outputs_axis!(outputs_model(m, "UC"), "horizon")
    outputs_model(m, "UC").datasets[1] =
        _with(outputs_model(m, "UC").datasets[1]; axes = ["execution"],
            layout = IS.DatasetLayout(
                [1],
                outputs_model(m, "UC").datasets[1].layout.filters,
            ))
    @test !outputs_model(m, "UC").supports_realized_values_post_calculation

    text = read(joinpath(DATA_DIR, "outputs", "single", "outputs.json"), String)
    missing_key = replace(text, r"\n *\"supports_realized_values_post_calculation\": \w+,"
    => "")
    @test missing_key != text
    path = joinpath(mktempdir(), "outputs.json")
    write(path, missing_key)
    @test_throws Exception IS.read_outputs_metadata(path)
end

@testset "validate_metadata: axis names bind to axis kinds" begin
    m = _sim_meta()
    push!(
        outputs_model(m, "UC").axes,
        _with(outputs_axis(outputs_model(m, "EM"), "time"); group = "/UC/axes/time"),
    )
    _expect_invalid(
        "time axis under the realized values flag",
        m,
        r"model UC: supports_realized_values_post_calculation forbids a time axis",
    )

    for (model, key) in (("UC", "time"), ("EM", "execution"), ("EM", "horizon"))
        m = _sim_meta()
        push!(outputs_model(m, model).axes, IS.LabelAxis("label", key, ["x"]))
        _expect_invalid(
            "label axis named $key",
            m,
            Regex("model $model: label axis name \"$key\" is reserved"),
        )
    end
end

@testset "validate_metadata: one field changed in a valid document" begin
    single() = IS.read_outputs_metadata(
        joinpath(DATA_DIR, "outputs", "single", "outputs.json"),
    )
    edit_dataset(m, model, i; kw...) =
        _set_dataset!(m, model, i, _with(outputs_model(m, model).datasets[i]; kw...))

    m = single()
    d = outputs_model(m, "model").datasets[1]
    _expect_invalid(
        "dataset axis that does not exist",
        edit_dataset(m, "model", 1; axes = [d.axes[1], "Nope", d.axes[3]]),
        r"uses axis \"Nope\" absent from the model axes",
    )
    _expect_invalid(
        "dataset without container",
        edit_dataset(single(), "model", 1; container = ""),
        r"container \"\" is not one of",
    )
    _expect_invalid(
        "units other than pu for COMPONENT_BASE",
        edit_dataset(single(), "model", 1; units = "MW"),
        r"COMPONENT_BASE needs a base_reference and units \"pu\"",
    )
    _expect_invalid(
        "COMPONENT_BASE without base_reference",
        edit_dataset(single(), "model", 1; base_reference = ""),
        r"COMPONENT_BASE needs a base_reference",
    )
    _expect_invalid(
        "NATURAL_UNITS with base_reference",
        edit_dataset(single(), "model", 2; base_reference = "system"),
        r"NATURAL_UNITS must not have a base_reference",
    )
    _expect_invalid(
        "meta with double underscore",
        edit_dataset(single(), "model", 1; meta = "a__b"),
        r"meta \"a__b\" contains \"__\"",
    )
    _expect_invalid(
        "float fill for i64",
        edit_dataset(single(), "model", 2; dtype = "i64", fill_value = 1.5),
        r"fill_value .* is not valid for dtype",
    )
    m = single()
    entry = outputs_model(m, "model")
    t = entry.tables[1]
    cols = copy(t.columns)
    cols[2] = _with(cols[2]; quantity_kind = "")
    entry.tables[1] = _with(t; columns = cols)
    _expect_invalid(
        "table column with units and without quantity_kind",
        m,
        r"must be all present or all absent",
    )
    m = single()
    d = outputs_model(m, "model").datasets[1]
    entry = outputs_model(m, "model")
    entry.datasets[1] = _with(d; axes = ["ThermalStandard", "horizon"],
        layout = IS.DatasetLayout([76, 48], d.layout.filters))
    _expect_invalid(
        "horizon without execution",
        m,
        r"has a horizon axis without an execution axis",
    )
    m = single()
    _expect_invalid(
        "kind not in the list",
        IS.OutputsMetadata(
            m.schema_version, "batch", m.producer, m.created_at, m.status, m.systems,
            m.models, m.simulation,
        ),
        r"kind \"batch\" is not one of",
    )
    _expect_invalid(
        "unknown schema version",
        _with(single(); schema_version = "0.2.0"),
        r"schema_version \"0.2.0\"",
    )
    m = _sim_meta()
    _set_entry(m, "EM"; supports_realized_values_post_calculation = true)
    _expect_invalid(
        "realized-values flag on a model without execution and horizon",
        m,
        r"model EM: supports_realized_values_post_calculation requires",
    )
end
