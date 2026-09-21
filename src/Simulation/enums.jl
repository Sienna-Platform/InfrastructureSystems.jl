@scoped_enum(
    RunStatus,
    NOT_READY = -2,
    INITIALIZED = -1,
    SUCCESSFULLY_FINALIZED = 0,
    RUNNING = 1,
    FAILED = 2,
)

@scoped_enum(SimulationBuildStatus, IN_PROGRESS = -1, BUILT = 0, FAILED = 1, EMPTY = 2,)

Base.convert(::Type{SimulationBuildStatus.Value}, val::String) =
    SimulationBuildStatus.Value(val)
Base.convert(::Type{RunStatus.Value}, val::String) = RunStatus.Value(val)
