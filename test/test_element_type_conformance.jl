# The store's element-type encodings, checked against the cross-language
# conformance corpus.
#
# `conformance/element_type_vectors.json` in the infrastore repo is generated
# from `infrastore-core`'s `codec::conformance` vectors and read by every
# binding's codec tests. IS.jl's `_storage_array` / `_decode_static_values` are
# the Julia implementation of those encodings, so pinning them against the same
# corpus is what keeps a curve written here readable by the Rust CLI, the Python
# bindings, and the web app's TypeScript codec.
#
# The corpus lives in the infrastore checkout, which is not a Julia dependency;
# when it cannot be located the tests skip rather than fail, so IS.jl stays
# testable on its own.

# Locate `conformance/element_type_vectors.json` next to the InfraStore.jl
# checkout IS.jl already depends on, or wherever `INFRASTORE_CONFORMANCE_DIR`
# points. `nothing` when neither is present.
function _element_type_vectors_path()
    from_env = get(ENV, "INFRASTORE_CONFORMANCE_DIR", nothing)
    if !isnothing(from_env)
        path = joinpath(from_env, "element_type_vectors.json")
        return isfile(path) ? path : nothing
    end
    binding = Base.find_package("InfraStore")
    isnothing(binding) && return nothing
    # <repo>/julia/InfraStore.jl/src/InfraStore.jl -> <repo>/conformance
    repo = abspath(joinpath(dirname(binding), "..", "..", ".."))
    path = joinpath(repo, "conformance", "element_type_vectors.json")
    return isfile(path) ? path : nothing
end

_load_element_type_vectors(path) = JSON.parsefile(path)["vectors"]

# Rebuild the stored `(rows..., width)` array from a vector's flat row-major
# values. Julia is column-major, so the trailing element dim is read back by
# reshaping the reversed shape and permuting the axes.
function _vector_storage_array(vector)
    shape = Int.(vector["shape"])
    values = Float64.(vector["values"])
    n = length(shape)
    n == 1 && return values
    return permutedims(reshape(values, reverse(shape)...), reverse(ntuple(identity, n)))
end

# Whether IS's domain types can represent every timestep of a vector. The store
# accepts a piecewise curve with zero or one point; `PiecewiseLinearData` and
# `PiecewiseStepData` require at least two x-coordinates, so those vectors
# exercise the store's encoding but not IS's. The corpus carries a
# `*_two_widths` companion for each ragged kind precisely so the ragged path is
# still covered here.
function _is_representable(vector)
    kind = vector["decoded"]["kind"]
    steps = vector["decoded"]["timesteps"]
    kind == "piecewise_linear" && return all(s -> length(s) >= 2, steps)
    kind == "piecewise_step" && return all(s -> length(s["x"]) >= 2, steps)
    return true
end

# The per-timestep IS values a vector's `decoded` payload describes. Only the
# element types IS maps to a domain type are built here; the rest are skipped by
# the caller.
function _vector_expected_values(vector)
    kind = vector["decoded"]["kind"]
    steps = vector["decoded"]["timesteps"]
    if kind == "linear_function"
        return [IS.LinearFunctionData(s["proportional"], s["constant"]) for s in steps]
    elseif kind == "quadratic_function"
        return [
            IS.QuadraticFunctionData(s["quadratic"], s["proportional"], s["constant"])
            for s in steps
        ]
    elseif kind == "piecewise_linear"
        return [
            IS.PiecewiseLinearData([(p["x"], p["y"]) for p in s]) for s in steps
        ]
    elseif kind == "piecewise_step"
        return [
            IS.PiecewiseStepData(Float64.(s["x"]), Float64.(s["y"])) for s in steps
        ]
    elseif kind == "tuple"
        return [Tuple(Float64.(s)) for s in steps]
    else
        return nothing
    end
end

@testset "element_type conformance vectors decode to IS values" begin
    path = _element_type_vectors_path()
    if isnothing(path)
        @test_skip "conformance/element_type_vectors.json not found"
    else
        checked = 0
        for vector in _load_element_type_vectors(path)
            _is_representable(vector) || continue
            expected = _vector_expected_values(vector)
            isnothing(expected) && continue
            # Only the static layouts decode through `_decode_static_values`;
            # forecast layouts go through `_decode_forecast_window`, which slices
            # a window out first and is covered separately.
            vector["leading_dims"] == 1 || continue

            arr = _vector_storage_array(vector)
            encoding = IS._element_encoding(vector["element_type"])
            got = IS._decode_static_values(arr, encoding, size(arr, 1))
            @test got == expected
            checked += 1
        end
        # A corpus whose vectors all became unrepresentable would silently stop
        # testing anything; every element type IS maps must stay covered.
        @test checked >= 5
    end
end

@testset "element_type conformance vectors round-trip through the encoder" begin
    path = _element_type_vectors_path()
    if isnothing(path)
        @test_skip "conformance/element_type_vectors.json not found"
    else
        checked = 0
        for vector in _load_element_type_vectors(path)
            _is_representable(vector) || continue
            expected = _vector_expected_values(vector)
            isnothing(expected) && continue
            vector["leading_dims"] == 1 || continue

            encoded, element_type = IS._storage_array(expected)
            # The element type IS tags the array with is the store's own name...
            @test element_type == vector["element_type"]
            # ...and the bytes it produces are the ones the corpus pins.
            @test encoded == _vector_storage_array(vector)
            checked += 1
        end
        @test checked >= 5
    end
end

@testset "element_type names are the store's neutral vocabulary" begin
    # A regression guard on the names themselves: they are a storage contract
    # shared with every other binding, not Julia type names.
    @test IS._storage_array([IS.LinearFunctionData(1.0, 2.0)])[2] == "linear_function"
    @test IS._storage_array([IS.QuadraticFunctionData(1.0, 2.0, 3.0)])[2] ==
          "quadratic_function"
    @test IS._storage_array([IS.PiecewiseLinearData([(0.0, 1.0), (1.0, 3.0)])])[2] ==
          "piecewise_linear"
    @test IS._storage_array([IS.PiecewiseStepData([0.0, 1.0], [2.0])])[2] ==
          "piecewise_step"
    @test IS._storage_array([(1.0, 2.0, 3.0)])[2] == "tuple(3,f64)"
    @test IS._storage_array([1.0, 2.0])[2] == "f64"
    @test IS._storage_array(Int64[1, 2])[2] == "i64"
    @test IS._storage_array(Bool[true, false])[2] == "bool"

    # An element type IS cannot represent is a loud error, not a silent scalar.
    @test_throws ErrorException IS._storage_array([1.0 + 2.0im])
end
