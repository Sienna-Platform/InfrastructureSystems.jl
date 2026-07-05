# Test abstract types from IS.Optimization
# Note: Concrete implementations (Keys, Stores, Outputs) are in InfrastructureOptimizationModels

# Mock types extending IS.Optimization abstract types
struct MockContainer <: IS.Optimization.AbstractOptimizationContainer end
struct MockVariable <: IS.Optimization.VariableType end
struct MockVariable2 <: IS.Optimization.VariableType end
struct MockConstraint <: IS.Optimization.ConstraintType end
struct MockAuxVariable <: IS.Optimization.AuxVariableType end
struct MockExpression <: IS.Optimization.ExpressionType end
struct MockExpression2 <: IS.Optimization.ExpressionType end
struct MockParameter <: IS.Optimization.ParameterType end
struct MockInitialCondition <: IS.Optimization.InitialConditionType end
struct MockStoreParams <: IS.Optimization.AbstractModelStoreParams
    size::Integer
end

# Extend utility functions for custom types
IS.Optimization.convert_output_to_natural_units(::Type{MockVariable2}) = true
IS.Optimization.should_write_resulting_value(::Type{MockVariable2}) = false
IS.Optimization.convert_output_to_natural_units(::Type{MockExpression2}) = true
IS.Optimization.should_write_resulting_value(::Type{MockExpression2}) = false

@testset "IS.Optimization abstract types" begin
    # Test that mock types are subtypes of the correct abstract types
    @test MockContainer <: IS.Optimization.AbstractOptimizationContainer
    @test MockVariable <: IS.Optimization.VariableType
    @test MockVariable <: IS.Optimization.OptimizationKeyType
    @test MockConstraint <: IS.Optimization.ConstraintType
    @test MockConstraint <: IS.Optimization.OptimizationKeyType
    @test MockAuxVariable <: IS.Optimization.AuxVariableType
    @test MockExpression <: IS.Optimization.ExpressionType
    @test MockParameter <: IS.Optimization.ParameterType
    @test MockInitialCondition <: IS.Optimization.InitialConditionType
    @test MockStoreParams <: IS.Optimization.AbstractModelStoreParams
end

@testset "IS.Optimization utility functions" begin
    # Test default values
    @test IS.Optimization.convert_output_to_natural_units(MockVariable) == false
    @test IS.Optimization.should_write_resulting_value(MockVariable) == true
    @test IS.Optimization.convert_output_to_natural_units(MockConstraint) == false
    @test IS.Optimization.should_write_resulting_value(MockConstraint) == true
    @test IS.Optimization.convert_output_to_natural_units(MockAuxVariable) == false
    @test IS.Optimization.should_write_resulting_value(MockAuxVariable) == true
    @test IS.Optimization.convert_output_to_natural_units(MockExpression) == false
    @test IS.Optimization.should_write_resulting_value(MockExpression) == false
    @test IS.Optimization.convert_output_to_natural_units(MockParameter) == false
    @test IS.Optimization.should_write_resulting_value(MockParameter) == false

    # Test overridden values
    @test IS.Optimization.convert_output_to_natural_units(MockVariable2) == true
    @test IS.Optimization.should_write_resulting_value(MockVariable2) == false
    @test IS.Optimization.convert_output_to_natural_units(MockExpression2) == true
    @test IS.Optimization.should_write_resulting_value(MockExpression2) == false
end

@testset "IS.Optimization enums" begin
    @test IS.Optimization.ModelBuildStatus.IN_PROGRESS ==
          IS.Optimization.ModelBuildStatus(-1)
    @test IS.Optimization.ModelBuildStatus.BUILT == IS.Optimization.ModelBuildStatus(0)
    @test IS.Optimization.ModelBuildStatus.FAILED == IS.Optimization.ModelBuildStatus(1)
    @test IS.Optimization.ModelBuildStatus.EMPTY == IS.Optimization.ModelBuildStatus(2)
end

@testset "IS.Optimization construction stages" begin
    @test IS.Optimization.ArgumentConstructStage <: IS.Optimization.ConstructStage
    @test IS.Optimization.ModelConstructStage <: IS.Optimization.ConstructStage
    # Can instantiate
    @test IS.Optimization.ArgumentConstructStage() isa IS.Optimization.ConstructStage
    @test IS.Optimization.ModelConstructStage() isa IS.Optimization.ConstructStage
end

@testset "InitialConditionType trait methods throw instead of returning errors" begin
    @test_throws ArgumentError IS.Optimization.convert_output_to_natural_units(
        MockInitialCondition,
    )
    @test_throws ArgumentError IS.Optimization.should_write_resulting_value(
        MockInitialCondition,
    )
end

@testset "ModelBuildStatus convert from String" begin
    @test convert(IS.Optimization.ModelBuildStatus, "BUILT") ==
          IS.Optimization.ModelBuildStatus.BUILT
    @test convert(IS.Optimization.ModelBuildStatus, "IN_PROGRESS") ==
          IS.Optimization.ModelBuildStatus.IN_PROGRESS
end
