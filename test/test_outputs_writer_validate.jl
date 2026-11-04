# Tests `src/outputs/validate_components.jl`. Reuses helpers from test_outputs_writer.jl.

function _validate_system(n::Int; renamed = 0)
    data = IS.SystemData()
    for i in 1:n
        name = "name_$i"
        if i == renamed
            name = "other_$i"
        end
        IS.add_component!(data, IS.TestComponent(name, i))
    end
    return data
end

function _validate_axis_data(m, data)
    ad = simulation_axis_data(m)
    for (key, n) in (("ThermalStandard", 76), ("VariableReserve__ThermalStandard", 152))
        ax = ad[("model", key)]
        nc = size(ax.ids, 1)
        comps = [IS.get_component(data, i) for i in 1:n]
        ids = Int64[IS.get_id(c) for _ in 1:nc, c in comps]
        labels = String[IS.get_name(c) for _ in 1:nc, c in comps]
        ad[("model", key)] = IS.AxisData(ids, labels, ax.timestamps)
    end
    return ad
end

@testset "outputs validate: matching System passes, renamed or missing fails" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = _validate_axis_data(m, data),
        values = Dict(("model", _KEY...) => rand(48, 76, 7)), tables = Dict())
    a = IS.open_outputs(dir)
    @test IS.validate_components(a, "model", data) === nothing

    err = try
        IS.validate_components(a, "model", _validate_system(152; renamed = 5))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("model", err.msg) && occursin("axis ThermalStandard", err.msg)
    @test occursin("column 1", err.msg) && occursin("id 5 ", err.msg)
    @test occursin("other_5", err.msg) && occursin("name_5", err.msg)

    err = try
        IS.validate_components(a, "model", _validate_system(100))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("VariableReserve__ThermalStandard", err.msg)
    @test occursin("id 101", err.msg)

    @test_throws ArgumentError IS.validate_components(a, "ZZ", data)
end

@testset "outputs reader: missing ids dataset is an error" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = _validate_axis_data(m, data),
        values = Dict(("model", _KEY...) => rand(48, 76, 7)), tables = Dict())
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r+") do f
        HDF5.delete_object(f, "/model/axes/ThermalStandard/ids")
    end
    a = IS.open_outputs(dir)
    err = try
        IS.read_axis_data(a, "model", "ThermalStandard")
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("model", err.msg) && occursin("ThermalStandard", err.msg)
    @test_throws ArgumentError IS.validate_components(a, "model", data)
end

@testset "outputs validate: ids and labels must have the same size" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = _validate_axis_data(m, data),
        values = Dict(("model", _KEY...) => rand(48, 76, 7)), tables = Dict())
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r+") do f
        HDF5.delete_object(f, "/model/axes/ThermalStandard/ids")
        f["/model/axes/ThermalStandard/ids"] = zeros(Int64, 1, 3)
    end
    a = IS.open_outputs(dir)
    err = try
        IS.validate_components(a, "model", data)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("ids have size (1, 3)", err.msg)
end
