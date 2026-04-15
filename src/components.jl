const ComponentsByType = Dict{DataType, Dict{String, <:InfrastructureSystemsComponent}}

"A simple container for components and time series data."
struct Components <: ComponentContainer
    data::ComponentsByType
    time_series_manager::TimeSeriesManager
    validation_descriptors::Vector
end

get_member_string(::Components) = "components"

function Components(
    time_series_manager::TimeSeriesManager,
    validation_descriptors = nothing,
)
    if isnothing(validation_descriptors)
        validation_descriptors = Vector()
    end

    return Components(ComponentsByType(), time_series_manager, validation_descriptors)
end

function serialize(components::Components)
    # time_series_storage and validation_descriptors are serialized elsewhere.
    return [serialize(x) for y in values(components.data) for x in values(y)]
end

function _add_component!(
    components::Components,
    component::T;
    skip_validation = false,
    allow_existing_time_series = false,
) where {T <: InfrastructureSystemsComponent}
    component_name = get_name(component)
    if !isconcretetype(T)
        throw(ArgumentError("add_component! only accepts concrete types"))
    end

    if !haskey(components.data, T)
        components.data[T] = Dict{String, T}()
    elseif haskey(components.data[T], component_name)
        throw(
            ArgumentError("Component name $(component_name) is already stored for type $T"),
        )
    end

    !skip_validation && check_component(components, component)

    if !allow_existing_time_series && has_time_series(component)
        throw(ArgumentError("cannot add a component with time_series: $component"))
    end

    components.data[T][component_name] = component
    return
end

"""
Add a component.

Throws ArgumentError if the component's name is already stored for its concrete type.

Throws InvalidRange if any of the component's field values are outside of defined valid
range.
"""
function add_component!(
    components::Components,
    component::T;
    kwargs...,
) where {T <: InfrastructureSystemsComponent}
    kw = _add_component_kwarg_deprecation(kwargs)
    _add_component!(components, component; kw...)
    return
end

function check_components(components::Components)
    return check_components(components, iterate_components(components))
end

function check_components(
    components::Components,
    ::Type{<:T},
) where {T <: InfrastructureSystemsComponent}
    return check_components(components, get_components(T, components))
end

function check_components(components::Components, components_iterable)
    for component in components_iterable
        check_component(components, component)
    end
end

function check_component(components::Components, comp::InfrastructureSystemsComponent)
    if !isempty(components.validation_descriptors) && !validate_fields(components, comp)
        throw(InvalidValue("$(summary(comp)) has an invalid field"))
    end

    if !validate_struct(comp)
        throw(InvalidValue("$(summary(comp)) is invalid"))
    end
    return
end

"""
Removes all components from the system.
"""
function clear_components!(components::Components)
    for type_ in collect(keys(components.data))
        remove_components!(type_, components)
    end
end

"""
Remove all components of type T.

Throws ArgumentError if the type is not stored.
"""
function remove_components!(
    ::Type{T},
    components::Components,
) where {T <: InfrastructureSystemsComponent}
    if !haskey(components.data, T)
        throw(ArgumentError("component $T is not stored"))
    end

    _components = pop!(components.data, T)
    for component in values(_components)
        prepare_for_removal!(component)
    end

    @debug "Removed all components of type" _group = LOG_GROUP_SYSTEM T
    return values(_components)
end

"""
Remove a component by its value.

Throws ArgumentError if the component is not stored.
"""
function remove_component!(
    components::Components,
    component::T;
    remove_time_series = true,
    remove_supplemental_attributes = true,
) where {T <: InfrastructureSystemsComponent}
    return _remove_component!(
        T,
        components,
        get_name(component);
        remove_time_series = remove_time_series,
        remove_supplemental_attributes = remove_supplemental_attributes,
    )
end

"""
Remove a component by its name.

Throws ArgumentError if the component is not stored.
"""
function remove_component!(
    ::Type{T},
    components::Components,
    name::AbstractString;
    remove_time_series = true,
    remove_supplemental_attributes = true,
) where {T <: InfrastructureSystemsComponent}
    return _remove_component!(
        T,
        components,
        name;
        remove_time_series = remove_time_series,
        remove_supplemental_attributes = remove_supplemental_attributes,
    )
end

function _remove_component!(
    ::Type{T},
    components::Components,
    name::AbstractString;
    remove_time_series = true,
    remove_supplemental_attributes = true,
) where {T <: InfrastructureSystemsComponent}
    if !haskey(components.data, T)
        throw(ArgumentError("component $T is not stored"))
    end

    if !haskey(components.data[T], name)
        throw(ArgumentError("component $T name=$name is not stored"))
    end

    component = pop!(components.data[T], name)
    if isempty(components.data[T])
        pop!(components.data, T)
    end

    if remove_supplemental_attributes && has_supplemental_attributes(component)
        clear_supplemental_attributes!(component)
    end

    if remove_time_series
        prepare_for_removal!(component)
    end

    @debug "Removed component" _group = LOG_GROUP_SYSTEM T name
    return component
end

"""
Check to see if a component with name exists.
"""
function has_component(
    components::Components,
    T::Type{<:InfrastructureSystemsComponent},
    name::AbstractString,
)
    !isconcretetype(T) && return !isempty(get_components_by_name(T, components, name))
    !haskey(components.data, T) && return false
    return haskey(components.data[T], name)
