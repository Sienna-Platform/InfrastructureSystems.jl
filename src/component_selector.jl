# ABSTRACT TYPE DEFINITIONS
#=
`ComponentSelector` extension notes:
Concrete subtypes MUST implement:
 - `get_components(scope_limiter, selector, sys)`: returns an iterable of components
 - `get_name`: returns a name for the selector -- or use the default by having a `name::String` field
 - `get_groups(scope_limiter, selector, sys)`: returns an iterable of `ComponentSelector`s
 - `rebuild_selector`: returns a new `ComponentSelector` (need not be the same concrete
   type) with the changes given in the keyword arguments. `name` MUST be a valid keyword
   argument; it is up to the extender what other attributes of the selector may be rebuilt.
   There is a default that may suffice.

Concrete subtypes SHOULD implement:
 - The factory method `make_selector` (make sure your signature does not conflict with an
   existing one)

New `ComponentContainer`-like types MUST ensure that `get_available_components` and
`get_available_groups` work for them.
=#

# NOTE we cannot do all the @ref links we want to here because `IS.get_components !== PSY.get_components`, etc.
# See https://github.com/Sienna-Platform/InfrastructureSystems.jl/issues/388#issuecomment-2660019861
"""
Given some [`ComponentContainer`](@ref)-like source of components to draw from, such as a
[`PowerSystems.System`](@extref), a `ComponentSelector` picks out a certain subset of them
based on some user-defined selection criteria. A `ComponentSelector` can also be used to
name that subset of components or to split it up into groups. The same `ComponentSelector`
can be used to apply the same set of selection criteria to multiple sources of components.
The primary use case for `ComponentSelector` is to support repeatable multi-scenario
post-processing analytics (see e.g.
[`PowerAnalytics.jl`](https://sienna-platform.github.io/PowerAnalytics.jl/stable/)).

Formally, instances of `ComponentSelector` represent lazy, partitioned, named,
source-independent collections of [`InfrastructureSystemsComponent`](@ref)s.

# Core Interface

  - [`make_selector`](@ref): factory function to handle `ComponentSelector` creation; end
    users should use this rather than calling the constructors directly.
  - `get_groups`: get the groups that make up a `ComponentSelector`, which will themselves
    be represented as `ComponentSelector`s.
  - `get_components`: get all the components that make up a `ComponentSelector`, ignoring
    how they are grouped. A component should appear in the `get_components` of a given
    selector if and only if it appears in the `get_components` of at least one of that
    selector's groups.
  - [`get_name`](@ref): get the name of the `ComponentSelector`. All `ComponentSelector`s
    have a name, whether it is specified by the user or created automatically.
  - [`rebuild_selector`](@ref): create a new `ComponentSelector` from an existing one with
    some details (e.g., the name or the grouping behavior) tweaked.

# Availability Filtering

Besides the core interface, also provided are `get_component` for `ComponentSelector`
subtypes that can only refer to at most one component; and `get_available_component`,
`get_available_components`, and `get_available_groups`, which work the same as the
corresponding functions without `available` except they only consider components for which
`get_available` is true.

# `scope_limiter` Filtering

The `ComponentSelector` methods of `get_component`, `get_components`, and `get_groups`, and
the corresponding `_available_` variants, take an optional first argument
`scope_limiter::Union{Function, Nothing}`. If a function is passed in here, it will be used
as a filter function to limit the components under consideration before the
`ComponentSelector`'s criteria are evaluated.
"""
abstract type ComponentSelector end

#=
`SingularComponentSelector` extension notes:
The interface is the same as for `ComponentSelector` except:
 - `get_components` MUST return zero or one components
 - `get_component` MUST be implemented: return `nothing` where `get_components` would return
   zero components, else return an iterator of the one component
 - there is a sensible default for `get_groups`; it MAY be overridden
=#
"""
[`ComponentSelector`](@ref) subtype that can only refer to zero or one components.
`get_components` will always return zero or one components; `get_component`
will return the component directly if there is one and return `nothing` if there is not.
"""
abstract type SingularComponentSelector <: ComponentSelector end

