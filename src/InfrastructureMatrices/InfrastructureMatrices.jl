"""
    InfrastructureMatrices

Abstract types for network matrix containers and network reduction data. Concrete
implementations are provided by domain packages (e.g. PowerNetworkMatrices.jl), so
that consumers (e.g. InfrastructureOptimizationModels.jl) can hold and pass these
objects without depending on the implementing package.
"""
module InfrastructureMatrices

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                    $(TYPEDSIGNATURES)
                                    $(DOCSTRING)
                                    """

"""
Abstract type for network matrix containers (e.g. PTDF, LODF, MODF and their
virtual variants). Concrete subtypes are defined by matrix-providing packages.

Rooted in `AbstractArray{T, 2}` so implementing packages (whose matrix types
already provide the 2-D array interface) can re-root under it without losing
the array interface.
"""
abstract type AbstractInfrastructureNetworkMatrix{T} <: AbstractArray{T, 2} end

"""
Abstract type for network reduction descriptions (e.g. radial or degree-two branch
reductions). Concrete subtypes are defined by matrix-providing packages.
"""
abstract type AbstractInfrastructureNetworkReductionData end

export AbstractInfrastructureNetworkMatrix
export AbstractInfrastructureNetworkReductionData

end # module InfrastructureMatrices
