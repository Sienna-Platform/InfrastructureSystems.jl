
import Mustache

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
{{#create_docstring}}\"\"\"Get [`{{struct_name}}`](@ref) `{{name}}` as a bare number in the requested `units` (e.g. `SU`, `DU`; domain-provided units such as `MW` are also accepted when the owning domain package has registered a `_strip_units` method for the returned quantity type). Returns a bare number only when such a method is registered; otherwise returns the quantity wrapper. For the unit-bearing value see [`{{accessor}}_unitful`](@ref).\"\"\"{{/create_docstring}}
{{accessor}}(value::{{struct_name}}, units) = InfrastructureSystems._strip_units(get_value(value, Val(:{{name}}), Val({{conversion_unit}}), units))
{{#create_docstring}}\"\"\"Get [`{{struct_name}}`](@ref) `{{name}}` as a unit-bearing quantity in the requested `units` (e.g. `SU`, `DU`, `MW`). For a bare number see [`{{accessor}}`](@ref).\"\"\"{{/create_docstring}}
{{accessor}}_unitful(value::{{struct_name}}, units) = get_value(value, Val(:{{name}}), Val({{conversion_unit}}), units)
InfrastructureSystems.display_units_arg(::typeof({{accessor}}), ::{{units_type_sig}}){{#units_bound}} where {T <: {{units_bound}}}{{/units_bound}} = InfrastructureSystems.{{display_units}}
InfrastructureSystems.display_units_arg(::typeof({{accessor}}_unitful), ::{{units_type_sig}}){{#units_bound}} where {T <: {{units_bound}}}{{/units_bound}} = InfrastructureSystems.{{display_units}}
{{/needs_conversion}}
{{^needs_conversion}}
{{#create_docstring}}\"\"\"Get [`{{struct_name}}`](@ref) `{{name}}`.\"\"\"{{/create_docstring}}
{{accessor}}(value::{{struct_name}}) = value.{{name}}
{{/needs_conversion}}
{{/accessors}}

{{#setters}}
{{#needs_conversion}}
{{#create_docstring}}\"\"\"Set [`{{struct_name}}`](@ref) `{{name}}`.\"\"\"{{/create_docstring}}
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

{{#openapi_type}}
{{#openapi_enum_tables}}
const {{const_name}} = Dict{String, {{{enum_type}}}}(string(m) => m for m in instances({{{enum_type}}}))
{{/openapi_enum_tables}}

function from_openapi(::{{{openapi_type_annotation}}}, po, refs::OpenAPIRefs, ::Val{:DEVICE_BASE})
    return {{struct_name}}(;
        {{#openapi_kwargs_device}}
        {{name}} = {{{expr}}},
        {{/openapi_kwargs_device}}
    )
end

function from_openapi(::{{{openapi_type_annotation}}}, po, refs::OpenAPIRefs, ::Val{:NATURAL_UNITS})
    return {{struct_name}}(;
        {{#openapi_kwargs_natural}}
        {{name}} = {{{expr}}},
        {{/openapi_kwargs_natural}}
    )
end
{{/openapi_type}}
"""

# --------------------------------------------------------------------------------------
# OpenAPI import-direction converter generation (converter-plan Task 1:
# `.claude/plans/2026-08-03-openapi-to-psy-generated-converter-plan.md` §7/§8).
#
# A descriptor entry carrying a top-level `openapi_type` key gets `from_openapi` methods
# appended to its generated file, one per unit system (`Val{:DEVICE_BASE}` pass-through,
# `Val{:NATURAL_UNITS}` with the §8 conversion arithmetic inlined). The generic
# `from_openapi` function, `OpenAPIRefs`, `convert_cost`, and the PO modules are all
# defined in PowerSystems, not here — this generator only emits methods that compile
# against them.
#
# `po` is left untyped. Annotating it would require this generator to name the PO
# module, which would either hardcode a package name IS does not depend on or force IS
# to depend on the OpenAPI model packages — neither acceptable (the plan requires IS stay
# free of OpenAPI deps). Dispatch is already unambiguous on `Type{...}`/`Val{...}` alone.
#
# A descriptor entry without `openapi_type` never reaches any function below — every one
# is only called from `compute_openapi_converter!`, itself only called when
# `haskey(item, "openapi_type")` — which is what keeps Task 1 byte-identical for the 133
# untouched types.
# --------------------------------------------------------------------------------------

const OPENAPI_SKIP_FIELDS = Set(["ext", "internal", "services", "dynamic_injector"])
const OPENAPI_SCALAR_TYPES = Set(["Float64", "Int", "Int32", "Int64", "String", "Bool"])
const OPENAPI_COMPOUND_MEMBERS = Dict(
    "MinMax" => ("min", "max"),
    "UpDown" => ("up", "down"),
    "FromTo" => ("from", "to"),
    "InOut" => ("in", "out"),
)
const OPENAPI_CONVERSION_KINDS =
    Dict(":mva" => :power, ":ohm" => :impedance, ":siemens" => :admittance)

"""Split `Union{Nothing, X}` into `(X, true)`; any other type string is `(type, false)`."""
function openapi_strip_nullable(data_type::AbstractString)
    m = match(r"^Union\{Nothing,\s*(.+)\}$", data_type)
    if isnothing(m)
        return (data_type, false)
    end
    return (String(m.captures[1]), true)
end

openapi_enum_table_name(bare::AbstractString) = uppercase(bare) * "_FROM_STRING"

"""
Classify one field's role in an OpenAPI converter. Returns `(kind, bare, nullable)` with
`kind` one of `:skip`, `:cost`, `:scalar`, `:compound`, `:reference`, `:enum`.

Raises `DataFormatError` — never returns a partial/guessed classification — when `bare`
is neither a scalar, a known compound alias, a component struct defined in this same
descriptor, nor a plausible bare enum type identifier (e.g. `Complex{Float64}`,
`Tuple{...}`, a `Union` of concrete curve types all fail this last check).
"""
function openapi_classify_field(struct_name, field, struct_names)
    name = field["name"]
    if name in OPENAPI_SKIP_FIELDS
        return (:skip, field["data_type"], false)
    end
    if name == "operation_cost"
        return (:cost, field["data_type"], false)
    end
    bare, nullable = openapi_strip_nullable(field["data_type"])
    if bare in OPENAPI_SCALAR_TYPES
        return (:scalar, bare, nullable)
    end
    if haskey(OPENAPI_COMPOUND_MEMBERS, bare)
        return (:compound, bare, nullable)
    end
    if bare in struct_names
        return (:reference, bare, nullable)
    end
    if !occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", bare)
        throw(
            DataFormatError(
                "openapi_type=$struct_name field=$name data_type=$(field["data_type"]) " *
                "has no determinable OpenAPI converter kind (not scalar, compound, a " *
                "component reference, or a plausible scoped-enum type name)",
            ),
        )
    end
    return (:enum, bare, nullable)
end

"""
Validate a field's optional `openapi_unit` override. Only `"pu"` is recognized: it means
the OpenAPI document already carries this field per-unit (its schema `x-unit` is `pu`, not
a natural unit), so a `conversion_unit`-driven division/multiplication would double-convert
it — e.g. `Line.r`/`x`/`b`/`g`, which carry `needs_conversion` + `:ohm`/`:siemens` for PSY's
own SU/DU accessor machinery, but are pu in the document. SiennaSchemas' parity checker is
the intended place to cross-check `"pu"` against the schema's declared `x-unit`; this
generator only recognizes the one value and raises on anything else — never guesses.

Returns `true` when the override applies (skip the §8 arithmetic in both unit-system
methods), `false` when the key is absent. Runs — and can raise — regardless of the field's
converter `kind`; only `:scalar`/`:compound` fields act on a `true` result.
"""
function openapi_validate_unit_override(struct_name, field)
    if !haskey(field, "openapi_unit")
        return false
    end
    value = field["openapi_unit"]
    if value != "pu"
        throw(
            DataFormatError(
                "struct=$struct_name field=$(field["name"]) has unmapped " *
                "openapi_unit=$value (only \"pu\" is supported)",
            ),
        )
    end
    return true
end

"""
`openapi_unit` is only meaningful on a struct carrying `openapi_type` — nothing reads it
otherwise, so it is stray descriptor noise rather than a silent no-op. Runs for every item,
regardless of annotation; only raises when the (brand new, opt-in) key is actually present,
so an unannotated entry with no `openapi_unit` fields is untouched.
"""
function openapi_check_no_orphan_unit!(item)
    if haskey(item, "openapi_type")
        return nothing
    end
    struct_name = item["struct_name"]
    for field in item["fields"]
        if haskey(field, "openapi_unit")
            throw(
                DataFormatError(
                    "struct=$struct_name field=$(field["name"]) has openapi_unit=" *
                    "$(field["openapi_unit"]) but the struct has no openapi_type; " *
                    "openapi_unit is only meaningful on an annotated struct",
                ),
            )
        end
    end
    return nothing
end

"""
Classify the natural-units conversion rule for a scalar/compound field from the existing
`needs_conversion` + `conversion_unit` descriptor keys (converter-plan §8). Returns
`:none`, `:power`, `:impedance`, or `:admittance`.
"""
function openapi_natural_conversion(struct_name, field)
    if !get(field, "needs_conversion", false)
        return :none
    end
    conversion_unit = get(field, "conversion_unit", nothing)
    kind = get(OPENAPI_CONVERSION_KINDS, conversion_unit, nothing)
    if isnothing(kind)
        throw(
            DataFormatError(
                "openapi_type=$struct_name field=$(field["name"]) has needs_conversion=true " *
                "with an unmapped conversion_unit=$conversion_unit",
            ),
        )
    end
    return kind
end

"""
S_base/Z_base source expressions for the §8 conversion arithmetic, requiring the
struct's own `base_power`/`base_voltage` fields (§8: `S_base = po.base_power`;
`Z_base = V_base^2 / S_base`). Resolving `V_base` through a component reference (e.g.
`Line` → its arc's from-bus) is a documented gap in this generator pass — see the R4
flag in the agent report; raise rather than guess.
"""
function openapi_base_exprs(struct_name, field_name, conversion, field_names)
    if conversion == :power
        if !("base_power" in field_names)
            throw(
                DataFormatError(
                    "openapi_type=$struct_name field=$field_name needs S_base for a " *
                    ":power conversion but the struct has no base_power field",
                ),
            )
        end
        return (s_base = "po.base_power", z_base = nothing)
    end
    if conversion in (:impedance, :admittance)
        if !("base_power" in field_names) || !("base_voltage" in field_names)
            throw(
                DataFormatError(
                    "openapi_type=$struct_name field=$field_name needs V_base/S_base for " *
                    "a $conversion conversion but the struct has no base_voltage/base_power " *
                    "field on itself; resolving V_base through a component reference is " *
                    "not implemented in this generator pass",
                ),
            )
        end
        return (s_base = "po.base_power", z_base = "(po.base_voltage^2 / po.base_power)")
    end
    return (s_base = nothing, z_base = nothing)
end

"""Device-base is always pass-through (converter-plan §8); only the natural-units
expression varies with `conversion`. A nullable field with a real conversion needs a
nothing-guard (mirrors `scale_optional` in the verified `rts_openapi_roundtrip.jl`
reference); a nullable field with no conversion does not (mirrors plain `po.angle`-style
passthrough there) since scalar field access on `nothing` is never attempted."""
function openapi_scalar_exprs(field_name, conversion, nullable, bases)
    device = "po.$field_name"
    if conversion == :none
        return (device, device)
    end
    scaled = if conversion == :power
        "po.$field_name / $(bases.s_base)"
    elseif conversion == :impedance
        "po.$field_name / $(bases.z_base)"
    else
        "po.$field_name * $(bases.z_base)"
    end
    if !nullable
        return (device, scaled)
    end
    natural = "(if isnothing(po.$field_name); nothing; else; $scaled; end)"
    return (device, natural)
end

"""Compound fields always get member-rebuilt in both methods — the PO struct's compound
type is never PSY's `NamedTuple` alias, so even device-base is not a bare `po.<name>`
passthrough (mirrors `minmax`/`updown`/`fromto` in the reference). A nullable compound
additionally needs a nothing-guard in *both* methods, since member access on `nothing`
errors regardless of unit system (mirrors `opt_minmax`/`minmax_du` there)."""
function openapi_compound_exprs(field_name, members, conversion, nullable, bases)
    device_body = "(" * join(("$m = po.$field_name.$m" for m in members), ", ") * ")"
    natural_body = if conversion == :none
        device_body
    elseif conversion == :power
        "(" *
        join(("$m = po.$field_name.$m / $(bases.s_base)" for m in members), ", ") *
        ")"
    elseif conversion == :impedance
        "(" *
        join(("$m = po.$field_name.$m / $(bases.z_base)" for m in members), ", ") *
        ")"
    else
        "(" *
        join(("$m = po.$field_name.$m * $(bases.z_base)" for m in members), ", ") *
        ")"
    end
    if !nullable
        return (device_body, natural_body)
    end
    device = "(if isnothing(po.$field_name); nothing; else; $device_body; end)"
    natural = "(if isnothing(po.$field_name); nothing; else; $natural_body; end)"
    return (device, natural)
end

"""
Compute and attach the OpenAPI import-direction converter data for one annotated
descriptor entry (mutates `item`). Only called when `haskey(item, "openapi_type")`; a
descriptor entry without that key never reaches this function.

`defined_enum_tables` is shared across the whole `generate_structs` call so an enum type
used by more than one annotated struct gets exactly one `const ..._FROM_STRING` table
(in whichever struct's file is processed first) instead of a duplicate-`const` error when
every generated file is `include`d into the same module.
"""
function compute_openapi_converter!(item, struct_names, defined_enum_tables)
    struct_name = item["struct_name"]
    if haskey(item, "parametric")
        throw(
            DataFormatError(
                "openapi_type=$struct_name is parametric ($(item["parametric"])); " *
                "parametric OpenAPI converters are not implemented in this generator pass",
            ),
        )
    end
    field_names = Set(f["name"] for f in item["fields"])
    enum_tables = Vector{Dict{String, String}}()
    kwargs_device = Vector{Dict{String, String}}()
    kwargs_natural = Vector{Dict{String, String}}()

    for field in item["fields"]
        name = field["name"]
        kind, bare, nullable = openapi_classify_field(struct_name, field, struct_names)
        pu_override = openapi_validate_unit_override(struct_name, field)
        if kind == :skip
            continue
        end
        if kind == :cost
            expr = "convert_cost(po.$name)"
            push!(kwargs_device, Dict("name" => name, "expr" => expr))
            push!(kwargs_natural, Dict("name" => name, "expr" => expr))
            continue
        end
        if kind == :reference
            expr = "refs[po.$name]"
            push!(kwargs_device, Dict("name" => name, "expr" => expr))
            push!(kwargs_natural, Dict("name" => name, "expr" => expr))
            continue
        end
        if kind == :enum
            table_name = openapi_enum_table_name(bare)
            if !(table_name in defined_enum_tables)
                push!(enum_tables, Dict("const_name" => table_name, "enum_type" => bare))
                push!(defined_enum_tables, table_name)
            end
            expr = "$table_name[po.$name]"
            push!(kwargs_device, Dict("name" => name, "expr" => expr))
            push!(kwargs_natural, Dict("name" => name, "expr" => expr))
            continue
        end
        conversion = if pu_override
            :none
        else
            openapi_natural_conversion(struct_name, field)
        end
        bases = openapi_base_exprs(struct_name, name, conversion, field_names)
        if kind == :scalar
            device, natural = openapi_scalar_exprs(name, conversion, nullable, bases)
        else
            members = OPENAPI_COMPOUND_MEMBERS[bare]
            device, natural =
                openapi_compound_exprs(name, members, conversion, nullable, bases)
        end
        push!(kwargs_device, Dict("name" => name, "expr" => device))
        push!(kwargs_natural, Dict("name" => name, "expr" => natural))
    end

    item["openapi_type_annotation"] = "Type{$struct_name}"
    item["openapi_enum_tables"] = enum_tables
    item["openapi_kwargs_device"] = kwargs_device
    item["openapi_kwargs_natural"] = kwargs_natural
    return nothing
end

function read_json_data(filename::String)
    return open(filename) do io
        data = JSON.parse(io; dicttype = Dict{String, Any})
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
    openapi_struct_names = Set(it["struct_name"] for it in data)
    openapi_defined_enum_tables = Set{String}()

    for item in data
        openapi_check_no_orphan_unit!(item)
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
            include_getter = !get(param, "exclude_getter", false)
            if include_getter
                push!(
                    accessors,
                    Dict(
                        "name" => param["name"],
                        "accessor" => accessor_name,
                        "create_docstring" => create_docstring,
                        "needs_conversion" => get(param, "needs_conversion", false),
                        "conversion_unit" => conversion_unit,
                        # Units argument used when displaying the field (tables, REPL);
                        # override per field in the descriptor with "display_units".
                        "display_units" => get(param, "display_units", "SU"),
                        # The units trait dispatches on the component's concrete
                        # type, so parametric structs need the `Type{Name{T}} where`
                        # form (`Type{Name}` is the UnionAll and never matches a
                        # concrete `Name{...}`); concrete structs use the exact form.
                        "units_type_sig" => if haskey(item, "parametric")
                            "Type{$(item["struct_name"]){T}}"
                        else
                            "Type{$(item["struct_name"])}"
                        end,
                        # The bound is substituted inside a literal `where {T <: …}`
                        # template fragment (values get HTML-escaped; literals don't).
                        "units_bound" => get(item, "parametric", false),
                    ),
                )
            else
                internal_name = "_get_" * param["name"]
                push!(
                    accessors,
                    Dict(
                        "name" => param["name"],
                        "accessor" => internal_name,
                        "create_docstring" => false,
                        "needs_conversion" => false,
                        "conversion_unit" => "nothing",
                    ),
                )
            end
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
                # exclude_getter/exclude_setter mean "hand-written elsewhere" (e.g.
                # unit-aware accessors with different signatures), not "nonexistent" —
                # always export the public name.
                push!(unique_accessor_functions, accessor_name)
                push!(unique_setter_functions, setter_name)
                # The `_unitful` companion is exported only when the getter is
                # actually generated. For exclude_getter fields we emit just the
                # private `_get_X` (needs_conversion forced false), so `_get_X_unitful`
                # is never generated — PowerSystems hand-writes both `get_X` and
                # `get_X_unitful` for those fields itself. Gating this export on
                # needs_conversion alone would make IS export a `_unitful` symbol it
                # never defined, colliding with PSY's hand-written one — coordinate
                # with PSY before widening.
                if include_getter && get(param, "needs_conversion", false)
                    push!(unique_accessor_functions, accessor_name * "_unitful")
                end
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

        if haskey(item, "openapi_type")
            compute_openapi_converter!(
                item,
                openapi_struct_names,
                openapi_defined_enum_tables,
            )
        end

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