#=
`PluralComponentSelector` extension notes:
The interface is the same as for `ComponentSelector`.
=#
"""
[`ComponentSelector`](@ref) subtype that may refer to multiple components.
"""
abstract type PluralComponentSelector <: ComponentSelector end

#=
`DynamicallyGroupedComponentSelector` extension notes:
One MAY subtype this and have a `groupby::Union{Symbol, Function}` field to get an automatic
implementation of `get_groups`.
=#
"""
`PluralComponentSelector`s whose grouping is determined by a `groupby` field. The semantics
of this field are described at [`make_selector`](@ref).
"""
abstract type DynamicallyGroupedComponentSelector <: PluralComponentSelector end

# COMMON COMPONENTSELECTOR INFRASTRUCTURE
"Canonical way to turn an `InfrastructureSystemsComponent` subtype into a unique string."
subtype_to_string(subtype::Type{<:InfrastructureSystemsComponent}) =
    strip_module_name(subtype)

"""
Canonical way to turn an `InfrastructureSystemsComponent` specification/instance into a
unique-per-system string.
"""
component_to_qualified_string(
    component_type::Type{<:InfrastructureSystemsComponent},
    component_name::AbstractString,
) = subtype_to_string(component_type) * COMPONENT_NAME_DELIMITER * component_name
component_to_qualified_string(component::InfrastructureSystemsComponent) =
    component_to_qualified_string(typeof(component), get_name(component))

const VALID_GROUPBY_KEYWORDS = [:all, :each]
const DEFAULT_GROUPBY = :each

"""
Helper function to check that the `groupby` argument is valid. Passes it through if so,
errors if not.
"""
validate_groupby(groupby::Symbol) =
    if (groupby in VALID_GROUPBY_KEYWORDS)
        groupby
    else
        throw(ArgumentError("groupby must be one of $VALID_GROUPBY_KEYWORDS or a function"))
    end
validate_groupby(groupby::Function) = groupby  # Don't try to validate functions for now

"""
Return a function that computes the conjunction of the two functions with short-circuit
evaluation, where if either of the functions is `nothing` it is as if its result is `true`.
"""
optional_and_fns(fn1::Function, fn2::Function) = x -> fn1(x) && fn2(x)
optional_and_fns(::Nothing, fn2::Function) = fn2
optional_and_fns(fn1::Function, ::Nothing) = fn1
optional_and_fns(::Nothing, ::Nothing) = Returns(true)

"""
Use `optional_and_fns` to return a function that computes the conjunction of `get_available`
and the given function
"""
available_and_fn(fn::Union{Function, Nothing}, sys) =
    optional_and_fns(get_available, fn)

# Generic implementations/generic docstrings for simple functions with many methods
"""
Factory function to create the appropriate subtype of [`ComponentSelector`](@ref) given the
arguments. Users should call this rather than manually constructing `ComponentSelector`s.

# Arguments

Several methods of this function have a parameter `groupby::Union{Symbol, Function}`, which
specifies how the selector is grouped for the purposes of `get_groups`. The
`groupby` argument has the following semantics:

  - `groupby = :each` (default): each component that makes up the selector forms its own
    group. The number of groups from `get_groups` will be equal to the number of
    components from `get_components`.
  - `groupby = :all`: all components that make up the selector are put into the same group.
    `get_groups` will yield one group.
  - `groupby = partition_function`: if the argument is a user-supplied function, the
    function will be applied to each component; all components with the same result under
    the function will be grouped together, with the name of the group specified by the
    function's output.

Other arguments are documented on a per-method basis.

# Examples

See the methods.
"""
function make_selector end

# Override this if you define a ComponentSelector subtype with no name field
"""
Get the name of the [`ComponentSelector`](@ref). This is either a user-specified name passed
in at creation or a name automatically generated from the selector's specification.

# Examples

```julia
sel = make_selector(RenewableDispatch)
get_name(sel)  # "RenewableDispatch"
```
"""
get_name(selector::ComponentSelector) = selector.name

