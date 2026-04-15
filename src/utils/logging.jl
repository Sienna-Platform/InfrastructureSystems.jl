# These use PascalCase to avoid clashing with source filenames.
const LOG_GROUP_PARSING = :Parsing
const LOG_GROUP_RECORDER = :Recorder
const LOG_GROUP_SERIALIZATION = :Serialization
const LOG_GROUP_SUPPLEMENTAL_ATTRIBUTES = :SupplementalAttributes
const LOG_GROUP_SYSTEM = :System
const LOG_GROUP_SYSTEM_CHECKS = :SystemChecks
const LOG_GROUP_TIME_SERIES = :TimeSeries

# Try to keep this updated so that users can check the known groups in the REPL.
const LOG_GROUPS = (
    LOG_GROUP_PARSING,
    LOG_GROUP_RECORDER,
    LOG_GROUP_SERIALIZATION,
    LOG_GROUP_SYSTEM,
    LOG_GROUP_TIME_SERIES,
)
const SIENNA_LOGGING_CONFIG_FILENAME =
    joinpath(dirname(pathof(InfrastructureSystems)), "utils", "logging_config.toml")

const LOG_LEVELS = Dict(
    "Debug" => Logging.Debug,
    "Progress" => ProgressLevel,
    "Info" => Logging.Info,
    "Warn" => Logging.Warn,
    "Error" => Logging.Error,
)

"""
Contains information describing a log event.
"""
mutable struct LogEvent
    file::String
    line::Int
    id::Symbol
    message::String
    level::Logging.LogLevel
    count::Int
    suppressed::Int
end

function LogEvent(file, line, id, message, level)
    if isnothing(file)
        file = "None"
    end

    return LogEvent(file, line, id, message, level, 1, 0)
end

struct LogEventTracker
    events::Dict{Logging.LogLevel, Dict{Symbol, LogEvent}}

    # Defining an inner constructor to prohibit creation of a default constructor that
    # takes a parameter of type Any. The outer constructor below causes an overwrite of
    # that method, which results in a warning message from Julia.
    LogEventTracker(events::Dict{Logging.LogLevel, Dict{Symbol, LogEvent}}) = new(events)
end

"""
Returns a summary of log event counts by level.
"""
function report_log_summary(tracker::LogEventTracker)
    text = "\nLog message summary:\n"
    # Order by criticality.
    for level in sort!(collect(keys(tracker.events)); rev = true)
        num_events = length(tracker.events[level])
        text *= "\n$num_events $level events:\n"
        for event in
            sort!(collect(get_log_events(tracker, level)); by = x -> x.count, rev = true)
            text *= "  count=$(event.count) at $(event.file):$(event.line)\n"
            text *= "    example message=\"$(event.message)\"\n"
            if event.suppressed > 0
                text *= "    suppressed=$(event.suppressed)\n"
            end
        end
    end

    return text
end

"""
Returns an iterable of log events for a level.
"""
function get_log_events(tracker::LogEventTracker, level::Logging.LogLevel)
    if !_is_level_valid(tracker, level)
        return []
    end

    return values(tracker.events[level])
end

"""
Increments the count of a log event.
"""
function increment_count!(tracker::LogEventTracker, event::LogEvent, suppressed::Bool)
    if _is_level_valid(tracker, event.level)
        if haskey(tracker.events[event.level], event.id)
            tracker.events[event.level][event.id].count += 1
            if suppressed
                tracker.events[event.level][event.id].suppressed += 1
            end
        else
            tracker.events[event.level][event.id] = event
        end
    end
end

function _is_level_valid(tracker::LogEventTracker, level::Logging.LogLevel)
    return level in keys(tracker.events)
end

@kwdef struct LoggingConfiguration
    console::Bool = true
    console_stream::IO = stderr
    console_level::Base.LogLevel = Logging.Error
    progress::Bool = true
    file::Bool = true
    filename::Union{Nothing, String} = "log.txt"
    file_level::Base.LogLevel = Logging.Info
    file_mode::String = "w+"
    tracker::Union{Nothing, LogEventTracker} = nothing
    set_global::Bool = true
    group_levels::Dict{Symbol, Base.LogLevel} = Dict()
