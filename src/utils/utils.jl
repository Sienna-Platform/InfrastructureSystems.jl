import InteractiveUtils
import SHA
import JSON

const HASH_FILENAME = "check.sha256"

# Element types the time series store can encode for Deterministic forecast
# windows (see `_storage_forecast_array` in infrastore.jl).
const DETERMINISTIC_SUPPORTED_ELTYPES = [
    "Real (Float64, Int, etc.)",
    "LinearFunctionData",
    "QuadraticFunctionData",
    "PiecewiseLinearData",
    "PiecewiseStepData",
    "NTuple{N, Float64}",
]

"""
Check if the element type T can be encoded by the time series store for
Deterministic forecast windows. Returns true if supported, false otherwise.
"""
is_array_type_supported(::Type{T}) where {T <: Real} = true
is_array_type_supported(::Type{T}) where {T <: LinearFunctionData} = true
is_array_type_supported(::Type{T}) where {T <: QuadraticFunctionData} = true
is_array_type_supported(::Type{T}) where {T <: PiecewiseLinearData} = true
is_array_type_supported(::Type{T}) where {T <: PiecewiseStepData} = true
# Fixed-arity Float64 tuples — the same tuple form the static storage encoding
# supports (`_storage_array` in infrastore.jl).
is_array_type_supported(::Type{NTuple{N, Float64}}) where {N} = true
# Catchall for unsupported types
is_array_type_supported(::Type{T}) where {T} = false

"""
Validate that data in a SortedDict has element types the time series store can
encode. Throws an ArgumentError if any vector has an unsupported element type.
"""
function validate_time_series_data_for_backend(
    ::SortedDict{Dates.DateTime, Vector{T}},
) where {T}
    if !is_array_type_supported(T)
        supported = join(DETERMINISTIC_SUPPORTED_ELTYPES, ", ")
        if !isconcretetype(T)
            throw(
                ArgumentError(
                    "Cannot create time series with non-concrete element type. " *
                    "The data has value type Vector{$T} where $T is not concrete. " *
                    "Please ensure your time series data has a concrete element type like Float64. " *
                    "Supported types: $supported.",
                ),
            )
        else
            throw(
                ArgumentError(
                    "Cannot create time series with unsupported element type $T. " *
                    "Supported types: $supported. " *
                    "Please ensure your time series data has a valid element type like Float64. ",
                ),
            )
        end
    end
    return nothing
end

# Fallback for other SortedDict types - throw error since Deterministic only supports
# SortedDict{Dates.DateTime, Vector{T}} where T is a supported type
function validate_time_series_data_for_backend(data::SortedDict)
    supported = join(DETERMINISTIC_SUPPORTED_ELTYPES, ", ")
    throw(
        ArgumentError(
            "Cannot create time series with this data structure. " *
            "Deterministic only supports SortedDict{Dates.DateTime, Vector{T}} " *
            "where T is a supported element type. " *
            "Supported types: $supported.",
        ),
    )
end

g_cached_subtypes = Dict{DataType, Vector{DataType}}()

"""
Returns an array of all concrete subtypes of T. Caches the values for faster lookup on
repeated calls.

Note that this does not find parameterized types.
It will also not find types dynamically added after the first call of given type.
"""
function get_all_concrete_subtypes(::Type{T}) where {T}
    if haskey(g_cached_subtypes, T)
        return g_cached_subtypes[T]
    end

    sub_types = Vector{DataType}()
    _get_all_concrete_subtypes(T, sub_types)
    g_cached_subtypes[T] = sub_types
    return sub_types
end

"""
Recursively builds a vector of subtypes.
"""
function _get_all_concrete_subtypes(::Type{T}, sub_types::Vector{DataType}) where {T}
    for sub_type in InteractiveUtils.subtypes(T)
        if isconcretetype(sub_type)
            push!(sub_types, sub_type)
        elseif isabstracttype(sub_type)
            _get_all_concrete_subtypes(sub_type, sub_types)
        end
    end

    return nothing
end

