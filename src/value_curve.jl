"""
A cost (or fuel) curve that wraps a [`FunctionData`](@ref) and declares how to interpret it.

`ValueCurve` adds meaning to raw function data. The three concrete families differ in what
the y-axis represents for a given production quantity x:

| Subtype | Interpretation | Typical y units |
|---|---|---|
| [`InputOutputCurve`](@ref) | `y = f(x)` — total output at x | \$/h or MBTU/h |
| [`IncrementalCurve`](@ref) | `y = f'(x)` — marginal rate at x | \$/MWh or MBTU/MWh |
| [`AverageRateCurve`](@ref) | `y = f(x)/x` — average rate at x | \$/MWh or MBTU/MWh |

All three can represent the same physical cost function and are inter-convertible (given
`initial_input`). Your data source determines which to start with: market bid stacks →
[`IncrementalCurve`](@ref); total cost tables → [`InputOutputCurve`](@ref); efficiency
tables → [`AverageRateCurve`](@ref).

The type parameter `T <: FunctionData` specifies the function shape. For ergonomic
construction, use the cost aliases: [`LinearCurve`](@ref), [`QuadraticCurve`](@ref),
[`PiecewisePointCurve`](@ref), [`PiecewiseIncrementalCurve`](@ref),
[`PiecewiseAverageCurve`](@ref).
"""
abstract type ValueCurve{T <: FunctionData} end

# JSON SERIALIZATION
serialize(val::ValueCurve) = serialize_struct(val)
deserialize(T::Type{<:ValueCurve}, val::Dict) = deserialize_struct(T, val)

"Get the underlying `FunctionData` representation of this `ValueCurve`"
get_function_data(curve::ValueCurve) = curve.function_data

"Get the `input_at_zero` field of this `ValueCurve`"
get_input_at_zero(curve::ValueCurve) = curve.input_at_zero

"""
A curve where `y = f(x)` — the **total** cost or fuel at production level `x`.

Use when your data directly gives total output vs. input: e.g., total \$/h at each MW level,
or total MBTU/h from a heat rate curve fit. The y-axis is an absolute quantity, not a rate.

- In a [`CostCurve`](@ref): x = MW, y = \$/h
- In a [`FuelCurve`](@ref): x = MW, y = MBTU/h (or other fuel units)

Use [`IncrementalCurve`](@ref) if your data is in marginal-rate form (e.g., a bid stack).
"""
@kwdef struct InputOutputCurve{
    T <: Union{QuadraticFunctionData, LinearFunctionData, PiecewiseLinearData},
} <: ValueCurve{T}
    "The underlying `FunctionData` representation of this `ValueCurve`"
    function_data::T
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, Float64} = nothing
end

InputOutputCurve(function_data) = InputOutputCurve(function_data, nothing)
InputOutputCurve{T}(
    function_data,
) where {(T <: Union{QuadraticFunctionData, LinearFunctionData, PiecewiseLinearData})} =
    InputOutputCurve{T}(function_data, nothing)

"""
Evaluate the `InputOutputCurve` at a given input value `x`.
"""
(ioc::InputOutputCurve)(x::Real) = get_function_data(ioc)(x)

"""
A curve where `y = f'(x)` — the **marginal rate** (derivative of cost) at production level `x`.

Use when your data is in incremental form: e.g., a generator bid stack where each segment
has a constant \$/MWh price. This is the native format for market offers and incremental
heat rate data.

- In a [`CostCurve`](@ref): x = MW, y = \$/MWh (marginal cost)
- In a [`FuelCurve`](@ref): x = MW, y = MBTU/MWh (incremental heat rate)

`initial_input` stores the **total cost at the minimum production point** `x_coords[1]`.
It is not part of the curve itself — it anchors the absolute cost level and is required to
convert this curve to an [`InputOutputCurve`](@ref).

Use [`InputOutputCurve`](@ref) if your data gives total cost at each output level directly.
"""
@kwdef struct IncrementalCurve{T <: Union{LinearFunctionData, PiecewiseStepData}} <:
              ValueCurve{T}
    "The underlying `FunctionData` representation of this `ValueCurve`"
    function_data::T
    "Total cost at the minimum production point `x_coords[1]`, used to anchor the curve and enable conversion to `InputOutputCurve`. Set to `nothing` if unknown or not needed."
    initial_input::Union{Float64, Nothing}
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, Float64} = nothing
end

IncrementalCurve(function_data, initial_input) =
    IncrementalCurve(function_data, initial_input, nothing)
IncrementalCurve{T}(
    function_data,
    initial_input,
) where {(T <: Union{LinearFunctionData, PiecewiseStepData})} =
    IncrementalCurve{T}(function_data, initial_input, nothing)

