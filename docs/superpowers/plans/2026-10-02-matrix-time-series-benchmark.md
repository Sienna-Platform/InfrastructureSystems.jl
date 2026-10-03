# Matrix Time Series Axes and Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let IS store labeled value axes on N-D `SingleTimeSeries` and `Deterministic`, read N-D `Deterministic`/DST through IS, and benchmark load-zone distribution factors stored per bus against one matrix series.

**Architecture:** A small `TimeSeriesAxis` type and a `value_axes` field, modeled on `units`, persisted as JSON in the store's per-row `application_data`.
The store already carries that string to DST rows and OpenAPI rows, so no InfraStore change is needed.
The N-D forecast fixes are local to IS's window slicing and validation.
The benchmark is one script that reuses `benchmark/bench.jl`'s helpers and runs each representation in a fresh process.

**Tech Stack:** Julia 1.10+, InfrastructureSystems.jl (IS4 branch), InfraStore.jl 0.14, JSON.jl 1.x, ReTest.

**Spec:** `docs/superpowers/specs/2026-10-02-matrix-time-series-benchmark-design.md`

## Global Constraints

- Branch: `rh/ts_matrix_benchmark`. Never bump the package version (stays 3.6.0).
- Julia compat `^1.10`; `stack`, `allunique` and `selectdim` are all available there.
- No new exports. `TimeSeriesAxis` and `get_value_axes` are reached as `IS.TimeSeriesAxis` / `IS.get_value_axes`.
- No `isa`/`<:` branching in function logic; use dispatch. Exception inspection inside `catch` blocks is allowed.
- Errors are `ArgumentError`s that name the offending axis, size or type. Nothing fails silently.
- Never edit `src/generated/`, `CHANGELOG.md`, or `[compat] InfraStore`.
- Comments: at most 3 lines each, no em dashes, no "this used to" history.
- Commit messages carry no AI co-author line.
- Run the formatter before calling any task done: `julia scripts/formatter/formatter_code.jl`.

## Review Focus

Inputs the spec implies but its test list does not name, each pinned by a test in the owning task:

1. Labels arriving as `Int32`, `SubString`, or with `missing` (a DataFrame column): the first two convert, `missing` is a named `ArgumentError` (Task 1).
2. Time slicing a labeled series with `head`/`tail`: the slice keeps its axes (Task 2).
3. `copy_time_series!` of a labeled series: the copy keeps its axes (Task 2).
4. One deduplicated array added to two owners with different labels: each owner reads its own labels (Task 2).
5. A DST read with `len` and `count` narrower than the stored window: shape is right and axes are kept (Task 3).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/time_series_axes.jl` (new) | `TimeSeriesAxis`, `get_value_axes` generic, shape validation, `application_data` JSON codec |
| `src/InfrastructureSystems.jl` | include the new file before `single_time_series.jl` |
| `src/single_time_series.jl` | `value_axes` field, constructors, accessor |
| `src/deterministic.jl` | `value_axes` field, constructors, accessor, N-D `convert_data` |
| `src/forecasts.jl` | `_window_value_dims`; `get_window_common` N-D guard |
| `src/utils/utils.jl` | accept N-D `Deterministic` windows in backend validation |
| `src/time_series_structs.jl` | `get_value_axes(::TimeSeriesMetadata)` |
| `src/infrastore.jl` | write axes on add; read axes back; N-D window slicing; `stack` on forecast write |
| `test/test_time_series_value_axes.jl` (new) | every test in this plan (auto-included by `test/InfrastructureSystemsTests.jl`) |
| `benchmark/bench.jl` | guard its run so other scripts can include it |
| `benchmark/matrix_bench.jl` (new) | the distribution-factor benchmark |
| `benchmark/README.md` | how to run it |

Test helpers in the new test file carry a `_va_` prefix, because every test file shares one module.

---

### Task 1: `TimeSeriesAxis`, validation and codec

**Files:**
- Create: `src/time_series_axes.jl`
- Modify: `src/InfrastructureSystems.jl:210` (add one include)
- Test: `test/test_time_series_value_axes.jl` (create)

**Interfaces:**
- Consumes: `JSON` (already imported at module level in `src/utils/utils.jl:3`).
- Produces:
  - `TimeSeriesAxis(name::AbstractString, labels::AbstractVector)` with fields `name::String`, `labels::Union{Vector{Int64}, Vector{String}}`; `==` and `hash` by value.
  - `get_value_axes` (generic, methods added in Tasks 2 and 3).
  - `_check_value_axes(value_axes::Union{Nothing, Vector{TimeSeriesAxis}}, value_dims::Tuple)` -> `nothing` or throws.
  - `_value_axes_application_data(value_axes) -> Union{Nothing, String}`.
  - `_value_axes_from_application_data(application_data::Union{Nothing, AbstractString}) -> Union{Nothing, Vector{TimeSeriesAxis}}`.

- [ ] **Step 1: Set up the test environment (once per checkout)**

```sh
JULIA_PKG_SERVER= julia --project=test -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
```

Expected: completes without error. `test/Manifest.toml` is git-ignored.

- [ ] **Step 2: Write the failing tests**

Create `test/test_time_series_value_axes.jl`:

```julia
# Labeled value axes on N-D time series, and N-D Deterministic / DST reads.

const _VA_T0 = Dates.DateTime("2024-01-01T00:00:00")

_va_bus_axis(n) = IS.TimeSeriesAxis("bus", collect(101:(100 + n)))

@testset "Test value_axes TimeSeriesAxis construction" begin
    axis = IS.TimeSeriesAxis("bus", Int32[1, 2])
    @test axis.labels isa Vector{Int64}
    @test axis == IS.TimeSeriesAxis("bus", [1, 2])
    @test hash(axis) == hash(IS.TimeSeriesAxis("bus", [1, 2]))
    @test axis != IS.TimeSeriesAxis("bus", ["1", "2"])
    @test IS.TimeSeriesAxis("zone", SubString.(["a", "b"])).labels isa Vector{String}
    # Review focus: a DataFrame column with missing values, or an unsupported label type.
    @test_throws ArgumentError IS.TimeSeriesAxis("bus", [1, missing])
    @test_throws ArgumentError IS.TimeSeriesAxis("bus", [:a, :b])
end

@testset "Test value_axes validation against value dimensions" begin
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), IS.TimeSeriesAxis("bus", [1, 2, 3])]
    @test IS._check_value_axes(axes, (2, 3)) === nothing
    @test IS._check_value_axes(nothing, (2, 3)) === nothing
    @test_throws ArgumentError IS._check_value_axes(axes, (2,))
    @test_throws ArgumentError IS._check_value_axes(axes, (2, 4))
    @test_throws ArgumentError IS._check_value_axes([IS.TimeSeriesAxis("bus", [1, 1])], (2,))
    @test_throws ArgumentError IS._check_value_axes(
        [IS.TimeSeriesAxis("x", [1]), IS.TimeSeriesAxis("x", [2])],
        (1, 1),
    )
end

@testset "Test value_axes application_data codec" begin
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), IS.TimeSeriesAxis("bus", [7, 9])]
    encoded = IS._value_axes_application_data(axes)
    @test IS._value_axes_from_application_data(encoded) == axes
    @test IS._value_axes_application_data(nothing) === nothing
    @test IS._value_axes_from_application_data(nothing) === nothing
    # Another client's payload: not JSON, JSON that is not an object, an object without the key.
    @test IS._value_axes_from_application_data("not json {") === nothing
    @test IS._value_axes_from_application_data("[1, 2]") === nothing
    @test IS._value_axes_from_application_data("{\"other\": 1}") === nothing
    @test_throws ArgumentError IS._value_axes_from_application_data(
        "{\"value_axes\": [{\"name\": \"b\", \"label_type\": \"float\", \"labels\": [1.5]}]}",
    )
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("value_axes")'`
Expected: FAIL with `UndefVarError: TimeSeriesAxis not defined`.

- [ ] **Step 4: Write the implementation**

Create `src/time_series_axes.jl`:

```julia
"""
    TimeSeriesAxis(name, labels)

Names one non-time dimension of a time series value and labels each of its entries,
e.g. `TimeSeriesAxis("bus", [101, 102])`. Labels are integers or strings and must be
unique within the axis. See [`get_value_axes`](@ref).
"""
struct TimeSeriesAxis
    name::String
    labels::Union{Vector{Int64}, Vector{String}}

    TimeSeriesAxis(name::AbstractString, labels::AbstractVector{<:Integer}) =
        new(String(name), Vector{Int64}(labels))
    TimeSeriesAxis(name::AbstractString, labels::AbstractVector{<:AbstractString}) =
        new(String(name), Vector{String}(labels))
    TimeSeriesAxis(name::AbstractString, labels::AbstractVector) = throw(
        ArgumentError(
            "value axis '$name' labels must be integers or strings; got $(eltype(labels))",
        ),
    )
end

Base.:(==)(a::TimeSeriesAxis, b::TimeSeriesAxis) = a.name == b.name && a.labels == b.labels
Base.hash(a::TimeSeriesAxis, h::UInt) =
    hash(a.labels, hash(a.name, hash(:TimeSeriesAxis, h)))

"""
    get_value_axes(x)

Return the labeled non-time axes of a time series' values, in dimension order, or
`nothing` when the values are unlabeled.
"""
function get_value_axes end

# Each non-time dimension of a value gets exactly one axis, sized to that dimension.
_check_value_axes(::Nothing, _value_dims::Tuple) = nothing

function _check_value_axes(value_axes::Vector{TimeSeriesAxis}, value_dims::Tuple)
    length(value_axes) == length(value_dims) || throw(
        ArgumentError(
            "value_axes names $(length(value_axes)) axes, but each value has " *
            "$(length(value_dims)) dimensions $(value_dims)",
        ),
    )
    names = [axis.name for axis in value_axes]
    allunique(names) || throw(ArgumentError("value_axes names are not unique: $names"))
    for (axis, n) in zip(value_axes, value_dims)
        length(axis.labels) == n || throw(
            ArgumentError(
                "value axis '$(axis.name)' has $(length(axis.labels)) labels, but its " *
                "dimension has size $n",
            ),
        )
        allunique(axis.labels) ||
            throw(ArgumentError("value axis '$(axis.name)' has duplicate labels"))
    end
    return nothing
end

# Kept in the association row's `application_data` under this key; the store carries
# that string to DST rows and OpenAPI rows without interpreting it.
const _VALUE_AXES_KEY = "value_axes"

_label_type(::Vector{Int64}) = "int"
_label_type(::Vector{String}) = "string"

_value_axes_application_data(::Nothing) = nothing
_value_axes_application_data(value_axes::Vector{TimeSeriesAxis}) = JSON.json(
    Dict(
        _VALUE_AXES_KEY => [
            Dict(
                "name" => axis.name,
                "label_type" => _label_type(axis.labels),
                "labels" => axis.labels,
            ) for axis in value_axes
        ],
    ),
)

_value_axes_from_application_data(::Nothing) = nothing

function _value_axes_from_application_data(application_data::AbstractString)
    parsed = try
        JSON.parse(application_data; dicttype = Dict{String, Any})
    catch e
        # `catch`-block exception inspection: another client's payload need not be JSON.
        e isa ArgumentError || rethrow()
        return nothing
    end
    return _value_axes_from_parsed(parsed)
end

# Valid JSON that is not IS's object belongs to another client and carries no axes.
_value_axes_from_parsed(_parsed) = nothing

function _value_axes_from_parsed(parsed::Dict{String, Any})
    raw = get(parsed, _VALUE_AXES_KEY, nothing)
    isnothing(raw) && return nothing
    return TimeSeriesAxis[
        TimeSeriesAxis(axis["name"], _decode_labels(axis["label_type"], axis["labels"]))
        for axis in raw
    ]
end

function _decode_labels(label_type::AbstractString, labels::AbstractVector)
    label_type == "int" && return Int64[label for label in labels]
    label_type == "string" && return String[label for label in labels]
    throw(ArgumentError("unknown value axis label_type '$label_type'"))
end
```

In `src/InfrastructureSystems.jl`, after `include("time_series_normalization.jl")` (line 210) add:

```julia
include("time_series_axes.jl")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("value_axes")'`
Expected: PASS for the three testsets. Aqua runs on load and must stay green (no new ambiguities).

- [ ] **Step 6: Commit**

```bash
git add src/time_series_axes.jl src/InfrastructureSystems.jl test/test_time_series_value_axes.jl
git commit -m "Add TimeSeriesAxis and the value_axes application_data codec"
```

---

### Task 2: `value_axes` on `SingleTimeSeries`, persisted through the store

**Files:**
- Modify: `src/single_time_series.jl` (struct at :43-57, docstring at :1-41, constructors at :85-103, :139-160, :171-188, :350-360)
- Modify: `src/infrastore.jl:345-374` (`serialize_single!`), `src/infrastore.jl:954-958` (`_single_from_store`)
- Modify: `src/time_series_structs.jl` (after `get_application_data` at :304)
- Test: `test/test_time_series_value_axes.jl`

**Interfaces:**
- Consumes (Task 1): `TimeSeriesAxis`, `get_value_axes`, `_check_value_axes`, `_value_axes_application_data`, `_value_axes_from_application_data`.
- Produces:
  - `SingleTimeSeries(name, initial_timestamp, resolution, data; units, quantity_kind, unit_system, value_axes = nothing)` and the keyword form with `value_axes`.
  - `get_value_axes(ts::SingleTimeSeries)`.
  - `get_value_axes(md::TimeSeriesMetadata)` (decodes and validates against `md.element_shape`).

- [ ] **Step 1: Write the failing tests**

Append to `test/test_time_series_value_axes.jl`:

```julia
function _va_system(n_owners = 1)
    sys = IS.SystemData()
    owners = [IS.TestComponent("va$i", i) for i in 1:n_owners]
    foreach(owner -> IS.add_component!(sys, owner), owners)
    return sys, owners
end

_va_sts(name, data; value_axes = nothing) =
    IS.SingleTimeSeries(name, _VA_T0, Dates.Hour(1), data; value_axes = value_axes)

# Writes a row straight to the store with an `application_data` the test chooses, as
# another client of the same store would.
function _va_add_raw!(sys, owner, name, data, application_data)
    store = IS.get_data_store(sys)
    owner_id, owner_type, category = IS._infrastore_owner_args(owner)
    raw = IS.InfraStore.SingleTimeSeries(
        _VA_T0, Dates.Hour(1), data, name; application_data = application_data,
    )
    batch = IS.InfraStore.AddBatch()
    IS.InfraStore.add_time_series!(batch, owner_id, owner_type, category, raw)
    IS.InfraStore.add_time_series_bulk!(store.inner, batch)
    IS.flush!(store)
    return
end

@testset "Test value_axes on SingleTimeSeries construction" begin
    data = rand(24, 3)
    ts = _va_sts("f", data; value_axes = [_va_bus_axis(3)])
    @test IS.get_value_axes(ts) == [_va_bus_axis(3)]
    @test IS.get_value_axes(_va_sts("f", data)) === nothing
    @test_throws ArgumentError _va_sts("f", data; value_axes = [_va_bus_axis(4)])
    @test_throws ArgumentError _va_sts("f", rand(24); value_axes = [_va_bus_axis(1)])
    @test IS.get_value_axes(IS.SingleTimeSeries(ts, "g")) == [_va_bus_axis(3)]
    kw = IS.SingleTimeSeries(;
        name = "k",
        data = data,
        initial_timestamp = _VA_T0,
        resolution = Dates.Hour(1),
        value_axes = [_va_bus_axis(3)],
    )
    @test IS.get_value_axes(kw) == [_va_bus_axis(3)]
    # Review focus: time slicing keeps the value axes.
    @test IS.get_value_axes(IS.head(ts, 5)) == [_va_bus_axis(3)]
    @test IS.get_value_axes(IS.tail(ts, 5)) == [_va_bus_axis(3)]
end

@testset "Test value_axes round-trip through the store" begin
    sys, (owner,) = _va_system()
    data = rand(24, 2, 3)
    axes = [IS.TimeSeriesAxis("zone", ["LZ1", "LZ2"]), _va_bus_axis(3)]
    IS.add_time_series!(sys, owner, _va_sts("f", data; value_axes = axes))
    back = IS.get_time_series(IS.SingleTimeSeries, owner, "f")
    @test IS.get_array(back) == data
    @test IS.get_value_axes(back) == axes
    sliced = IS.get_time_series(
        IS.SingleTimeSeries, owner, "f"; start_time = _VA_T0 + Dates.Hour(2), len = 5,
    )
    @test IS.get_array(sliced) == data[3:7, :, :]
    @test IS.get_value_axes(sliced) == axes
    @test IS.get_value_axes(only(IS.list_time_series_metadata(owner))) == axes
end

@testset "Test value_axes with one array shared by several owners" begin
    sys, owners = _va_system(3)
    data = rand(24, 3)
    IS.add_time_series!(sys, owners[1:2], _va_sts("f", data; value_axes = [_va_bus_axis(3)]))
    for owner in owners[1:2]
        back = IS.get_time_series(IS.SingleTimeSeries, owner, "f")
        @test IS.get_value_axes(back) == [_va_bus_axis(3)]
    end
    # Review focus: labels live on each row, so one array can carry different labels.
    other = IS.TimeSeriesAxis("bus", [7, 8, 9])
    IS.add_time_series!(sys, owners[3], _va_sts("f", data; value_axes = [other]))
    @test IS.get_value_axes(IS.get_time_series(IS.SingleTimeSeries, owners[3], "f")) ==
          [other]
    hashes = IS.get_time_series_hashes(owners, IS.SingleTimeSeries, "f")
    @test length(unique(values(hashes))) == 1
    # Review focus: copying a row keeps its labels.
    copy_owner = IS.TestComponent("va_copy", 9)
    IS.add_component!(sys, copy_owner)
    IS.copy_time_series!(copy_owner, owners[1])
    @test IS.get_value_axes(IS.get_time_series(IS.SingleTimeSeries, copy_owner, "f")) ==
          [_va_bus_axis(3)]
end

@testset "Test value_axes leaves another client's application_data alone" begin
    sys, (owner,) = _va_system()
    _va_add_raw!(sys, owner, "foreign", rand(24, 3), "not json {")
    _va_add_raw!(sys, owner, "other_json", rand(24, 3), "{\"other\": 1}")
    for name in ("foreign", "other_json")
        back = IS.get_time_series(IS.SingleTimeSeries, owner, name)
        @test IS.get_value_axes(back) === nothing
    end
    # IS's own key disagreeing with the stored shape is a storage inconsistency.
    bad = IS._value_axes_application_data([_va_bus_axis(4)])
    _va_add_raw!(sys, owner, "bad", rand(24, 3), bad)
    @test_throws ArgumentError IS.get_time_series(IS.SingleTimeSeries, owner, "bad")
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("value_axes")'`
Expected: FAIL with `MethodError` / unsupported keyword `value_axes`.

