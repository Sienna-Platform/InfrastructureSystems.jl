# Recorder Events

`InfrastructureSystems.jl` provides a mechanism to store structured data in events
that get recorded in one or more files. They can be filtered and displayed in
tabular form.

The primary use is to store information that can help debug problems and it is largely used in [PowerSimulations.jl](https://github.com/Sienna-Platform/PowerSimulations.jl). For
example, you may want to store all state transitions in a simulation or every
update of a variable.  If a problem occurs you can then display filtered tables
of that data to figure out what went wrong.

## Instructions

 1. Create events that are subtypes of
    [`InfrastructureSystems.AbstractRecorderEvent`](@ref). Include an instance of
    `RecorderEventCommon` in each struct.

 2. Call [`InfrastructureSystems.register_recorder!`](@ref) with arguments `recorder-name` for each recorder object you want to create.
    
      + Depending on how often your code create events you may want to make this
        conditional. You may only need it for debug runs.
      + PowerSimulations creates one recorder for simulation step and stage
        start/stop events that is always enabled. It creates another that is
        optional but used for frequently-generated events.
 3. Call [`@InfrastructureSystems.record`](@ref) with arguments `recorder-name` `event` wherever you want to generate events in your code. The event will only get constructed if the recorder is registered.
 4. Call [`InfrastructureSystems.unregister_recorder!`](@ref) with arguments `recorder-name` for each registered recorder. You should guarantee this gets called, even if an exception is thrown.  Otherwise, the file may not get flushed and closed.
 5. After your code runs call [`InfrastructureSystems.show_recorder_events`](@ref) to
    view events.  Refer to the docstrings for more information.
 6. Refer to
    [`PowerSimulations.show_simulation_events`](https://sienna-platform.github.io/PowerSimulations.jl/latest/api/PowerSimulations/#PowerSimulations.show_simulation_events-Union%7BTuple%7BT%7D,%20Tuple%7BType%7BT%7D,AbstractString%7D,%20Tuple%7BType%7BT%7D,AbstractString,Union%7BNothing,%20Function%7D%7D%7D%20where%20T%3C:InfrastructureSystems.AbstractRecorderEvent)
    for an example on how to customize this behavior for your package.
