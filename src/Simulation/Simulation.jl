"""
    Simulation
"""
module Simulation

import ..InfrastructureSystems as IS

import ..InfrastructureSystems:
    @scoped_enum

import Dates
import JSON

include("enums.jl")
include("simulation_info.jl")
include("simulation_params.jl")

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

end