end

function LoggingConfiguration(config_filename)
    config = open(config_filename, "r") do io
        return TOML.parse(io)
    end

    console_stream_str = get(config, "console_stream", "stderr")
    if console_stream_str == "stderr"
        config["console_stream"] = stderr
    elseif console_stream_str == "stdout"
        config["console_stream"] = stdout
    else
        error("unsupport console_stream value: {console_stream_str")
    end

    config["console_level"] = get_logging_level(get(config, "console_level", "Info"))
    config["file_level"] = get_logging_level(get(config, "file_level", "Info"))
    config["group_levels"] =
        Dict(Symbol(k) => get_logging_level(v) for (k, v) in config["group_levels"])
    config["tracker"] = nothing
    return LoggingConfiguration(; Dict(Symbol(k) => v for (k, v) in config)...)
end

"""
Create a logging configuration file from the default template.

Pass `force = true` to overwrite an existing file.
"""
function make_logging_config_file(filename = "logging_config.toml"; force = false)
    cp(SIENNA_LOGGING_CONFIG_FILENAME, filename; force = force)
    println("Created $filename")
    return
end

"""
Tracks counts of all log events by level.

# Examples

```Julia
LogEventTracker()
LogEventTracker((Logging.Info, Logging.Warn, Logging.Error))
```
"""
function LogEventTracker(levels = (Logging.Info, Logging.Warn, Logging.Error))
    return LogEventTracker(Dict(l => Dict{Symbol, LogEvent}() for l in levels))
end

"""
Creates console and file loggers per caller specification and returns a MultiLogger.

Suppress noisy events by specifying per-event values of `maxlog = X` and
`_suppression_period = Y` where X is the max number of events that can occur in Y
seconds. After the period ends, messages will no longer be suppressed. Note that
if you don't specify `_suppression_period` then `maxlog` applies for the for the
duration of your process (standard Julia logging behavior).

**Note:** Use of log message suppression and the LogEventTracker are not thread-safe.
Please contact the package developers if you need this functionality.

**Note:** If logging to a file users must call Base.close() on the returned MultiLogger to
ensure that all events get flushed.

# Arguments

  - `console::Bool=true`: create console logger
  - `console_stream::IOStream=stderr`: stream for console logger
  - `console_level::Logging.LogLevel=Logging.Error`: level for console messages
  - `progress::Bool=true`: enable progress logger
  - `file::Bool=true`: create file logger
  - `filename::Union{Nothing, String}=log.txt`: log file
  - `file_level::Logging.LogLevel=Logging.Info`: level for file messages
  - `file_mode::String=w+`: mode used when opening log file
  - `tracker::Union{LogEventTracker, Nothing}=LogEventTracker()`: optionally track log events
  - `set_global::Bool=true`: set the created logger as the global logger

# Example

```Julia
logger = configure_logging(filename="mylog.txt")
@info "hello world"
@info "hello world" maxlog = 5 _suppression_period = 10
```
"""
function configure_logging(;
    console = true,
    console_stream = stderr,
    console_level = Logging.Error,
    progress = true,
    file = true,
    filename = "log.txt",
    file_level = Logging.Info,
    file_mode = "w+",
    tracker = LogEventTracker(),
    set_global = true,
)
    config = LoggingConfiguration(;
        console = console,
        console_stream = console_stream,
        console_level = console_level,
        progress = progress,
        file = file,
        filename = filename,
        file_level = file_level,
        file_mode = file_mode,
        tracker = tracker,
        set_global = set_global,
    )
    return configure_logging(config)
end

function configure_logging(config_filename::AbstractString)
    return configure_logging(LoggingConfiguration(config_filename))
end

