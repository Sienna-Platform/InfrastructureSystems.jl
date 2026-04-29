"""
    _validate_conversion_unit(s::AbstractString)

`conversion_unit` is interpolated into `Val(...)` in the generated getter, so
it MUST evaluate to a compile-time constant. Accept only:

  * The literal `"nothing"` (no conversion).
  * A symbol literal: `:active_power_unit`, `:mva`, `:x_unit`
  * A dotted constant path: `PowerSystems.PowerUnits.MW`

Anything else is rejected — including arithmetic operators (`+`, `*`, `-`),
commas, `\$` interpolation, function calls, array/dict literals, whitespace,
leading/trailing dots, and other runtime expressions.
"""
function _validate_conversion_unit(s::AbstractString)
    s == "nothing" && return s
    occursin(r"^:?\w+(\.\w+)*$", s) && return s
    error(
        "conversion_unit must be a compile-time constant (symbol literal " *
        "or const-bound dotted path); got: $(repr(s))",
    )
end

struct StructField
    name::String
    data_type::String
    default::Any
    comment::String
    needs_conversion::Bool
    exclude_setter::Bool
    valid_range::Union{Nothing, String, Dict}
    validation_action::Union{Nothing, String}
    internal_default::Any
    null_value::Any
end

"""
Construct a StructField for code auto-generation purposes.

# Arguments

  - `name::String`: Field name
  - `data_type::Union{DataType, String}`: Field type
  - `default::Any`: The generated constructors will define this as a default value.
  - `comment::String`: Include this comment above the field name. Defaults to empty string.
  - `needs_conversion::Bool`: Set to true if the getter and setter functions need to apply
    unit
    conversion. The type must implement `get_value(::Component, ::Type)` and
    `set_value(::Component, ::Type)` for this combination of component type and field type.
  - `exclude_setter::Bool`: Do not generate a setter function for this field. Defaults to
    false.
  - `valid_range::Union{Nothing, String, Dict}`: Enables range validation when the component
    is added to a system. Define this as a Dict with "min" and "max" or as a String with the
    field name in the struct that defines this field's valid range and InfrastructureSystems
    will validate any value against that range. Use `nothing` if one doesn't apply, such as
    if there is no max limit.
  - `validation_action`: Define this as "error" or "warn". If it is "error" then
    InfrastructureSystems will throw an exception if the validation code detects a problem.
    Otherwise, it will log a warning.
  - `null_value::Any`: Value to indicate the field is zero or empty, such as 0.0 for Float64.
    If all members in the struct define this field then a "demo" constructor will be
    generated.
    This allows entering `val = MyType(nothing)` in the REPL to see the layout of a struct
    without worrying about valid values.
  - `internal_default`: Set to true for non-user-facing fields like
    `InfrastructureSystemsInternal` that have default values.
"""
function StructField(;
    name,
    data_type,
    default = nothing,
    comment = "",
    needs_conversion = false,
    exclude_setter = false,
    valid_range = nothing,
    validation_action = nothing,
    null_value = nothing,
    internal_default = nothing,
)
    if !isnothing(valid_range) && valid_range isa Dict
        diff = setdiff(keys(valid_range), ("min", "max"))
        !isempty(diff) && error("valid_range only allows 'min' and 'max': $diff")
    end
    if !isnothing(validation_action) && !in(validation_action, ("error", "warn"))
        error("validation_action must be 'error' or 'warn': $validation_action")
    end
    if data_type isa DataType
        data_type = string(data_type)
    end

    if isnothing(null_value)
        if data_type in ("Float32", "Float64")
            null_value = 0.0
        elseif data_type in ("Int", "Integer", "Int32", "Int64")
            null_value = 0
        elseif data_type == "String"
            null_value = "init"
        end
    end

    return StructField(
        name,
        data_type,
        default,
        comment,
        needs_conversion,
        exclude_setter,
        valid_range,
        validation_action,
        internal_default,
        null_value,
    )
end

struct StructDefinition
    struct_name::AbstractString
    fields::Vector{StructField}
    supertype::String
    docstring::AbstractString
end

