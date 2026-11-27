@testset "outputs types: axis names and lengths" begin
    t0 = DateTime(2024, 1, 1)
    time_axis = IS.TimeAxis(t0, Dates.Hour(1), 3)
    execution = IS.ExecutionAxis(t0, Dates.Day(1), 2)
    horizon = IS.HorizonAxis(Dates.Minute(5), 12)
    one = IS.ComponentAxis([IS.ComponentAxisColumn("ThermalStandard", true)], 4)
    pair = IS.ComponentAxis(
        [IS.ComponentAxisColumn("VariableReserve", true),
            IS.ComponentAxisColumn("ThermalStandard", true)], 5)
    subset = IS.ComponentAxis([IS.ComponentAxisColumn("ACBranch", false)], 6, "monitored")
    label = IS.LabelAxis("winding", ["primary", "secondary"])
    @test IS.axis_name.([time_axis, execution, horizon]) == ["time", "execution", "horizon"]
    @test IS.axis_name(IS.TimeAxis) == "time"
    @test IS.axis_name(IS.ExecutionAxis) == "execution"
    @test IS.axis_name(IS.HorizonAxis) == "horizon"
    @test IS.axis_name(one) == "ThermalStandard"
    @test IS.axis_name(pair) == "VariableReserve__ThermalStandard"
    @test IS.axis_name(subset) == "ACBranch__monitored"
    @test IS.axis_name(label) == "winding"
    @test IS.axis_length.([time_axis, execution, horizon, one, pair, subset, label]) ==
          [3, 2, 12, 4, 5, 6, 2]
    @test time_axis.resolution == Dates.Millisecond(3_600_000)
end

@testset "outputs types: axis rules" begin
    t0 = DateTime(2024, 1, 1)
    time_axis = IS.TimeAxis(t0, Dates.Hour(1), 3)
    execution = IS.ExecutionAxis(t0, Dates.Day(1), 2)
    horizon = IS.HorizonAxis(Dates.Minute(5), 12)
    component = IS.ComponentAxis([IS.ComponentAxisColumn("Bus", false)], 2)
    label = IS.LabelAxis("winding", ["primary"])
    axes = IS.OutputAxis[time_axis, execution, horizon, component, label]
    @test IS.axis_timestamps(time_axis) == [t0, t0 + Dates.Hour(1), t0 + Dates.Hour(2)]
    @test IS.axis_timestamps(execution) == [t0, t0 + Dates.Day(1)]
    @test IS.is_append_axis.(axes) == [false, true, false, false, false]
    @test IS.shrinks_first.(axes) == [true, false, true, false, false]
    @test IS.takes_axis_data.(axes) == [false, false, false, true, false]
    @test IS.get_horizon(horizon) == Dates.Millisecond(3_600_000)
    @test_throws OverflowError IS.get_horizon(
        IS.HorizonAxis(Dates.Millisecond(typemax(Int64)), 2),
    )
    @test IS.axis_group("UC", component) == "/UC/axes/Bus"
end

@testset "outputs types: dataset, column, and document" begin
    dataset = IS.OutputDataset(
        "variables", "FlowVariable", "Pipe", "", ["time", "Pipe"], "f64", "NaN",
        "VolumeFlow", IS.NU, "m3/s", [3, 2], ["shuffle"],
    )
    @test IS.dataset_key(dataset) == ("FlowVariable", "Pipe", "")
    @test IS.dataset_name(dataset) == "FlowVariable__Pipe"
    @test IS.dataset_path("m", dataset) == "/m/datasets/FlowVariable__Pipe"
    @test IS.get_axis_names(dataset) == ["time", "Pipe"]
    plain = IS.OutputColumn("execution", "i64")
    timed = IS.OutputColumn("solve_time", "f64", "Duration", IS.NU, "s")
    @test !IS.has_units(plain)
    @test IS.has_units(timed)
    @test IS.get_units(timed) == "s"
    @test IS.get_unit_system(timed) == IS.NU
    @test_throws ArgumentError IS.get_units(plain)
    table = IS.OutputTable("stats", 2, [plain, timed])
    @test IS.table_group("m", table) == "/m/tables/stats"
    producer = IS.ProducerInfo("Example", "0.1.0", string(VERSION))
    doc = IS.OutputsDocument("single", producer, Dict("u" => "system-1"), IS.OutputsModel[])
    @test doc.schema_version == IS.OUTPUTS_SCHEMA_VERSION
    @test doc.status == IS.Simulation.RunStatus.RUNNING
    @test typeof(doc.simulation) == IS.Simulation.NoSimulation
    params = IS.Simulation.SimulationParams(DateTime(2024, 1, 1), Dates.Day(1), 2, ["UC"])
    with_sim = IS.OutputsDocument("simulation", producer, Dict("u" => "system-1"),
        IS.OutputsModel[], params)
    @test with_sim.simulation.num_steps == 2
end