function configure_logging(config::LoggingConfiguration)
    if !config.console && !config.file && !config.progress
        error("At least one of console, file, or progress must be true")
    end

    loggers = Vector{Logging.AbstractLogger}()
    if config.console
        # We could use TerminalLogger here but it renders messages as Markdown, and that
        # can cause unexpected results, particularly with variable names and underscores.
        console_logger = Logging.ConsoleLogger(config.console_stream, config.console_level)
        push!(loggers, console_logger)
    end

    if config.progress
        progress_logger = ProgressLogger(config.console_stream, ProgressLevel)
        push!(loggers, progress_logger)
    end

    if config.file
        io = open(config.filename, config.file_mode)
        file_logger = FileLogger(io, config.file_level)
        push!(loggers, file_logger)
    end

    logger = MultiLogger(
        loggers,
        config.tracker,
        Dict{Symbol, Base.LogLevel}(),
        LogSuppressionTracker(),
    )
    if config.set_global
        Logging.global_logger(logger)
    end

    return logger
end

"""
Specializes the behavior of SimpleLogger by adding timestamps and process and thread IDs.
"""
struct FileLogger <: Logging.AbstractLogger
    logger::Logging.SimpleLogger
end

function FileLogger(stream::IO, level::Base.CoreLogging.LogLevel)
    return FileLogger(Logging.SimpleLogger(stream, level))
end

function Logging.handle_message(
    file_logger::FileLogger,
    level,
    message,
    _module,
    group,
    id,
    file,
    line;
    maxlog = nothing,
    kwargs...,
)
    return Logging.handle_message(
        file_logger.logger,
        level,
        "$(Dates.now()) [$(getpid()):$(Base.Threads.threadid())]: $message",
        _module,
        group,
        id,
        file,
        line;
        maxlog = maxlog,
        kwargs...,
    )
end

function Logging.shouldlog(logger::FileLogger, level, _module, group, id)
    level == ProgressLevel && return false
    return Logging.shouldlog(logger.logger, level, _module, group, id)
end

Logging.min_enabled_level(logger::FileLogger) = Logging.min_enabled_level(logger.logger)
Logging.catch_exceptions(logger::FileLogger) = false
Base.flush(logger::FileLogger) = flush(logger.logger.stream)
Base.close(logger::FileLogger) = close(logger.logger.stream)

"""
Opens a file logger using `Logging.SimpleLogger`.

# Arguments
  - `func::Function`
  - `filename::String`: logger filename
  - `level=Logging.Info`: optional, to change the minimum logging level
  - `mode = "w+"`: Optional, to designate write mode

# Example

```Julia
open_file_logger("log.txt", Logging.Info) do logger
    global_logger(logger)
    @info "hello world"
end
```
"""
function open_file_logger(
    func::Function,
    filename::String,
    level = Logging.Info,
    mode = "w+",
)
    stream = open(filename, mode)
    try
        logger = FileLogger(stream, level)
        func(logger)
    finally
        close(stream)
    end
end

mutable struct LogEventSuppressionStats
    "The event being tracked"
    event_id::Symbol
    "The time we started tracking an event."
    tracking_start_time::Float64
    "Number of times an event has occurred since tracking started."
    count::Int
    "Length in seconds of one tracking period"
    period::Int
    "Number of times an event has been suppressed since tracking started."
    num_suppressed::Int
    "Whether tracking is active"
    is_tracking_active::Bool
    "Whether the event is being suppressed"
    is_suppression_enabled::Bool
end

function LogEventSuppressionStats(event_id::Symbol, cur_time::Float64, period::Int)
    return LogEventSuppressionStats(event_id, cur_time, 0, period, 0, false, false)
end

function start_tracking!(stats::LogEventSuppressionStats, cur_time::Float64)
    stats.is_tracking_active = true
    stats.tracking_start_time = cur_time
    stats.count = 1
    stats.is_suppression_enabled = false
    stats.num_suppressed = 0
    return
end