- [ ] **Step 3: Add the field and thread it through the constructors**

In `src/single_time_series.jl`:

1. In the docstring's struct block (lines 2-10) add `value_axes::Union{Nothing, Vector{TimeSeriesAxis}}` after `unit_system`, and in `# Arguments` add:

```julia
  - `value_axes::Union{Nothing, Vector{TimeSeriesAxis}}`: optional labels for each
    non-time dimension of the values, e.g. `[TimeSeriesAxis("bus", bus_numbers)]`
```

2. In the struct (after the `unit_system` field, line 56) add:

```julia
    "labeled non-time axes of the values (see [`TimeSeriesAxis`](@ref)), or `nothing`"
    value_axes::Union{Nothing, Vector{TimeSeriesAxis}}
```

3. Replace the primary constructor (lines 85-103) with:

```julia
function SingleTimeSeries(
    name,
    initial_timestamp::Dates.DateTime,
    resolution::Dates.Period,
    data::AbstractArray;
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
    value_axes::Union{Nothing, Vector{TimeSeriesAxis}} = nothing,
)
    arr = _ensure_array(data)
    _check_value_axes(value_axes, Base.tail(size(arr)))
    return SingleTimeSeries{eltype(arr), ndims(arr)}(
        String(name),
        initial_timestamp,
        resolution,
        arr,
        _maybe_string(units),
        _maybe_string(quantity_kind),
        unit_system,
        value_axes,
    )
end
```

4. In the keyword constructor (`function SingleTimeSeries(;`, line 139) add the keyword `value_axes::Union{Nothing, Vector{TimeSeriesAxis}} = nothing,` after `unit_system`, and forward it:

```julia
    return SingleTimeSeries(
        name, first_timestamp, res, arr;
        units = units, quantity_kind = quantity_kind, unit_system = unit_system,
        value_axes = value_axes,
    )
```

5. In `SingleTimeSeries(src::SingleTimeSeries, name::AbstractString)` (line 171) add `value_axes = src.value_axes,` after `unit_system = src.unit_system,`.

6. In `SingleTimeSeries(time_series::SingleTimeSeries, data::TimeSeries.TimeArray)` (line 350) add `value_axes = get_value_axes(time_series),` after `unit_system = get_unit_system(time_series),`.

7. After `get_initial_timestamp(time_series::SingleTimeSeries) = ...` (line 345) add:

```julia
"""
Get [`SingleTimeSeries`](@ref) `value_axes`.
"""
get_value_axes(value::SingleTimeSeries) = value.value_axes
```

The `TimeArray`, `DataFrame`, constant-value and concatenation constructors stay as they are: they build 1-D series, which have no value axes.

- [ ] **Step 4: Write the axes on add and read them back**

In `src/infrastore.jl`, `serialize_single!` (line 361), add one keyword to the `InfraStore.SingleTimeSeries` call:

```julia
    tss_ts = InfraStore.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        values,
        name;
        units = units,
        quantity_kind = quantity_kind,
        unit_system = _to_store_unit_system(unit_system),
        application_data = _value_axes_application_data(get_value_axes(sts)),
    )
```

Replace `_single_from_store` (line 954) with:

```julia
_single_from_store(sts, name::AbstractString) = SingleTimeSeries(
    String(name), sts.initial_timestamp, sts.resolution, sts.data;
    units = sts.units, quantity_kind = sts.quantity_kind,
    unit_system = _from_store_unit_system(sts.unit_system),
    value_axes = _value_axes_from_application_data(sts.application_data),
)
```

The constructor's `_check_value_axes` is what turns a row whose axes disagree with its shape into an `ArgumentError`.

In `src/time_series_structs.jl`, after `get_application_data(md::TimeSeriesMetadata) = md.application_data` (line 304) add:

```julia
"""
Decode the value axes IS stored on this catalog row, or `nothing` when the row has none.
For readers that hand back raw arrays, such as the forecast reader.
"""
function get_value_axes(md::TimeSeriesMetadata)
    value_axes = _value_axes_from_application_data(md.application_data)
    _check_value_axes(value_axes, Tuple(md.element_shape))
    return value_axes
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("value_axes")'`
Expected: PASS.

Then run the neighbouring suites that construct `SingleTimeSeries`:
Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests(r"SingleTimeSeries|N-D|consistency")'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/single_time_series.jl src/infrastore.jl src/time_series_structs.jl test/test_time_series_value_axes.jl
git commit -m "Store value_axes on SingleTimeSeries through application_data"
```

---

### Task 3: N-D `Deterministic` and DST through IS

**Files:**
- Modify: `src/utils/utils.jl:34-73` (`validate_time_series_data_for_backend`)
- Modify: `src/forecasts.jl:72-77` (add `_window_value_dims`)
- Modify: `src/deterministic.jl` (struct and inner constructor :31-71, outer constructors :74-157, :186-238, `convert_data` :250-255, accessors)
- Modify: `src/infrastore.jl` (`_infrastore_build_forecast(::Deterministic)` :1133-1150, `_truncate_window` :1319-1323, `_check_deterministic_window_shape` :1374-1390, `_forecast_from_store(::InfraStore.Deterministic)` :1402-1416)
- Test: `test/test_time_series_value_axes.jl`

**Interfaces:**
- Consumes (Tasks 1-2): `TimeSeriesAxis`, `_check_value_axes`, the codec, `get_value_axes(::SingleTimeSeries)`, `get_value_axes(::TimeSeriesMetadata)`, `_va_system`, `_va_sts`, `_va_bus_axis`.
- Produces:
  - `Deterministic(name, data, resolution; interval, ..., value_axes = nothing)` accepting `SortedDict{DateTime, Array{T, N}}` windows of plain numbers.
  - `get_value_axes(ts::Deterministic)`.
  - `get_time_series(IS.Deterministic, owner, name; start_time, len, count)` returning `Deterministic{T, N}` with `[H, *E]` windows and `value_axes`, for stored N-D `Deterministic` and for DST over N-D `SingleTimeSeries`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_time_series_value_axes.jl`:

