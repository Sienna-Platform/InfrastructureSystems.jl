const StructUtils = JSON.StructUtils

"Simulation parameters of an outputs document: `SimulationParams` or `NoSimulation`."
abstract type AbstractSimulation end

"Simulation-wide parameters. Only present when the document `kind` is `simulation`."
JSON.@defaults struct SimulationParams <: AbstractSimulation
    initial_time::Dates.DateTime & (json = (lift = IS._naive_timestamp,),)
    step_resolution::String
    num_steps::Int
    execution_order::Vector{String}
end

"The `simulation` value of a document that omits the simulation object."
struct NoSimulation <: AbstractSimulation end

# Absence in the file is `NoSimulation`; a present object is always `SimulationParams`.
JSON.@choosetype AbstractSimulation x -> SimulationParams