function increment!(stats::LogEventSuppressionStats, maxlog::Int)
    @assert stats.is_tracking_active
    stats.count += 1
    if stats.count > maxlog
        if !stats.is_suppression_enabled
            stats.is_suppression_enabled = true
        end
        stats.num_suppressed += 1
    end
    return
end

function should_suppress!(stats::LogEventSuppressionStats, cur_time::Float64, maxlog::Int)
    diff = cur_time - stats.tracking_start_time
    num_suppressed = 0
    if !stats.is_tracking_active
        start_tracking!(stats, cur_time)
    elseif cur_time - stats.tracking_start_time < stats.period
        increment!(stats, maxlog)
        num_suppressed = stats.num_suppressed
    else
        # The suppression period has ended.
        num_suppressed = stats.num_suppressed
        start_tracking!(stats, cur_time)
    end

    return stats.is_suppression_enabled, num_suppressed
end

struct LogSuppressionTracker
    event_stats::Dict{Symbol, LogEventSuppressionStats}
end

function LogSuppressionTracker()
    return LogSuppressionTracker(Dict{Symbol, LogEventSuppressionStats}())
end

should_suppress!(tracker::LogSuppressionTracker, ::Any, ::Any, ::Nothing) = false, 0

function should_suppress!(
    tracker::LogSuppressionTracker,
    event_id::Symbol,
    maxlog::Int,
    suppression_period::Int,
)
    cur_time = time()
    stats = get!(
        tracker.event_stats,
        event_id,
        LogEventSuppressionStats(event_id, cur_time, suppression_period),
    )
    return should_suppress!(stats, cur_time, maxlog)
end

"""
Redirects log events to multiple loggers. The primary use case is to allow logging to
both a file and the console. Secondarily, it can track the counts of all log messages.

# Example

```Julia
MultiLogger([TerminalLogger(stderr), SimpleLogger(stream)], LogEventTracker())
```
"""
mutable struct MultiLogger <: Logging.AbstractLogger
    loggers::Array{Logging.AbstractLogger}
    tracker::Union{LogEventTracker, Nothing}
    group_levels::Dict{Symbol, Base.LogLevel}
    suppression_tracker::LogSuppressionTracker
end

"""
Creates a MultiLogger with no event tracking.

# Example

```Julia
MultiLogger([TerminalLogger(stderr), SimpleLogger(stream)])
```
"""
function MultiLogger(loggers::Array{T}) where {T <: Logging.AbstractLogger}
    return MultiLogger(
        loggers,
        nothing,
        Dict{Symbol, Base.LogLevel}(),
        LogSuppressionTracker(),
    )
end

function MultiLogger(
    loggers::Array{T},
    tracker::LogEventTracker,
) where {T <: Logging.AbstractLogger}
    return MultiLogger(
        loggers,
        tracker,
        Dict{Symbol, Base.LogLevel}(),
        LogSuppressionTracker(),
    )
end

function Logging.shouldlog(logger::MultiLogger, level, _module, group, id)
    return get(logger.group_levels, group, level) <= level
end

function Logging.min_enabled_level(logger::MultiLogger)
    return minimum([Logging.min_enabled_level(x) for x in logger.loggers])
end

Logging.catch_exceptions(logger::MultiLogger) = false

function Logging.handle_message(
    logger::MultiLogger,
    level::Int,
    message,
    _module,
    group,
    id,
    file,
    line;
    kwargs...,
)
    return Logging.handle_message(
        logger::MultiLogger,
        Logging.LogLevel(level),
        message,
        _module,
        group,
        id,
        file,
        line;
        kwargs...,
    )
end

