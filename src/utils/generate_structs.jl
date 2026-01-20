
import Mustache

# Map conversion_unit to the default natural Unitful unit for getters
const NATURAL_UNIT_MAP = Dict{String, String}(
    ":mva" => "MW",           # Power → MW (default for :mva)
    ":ohm" => "OHMS",         # Impedance → Ohms
    ":siemens" => "SIEMENS",  # Admittance → Siemens
)

# Determine the natural unit based on conversion_unit and field name
function get_natural_unit(conversion_unit::String, field_name::String)
    if conversion_unit == ":mva"
        # Reactive power fields use Mvar instead of MW
        if occursin("reactive", lowercase(field_name))
            return "Mvar"
        else
            return "MW"
        end
    end
    return get(NATURAL_UNIT_MAP, conversion_unit, "MW")
end

const STRUCT_TEMPLATE = """
#=
This file is auto-generated. Do not edit.
=#

#! format: off

\"\"\"
    mutable struct {{struct_name}}{{#parametric}}{T <: {{parametric}}}{{/parametric}} <: {{supertype}}
        {{#parameters}}
        {{name}}::{{{data_type}}}
        {{/parameters}}
    end

{{#docstring}}{{{docstring}}}{{/docstring}}

# Arguments
{{#parameters}}
- `{{name}}::{{{data_type}}}`:{{#default}} (default: `{{{default}}}`){{/default}}{{#comment}} {{{comment}}}{{/comment}}{{#valid_range}}, validation range: `{{{valid_range}}}`{{/valid_range}}
{{/parameters}}
\"\"\"
mutable struct {{struct_name}}{{#parametric}}{T <: {{parametric}}}{{/parametric}} <: {{supertype}}
    {{#parameters}}
    {{#comment}}"{{{comment}}}"\n    {{/comment}}{{name}}::{{{data_type}}}
    {{/parameters}}
    {{#inner_constructor_check}}

    function {{struct_name}}({{#parameters}}{{name}}, {{/parameters}})
        ({{#parameters}}{{name}}, {{/parameters}}) = {{inner_constructor_check}}(
            {{#parameters}}
            {{name}},
            {{/parameters}}
        )
        new({{#parameters}}{{name}}, {{/parameters}})
    end
    {{/inner_constructor_check}}
end

{{#needs_positional_constructor}}
function {{constructor_func}}({{#parameters}}{{^internal_default}}{{name}}{{#default}}={{default}}{{/default}}, {{/internal_default}}{{/parameters}}){{{closing_constructor_text}}}
    {{constructor_func}}({{#parameters}}{{^internal_default}}{{name}}, {{/internal_default}}{{/parameters}}{{#parameters}}{{#internal_default}}{{{internal_default}}}, {{/internal_default}}{{/parameters}})
end
{{/needs_positional_constructor}}

function {{constructor_func}}(; {{#parameters}}{{name}}{{#kwarg_value}}{{{kwarg_value}}}{{/kwarg_value}}, {{/parameters}}){{{closing_constructor_text}}}
    {{constructor_func}}({{#parameters}}{{name}}, {{/parameters}})
end

{{#has_null_values}}
# Constructor for demo purposes; non-functional.
function {{constructor_func}}(::Nothing){{{closing_constructor_text}}}
    {{constructor_func}}(;
        {{#parameters}}
        {{^internal_default}}
        {{name}}={{#quotes}}"{{null_value}}"{{/quotes}}{{^quotes}}{{null_value}}{{/quotes}},
        {{/internal_default}}
        {{/parameters}}
    )
end

{{/has_null_values}}
{{#accessors}}
{{#needs_conversion}}
{{#create_docstring}}\"\"\"Get [`{{struct_name}}`](@ref) `{{name}}`. Returns natural units ({{natural_unit}}) by default.\"\"\"{{/create_docstring}}
{{accessor}}(value::{{struct_name}}) = get_value(value, Val(:{{name}}), Val({{conversion_unit}}), {{natural_unit}})
{{accessor}}(value::{{struct_name}}, units) = get_value(value, Val(:{{name}}), Val({{conversion_unit}}), units)
{{/needs_conversion}}
{{^needs_conversion}}
{{#create_docstring}}\"\"\"Get [`{{struct_name}}`](@ref) `{{name}}`.\"\"\"{{/create_docstring}}
{{accessor}}(value::{{struct_name}}) = value.{{name}}
{{/needs_conversion}}
{{/accessors}}

{{#setters}}
{{#needs_conversion}}
{{#create_docstring}}\"\"\"Set [`{{struct_name}}`](@ref) `{{name}}`. Value must have units (e.g., `30.0MW`, `0.5DU`).\"\"\"{{/create_docstring}}
{{setter}}(value::{{struct_name}}, val) = value.{{name}} = set_value(value, Val(:{{name}}), val, Val({{conversion_unit}}))
{{/needs_conversion}}
{{^needs_conversion}}
{{#create_docstring}}\"\"\"Set [`{{struct_name}}`](@ref) `{{name}}`.\"\"\"{{/create_docstring}}
{{setter}}(value::{{struct_name}}, val) = value.{{name}} = val
{{/needs_conversion}}
{{/setters}}

{{#custom_code}}
{{{custom_code}}}
{{/custom_code}}
"""

function read_json_data(filename::String)
    return open(filename) do io
        data = JSON3.read(io, Dict)
        if data isa Array
            return data
        elseif data isa Dict && haskey(data, "auto_generated_structs")
            return data["auto_generated_structs"]
        else
            throw(DataFormatError("$filename has invalid format"))
        end
    end
end

