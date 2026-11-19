# Tests that a Python reader with json + h5py reads the artifact. The tests error, never
# skip, when python or h5py is missing: set SIENNA_PYTHON to a python3 that has h5py.

function _outputs_python()
    python = get(
        ENV,
        "SIENNA_PYTHON",
        joinpath(dirname(dirname(@__DIR__)), ".venv", "bin", "python3"),
    )
    if !isfile(python)
        error(
            "outputs python tests need a python3 with h5py: $python does not exist. Set SIENNA_PYTHON.",
        )
    end
    ok =
        success(pipeline(`$python -I -c "import h5py"`; stdout = devnull, stderr = devnull))
    if !ok
        error(
            "outputs python tests need the python package h5py: $python cannot import it.",
        )
    end
    return python
end

@testset "outputs python: h5py reads the artifact" begin
    python = _outputs_python()
    script = joinpath(@__DIR__, "python", "read_outputs.py")
    for kind in ("single", "simulation", "power_flow", "security_analysis")
        m = IS.read_outputs_metadata(outputs_fixture(kind))
        if kind == "single"
            m = _single_meta()
        end
        dir = mktempdir()
        values = _all_values(m)
        # Each value encodes its Julia index, so a reader sees where it sits.
        sentinel = [i + 100j + 10_000k for i in 1:48, j in 1:76, k in 1:7]
        if kind == "single"
            values[("model", "ActivePowerVariable", "ThermalStandard", "")] = sentinel
        end
        IS.write_outputs(
            dir, m; axis_data = simulation_axis_data(m), values = values,
            tables = _all_tables(m), systems = _bundle_systems(m),
        )
        path = "/model/datasets/ActivePowerVariable__ThermalStandard"
        points = ((1, 1, 1), (5, 10, 3), (48, 76, 7))
        point_args = String[]
        if kind == "single"
            for p in points
                push!(point_args, path, join(reverse(p) .- 1, ","))
            end
        end
        out = read(`$python -I $script $dir $point_args`, String)
        if kind == "single"
            @test occursin(
                "model ActivePowerVariable__ThermalStandard (7, 76, 48) (1, 76, 48)",
                out,
            )
            @test occursin("model axis ThermalStandard labels (76, 1) ids (76, 1)", out)
            for p in points
                index = join(reverse(p) .- 1, ",")
                @test occursin("value $path $index $(float(sentinel[p...]))", out)
            end
        end
    end
end