"""
A curve where `y = f(x)/x` — the **average rate** (total cost divided by production) at `x`.

Use when your data source gives average efficiency: total fuel consumed per unit output,
which is common in generator heat rate tables that report MBTU/MWh as a function of MW
(not the incremental/marginal rate, but the average over the whole output).

- In a [`CostCurve`](@ref): x = MW, y = \$/MWh (average, not marginal)
- In a [`FuelCurve`](@ref): x = MW, y = MBTU/MWh (average heat rate)

`initial_input` stores the **total cost at the minimum production point** `x_coords[1]`,
required to convert this curve to an [`InputOutputCurve`](@ref).

Use [`IncrementalCurve`](@ref) if your data gives marginal rates, not averages.
"""
@kwdef struct AverageRateCurve{T <: Union{LinearFunctionData, PiecewiseStepData}} <:
              ValueCurve{T}
    "The underlying `FunctionData` representation of this `ValueCurve`. For `AverageRateCurve{LinearFunctionData}`, this represents only the oblique asymptote of the implied total cost curve."
    function_data::T
    "Total cost at the minimum production point `x_coords[1]`, used to anchor the curve and enable conversion to `InputOutputCurve`. Set to `nothing` if unknown or not needed."
    initial_input::Union{Float64, Nothing}
    "Optional, an explicit representation of the input value at zero output."
    input_at_zero::Union{Nothing, Float64} = nothing
end

AverageRateCurve(function_data, initial_input) =
    AverageRateCurve(function_data, initial_input, nothing)
AverageRateCurve{T}(
    function_data,
    initial_input,
) where {(T <: Union{LinearFunctionData, PiecewiseStepData})} =
    AverageRateCurve{T}(function_data, initial_input, nothing)

"Get the `initial_input` field of this `ValueCurve` (not defined for `InputOutputCurve`)"
get_initial_input(curve::Union{IncrementalCurve, AverageRateCurve}) = curve.initial_input

# BASE METHODS
Base.:(==)(a::T, b::T) where {T <: ValueCurve} = double_equals_from_fields(a, b)

Base.isequal(a::T, b::T) where {T <: ValueCurve} = isequal_from_fields(a, b)

Base.hash(a::ValueCurve, h::UInt) = hash_from_fields(a, h)

"Get an `InputOutputCurve` representing `f(x) = 0`"
Base.zero(::Union{InputOutputCurve, Type{InputOutputCurve}}) =
    InputOutputCurve(zero(FunctionData))

"Get an `IncrementalCurve` representing `f'(x) = 0` with zero `initial_input`"
Base.zero(::Union{IncrementalCurve, Type{IncrementalCurve}}) =
    IncrementalCurve(zero(FunctionData), 0.0)

"Get an `AverageRateCurve` representing `f(x)/x = 0` with zero `initial_input`"
Base.zero(::Union{AverageRateCurve, Type{AverageRateCurve}}) =
    AverageRateCurve(zero(FunctionData), 0.0)

"Get a `ValueCurve` representing zero variable cost"
Base.zero(::Union{ValueCurve, Type{ValueCurve}}) =
    Base.zero(InputOutputCurve)

# CONVERSIONS: InputOutputCurve{LinearFunctionData} to InputOutputCurve{QuadraticFunctionData}
InputOutputCurve{QuadraticFunctionData}(data::InputOutputCurve{LinearFunctionData}) =
    InputOutputCurve{QuadraticFunctionData}(
        get_function_data(data),
        get_input_at_zero(data),
    )

Base.convert(
    ::Type{InputOutputCurve{QuadraticFunctionData}},
    data::InputOutputCurve{LinearFunctionData},
) = InputOutputCurve{QuadraticFunctionData}(data)

# CONVERSIONS: InputOutputCurve to X
function IncrementalCurve(data::InputOutputCurve{QuadraticFunctionData})
    fd = get_function_data(data)
    q, p, c = get_quadratic_term(fd), get_proportional_term(fd), get_constant_term(fd)
    return IncrementalCurve(LinearFunctionData(2q, p), c, get_input_at_zero(data))
end

function AverageRateCurve(data::InputOutputCurve{QuadraticFunctionData})
    fd = get_function_data(data)
    q, p, c = get_quadratic_term(fd), get_proportional_term(fd), get_constant_term(fd)
    return AverageRateCurve(LinearFunctionData(q, p), c, get_input_at_zero(data))
end

IncrementalCurve(data::InputOutputCurve{LinearFunctionData}) =
    IncrementalCurve(InputOutputCurve{QuadraticFunctionData}(data))

AverageRateCurve(data::InputOutputCurve{LinearFunctionData}) =
    AverageRateCurve(InputOutputCurve{QuadraticFunctionData}(data))

function IncrementalCurve(data::InputOutputCurve{PiecewiseLinearData})
    fd = get_function_data(data)
    return IncrementalCurve(
        PiecewiseStepData(get_x_coords(fd), get_slopes(fd)),
        first(get_points(fd)).y, get_input_at_zero(data),
    )
end

function AverageRateCurve(data::InputOutputCurve{PiecewiseLinearData})
    fd = get_function_data(data)
    points = get_points(fd)
    slopes_from_origin = [p.y / p.x for p in points[2:end]]
    return AverageRateCurve(
        PiecewiseStepData(get_x_coords(fd), slopes_from_origin),
        first(points).y, get_input_at_zero(data),
    )
end

