"""
    Optimization

Base types and enums for optimization models. Concrete implementations
are provided by InfrastructureOptimizationModels.jl.
"""
module Optimization

import ..InfrastructureSystems as IS
import ..InfrastructureSystems: @scoped_enum

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                    $(TYPEDSIGNATURES)
                                    $(DOCSTRING)
                                    """

include("enums.jl")
include("optimization_container_types.jl")
include("abstract_model_store_params.jl")
include("abstract_formulations.jl")

# Exports (after includes so types are defined)

# Enums
export ModelBuildStatus

# Abstract types from optimization_container_types.jl
export AbstractOptimizationContainer
export OptimizationKeyType
export VariableType
export ConstraintType
export AuxVariableType
export ParameterType
export InitialConditionType
export ExpressionType
export RightHandSideParameter
export ObjectiveFunctionParameter
export TimeSeriesParameter
export ConstructStage
export ArgumentConstructStage
export ModelConstructStage

# Abstract types from abstract_model_store_params.jl
export AbstractModelStoreParams

# Formulation abstract types from abstract_formulations.jl
export AbstractDeviceFormulation
export AbstractServiceFormulation
export AbstractReservesFormulation
export AbstractThermalFormulation
export AbstractRenewableFormulation
export AbstractStorageFormulation
export AbstractLoadFormulation
export AbstractInfrastructureModel
export AbstractPowerModel
export AbstractActivePowerModel
export AbstractACPModel
export AbstractHVDCNetworkModel

end
