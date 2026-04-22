import InteractiveUtils
import SHA
import JSON

const HASH_FILENAME = "check.sha256"
const COMPARE_VALUES_SENTINEL = :(!NOUPGRADE)  # A Symbol that can't be a field name

# Supported element types for transform_array_for_hdf Vector inputs
const TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES = [
    "Real (Float64, Int, etc.)",
    "Tuple",
    "Vector{Tuple}",
    "Matrix",
    "LinearFunctionData",
    "QuadraticFunctionData",
    "PiecewiseLinearData",
    "PiecewiseStepData",
]

"""
Check if the element type T is supported by transform_array_for_hdf.
Returns true if supported, false otherwise.
Uses multiple dispatch for a more Julian approach.
"""
is_transform_array_for_hdf_supported(::Type{T}) where {T <: Real} = true
is_transform_array_for_hdf_supported(::Type{T}) where {T <: Tuple} = isconcretetype(T)
is_transform_array_for_hdf_supported(::Type{T}) where {T <: Vector{<:Tuple}} =
    isconcretetype(T)
is_transform_array_for_hdf_supported(::Type{T}) where {T <: Matrix} = true
is_transform_array_for_hdf_supported(::Type{T}) where {T <: LinearFunctionData} = true
is_transform_array_for_hdf_supported(::Type{T}) where {T <: QuadraticFunctionData} = true
is_transform_array_for_hdf_supported(::Type{T}) where {T <: PiecewiseLinearData} = true
is_transform_array_for_hdf_supported(::Type{T}) where {T <: PiecewiseStepData} = true
# Catchall for unsupported types
is_transform_array_for_hdf_supported(::Type{T}) where {T} = false

"""
Validate that data in a SortedDict has supported element types for transform_array_for_hdf.
Throws an ArgumentError if any vector has an unsupported element type.
"""
function validate_time_series_data_for_hdf(
    ::SortedDict{Dates.DateTime, Vector{T}},
) where {T}
    if !is_transform_array_for_hdf_supported(T)
        supported = join(TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES, ", ")
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
function validate_time_series_data_for_hdf(data::SortedDict)
    supported = join(TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES, ", ")
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
    name = string(nameof(T))
    if isempty(T.parameters)
        return name
    else # I believe there's only 2 parameters, so slightly overkill.
        param_names = join([string(nameof(p)) for p in T.parameters], ", ")
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

# Whether to stop recursing and apply the match_fn
_is_compare_directly(::DataType, ::DataType) = true
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
    # Special case: if match_fn is nothing, try calling the two-argument version to maintain
    # backwards compatibility with packages that only implement that. Keep track of this to
    # avoid infinite recursion. TODO remove in next major version
    if isnothing(match_fn) && !(COMPARE_VALUES_SENTINEL in exclude)
        return compare_values(x, y; compare_uuids = compare_uuids,
            exclude = union(exclude, [COMPARE_VALUES_SENTINEL]))
    end
    exclude = setdiff(exclude, [COMPARE_VALUES_SENTINEL])

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

function transform_array_for_hdf(data::SortedDict{Dates.DateTime, Vector{CONSTANT}})
    return hcat(values(data)...)
end

function transform_array_for_hdf(data::AbstractVector{T}) where {T <: Number}
    return transform_array_for_hdf(convert(Vector{T}, data))
end

function transform_array_for_hdf(data::Vector{<:Real})
    return data
end

function transform_array_for_hdf(data::Vector{T}) where {T <: Tuple}
    rows = length(data)
    degree = fieldcount(T)  # 2 for linear, 3 for quadratic
    t_lin_cost = Array{Float64}(undef, rows, degree)
    for r in 1:rows
        t_lin_cost[r, :] = collect(data[r])
    end
    return t_lin_cost
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, Vector{T}},
) where {T <: Tuple}
    lin_cost = hcat(values(data)...)
    rows, cols = size(lin_cost)
    degree = fieldcount(T)  # 2 for linear, 3 for quadratic
    t_lin_cost = Array{Float64}(undef, rows, cols, degree)
    for r in 1:rows, c in 1:cols
        t_lin_cost[r, c, :] = collect(lin_cost[r, c])
    end
    return t_lin_cost
end

_elem_to_pad_for_hdf(::Type{Tuple{Float64, Float64}}) = (NaN, NaN)
_elem_to_pad_for_hdf(::Type{Float64}) = NaN

function _pad_fd_for_hdf(data::Array{T}, max_length) where {T}
    data_length = first(size(data))
    max_length >= data_length ||
        throw(
            ArgumentError("max_length must be greater than or equal to the length of data"),
        )
    data_other_dims = size(data)[2:end]
    padding_shape = (max_length - data_length, data_other_dims...)
    padding = fill(_elem_to_pad_for_hdf(T), padding_shape)
    return vcat(data, padding)
end

function _pad_array_for_hdf(data::Vector{<:Array{T}}, max_length) where {T}
    result = _pad_fd_for_hdf.(data, max_length)
    return result
