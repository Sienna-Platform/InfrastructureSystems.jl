"""
Supertype of the simulation field of an outputs document.
"""
abstract type AbstractSimulation end

"""
Parameters of a simulation that produced an outputs document.
"""
struct SimulationParams <: AbstractSimulation
    initial_time::Dates.DateTime
    step_resolution::Dates.Millisecond
    num_steps::Int
    execution_order::Vector{String}
end

"""
Marker for an outputs document that has no simulation.
"""
struct NoSimulation <: AbstractSimulation end