"""
Given a [`ComponentContainer`](@ref)-like source of components, get those components that make up
the [`ComponentSelector`](@ref).

# Arguments

  - `selector::ComponentSelector`: the `ComponentSelector` that specifies which components
    to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
get_components(selector::ComponentSelector, sys) = get_components(nothing, selector, sys)

"""
Get the single component that matches the [`SingularComponentSelector`](@ref), or `nothing`
if there is no match.

# Arguments

  - `selector::SingularComponentSelector`: the `SingularComponentSelector` that specifies
    which component to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
get_component(selector::SingularComponentSelector, sys) =
    get_component(nothing, selector, sys)

"""
Like `get_components` but only operates on components for which
[`get_available`](@ref) is `true`.
"""
function get_available_components(
    scope_limiter::Union{Function, Nothing},
    selector::ComponentSelector,
    sys,
)
    filter_func = optional_and_fns(get_available, scope_limiter)
    get_components(filter_func, selector, sys)
end

"""
Like `get_components` but only operates on components for which
[`get_available`](@ref) is `true`.
"""
get_available_components(selector::ComponentSelector, sys) =
    get_available_components(nothing, selector, sys)

"""
Like `get_component` but only operates on components for which
[`get_available`](@ref) is `true`.
"""
get_available_component(
    scope_limiter::Union{Function, Nothing},
    selector::ComponentSelector,
    sys,
) = get_component(available_and_fn(scope_limiter, sys), selector, sys)

"""
Like `get_component` but only operates on components for which
[`get_available`](@ref) is `true`.
"""
get_available_component(selector::ComponentSelector, sys) =
    get_available_component(nothing, selector, sys)

"""
Given a [`ComponentContainer`](@ref)-like source of components, get the groups that make up the
[`ComponentSelector`](@ref).

# Arguments

  - `selector::ComponentSelector`: the `ComponentSelector` whose groups should be retrieved
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
get_groups(selector::ComponentSelector, sys) = get_groups(nothing, selector, sys)

"""
Like [`get_groups`](@ref) but only operates on components for which [`get_available`](@ref)
is `true`.
"""
get_available_groups(
    scope_limiter::Union{Function, Nothing},
    selector::ComponentSelector,
    sys,
) = get_groups(available_and_fn(scope_limiter, sys), selector, sys)

"""
Like [`get_groups`](@ref) but only operates on components for which [`get_available`](@ref)
is `true`.
"""
get_available_groups(selector::ComponentSelector, sys) =
    get_available_groups(nothing, selector, sys)

"""
Make a [`ComponentSelector`](@ref) containing the components in `all_components` whose
corresponding entry of `partition_results` matches `group_result`
"""
function _make_group(all_components, partition_results, group_result, group_name)
    to_include = [isequal(p_res, group_result) for p_res in partition_results]
    component_selectors = make_selector.(all_components[to_include])
    return make_selector(component_selectors...; name = group_name)
end

"""
Given a [`ComponentContainer`](@ref)-like source of components, use the `groupby` property
(see [`make_selector`](@ref)) to get the groups that make up the
`DynamicallyGroupedComponentSelector`.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::DynamicallyGroupedComponentSelector`: the
    [`DynamicallyGroupedComponentSelector`](@ref) whose groups should be retrieved
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
function get_groups(
    scope_limiter::Union{Function, Nothing},
    selector::DynamicallyGroupedComponentSelector,
    sys,
)
    (selector.groupby == :all) && return [selector]
    (selector.groupby == :each) &&
        return Iterators.map(make_selector,
            get_components(scope_limiter, selector, sys))
    @assert selector.groupby isa Function
    components = collect(get_components(scope_limiter, selector, sys))

    partition_results = (selector.groupby).(components)
    unique_partitions = unique(partition_results)
    partition_labels = string.(unique_partitions)
    # Catch the case where `p1 != p2` but `string(p1) == string(p2)`
    (length(unique_partitions) == length(unique(partition_labels))) ||
        throw(ArgumentError("Some partitions have the same name when converted to string"))

    return [
        _make_group(components, partition_results, group_result, group_name)
        for (group_result, group_name) in zip(unique_partitions, partition_labels)
    ]
end

"""
Get the single group that corresponds to the [`SingularComponentSelector`](@ref), i.e.,
itself.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref) (unused in
    this case)
  - `selector::SingularComponentSelector`: the `SingularComponentSelector` whose group
    should be retrieved
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from (unused in
    this case)
"""
get_groups(
    scope_limiter::Union{Function, Nothing},
    selector::SingularComponentSelector,
    sys,
) =
    [selector]

# Fallback `rebuild_selector` that only handles `name`
"""
Returns a [`ComponentSelector`](@ref) functionally identical to the input `selector` except
with the changes to its fields specified in the keyword arguments.

# Examples

Suppose you have a selector with `name = "my_name`. If you instead wanted `name =
"your_name`:
```julia
sel = make_selector(ThermalStandard, "322_CT_6"; name = "my_name")
sel_yours = rebuild_selector(sel; name = "your_name")
```
"""
function rebuild_selector(selector::T; name = nothing) where {T <: ComponentSelector}
    selector_data =
        Dict(key => getfield(selector, key) for key in fieldnames(typeof(selector)))
    isnothing(name) || (selector_data[:name] = name)
    return T(; selector_data...)
end

"""
Returns a [`ComponentSelector`](@ref) functionally identical to the input `selector` except
with the changes to its fields specified in the keyword arguments.

