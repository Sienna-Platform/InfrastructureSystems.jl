# Tests that a Python reader with json + h5py reads the artifact and that the written
# outputs.json satisfies the PowerAnalytics JSON schema, using the vendored schema copy.
# The tests error, never skip, when python, h5py, or jsonschema is missing: set
# SIENNA_PYTHON to a python3 that has h5py and jsonschema.

const _SCHEMA_DIR = joinpath(DATA_DIR, "outputs", "schema")

function _outputs_python()
    python = get(
        ENV,
        "SIENNA_PYTHON",
        joinpath(dirname(dirname(@__DIR__)), ".venv", "bin", "python3"),
    )
    if !isfile(python)
        error(
            "outputs python tests need a python3 with h5py and jsonschema: $python does not exist. Set SIENNA_PYTHON.",
        )
    end
    for pkg in ("h5py", "jsonschema", "referencing")
        ok = success(
            pipeline(`$python -I -c "import $pkg"`; stdout = devnull, stderr = devnull),
        )
        if !ok
            error(
                "outputs python tests need the python package $pkg: $python cannot import it.",
            )
        end
    end
    return python
end

@testset "outputs python: h5py reads the artifact and the schema validates it" begin
    python = _outputs_python()
    script = joinpath(@__DIR__, "python", "read_outputs.py")
    for kind in ("single", "simulation", "power_flow", "security_analysis")
        m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", kind, "outputs.json"))
        dir = mktempdir()
        values = _all_values(m)
        if kind == "single"
            values[("model", "ActivePowerVariable", "ThermalStandard", "")] =
                rand(48, 76, 7)
        end
        IS.write_outputs(
            dir, m; axis_data = simulation_axis_data(m), values = values,
            tables = _all_tables(m), systems = _bundle_systems(m),
        )
        out = read(`$python -I $script $dir --schema $_SCHEMA_DIR`, String)
        @test occursin("schema ok", out)
        if kind == "single"
            @test occursin(
                "model ActivePowerVariable__ThermalStandard (7, 76, 48) (1, 76, 48)",
                out,
            )
            @test occursin("model axis ThermalStandard labels (76, 1) ids (76, 1)", out)
        end
    end

    # a document that violates the schema exits with code 3
    m = IS.read_outputs_metadata(joinpath(DATA_DIR, "outputs", "single", "outputs.json"))
    dir = mktempdir()
    IS.write_outputs(
        dir, m; axis_data = simulation_axis_data(m), values = _all_values(m),
        tables = _all_tables(m),
    )
    path = joinpath(dir, "outputs.json")
    write(path, replace(read(path, String), "\"0.1.0\"" => "\"9.9.9\""))
    proc = run(
        pipeline(ignorestatus(`$python -I $script $dir --schema $_SCHEMA_DIR`);
            stdout = devnull, stderr = devnull),
    )
    @test proc.exitcode == 3
end