"""
Returns the names of all leaf subtypes of T, as Strings.

Unlike [`get_all_concrete_subtypes`](@ref), this includes *parametric* leaf types
(e.g. `SingleTimeSeries`, `ConstantReserveGroup`), which have no concrete `DataType` of
their own but are persisted under their base name. Use this when building type-name
clauses for SQL queries; use `get_all_concrete_subtypes` when the types will be
instantiated, since a parametric type has no instantiable concrete form.
"""
function get_all_subtype_names(::Type{T}) where {T}
    names = Vector{String}()
    _get_all_subtype_names(T, names)
    return names
end

function _get_all_subtype_names(::Type{T}, names::Vector{String}) where {T}
    for sub_type in InteractiveUtils.subtypes(T)
        if isabstracttype(sub_type)
            _get_all_subtype_names(sub_type, names)
        else
            # Concrete types and parametric leaves (`UnionAll`) alike are stored under
            # their base name.
            push!(names, string(nameof(sub_type)))
        end
    end

    return nothing
end

"""
Returns an array of concrete types that are direct subtypes of T.
"""
function get_concrete_subtypes(::Type{T}) where {T}
    return [x for x in InteractiveUtils.subtypes(T) if isconcretetype(x)]
end

"""
Returns an array of abstract types that are direct subtypes of T.
"""
function get_abstract_subtypes(::Type{T}) where {T}
    return [x for x in InteractiveUtils.subtypes(T) if isabstracttype(x)]
end

"""
Returns an array of all super types of T.
"""
function supertypes(::Type{T}, types = []) where {T}
    super = supertype(T)
    push!(types, super)
    if super == Any
        return types
    end

    return supertypes(super, types)
end

"""
Strips the module name off of a type string. This can be useful to print types as strings
and receive consistent results regardless of whether the user used `import` or `using` to
load a package.

Note: This only strips the outermost module name. Module names inside parametric types
(e.g., inside `{...}`) are preserved.

# Examples
```julia-repl
julia> strip_module_name("PowerSystems.HydroDispatch")
"HydroDispatch"
julia> strip_module_name("SingleTimeSeries{PowerSystems.HydroDispatch}")
"SingleTimeSeries{PowerSystems.HydroDispatch}"
```
"""
function strip_module_name(name::String)
    index = findfirst(".", name)
    # Account for the period being part of a parametric type.
    parametric_index = findfirst("{", name)

    if isnothing(index) ||
       (!isnothing(parametric_index) && index.start > parametric_index.start)
        return name
    else
        return name[(index.start + 1):end]
    end
end

"""
Strips the module name off of a type. Unlike the String method, this also strips module
names from type parameters.

# Examples
```julia-repl
julia> strip_module_name(PowerSystems.RegulationDevice{ThermalStandard})
"RegulationDevice{ThermalStandard}"
julia> strip_module_name(VariableReserve{PowerSystems.ReserveUp})
"VariableReserve{ReserveUp}"
```
"""
@generated function strip_module_name(::Type{T}) where {T}
    if T isa Union
        # Fall back to string method for Union types
        return :(strip_module_name(string(T)))
    end
    # A partially-applied parameterized type (e.g. `ReserveDemandCurve{ReserveUp}` when the
    # type carries a further free parameter such as a unit system) is a `UnionAll` and has
    # no `.parameters`. Unwrap it and drop the free `TypeVar`s, keeping the bound parameters
    # so the stripped name stays unique on those (e.g. "ReserveDemandCurve{ReserveUp}").
    base = T isa UnionAll ? Base.unwrap_unionall(T) : T
    name = string(nameof(base))
    params = filter(p -> !(p isa TypeVar), collect(base.parameters))
    if isempty(params)
        return name
    else # I believe there's only 2 parameters, so slightly overkill.
        param_names =
            join([p isa Type ? string(nameof(p)) : string(p) for p in params], ", ")
        return name * "{" * param_names * "}"
    end
end

"""
Return true if all publicly exported names in mod are defined.
"""
function validate_exported_names(mod::Module)
    is_valid = true
    for name in names(mod)
        if !isdefined(mod, name)
            is_valid = false
            @error "module $mod exports $name but does not define it"
        end
    end

    return is_valid
end

# Make match_fn optional
compare_values(x, y; kwargs...) = compare_values(nothing, x, y; kwargs...)

# Get the default match_fn if necessary. Only call when you know you're done recursing
_fetch_match_fn(match_fn::Function) = match_fn
_fetch_match_fn(::Nothing) = isequivalent