# Examples

Suppose you have a selector with `groupby = :all`. If you instead wanted `groupby = :each`:
```julia
sel = make_selector(ThermalStandard; groupby = :all)
sel_each = rebuild_selector(sel; groupby = :each)
```
"""
function rebuild_selector(selector::T;
    name = nothing, groupby = nothing) where {T <: DynamicallyGroupedComponentSelector}
    selector_data =
        Dict(key => getfield(selector, key) for key in fieldnames(typeof(selector)))
    isnothing(name) || (selector_data[:name] = name)
    isnothing(groupby) || (selector_data[:groupby] = groupby)
    return T(; selector_data...)
end

# CONCRETE SUBTYPE IMPLEMENTATIONS
# NameComponentSelector
"""
[`ComponentSelector`](@ref) that refers by type and name to at most a single component. Has
a single group that contains that component if it exists or contains no components if it
doesn't.
"""
@kwdef struct NameComponentSelector <: SingularComponentSelector
    component_type::Type{<:InfrastructureSystemsComponent}
    component_name::AbstractString
    name::String
end

# Construction (default constructor works if name is not nothing)
NameComponentSelector(
    component_type::Type{<:InfrastructureSystemsComponent},
    component_name::AbstractString,
    ::Nothing = nothing,
) =
    NameComponentSelector(
        component_type,
        component_name,
        component_to_qualified_string(component_type, component_name),
    )

"""
Make a [`ComponentSelector`](@ref) pointing to a single component with the given type and
name. Optionally provide a name for the selector. Selectors constructed this way contain
exactly one group, which contains one component if the target component exists and zero if
it doesn't.

# Arguments

  - `component_type::Type{<:InfrastructureSystemsComponent}`: the type of the target
    component
  - `component_name::AbstractString`: the name of the target component
  - `name::Union{String, Nothing} = nothing`: the name of the selector; if not provided, one
    will be constructed automatically

# Examples

```julia
sel1 = make_selector(ThermalStandard, "322_CT_6")
sel2 = make_selector(ThermalStandard, "322_CT_6"; name = "my_selector")
```

See also: [`make_selector`](@ref) unified function documentation
"""
make_selector(
    component_type::Type{<:InfrastructureSystemsComponent},
    component_name::AbstractString;
    name::Union{String, Nothing} = nothing,
) = NameComponentSelector(component_type, component_name, name)
"""
Make a [`ComponentSelector`](@ref) from a component, pointing to a single component with the
same type and name as the one given. Optionally provide a name for the selector. Selectors
constructed this way contain exactly one group, which contains one component if the target
component exists and zero if it doesn't.

