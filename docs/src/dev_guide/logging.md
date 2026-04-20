# [Logging](@id log)

`InfrastructureSystems.jl` provides a `MultiLogger` object that allows customized
logging to console and file. Refer to the [logging
documentation](./logging.md).

If you want to create a package-specific log file during a simulation, consider
the workflow used by [PowerSimulations.jl](https://github.com/Sienna-Platform/PowerSimulations.jl). It creates a custom logger in its `build!(Simulation)` function and then uses
Julia's `Logging.with_logger` function to temporarily take over the global logger
during `build()` and `execute()`.

This document describes logging facilities available in the modules that use `InfrastructureSystems.jl`. The examples assume the following imports:

```julia
import Logging
import InfrastructureSystems:
    configure_logging,
    open_file_logger,
    MultiLogger,
    LogEventTracker,
    make_logging_config_file,
    report_log_summary
```

**Note**: Packages that depend on `InfrastructureSystems.jl` already re-export `configure_logging`, `open_file_logger`, `MultiLogger`, `LogEventTracker`

## Use Cases

### Enable logging in REPL or Jupyter Notebook

Use [`InfrastructureSystems.configure_logging`](@ref) to create a logger with your
preferences (console and/or file, levels, etc.).

**Note:** log messages are not automatically flushed to files. Call
`flush(logger)` to make this happen.

**Example**: Global logger configuration

```julia
logger = configure_logging(; filename = "log.txt")
@info "hello world"
flush(logger)
@error "some error"
close(logger)
```

You can also configure logging from a configuration file.

```julia
make_logging_config_file("logging_config.toml")
# Customize in an editor.
logger = configure_logging("logging_config.toml")
```

### Enable debug logging for code you are debugging but not for noisy areas you don't care about.

InfrastructureSystems uses the `_group` field of a log event to perform
additional filtering. All debug log messages that run frequently should have
this field defined.

Note that the default value of `_group` for a log event is its filename. Refer
to the [Julia
docs](https://docs.julialang.org/en/v1/stdlib/Logging/#Log-event-structure) for
more information.

Run this in the REPL to see commonly-used groups in InfrastructureSystems:

```julia
@show InfrastructureSystems.LOG_GROUPS
```

You can tell InfrastructureSystems to filter out messages from a particular
group in two ways:

 1. Specify the group level in the `logging_config.toml` file mentioned above
    and configure logging with it.
 2. Change the logger dynamically from with Julia. Here is an example:

```julia
logger = configure_logging(; console_level = Logging.Debug)
InfrastructureSystems.set_group_level!(
    logger,
    InfrastructureSystems.LOG_GROUP_TIME_SERIES,
    Logging.Info,
)

# Or many at once.
InfrastructureSystems.set_group_levels!(
    logger,
    Dict(
        InfrastructureSystems.LOG_GROUP_SERIALIZATION => Logging.Info,
        InfrastructureSystems.LOG_GROUP_TIME_SERIES => Logging.Info,
    ),
)

# Get current settings
InfrastructureSystems.get_group_levels(logger)
InfrastructureSystems.get_group_level(logger, InfrastructureSystems.LOG_GROUP_TIME_SERIES)
```

### Log to console and file in an application or unit test environment

Create a `MultiLogger` from `TerminalLoggers.TerminalLogger` and `Logging.SimpleLogger`.
Use `open_file_logger` to guarantee that all messages get flushed to the file.

Note that you can use `Logging.ConsoleLogger` if you don't have `TerminalLoggers` installed.

**Example** Multilogger configuration

```julia
console_logger = TerminalLogger(stderr, Logging.Error)

open_file_logger("log.txt", Logging.Info) do file_logger
    multi_logger = MultiLogger([console_logger, file_logger])
    global_logger(multi_logger)

    do_stuff()
end
```

**Note:** If someone may execute the code in the REPL then wrap that code in a
try/finally block and reset the global logger upon exit.

```julia
function run_tests()
    console_logger = TerminalLogger(stderr, Logging.Error)

    open_file_logger("log.txt", Logging.Info) do file_logger
        multi_logger = MultiLogger([console_logger, file_logger])
        global_logger(multi_logger)

        do_stuff()
    end
end

logger = global_logger()

try
    run_tests()
finally
    # Guarantee that the global logger is reset.
    global_logger(logger)
    nothing
end
```

### Suppress frequent messages

The standard Logging module in Julia provides a method to suppress messages.
Tag the log message with maxlog = X.

```julia
for i in range(1; length = 100)
    @error "something happened" i maxlog = 2
end
```

Only 2 messages will get logged.

The InfrastructureSystems logger provides a customization to make `maxlog`
apply to a period of time instead of the duration of the Julia process.

In this example the suppression will timeout and two messages will get logged
every five seconds. It will log how many log messages were suppressed on the
first message that gets logged after a timeout.

```julia
for i in range(1; length = 100)
    @error "something happened" i maxlog = 2 _suppression_period = 5
    sleep(0.5)
end
```

### Get a summary of log messages

By default a `MultiLogger` creates a `LogEventTracker` that keeps counts of all
messages. Call `report_log_summary` after execution.

```julia
logger = configure_logging(; filename = "log.txt")
@info "hello world"

# Include a summary in the log file.
@info report_log_summary(logger)
close(logger)
```

The output of the logger can be explored in the REPL:

```julia
for i in range(1; length = 100)
    @info "hello" maxlog = 2
    @warn "beware" maxlog = 2
end
@info report_log_summary(logger)
```