# Whether to stop recursing and apply the match_fn. Type-valued fields (e.g.
# `ForecastKey.time_series_type`) are leaves: compare them directly rather than
# recursing into type internals. A concrete type is a `DataType`; an
# unparametrized parametric type (e.g. `Deterministic`) is a `UnionAll` whose
# `fieldnames` (`:var`, `:body`) would otherwise drive a recursion that crashes.
_is_compare_directly(::DataType, ::DataType) = true
_is_compare_directly(::UnionAll, ::UnionAll) = true
_is_compare_directly(::T, ::U) where {T, U} = true
_is_compare_directly(::T, ::T) where {T} = isempty(fieldnames(T))

"""
Recursively compares struct values. Prints all mismatched values to stdout.

# Arguments
  - `match_fn`: optional, a function used to determine whether two values match in the base
    case of the recursion. If `nothing` or not specified, the default implementation uses
    `IS.isequivalent`.
  - `x::T`: First value
  - `y::U`: Second value
  - `compare_uuids::Bool = false`: Compare any UUID in the object or composed objects.
  - `exclude::Set{Symbol} = Set{Symbol}(): Fields to exclude from comparison. Passed on
     recursively and so applied per type.
"""
function compare_values(match_fn::Union{Function, Nothing}, x::T, y::U;
    compare_uuids = false, exclude = Set{Symbol}()) where {T, U}
    _is_compare_directly(x, y) && (return _fetch_match_fn(match_fn)(x, y))

    match = true
    @assert T === U  # other case caught by _is_compare_directly
    fields = fieldnames(T)
    for field_name in fields
        field_name in exclude && continue
        val1 = getproperty(x, field_name)
        val2 = getproperty(y, field_name)
        sub_result = compare_values(match_fn, val1, val2;
            compare_uuids = compare_uuids, exclude = exclude)
        if !sub_result
            @error "values do not match" T field_name val1 val2
            match = false
        end
    end

    return match
end

# compare_values of an AbstractArray: ignore the fields, iterate over all dimensions of the array
function compare_values(
    match_fn::Union{Function, Nothing},
    x::AbstractArray,
    y::AbstractArray;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    if size(x) != size(y)
        @error "sizes do not match" size(x) size(y)
        return false
    end

    match = true
    for i in keys(x)
        if !compare_values(
            match_fn,
            x[i],
            y[i];
            compare_uuids = compare_uuids,
            exclude = exclude,
        )
            @error "values do not match" typeof(x[i]) i x[i] y[i]
            match = false
        end
    end

    return match
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::AbstractDict,
    y::AbstractDict;
    compare_uuids = false,
    exclude = Set{Symbol}(),
)
    keys_x = Set(keys(x))
    keys_y = Set(keys(y))
    if keys_x != keys_y
        @error "keys don't match" keys_x keys_y
        return false
    end

    match = true
    for key in keys_x
        if !compare_values(
            match_fn,
            x[key],
            y[key];
            compare_uuids = compare_uuids,
            exclude = exclude,
        )
            @error "values do not match" typeof(x[key]) key x[key] y[key]
            match = false
        end
    end

    return match
end