# Arguments

  - `component::InfrastructureSystemsComponent`: the component whose type and name specify
    the target of this selector
  - `name::Union{String, Nothing} = nothing`: the name of the selector; if not provided, one
    will be constructed automatically

# Examples

```julia
sel1 = make_selector(my_component)
sel2 = make_selector(my_component; name = "my_selector")
```

See also: [`make_selector`](@ref) unified function documentation
"""
make_selector(
    component::InfrastructureSystemsComponent;
    name::Union{String, Nothing} = nothing,
) =
    make_selector(typeof(component), get_name(component)::AbstractString; name = name)

# Contents
"""
Get the component to which the [`NameComponentSelector`](@ref) points, or `nothing` if such
a component does not exist in `sys`.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::NameComponentSelector`: the `NameComponentSelector` whose component to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
function get_component(
    scope_limiter::Union{Function, Nothing},
    selector::NameComponentSelector,
    sys,
)
    com = get_component(selector.component_type, sys, selector.component_name)
    isnothing(com) && return nothing
    (!isnothing(scope_limiter) && !scope_limiter(com)) && return nothing
    return com
end

"""
Get the components to which the [`NameComponentSelector`](@ref) points.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::NameComponentSelector`: the `NameComponentSelector` whose components to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
function get_components(
    scope_limiter::Union{Function, Nothing},
    selector::NameComponentSelector,
    sys,
)
    com = get_component(scope_limiter, selector, sys)
    isnothing(com) && return _make_empty_iterator(selector.component_type)
    # Wrap the one component up in a bunch of other data structures to get the Sienna standard type for this
    com_dict = Dict(selector.component_name => com)
    return _make_iterator_from_concrete_dict(selector.component_type, com_dict)
end

# ListComponentSelector
"""
[`ComponentSelector`](@ref) represented by a list of other `ComponentSelector`s. Those
selectors form the groups.
"""
@kwdef struct ListComponentSelector <: PluralComponentSelector
    # Using tuples internally for immutability => `==` is automatically well-behaved
    content::Tuple{Vararg{ComponentSelector}}
    name::String
end

# Construction (default constructor works if name is not nothing)
ListComponentSelector(content::Tuple{Vararg{ComponentSelector}}, ::Nothing = nothing) =
    ListComponentSelector(content, "[$(join(get_name.(content), ", "))]")

"""
Make a [`ComponentSelector`](@ref) from several existing `ComponentSelector`s. Optionally
provide a name for the selector. Selectors constructed this way contain one group for each
of the selectors they were constructed with.

# Arguments

  - `content::ComponentSelector...`: the list of selectors that should form the groups
  - `name::Union{String, Nothing} = nothing`: the name of the selector; if not provided, one
    will be constructed automatically

# Examples

```julia
sel1 = make_selector(make_selector(ThermalStandard), make_selector(RenewableDispatch))
sel2 = make_selector(make_selector(ThermalStandard), make_selector(RenewableDispatch); name = "my_selector")
```

See also: [`make_selector`](@ref) unified function documentation
"""
make_selector(content::ComponentSelector...; name::Union{String, Nothing} = nothing) =
    ListComponentSelector(content, name)

