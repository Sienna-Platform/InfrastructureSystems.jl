# Tests that a Python reader with json + h5py reads the artifact and that the written
# outputs.json satisfies the PowerAnalytics JSON schema.

@testset "outputs python: h5py reads the artifact and the schema validates it" begin
    python = get(
        ENV,
        "SIENNA_PYTHON",
        joinpath(dirname(dirname(@__DIR__)), ".venv", "bin", "python3"),
    )
    schema_dir = get(
        ENV,
        "SIENNA_OUTPUTS_SCHEMA_DIR",
        joinpath(dirname(dirname(@__DIR__)), "PowerAnalytics.jl", "schemas", "outputs"),
    )
    if !isfile(python) || !isdir(schema_dir)
        @warn "Skipping outputs python test: set SIENNA_PYTHON and SIENNA_OUTPUTS_SCHEMA_DIR" python schema_dir
        @test_broken false
    else
        script = joinpath(@__DIR__, "python", "read_outputs.py")
        for kind in ("single", "simulation")
            m = IS.read_outputs_metadata(
                joinpath(DATA_DIR, "outputs", kind, "outputs.json"),
            )
            dir = mktempdir()
            values = Dict()
            if kind == "single"
                values[("model", "ActivePowerVariable", "ThermalStandard", "")] =
                    rand(48, 76, 7)
            end
            IS.write_outputs(
                dir, m; axis_data = simulation_axis_data(m), values = values,
                tables = Dict(),
            )
            out = read(`$python -I $script $dir --schema $schema_dir`, String)
            @test occursin("schema ok", out)
            if kind == "single"
                @test occursin(
                    "model ActivePowerVariable__ThermalStandard (7, 76, 48) (1, 76, 48)",
                    out,
                )
                @test occursin(
                    "model axis ThermalStandard labels (76, 1) ids (76, 1)",
                    out,
                )
            end
        end

        # a document that violates the schema exits with code 3
        m = IS.read_outputs_metadata(
            joinpath(DATA_DIR, "outputs", "single", "outputs.json"),
        )
        dir = mktempdir()
        IS.write_outputs(
            dir, m; axis_data = simulation_axis_data(m), values = Dict(), tables = Dict(),
        )
        path = joinpath(dir, "outputs.json")
        write(path, replace(read(path, String), "\"0.1.0\"" => "\"9.9.9\""))
        proc = run(
            pipeline(ignorestatus(`$python -I $script $dir --schema $schema_dir`);
                stdout = devnull, stderr = devnull),
        )
        @test proc.exitcode == 3
    end
end
