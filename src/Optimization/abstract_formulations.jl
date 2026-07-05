#################################################################################
# Formulation abstract types
# Concrete implementations are defined in downstream packages (e.g., PowerOperationsModels)
#################################################################################

"""
Abstract type for Device Formulations (a.k.a Models).
Subtypes define how a particular device type is represented in the optimization problem.
"""
abstract type AbstractDeviceFormulation end

"""
Abstract type for Service Formulations.
Subtypes define how services (reserves, AGC, etc.) are represented in the optimization problem.
"""
abstract type AbstractServiceFormulation end

"""
Abstract type for Reserves Formulations.
Subtypes define how reserve services are modeled in the optimization problem.
"""
abstract type AbstractReservesFormulation <: AbstractServiceFormulation end

# Device-specific formulation abstract types

"""
Abstract type for Thermal Generator Formulations.
"""
abstract type AbstractThermalFormulation <: AbstractDeviceFormulation end

"""
Abstract type for Renewable Generator Formulations.
"""
abstract type AbstractRenewableFormulation <: AbstractDeviceFormulation end

"""
Abstract type for Storage Formulations.
"""
abstract type AbstractStorageFormulation <: AbstractDeviceFormulation end

"""
Abstract type for Load Formulations.
"""
abstract type AbstractLoadFormulation <: AbstractDeviceFormulation end

"""
Root of the infrastructure model formulation type hierarchy.
Originally defined in InfrastructureModels.jl; now lives in IS so that
AbstractPowerModel can subtype it without circular dependencies.
"""
abstract type AbstractInfrastructureModel end

"""
Abstract type for Power Model Formulations.
Subtypes define the network representation (e.g., copper plate, PTDF, AC power flow).
"""
abstract type AbstractPowerModel <: AbstractInfrastructureModel end

"""
Abstract type for Active Power Model Formulations.
Subtypes model only active power (no reactive power).
"""
abstract type AbstractActivePowerModel <: AbstractPowerModel end

## AbstractPTDFModel and AbstractSecurityConstrainedPTDFModel are defined in
## PowerOperationsModels.jl where they can subtype PM.AbstractDCPModel.

"""
Abstract type for ACP (AC Polar) Power Model Formulations.
Concrete subtypes define specific polar AC formulations.
"""
abstract type AbstractACPModel <: AbstractPowerModel end

"""
Abstract type for HVDC Network Model Formulations.
Subtypes define how HVDC networks are modeled (e.g., transport, voltage dispatch).
"""
abstract type AbstractHVDCNetworkModel end
