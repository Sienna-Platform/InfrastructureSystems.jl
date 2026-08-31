# Asserts IS's `FunctionData` against the shared `element_type_vectors.json`
# conformance corpus.
#
# The encodings themselves live in InfraStore.jl now, with their own conformance
# test covering every vector in both directions. What IS still owns is the two
# ends: the `element_type_tag` / `element_row_width` / `write_element_row!`
# methods that pack one of *its* values, and the `_IS_ELEMENT_TYPES` table that
# names which of its types a tag decodes to. This checks that pair against the
# corpus, so a drift in either shows up here rather than in a store round trip.

# The corpus is vendored at `test/conformance/element_type_vectors.json` (see the README
# there) so the parity check always runs. A live copy — from `INFRASTORE_CONFORMANCE_DIR`
# or beside an InfraStore.jl source checkout — wins when one is present, so an infrastore
# dev tests against the corpus they are editing.
const VENDORED_ELEMENT_TYPE_VECTORS =
    joinpath(BASE_DIR, "test", "conformance", "element_type_vectors.json")

# The live corpus, or "" when this checkout has none. `Base.find_package` points at
# <repo>/julia/InfraStore.jl/src/InfraStore.jl in an infrastore checkout, and at
# ~/.julia/packages/... for the registered package, which ships no corpus.
function _live_element_type_vectors_path()
    from_env = get(ENV, "INFRASTORE_CONFORMANCE_DIR", "")
    if !isempty(from_env)
        path = joinpath(from_env, "element_type_vectors.json")
        isfile(path) || error("INFRASTORE_CONFORMANCE_DIR holds no corpus: $path")
        return path
    end
    binding = Base.find_package("InfraStore")
    isnothing(binding) && return ""
    repo = abspath(joinpath(dirname(binding), "..", "..", ".."))
    path = joinpath(repo, "conformance", "element_type_vectors.json")
    return isfile(path) ? path : ""
end

function _element_type_vectors_path()
    live = _live_element_type_vectors_path()
    isempty(live) && return VENDORED_ELEMENT_TYPE_VECTORS
    return live
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
    checked = 0
    for vector in _load_element_type_vectors(path)
        _is_representable(vector) || continue
        expected = _vector_expected_values(vector)
        isnothing(expected) && continue

        arr = _vector_storage_array(vector)
        got = IS.InfraStore.decode_element_values(
            arr, vector["element_type"], vector["leading_dims"];
            types = IS._IS_ELEMENT_TYPES,
        )
        # Forecast layouts come back windowed, so flatten to the corpus'
        # row-major timestep order before comparing.
        flat = if got isa AbstractVector
            got
        else
            vec(permutedims(got, reverse(ntuple(identity, ndims(got)))))
        end
        @test flat == expected
        checked += 1
    end
    # A corpus whose vectors all became unrepresentable would silently stop
    # testing anything; every element type IS maps must stay covered.
    @test checked >= 5
end

@testset "element_type conformance vectors round-trip through the encoder" begin
    path = _element_type_vectors_path()
    checked = 0
    for vector in _load_element_type_vectors(path)
        _is_representable(vector) || continue
        expected = _vector_expected_values(vector)
        isnothing(expected) && continue
        # The store packs a flat vector of values; a forecast's leading axes are
        # restored by the constructor that writes it, not by the encoder.
        vector["leading_dims"] == 1 || continue

        encoded, element_type = IS.InfraStore.encode_element_values(expected)
        # The element type IS's values tag themselves with is the store's own name...
        @test element_type == vector["element_type"]
        # ...and the bytes they produce are the ones the corpus pins.
        @test encoded == _vector_storage_array(vector)
        checked += 1
    end
    @test checked >= 5
end

@testset "element_type names are the store's neutral vocabulary" begin
    # A regression guard on the names themselves: they are a storage contract
    # shared with every other binding, not Julia type names. The composite tags
    # are the ones IS's own values carry, so they are asserted off the encoder.
    encode(values) = IS.InfraStore.encode_element_values(values)[2]
    @test encode([IS.LinearFunctionData(1.0, 2.0)]) == "linear_function"
    @test encode([IS.QuadraticFunctionData(1.0, 2.0, 3.0)]) == "quadratic_function"
    @test encode([IS.PiecewiseLinearData([(0.0, 1.0), (1.0, 3.0)])]) == "piecewise_linear"
    @test encode([IS.PiecewiseStepData([0.0, 1.0], [2.0])]) == "piecewise_step"
    @test encode([(1.0, 2.0, 3.0)]) == "tuple(3,f64)"

    # A value type nothing encodes is a loud error, not a silent scalar.
    @test_throws IS.InfraStore.InvalidParameterError encode([1.0 + 2.0im])

    # A scalar dtype is named by the store on the way in — IS never tags one — so
    # those spellings are pinned off the catalog rows of a round trip instead.
    sys = IS.SystemData()
    component = IS.TestComponent("conformance", 1)
    IS.add_component!(sys, component)
    initial_time = Dates.DateTime("2020-01-01")
    resolution = Dates.Hour(1)
    for (name, values, tag) in (
        ("floats", [1.0, 2.0, 3.0], "f64"),
        ("ints", Int64[1, 2, 3], "i64"),
        ("bools", Bool[true, false, true], "bool"),
    )
        IS.add_time_series!(
            sys,
            component,
            IS.SingleTimeSeries(name, initial_time, resolution, values),
        )
        @test IS.get_element_type(only(IS.list_metadata(sys; name = name))) == tag
    end
end

@testset "the vendored corpus matches the live one when both are present" begin
    live = _live_element_type_vectors_path()
    if isempty(live) || live == VENDORED_ELEMENT_TYPE_VECTORS
        @test isfile(VENDORED_ELEMENT_TYPE_VECTORS)
    elseif read(live) != read(VENDORED_ELEMENT_TYPE_VECTORS)
        # Not a failure: the live checkout may be mid-edit. The testsets above ran
        # against `live`, so the contract is still asserted — only the pinned copy
        # is stale, and refreshing it is a deliberate step (see the README).
        @warn "Vendored conformance corpus differs from the live one; refresh it" live vendored =
            VENDORED_ELEMENT_TYPE_VECTORS
        @test_skip false
    else
        @test true
    end
end
