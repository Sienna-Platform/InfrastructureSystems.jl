"""
    Simulation
"""
module Simulation

import Dates
import ..InfrastructureSystems as IS

import ..InfrastructureSystems:
    @scoped_enum

include("enums.jl")
include("simulation_info.jl")
include("simulation_params.jl")

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

end
