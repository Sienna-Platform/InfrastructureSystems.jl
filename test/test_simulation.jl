const Sim = IS.Simulation

@testset "Simulation enums" begin
    @test Sim.RunStatus.INITIALIZED == Sim.RunStatus.T(-1)
    @test Sim.RunStatus.SUCCESSFULLY_FINALIZED == Sim.RunStatus.T(0)
    @test Sim.SimulationBuildStatus.BUILT == Sim.SimulationBuildStatus.T(0)
    @test Sim.SimulationBuildStatus.EMPTY == Sim.SimulationBuildStatus.T(2)
end

@testset "SimulationInfo" begin
    si = Sim.SimulationInfo()
    @test Sim.get_number(si) === nothing
    @test Sim.get_sequence_uuid(si) === nothing
    @test Sim.get_run_status(si) == Sim.RunStatus.INITIALIZED

    Sim.set_number!(si, 5)
    @test Sim.get_number(si) == 5

    uuid = Base.UUID("12345678-1234-1234-1234-123456789abc")
    Sim.set_sequence_uuid!(si, uuid)
    @test Sim.get_sequence_uuid(si) == uuid

    Sim.set_run_status!(si, Sim.RunStatus.RUNNING)
    @test Sim.get_run_status(si) == Sim.RunStatus.RUNNING
end

@testset "Simulation status enums convert from String" begin
    @test convert(Sim.RunStatus.T, "RUNNING") == Sim.RunStatus.RUNNING
    @test convert(Sim.SimulationBuildStatus.T, "BUILT") == Sim.SimulationBuildStatus.BUILT
end