end

"""
Check to see if a component if the given type exists.
"""
function has_components(
    components::Components,
    T::Type{<:InfrastructureSystemsComponent},
)
    if !isconcretetype(T)
        for key in keys(components.data)
            if key <: T
                return true
            end
        end
    end
    return haskey(components.data, T)
end

"""
Get the component of type T with name. Returns nothing if no component matches. If T is an abstract
type then the names of components across all subtypes of T must be unique.

See [`get_components_by_name`](@ref) for abstract types with non-unique names across subtypes.

Throws ArgumentError if T is not a concrete type and there is more than one component with
requested name
"""
function get_component(
    ::Type{T},
    components::Components,
    name::AbstractString,
) where {T <: InfrastructureSystemsComponent}
    if !isconcretetype(T)
        components = get_components_by_name(T, components, name)
        if length(components) > 1
            throw(
                ArgumentError(
                    "More than one abstract component of type $T with name $name in the system. Operation can't continue",
                ),
            )
        end
        return isempty(components) ? nothing : first(components)
    end

    if !haskey(components.data, T)
        @debug "components of type $T are not stored" _group = LOG_GROUP_SYSTEM
        return nothing
    end

    return get(components.data[T], name, nothing)
end

"""
Get the components of abstract type T with name. Note that
InfrastructureSystems enforces unique names on each concrete type but not
across concrete types.

See [`get_component`](@ref) if the concrete type is known.

Throws ArgumentError if T is not an abstract type.
"""
function get_components_by_name(
    ::Type{T},
    components::Components,
    name::AbstractString,
) where {T <: InfrastructureSystemsComponent}
    if isconcretetype(T)
        throw(ArgumentError("get_components_by_name does not support concrete types: $T"))
    end

    _components = Vector{T}()
    for key in keys(components.data)
        if key <: T
            component = get_component(key, components, name)
            if !isnothing(component)
                push!(_components, component)
            end
        end
    end

    return _components
end

"""
Returns an iterator of components. T can be concrete or abstract.
Call collect on the result if an array is desired.

# Arguments

  - `T`: component type
  - `components::Components`: Components of the system
  - `filter_func::Union{Nothing, Function} = nothing`: Optional function that accepts a component
    of type T and returns a Bool. Apply this function to each component and only return components
    where the result is true.

See also: [`iterate_components`](@ref)
"""
function get_components(
    ::Type{T},
    components::Components;
    component_uuids::Union{Nothing, Set{Base.UUID}} = nothing,
) where {T <: InfrastructureSystemsComponent}
    return iterate_instances(T, components.data, component_uuids)
end

function get_components(
    filter_func::Function,
    ::Type{T},
    components::Components;
    component_uuids::Union{Nothing, Set{Base.UUID}} = nothing,
) where {T <: InfrastructureSystemsComponent}
    return iterate_instances(filter_func, T, components.data, component_uuids)
end

"""
Iterates over all components.

# Examples

```Julia
for component in iterate_components(obj)
    @show component
end
```

See also: [`get_components`](@ref)
"""
function iterate_components(components::Components)
    return iterate_container(components)
end

"""
Return the total number of components stored.
"""
function get_num_components(components::Components)
    return get_num_members(components)
end

function is_attached(component::InfrastructureSystemsComponent, components::Components)
    T = typeof(component)
    !haskey(components.data, T) && return false
    _component = get(components.data[T], get_name(component), nothing)
    isnothing(_component) && return false

    if component !== _component
        @warn "A component with the same name as $(summary(component)) is stored in the " *
              "system but is not the same instance."
        return false
    end

    return true
end

function throw_if_not_attached(
    components::Components,
    component::InfrastructureSystemsComponent,
)
    if !is_attached(component, components)
        throw(ArgumentError("$(summary(component)) is not attached to the system"))
    end
end

function set_name!(
    components::Components,
    component::T,
    name,
) where {T <: InfrastructureSystemsComponent}
    throw_if_not_attached(components, component)
    if haskey(components.data[T], name)
        if components.data[T][name] === component
            return
        end
        throw(ArgumentError("A component of type $T and name = $name is already stored"))
    end

    old_name = get_name(component)
    _component = components.data[T][old_name]

    if component !== _component
        throw(
            ArgumentError(
                "component does not match the stored component: $(summary(component))",
            ),
        )
    end

    pop!(components.data[T], old_name)
    set_name_internal!(component, name)
    components.data[T][name] = component
    @debug "Changed the name of component $(summary(component))" _group = LOG_GROUP_SYSTEM
    return
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::Components,
    y::Components;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    match = true
    for name in fieldnames(Components)
        name in exclude && continue
        # This gets validated in SystemData.
        name == :time_series_manager && continue
        val_x = getproperty(x, name)
        val_y = getproperty(y, name)
        if !compare_values(
            match_fn,
            val_x,
            val_y;
            compare_uuids = compare_uuids,
            exclude = exclude,
        )
            val_x = getproperty(x, name)
            val_y = getproperty(y, name)
            @error "Components field = $name does not match" val_x val_y
            match = false
        end
    end

    return match
end