```julia
function _va_nd_det(name; count = 2, horizon = 4, dims = (2, 3), value_axes = nothing)
    data = SortedDict{Dates.DateTime, Array{Float64, length(dims) + 1}}(
        _VA_T0 + Dates.Hour(horizon) * (k - 1) => rand(horizon, dims...) for k in 1:count
    )
    return IS.Deterministic(
        name, data, Dates.Hour(1);
        interval = Dates.Hour(horizon), value_axes = value_axes,
    )
end

function _va_same_windows(a, b)
    da, db = IS.get_data(a), IS.get_data(b)
    return collect(keys(da)) == collect(keys(db)) &&
           all(da[k] == db[k] for k in keys(da))
end

@testset "Test value_axes N-D Deterministic construction" begin
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), _va_bus_axis(3)]
    det = _va_nd_det("d"; value_axes = axes)
    @test det isa IS.Deterministic{Float64, 3}
    @test IS.get_value_axes(det) == axes
    @test IS.get_value_axes(IS.Deterministic(det, "e")) == axes
    @test_throws ArgumentError _va_nd_det("d"; value_axes = [_va_bus_axis(3)])
    ragged = SortedDict{Dates.DateTime, Array{Float64, 3}}(
        _VA_T0 => rand(4, 2, 3),
        _VA_T0 + Dates.Hour(4) => rand(4, 2, 2),
    )
    @test_throws ArgumentError IS.Deterministic(
        "r", ragged, Dates.Hour(1); interval = Dates.Hour(4),
    )
    composite = SortedDict{Dates.DateTime, Matrix{IS.LinearFunctionData}}(
        _VA_T0 => fill(IS.LinearFunctionData(1.0, 0.0), 4, 2),
    )
    @test_throws ArgumentError IS.Deterministic(
        "c", composite, Dates.Hour(1); interval = Dates.Hour(4),
    )
end

@testset "Test value_axes N-D Deterministic round-trip through the store" begin
    sys, (owner,) = _va_system()
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), _va_bus_axis(3)]
    det = _va_nd_det("d"; value_axes = axes)
    IS.add_time_series!(sys, owner, det)
    back = IS.get_time_series(IS.Deterministic, owner, "d")
    @test back isa IS.Deterministic{Float64, 3}
    @test _va_same_windows(back, det)
    @test IS.get_value_axes(back) == axes
    short = IS.get_time_series(IS.Deterministic, owner, "d"; len = 2)
    for (k, w) in IS.get_data(det)
        @test IS.get_data(short)[k] == w[1:2, :, :]
    end
    @test IS.get_value_axes(short) == axes
end

@testset "Test value_axes DST over N-D SingleTimeSeries" begin
    sys, owners = _va_system(2)
    cube = rand(24, 2, 3)
    cube_axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), _va_bus_axis(3)]
    mat = rand(24, 3)
    IS.add_time_series!(sys, owners, _va_sts("f", cube; value_axes = cube_axes))
    IS.add_time_series!(sys, owners[1], _va_sts("g", mat; value_axes = [_va_bus_axis(3)]))
    IS.transform_single_time_series!(
        sys, IS.DeterministicSingleTimeSeries, Dates.Hour(6), Dates.Hour(6),
    )
    for owner in owners
        det = IS.get_time_series(IS.Deterministic, owner, "f")
        @test IS.get_count(det) == 4
        for (i, w) in enumerate(values(IS.get_data(det)))
            @test w == cube[(6 * (i - 1) + 1):(6 * i), :, :]
        end
        @test IS.get_value_axes(det) == cube_axes
        # Review focus: a narrower window keeps its shape and its axes.
        short = IS.get_time_series(
            IS.Deterministic, owner, "f";
            start_time = _VA_T0 + Dates.Hour(6), len = 3, count = 1,
        )
        @test only(values(IS.get_data(short))) == cube[7:9, :, :]
        @test IS.get_value_axes(short) == cube_axes
    end
    matrix_det = IS.get_time_series(IS.Deterministic, owners[1], "g")
    @test first(values(IS.get_data(matrix_det))) == mat[1:6, :]
    @test IS.get_value_axes(matrix_det) == [_va_bus_axis(3)]

    # The forecast reader reads the shared array once and hands back raw [H, *E] windows.
    reader = IS.build_forecast_reader(
        sys, IS.Deterministic; resolution = Dates.Hour(1), name = "f",
    )
    @test IS.get_num_forecast_slots(reader) == 1
    IS.read_forecast_window!(reader, _VA_T0 + Dates.Hour(12))
    for i in 1:length(reader)
        @test IS.get_forecast_window(reader, i) == cube[13:18, :, :]
    end
    md = only(
        IS.list_time_series_metadata(
            owners[1]; time_series_type = IS.DeterministicSingleTimeSeries, name = "f",
        ),
    )
    @test IS.get_value_axes(md) == cube_axes
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("value_axes")'`
Expected: the three new testsets FAIL. Construction fails in `convert_data` / `validate_time_series_data_for_backend`; the DST read fails with "read back as a 4-dimensional array".

- [ ] **Step 3: Accept N-D windows in validation and conversion**

In `src/utils/utils.jl`, replace the supported-type method (lines 30-59) with:

```julia
"""
Validate that data in a SortedDict has element types the time series store can
encode, and that windows of rank >= 2 share one shape. Throws an ArgumentError otherwise.
"""
function validate_time_series_data_for_backend(
    data::SortedDict{Dates.DateTime, Array{T, N}},
) where {T, N}
    if !is_array_type_supported(T)
        supported = join(DETERMINISTIC_SUPPORTED_ELTYPES, ", ")
        if !isconcretetype(T)
            throw(
                ArgumentError(
                    "Cannot create time series with non-concrete element type. " *
                    "The data has value type Array{$T, $N} where $T is not concrete. " *
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
    _check_window_shapes(T, Val(N), data)
    return nothing
end

# Windows of rank >= 2 carry a per-step value shape: plain numbers only, one shape for all.
_check_window_shapes(::Type, ::Val{1}, _data) = nothing
_check_window_shapes(::Type{<:Real}, ::Val{1}, _data) = nothing

function _check_window_shapes(::Type{<:Real}, ::Val{N}, data) where {N}
    sizes = unique(size(w) for w in values(data))
    length(sizes) <= 1 || throw(
        ArgumentError("every Deterministic window must have the same size; got $sizes"),
    )
    return nothing
end

_check_window_shapes(::Type{T}, ::Val{N}, _data) where {T, N} = throw(
    ArgumentError(
        "Deterministic windows of rank $N need a plain numeric element type " *
        "(Float64, Int, ...); got $T",
    ),
)
```

In the fallback method's message (line 68) replace `SortedDict{Dates.DateTime, Vector{T}}` with `SortedDict{Dates.DateTime, Array{T, N}}`, and update the comment above it the same way.

In `src/deterministic.jl`, replace the `Vector{T}` method of `convert_data` (line 253):

```julia
# If values are more specific, don't assume CONSTANT but do upgrade some types
convert_data(data::AbstractDict{<:Any, Array{T, N}}) where {T, N} =
    SortedDict{Dates.DateTime, Array{T, N}}(data)
```

`Probabilistic`'s `Matrix{T}` methods (`src/probabilistic.jl:242-248`) stay more specific, so they still win for matrix windows.

In `src/forecasts.jl`, after `_window_ndims` (line 73) add:

```julia
# The shape of one step's value: a window's size without its leading horizon axis.
_window_value_dims(data::AbstractDict) =
    isempty(data) ? () : Base.tail(size(first(values(data))))
```

- [ ] **Step 4: Add `value_axes` to `Deterministic`**

In `src/deterministic.jl`:

1. Docstring struct block and `# Arguments`: add `value_axes::Union{Nothing, Vector{TimeSeriesAxis}}` with the same wording as `SingleTimeSeries`.

2. Struct: after the `unit_system` field (line 44) add:

```julia
    "labeled non-time axes of the window values (see [`TimeSeriesAxis`](@ref)), or `nothing`"
    value_axes::Union{Nothing, Vector{TimeSeriesAxis}}
```

3. Inner constructor (lines 50-70): add the parameter and the check:

```julia
    function Deterministic{T, N}(
        name::AbstractString,
        data::SortedDict{Dates.DateTime, Array{T, N}},
        resolution::Dates.Period,
        interval::Dates.Period,
        units::Union{Nothing, AbstractString} = nothing,
        quantity_kind::Union{Nothing, AbstractString} = nothing,
        unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
        value_axes::Union{Nothing, Vector{TimeSeriesAxis}} = nothing,
    ) where {T, N}
        validate_time_series_data_for_backend(data)
        _check_value_axes(value_axes, _window_value_dims(data))
        return new{T, N}(
            String(name),
            data,
            resolution,
            interval,
            _maybe_string(units),
            _maybe_string(quantity_kind),
            unit_system,
            value_axes,
        )
    end
```

4. Replace the three outer constructors at lines 74-157 (the 4-positional form, the keyword form, and the 3-positional form) with:

```julia
function Deterministic(
    name::AbstractString,
    data::AbstractDict{Dates.DateTime},
    resolution::Dates.Period,
    interval::Dates.Period;
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
    value_axes::Union{Nothing, Vector{TimeSeriesAxis}} = nothing,
)
    sorted = _ensure_sorted_dict(data)
    return Deterministic{_window_eltype(sorted), _window_ndims(sorted)}(
        String(name),
        sorted,
        resolution,
        interval,
        units,
        quantity_kind,
        unit_system,
        value_axes,
    )
end

function Deterministic(;
    name,
    data,
    resolution,
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
    value_axes::Union{Nothing, Vector{TimeSeriesAxis}} = nothing,
)
    if isnothing(interval)
        interval = get_interval_from_initial_times(get_sorted_keys(data))
    end
    converted_data = convert_data(data)
    data = handle_normalization_factor(converted_data, normalization_factor)
    return Deterministic(
        name,
        data,
        resolution,
        interval;
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
        value_axes = value_axes,
    )
end

function Deterministic(
    name::AbstractString,
    data::AbstractDict,
    resolution::Dates.Period;
    interval::Union{Nothing, Dates.Period} = nothing,
    normalization_factor::NormalizationFactor = 1.0,
    units::Union{Nothing, AbstractString} = nothing,
    quantity_kind::Union{Nothing, AbstractString} = nothing,
    unit_system::Union{Nothing, AbstractUnitSystem} = nothing,
    value_axes::Union{Nothing, Vector{TimeSeriesAxis}} = nothing,
)
    return Deterministic(;
        name = name,
        data = data,
        resolution = resolution,
        interval = interval,
        normalization_factor = normalization_factor,
        units = units,
        quantity_kind = quantity_kind,
        unit_system = unit_system,
        value_axes = value_axes,
    )
end
```

The `TimeArray`-dict constructor (line 159) stays as it is: it builds 1-D windows, which have no value axes.

5. Replace `Deterministic(forecast::Deterministic, data)` (line 186) with:

```julia
function Deterministic(forecast::Deterministic, data)
    return Deterministic(
        get_name(forecast),
        data,
        get_resolution(forecast),
        get_interval(forecast);
        units = get_units(forecast),
        quantity_kind = get_quantity_kind(forecast),
        unit_system = get_unit_system(forecast),
        value_axes = get_value_axes(forecast),
    )
end
```

6. Replace the body of `Deterministic(src::Deterministic, name::AbstractString)` (line 227, keep its docstring) with:

```julia
function Deterministic(
    src::Deterministic,
    name::AbstractString,
)
    return Deterministic(
        name,
        src.data,
        src.resolution,
        src.interval;
        units = src.units,
        quantity_kind = src.quantity_kind,
        unit_system = src.unit_system,
        value_axes = src.value_axes,
    )
end
```

7. After `get_interval(value::Deterministic) = value.interval` add:

```julia
"""
Get [`Deterministic`](@ref) `value_axes`.
"""
get_value_axes(value::Deterministic) = value.value_axes
```

- [ ] **Step 5: Fix the store write and read paths**

In `src/infrastore.jl`:

1. `_infrastore_build_forecast(ts::Deterministic, ...)` (line 1137). Replace the comment above it and the body:

```julia
# Windows are stacked along a new second axis: (horizon_count, count, *E). A composite
# element type is then packed across a further axis by the store.
function _infrastore_build_forecast(
    ts::Deterministic,
    initial,
    resolution,
    horizon,
    interval,
    name,
)
    windows = collect(values(get_data(ts)))
    return InfraStore.Deterministic(initial, resolution, horizon, interval,
        length(windows), stack(windows; dims = 2), name;
        units = get_units(ts),
        quantity_kind = get_quantity_kind(ts),
        unit_system = _to_store_unit_system(get_unit_system(ts)),
        application_data = _value_axes_application_data(get_value_axes(ts)))
end
```

2. Replace the three `_truncate_window` methods (lines 1321-1323) with:

```julia
# `len`, when given, truncates a window to its first `len` horizon steps (the
# horizon is the leading axis of a window of any rank).
_truncate_window(w, ::Nothing) = w
_truncate_window(w::AbstractArray, len::Int) = collect(selectdim(w, 1, 1:len))
```

3. Replace `_check_deterministic_window_shape` (lines 1374-1390) with:

```julia
# A `Deterministic`'s decoded values are `(horizon_count, count, *E)`: plain-dtype
# values may carry any per-step shape E. A composite element type that read back with
# extra axes did not decode; slicing it would return the wrong numbers, so it is named.
const _PLAIN_STORE_DTYPES =
    ("f64", "f32", "i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "bool")

_check_deterministic_window_shape(::AbstractMatrix, ::String, _element_type) = nothing

function _check_deterministic_window_shape(data::AbstractArray, name::String, element_type)
    something(element_type, "f64") in _PLAIN_STORE_DTYPES && return nothing
    throw(
        ArgumentError(
            "Deterministic '$name' read back as a $(ndims(data))-dimensional array " *
            "with element type $(something(element_type, "f64")); a Deterministic's " *
            "windows are the columns of a (horizon_count, count) matrix. Its stored " *
            "element type does not describe the values it holds.",
        ),
    )
end
```

The existing test at `test/test_time_series.jl:6701` passes `"piecewise_step"` with a rank-3 array and still expects this error.

4. In `_forecast_from_store(d::InfraStore.Deterministic, name, len)` (line 1402) replace the window and constructor lines:

```julia
    # Window i is d.data[:, i, ...], materialized: a view would keep the whole
    # forecast array alive behind every window.
    window(i) = _truncate_window(copy(selectdim(d.data, 2, i)), len)
    data = _assemble_forecast_windows(d.initial_timestamp, d.interval, d.count, window)
    return Deterministic(; name = name, data = data,
        resolution = d.resolution, interval = d.interval, units = d.units,
        quantity_kind = d.quantity_kind,
        unit_system = _from_store_unit_system(d.unit_system),
        value_axes = _value_axes_from_application_data(d.application_data))
```

Remove the old comment lines about `d.data[:, i]` that this replaces.

- [ ] **Step 6: Run the tests**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("value_axes")'`
Expected: PASS.

Two places may still fail, because their N-D behavior is untested upstream:

- If `IS.get_value_axes(det)` is `nothing` for the **DST** read only (stored `Deterministic` passes), InfraStore.jl's DST materialization does not copy `application_data` from the catalog row. Read it from the row instead: in `_infrastore_read_forecast` (`src/infrastore.jl:1268`), after the store read, rebuild the axes with `_value_axes_from_application_data(InfraStore.get_metadata_by_id(store.inner, Int64(get_association_id(key))).application_data)` and pass them to `_forecast_from_store` as a new last argument. Record the gap in the commit message so it can be raised on infrastore#100.
- If the forecast reader assertion fails, print `size(IS.get_forecast_window(reader, 1))`. When it is not `(6, 2, 3)`, permute in `_decode_forecast_reader_window(::Type{<:AbstractDeterministic}, raw, element_type)` (`src/infrastore.jl:1478`) so the window is `[H, *E]`, and add a comment naming the layout the reader returns.

