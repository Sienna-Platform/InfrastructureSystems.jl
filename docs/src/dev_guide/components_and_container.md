# Managing Components

`InfrastructureSystems.jl` provides a common way of managing component structs in a
system.

## Type hierachy

Make every component a subtype of `InfrastructureSystemsComponent`.

## InfrastructureSystemsInternal

Add this struct to every component struct.

  - It automatically creates a UUID for the component. This guarantees a unique
    way to identify the component.
  - It optionally provides an extension dictionary for user data. A user
    extending your package may want to use your struct but need one more field.
    Rather than create a new type they can add data to this `ext` object.

## Instructions to implement a `Component`

 1. Add the field to your struct. The constructor does not take any parameters.

```julia
struct MyComponent
    internal::InfrastructureSystemsInternal
end

# Optional
get_ext(c::MyComponent) = InfrastructureSystems.get_ext(c.ext)
clear_ext!(c::MyComponent) = InfrastructureSystems.clear_ext(c.ext)
```

 2. Implement this function with `true` or `false` depending on whether your component type
    will support time series data. The default method returns `false`.

```julia
supports_time_series(::MyComponent) = true
```

 3. Implement this function with `true` or `false` depending on whether your component type
    will support supplemental attributes. The default method returns `true`.

```julia
supports_supplemental_attributes(::MyComponent) = true
```

*Notes*:

  - [`InfrastructureSystems.get_id`](@ref) with argument `obj::InfrastructureSystemsComponent`
    returns the component ID.
  - The extension dictionary is not created until the first time `get_ext` is
    called.

## Interface requirements

Implement these methods for every struct.

  - `get_internal(c::MyComponent)::InfrastructureSystemsInternal`
  - `get_name(c::MyComponent)::String`

If the struct supports time series (default is false):

  - `supports_time_series(::MyComponent) = true`

## Component Container

`InfrastructureSystems.jl` provides the `SystemData` struct to store a collection of
components.

It is recommended but not required that you include this struct within your own
system struct for these reasons:

  - Provides search and iteration with [`InfrastructureSystems.get_component`](@ref)
    and [`InfrastructureSystems.get_components`](@ref) for abstract and concrete types.
  - Enforces name uniqueness within a concrete type.
  - Allows for component field validation.
  - Enables component JSON serialization and deserialization.

## Instructions on how to use the `SystemData` container

 1. Add an instance of `SystemData` to your system struct.
 2. Optionally pass a component validation descriptor file to the constructor.
 3. Optionally pass `time_series_in_memory = true` to the constructor if you
    know that all time series data will fit in memory and want a performance
    boost.
 4. Redirect these function calls to your instance of SystemData.

  - `add_component!`
  - `remove_component!`
  - `get_component`
  - `get_components`
  - `get_components_by_name`
  - `add_time_series!`

## Importing InfrastructureSystems methods

It is recommended that you perform redirection on methods that act on
`SystemData` so that those methods don't show up in `Julia` help or in
`methods` output. For example:

```julia
get_time_series_resolution(sys::MySystem) =
    InfrastructureSystems.get_time_series_resolution(sys.data)
```

On the other hand, it is recommended that you import methods that act on an
`InfrastructureSystemsComponent` into your package's namespace so that you
don't have to duplicate docstrings and perform redirection. For example:

```julia
import InfrastructureSystems: get_time_series
```
