mutable struct TestComponent <: InfrastructureSystemsComponent
    name::String
    val::Int
    val2::Int
    internal::InfrastructureSystemsInternal
end

function TestComponent(name, val; val2 = 0)
    return TestComponent(
        name,
        val,
        val2,
        InfrastructureSystemsInternal(),
    )
end

mutable struct AdditionalTestComponent <: InfrastructureSystemsComponent
    name::String
    val::Int
    internal::InfrastructureSystemsInternal
end

function AdditionalTestComponent(name, val)
    return AdditionalTestComponent(
        name,
        val,
        InfrastructureSystemsInternal(),
    )
end

mutable struct SimpleTestComponent <: InfrastructureSystemsComponent
    name::String
    val::Int
    internal::InfrastructureSystemsInternal
end

function SimpleTestComponent(name, val)
    return SimpleTestComponent(name, val, InfrastructureSystemsInternal())
end

function SimpleTestComponent(; name, val, internal = InfrastructureSystemsInternal())
    return SimpleTestComponent(name, val, internal)
end

get_internal(component::TestComponent) = component.internal
get_internal(component::AdditionalTestComponent) = component.internal
get_val(component::TestComponent) = component.val
get_val2(component::TestComponent) = component.val2
supports_time_series(::TestComponent) = true
supports_time_series(::AdditionalTestComponent) = true
supports_time_series(::SimpleTestComponent) = false

function from_json(io::IO, ::Type{TestComponent})
    data = JSON.parse(io; dicttype = Dict{String, Any})
    return deserialize(TestComponent, data)
end

function deserialize(::Type{TestComponent}, data::Dict)
    return TestComponent(
        data["name"],
        data["val"],
        data["val2"],
        deserialize(InfrastructureSystemsInternal, data["internal"]),
    )
end

struct TestSupplemental <: SupplementalAttribute
    value::Float64
    internal::InfrastructureSystemsInternal
end

function TestSupplemental(;
    value::Float64,
    internal::InfrastructureSystemsInternal = InfrastructureSystemsInternal(),
)
    return TestSupplemental(value, internal)
end

supports_time_series(::TestSupplemental) = true
get_value(attr::TestSupplemental) = attr.attr_json
get_internal(attr::TestSupplemental) = attr.internal
get_uuid(attr::TestSupplemental) = get_uuid(get_internal(attr))
