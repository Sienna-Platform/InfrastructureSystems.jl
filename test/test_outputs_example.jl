struct ExampleFlowVariable <: IS.Optimization.VariableType end
IS.Optimization.output_unit_system(::Type{ExampleFlowVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{ExampleFlowVariable}) = "VolumeFlow"
IS.Optimization.natural_units(::Type{ExampleFlowVariable}) = "m3/s"
struct ExamplePipe end

@testset "outputs example: write one model and read it" begin
    dir = mktempdir()
    system_uuid = "11111111-2222-3333-4444-555555555555"
    bundle = "system-1"

    # 1. Declare the axes of the model.
    time_axis = IS.TimeAxis(Dates.DateTime(2024, 1, 1), Dates.Hour(1), 3)
    pipe_axis = IS.ComponentAxis([IS.ComponentAxisColumn("ExamplePipe", false)], 2)

    # 2. Declare one dataset. It names its axes in storage order.
    dataset = IS.dataset_descriptor(
        ExampleFlowVariable, ExamplePipe, "", IS.OutputAxis[time_axis, pipe_axis],
    )

    # 3. Put the model in a document.
    model = IS.OutputsModel(;
        name = "model", model_type = "emulation", system_uuid = system_uuid,
        base_power = 100.0, supports_realized_values_post_calculation = false,
        settings = Dict{String, Any}(),
        axes = IS.OutputAxis[time_axis, pipe_axis], datasets = [dataset],
    )
    producer = IS.ProducerInfo("Example", "0.1.0", string(VERSION))
    doc = IS.OutputsDocument("single", producer, Dict(system_uuid => bundle), [model])

    # 4. Give the data of each component axis, by model name and axis name.
    axis_data = Dict(
        ("model", IS.axis_name(pipe_axis)) =>
            IS.AxisData(zeros(Int64, 0, 0), ["pipe1" "pipe2"]),
    )

    # 5. Write. The array is in Julia order: the reverse of the dataset axes.
    writer = IS.open_outputs_writer(dir, doc; axis_data = axis_data)
    values = [1.0 2.0 3.0; 4.0 5.0 6.0]
    IS.write_values!(writer, "model", IS.dataset_key(dataset), values)
    mkpath(joinpath(dir, bundle))  # The package that owns the system writes its bundle here.
    IS.finalize!(writer; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)

    # 6. Read.
    reader = IS.open_outputs_reader(dir)
    read_values, axis_names =
        IS.read_dataset(reader, "model", "ExampleFlowVariable", "ExamplePipe")
    @test read_values == values
    @test axis_names == ["ExamplePipe", "time"]
    @test IS.get_timestamps(IS.read_axis_data(reader, "model", "time")) ==
          IS.axis_timestamps(time_axis)
    @test IS.get_labels(IS.read_axis_data(reader, "model", "ExamplePipe")) ==
          ["pipe1" "pipe2"]
    @test IS.get_status(IS.get_document(reader)) ==
          IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED
end