Then run every forecast suite:
Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests(r"Deterministic|Forecast|forecast|DST|transform")'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/utils/utils.jl src/forecasts.jl src/deterministic.jl src/infrastore.jl test/test_time_series_value_axes.jl
git commit -m "Read and write N-D Deterministic and DST windows through IS, with value_axes"
```

---

### Task 4: `get_window` stops returning wrong values for N-D windows

**Files:**
- Modify: `src/forecasts.jl:203-240` (`get_window_common`)
- Test: `test/test_time_series_value_axes.jl`

**Interfaces:**
- Consumes (Task 3): `_va_nd_det`.
- Produces: `get_window(f, initial_time; len)` unchanged for vector and matrix windows; an `ArgumentError` for rank 3 and above.

- [ ] **Step 1: Write the failing test**

Append to `test/test_time_series_value_axes.jl`:

```julia
@testset "Test value_axes get_window rejects N-D windows" begin
    @test_throws ArgumentError IS.get_window(_va_nd_det("d"), _VA_T0)
    vector_det = IS.Deterministic(
        "v",
        SortedDict{Dates.DateTime, Vector{Float64}}(_VA_T0 => collect(1.0:4)),
        Dates.Hour(1),
    )
    @test IS.TimeSeries.values(IS.get_window(vector_det, _VA_T0; len = 2)) == [1.0, 2.0]
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("get_window rejects")'`
Expected: FAIL. No exception is thrown; the rank-3 window is sliced by linear index.

- [ ] **Step 3: Implement**

In `get_window_common` replace the `if ndims(data) == 2 ... end` block and the `return` line with:

```julia
    data = selectdim(data, 1, 1:len)
    return _window_time_array(make_timestamps(forecast, initial_time, len), data)
end

# A `TimeArray` holds at most a (time, column) matrix.
_window_time_array(timestamps, data::AbstractVecOrMat) =
    TimeSeries.TimeArray(timestamps, data)
_window_time_array(_timestamps, data::AbstractArray) = throw(
    ArgumentError(
        "get_window returns a TimeArray, which holds at most 2 dimensions, but this " *
        "window has $(ndims(data)); read N-D windows with get_data(forecast)[initial_time]",
    ),
)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests(r"get_window|value_axes|Probabilistic|Scenarios")'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/forecasts.jl test/test_time_series_value_axes.jl
git commit -m "Reject N-D windows in get_window instead of slicing them by linear index"
```

---

### Task 5: `value_axes` survive both serialization paths

**Files:**
- Test: `test/test_time_series_value_axes.jl`
- Modify only if the test fails: the read or write site it points at.

**Interfaces:**
- Consumes: `validate_serialization(sys)` from `test/test_serialization.jl:1` (returns `(sys2, ok::Bool)`), `openapi_time_series_association_json`, `serialize_arrays`, `deserialize_arrays`, `import_time_series_association_rows!`, `get_time_series(store::Store, key)`.
- Produces: no new API.

- [ ] **Step 1: Write the test**

Append to `test/test_time_series_value_axes.jl`:

```julia
@testset "Test value_axes survive both serialization paths" begin
    sys, owners = _va_system(2)
    axes = [IS.TimeSeriesAxis("zone", ["a", "b"]), _va_bus_axis(3)]
    IS.add_time_series!(sys, owners, _va_sts("f", rand(24, 2, 3); value_axes = axes))
    IS.transform_single_time_series!(
        sys, IS.DeterministicSingleTimeSeries, Dates.Hour(6), Dates.Hour(6),
    )

    # Legacy: the JSON document plus the store's .h5 and .sqlite.
    sys2, ok = validate_serialization(sys)
    @test ok
    owner2 = IS.get_component(IS.TestComponent, sys2, IS.get_name(owners[1]))
    @test IS.get_value_axes(IS.get_time_series(IS.SingleTimeSeries, owner2, "f")) == axes
    @test IS.get_value_axes(IS.get_time_series(IS.Deterministic, owner2, "f")) == axes

    # OpenAPI: the association rows plus the array half alone.
    dir = mktempdir()
    rows = IS.openapi_time_series_association_json(sys)
    IS.serialize_arrays(IS.get_data_store(sys), joinpath(dir, "arrays.h5"))
    store = IS.deserialize_arrays(joinpath(dir, "arrays.h5"))
    IS.import_time_series_association_rows!(store, rows)
    mds = IS.list_time_series_metadata(owners[1])
    @test length(mds) == 2
    for md in mds
        @test IS.get_value_axes(IS.get_time_series(store, IS.get_time_series_key(md))) ==
              axes
    end
end
```

- [ ] **Step 2: Run it**

Run: `julia --project=test -e 'include("test/InfrastructureSystemsTests.jl"); run_tests("serialization paths")'`
Expected: PASS with no code change, because both paths carry `application_data` verbatim.
If it fails, the failing assertion names the path. Fix the site that drops `application_data` there, and keep the test.

- [ ] **Step 3: Commit**

```bash
git add test/test_time_series_value_axes.jl
git commit -m "Test that value_axes survive legacy and OpenAPI serialization"
```

---

### Task 6: The distribution-factor benchmark

**Files:**
- Modify: `benchmark/bench.jl` (last 7 lines)
- Create: `benchmark/matrix_bench.jl`
- Modify: `benchmark/README.md` (new section at the end)

**Interfaces:**
- Consumes from `bench.jl`: `build_system(n) -> (sys, comps, dir)`, `timed_op(kind, eltype, op, n, f) -> Bool`, `report(kind, eltype, op, n, t, bytes, status)`, `report_maxrss(kind, eltype)`, `T0`, `RES`.
- Consumes from Tasks 1-3: `IS.TimeSeriesAxis`, `value_axes` keyword, `IS.get_value_axes` on series and metadata, N-D `Deterministic` reads.
- Produces: CSV rows `kind,eltype,op,n,total_s,us_per_op,bytes,status` with `kind` in `B0-Det, B0-DST, M1, M2, M2-DST`.

- [ ] **Step 1: Guard `bench.jl`'s run**

Replace the last lines of `benchmark/bench.jl` (from `println("kind,eltype,op,n,total_s,us_per_op,bytes,status")` to the end) with:

```julia
# Guarded so other benchmark scripts can include this file for its helpers.
if abspath(PROGRAM_FILE) == @__FILE__
    println("kind,eltype,op,n,total_s,us_per_op,bytes,status")
    # Warmup (JIT) on a small system.
    redirect_stdout(devnull) do
        run_all(40, 40, 40)
    end
    run_all(N, SWEEP_N, SCALING_N)
    println("DONE")
end
```

- [ ] **Step 2: Check `bench.jl` still runs**

Run: `BENCH_N=40 BENCH_SWEEP_N=40 BENCH_SCALING_N=80 julia --project=test benchmark/bench.jl | tail -2`
Expected: the last line is `DONE`.

- [ ] **Step 3: Write `benchmark/matrix_bench.jl`**

