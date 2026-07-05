
"""
Thrown upon detection of user data that is not supported.
"""
struct DataFormatError <: Exception
    msg::AbstractString
end

struct InvalidRange <: Exception
    msg::AbstractString
end

struct InvalidValue <: Exception
    msg::AbstractString
end

struct ConflictingInputsError <: Exception
    msg::AbstractString
end

struct HashMismatchError <: Exception
    msg::AbstractString
end

"""
Indicate that the feature at hand happens to not be implemented for the given data even
though it could be. If it is a category mistake to imagine this feature defined on that
data, use another exception, like `TypeError` or `ArgumentError`.
"""
struct NotImplementedError <: Exception
    msg::AbstractString
end

NotImplementedError(feature, data) =
    NotImplementedError("$feature not currently implemented for $data")

Base.showerror(io::IO, e::NotImplementedError) =
    println(io, "$NotImplementedError: $(e.msg)")

const CONSTANT = Float64
const LIM_TOL = 1e-6
const XY_COORDS = @NamedTuple{x::Float64, y::Float64}

"Delimiter to use when constructing qualified names like `component_type__component_name`."
const COMPONENT_NAME_DELIMITER = "__"

# See https://github.com/JuliaLang/julia/issues/18485
"An equality predicate that is `true` for `NaN, NaN` (unlike `==`) and for `-0.0, 0.0` (unlike `isequal`)"
isequivalent(x, y) = isequal(x, y) || (x == y)

abstract type InfrastructureSystemsContainer <: InfrastructureSystemsType end

"Abstract supertype for time-series manager implementations."
abstract type AbstractTimeSeriesManager <: InfrastructureSystemsType end

"Abstract supertype for supplemental-attribute manager implementations."
abstract type AbstractSupplementalAttributeManager <: InfrastructureSystemsContainer end
