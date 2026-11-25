@testset "outputs example: write one model and read it" begin
    IOS = InfrastructureOutputSchemas
    dir = mktempdir()
    system_uuid = "11111111-2222-3333-4444-555555555555"
    bundle = "system-1"

    # 1. Declare the axes of the model.
    time_axis = IOS.TimeAxis(;
        kind = "time", initial_timestamp = "2024-01-01T00:00:00", resolution = "PT1H",
        length = 3, group = "/model/axes/time",
    )
    bus_axis = IOS.ComponentAxis(;
        kind = "component", length = 2, group = "/model/axes/Bus",
        columns = [IOS.ComponentAxisColumnsItem(; component_type = "Bus", has_ids = false)],
    )

    # 2. Declare one dataset. It names its axes in storage order.
    dataset = IOS.Dataset(;
        container = IOS.Container("variables"), entry_type = "PowerInjection",
        component_type = "Bus", meta = "", axes = ["time", "Bus"],
        dtype = IOS.Dtype("f64"), fill_value = "NaN", quantity_kind = "ActivePower",
        unit_system = IOS.UnitSystem("SYSTEM_BASE"), units = "pu",
        layout = IOS.DatasetLayout(; chunks = [3, 2], filters = ["shuffle"]),
        path = "/model/datasets/PowerInjection__Bus",
    )

    # 3. Put the model in a document.
    model = IOS.Model(;
        name = "model", model_type = "emulation", system_uuid = system_uuid,
        base_power = 100.0, supports_realized_values_post_calculation = false,
        settings = IOS.ModelSettings(; additional_properties = Dict{String, Any}()),
        axes = [IOS.Axis(time_axis), IOS.Axis(bus_axis)], datasets = [dataset],
    )
    doc = IOS.OutputsDocument(;
        schema_version = IS.OUTPUTS_SCHEMA_VERSION, kind = "single",
        producer = IOS.ProducerInfo(;
            package = "Example", version = "0.1.0", julia = string(VERSION),
        ),
        created_at = IS.TimeZones.now(IS.TimeZones.TimeZone("UTC")),
        status = IOS.RunStatus("RUNNING"),
        systems = IOS.OutputsDocumentSystems(;
            additional_properties = Dict(system_uuid => bundle),
        ),
        models = [model],
    )

    # 4. Give the data of each time axis and each component axis, by model name and axis name.
    timestamps = [Dates.DateTime(2024, 1, 1) + Dates.Hour(i) for i in 0:2]
    axis_data = Dict(
        ("model", "time") => IS.AxisData(timestamps),
        ("model", "Bus") =>
            IS.AxisData(zeros(Int64, 0, 0), ["bus1" "bus2"], Dates.DateTime[]),
    )

    # 5. Write. The array is in Julia order: the reverse of the dataset axes.
    writer = IS.open_outputs_writer(dir, doc; axis_data = axis_data)
    values = [1.0 2.0 3.0; 4.0 5.0 6.0]
    IS.write_values!(writer, "model", ("PowerInjection", "Bus", ""), values)
    mkpath(joinpath(dir, bundle))  # The package that owns the system writes its bundle here.
    IS.finalize!(writer; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)

    # 6. Read.
    reader = IS.open_outputs_reader(dir)
    read_values, axis_names = IS.read_dataset(reader, "model", "PowerInjection", "Bus")
    @test read_values == values
    @test axis_names == ["Bus", "time"]
    @test IS.read_axis_data(reader, "model", "time").timestamps == timestamps
    @test IS.read_axis_data(reader, "model", "Bus").labels == ["bus1" "bus2"]
    @test string(IS.get_document(reader).status) == "SUCCESSFULLY_FINALIZED"
end