"""
Get the groups to which the [`ListComponentSelector`](@ref) points.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::ListComponentSelector`: the `ListComponentSelector` whose groups to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
# Contents
function get_groups(::Union{Function, Nothing}, selector::ListComponentSelector, sys)
    return selector.content
end

"""
Get the components to which the [`ListComponentSelector`](@ref) points.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::ListComponentSelector`: the `ListComponentSelector` whose components to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
function get_components(
    scope_limiter::Union{Function, Nothing},
    selector::ListComponentSelector,
    sys,
)
    sub_components =
        map(
            x -> get_components(scope_limiter, x, sys),
            selector.content,
        )
    my_supertype = typejoin(eltype.(sub_components)...)
    return FlattenIteratorWrapper(my_supertype, sub_components)
end

# Rebuilding
"""
Returns a [`ComponentSelector`](@ref) functionally identical to the input `selector` except
with the changes to its fields specified in the keyword arguments. It is not guaranteed that
the result will have the same concrete type.

# Examples

Suppose you have a selector with manual groups and you want to group by `:each`:
```julia
sel = make_selector(make_selector(ThermalStandard), make_selector(RenewableDispatch))
sel_each = rebuild_selector(sel; groupby = :each)  # will be a RegroupedComponentSelector
```
"""
function rebuild_selector(selector::ListComponentSelector;
    name = nothing, groupby = nothing)
    # Handle the easy stuff first
    selector_data =
        Dict(key => getfield(selector, key) for key in fieldnames(typeof(selector)))
    isnothing(name) || (selector_data[:name] = name)
    rebuilt = ListComponentSelector(; selector_data...)

    # Wrap in a RegroupedComponentSelector if we need to
    isnothing(groupby) && return rebuilt
    return RegroupedComponentSelector(rebuilt, groupby)
end

# TypeComponentSelector
"""
[`ComponentSelector`](@ref) represented by a type of component. Contains all the components
of that type, grouped by the `groupby` field (see [`make_selector`](@ref)).
"""
@kwdef struct TypeComponentSelector <: DynamicallyGroupedComponentSelector
    component_type::Type{<:InfrastructureSystemsComponent}
    groupby::Union{Symbol, Function}
    name::String

    TypeComponentSelector(
        component_type::Type{<:InfrastructureSystemsComponent},
        groupby::Union{Symbol, Function},
        name::String,
    ) = new(component_type, validate_groupby(groupby), name)
end

# Construction
TypeComponentSelector(
    component_type::Type{<:InfrastructureSystemsComponent},
    groupby::Union{Symbol, Function},
    ::Nothing = nothing,
) = TypeComponentSelector(component_type, groupby, subtype_to_string(component_type))

"""
Make a [`ComponentSelector`](@ref) from a type of component. Optionally provide a grouping
behavior and/or name for the selector. Selectors constructed this way point to all the
components of the given type, grouped by the `groupby` argument (see the base
[`make_selector`](@ref) documentation).

# Arguments

  - `component_type::Type{<:InfrastructureSystemsComponent}`: the type of component to
    select
  - `groupby::Union{Symbol, Function} = :each`: the grouping behavior (see the base
    [`make_selector`](@ref) documentation)
  - `name::Union{String, Nothing} = nothing`: the name of the selector; if not provided, one
    will be constructed automatically

# Examples

```julia
sel1 = make_selector(RenewableDispatch)
sel2 = make_selector(RenewableDispatch; groupby = :all)
sel3 = make_selector(RenewableDispatch; name = "my_selector")
```

See also: [`make_selector`](@ref) unified function documentation
"""
make_selector(
    component_type::Type{<:InfrastructureSystemsComponent};
    groupby::Union{Symbol, Function} = DEFAULT_GROUPBY,
    name::Union{String, Nothing} = nothing,
) = TypeComponentSelector(component_type, groupby, name)

# Contents
"""
Get the components to which the [`TypeComponentSelector`](@ref) points.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::TypeComponentSelector`: the `TypeComponentSelector` whose components to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
function get_components(
    scope_limiter::Union{Function, Nothing},
    selector::TypeComponentSelector,
    sys,
)
    isnothing(scope_limiter) && return get_components(selector.component_type, sys)
    return get_components(scope_limiter, selector.component_type, sys)
end

# FilterComponentSelector
"""
[`ComponentSelector`](@ref) represented by a filter function and a type of component.
Contains all the components of that type that satisfy the filter function, grouped by the
`groupby` field (see [`make_selector`](@ref)).
"""
@kwdef struct FilterComponentSelector <: DynamicallyGroupedComponentSelector
    component_type::Type{<:InfrastructureSystemsComponent}
    filter_func::Function
    groupby::Union{Symbol, Function}
    name::String

    FilterComponentSelector(
        component_type::Type{<:InfrastructureSystemsComponent},
        filter_func::Function,
        groupby::Union{Symbol, Function},
        name::String,
    ) = new(component_type, filter_func, validate_groupby(groupby), name)