"""
Construct a StructDefinition for code auto-generation purposes.

# Arguments

  - `struct_name::AbstractString`: Struct name
  - `fields::Vector{StructField}`: Struct fields. Refer to [`StructField`](@ref).
  - `docstring::AbstractString`: Struct docstring. Defaults to an empty string.
  - `supertype::Union{String, DataType}`: Struct supertype. Defaults to no supertype.
  - `is_component::Bool`: Set to true for component types that will be attached to a
    system. Do not set to Default to true.
"""
function StructDefinition(;
    struct_name,
    fields,
    supertype = nothing,
    docstring = "",
    is_component = true,
)
    if supertype isa DataType
        supertype = string(DataType)
    end

    if is_component
        if !any(x -> endswith(x.data_type, "InfrastructureSystemsInternal"), fields)
            push!(
                fields,
                StructField(;
                    name = "internal",
                    data_type = "InfrastructureSystemsInternal",
                    comment = "Internal reference, do not modify.",
                    internal_default = "InfrastructureSystemsInternal()",
                    exclude_setter = true,
                ),
            )
            @info "Added InfrastructureSystemsInternal to component struct $struct_name."
        end
    end

    field_names = Set((x.name for x in fields))
    for field in fields
        if field.valid_range isa String && !in(field.valid_range, field_names)
            error(
                "struct=$struct_name field=$(field.name) has an invalid valid_range=$(field.valid_range)",
            )
        end
    end

    return StructDefinition(struct_name, fields, supertype, docstring)
end

# These allow JSON3 serialization of the structs.
StructTypes.StructType(::Type{StructDefinition}) = StructTypes.Struct()
StructTypes.StructType(::Type{StructField}) = StructTypes.Struct()

"""
Generate a Julia source code file for one struct from a `StructDefinition`.

Refer to `StructDefinition` and `StructField` for descriptions of the available fields.

# Arguments

  - `definition::StructDefinition`: Defines the struct and all fields.
  - `filename::AbstractString`: Add the struct definition to this JSON file. Defaults to
    `src/descriptors/structs.json`
  - `output_directory::AbstractString`: Generate the files in this directory. Defaults to
    `src/generated`
"""
function generate_struct_file(
    definition::StructDefinition;
    filename = nothing,
    output_directory = nothing,
)
    generate_struct_files(
        [definition];
        filename = filename,
        output_directory = output_directory,
    )
end

"""
Generate Julia source code files for multiple structs from a iterable of `StructDefinition`
instances.

Refer to `StructDefinition` and `StructField` for descriptions of the available fields.

# Arguments

  - `definitions`: Defines the structs and all fields.
  - `filename::AbstractString`: Add the struct definition to this JSON file. Defaults to
    `src/descriptors/power_system_structs.json`
  - `output_directory::AbstractString`: Generate the files in this directory. Defaults to
    `src/generated`
"""
function generate_struct_files(definitions; filename = nothing, output_directory = nothing)
    if isnothing(filename)
        filename = joinpath(
            dirname(Base.find_package("InfrastructureSystems")),
            "descriptors",
            "structs.json",
        )
    end
    if isnothing(output_directory)
        output_directory =
            joinpath(dirname(Base.find_package("InfrastructureSystems")), "generated")
    end

    data = open(filename, "r") do io
        JSON3.read(io, Dict)
    end

    # The user might run this multiple times and so we need to remove existing entries.
    new_names = Set((x.struct_name for x in definitions))
    to_remove = Vector{Int}()
    for (i, existing_struct) in enumerate(data["auto_generated_structs"])
        if existing_struct["struct_name"] in new_names
            push!(to_remove, i)
        end
    end
    for i in reverse(to_remove)
        deleteat!(data["auto_generated_structs"], i)
    end

    for def in definitions
        push!(data["auto_generated_structs"], def)
    end

    open(filename, "w") do io
        JSON3.pretty(io, data, JSON3.AlignmentContext(; indent = 2))
    end

    @info "Added $(length(definitions)) structs to $filename"

    generate_structs(filename, output_directory)

    if !isempty(to_remove)
        text = join(new_names, ",")
        @warn "Removed duplicate entries in $filename: $text. Please ensure that this is expected."
    end
end