end

# entry point for the vector of FunctionData case
_pad_array_for_hdf(data::Vector{<:Array{T}}) where {T} =
    _pad_array_for_hdf(data, maximum(length.(data)))

# entry point for the SortedDict of vector of FunctionData case
_pad_arrays_for_hdf(data) =
    _pad_array_for_hdf.(data, maximum((x -> maximum(length.(x))).(data)))

function _unpad_array_for_hdf(data::AbstractArray{T}) where {T}
    pad_elem = _elem_to_pad_for_hdf(T)
    # find last slice for which it is not the case that everything is padding
    last_valid = findlast(x -> !all(isequal(pad_elem), x), eachslice(data; dims = 1))
    return selectdim(data, 1, 1:last_valid)
end

function transform_array_for_hdf(data::Vector{<:Vector{<:Tuple}})
    data = _pad_array_for_hdf(data)
    rows = length(data)
    n_points = length(first(data))
    @assert all(length.(data) .== n_points)  # because we padded
    @assert_op length(first(first(data))) == 2  # should be just (x, y)
    t_quad_cost = Array{Float64}(undef, rows, n_points, 2)
    for r in 1:rows, t in 1:n_points
        t_quad_cost[r, t, :] = collect(data[r][t])
    end
    return t_quad_cost
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, Vector{Vector{Tuple{Float64, Float64}}}},
)
    quad_cost = hcat(_pad_arrays_for_hdf(values(data))...)
    rows, cols = size(quad_cost)
    n_points = length(quad_cost[1, 1])
    @assert all(length.(quad_cost) .== n_points)
    @assert_op length(first(quad_cost[1, 1])) == 2  # should be just (x, y)
    t_quad_cost = Array{Float64}(undef, rows, cols, n_points, 2)
    for r in 1:rows, c in 1:cols, t in 1:n_points
        t_quad_cost[r, c, t, :] = collect(quad_cost[r, c][t])
    end
    return t_quad_cost
end

function transform_array_for_hdf(data::Vector{<:Matrix})
    data = _pad_array_for_hdf(data)
    rows = length(data)
    n_points = size(first(data), 1)
    @assert all(size.(data, 1) .== n_points)
    @assert_op size(first(data), 2) == 2  # should be just (x, y)
    combined_cost = Array{Float64}(undef, rows, n_points, 2)
    for r in 1:rows
        combined_cost[r, :, :] = data[r]
    end
    return combined_cost
end

function transform_array_for_hdf(
    data::SortedDict{Dates.DateTime, <:Vector{<:Matrix}},
)
    cols = length(data)
    costs = _pad_arrays_for_hdf(values(data))
    rows = length(first(costs))
    n_points = size(first(first(costs)), 1)
    for cost in costs
        @assert length(cost) == rows && all(size.(cost, 1) .== n_points)
    end
    @assert_op size(first(first(costs)), 2) == 2  # should be just (x, y)

    combined_cost = Array{Float64}(undef, rows, cols, n_points, 2)
    for r in 1:rows, (c, ca) in enumerate(costs)
        combined_cost[r, c, :, :] = ca[r]
    end
    return combined_cost
end

# Catchall methods for better error messages when element type cannot be determined
function transform_array_for_hdf(::Vector{T}) where {T}
    if !isconcretetype(T)
        supported = join(TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES, ", ")
        throw(
            ArgumentError(
                "Cannot determine the correct HDF5 data format to store time series data. " *
                "The vector has element type $T which is not concrete. " *
                "This typically occurs when Julia cannot infer the element type of your data. " *
                "Please ensure your time series data has a concrete element type. " *
                "Supported types: $supported.",
            ),
        )
    end
    supported = join(TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES, ", ")
    throw(
        ArgumentError(
            "Cannot determine the correct HDF5 data format for time series data with element type $T. " *
            "No transform_array_for_hdf method is defined for this type. " *
            "Supported types: $supported. " *
            "To use type $T, you need to implement a specific transform_array_for_hdf method for it in InfrastructureSystems.",
        ),
    )
end

function transform_array_for_hdf(data::SortedDict{Dates.DateTime, Vector{T}}) where {T}
    if !isconcretetype(T)
        supported = join(TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES, ", ")
        throw(
            ArgumentError(
                "Cannot determine the correct HDF5 data format to store time series data. " *
                "The SortedDict has value type Vector{$T} where $T is not concrete. " *
                "This typically occurs when Julia cannot infer the element type of your data. " *
                "Please ensure your time series data has a concrete element type. " *
                "Supported types: $supported.",
            ),
        )
    end
    supported = join(TRANSFORM_ARRAY_FOR_HDF_SUPPORTED_ELTYPES, ", ")
    throw(
        ArgumentError(
            "Cannot determine the correct HDF5 data format for time series data with element type $T. " *
            "No transform_array_for_hdf method is defined for this type. " *
            "Supported types: $supported. " *
            "To use type $T, you need to implement a specific transform_array_for_hdf method for it.",
        ),
    )
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
