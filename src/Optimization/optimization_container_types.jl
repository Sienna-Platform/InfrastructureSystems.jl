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

"""
Return the unit system (`IS.SU`, `IS.CU`, or `IS.NU`) of the values of an output key type.
There is no default: each key type must define it.
"""
function output_unit_system(::Type{T}) where {T <: OptimizationKeyType}
    throw(ArgumentError("No `output_unit_system` method for $T."))
end

"""
Return the `units.json` quantity kind name of the values of an output key type.
There is no default: each key type must define it.
"""
function quantity_kind(::Type{T}) where {T <: OptimizationKeyType}
    throw(ArgumentError("No `quantity_kind` method for $T."))
end

"""
Return the `allowed_units` entry (for example `"rad"`) of an output key type.
Define it only for key types with `output_unit_system` equal to `IS.NU`.
"""
function natural_units(::Type{T}) where {T <: OptimizationKeyType}
    throw(ArgumentError("No `natural_units` method for $T."))
end

"""
Return the name of the output container that stores values of an output key type.
"""
function container_name end

container_name(::Type{<:VariableType}) = "variables"
container_name(::Type{<:AuxVariableType}) = "aux_variables"
container_name(::Type{<:ParameterType}) = "parameters"
container_name(::Type{<:ExpressionType}) = "expressions"
container_name(::Type{<:ConstraintType}) = "duals"
function container_name(::Type{T}) where {T <: InitialConditionType}
    throw(ArgumentError("$T is an initial condition: it has no output container."))
end

abstract type ObjectiveFunctionParameter <: ParameterType end

"Parameter whose values are read from a time series."
abstract type TimeSeriesParameter <: ParameterType end

"""
Optimization Container construction stage
"""
abstract type ConstructStage end

struct ArgumentConstructStage <: ConstructStage end
struct ModelConstructStage <: ConstructStage end