function generate_structs(directory, data::Vector; print_results = true)
    struct_names = Vector{String}()
    unique_accessor_functions = Set{String}()
    unique_setter_functions = Set{String}()

    for item in data
        has_internal = false
        accessors = Vector{Dict}()
        setters = Vector{Dict}()
        item["has_null_values"] = true
        has_non_default_values = false

        item["constructor_func"] = item["struct_name"]
        item["closing_constructor_text"] = ""
        if haskey(item, "parametric")
            item["constructor_func"] *= "{T}"
            item["closing_constructor_text"] = " where T <: $(item["parametric"])"
        end

        parameters = Vector{Dict}()
        for field in item["fields"]
            param = field
            param["struct_name"] = item["struct_name"]
            if haskey(param, "valid_range")
                if typeof(param["valid_range"]) == Dict{String, Any}
                    min = param["valid_range"]["min"]
                    max = param["valid_range"]["max"]
                    param["valid_range"] = "($min, $max)"
                elseif typeof(param["valid_range"]) == String
                    param["valid_range"] = param["valid_range"]
                end
            end
            if haskey(param, "default")
                param["default"] = string(param["default"])
            end
            push!(parameters, param)

            # Allow accessor functions to be re-implemented from another module.
            # If this key is defined then the accessor function will not be exported.
            # Example:  get_name is defined in InfrastructureSystems and re-implemented in
            # PowerSystems.
            if haskey(param, "accessor_module")
                accessor_module = param["accessor_module"] * "."
                create_docstring = false
            else
                accessor_module = ""
                create_docstring = true
            end
            accessor_name = accessor_module * "get_" * param["name"]
            setter_name = accessor_module * "set_" * param["name"] * "!"
            conversion_unit = get(param, "conversion_unit", "nothing")
            natural_unit = get_natural_unit(conversion_unit, param["name"])
            push!(
                accessors,
                Dict(
                    "name" => param["name"],
                    "accessor" => accessor_name,
                    "create_docstring" => create_docstring,
                    "needs_conversion" => get(param, "needs_conversion", false),
                    "conversion_unit" => conversion_unit,
                    "natural_unit" => natural_unit,
                ),
            )
            include_setter = !get(param, "exclude_setter", false)
            if include_setter
                push!(
                    setters,
                    Dict(
                        "name" => param["name"],
                        "setter" => setter_name,
                        "data_type" => param["data_type"],
                        "create_docstring" => create_docstring,
                        "needs_conversion" => get(param, "needs_conversion", false),
                        "conversion_unit" => conversion_unit,
                    ),
                )
            end
            if field["name"] != "internal" && accessor_module == ""
                push!(unique_accessor_functions, accessor_name)
                push!(unique_setter_functions, setter_name)
            end

            param["kwarg_value"] = ""
            if !isnothing(get(param, "default", nothing))
                param["kwarg_value"] = "=" * param["default"]
            elseif !isnothing(get(param, "internal_default", nothing))
                param["kwarg_value"] = "=" * string(param["internal_default"])
                has_internal = true
                continue
            else
                has_non_default_values = true
            end

            # This controls whether a demo constructor will be generated.
            if isnothing(get(param, "null_value", nothing)) &&
               isnothing(get(param, "default", nothing))
                item["has_null_values"] = false
            else
                if isnothing(get(param, "null_value", nothing))
                    item["null_value"] = param["default"]
                end
                if param["data_type"] == "String"
                    param["quotes"] = true
                end
            end
        end

        item["parameters"] = parameters
        item["accessors"] = accessors
        item["setters"] = setters
        # If all parameters have defaults then the positional constructor will
        # collide with the kwarg constructor.
        item["needs_positional_constructor"] = has_internal && has_non_default_values

        filename = joinpath(directory, item["struct_name"] * ".jl")
        open(filename, "w") do io
            write(io, strip(Mustache.render(STRUCT_TEMPLATE, item)))
            write(io, "\n")
            push!(struct_names, item["struct_name"])
        end

        if print_results
            println("Wrote $filename")
        end
    end

    accessors = sort!(collect(unique_accessor_functions))
    setters = sort!(collect(unique_setter_functions))
    filename = joinpath(directory, "includes.jl")
    open(filename, "w") do io
        for name in struct_names
            write(io, "include(\"$name.jl\")\n")
        end
        write(io, "\n")

        for accessor in accessors
            write(io, "export $accessor\n")
        end
        for setter in setters
            write(io, "export $setter\n")
        end
        if print_results
            println("Wrote $filename")
        end
    end
end

function generate_structs(
    input_file::AbstractString,
    output_directory::AbstractString;
    print_results = true,
)
    # Include each generated file.
    if !isdir(output_directory)
        mkdir(output_directory)
    end

    data = read_json_data(input_file)
    generate_structs(output_directory, data; print_results = print_results)
    return
end

"""
Return true if the structs defined in `existing_dir` match structs freshly generated from
`descriptor_file`.
"""
function test_generated_structs(descriptor_file, existing_dir)
    output_dir = mktempdir()

    generate_structs(descriptor_file, output_dir; print_results = false)

    matched = true
    for (file1, file2) in zip(readdir(output_dir), readdir(existing_dir))
        path1 = joinpath(output_dir, file1)
        path2 = joinpath(existing_dir, file2)
        for (line1, line2) in zip(readlines(path1), readlines(path2))
            # Note: must strip the line endings.
            line1 = strip(line1)
            line2 = strip(line2)
            if line1 != line2
                @error "Generated structs do not match descriptor file" file1 line1 line2
                matched = false
                # Every line will now fail. Trying to use system utilities like diff didn't
                # work well across platforms.
                break
            end
        end
    end

    rm(output_dir; recursive = true)
    return matched
end