# Copied from https://discourse.julialang.org/t/encapsulating-enum-access-via-dot-syntax/11785/10
# Some InfrastructureSystems-specific modifications
"""
Macro to wrap Enum in a module to keep the top level scope clean.

# Examples

```Julia
julia> @scoped_enum Fruit APPLE = 1 ORANGE = 2

julia> value = Fruit.APPLE
Fruit.APPLE = 1

julia> value = Fruit(1)
Fruit.APPLE = 1

julia> @scoped_enum(Fruit,
    APPLE = 1,  # comment
    ORANGE = 2,  # comment
)
```
"""
macro scoped_enum(T, args...)
    hn_methods = Array{Expr}(undef, length(args))
    n2v_methods = Array{Expr}(undef, length(args))
    v2n_methods = Array{Expr}(undef, length(args))
    for (i, p) in enumerate(args)
        _ValKey = Val{first(p.args)}
        _value = Int64(last(p.args))
        hn_methods[i] = :(_hasname(::$_ValKey) = true)
        n2v_methods[i] = :(_name2value(::$_ValKey) = $_value)
        v2n_methods[i] = :(_value2name(::Val{$_value}) = $(String(first(p.args))))
    end
    blk = esc(
        :(
            module $(Symbol("$(T)Module"))
            import InfrastructureSystems
            export $T
            struct $T
                value::Int64
            end

            # A set, implemented by multiple dispatch
            $(hn_methods...)
            _hasname(::Val) = false

            # Some dictionaries, implemented by multiple dispath
            $(n2v_methods...)
            _name2value(name::Symbol) = _name2value(Val(name))
            _name2value(name::String) = _name2value(Symbol(name))

            $(v2n_methods...)
            _value2name(value::Int64) = _value2name(Val{value}())

            const _ALL_NAMES = Tuple(first(x.args) for x in $args)
            const _ALL_INSTANCES = Tuple($T(last(x.args)) for x in $args)

            $T(name::Union{Symbol, String}) = $T(_name2value(name))
            Base.string(e::$T) = _value2name(e.value)
            Base.getproperty(::Type{$T}, sym::Symbol) =
                _hasname(Val(sym)) ? $T(sym) : getfield($T, sym)
            Base.show(io::IO, e::$T) =
                print(io, string($T, ".", string(e), " = ", e.value))
            Base.propertynames(::Type{$T}) = _ALL_NAMES

            InfrastructureSystems.serialize(val::$T) = Base.string(val)
            InfrastructureSystems.serialize(vals::Vector{$T}) =
                InfrastructureSystems.serialize.(vals)
            InfrastructureSystems.deserialize(::Type{$T}, val) = $T(val)
            InfrastructureSystems.deserialize(::Type{Vector{$T}}, vals::Vector) =
                [InfrastructureSystems.deserialize($T, v) for v in vals]

            Base.convert(::Type{$T}, val::Integer) = $T(val)
            Base.isless(val::$T, other::$T) = isless(val.value, other.value)
            Base.instances(::Type{$T}) = _ALL_INSTANCES
            end
        ),
    )
    top = Expr(:toplevel, blk)
    push!(top.args, :(using .$(Symbol("$(T)Module"))))
    return top
end

function compose_function_delegation_string(
    sender_type::String,
    sender_symbol::String,
    argid::Vector{Int},
    method::Method,
)
    s = "p" .* string.(1:(method.nargs - 1))
    s .*= "::" .* string.(fieldtype.(Ref(method.sig), 2:(method.nargs)))
    s[argid] .= "p" .* string.(argid) .* "::$sender_type"

    m = string(method.module.eval(:(parentmodule($(method.name))))) * "."
    l = "$m:(" * string(method.name) * ")(" * join(s, ", ")

    m = string(method.module) * "."
    l *= ") = $m:(" * string(method.name) * ")("
    s = "p" .* string.(1:(method.nargs - 1))

    s[argid] .= "getproperty(" .* s[argid] .* ", :$sender_symbol)"
    l *= join(s, ", ") * ")"
    l = join(split(l, "#"))
    return l
end

function forward(sender::Tuple{Type, Symbol}, ::Type, method::Method)
    # Assert that function is always just one argument
    @assert method.nargs < 4 "`forward` only works for one and two argument functions"
    # Assert that function name always starts with `get_*`
    "`forward` only works for accessor methods that are defined as `get_*` or `set_*`"
    @assert startswith(string(method.name), r"set_|get_")
    sender_type = string(sender[1])
    sender_symbol = string(sender[2])
    code_array = Vector{String}()
    # Search for receiver type in method arguments
    argtype = fieldtype(method.sig, 2)
    (sender[1] == argtype) && (return code_array)
    if string(method.name)[1] == '@'
        @warn "Forwarding macros is not yet supported."
        display(method)
        println()
        return code_array
    end

    # first argument only
    push!(
        code_array,
        compose_function_delegation_string(sender_type, sender_symbol, [1], method),
    )

    tmp = split(string(method.module), ".")[1]
    code =
        "@eval " .* tmp .* " " .* code_array .* " # " .* string(method.file) .* ":" .*
        string(method.line)
    if (tmp != "Base") && (tmp != "Main")
        pushfirst!(code, "using $tmp")
    end
    code = unique(code)
    return code
end

