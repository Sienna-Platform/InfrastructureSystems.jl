# Attribute type that defines an output label, for the success case of validate_components.
struct _LabeledAttribute <: IS.SupplementalAttribute
    name::String
    internal::IS.InfrastructureSystemsInternal
end
IS.get_internal(a::_LabeledAttribute) = a.internal
IS.output_label(a::_LabeledAttribute) = a.name

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
        systems = _bundle_systems(m), values = _all_values(m), tables = _all_tables(m))
    a = IS.open_outputs(dir)
    @test IS.validate_components(a, "model", data) === nothing

    renamed = _validate_system(152; renamed = 5)
    @test_throws ArgumentError IS.validate_components(a, "model", renamed)
    @test_throws r"model.*axis ThermalStandard column 1: id 5 .*other_5.*name_5" IS.validate_components(
        a, "model", renamed)

    short = _validate_system(100)
    @test_throws ArgumentError IS.validate_components(a, "model", short)
    @test_throws r"VariableReserve__ThermalStandard column \d: id 101 " IS.validate_components(
        a, "model", short)

    @test_throws ArgumentError IS.validate_components(a, "ZZ", data)
end

@testset "outputs reader: missing ids dataset is an error" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = _validate_axis_data(m, data),
        systems = _bundle_systems(m), values = _all_values(m), tables = _all_tables(m))
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r+") do f
        HDF5.delete_object(f, "/model/axes/ThermalStandard/ids")
    end
    a = IS.open_outputs(dir)
    @test_throws ArgumentError IS.read_axis_data(a, "model", "ThermalStandard")
    @test_throws r"model.*ThermalStandard" IS.read_axis_data(a, "model", "ThermalStandard")
    @test_throws ArgumentError IS.validate_components(a, "model", data)
end

@testset "outputs validate: ids and labels must have the same size" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = _validate_axis_data(m, data),
        systems = _bundle_systems(m), values = _all_values(m), tables = _all_tables(m))
    HDF5.h5open(joinpath(dir, "outputs.h5"), "r+") do f
        HDF5.delete_object(f, "/model/axes/ThermalStandard/ids")
        f["/model/axes/ThermalStandard/ids"] = zeros(Int64, 1, 3)
    end
    a = IS.open_outputs(dir)
    @test_throws ArgumentError IS.validate_components(a, "model", data)
    @test_throws "ids have size (1, 3)" IS.validate_components(a, "model", data)
end

@testset "outputs validate: ids resolve to supplemental attributes" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    comp = IS.get_component(data, 1)
    attr = IS.GeographicInfo()
    IS.add_supplemental_attribute!(data, comp, attr)
    @test !iszero(IS.get_id(attr))
    ad = _validate_axis_data(m, data)
    t = ad[("model", "ThermalStandard")]
    ids = copy(t.ids)
    ids[1, 2] = IS.get_id(attr)
    ad[("model", "ThermalStandard")] = IS.AxisData(ids, t.labels, t.timestamps)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, systems = _bundle_systems(m),
        values = _all_values(m), tables = _all_tables(m))
    a = IS.open_outputs(dir)
    # the id resolves to the attribute; IS has no label rule for its type
    @test_throws "GeographicInfo has no output label" IS.validate_components(
        a, "model", data)
    # an id of neither kind
    ids[1, 2] = 100_000
    ad[("model", "ThermalStandard")] = IS.AxisData(ids, t.labels, t.timestamps)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, systems = _bundle_systems(m),
        values = _all_values(m), tables = _all_tables(m))
    @test_throws "id 100000 is neither a component nor a supplemental attribute" IS.validate_components(
        IS.open_outputs(dir), "model", data)
end

@testset "outputs validate: an attribute type with an output label validates" begin
    m = IS.read_outputs_metadata(_SINGLE_JSON)
    data = _validate_system(152)
    attr = _LabeledAttribute("outage_1", IS.InfrastructureSystemsInternal())
    IS.add_supplemental_attribute!(data, IS.get_component(data, 1), attr)
    ad = _validate_axis_data(m, data)
    t = ad[("model", "ThermalStandard")]
    ids = copy(t.ids)
    labels = copy(t.labels)
    ids[1, 2] = IS.get_id(attr)
    labels[1, 2] = "outage_1"
    ad[("model", "ThermalStandard")] = IS.AxisData(ids, labels, t.timestamps)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, systems = _bundle_systems(m),
        values = _all_values(m), tables = _all_tables(m))
    a = IS.open_outputs(dir)
    @test IS.validate_components(a, "model", data) === nothing
    labels[1, 2] = "wrong"
    ad[("model", "ThermalStandard")] = IS.AxisData(ids, labels, t.timestamps)
    dir = mktempdir()
    IS.write_outputs(dir, m; axis_data = ad, systems = _bundle_systems(m),
        values = _all_values(m), tables = _all_tables(m))
    @test_throws "is named outage_1 in the System, label is wrong" IS.validate_components(
        IS.open_outputs(dir), "model", data)
end
