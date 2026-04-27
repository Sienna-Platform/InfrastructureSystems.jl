"""
Supertype for recorder events
"""
abstract type AbstractRecorderEvent end

get_common(event::AbstractRecorderEvent) = event.common
get_name(event::AbstractRecorderEvent) = get_name(get_common(event))
get_timestamp(event::AbstractRecorderEvent) = get_timestamp(get_common(event))

struct RecorderEventCommon
    name::String
    timestamp::Dates.DateTime
end

function RecorderEventCommon(name::AbstractString)
    return RecorderEventCommon(name, Dates.now())
end

get_name(event::RecorderEventCommon) = event.name
get_timestamp(event::RecorderEventCommon) = event.timestamp

function serialize(event::T) where {T <: AbstractRecorderEvent}
    data = Dict{Symbol, Any}()

    for (fieldname, fieldtype) in zip(fieldnames(T), fieldtypes(T))
        if fieldtype <: RecorderEventCommon
            data[:name] = get_name(event)
            data[:timestamp] = get_timestamp(event)
        else
            data[fieldname] = getproperty(event, fieldname)
        end
    end

    return data
end

to_json(event::AbstractRecorderEvent) = JSON.json(serialize(event))
from_json(::Type{T}, text::AbstractString) where {T <: AbstractRecorderEvent} =
    deserialize(T, JSON.parse(text; dicttype = Dict{String, Any}))

function deserialize(::Type{T}, data::Dict) where {T <: AbstractRecorderEvent}
    name = pop!(data, "name")
    timestamp = Dates.DateTime(pop!(data, "timestamp"))
    common = RecorderEventCommon(name, timestamp)
    vals = []

    for (fieldname, fieldtype) in zip(fieldnames(T), fieldtypes(T))
        if fieldtype <: RecorderEventCommon
            push!(vals, common)
        else
            val = fieldtype(data[string(fieldname)])
            push!(vals, val)
        end
    end

    return T(vals...)
end

"""
Records user-defined events in JSON format.
"""
mutable struct Recorder
    name::Symbol
    io::IO
end

"""
Construct a Recorder.

# Arguments

  - `name::Symbol`: name of recorder
  - `io::Union{Nothing, IO}`:  If nothing, record events in a file using name.
  - `mode = "w"`:  Only used when io is nothing.
  - `directory = "."`:  Only used when io is nothing.
"""
function Recorder(
    name::Symbol;
    io::Union{Nothing, IO} = nothing,
    mode = "w",
    directory = ".",
)
    if isnothing(io)
        filename = joinpath(directory, string(name) * ".log")
        io = open(filename, mode)
        @debug "opened recorder log at" _group = LOG_GROUP_RECORDER filename
    end

    return Recorder(name, io)
end

Base.close(mgr::Recorder) = close(mgr.io)
Base.flush(mgr::Recorder) = flush(mgr.io)

g_recorders = Dict{Symbol, Recorder}()

"""
Register a recorder to log events. Afterwards, calls to @record name <event-type>()
will record the event as JSON in <name>.log.

Callers should guarantee that [`unregister_recorder!`](@ref) is called to close the file
handle.

# Arguments

  - `name::Symbol`: name of recorder
  - `io::Union{Nothing, IO}`:  If nothing, record events in a file using name.
  - `mode = "w"`:  Only used when io is nothing.
  - `directory = "."`:  Only used when io is nothing.
"""
function register_recorder!(
    name::Symbol;
    io::Union{Nothing, IO} = nothing,
    mode = "w",
    directory = ".",
)
    unregister_recorder!(name)
    g_recorders[name] = Recorder(name; io = io, mode = mode, directory = directory)
    @debug "registered new Recorder" _group = LOG_GROUP_RECORDER name
end

"""
Unregister the recorder with this name and stop recording events.
"""
function unregister_recorder!(name::Symbol; close_io = true)
    if haskey(g_recorders, name)
        @debug "unregister Recorder" _group = LOG_GROUP_RECORDER name
        recorder = pop!(g_recorders, name)
        close_io && close(recorder)
    end
end

"""
Record an event if the recorder with name is enabled.

# Arguments

  - `name::Symbol`: name of recorder
  - `event::AbstractRecorderEvent`: event to record

# Examples

```Julia
@record simulation TestEvent("start", 1, 2.0)
```
"""
macro record(name, expr)
    return :(!haskey(g_recorders, $name) ? nothing : _record_event($name, $(esc(expr))))
end

function _record_event(name::Symbol, event::AbstractRecorderEvent)
    # Key is not checked. Callers must use @record and not call this directly.
    recorder = g_recorders[name]
    write(recorder.io, JSON.json(serialize(event)))
    return write(recorder.io, "\n")
end

"""
Return the events of type T in filename.

# Arguments

  - `T`: event type
  - `filename::AbstractString`: filename containing recorder events
  - `filter_func::Union{Nothing, Function} = nothing`: Optional function that accepts an event
    of type T and returns a Bool. Apply this function to each event and only return events
    where the result is true.
"""
function list_recorder_events(
    ::Type{T},
    filename::AbstractString,
    filter_func::Union{Nothing, Function} = nothing,
) where {T <: AbstractRecorderEvent}
    events = Vector{T}()
    for line in eachline(filename)
        type_name = "\"" * string(nameof(T)) * "\""
        # Perform a string search for the type to avoid decoding every JSON object.
        if occursin(type_name, line)
            event = from_json(T, line)
            valid = true
            if !isnothing(filter_func)
                valid = filter_func(event)
            end

            if valid
                push!(events, event)
            end
        end
    end

    return events
end

"""
Show the events of type T in filename in a table. Refer to PrettyTables.jl documentation
for accepted kwargs.

# Arguments

  - `T`: event type
  - `filename::AbstractString`: filename containing recorder events
  - `filter_func::Union{Nothing, Function} = nothing`: Optional function that accepts an event
    of type T and returns a Bool. Apply this function to each event and only return events
    where the result is true.
  - `exclude_columns = Set{String}()`: Column names to exclude from the table
  - `kwargs`: Passed to PrettyTables

# Examples

```Julia
show_recorder_events(TestEvent, test_recorder.log)
show_recorder_events(TestEvent, test_recorder.log, x -> x.val2 > 2)
```
"""
function show_recorder_events(
    ::Type{T},
    filename::AbstractString,
    filter_func::Union{Nothing, Function} = nothing;
    kwargs...,
) where {T <: AbstractRecorderEvent}
    return show_recorder_events(stdout, T, filename, filter_func; kwargs...)
end

function show_recorder_events(
    io::IO,
    ::Type{T},
    filename::AbstractString,
    filter_func::Union{Nothing, Function} = nothing;
    kwargs...,
) where {T <: AbstractRecorderEvent}
    events = list_recorder_events(T, filename, filter_func)
    if isempty(events)
        println("no events matched")
        return
    end

    show_recorder_events(io, events; kwargs...)
    return
end