function Logging.handle_message(
    logger::MultiLogger,
    level::Logging.LogLevel,
    message,
    _module,
    group,
    id,
    file,
    line;
    maxlog = nothing,
    _suppression_period = nothing,
    kwargs...,
)
    suppressed, num_suppressed =
        should_suppress!(logger.suppression_tracker, id, maxlog, _suppression_period)
    if !suppressed
        # Takeover maxlog if suppression_period is set.
        maxlog = _suppression_period === nothing ? maxlog : nothing
        for _logger in logger.loggers
            if level >= Logging.min_enabled_level(_logger)
                if Logging.shouldlog(_logger, level, _module, group, id)
                    if num_suppressed > 0
                        kwargs =
                            merge(Dict(kwargs), Dict(:num_suppressed => num_suppressed))
                    end
                    # Without this line, the ConsoleLogger would log progress messages if
                    # its min_enabled_level was debug.
                    level == ProgressLevel && !isa(_logger, ProgressLogger) && continue
                    Logging.handle_message(
                        _logger,
                        level,
                        message,
                        _module,
                        group,
                        id,
                        file,
                        line;
                        maxlog = maxlog,
                        kwargs...,
                    )
                end
            end
        end
    end

    if !isnothing(logger.tracker)
        id = isa(id, Symbol) ? id : :empty
        event = LogEvent(file, line, id, string(message), level)
        increment_count!(logger.tracker, event, suppressed)
    end

    return
end

"""
Empty the minimum log levels stored for each group.
"""
function empty_group_levels!(logger::MultiLogger)
    empty!(logger.group_levels)
    return
end

"""
Set the minimum log level for a group.

The `group` field of a log message defaults to its file's base name (no extension) as a
symbol. It can be customized by setting `_group = :a_group_name`.

The minimum log level stored for a console or file logger supercede this setting.
"""
function set_group_level!(logger::MultiLogger, group::Symbol, level::Base.LogLevel)
    logger.group_levels[group] = level
    return
end

"""
Set the minimum log levels for multiple groups. Refer to [`set_group_level!`](@ref) for more
information.
"""
function set_group_levels!(logger::MultiLogger, group_levels::Dict{Symbol, Base.LogLevel})
    merge!(logger.group_levels, group_levels)
    return
end

"""
Return the minimum logging level for a group or nothing if `group` is not stored.
"""
get_group_level(logger::MultiLogger, group::Symbol) =
    get(logger.group_levels, group, nothing)

"""
Return the minimum logging levels for groups that have been stored.
"""
get_group_levels(logger::MultiLogger) = deepcopy(logger.group_levels)

"""
Returns a summary of log event counts by level.
"""
function report_log_summary(logger::MultiLogger)
    if isnothing(logger.tracker)
        error("log event tracking is not enabled")
    end

    return report_log_summary(logger.tracker)
end

"""
Flush any file streams.
"""
function Base.flush(logger::MultiLogger)
    return _handle_log_func(logger, Base.flush)
end

"""
Ensures that any file streams are flushed and closed.
"""
function Base.close(logger::MultiLogger)
    return _handle_log_func(logger, Base.close)
end

function get_logging_level(level::String)
    if !haskey(LOG_LEVELS, level)
        error("Invalid log level $level: Supported levels: $(values(LOG_LEVELS))")
    end

    return LOG_LEVELS[level]
end

function _handle_log_func(logger::MultiLogger, func::Function)
    for _logger in logger.loggers
        if isa(_logger, Logging.SimpleLogger)
            func(_logger.stream)
        elseif isa(_logger, FileLogger)
            func(_logger)
        end
    end
end

mutable struct ProgressLogger <: Logging.AbstractLogger
    logger::TerminalLogger
end

ProgressLogger(args...) = ProgressLogger(TerminalLogger(args...))

function Logging.shouldlog(logger::ProgressLogger, level, _module, group, id)
    return level == ProgressLevel
end

Logging.min_enabled_level(x::ProgressLogger) = Logging.min_enabled_level(x.logger)
Logging.catch_exceptions(x::ProgressLogger) = Logging.catch_exceptions(x.logger)

function Logging.handle_message(x::ProgressLogger, args...; kwargs...)
    Logging.handle_message(x.logger, args...; kwargs...)
end
