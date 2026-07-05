abstract type AbstractOptimizationContainer end

abstract type OptimizationKeyType end
abstract type VariableType <: OptimizationKeyType end
abstract type ConstraintType <: OptimizationKeyType end
abstract type AuxVariableType <: OptimizationKeyType end
abstract type ParameterType <: OptimizationKeyType end
abstract type InitialConditionType <: OptimizationKeyType end
abstract type ExpressionType <: OptimizationKeyType end

convert_output_to_natural_units(::Type{<:VariableType}) = false
convert_output_to_natural_units(::Type{<:ConstraintType}) = false
convert_output_to_natural_units(::Type{<:AuxVariableType}) = false
convert_output_to_natural_units(::Type{<:ExpressionType}) = false
convert_output_to_natural_units(::Type{<:InitialConditionType}) = throw(
    ArgumentError(
        "Initial conditions aren't written to output store: this shouldn't be called.",
    ),
)
convert_output_to_natural_units(::Type{<:ParameterType}) = false

should_write_resulting_value(::Type{<:VariableType}) = true
should_write_resulting_value(::Type{<:ConstraintType}) = true
should_write_resulting_value(::Type{<:AuxVariableType}) = true
should_write_resulting_value(::Type{<:ExpressionType}) = false
should_write_resulting_value(::Type{<:InitialConditionType}) = throw(
    ArgumentError(
        "Initial conditions aren't written to output store: this shouldn't be called.",
    ),
)
# TODO: Piecewise linear parameter are broken to write
should_write_resulting_value(::Type{<:ParameterType}) = false

abstract type RightHandSideParameter <: ParameterType end
abstract type ObjectiveFunctionParameter <: ParameterType end

abstract type TimeSeriesParameter <: RightHandSideParameter end

"""
Optimization Container construction stage
"""
abstract type ConstructStage end

struct ArgumentConstructStage <: ConstructStage end
struct ModelConstructStage <: ConstructStage end