function forward(sender::Tuple{Type, Symbol}, receiver::Type, exclusions::Vector{Symbol})
    @assert isconcretetype(sender[1])
    @assert isconcretetype(receiver)
    code = Vector{String}()
    active_methods = getfield.(InteractiveUtils.methodswith(sender[1]), :name)
    for m in InteractiveUtils.methodswith(receiver)
        m.name ∈ exclusions && continue
        m.name ∈ active_methods && continue
        if startswith(string(m.name), "get_") && m.nargs == 2
            # forwarding works for functions with 1 argument and starts with `get_`
            append!(code, forward(sender, receiver, m))
        elseif startswith(string(m.name), "set_") && m.nargs == 3
            # forwarding works for functions with 2 argument and starts with `set_`
            append!(code, forward(sender, receiver, m))
        end
    end
    return code
end

macro forward(sender, receiver, exclusions = Symbol[])
    out = quote
        list = InfrastructureSystems.forward($sender, $receiver, $exclusions)
        for line in list
            eval(Meta.parse("$line"))
        end
    end
    return esc(out)
end

# Looking up modules with Base.root_module is slow; cache them.
const g_cached_modules = Dict{String, Module}()

function get_module(module_name::AbstractString)
    cached_module = get(g_cached_modules, module_name, nothing)
    if !isnothing(cached_module)
        return cached_module
    end

    # root_module cannot find InfrastructureSystems if it hasn't been installed by the
    # user (but has been installed as a dependency to another package).
    mod = if module_name == "InfrastructureSystems"
        InfrastructureSystems
    else
        Base.root_module(Base.__toplevel__, Symbol(module_name))
    end

    g_cached_modules[module_name] = mod
    return mod
end

get_type_from_strings(module_name, type) =
    getproperty(get_module(module_name), Symbol(type))

# This function is used instead of cp given
# https://github.com/JuliaLang/julia/issues/30723
function copy_file(src::AbstractString, dst::AbstractString)
    src_path = normpath(src)
    dst_path = normpath(dst)
    if Sys.iswindows()
        run(`cmd /c copy /Y $(src_path) $(dst_path)`)
    else
        run(`cp -f $(src_path) $(dst_path)`)
    end
    return
end

to_namedtuple(val) = (; (x => getproperty(val, x) for x in fieldnames(typeof(val)))...)

function compute_file_hash(path::String, files::Vector{String})
    data = Dict("files" => [])
    for file in files
        file_path = joinpath(path, file)
        # Don't put the path in the file so that we can move results directories.
        file_info = Dict("filename" => file, "hash" => compute_sha256(file_path))
        push!(data["files"], file_info)
    end

    open(joinpath(path, HASH_FILENAME), "w") do io
        JSON.json(io, data)
    end
end

function compute_file_hash(path::String, file::String)
    return compute_file_hash(path, [file])
end

"""
Return the SHA 256 hash of a file.
"""
function compute_sha256(filename::AbstractString)
    return open(filename) do io
        return bytes2hex(SHA.sha256(io))
    end
end

convert_for_path(x::Dates.DateTime) = replace(string(x), ":" => "-")

"""
For `a` and `b`, instances of the same concrete type, iterate over all the fields, compare
`a`'s value to `b`'s using `cmp_op`, and reduce to one value using `reduce_op` with an
initialization value of `init`.
"""
function compare_over_fields(cmp_op, reduce_op, init, a::T, b::T) where {T}
    comps = (cmp_op(getfield(a, name), getfield(b, name)) for name in fieldnames(T))
    return reduce(reduce_op, comps; init = init)
end

"Compute the conjunction of the `==` values of all the fields in `a` and `b`"
double_equals_from_fields(a::T, b::T) where {T} =
    compare_over_fields(==, &, true, a, b)

"Compute the conjunction of the `isequal` values of all the fields in `a` and `b`"
isequal_from_fields(a::T, b::T) where {T} =
    compare_over_fields(isequal, &, true, a, b)

"Compute a hash of the instance `a` by combining hashes of all its fields"
hash_from_fields(a) = hash_from_fields(a, zero(UInt))

function hash_from_fields(a, h::UInt)
    for field in sort!(collect(fieldnames(typeof(a))))
        h = hash(getfield(a, field), h)
    end
    return h
end
