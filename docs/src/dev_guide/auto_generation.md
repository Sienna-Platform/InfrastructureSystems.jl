# Auto-Generation of Component Structs

`InfrastructureSystems.jl` provides a mechanism to auto-generate Julia files
containing structs and field accessor functions from JSON descriptors. Here are
reasons to consider using this approach:

  - Auto-generation allows for easy refactoring of code. Adding fields
    to many structs can be tedious because you might have to edit many
    constructors. This process eliminates boiler-plate edits.
  - The JSON descriptor format includes a mechanism to define range validation
    on component fields. Validation can be enabled when adding components to a
    system.
  - Provides consistent formatting of structs, fields, and constructors.
  - Provides consistent documentation of structs and fields.

## Instructions

Refer to the docstrings for `generate_struct` and `generate_structs` and generate the files from the REPL.

Or

 1. Create or modify the JSON descriptor file. Follow the
    [PowerSystems.jl](https://github.com/Sienna-Platform/PowerSystems.jl/blob/main/src/descriptors/power_system_structs.json)
    example.
 2. Run the generation script, passing your descriptor file and an output
    directory.

```julia
InfrastructureSystems.generate_structs(
    "./src/descriptors/power_system_structs.json",
    "./src/models/generated",
)
```

## Struct Descriptor Rules

Each struct descriptor must define the following fields:

  - `struct_name`: Name of struct
  - `docstring`: The docstring of the struct
  - `fields`: Array of struct members. See below for requirements.
  - `supertype`: Declare the struct with this parent type.

Required fields for each struct member:

  - `name`: Name of field
  - `data_type`: Type of field

Optional fields for each struct member:

  - `accessor_module`: Set this if the getter/setter functions are reimplementing a method defined in a different module.

  - `comment`: Field comment
  - `default`: The constructors will define this as a default value.
  - `exclude_setter`: Do not generate a setter function for this field.
  - `internal_default`: Set to true for non-user-facing fields like `InfrastructureSystemsInternal` that have default values.
  - `needs_conversion`: Set to true if the getter and setter function needs to apply unit conversion. The type must implement
    
      + `get_value(::InfrastructureSystemsComponent, ::Type)` and
      + `set_value(::InfrastructureSystemsComponent, ::Type)`
        for this combination of component type and member type.
  - `null_value`: Value to indicate the value is null, such as 0.0 for floating point numbers.
    If all members in the struct define this field then a "demo" constructor will be generated.
    This allows you to enter `val = MyType(nothing)` in the REPL and see the layout of a struct without worrying about valid values.
  - `valid_range`: Define this as a Dict with `min` and `max` and `InfrastructureSystems.jl` will validate any value against that range when you add the component to the system. Use `null` if one doesn't apply, such as if there is no max limit.
  - `validation_action`: Define this as `error` or `warn`. If it is `error` then `InfrastructureSystems.jl` will raise an exception if the validation code detects a problem. Otherwise, it will log a warning.

*Notes*:

  - You will need to decide how to manage the generated files. The Sienna packages keep the
    generated code in the git repository. This is not required.
    You could choose to generate them at startup.
  - You may need to create custom constructors and this approach will not allow
    you to put them in the same file as the struct definition.
