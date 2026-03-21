module InfrastructureSystemsTests

using ReTest
using Logging
using Dates
import TerminalLoggers: TerminalLogger
import TimeSeries
import UUIDs
import JSON3
import HDF5
using DataStructures: SortedDict
using DataFrames
using DataFramesMeta
using Random
using ProgressLogging
import SQLite

import InfrastructureSystems
import InfrastructureSystems as IS

import Aqua
Aqua.test_all(InfrastructureSystems)

const BASE_DIR =
    abspath(joinpath(dirname(Base.find_package("InfrastructureSystems")), ".."))
const DATA_DIR = joinpath(BASE_DIR, "test", "data")
const FORECASTS_DIR = joinpath(DATA_DIR, "time_series")

const LOG_FILE = "infrastructure-systems.log"

include("common.jl")
include("components.jl")
include("events.jl")
include("optimization.jl")

for filename in readdir(joinpath(BASE_DIR, "test"))
    if startswith(filename, "test_") && endswith(filename, ".jl")
        include(filename)
    end
end

function get_logging_level_from_env(env_name::String, default)
    level = get(ENV, env_name, default)
    return IS.get_logging_level(level)
end

function run_tests(args...; kwargs...)
    logger = global_logger()
    try
        logging_config_filename = get(ENV, "SIENNA_LOGGING_CONFIG", nothing)
        if logging_config_filename !== nothing
            config = IS.LoggingConfiguration(logging_config_filename)
        else
            config = IS.LoggingConfiguration(;
                filename = LOG_FILE,
                file_level = get_logging_level_from_env("SIENNA_FILE_LOG_LEVEL", "Info"),
                console_level = get_logging_level_from_env(
                    "SIENNA_CONSOLE_LOG_LEVEL",
                    "Error",
                ),
            )
        end
        console_logger = TerminalLogger(config.console_stream, config.console_level)

        IS.open_file_logger(config.filename, config.file_level) do file_logger
            levels = (Logging.Info, Logging.Warn, Logging.Error)
            multi_logger =
                IS.MultiLogger([console_logger, file_logger], IS.LogEventTracker(levels))
            global_logger(multi_logger)

            if !isempty(config.group_levels)
                IS.set_group_levels!(multi_logger, config.group_levels)
            end

            @time retest(args...; kwargs...)
            @test length(IS.get_log_events(multi_logger.tracker, Logging.Error)) == 0
            @info IS.report_log_summary(multi_logger)
        end
    finally
        # Guarantee that the global logger is reset.
        global_logger(logger)
        nothing
    end
end

export run_tests

end

using .InfrastructureSystemsTests