# CONVERSIONS: IncrementalCurve to X
function InputOutputCurve(data::IncrementalCurve{LinearFunctionData})
    fd = get_function_data(data)
    p = get_proportional_term(fd)
    c = get_initial_input(data)
    isnothing(c) && throw(
        ArgumentError("Cannot convert `IncrementalCurve` with undefined `initial_input`"),
    )
    (p == 0) && return InputOutputCurve(
        LinearFunctionData(get_constant_term(fd), c),
    )
    return InputOutputCurve(
        QuadraticFunctionData(p / 2, get_constant_term(fd), c),
        get_input_at_zero(data),
    )
end

function InputOutputCurve(data::IncrementalCurve{PiecewiseStepData})
    fd = get_function_data(data)
    c = get_initial_input(data)
    isnothing(c) && throw(
        ArgumentError("Cannot convert `IncrementalCurve` with undefined `initial_input`"),
    )
    points = running_sum(fd)
    return InputOutputCurve(
        PiecewiseLinearData([(p.x, p.y + c) for p in points]),
        get_input_at_zero(data),
    )
end

AverageRateCurve(data::IncrementalCurve) = AverageRateCurve(InputOutputCurve(data))

# CONVERSIONS: AverageRateCurve to X
function InputOutputCurve(data::AverageRateCurve{LinearFunctionData})
    fd = get_function_data(data)
    p = get_proportional_term(fd)
    c = get_initial_input(data)
    isnothing(c) && throw(
        ArgumentError("Cannot convert `AverageRateCurve` with undefined `initial_input`"),
    )
    (p == 0) && return InputOutputCurve(
        LinearFunctionData(get_constant_term(fd), c),
        get_input_at_zero(data),
    )
    return InputOutputCurve(
        QuadraticFunctionData(p, get_constant_term(fd), c),
        get_input_at_zero(data),
    )
end

function InputOutputCurve(data::AverageRateCurve{PiecewiseStepData})
    fd = get_function_data(data)
    c = get_initial_input(data)
    isnothing(c) && throw(
        ArgumentError("Cannot convert `AverageRateCurve` with undefined `initial_input`"),
    )
    xs = get_x_coords(fd)
    ys = xs[2:end] .* get_y_coords(fd)
    return InputOutputCurve(
        PiecewiseLinearData(collect(zip(xs, vcat(c, ys)))),
        get_input_at_zero(data),
    )
end

IncrementalCurve(data::AverageRateCurve) = IncrementalCurve(InputOutputCurve(data))

# PRINTING
"Whether there is a cost alias for the instance or type under consideration"
is_cost_alias(::Union{ValueCurve, Type{<:ValueCurve}}) = false

# For cost aliases, return the alias name; otherwise, return the type name without the parameter
simple_type_name(curve::ValueCurve) =
    string(is_cost_alias(curve) ? typeof(curve) : nameof(typeof(curve)))

function Base.show(io::IO, ::MIME"text/plain", curve::InputOutputCurve)
    print(io, simple_type_name(curve))
    is_cost_alias(curve) && print(io, " (a type of $InputOutputCurve)")
    print(io, " where ")
    !isnothing(get_input_at_zero(curve)) &&
        print(io, "value at zero is $(get_input_at_zero(curve)), ")
    print(io, "function is: ")
    show(IOContext(io, :compact => true), "text/plain", get_function_data(curve))
end

function Base.show(io::IO, ::MIME"text/plain", curve::IncrementalCurve)
    print(io, simple_type_name(curve))
    print(io, " where ")
    !isnothing(get_input_at_zero(curve)) &&
        print(io, "value at zero is $(get_input_at_zero(curve)), ")
    print(io, "initial value is $(get_initial_input(curve))")
    print(io, ", derivative function f is: ")
    show(IOContext(io, :compact => true), "text/plain", get_function_data(curve))
end

function Base.show(io::IO, ::MIME"text/plain", curve::AverageRateCurve)
    print(io, simple_type_name(curve))
    print(io, " where ")
    !isnothing(get_input_at_zero(curve)) &&
        print(io, "value at zero is $(get_input_at_zero(curve)), ")
    print(io, "initial value is $(get_initial_input(curve))")
    print(io, ", average rate function f is: ")
    show(IOContext(io, :compact => true), "text/plain", get_function_data(curve))
end

# MORE GENERIC CONSTRUCTORS
# These manually do what https://github.com/JuliaLang/julia/issues/35053 (open at time of writing) proposes to automatically provide
InputOutputCurve(
    function_data::T,
    input_at_zero,
) where {T <: Union{LinearFunctionData, QuadraticFunctionData, PiecewiseLinearData}} =
    InputOutputCurve{T}(function_data, input_at_zero)
IncrementalCurve(
    function_data::T,
    initial_input,
    input_at_zero,
) where {T <: Union{LinearFunctionData, PiecewiseStepData}} =
    IncrementalCurve{T}(function_data, initial_input, input_at_zero)
AverageRateCurve(
    function_data::T,
    initial_input,
    input_at_zero,
) where {T <: Union{LinearFunctionData, PiecewiseStepData}} =
    AverageRateCurve{T}(function_data, initial_input, input_at_zero)