end

# Construction
FilterComponentSelector(
    component_type::Type{<:InfrastructureSystemsComponent},
    filter_func::Function,
    groupby::Union{Symbol, Function},
    ::Nothing = nothing,
) =
    FilterComponentSelector(
        component_type,
        filter_func,
        groupby,
        string(filter_func) * COMPONENT_NAME_DELIMITER * subtype_to_string(component_type),
    )

"""
Make a [`ComponentSelector`](@ref) from a filter function and a type of component. The
filter function must accept instances of `component_type` as a sole argument and return a
`Bool`. Optionally provide a grouping behavior and/or name for the selector. Selectors
constructed this way point to all the components of the given type that satisfy the filter
function, grouped by the `groupby` argument (see the base [`make_selector`](@ref)
documentation).

# Arguments

  - `filter_func::Function`: the filter function to apply to components
  - `component_type::Type{<:InfrastructureSystemsComponent}`: the type of component to
    select
  - `groupby::Union{Symbol, Function} = :each`: the grouping behavior (see the base
    [`make_selector`](@ref) documentation)
  - `name::Union{String, Nothing} = nothing`: the name of the selector; if not provided, one
    will be constructed automatically

# Examples

```julia
sel1 = make_selector(RenewableDispatch, x -> get_prime_mover_type(x) == PrimeMovers.PVe)
sel2 = make_selector(RenewableDispatch, x -> get_prime_mover_type(x) == PrimeMovers.PVe; groupby = :all)
sel3 = make_selector(RenewableDispatch, x -> get_prime_mover_type(x) == PrimeMovers.PVe; name = "my_selector")
```

See also: [`make_selector`](@ref) unified function documentation
"""
make_selector(
    filter_func::Function,
    component_type::Type{<:InfrastructureSystemsComponent};
    name::Union{String, Nothing} = nothing,
    groupby::Union{Symbol, Function} = DEFAULT_GROUPBY,
) = FilterComponentSelector(component_type, filter_func, groupby, name)

# Contents
"""
Get the components to which the [`FilterComponentSelector`](@ref) points.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::FilterComponentSelector`: the `FilterComponentSelector` whose components to
    get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
function get_components(
    scope_limiter::Union{Function, Nothing},
    selector::FilterComponentSelector,
    sys,
)
    # Short-circuit-evaluate the `scope_limiter` first so `filter_func` may refer to
    # component attributes that do not exist in components outside the scope
    combo_filter = optional_and_fns(scope_limiter, selector.filter_func)
    components = get_components(combo_filter, selector.component_type, sys)
    return components
end

# RegroupedComponentSelector
"""
[`ComponentSelector`](@ref) that wraps another `ComponentSelector` and applies dynamic
grouping. Components are the same as those of the wrapped selector, grouping is by the
`groupby` field (see [`make_selector`](@ref))
"""
@kwdef struct RegroupedComponentSelector <: DynamicallyGroupedComponentSelector
    wrapped_selector::ComponentSelector
    groupby::Union{Symbol, Function}

    RegroupedComponentSelector(
        wrapped_selector::ComponentSelector,
        groupby::Union{Symbol, Function},
    ) = new(wrapped_selector, validate_groupby(groupby))
end

# Naming
get_name(selector::RegroupedComponentSelector) = get_name(selector.wrapped_selector)

# Contents
"""
Get the components to which the [`RegroupedComponentSelector`](@ref) points.

# Arguments

  - `scope_limiter::Union{Function, Nothing}`: see [`ComponentSelector`](@ref)
  - `selector::RegroupedComponentSelector`: the `RegroupedComponentSelector` whose
    components to get
  - `sys`: the [`ComponentContainer`](@ref)-like source of components to draw from
"""
get_components(
    scope_limiter::Union{Function, Nothing},
    selector::RegroupedComponentSelector,
    sys,
) =
    get_components(scope_limiter, selector.wrapped_selector, sys)