```julia
# Load-zone distribution factors: one series per bus against one matrix series.
#
#   julia --project=test benchmark/matrix_bench.jl > matrix.csv   # every case, fresh process each
#   julia --project=test benchmark/matrix_bench.jl M2              # one case, rows only
#
# Sizes: MATRIX_BUSES (50000), MATRIX_ZONES (8), MATRIX_STEPS (24). See README.md.
include(joinpath(@__DIR__, "bench.jl"))  # helpers only; its own run is guarded

const TS_NAME = "distribution_factor"
const CASES = ("B0-Det", "B0-DST", "M1", "M2", "M2-DST")
const READ_REPEATS = parse(Int, get(ENV, "MATRIX_READ_REPEATS", "3"))

struct Fixture
    nzone::Int
    nbus::Int
    steps::Int
    members::Vector{Vector{Int}}      # bus numbers per zone, ascending
    factors::Vector{Matrix{Float64}}  # (steps, members) per zone; each row sums to 1
end

# Bus b sits in zone mod1(b, nzone). Factors are smooth in time, distinct per bus so the
# store cannot deduplicate them, and normalized within each zone at every step.
function Fixture(nzone, nbus, steps)
    members = [collect(z:nzone:nbus) for z in 1:nzone]
    factors = map(members) do buses
        raw = [1.0 + 0.5 * sinpi(2 * (t + b) / steps) + 1e-6 * b for t in 1:steps, b in buses]
        raw ./ sum(raw; dims = 2)
    end
    return Fixture(nzone, nbus, steps, members, factors)
end

# ---- payloads (built outside the timed write) ----------------------------------

per_bus(fx, make) =
    [(z, b, make(fx.factors[z][:, j])) for z in 1:fx.nzone for (j, b) in enumerate(fx.members[z])]

m1_payload(fx) = [
    IS.SingleTimeSeries(TS_NAME, T0, RES, fx.factors[z];
        value_axes = [IS.TimeSeriesAxis("bus", fx.members[z])])
    for z in 1:fx.nzone
]

# One (steps, zone, bus) array over every bus; 0 where a bus is outside the zone.
function m2_payload(fx, zones)
    a = zeros(fx.steps, fx.nzone, fx.nbus)
    for z in 1:fx.nzone, (j, b) in enumerate(fx.members[z])
        a[:, z, b] .= view(fx.factors[z], :, j)
    end
    value_axes = [
        IS.TimeSeriesAxis("zone", IS.get_name.(zones)),
        IS.TimeSeriesAxis("bus", collect(1:fx.nbus)),
    ]
    return IS.SingleTimeSeries(TS_NAME, T0, RES, a; value_axes = value_axes)
end

function make_payload(case, fx, zones)
    case == "B0-Det" &&
        return per_bus(fx, v -> IS.Deterministic(TS_NAME, SortedDict(T0 => v), RES))
    case == "B0-DST" && return per_bus(fx, v -> IS.SingleTimeSeries(TS_NAME, T0, RES, v))
    case == "M1" && return m1_payload(fx)
    return m2_payload(fx, zones)
end

# ---- writes --------------------------------------------------------------------

function write_case!(case, sys, zones, items, fx)
    if case in ("B0-Det", "B0-DST")
        IS.time_series_transaction(sys) do txn
            for (z, b, ts) in items
                IS.add_time_series!(txn, zones[z], ts; features = Dict{String, Any}("bus" => b))
            end
        end
    elseif case == "M1"
        IS.time_series_transaction(sys) do txn
            for (zone, ts) in zip(zones, items)
                IS.add_time_series!(txn, zone, ts)
            end
        end
    else
        IS.add_time_series!(sys, zones, items)  # one array, one row per zone
    end
    case in ("B0-DST", "M2-DST") && IS.transform_single_time_series!(
        sys, IS.DeterministicSingleTimeSeries, Hour(fx.steps), Hour(fx.steps),
    )
    return
end

# ---- reads: each returns (bus numbers, (steps, buses) factors) for one zone -----

# PowerOperationsModels cc12092: one catalog pass, then one window read per member bus.
function read_zone_per_bus(fx, zone, z)
    keys = Dict{Int, IS.TimeSeriesKey}()
    for md in IS.list_time_series_metadata(
        zone; time_series_type = IS.Deterministic, name = TS_NAME,
    )
        keys[IS.get_features(md)["bus"]] = IS.get_time_series_key(md)
    end
    buses = fx.members[z]
    out = Matrix{Float64}(undef, fx.steps, length(buses))
    for (j, b) in enumerate(buses)
        out[:, j] = IS.get_time_series_values(zone, keys[b]; start_time = T0, len = fx.steps)
    end
    return buses, out
end

function read_zone_m1(fx, zone)
    ts = IS.get_time_series(IS.SingleTimeSeries, zone, TS_NAME; start_time = T0, len = fx.steps)
    return only(IS.get_value_axes(ts)).labels, IS.get_array(ts)
end

# A zone's slice of a (steps, zone, bus) array: its buses are the nonzero columns.
function zone_slice(values, value_axes, zone)
    zone_axis, bus_axis = value_axes
    zi = findfirst(==(IS.get_name(zone)), zone_axis.labels)
    cols = findall(!iszero, view(values, 1, zi, :))
    return bus_axis.labels[cols], values[:, zi, cols]
end

function read_zone_m2(fx, zone)
    ts = IS.get_time_series(IS.SingleTimeSeries, zone, TS_NAME; start_time = T0, len = fx.steps)
    return zone_slice(IS.get_array(ts), IS.get_value_axes(ts), zone)
end

function read_zone_m2_dst(fx, zone)
    det = IS.get_time_series(IS.Deterministic, zone, TS_NAME; start_time = T0, len = fx.steps)
    return zone_slice(only(values(IS.get_data(det))), IS.get_value_axes(det), zone)
end

function read_zone(case, fx, zone, z)
    case in ("B0-Det", "B0-DST") && return read_zone_per_bus(fx, zone, z)
    case == "M1" && return read_zone_m1(fx, zone)
    case == "M2" && return read_zone_m2(fx, zone)
    return read_zone_m2_dst(fx, zone)
end

# Group zones by the array behind their row and read each array once. M2's rows share
# their labels as well as their array, so the first row's axes serve every zone.
function read_all_m2(fx, zones)
    hashes = IS.get_time_series_hashes(zones, IS.SingleTimeSeries, TS_NAME)
    arrays = Dict{String, IS.SingleTimeSeries}()
    return map(zones) do zone
        ts = get!(arrays, hashes[IS.get_id(zone)]) do
            IS.get_time_series(IS.SingleTimeSeries, zone, TS_NAME; start_time = T0, len = fx.steps)
        end
        zone_slice(IS.get_array(ts), IS.get_value_axes(ts), zone)
    end
end

# The forecast reader reads a shared array once per window; labels come from the row.
function read_all_m2_dst(sys, zones)
    reader = IS.build_forecast_reader(sys, IS.Deterministic; resolution = RES, name = TS_NAME)
    IS.read_forecast_window!(reader, T0)
    entries = IS.get_forecast_reader_entries(reader)
    return map(zones) do zone
        i = findfirst(e -> e.owner === zone, entries)
        md = only(IS.list_time_series_metadata(
            zone; time_series_type = IS.Deterministic, name = TS_NAME,
        ))
        zone_slice(IS.get_forecast_window(reader, i), IS.get_value_axes(md), zone)
    end
end

read_all(case, fx, sys, zones) =
    case == "M2" ? read_all_m2(fx, zones) : read_all_m2_dst(sys, zones)

# ---- serialization -------------------------------------------------------------

function ser_legacy(sys, dir)
    path = joinpath(dir, "system.json")
    IS.prepare_for_serialization_to_file!(sys, path; force = true)
    open(io -> IS.JSON.json(io, IS.serialize(sys)), path, "w")
    return path
end

# Component deserialization is normally directed by the parent package; replicate it.
function de_legacy(path)
    data = open(io -> IS.JSON.parse(io; dicttype = Dict{String, Any}), path)
    return cd(dirname(path)) do
        sys2 = IS.deserialize(IS.SystemData, data)
        for component in data["components"]
            type = IS.get_type_from_serialization_data(component)
            IS.add_component!(
                sys2, IS.deserialize(type, component); allow_existing_time_series = true,
            )
        end
        sys2
    end
end

function ser_openapi(sys, dir)
    write(joinpath(dir, "rows.json"), IS.openapi_time_series_association_json(sys))
    IS.serialize_arrays(IS.get_data_store(sys), joinpath(dir, "arrays.h5"))
    return
end

function de_openapi(dir)
    store = IS.deserialize_arrays(joinpath(dir, "arrays.h5"))
    IS.import_time_series_association_rows!(store, read(joinpath(dir, "rows.json"), String))
    return store
end

# ---- checks and sizes ----------------------------------------------------------

function check(case, op, fx, got)
    ok = !isnothing(got) && all(1:fx.nzone) do z
        buses, values = got[z]
        buses == fx.members[z] && values == fx.factors[z]
    end
    status = ok ? "ok" : "error: factors differ from the fixture"
    report(case, "float64", "check_" * op, 1, 0.0, 0, status)
end

series_values(ts::IS.SingleTimeSeries) = IS.get_array(ts)
series_values(ts::IS.Deterministic) = collect(values(IS.get_data(ts)))

# Association ids survive the OpenAPI path, so every original key must read the same.
function check_store(case, sys, zones, store)
    original = IS.get_data_store(sys)
    ok = all(zones) do zone
        all(IS.list_time_series_metadata(zone; name = TS_NAME)) do md
            key = IS.get_time_series_key(md)
            a, b = IS.get_time_series(store, key), IS.get_time_series(original, key)
            series_values(a) == series_values(b) && IS.get_value_axes(a) == IS.get_value_axes(b)
        end
    end
    report(case, "float64", "check_de_openapi", 1, 0.0, 0, ok ? "ok" : "error: store differs")
end

# Bytes per file extension (.h5, .sqlite, .json) under `dir`.
function report_files(case, prefix, dir)
    sizes = Dict{String, Int}()
    for f in readdir(dir)
        ext = last(splitext(f))
        sizes[ext] = get(sizes, ext, 0) + filesize(joinpath(dir, f))
    end
    for (ext, bytes) in sort!(collect(sizes))
        report(case, "float64", "$(prefix)_bytes$(ext)", 1, 0.0, bytes, "ok")
    end
end

# ---- one case ------------------------------------------------------------------

function run_case(case, fx)
    sys, zones, dir = build_system(fx.nzone)
    n = fx.nbus
    items = make_payload(case, fx, zones)
    timed_op(case, "float64", "write", n, () -> write_case!(case, sys, zones, items, fx))
    items = nothing
    report_files(case, "store", dir)

    # Reads leave the store as it was, so they repeat; the report takes each op's median.
    got = Ref{Any}(nothing)
    for _ in 1:READ_REPEATS
        timed_op(case, "float64", "read_zone", n,
            () -> got[] = [read_zone(case, fx, zone, z) for (z, zone) in enumerate(zones)])
    end
    check(case, "read_zone", fx, got[])
    if case in ("M2", "M2-DST")
        got[] = nothing
        for _ in 1:READ_REPEATS
            timed_op(case, "float64", "read_all_once", n,
                () -> got[] = read_all(case, fx, sys, zones))
        end
        check(case, "read_all_once", fx, got[])
    end

    legacy_dir = mktempdir()
    path = Ref{String}()
    timed_op(case, "float64", "ser_legacy", n, () -> path[] = ser_legacy(sys, legacy_dir))
    report_files(case, "legacy", legacy_dir)
    sys2 = Ref{Any}(nothing)
    timed_op(case, "float64", "de_legacy", n, () -> sys2[] = de_legacy(path[]))
    if !isnothing(sys2[])
        zones2 = [IS.get_component(IS.TestComponent, sys2[], IS.get_name(z)) for z in zones]
        check(case, "de_legacy", fx, [read_zone(case, fx, zone, z) for (z, zone) in enumerate(zones2)])
    end

    api_dir = mktempdir()
    timed_op(case, "float64", "ser_openapi", n, () -> ser_openapi(sys, api_dir))
    report_files(case, "openapi", api_dir)
    store2 = Ref{Any}(nothing)
    timed_op(case, "float64", "de_openapi", n, () -> store2[] = de_openapi(api_dir))
    isnothing(store2[]) || check_store(case, sys, zones, store2[])

    report_maxrss(case, "float64")
    return
end

# ---- driver --------------------------------------------------------------------

function main(args)
    fx = Fixture(
        parse(Int, get(ENV, "MATRIX_ZONES", "8")),
        parse(Int, get(ENV, "MATRIX_BUSES", "50000")),
        parse(Int, get(ENV, "MATRIX_STEPS", "24")),
    )
    if isempty(args)
        println("kind,eltype,op,n,total_s,us_per_op,bytes,status")
        for case in CASES
            # A fresh process per case, so its maxrss row belongs to that case alone.
            cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) $(@__FILE__) $case`
            success(pipeline(cmd; stdout = stdout, stderr = stderr)) ||
                report(case, "float64", "process", 1, NaN, 0, "error: case process failed")
        end
        println("DONE")
        return
    end
    case = only(args)
    case in CASES || error("unknown case $case; expected one of $(join(CASES, ", "))")
    # JIT warmup on a small fixture, so the timed rows measure the run, not compilation.
    redirect_stdout(devnull) do
        run_case(case, Fixture(fx.nzone, 16 * fx.nzone, fx.steps))
    end
    run_case(case, fx)
    return
end

abspath(PROGRAM_FILE) == @__FILE__ && main(ARGS)
```

- [ ] **Step 4: Smoke-run at a small size**

Run: `MATRIX_BUSES=64 MATRIX_ZONES=4 julia --project=test benchmark/matrix_bench.jl | tee /dev/stderr | grep -c error`
Expected: prints `0`. Every case emits `write`, `read_zone`, `ser_*`, `de_*` rows with status `ok`, and every `check_*` row is `ok`. The last line is `DONE`.

If a row reads `error: ...`, the message names the failing op. Fix the cause, not the check.

- [ ] **Step 5: Document it**

Append to `benchmark/README.md`:

~~~markdown
## Matrix-valued distribution factors

`matrix_bench.jl` compares load-zone distribution factors stored one series per bus with one matrix series, for reads and for both serialization paths.
It runs each representation in a fresh process, so each `maxrss` row belongs to one case.

```sh
julia --project=test benchmark/matrix_bench.jl > matrix.csv
```

| case | what is stored |
|---|---|
| `B0-Det` | one scalar `Deterministic` per bus, owned by its zone, with feature `"bus"` |
| `B0-DST` | one scalar `SingleTimeSeries` per bus, then `transform_single_time_series!` |
| `M1` | one `SingleTimeSeries{Float64, 2}` per zone, `[steps, members]`, bus labels in `value_axes` |
| `M2` | one `[steps, zones, buses]` array owned by every zone, 0 for non-members |
| `M2-DST` | `M2` plus `transform_single_time_series!` |

Sizes come from `MATRIX_BUSES` (50000), `MATRIX_ZONES` (8) and `MATRIX_STEPS` (24).
Read ops repeat `MATRIX_READ_REPEATS` (3) times; take the median of their rows.
Every `check_*` row compares the factors read back with the generated ones and must be `ok`.
~~~

- [ ] **Step 6: Commit**

```bash
git add benchmark/bench.jl benchmark/matrix_bench.jl benchmark/README.md
git commit -m "Add the load-zone distribution-factor matrix benchmark"
```

---

### Task 7: Verify the branch

**Files:** none changed unless a check fails.

- [ ] **Step 1: Format**

Run: `julia scripts/formatter/formatter_code.jl`
Then: `git status --short`
Expected: only files this plan touched are modified. Commit any formatting changes: `git commit -am "Format"`.

- [ ] **Step 2: Full test suite**

Run: `julia --project=test test/runtests.jl`
Expected: all pass, including Aqua. The baseline is 8,771 passing and 1 broken (2026-07-29); the new count is that plus this plan's tests. A failure anywhere gets fixed, even outside this plan's files.

- [ ] **Step 3: psy6 stack smoke**

Run: `julia --project=/Users/rhenriqu/Repos/PSY6 -e 'using PowerSystems, PowerNetworkMatrices, PowerFlows, PowerOperationsModels, PowerSystemCaseBuilder'`
Expected: loads without error. If the workspace does not develop this checkout of IS, say so in the report rather than skipping silently.

- [ ] **Step 4: Full-size benchmark run**

Run: `julia --project=test benchmark/matrix_bench.jl > benchmark/matrix_results.csv`
Expected: `DONE` on the last line, no `error` rows. Leave `matrix_results.csv` uncommitted; Task 8 reads it.

---

### Task 8: Results report

**Files:** an HTML artifact, not part of the repo.

- [ ] **Step 1: Build the report**

Build an HTML page in the house template of `https://claude.ai/artifact/Pm14LBHAH2kWJTJzaThMpQ` (read it with the Artifact tool and reuse its `:root` tokens and component CSS).
Content, from `benchmark/matrix_results.csv`:

- A comparison table per op (`write`, `read_zone`, `read_all_once`, `ser_legacy`, `de_legacy`, `ser_openapi`, `de_openapi`) with one column per case, best cell tinted good.
- Bytes per artifact (`store_bytes.h5`, `.sqlite`, `legacy_bytes.json`, `openapi_bytes.*`) as bars drawn to scale.
- `maxrss` per case.
- A recommendation box: per bus, `M1` or `M2`, and whether `MatrixTimeSeries` needs to be a new type.
- A "How this was measured" footer: sizes, machine, InfraStore version, commit.

- [ ] **Step 2: Publish privately and hand back**

Publish it as a private artifact and give the user the link.
Do not post to NatLabRockies/infrastore#100: the user reviews the results first and decides what to post.
