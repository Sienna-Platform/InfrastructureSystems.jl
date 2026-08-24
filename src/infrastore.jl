# InfraStore-backed time series storage.
#
# InfraStore manages both the time series data and the associations between components /
# supplemental attributes and that data. The `Store` type (declared in `store.jl`)
# delegates BOTH array data and metadata to it, via the `InfraStore.jl` binding package.
# InfraStore owns both: arrays land in an HDF5 `.h5` file (content-addressed by SHA-256
# hash) and metadata in a sibling `.sqlite` file. Time series *data* identity is the
# array content hash, not a UUID. Persisting a system writes the `.h5` + `.sqlite` pair
# directly.
#
# This file holds the IS-specific glue (owner/feature conversion, window
# flatten/reshape, manager routing). All low-level FFI lives in `InfraStore`.

# ---- Store construction ----------------------------------------------------

"""
    open_infrastore_store(path; read_only=false)

Open an existing on-disk InfraStore store from its `.h5` base path.
"""
function open_infrastore_store(
    path::AbstractString;
    read_only::Bool = false,
    catalog = :attached,
)
    # Open with an absolute path so the InfraStore handle's backing path survives later
    # `cd`s (e.g. a deserialize that opens a relative basename, then a re-serialize
    # elsewhere). Opening relative leaves the handle resolving its source relative to
    # the cwd at open time, so a later `persist!` fails once the cwd changes.
    abs_path = abspath(String(path))
    inner = InfraStore.open_store(abs_path; read_only = read_only, catalog = catalog)
    return Store(inner)
end

# The store's backing path (nothing for an in-memory store).
_store_path(store::Store) = InfraStore.get_path(store.inner)

# Translate the `InfraStore.get_compression` NamedTuple back into a
# `CompressionSettings`.
function _compression_settings(c)
    c.compression == :none && return CompressionSettings(; enabled = false)
    return CompressionSettings(;
        enabled = true,
        type = CompressionTypes.DEFLATE,
        level = c.level,
        shuffle = c.shuffle,
    )
end

"""
    open_deserialized_infrastore_store(source, directory, read_only)

Open the InfraStore store for a deserialized system. In read-only mode the source
artifacts are opened in place. Otherwise the `.h5` (+ sidecar `.sqlite`) are
copied to an isolated working location under `directory` (or `tempdir()`) and the
copy is opened writable, so mutating the deserialized system cannot corrupt the
source file (e.g. a cached system shared by later builds).

The writable copy holds its catalog in memory: it is scratch, and the system it backs is
itself in memory, so a crash loses both regardless. Changes reach disk only when the
system is serialized. A read-only open leaves the catalog attached — nothing mutates it,
so there is nothing to gain by reading it into RAM.
"""
function open_deserialized_infrastore_store(
    source::AbstractString,
    directory::Union{Nothing, AbstractString},
    read_only::Bool,
)
    read_only && return open_infrastore_store(source; read_only = true)
    dir = if isnothing(directory)
        tempdir()
    else
        String(directory)
    end
    mkpath(dir)
    dst = joinpath(dir, string(UUIDs.uuid4()) * "_time_series.h5")
    # The `.sqlite` is copied so the open below has a catalog to read into memory; it
    # is ignored from then on, and `serialize` writes a fresh pair.
    cp(source, dst; force = true)
    src_sqlite = source * ".sqlite"
    isfile(src_sqlite) && cp(src_sqlite, dst * ".sqlite"; force = true)
    return open_infrastore_store(dst; read_only = false, catalog = :memory)
end

close!(store::Store) = InfraStore.close!(store.inner)

# The store is an opaque handle onto its backing artifacts, so the default field-wise
# `deepcopy` would hand the copy the SAME handle: mutating the copy (e.g.
# `clear_time_series!`) would then mutate the original. The backend exposes no clone API,
# so round-trip through `persist!` + `open_store` to give the copy its own artifacts.
function Base.deepcopy_internal(store::Store, dict::IdDict)
    haskey(dict, store) && return dict[store]

    # `persist!` copies an on-disk store's artifacts and materializes an in-memory one.
    # An in-memory store has no path, so its copy lands in `tempdir()` and is therefore
    # disk-backed: the backend gives us no way to clone in-memory state in place.
    path = _store_path(store)
    directory = if isnothing(path)
        tempdir()
    else
        dirname(path)
    end
    dst = joinpath(directory, string(UUIDs.uuid4()) * "_time_series.h5")
    InfraStore.persist!(store.inner, dst)
    new_store =
        open_infrastore_store(dst; read_only = false, catalog = catalog_mode(store))
    dict[store] = new_store
    return new_store
end

# ---- Conversions -----------------------------------------------------------

# Unit system, between IS's `RelativeUnits` markers and the store's two-valued enum.
_to_store_unit_system(::Nothing) = nothing
_to_store_unit_system(::NaturalUnit) = InfraStore.NaturalUnits
_to_store_unit_system(::DeviceBaseUnit) = InfraStore.ComponentBase
_to_store_unit_system(::SystemBaseUnit) = throw(
    ArgumentError(
        "the time series store cannot represent SystemBaseUnit (SU): it records only " *
        "natural units (NU) and the component's own base (DU). Normalize the values to " *
        "one of those before adding the time series.",
    ),
)

# The store's spelling never carries a system base, so the inverse is total over
# what a read can actually produce.
_from_store_unit_system(::Nothing) = nothing
function _from_store_unit_system(unit_system::InfraStore.UnitSystem)
    unit_system === InfraStore.NaturalUnits && return NU
    unit_system === InfraStore.ComponentBase && return DU
    throw(ArgumentError("unrecognized store unit system: $unit_system"))
end

# Owner category of an association owner, as the `InfraStore.OwnerCategory`
# enum the binding takes everywhere. Accepts an owner instance or its type.
get_owner_category(
    ::Union{InfrastructureSystemsComponent, Type{<:InfrastructureSystemsComponent}},
) = InfraStore.Component
get_owner_category(
    ::Union{SupplementalAttribute, Type{<:SupplementalAttribute}},
) = InfraStore.SupplementalAttribute

# ---- Element encoding ------------------------------------------------------
# Scalars store as a 1-D array; structured elements as a `(length, k)` Float64 array.
# Every encoder returns the store's canonical `element_type` tag, a first-class catalog
# column, so reads reconstruct from it rather than from the opaque `ext` payload.

# Julia scalar element type -> canonical dtype spelling. Only the widths the
# store supports; anything else is an unsupported element type, not a silent
# widening.
const _INFRASTORE_DTYPE_NAMES = Dict{Type, String}(
    Float64 => "f64",
    Float32 => "f32",
    Int64 => "i64",
    Int32 => "i32",
    Int16 => "i16",
    Int8 => "i8",
    UInt64 => "u64",
    UInt32 => "u32",
    UInt16 => "u16",
    UInt8 => "u8",
    Bool => "bool",
)

function _element_type_name(::Type{T}) where {T}
    name = get(_INFRASTORE_DTYPE_NAMES, T, nothing)
    isnothing(name) &&
        error("InfraStore backend does not support time series element type $T yet")
    return name
end

_storage_array(v::AbstractVector{<:Real}) =
    (collect(v), _element_type_name(eltype(v)))

# N-D per-step scalars (`SingleTimeSeries{T, N}` / `NonSequentialTimeSeries{T, N}` with
# `N > 1`): the store takes the array whole, with dim 1 as the time axis, and the read
# side (`_decode_stored_values`) hands it back unchanged.
_storage_array(v::AbstractArray{<:Real}) =
    (collect(v), _element_type_name(eltype(v)))

# Encoded width `k` of a vector of structured elements, without encoding it. The forecast
# encoder needs the widest window's `k` before it allocates, so this is the single source
# of truth every `_storage_array` below allocates from.
_storage_width(::AbstractVector{LinearFunctionData}) = 2

_storage_width(::AbstractVector{QuadraticFunctionData}) = 3

_storage_width(v::AbstractVector{PiecewiseLinearData}) =
    1 + 2 * maximum(length(get_points(fd)) for fd in v; init = 0)

function _storage_width(v::AbstractVector{PiecewiseStepData})
    max_n = maximum(length(get_x_coords(fd)) for fd in v; init = 0)
    iszero(max_n) && return 1
    return 2 * max_n
end

_storage_width(::AbstractVector{NTuple{N, Float64}}) where {N} = N

_storage_width(v::AbstractVector) =
    error("InfraStore backend does not support time series element type $(eltype(v)) yet")

function _storage_array(v::AbstractVector{LinearFunctionData})
    mat = Matrix{Float64}(undef, length(v), _storage_width(v))
    for (i, fd) in enumerate(v)
        mat[i, 1] = get_proportional_term(fd)
        mat[i, 2] = get_constant_term(fd)
    end
    return (mat, "linear_function")
end

function _storage_array(v::AbstractVector{QuadraticFunctionData})
    mat = Matrix{Float64}(undef, length(v), _storage_width(v))
    for (i, fd) in enumerate(v)
        mat[i, 1] = get_quadratic_term(fd)
        mat[i, 2] = get_proportional_term(fd)
        mat[i, 3] = get_constant_term(fd)
    end
    return (mat, "quadratic_function")
end

# Ragged: each step has a variable number of (x, y) points. Store as a
# `(len, 1 + 2*max_points)` matrix padded with zeros; column 1 of each row is the
# point count, so `shape[0]` stays the timestep count.
function _storage_array(v::AbstractVector{PiecewiseLinearData})
    mat = zeros(Float64, length(v), _storage_width(v))
    for (i, fd) in enumerate(v)
        pts = get_points(fd)
        mat[i, 1] = length(pts)
        for (j, p) in enumerate(pts)
            mat[i, 2j] = p.x
            mat[i, 2j + 1] = p.y
        end
    end
    return (mat, "piecewise_linear")
end

# Ragged like PiecewiseLinearData, but the x- and y-coordinates have different
# lengths (`n` x-coords, `n - 1` y-coords/slopes). Store as a `(len, 2*max_n)`
# matrix: column 1 of each row is the x-coord count `n`, then the `n` x-coords,
# then the `n - 1` y-coords. Each row is self-describing, so decode needs no
# global width.
function _storage_array(v::AbstractVector{PiecewiseStepData})
    mat = zeros(Float64, length(v), _storage_width(v))
    for (i, fd) in enumerate(v)
        xs = get_x_coords(fd)
        ys = get_y_coords(fd)
        n = length(xs)
        mat[i, 1] = n
        for (j, x) in enumerate(xs)
            mat[i, 1 + j] = x
        end
        for (j, y) in enumerate(ys)
            mat[i, 1 + n + j] = y
        end
    end
    return (mat, "piecewise_step")
end

# Fixed-arity `NTuple{N, Float64}` values. Dense, so unlike the ragged piecewise
# encodings every row is full width; the arity travels in the element type so decode
# rebuilds the tuple without inferring it from the array shape.
function _storage_array(v::AbstractVector{NTuple{N, Float64}}) where {N}
    mat = Matrix{Float64}(undef, length(v), N)
    for (i, tup) in enumerate(v)
        for j in 1:N
            mat[i, j] = tup[j]
        end
    end
    return (mat, "tuple($N,f64)")
end

_storage_array(v::AbstractVector) =
    error("InfraStore backend does not support time series element type $(eltype(v)) yet")

# ---- Element encodings ------------------------------------------------------
# One singleton per stored `element_type` tag, so decoding dispatches instead of
# comparing the tag string per value. `ScalarEncoding` is also the fallback for any tag
# this binding does not map; `RowEncoding` marks one-element-per-matrix-row layouts,
# which is the distinction the forecast and reader paths branch on.
abstract type ElementEncoding end
abstract type RowEncoding <: ElementEncoding end

struct ScalarEncoding <: ElementEncoding end
struct LinearFunctionEncoding <: RowEncoding end
struct QuadraticFunctionEncoding <: RowEncoding end
struct PiecewiseLinearEncoding <: RowEncoding end
struct PiecewiseStepEncoding <: RowEncoding end

# Fixed-arity f64 tuples: the arity is part of the encoding, so `_decode_ntuples` gets it
# as a type parameter instead of re-parsing the tag. The store's grammar allows other
# dtypes, which this binding does not map (they fall through to `ScalarEncoding`).
struct TupleEncoding{N} <: RowEncoding end

const _ELEMENT_ENCODINGS = Dict{String, ElementEncoding}(
    "linear_function" => LinearFunctionEncoding(),
    "quadratic_function" => QuadraticFunctionEncoding(),
    "piecewise_linear" => PiecewiseLinearEncoding(),
    "piecewise_step" => PiecewiseStepEncoding(),
)

const _TUPLE_ELEMENT_TYPE = r"^tuple\((\d+),f64\)$"

# The string -> type barrier. Deliberately the only type-unstable step: every
# decode reached from here is dispatched and inferrable.
_element_encoding(::Nothing) = ScalarEncoding()

function _element_encoding(element_type::AbstractString)
    haskey(_ELEMENT_ENCODINGS, element_type) && return _ELEMENT_ENCODINGS[element_type]
    m = match(_TUPLE_ELEMENT_TYPE, element_type)
    isnothing(m) && return ScalarEncoding()
    return TupleEncoding{parse(Int, m.captures[1])}()
end

# Rebuild the `NTuple{N, Float64}` vector from rows of a stored/materialized `(len, N)`
# matrix. Shared by every decode path.
function _decode_ntuples(mat, len::Integer, n::Integer)
    out = Vector{NTuple{n, Float64}}(undef, len)
    for i in 1:len
        out[i] = ntuple(j -> mat[i, j], n)
    end
    return out
end

# Reconstruct a single `PiecewiseStepData` from row `i` of a stored/materialized
# `(len, k)` matrix (see `_storage_array`). Shared by every decode path.
function _decode_pwl_step_row(mat, i::Integer)
    n = Int(round(mat[i, 1]))
    xs = [mat[i, 1 + j] for j in 1:n]
    ys = [mat[i, 1 + n + j] for j in 1:(n - 1)]
    return PiecewiseStepData(xs, ys)
end

# Decode an already-materialized static value array (the inverse of `_storage_array`),
# one method per [`ElementEncoding`]. `len` is the timestep count (`size(arr, 1)`);
# each encoded element occupies one row of the `(len, k)` matrix.
_decode_static_values(arr, ::ScalarEncoding, ::Integer) = arr

_decode_static_values(arr, ::LinearFunctionEncoding, len::Integer) =
    [LinearFunctionData(arr[i, 1], arr[i, 2]) for i in 1:len]

_decode_static_values(arr, ::QuadraticFunctionEncoding, len::Integer) =
    [QuadraticFunctionData(arr[i, 1], arr[i, 2], arr[i, 3]) for i in 1:len]

function _decode_static_values(arr, ::PiecewiseLinearEncoding, len::Integer)
    out = Vector{PiecewiseLinearData}(undef, len)
    for i in 1:len
        n = Int(round(arr[i, 1]))
        out[i] = PiecewiseLinearData([(arr[i, 2j], arr[i, 2j + 1]) for j in 1:n])
    end
    return out
end

_decode_static_values(arr, ::PiecewiseStepEncoding, len::Integer) =
    [_decode_pwl_step_row(arr, i) for i in 1:len]

_decode_static_values(arr, ::TupleEncoding{N}, len::Integer) where {N} =
    _decode_ntuples(arr, len, N)

# Decode a whole stored static array, whatever its rank. A 1-D array is scalar
# data (one value per timestep) and is already the answer; a higher-rank array
# is either encoded elements or N-D per-step scalars, which the encoding
# distinguishes. Used by the `SingleTimeSeries` and `NonSequentialTimeSeries`
# read paths, where the backend materializes the array in memory rather than
# handing back a content hash.
_decode_stored_values(data::AbstractVector, ::ElementEncoding) = data

_decode_stored_values(data::AbstractArray, encoding::ElementEncoding) =
    _decode_static_values(data, encoding, size(data, 1))

# ---- Forecast element encoding ---------------------------------------------
# Forecast windows of scalars store as a `(horizon, count)` array of `f64`.
# FunctionData windows store as `(horizon, count, k)` tagged with the element
# type; each window column is encoded with the same scheme as a SingleTimeSeries
# via `_storage_array`.

function _storage_forecast_array(windows::Vector{<:AbstractVector{<:Real}})
    count = length(windows)
    horizon = length(first(windows))
    arr = Matrix{Float64}(undef, horizon, count)
    for (c, w) in enumerate(windows)
        copyto!(view(arr, :, c), w)
    end
    return (arr, "f64")
end

# FunctionData windows encode row-wise like a SingleTimeSeries (ragged PWL is
# padded to the widest row); NTuple windows are the same dense per-row layout at
# constant width. Both carry the element type that drives window reconstruction.
function _storage_forecast_array(
    windows::Vector{<:AbstractVector{<:Union{FunctionData, NTuple}}},
)
    count = length(windows)
    horizon = length(first(windows))
    k = maximum(_storage_width, windows)
    arr = zeros(Float64, horizon, count, k)
    element_type = ""
    for c in 1:count
        # Encoded one window at a time: holding all `count` matrices before the copy
        # would double the forecast's peak footprint.
        mat, element_type = _storage_array(windows[c])
        @views arr[:, c, 1:size(mat, 2)] .= mat
    end
    return (arr, element_type)
end

# Densify a Probabilistic/Scenarios forecast — a SortedDict of
# `(horizon_count, dim1)` window matrices — into the `(dim1, horizon_count,
# count)` array the store's forecast constructors take.
function _dense_forecast_array(forecast::Forecast, dim1::Integer)
    arr = Array{Float64, 3}(
        undef, dim1, get_horizon_count(forecast), get_count(forecast),
    )
    for (ix, window) in enumerate(values(get_data(forecast)))
        arr[:, :, ix] = transpose(window)
    end
    return arr
end

# Decode window `c` (1-based) of a `(horizon, count, k)` forecast array into a Vector of
# the corresponding FunctionData or NTuple; the per-window `(horizon, k)` slice decodes
# with the same row-wise scheme as a static array.
#
# Only a `RowEncoding` has a `k` axis, so a scalar tag on a 3-D array is a storage
# inconsistency, not a pass-through: `_forecast_window` routes 2-D (scalar) arrays
# elsewhere, and a scalar-tagged window would decode wrong. The tag string travels
# alongside the encoding purely to name it in that error.
_decode_forecast_window(
    ::AbstractArray{<:Real, 3}, ::ScalarEncoding, element_type, ::Integer,
) = error("InfraStore backend cannot decode forecast element_type $element_type")

_decode_forecast_window(
    arr::AbstractArray{<:Real, 3}, encoding::RowEncoding, _element_type, c::Integer,
) = _decode_static_values(@view(arr[:, c, :]), encoding, size(arr, 1))

# ---- Operations (thin delegations to InfraStore) ----------------------

"""
    make_add_batch() -> batch

A client-side staging buffer for [`serialize_single!`](@ref) /
[`serialize_non_sequential!`](@ref), committed with [`commit_batch!`](@ref).
Exists so packages that write stores directly (e.g. a parser emitting a
serialized system) never touch the InfraStore module themselves.
"""
make_add_batch() = InfraStore.AddBatch()

"""
    commit_batch!(store::Store, batch)

Commit a staged batch to `store` as one all-or-nothing bulk add. The backend
packs the arrays into batch-sized datasets written whole-chunk, so this is
materially cheaper than the same adds issued one at a time.
"""
function commit_batch!(store::Store, batch::InfraStore.AddBatch)
    InfraStore.add_time_series_bulk!(store.inner, batch)
    flush!(store)
    return
end

"""
    serialize_single!(batch, owner_id, owner_type, owner_category, name, sts;
                      features=Dict(), units=get_units(sts),
                      quantity_kind=get_quantity_kind(sts), unit_system=get_unit_system(sts))

Stage a `SingleTimeSeries` (data + metadata) onto a `InfraStore.AddBatch` for a
bulk commit (a direct add is a one-item batch). The array is content-addressed;
identical arrays are de-duplicated automatically. `owner_category` is the
`InfraStore.OwnerCategory` enum. Returns the encoded array's byte size — the
amount the batch keeps buffered until it flushes.
"""
function serialize_single!(
    batch::InfraStore.AddBatch,
    owner_id::Integer,
    owner_type::AbstractString,
    owner_category::InfraStore.OwnerCategory,
    name::AbstractString,
    sts::SingleTimeSeries;
    features = Dict{String, Any}(),
    units::Union{Nothing, AbstractString} = get_units(sts),
    quantity_kind::Union{Nothing, AbstractString} = get_quantity_kind(sts),
    unit_system::Union{Nothing, AbstractUnitSystem} = get_unit_system(sts),
)
    # `get_array` returns the raw `Array{T, N}` (no TimeArray allocation).
    arr, element_type = _storage_array(get_array(sts))
    tss_ts = InfraStore.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        arr,
        name;
        element_type = element_type,
    )
    InfraStore.add_time_series!(batch, owner_id, owner_type,
        owner_category, tss_ts; features = features, units = units,
        quantity_kind = quantity_kind,
        unit_system = _to_store_unit_system(unit_system))
    # The encoded array is what the batch buffers; its byte size drives auto-flush.
    return sizeof(arr)
end

"""
    serialize_non_sequential!(batch, owner_id, owner_type, owner_category, name, nts;
                              features=Dict(), units=get_units(nts),
                              quantity_kind=get_quantity_kind(nts),
                              unit_system=get_unit_system(nts))

Stage a `NonSequentialTimeSeries` (irregular timestamps + data) onto a
`InfraStore.AddBatch` for a bulk commit (a direct add is a one-item batch). The
array is content-addressed (and de-duplicated); the explicit timestamps are
carried on the association. `owner_category` is the `InfraStore.OwnerCategory`
enum. Returns the byte size of the encoded array plus timestamps — the amount
the batch keeps buffered until it flushes.
"""
function serialize_non_sequential!(
    batch::InfraStore.AddBatch,
    owner_id::Integer,
    owner_type::AbstractString,
    owner_category::InfraStore.OwnerCategory,
    name::AbstractString,
    nts::NonSequentialTimeSeries;
    features = Dict{String, Any}(),
    units::Union{Nothing, AbstractString} = get_units(nts),
    quantity_kind::Union{Nothing, AbstractString} = get_quantity_kind(nts),
    unit_system::Union{Nothing, AbstractUnitSystem} = get_unit_system(nts),
)
    arr, element_type = _storage_array(get_array(nts))
    tss_ts = InfraStore.NonSequentialTimeSeries(
        get_timestamps(nts),
        arr,
        name;
        element_type = element_type,
    )
    InfraStore.add_time_series!(batch, owner_id, owner_type,
        owner_category, tss_ts; features = features, units = units,
        quantity_kind = quantity_kind,
        unit_system = _to_store_unit_system(unit_system))
    # The staged bytes are the encoded array plus the timestamps the association carries.
    return sizeof(arr) + sizeof(get_timestamps(nts))
end

"""
    get_non_sequential(store, owner_id, owner_category, name; features=Dict(), time_range=nothing) -> NonSequentialTimeSeries

Reconstruct a `NonSequentialTimeSeries` (timestamps + decoded array) from the InfraStore
store. A non-sequential series is addressed by name + features (it has no resolution).
`time_range`, if given, is a half-open `[start, stop)` window on the (irregular) timestamp
axis, sliced server-side — the same pushdown `_infrastore_read_single` uses for a
`SingleTimeSeries` grid window.
"""
function get_non_sequential(
    store::Store,
    owner_id::Integer,
    owner_category::InfraStore.OwnerCategory,
    name::AbstractString;
    features = Dict{String, Any}(),
    time_range::Union{Nothing, Tuple{Dates.DateTime, Dates.DateTime}} = nothing,
)
    nts = InfraStore.get_time_series(InfraStore.NonSequentialTimeSeries, store.inner,
        owner_id,
        owner_category, name; features = features, time_range = time_range)
    values = _decode_stored_values(nts.data, _element_encoding(nts.element_type))
    return NonSequentialTimeSeries(
        String(name), nts.timestamps, values; units = nts.units,
        quantity_kind = nts.quantity_kind,
        unit_system = _from_store_unit_system(nts.unit_system),
    )
end

function get_num_time_series(store::Store)
    c = InfraStore.get_counts(store.inner)
    return c.static_time_series + c.forecasts
end

flush!(store::Store) = InfraStore.flush!(store.inner)

"""
    catalog_mode(store::Store)

Where `store`'s SQLite catalog lives: `:attached` (the `.sqlite` file, durable on every
commit) or `:memory` (RAM, durable only at `serialize`). See [`Store`](@ref).
"""
catalog_mode(store::Store) = InfraStore.catalog_mode(store.inner)

# The store holds supplemental attribute associations as well as time series, and
# `serialize(::SystemData)` skips writing the artifact entirely for an empty store.
# Ignoring associations here would silently drop them for a system that has attributes
# but no time series.
#
# Existence probes, not counts: each is a `SELECT 1 ... LIMIT 1` against a covering index,
# where the counting form aggregates the whole table (`get_counts` alone is seven scans,
# one of them a COUNT(DISTINCT owner)). A boolean does not need a cardinality.
function Base.isempty(store::Store)
    return !InfraStore.has_any_time_series(store.inner) &&
           !InfraStore.has_supplemental_attribute_association(store.inner)
end

# Compression is fixed when the store is created/opened (threaded through the FFI
# via `_infrastore_compression_kwargs`); report the policy the store carries.
get_compression_settings(store::Store) =
    _compression_settings(InfraStore.get_compression(store.inner))

"""
    serialize(store::Store, file_path)

Persist the store's two artifacts to `file_path` (the HDF5 arrays) and
`file_path * ".sqlite"` (the metadata).
"""
function serialize(store::Store, file_path::AbstractString)
    # `persist!` copies the two artifacts for an on-disk store and materializes an
    # in-memory store to disk, so either kind of System can be serialized.
    InfraStore.persist!(store.inner, file_path)
    @info "Serialized InfraStore store to $file_path (+ .sqlite)"
    return
end

"""Remove all time series (data + metadata) from the store."""
clear_time_series!(store::Store) = InfraStore.clear!(store.inner)

"""
Reclaim the space that removed time series left behind, returning an
`InfraStore.CompactionReport`.

For an on-disk store this rewrites the `.h5` file: the arrays the catalog still
references are written to a sibling file which then replaces the original. The
store stays usable across the swap, and the report's `bytes_reclaimed` says how
much smaller the file got. An in-memory store has no file to rewrite.
"""
compact_time_series!(store::Store) = InfraStore.compact!(store.inner)

"""
Remove exactly the association that a fully-resolved `TimeSeriesKey` names.

The key carries the complete stored identity — type, name, resolution, interval,
and the *whole* feature set — so this routes to the store's exact-key removal
(the core matches the features by set hash) instead of the subset feature filter
that the by-name removals use. A sibling series whose feature set is a strict
superset of the key's therefore survives, which the subset filter would have
deleted along with the keyed series.
"""
function infrastore_remove_time_series!(
    store::Store,
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
)
    owner_id, _, category = _infrastore_owner_args(owner)
    name = get_name(key)
    try
        InfraStore.remove_time_series!(
            _infrastore_type(get_time_series_type(key)),
            store.inner,
            owner_id,
            category,
            name;
            resolution = get_resolution(key),
            interval = get_interval(key),
            features = get_features(key),
        )
    catch e
        # `catch`-block exception inspection: the core reports both conditions
        # through its own error types, which IS maps to the errors callers
        # dispatch on. The DST-orphan guard can only fire for a SingleTimeSeries
        # key; an InvalidParameterError for any other key type is something else
        # and propagates as itself.
        if e isa InfraStore.InvalidParameterError &&
           get_time_series_type(key) <: SingleTimeSeries
            throw(
                ArgumentError(
                    "Cannot remove SingleTimeSeries '$name' because it is attached to a " *
                    "DeterministicSingleTimeSeries."),
            )
        elseif e isa InfraStore.NotFoundError
            throw(
                ArgumentError(
                    "No time series matches the key $(summary(key)) with name='$name' " *
                    "on $(summary(owner)); it may already have been removed."),
            )
        end
        rethrow()
    end
    return
end

# The store handle / file path differ across a serialize→deserialize round-trip,
# so compare structurally by counts. Element-level equality is covered by the
# InfraStore integration tests.
function compare_values(
    match_fn::Union{Function, Nothing},
    x::Store,
    y::Store;
    kwargs...,
)
    return InfraStore.get_counts(x.inner) == InfraStore.get_counts(y.inner)
end

# ---- TimeSeriesManager routing ---------------------------------------------

"""
Route a manager-level `add_time_series!` to the InfraStore store. A direct add
is a one-item batch through the staging path (which applies the same
validation and key construction as bulk adds), committed immediately — exactly
what the store's own single-add entry point does. Data identity is the array
content hash.
"""
function infrastore_add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    batch = InfraStore.AddBatch()
    key, _ = _infrastore_stage!(
        batch,
        mgr,
        Dict{Tuple{Dates.Period, Dates.Period}, Any}(),
        owner,
        time_series;
        features...,
    )
    try
        InfraStore.add_time_series_bulk!(mgr.data_store.inner, batch)
    catch e
        _infrastore_rethrow_duplicate(
            e,
            _infrastore_owner_args(owner)[2],
            get_name(time_series),
        )
    end
    return key
end

# The store's duplicate-association rejection, which the add paths rely on
# instead of paying a pre-existence catalog query per add.
_infrastore_is_duplicate_error(e) =
    e isa InfraStore.DuplicateAssociationError ||
    e isa InfraStore.DuplicateTimeSeriesError

# Map the store's duplicate rejection to the IS-level ArgumentError; any other
# error propagates unchanged.
function _infrastore_rethrow_duplicate(e, owner_type, name)
    _infrastore_is_duplicate_error(e) && throw(
        ArgumentError(
            "Time series data with duplicate attributes are already stored: " *
            "$(owner_type)/$(name)"),
    )
    rethrow()
end

# Anything other than SingleTimeSeries / NonSequentialTimeSeries / Forecast is
# unsupported on the InfraStore backend.
infrastore_get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    kwargs...,
) where {T <: TimeSeriesData} =
    error(
        "InfraStore backend supports SingleTimeSeries, Deterministic, " *
        "DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
        "(requested $T)",
    )

# Forecasts reconstruct from the stored forecast type, honoring `start_time` /
# `count` slicing on the forecast window axis. `len`, when given, truncates each
# window to its first `len` horizon steps. A forecast stored as a
# DeterministicSingleTimeSeries is materialized into a regular `Deterministic`.
infrastore_get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: Forecast} = _infrastore_get_forecast(owner, name;
    time_series_type = T,
    start_time = start_time, len = len, count = count, resolution = resolution,
    interval = interval, features...)

"""
Route a public `get_time_series(SingleTimeSeries, owner, name; ...)` to the InfraStore
store, honoring `start_time` / `len` slicing on the time axis.
"""
function infrastore_get_time_series(
    ::Type{<:SingleTimeSeries},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,  # not applicable to a static series; ignored
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    # Resolve the unique series matching a possibly-partial (subset) feature /
    # resolution query, then read it by its exact stored attributes.
    key = infrastore_get_time_series_key(
        owner,
        SingleTimeSeries,
        name;
        resolution = resolution,
        features...,
    )
    return _infrastore_read_single(owner, key; start_time = start_time, len = len)
end

_window_length(::Nothing, index::Integer, total::Integer) = total - index + 1
_window_length(len::Integer, ::Integer, ::Integer) = len

# Step count of the requested `[index, index + n)` window on a series of `total` steps.
# Errors rather than clamping: the store clamps an out-of-grid range silently, so the
# window is validated here against the key before the sliced read is issued.
function _validate_window(index::Integer, len, total::Integer)
    n = _window_length(len, index, total)
    if index < 1 || n < 1 || index + n - 1 > total
        throw(ArgumentError("requested index=$index len=$n exceeds range $total"))
    end
    return n
end

# Key-addressed SingleTimeSeries read: the key carries the exact stored attributes
# plus the `(initial_timestamp, resolution, length)` needed to validate the
# requested window, so no catalog query is issued. The store slices the half-open
# `[start, start + n·resolution)` window server-side; only the requested steps are
# read and decoded.
function _infrastore_read_single(
    owner::TimeSeriesOwners,
    key::StaticTimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    name = get_name(key)
    initial_timestamp = get_initial_timestamp(key)
    resolution = get_resolution(key)
    total = get_length(key)
    feats = get_features(key)

    start = if isnothing(start_time)
        initial_timestamp
    else
        start_time
    end
    index = compute_time_array_index(initial_timestamp, start, resolution)
    n = _validate_window(index, len, total)
    time_range = if (isnothing(start_time) && isnothing(len))
        nothing
    else
        (start, start + resolution * n)
    end
    sts = InfraStore.get_time_series(InfraStore.SingleTimeSeries, store.inner, owner_id,
        category, name;
        resolution = resolution, features = feats, time_range = time_range)
    values = _decode_stored_values(sts.data, _element_encoding(sts.element_type))
    return SingleTimeSeries(
        String(name), sts.initial_timestamp, sts.resolution, values; units = sts.units,
        quantity_kind = sts.quantity_kind,
        unit_system = _from_store_unit_system(sts.unit_system),
    )
end

"""
Route a public `get_time_series(NonSequentialTimeSeries, owner, name; ...)` to the
InfraStore store, honoring `start_time` / `len` slicing on the (irregular) time axis.
"""
function infrastore_get_time_series(
    ::Type{<:NonSequentialTimeSeries},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,  # not applicable to a static series; ignored
    resolution::Union{Nothing, Dates.Period} = nothing,  # not applicable; ignored
    features...,
)
    # Resolve the unique series matching a possibly-partial (subset) feature query,
    # then read it by its exact stored attributes.
    key = infrastore_get_time_series_key(owner, NonSequentialTimeSeries, name; features...)
    return _infrastore_read_non_sequential(owner, key; start_time = start_time, len = len)
end

# Key-addressed NonSequentialTimeSeries read (no catalog re-resolution). Only `start_time`
# pushes down: `len` is a POINT COUNT, and turning it into an end timestamp needs to know
# which irregular timestamps exist — which is what the read is for. The store has no
# sentinel for "no upper bound" (`typemax(DateTime)` overflows the FFI's millisecond range
# check), so the suffix read stands one in and `len` slices the result client-side.
const _FAR_FUTURE_DATETIME = Dates.DateTime(9999, 12, 31, 23, 59, 59)
function _infrastore_read_non_sequential(
    owner::TimeSeriesOwners,
    key::NonSequentialTimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    feats = get_features(key)
    time_range = if isnothing(start_time)
        nothing
    else
        (start_time, _FAR_FUTURE_DATETIME)
    end
    nts = get_non_sequential(
        store, owner_id, category, get_name(key);
        features = feats, time_range = time_range,
    )
    (isnothing(start_time) && isnothing(len)) && return nts

    # Slice the values directly (not via a TimeArray) so FunctionData / N-D series slice
    # too. With `start_time` given, `nts` is already the store-side suffix, so this narrows
    # what the store returned; the exact-match check below still rejects a `start_time`
    # that is not one of the series' timestamps.
    timestamps = get_timestamps(nts)
    full = get_array(nts)
    total = size(full, 1)
    start = if isnothing(start_time)
        timestamps[1]
    else
        start_time
    end
    index = searchsortedfirst(timestamps, start)
    (index <= total && timestamps[index] == start) ||
        throw(ArgumentError("start_time=$start is not a timestamp in the series"))
    n = _validate_window(index, len, total)
    colons = ntuple(_ -> Colon(), ndims(full) - 1)
    vals = full[index:(index + n - 1), colons...]
    # A slice is the same values over a shorter window, so it keeps the label.
    return NonSequentialTimeSeries(
        String(get_name(key)), timestamps[index:(index + n - 1)], vals;
        units = get_units(nts), quantity_kind = get_quantity_kind(nts),
        unit_system = get_unit_system(nts))
end

# ---- Bulk staging ----------------------------------------------------------
# The bulk-add fast path stages every association onto a `InfraStore.AddBatch` and
# commits once: one metadata transaction, and the backend packs the arrays into
# batch-sized datasets with whole-chunk writes (no per-add read-modify-write).

"""
Commit a staged `AddBatch` to the store as one all-or-nothing bulk add.

The backend packs the arrays into batch-sized datasets written whole-chunk, so
this is materially cheaper than the same adds issued one at a time — which is why
the client-side buffer exists even though the store now has transactions.
"""
function _infrastore_commit_batch!(mgr::AbstractTimeSeriesManager, batch)
    try
        InfraStore.add_time_series_bulk!(mgr.data_store.inner, batch)
    catch e
        _infrastore_is_duplicate_error(e) && throw(
            ArgumentError("Time series data with duplicate attributes are already stored"),
        )
        rethrow()
    end
    flush!(mgr.data_store)
    return
end

"""
Stage one `(owner, time_series)` association onto `batch`, applying the same
validation as the per-add path, and return its `TimeSeriesKey`. The write
happens when the batch is committed. `params_cache` carries the forecast window
parameters per `(resolution, interval)` group so staged forecasts are checked
for compatibility against both the store and each other with one catalog query
per group.
"""
function _infrastore_stage!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    throw_if_does_not_support_time_series(owner)
    check_time_series_data(time_series)
    return _infrastore_stage_data!(
        batch,
        mgr,
        params_cache,
        owner,
        time_series;
        features...,
    )
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    ::TimeSeriesManager,
    ::AbstractDict,
    owner::TimeSeriesOwners,
    time_series::SingleTimeSeries;
    features...,
)
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(time_series)
    feats = _infrastore_features(features)
    nbytes = serialize_single!(batch, owner_id, owner_type, category, name,
        time_series; features = feats)
    key = StaticTimeSeriesKey(;
        time_series_type = SingleTimeSeries,
        name = name,
        initial_timestamp = get_initial_timestamp(time_series),
        resolution = get_resolution(time_series),
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
    return key, nbytes
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    ::TimeSeriesManager,
    ::AbstractDict,
    owner::TimeSeriesOwners,
    time_series::NonSequentialTimeSeries;
    features...,
)
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(time_series)
    feats = _infrastore_features(features)
    nbytes = serialize_non_sequential!(batch, owner_id, owner_type, category, name,
        time_series; features = feats)
    key = NonSequentialTimeSeriesKey(;
        time_series_type = NonSequentialTimeSeries,
        name = name,
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
    return key, nbytes
end

# Validate a staged forecast's window parameters against its `(resolution,
# interval)` group: the store's parameters are fetched once per group and the
# staged parameters become the group's baseline thereafter, so forecasts inside
# one batch are checked against each other as well as against the store.
function _infrastore_check_staged_forecast!(
    params_cache::AbstractDict,
    mgr::TimeSeriesManager,
    ts::Forecast,
)
    group = (get_resolution(ts), get_interval(ts))
    existing = get!(params_cache, group) do
        infrastore_forecast_parameters(
            mgr.data_store;
            resolution = group[1],
            interval = group[2],
        )
    end
    params = make_time_series_parameters(ts)
    check_params_compatibility(existing, params)
    isnothing(existing) && (params_cache[group] = params)
    return
end

# The three dense-forecast stagers differ only in how they build the InfraStore
# forecast object; the validation, owner marshalling, add, and returned
# `(ForecastKey, staged_nbytes)` pair around it are shared. `build(initial,
# resolution, horizon, interval, name)` returns that object together
# with its window count, which is the one field the callers disagree on.
function _infrastore_stage_forecast!(
    build,
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    ts::Forecast;
    features...,
)
    _infrastore_check_staged_forecast!(params_cache, mgr, ts)
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(ts)
    initial = get_initial_timestamp(ts)
    resolution = get_resolution(ts)
    interval = get_interval(ts)
    horizon = get_horizon(ts)
    feats = _infrastore_features(features)
    obj, count = build(initial, resolution, horizon, interval, name)
    InfraStore.add_time_series!(batch, owner_id, owner_type, category, obj;
        features = feats)
    # The key names the stored type as its UnionAll (`Probabilistic`, not
    # `Probabilistic{Float64, 2}`), exactly as a key listed back from the catalog does,
    # so the two compare and query alike.
    key = ForecastKey(;
        time_series_type = _unparameterized_type(typeof(ts)), name = name,
        initial_timestamp = initial, resolution = resolution,
        horizon = horizon, interval = interval, count = count,
        features = Dict{String, Any}(feats))
    # `obj.data` is the encoded dense array the batch buffers; its byte size drives
    # auto-flush.
    return key, sizeof(obj.data)
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    ts::Probabilistic;
    features...,
)
    return _infrastore_stage_forecast!(
        batch, mgr, params_cache, owner, ts; features...,
    ) do initial, resolution, horizon, interval, name
        arr = _dense_forecast_array(ts, length(get_percentiles(ts)))
        prob = InfraStore.Probabilistic(initial, resolution, horizon, interval,
            get_count(ts), Float64.(get_percentiles(ts)), arr, name;
            units = get_units(ts), quantity_kind = get_quantity_kind(ts),
            unit_system = _to_store_unit_system(get_unit_system(ts)))
        return (prob, get_count(ts))
    end
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    ts::Deterministic;
    features...,
)
    return _infrastore_stage_forecast!(
        batch, mgr, params_cache, owner, ts; features...,
    ) do initial, resolution, horizon, interval, name
        # (horizon_count, count) for scalars; (horizon_count, count, k) tagged
        # with the element type for FunctionData and NTuple windows.
        windows = collect(values(get_data(ts)))
        arr, element_type = _storage_forecast_array(windows)
        det = InfraStore.Deterministic(initial, resolution, horizon, interval,
            length(windows), arr, name;
            element_type = element_type, units = get_units(ts),
            quantity_kind = get_quantity_kind(ts),
            unit_system = _to_store_unit_system(get_unit_system(ts)))
        return (det, length(windows))
    end
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    ts::Scenarios;
    features...,
)
    return _infrastore_stage_forecast!(
        batch, mgr, params_cache, owner, ts; features...,
    ) do initial, resolution, horizon, interval, name
        arr = _dense_forecast_array(ts, get_scenario_count(ts))
        scen = InfraStore.Scenarios(initial, resolution, horizon, interval,
            get_count(ts), arr, name; units = get_units(ts),
            quantity_kind = get_quantity_kind(ts),
            unit_system = _to_store_unit_system(get_unit_system(ts)))
        return (scen, get_count(ts))
    end
end

_infrastore_stage_data!(
    ::InfraStore.AddBatch,
    ::TimeSeriesManager,
    ::AbstractDict,
    ::TimeSeriesOwners,
    ts::TimeSeriesData;
    features...,
) = error(
    "InfraStore backend supports SingleTimeSeries, NonSequentialTimeSeries, " *
    "Deterministic, Probabilistic, and Scenarios (got $(typeof(ts))). A " *
    "DeterministicSingleTimeSeries is derived in-store with " *
    "transform_single_time_series!.",
)

# 1-based index of the forecast window that starts at `start_time`, on the grid
# `initial_timestamp + k·interval`. `compute_time_array_index` does the period
# arithmetic, so calendar intervals (`Month`, `Year`) work like fixed ones. A
# single-window forecast carries a zero interval: its only window starts at
# `initial_timestamp`, which is then the only valid `start_time` — the zero-interval
# case must not skip the alignment check, or a misaligned request would silently
# read the window at `initial_timestamp`.
function _forecast_window_index(initial_timestamp, interval, start_time)
    start_time == initial_timestamp && return 1
    (start_time < initial_timestamp || iszero(Dates.value(interval))) &&
        _throw_misaligned(initial_timestamp, interval, start_time)
    return try
        compute_time_array_index(initial_timestamp, start_time, interval)
    catch e
        # `catch`-block exception inspection: the period arithmetic reports an
        # off-grid timestamp as an ArgumentError; name the window contract instead.
        if e isa ArgumentError
            _throw_misaligned(initial_timestamp, interval, start_time)
        else
            rethrow()
        end
    end
end

# Kept out of line so the aligned path — every forecast read after the first window —
# never pays for formatting the message.
@noinline function _throw_misaligned(initial_timestamp, interval, start_time)
    throw(
        ArgumentError(
            "start_time=$start_time is not a forecast window timestamp " *
            "(initial_timestamp=$initial_timestamp, interval=$(Dates.canonicalize(interval)))",
        ),
    )
end

# Translate IS's `start_time` / `count` window selection into the core's
# half-open `[start, end)` `time_range`, validated against the forecast's stored
# window grid (`initial_timestamp + k·interval`, `total_count` windows). Returns
# `nothing` when no slice is requested (read every window). Throws ArgumentError
# on a misaligned `start_time` or an out-of-range / oversized request — the store
# would otherwise silently truncate an over-request rather than error. The
# computed range is pushed into `get_time_series`, so the store slices the
# windows server-side instead of returning all of them for us to discard.
function _forecast_time_range(initial_timestamp, interval, total_count, start_time, count)
    isnothing(start_time) && isnothing(count) && return nothing

    start_idx = if isnothing(start_time)
        1
    else
        _forecast_window_index(initial_timestamp, interval, start_time)
    end
    if start_idx < 1 || start_idx > total_count
        throw(ArgumentError(
            "start_time=$start_time is out of range (count=$total_count)"))
    end
    n = _window_length(count, start_idx, total_count)
    if n < 1 || start_idx + n - 1 > total_count
        throw(
            ArgumentError(
                "requested count=$n from start_time=$start_time exceeds the " *
                "$total_count stored forecast windows"),
        )
    end

    # A single-window forecast carries a zero interval, so the arithmetic below would
    # collapse to a zero-width `[initial, initial)` range that selects nothing. The
    # request is already validated, so read the whole (single-window) series.
    iszero(Dates.value(interval)) && return nothing

    start_ts = initial_timestamp + interval * (start_idx - 1)
    end_ts = initial_timestamp + interval * (start_idx - 1 + n)  # exclusive
    return (start_ts, end_ts)
end

# Assemble forecast windows into a `SortedDict` with a concrete value type. Building it
# from a generator yields `SortedDict{Any, Any}`, which `Deterministic`'s `convert_data`
# then coerces to `Vector{Float64}` — corrupting FunctionData windows. Materializing
# first pins the value type to the window type `window(i)` actually returns.
function _assemble_forecast_windows(initial_timestamp, interval, count, window)
    windows = [window(i) for i in 1:count]
    V = if isempty(windows)
        Vector{Float64}
    else
        typeof(first(windows))
    end
    data = SortedDict{Dates.DateTime, V}()
    for i in 1:count
        data[initial_timestamp + interval * (i - 1)] = windows[i]
    end
    return data
end

"""Reconstruct a forecast from the InfraStore store (matches the STORED type),
honoring `start_time` / `count` slicing on the window axis. Pass `key` (a
previously resolved `ForecastKey`) to skip the catalog resolution query."""
function _infrastore_get_forecast(
    owner, name;
    time_series_type::Type{<:Forecast} = Forecast,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    key::Union{Nothing, ForecastKey} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    # Resolve the unique forecast of the requested type matching a possibly-partial
    # (subset) feature / resolution / interval query, then read it by its exact stored
    # attributes. `interval` matters when one series name carries several forecasts
    # that differ only by interval (`transform_single_time_series!` with
    # `delete_existing = false`); without it the lookup is ambiguous. The type is part
    # of the lookup too: one name can carry a Deterministic and a Probabilistic.
    matched = if isnothing(key)
        infrastore_get_time_series_key(
            owner, time_series_type, name;
            resolution = resolution, interval = interval, features...,
        )
    else
        key
    end
    feats = get_features(matched)
    resolution = get_resolution(matched)
    # `len` truncates each window to its first `len` steps; validate it against the
    # horizon here rather than letting the slice fail with a BoundsError (or silently
    # return empty windows for `len = 0`), matching the static read path.
    if !isnothing(len)
        horizon_count = get_horizon_count(matched)
        (len < 1 || len > horizon_count) && throw(
            ArgumentError(
                "requested len=$len is outside the forecast horizon of " *
                "$horizon_count steps",
            ),
        )
    end
    # Pin every store lookup below to the resolved forecast's exact interval.
    # One name can carry several forecasts differing only by interval, and the
    # typed lookups match on attributes, so without this they would match more
    # than one. (A single-window forecast carries a zero interval, stored as-is.)
    tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
        get_count(matched), start_time, count)
    # The resolved key names the stored concrete type; it selects the
    # reconstruction method (function barrier — the key's type is not known
    # statically).
    return _reconstruct_forecast(
        get_time_series_type(matched),
        store,
        owner_id,
        category,
        String(name),
        resolution,
        get_interval(matched),
        feats,
        tr,
        len,
    )
end

# `len`, when given, truncates a window to its first `len` horizon steps (the
# horizon is the leading axis of a window vector or matrix).
_truncate_window(w, ::Nothing) = w
_truncate_window(w::AbstractVector, len::Int) = w[1:len]
_truncate_window(w::AbstractMatrix, len::Int) = w[1:len, :]

# Extract window `i` from a stored deterministic-forecast array. Scalar windows
# are columns of a 2D `(horizon_count, count)` array; encoded FunctionData
# windows carry trailing coefficient dims (3D). The stored `element_type` names
# a scalar dtype in the 2-D case (and a DST inherits the metadata of the
# SingleTimeSeries it shares), so key the decode on the array rank instead.
_forecast_window(data::AbstractMatrix, ::ElementEncoding, _element_type, i) = data[:, i]

_forecast_window(
    data::AbstractArray{<:Any, 3}, encoding::ElementEncoding, element_type, i,
) = _decode_forecast_window(data, encoding, element_type, i)

# A Probabilistic/Scenarios window is stored `(member, horizon)` and transposed to the
# `(horizon, member)` matrix IS hands users.
_member_window(data::AbstractArray{<:Any, 3}, i) = permutedims(@view data[:, :, i])

# Reconstruct a forecast read from the store as its user-facing type. Every
# InfraStore read below is already sliced to the requested window range.
function _reconstruct_forecast(
    ::Type{<:Probabilistic},
    store::Store,
    owner_id,
    category,
    name::String,
    resolution,
    interval,
    feats,
    time_range,
    len,
)
    # `.data` is the canonical (percentile_count, horizon_count, count) array.
    p = InfraStore.get_time_series(InfraStore.Probabilistic, store.inner, owner_id,
        category, name;
        resolution = resolution, interval = interval, features = feats,
        time_range = time_range)
    window(i) = _truncate_window(_member_window(p.data, i), len)
    data = _assemble_forecast_windows(p.initial_timestamp, p.interval, p.count, window)
    return Probabilistic(; name = name, data = data,
        percentiles = p.percentiles, resolution = p.resolution,
        interval = p.interval, units = p.units, quantity_kind = p.quantity_kind,
        unit_system = _from_store_unit_system(p.unit_system))
end

_reconstruct_forecast(::Type{<:Deterministic}, args...) =
    _reconstruct_deterministic(InfraStore.Deterministic, args...)

# A DeterministicSingleTimeSeries is an internal storage optimization: it shares
# the underlying SingleTimeSeries array instead of materializing the overlapping
# windows. On read it is always returned as a regular `Deterministic` — the
# InfraStore store expands the shared array into the canonical
# (horizon_count, count) window matrix (honoring `time_range`), so the
# reconstruction is identical to the `Deterministic` method.
#
# This does NOT cost the storage optimization on a copy: `copy_time_series!`
# clones the association row inside the store, so the stored type survives
# without ever round-tripping through these Julia objects.
_reconstruct_forecast(::Type{<:DeterministicSingleTimeSeries}, args...) =
    _reconstruct_deterministic(InfraStore.DeterministicSingleTimeSeries, args...)

_reconstruct_forecast(::Type{T}, args...) where {T} =
    error("unreachable: unexpected stored forecast type $T")

function _reconstruct_deterministic(
    store_type,
    store::Store,
    owner_id,
    category,
    name::String,
    resolution,
    interval,
    feats,
    time_range,
    len,
)
    d = InfraStore.get_time_series(store_type, store.inner, owner_id, category, name;
        resolution = resolution, interval = interval, features = feats,
        time_range = time_range)
    # Resolved once per read: the tag is the same for every window.
    encoding = _element_encoding(d.element_type)
    window(i) =
        _truncate_window(_forecast_window(d.data, encoding, d.element_type, i), len)
    data = _assemble_forecast_windows(d.initial_timestamp, d.interval, d.count, window)
    return Deterministic(; name = name, data = data,
        resolution = d.resolution, interval = d.interval, units = d.units,
        quantity_kind = d.quantity_kind,
        unit_system = _from_store_unit_system(d.unit_system))
end

function _reconstruct_forecast(
    ::Type{<:Scenarios},
    store::Store,
    owner_id,
    category,
    name::String,
    resolution,
    interval,
    feats,
    time_range,
    len,
)
    # `.data` is the canonical (scenario_count, horizon_count, count) array.
    s_ts = InfraStore.get_time_series(InfraStore.Scenarios, store.inner, owner_id,
        category, name;
        resolution = resolution, interval = interval, features = feats,
        time_range = time_range)
    window(i) = _truncate_window(_member_window(s_ts.data, i), len)
    data = _assemble_forecast_windows(
        s_ts.initial_timestamp, s_ts.interval, s_ts.count, window,
    )
    return Scenarios(; name = name, data = data,
        scenario_count = s_ts.scenario_count, resolution = s_ts.resolution,
        interval = s_ts.interval, units = s_ts.units,
        quantity_kind = s_ts.quantity_kind,
        unit_system = _from_store_unit_system(s_ts.unit_system))
end

# ---- ForecastReader --------------------------------------------------------
# A timestamp-oriented reader over the forecasts matching a filter. It carries the
# InfraStore reader's `.h5` dedup up to Julia: forecasts sharing an array collapse to one
# slot, materialized (and decoded) at most once per read.

# Map an IS forecast type to the `InfraStore` reader type. An
# `InfraStore.Deterministic` reader spans both deterministic storage forms, so
# both IS `Deterministic` and `AbstractDeterministic` map to it; a DST query is
# exact.
_tss_forecast_type(::Type{<:DeterministicSingleTimeSeries}) =
    InfraStore.DeterministicSingleTimeSeries
_tss_forecast_type(::Type{<:AbstractDeterministic}) = InfraStore.Deterministic
_tss_forecast_type(::Type{<:Probabilistic}) = InfraStore.Probabilistic
_tss_forecast_type(::Type{<:Scenarios}) = InfraStore.Scenarios

# Orient + decode one raw window into IS's canonical per-window value, matching a single
# `get_time_series(...).data[timestamp]`. Dispatched on the forecast type, mirroring
# `_tss_forecast_type` above.
_decode_forecast_reader_window(::Type{<:Probabilistic}, raw, ::ElementEncoding) =
    permutedims(raw)

_decode_forecast_reader_window(::Type{<:Scenarios}, raw, ::ElementEncoding) =
    permutedims(raw)

_decode_forecast_reader_window(
    ::Type{<:AbstractDeterministic}, raw, encoding::ElementEncoding,
) = _decode_stored_values(raw, encoding)

_decode_forecast_reader_window(::Type{T}, raw, ::ElementEncoding) where {T <: Forecast} =
    throw(ArgumentError("InfraStore backend cannot decode a window of forecast type $T"))

"""
One forecast in a [`ForecastReader`], bound to its owner. `slot` is the 1-based
index of the deduplicated window read backing this entry; entries that share a
forecast array (and read plan) report the same `slot`.
"""
struct ForecastReaderEntry
    owner::TimeSeriesOwners
    key::ForecastKey
    slot::Int
end

"""
A timestamp-oriented reader over every forecast matching a build filter. Drive it
with [`read_forecast_window!`](@ref), then pull each entry's window with
[`get_forecast_window`](@ref). Build one with `build_forecast_reader(data, T; ...)`.

Forecasts that share an underlying array read the `.h5` file once per timestamp
(and materialize once in Julia); inspect the sharing via the entries' `slot`
field or [`get_num_forecast_slots`](@ref).
"""
mutable struct ForecastReader{T <: Forecast}
    inner::InfraStore.ForecastReader
    store::Store
    entries::Vector{ForecastReaderEntry}
    """
    Decode plan for each entry (parallel to `entries`). Resolved from the stored
    `element_type` once at build, so a per-timestamp read dispatches instead of
    re-interpreting the tag string.
    """
    element_encodings::Vector{ElementEncoding}
    "Per-slot materialized window cache; reset on each read."
    windows::Vector{Any}
    has_read::Bool
end

# The association identity a reader entry / metadata row is matched on:
# everything a build filter cannot disambiguate further (`key_info` carries no
# interval, but two same-identity forecasts differing only by interval cannot
# share one reader timeline, so the reader build has already rejected that
# case). Both arguments come off the same core catalog, so the periods and
# feature values compare exactly.
_infrastore_row_match_identity(x) = (
    Int(x.owner_id),
    x.owner_category,
    x.time_series_type,
    String(x.name),
    x.resolution,
    Tuple(sort!([string(k) => v for (k, v) in x.features])),
)

# Metadata rows for every association matching a reader build filter, indexed
# by association identity — ONE core catalog query for the whole reader,
# instead of a `get_metadata` round-trip per entry.
function _infrastore_metadata_by_identity(store::Store, resolution, name, features)
    metas = Dict{Any, InfraStore.TimeSeriesMetadata}()
    for m in InfraStore.list_time_series(store.inner;
        resolution = resolution, name = name, features = Dict{String, Any}(features))
        # Identities are unique per (resolution, interval, features); rows that
        # collide here differ only by interval and are unreachable behind a
        # reader build (they cannot share a window timeline).
        metas[_infrastore_row_match_identity(m)] = m
    end
    return metas
end

# The metadata row backing one reader entry (`info = key_info(entry.key)`).
function _infrastore_entry_metadata(metas::AbstractDict, info)
    meta = get(metas, _infrastore_row_match_identity(info), nothing)
    isnothing(meta) &&
        error("unreachable: reader entry $(info.name) has no matching metadata row")
    return meta
end

# Build a reader from the store. `id_to_owner(owner_id::Int, category::String)`
# resolves each entry's owner object (the system holds the owner maps). Per-entry
# metadata (owner, key, element_type) is resolved once here, off the read path.
function infrastore_build_forecast_reader(
    store::Store,
    id_to_owner,
    ::Type{T};
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features = Dict{String, Any}(),
) where {T <: Forecast}
    inner = InfraStore.build_forecast_reader(store.inner, _tss_forecast_type(T);
        resolution = resolution, name = name, features = features)
    tss_entries = InfraStore.forecast_entries(inner)
    metas = _infrastore_metadata_by_identity(store, resolution, name, features)
    n = length(tss_entries)
    entries = Vector{ForecastReaderEntry}(undef, n)
    element_encodings = Vector{ElementEncoding}(undef, n)
    for (i, e) in enumerate(tss_entries)
        info = InfraStore.key_info(e.key)
        owner = id_to_owner(Int(info.owner_id), info.owner_category)
        fmeta = _infrastore_entry_metadata(metas, info)
        element_encodings[i] = _element_encoding(fmeta.element_type)
        # `e.slot` is 0-based in the InfraStore store; carry it 1-based for Julia.
        entries[i] = ForecastReaderEntry(owner, _key_from_row(fmeta), e.slot + 1)
    end
    windows = Vector{Any}(nothing, InfraStore.forecast_num_slots(inner))
    return ForecastReader{T}(inner, store, entries, element_encodings, windows, false)
end

"""
$(TYPEDSIGNATURES)
The reader's window timeline as `(; initial_timestamp, resolution, interval,
count)`. Valid read timestamps are `initial_timestamp + k·interval` for
`k in 0:count-1`.
"""
get_forecast_reader_timeline(reader::ForecastReader) =
    InfraStore.forecast_timeline(reader.inner)

"""
$(TYPEDSIGNATURES)
The reader's entries, one per matching forecast, each bound to its owner.
"""
get_forecast_reader_entries(reader::ForecastReader) = reader.entries

"""
$(TYPEDSIGNATURES)
The number of deduplicated window slots — the count of physical `.h5` reads
[`read_forecast_window!`](@ref) performs per timestamp. Entries that share a
forecast array collapse to one slot, so this is `≤ length(get_forecast_reader_entries(reader))`.
"""
get_num_forecast_slots(reader::ForecastReader) = length(reader.windows)

Base.length(reader::ForecastReader) = length(reader.entries)

"""
$(TYPEDSIGNATURES)
Read the forecast window at `timestamp` for every entry, performing one `.h5`
read per unique slot. Follow with [`get_forecast_window`](@ref). Throws if
`timestamp` is off the window timeline.
"""
function read_forecast_window!(reader::ForecastReader, timestamp::Dates.DateTime)
    InfraStore.forecast_read!(reader.inner, timestamp)
    fill!(reader.windows, nothing)
    reader.has_read = true
    return reader
end

"""
$(TYPEDSIGNATURES)
The decoded window for entry `entry_index` (1-based) from the most recent
[`read_forecast_window!`](@ref). Entries that share a slot return the same
materialized array (read once per timestamp); treat it as read-only.
"""
function get_forecast_window(reader::ForecastReader{T}, entry_index::Integer) where {T}
    reader.has_read || throw(
        ArgumentError("call read_forecast_window! before reading window values"))
    entry = reader.entries[entry_index]
    cached = reader.windows[entry.slot]
    isnothing(cached) || return cached
    raw = InfraStore.forecast_values(reader.inner, entry_index)
    window =
        _decode_forecast_reader_window(T, raw, reader.element_encodings[entry_index])
    reader.windows[entry.slot] = window
    return window
end

# ---- StaticTimeSeriesReader ------------------------------------------------
# The static counterpart of the ForecastReader. The InfraStore reader packs matching
# series into columnar `(dtype, element_shape)` groups, one `.h5` read per group per
# timestamp; this wrapper materializes each group's values at most once per read.

"""
One series in a [`StaticTimeSeriesReader`], bound to its owner. `group` and
`column` locate the entry in the reader's columnar layout: every entry in one
`group` is served by a single physical read per timestamp.
"""
struct StaticTimeSeriesReaderEntry
    owner::TimeSeriesOwners
    key::StaticTimeSeriesKey
    group::Int
    column::Int
end

"""
A timestamp-oriented reader over every `SingleTimeSeries` matching a build
filter. Drive it with [`read_static_time_series_values!`](@ref), then pull each
entry's value with [`get_static_time_series_value`](@ref). Build one with
`build_static_time_series_reader(data; ...)`.

The matched series are packed into columnar groups; one physical `.h5` read per
group serves every entry in it at a timestamp — see
[`get_num_static_time_series_groups`](@ref).
"""
mutable struct StaticTimeSeriesReader
    inner::InfraStore.StaticReader
    store::Store
    entries::Vector{StaticTimeSeriesReaderEntry}
    """
    Decode plan for each entry (parallel to `entries`); drives the row decode.
    Resolved from the stored `element_type` once at build, so a per-timestamp
    read dispatches instead of re-interpreting the tag string.
    """
    element_encodings::Vector{ElementEncoding}
    "Per-group materialized values cache; reset on each read."
    values::Vector{Any}
    has_read::Bool
end

# Build a reader from the store. `id_to_owner(owner_id::Int, category)` resolves
# each entry's owner object (the system holds the owner maps). Per-entry metadata
# (owner, key, element encoding) is resolved once here, off the read path.
function infrastore_build_static_time_series_reader(
    store::Store,
    id_to_owner;
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features = Dict{String, Any}(),
)
    inner = InfraStore.build_static_reader(store.inner;
        resolution = resolution, name = name, features = features)
    metas = _infrastore_metadata_by_identity(store, resolution, name, features)
    entries = StaticTimeSeriesReaderEntry[]
    element_encodings = ElementEncoding[]
    groups = InfraStore.static_groups(inner)
    for (gi, group) in enumerate(groups)
        for (col, k) in enumerate(group.keys)
            info = InfraStore.key_info(k)
            owner = id_to_owner(Int(info.owner_id), info.owner_category)
            smeta = _infrastore_entry_metadata(metas, info)
            push!(
                entries,
                StaticTimeSeriesReaderEntry(owner, _key_from_row(smeta), gi, col),
            )
            push!(element_encodings, _element_encoding(smeta.element_type))
        end
    end
    values = Vector{Any}(nothing, length(groups))
    return StaticTimeSeriesReader(
        inner, store, entries, element_encodings, values, false,
    )
end

"""
$(TYPEDSIGNATURES)
The reader's time grid as `(; initial_timestamp, resolution, length)`. Valid
read timestamps are `initial_timestamp + k·resolution` for `k in 0:length-1`.
"""
get_static_time_series_reader_grid(reader::StaticTimeSeriesReader) =
    InfraStore.static_grid(reader.inner)

"""
$(TYPEDSIGNATURES)
The reader's entries, one per matching `SingleTimeSeries`, each bound to its
owner.
"""
get_static_time_series_reader_entries(reader::StaticTimeSeriesReader) = reader.entries

"""
$(TYPEDSIGNATURES)
The number of columnar groups — the count of physical `.h5` reads
[`read_static_time_series_values!`](@ref) performs per timestamp. Series with
the same element type collapse into one group, so this is
`≤ length(get_static_time_series_reader_entries(reader))` (typically 1).
"""
get_num_static_time_series_groups(reader::StaticTimeSeriesReader) =
    length(reader.values)

Base.length(reader::StaticTimeSeriesReader) = length(reader.entries)

"""
$(TYPEDSIGNATURES)
Read the value of every entry at `timestamp`, performing one `.h5` read per
columnar group. Follow with [`get_static_time_series_value`](@ref). Throws if
`timestamp` is off the reader's grid.
"""
function read_static_time_series_values!(
    reader::StaticTimeSeriesReader,
    timestamp::Dates.DateTime,
)
    InfraStore.static_read!(reader.inner, timestamp)
    fill!(reader.values, nothing)
    reader.has_read = true
    return reader
end

"""
$(TYPEDSIGNATURES)
The decoded value for entry `entry_index` (1-based) from the most recent
[`read_static_time_series_values!`](@ref): a scalar for scalar series, or the
reconstructed element (e.g. a `FunctionData`) for structured series.
"""
function get_static_time_series_value(
    reader::StaticTimeSeriesReader,
    entry_index::Integer,
)
    reader.has_read || throw(
        ArgumentError(
            "call read_static_time_series_values! before reading values"))
    entry = reader.entries[entry_index]
    vals = reader.values[entry.group]
    if isnothing(vals)
        vals = InfraStore.static_values(reader.inner, entry.group)
        reader.values[entry.group] = vals
    end
    return _static_group_element(
        vals, entry.column, reader.element_encodings[entry_index],
    )
end

# One entry's value out of its group's materialized array. A vector group is
# scalar data (one value per column); a higher-rank group carries one element row
# per column, decoded through the entry's encoding (same scheme as
# `_decode_static_values`, at `len == 1`).
_static_group_element(vals::AbstractVector, column::Integer, ::ElementEncoding) =
    vals[column]

function _static_group_element(
    vals::AbstractArray, column::Integer, encoding::ElementEncoding,
)
    colons = ntuple(_ -> Colon(), ndims(vals) - 1)
    return _decode_element(vals[column, colons...], encoding)
end

_decode_element(element, ::ScalarEncoding) = element

_decode_element(element, encoding::RowEncoding) =
    _decode_static_values(reshape(element, 1, :), encoding, 1)[1]

"""Route `has_time_series(owner, T, name; ...)` to the InfraStore store. Honors partial
(subset) feature / resolution queries: matches if any stored series of type `T`
contains at least the requested features. `name = nothing` probes across all
names (the name-less kwargs form with resolution/interval/feature filters)."""
function infrastore_has_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::Union{Nothing, AbstractString};
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    feats = _infrastore_features(features)
    # Pure existence probe — a covering-index `SELECT 1 ... LIMIT 1` in the store; nothing
    # is listed, hydrated, or marshaled, so this is safe in hot per-component loops. A
    # broad abstract query type expands to one probe per candidate stored type.
    probe =
        t -> InfraStore.has_any_time_series(store.inner;
            owner_id = owner_id, owner_category = category,
            time_series_type = t, name = name, resolution = resolution,
            interval = interval, features = feats)
    return _infrastore_probe_types(probe, _infrastore_query_types(T))
end

# ---- Type translation ------------------------------------------------------
# The InfraStore and IS time series types mirror each other one-to-one, so this
# table is the whole translation layer; everything below is derived from it.
const _INFRASTORE_TYPE_PAIRS = (
    (InfraStore.SingleTimeSeries, SingleTimeSeries),
    (InfraStore.NonSequentialTimeSeries, NonSequentialTimeSeries),
    (InfraStore.Deterministic, Deterministic),
    (InfraStore.DeterministicSingleTimeSeries, DeterministicSingleTimeSeries),
    (InfraStore.Probabilistic, Probabilistic),
    (InfraStore.Scenarios, Scenarios),
)

# The InfraStore type for a concrete IS time series type.
for (store_type, is_type) in _INFRASTORE_TYPE_PAIRS
    @eval _infrastore_type(::Type{<:$is_type}) = $store_type
end

# `InfraStore.Deterministic` already expands to both deterministic storage forms in the
# core, so a DST alongside it is a redundant query/probe.
function _infrastore_collapse_family(types::Tuple)
    (InfraStore.Deterministic in types) || return types
    return Tuple(t for t in types if t !== InfraStore.DeterministicSingleTimeSeries)
end

# The three answers `_infrastore_query_types` can give. `AllStoredTypes` means one
# unfiltered query serves the request; `NoStoredTypes` means no stored type can match (a
# `TimeSeriesData` subtype with no stored counterpart; a parameterized concrete such as
# `SingleTimeSeries{Float64, 1}` is normalized to its UnionAll first) and the caller must
# answer empty WITHOUT querying.
struct AllStoredTypes end
struct NoStoredTypes end

# All InfraStore types whose IS type is a subtype of `T` (strict `<:` semantics —
# distinct from `_infrastore_type_matches`, which treats a `Deterministic` query
# as also matching a `DeterministicSingleTimeSeries`). Used by the store-wide
# filters (`resolutions`, `list_owner_ids`) that key on subtyping. A parameterized
# concrete query is normalized the same way `_infrastore_type_matches` does, so a
# `typeof(ts)` query answers the same on every path.
_infrastore_subtype_types(::Type{T}) where {T <: TimeSeriesData} =
    _infrastore_collapse_family(
        Tuple(c for (c, k) in _INFRASTORE_TYPE_PAIRS if k <: _unparameterized_type(T)),
    )

# The stored InfraStore types a query for `T` should match, under the same
# `Deterministic`-matches-DST semantics as `_infrastore_type_matches`. `AllStoredTypes()`
# / `NoStoredTypes()` for the two degenerate answers; otherwise a non-empty tuple.
_infrastore_query_types(::Nothing) = AllStoredTypes()

function _infrastore_query_types(::Type{T}) where {T <: TimeSeriesData}
    types = Tuple(c for (c, k) in _INFRASTORE_TYPE_PAIRS if _infrastore_type_matches(k, T))
    length(types) == length(_INFRASTORE_TYPE_PAIRS) && return AllStoredTypes()
    isempty(types) && return NoStoredTypes()
    return _infrastore_collapse_family(types)
end

# The single InfraStore type to push into the core `list_keys` filter for a query
# type — a stored type, where `InfraStore.Deterministic` covers a
# `Deterministic`-family query because the core matches both storage forms under
# it. `nothing` when the type spans more than that (a broader abstract family
# like `Forecast`); the caller then applies the residual
# `_infrastore_type_matches` filter on the (already narrowed) rows.
_infrastore_pushable_type(::Type{T}) where {T <: TimeSeriesData} =
    _infrastore_pushable_type(_infrastore_query_types(T))

_infrastore_pushable_type(::Nothing) = nothing
_infrastore_pushable_type(::AllStoredTypes) = nothing
_infrastore_pushable_type(::NoStoredTypes) = nothing

function _infrastore_pushable_type(types::Tuple)
    length(types) == 1 && return only(types)
    return nothing
end

# `probe(time_series_type)` over the stored types a query matches: one unfiltered probe
# for `AllStoredTypes`, no probe at all when nothing can match.
_infrastore_probe_types(probe, ::AllStoredTypes) = probe(nothing)
_infrastore_probe_types(_probe, ::NoStoredTypes) = false
_infrastore_probe_types(probe, types::Tuple) = any(probe, types)

# True iff `owner` has any time series, optionally restricted to type `T`.
# `time_series_type` is deliberately untyped: annotating it `Union{Nothing, Type}`
# widens the passed `Type{T}` constant to abstract `Type`, which defeats constant
# propagation through `_infrastore_query_types` and boxes this function's return as
# `Any` instead of `Bool` — real cost on the `has_time_series` hot path.
function infrastore_has_any(owner; time_series_type = nothing)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    probe =
        t -> InfraStore.has_for_owner(
            store.inner, owner_id, category; time_series_type = t,
        )
    return _infrastore_probe_types(probe, _infrastore_query_types(time_series_type))
end

# ---- Metadata reconstruction -----------------------------------------------
# IS time series type for a `InfraStore` metadata-row type (matched by name) —
# the inverse of `_infrastore_type`, over the same table.
const _INFRASTORE_IS_TYPES =
    Dict(nameof(c) => k for (c, k) in _INFRASTORE_TYPE_PAIRS)
_infrastore_is_type(t::Type) = _infrastore_is_type(nameof(t))
_infrastore_is_type(s::Symbol) =
    get(_INFRASTORE_IS_TYPES, s) do
        error("InfraStore backend does not support time series type $s")
    end

# Whether a stored row of concrete type `row_type` satisfies a query for the query type.
# Mirrors InfraStore's semantics: a `Deterministic` (or `AbstractDeterministic`) query
# also matches a `DeterministicSingleTimeSeries` (which reads as a `Deterministic`),
# while a `DeterministicSingleTimeSeries` query matches DST only.
_infrastore_type_matches(
    row_type::Type, ::Type{<:DeterministicSingleTimeSeries},
) = row_type <: DeterministicSingleTimeSeries

_infrastore_type_matches(row_type::Type, ::Type{<:AbstractDeterministic}) =
    row_type <: AbstractDeterministic

# A parameterized concrete query (`SingleTimeSeries{Float64, 1}`, i.e. `typeof(ts)`)
# matches the same rows as its UnionAll: the catalog does not key on the element
# type, so the parameters can only restate what the stored array is, never select
# between arrays.
_infrastore_type_matches(row_type::Type, ::Type{T}) where {T <: TimeSeriesData} =
    row_type <: _unparameterized_type(T)

# `SingleTimeSeries{Float64, 1}` -> `SingleTimeSeries`; a UnionAll or a `Union` of
# time series types is returned as is.
_unparameterized_type(::Type{T}) where {T} =
    T isa Union ? T : Base.typename(T).wrapper

# `_infrastore_query_types`' answer is static per query type, and its generic
# method's runtime match loop costs ~2 µs — real money on the
# `has_time_series` per-component hot path. Bake a constant-returning method
# for each type callers actually pass (the UnionAlls; parameterized concretes
# still take the generic method).
for T in (
    (k for (_, k) in _INFRASTORE_TYPE_PAIRS)...,
    AbstractDeterministic,
    Forecast,
    StaticTimeSeries,
    TimeSeriesData,
)
    let types = _infrastore_query_types(T)
        @eval _infrastore_query_types(::Type{$T}) = $types
    end
end

# Build the matching IS `TimeSeriesKey` from a catalog row — a
# `InfraStore.list_keys` / `list_array_groups` row or a `list_time_series`
# metadata row (they share the key-describing fields). The key is the single
# descriptor for a stored association; forecast-only fields (percentiles,
# scenario_count) are not carried — they come from the data on read.
_key_from_row(row) = _key_from_row(_infrastore_is_type(row.time_series_type), row)

_row_features(row) = Dict{String, Any}(string(k) => v for (k, v) in row.features)

_key_from_row(::Type{T}, row) where {T <: NonSequentialTimeSeries} =
    NonSequentialTimeSeriesKey(;
        time_series_type = T,
        name = row.name,
        length = row.length,
        features = _row_features(row),
    )

_key_from_row(::Type{T}, row) where {T <: StaticTimeSeries} =
    StaticTimeSeriesKey(;
        time_series_type = T,
        name = row.name,
        initial_timestamp = row.initial_timestamp,
        resolution = row.resolution,
        length = row.length,
        features = _row_features(row),
    )

_key_from_row(::Type{T}, row) where {T <: Forecast} =
    ForecastKey(;
        time_series_type = T,
        name = row.name,
        initial_timestamp = row.initial_timestamp,
        resolution = row.resolution,
        horizon = row.horizon,
        interval = row.interval,
        count = row.count,
        features = _row_features(row),
    )

# All matching associations for one owner, as `TimeSeriesKey` objects. The core
# `list_keys` query filters owner / name / resolution / interval / features
# (periods are canonicalized to ISO-8601 on both write and query, so a regular
# `Hour(1)` matches a stored `Minute(60)`); an abstract `time_series_type` (or
# `Deterministic`, which also matches a DST) is not a catalog filter column, so
# it is applied as a residual on the already-narrowed rows.
function _infrastore_list_keys(
    store::Store,
    owner_id::Integer,
    owner_category::InfraStore.OwnerCategory;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features = (),
)
    type_filter = _infrastore_pushable_type(time_series_type)
    feats = Dict{String, Any}(string(k) => v for (k, v) in features)
    rows =
        InfraStore.list_keys(store.inner; owner_id = owner_id,
            owner_category = owner_category, time_series_type = type_filter,
            name = name, resolution = resolution, interval = interval,
            features = feats)
    out = ConcreteTimeSeriesKey[]
    for row in rows
        if !isnothing(time_series_type)
            _infrastore_type_matches(
                _infrastore_is_type(row.time_series_type),
                time_series_type,
            ) ||
                continue
        end
        push!(out, _key_from_row(row))
    end
    return out
end

# Owner-level `list_metadata` entry point.
function infrastore_owner_list_keys(
    owner::TimeSeriesOwners;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    return _infrastore_list_keys(store, owner_id, category;
        time_series_type = time_series_type, name = name, resolution = resolution,
        interval = interval, features = _infrastore_features(features))
end

# Single matching time series key; throws when zero or more than one match.
function infrastore_get_time_series_key(
    owner::TimeSeriesOwners,
    ::Type{T},
    name::AbstractString;
    resolution = nothing,
    interval = nothing,
    features...,
) where {T <: TimeSeriesData}
    items = infrastore_owner_list_keys(owner; time_series_type = T, name = name,
        resolution = resolution, interval = interval, features...)
    if isempty(items)
        throw(ArgumentError("No matching metadata is stored."))
    elseif length(items) > 1
        throw(
            ArgumentError(
                "Found more than one matching metadata: $(length(items)). " *
                "Specify additional keyword arguments (resolution, interval, or features) " *
                "to disambiguate.",
            ),
        )
    end
    return items[1]
end

# Content hash (64-char lowercase hex, the documented public form of the
# wrapper's 32-byte hash) of the array `key` resolves to under `owner`. Pushes
# the key's type/name/resolution/interval into one catalog query (a `nothing`
# resolution or interval — a key type that has none — constrains nothing), so
# the store applies its canonical comparisons; only the type residual and the
# whole-feature-set match stay in-memory.
function infrastore_get_time_series_hash(owner::TimeSeriesOwners, key::TimeSeriesKey)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) &&
        throw(InfraStore.NotFoundError("owner has no time series to hash"))
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    T = get_time_series_type(key)
    rows = InfraStore.list_array_groups(store.inner; owner_id = owner_id,
        owner_category = category,
        time_series_type = _infrastore_pushable_type(T), name = get_name(key),
        resolution = get_resolution(key), interval = get_interval(key))
    target_feats = get_features(key)
    for row in rows
        _infrastore_type_matches(_infrastore_is_type(row.time_series_type), T) || continue
        row.features == target_feats || continue
        return bytes2hex(row.data_hash)
    end
    throw(InfraStore.NotFoundError("no stored array matches key name=$(get_name(key))"))
end

# Content hashes for a homogeneous collection of owners, resolved by ONE catalog
# query (`list_array_groups` filtered on category/type/name/resolution/interval)
# instead of one per owner. Returns `get_id(owner) => 64-char hex hash` for every
# owner in `owners` with a stored series matching the filters; owners with no
# match are simply absent. Two matches with the same hash are fine (they resolve
# to the same array); two matches with different hashes mean the filters
# underdetermine the series for that owner, so that is an error.
function infrastore_get_time_series_hashes(
    owners,
    ::Type{T},
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    hashes = Dict{Int, String}()
    isempty(owners) && return hashes
    owner = first(owners)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) && return hashes
    store = mgr.data_store
    ids = Set{Int}(get_id(o) for o in owners)
    rows = InfraStore.list_array_groups(store.inner;
        owner_category = get_owner_category(owner),
        time_series_type = _infrastore_pushable_type(T),
        name = name,
        resolution = resolution,
        interval = interval,
        features = _infrastore_features(features))
    for row in rows
        id = Int(row.owner_id)
        id in ids || continue
        _infrastore_type_matches(_infrastore_is_type(row.time_series_type), T) || continue
        hex = bytes2hex(row.data_hash)
        existing = get(hashes, id, nothing)
        if !isnothing(existing) && existing != hex
            throw(
                ArgumentError(
                    "More than one time series of type $T with name=$name matches " *
                    "owner id $id. Specify additional keyword arguments (resolution, " *
                    "interval, or features) to disambiguate.",
                ),
            )
        end
        hashes[id] = hex
    end
    return hashes
end

# Group every stored association by content hash, as `(owner, key)` pairs. The
# `id_to_owner` callback resolves an `(owner_id, owner_category)` row back to the
# owner object (the system holds the component / supplemental-attribute maps).
# One catalog query returns the hash on every row, so no per-row metadata fetch.
#
# `DeterministicSingleTimeSeries` rows are excluded: such a forecast is a view of
# its own `SingleTimeSeries` and so always reports that array's hash, which is an
# artifact of the transformation rather than data shared between time series.
function infrastore_group_by_hash(
    store::Store,
    id_to_owner;
    only_shared = true,
)
    # Keyed by the 64-char hex form of the content hash (the public contract).
    groups = Dict{String, Vector{Tuple{TimeSeriesOwners, TimeSeriesKey}}}()
    for row in InfraStore.list_array_groups(store.inner)
        _infrastore_is_type(row.time_series_type) <: DeterministicSingleTimeSeries &&
            continue
        owner = id_to_owner(Int(row.owner_id), row.owner_category)
        pairs = get!(
            () -> Tuple{TimeSeriesOwners, TimeSeriesKey}[], groups,
            bytes2hex(row.data_hash))
        push!(pairs, (owner, _key_from_row(row)))
    end
    only_shared && filter!(x -> length(x.second) > 1, groups)
    return groups
end

# Reconstruct each matching time series for an owner; applies `filter_func`.
function infrastore_get_time_series_multiple(
    owner::TimeSeriesOwners,
    filter_func;
    type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
)
    metas = infrastore_owner_list_keys(owner; time_series_type = type, name = name,
        resolution = resolution, interval = interval)
    Channel() do channel
        for m in metas
            ts = _infrastore_read_key(owner, m)
            (isnothing(filter_func) || filter_func(ts)) && put!(channel, ts)
        end
    end
end

# Read one series by its already-resolved key — no catalog re-resolution.
_infrastore_read_key(owner::TimeSeriesOwners, key::ForecastKey) =
    _infrastore_get_forecast(owner, get_name(key); key = key)

_infrastore_read_key(owner::TimeSeriesOwners, key::NonSequentialTimeSeriesKey) =
    _infrastore_read_non_sequential(owner, key)

_infrastore_read_key(owner::TimeSeriesOwners, key::StaticTimeSeriesKey) =
    _infrastore_read_single(owner, key)

# ---- Store-wide aggregates -------------------------------------------------

# Distinct, sorted resolutions across the store, optionally restricted to a type
# (strict subtype). One DISTINCT query per concrete subtype code, in the core.
function infrastore_get_time_series_resolutions(
    store::Store;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
)
    # Calendar resolutions come back as `Month`/`Year`, which neither convert to nor
    # order against fixed periods, so the set is over `Period` and the sort goes
    # through `Dates.toms`, which is exact for fixed periods and uses the mean
    # Gregorian length for calendar ones.
    isnothing(time_series_type) && return sort!(
        Vector{Dates.Period}(InfraStore.get_resolutions(store.inner));
        by = Dates.toms,
    )
    res = Set{Dates.Period}()
    for t in _infrastore_subtype_types(time_series_type)
        union!(res, InfraStore.get_resolutions(store.inner; time_series_type = t))
    end
    return sort!(collect(res); by = Dates.toms)
end

# Counts of time series grouped by type name.
function infrastore_get_time_series_counts_by_type(store::Store)
    counts = OrderedDict{String, Int}()
    for r in InfraStore.counts_by_type(store.inner)
        counts[string(nameof(r.time_series_type))] = r.count
    end
    return [OrderedDict("type" => k, "count" => v) for (k, v) in sort!(OrderedDict(counts))]
end

# Static-time-series summary DataFrame. The core groups the rows; we shape them here.
function infrastore_static_summary_table(store::Store)
    rows = InfraStore.static_summary(store.inner)
    return DataFrames.DataFrame(;
        owner_type = [r.owner_type for r in rows],
        owner_category = [r.owner_category for r in rows],
        name = [r.name for r in rows],
        time_series_type = [string(nameof(r.time_series_type)) for r in rows],
        initial_timestamp = [r.initial_timestamp for r in rows],
        resolution = [Dates.canonicalize(r.resolution) for r in rows],
        count = [r.count for r in rows],
        time_step_count = [r.time_step_count for r in rows],
    )
end

# Forecast summary DataFrame.
function infrastore_forecast_summary_table(store::Store)
    rows = InfraStore.forecast_summary(store.inner)
    return DataFrames.DataFrame(;
        owner_type = [r.owner_type for r in rows],
        owner_category = [r.owner_category for r in rows],
        name = [r.name for r in rows],
        time_series_type = [string(nameof(r.time_series_type)) for r in rows],
        initial_timestamp = [r.initial_timestamp for r in rows],
        resolution = [Dates.canonicalize(r.resolution) for r in rows],
        count = [r.count for r in rows],
        horizon = [Dates.canonicalize(r.horizon) for r in rows],
        interval = [Dates.canonicalize(r.interval) for r in rows],
        window_count = [r.window_count for r in rows],
    )
end

# First matching forecast's parameters, optionally filtered by
# resolution/interval — one filtered catalog query in the core (every forecast
# in a `(resolution, interval)` group shares its window parameters). Returns
# `nothing` when no forecast matches.
function infrastore_forecast_parameters(
    store::Store;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    p = InfraStore.get_forecast_parameters(
        store.inner;
        resolution = resolution,
        interval = interval,
    )
    isnothing(p.count) && return nothing
    return ForecastParameters(;
        horizon = p.horizon,
        initial_timestamp = p.initial_timestamp,
        interval = p.interval,
        count = p.count,
        resolution = p.resolution,
    )
end

# Distinct owner ids of the given category that have time series, optionally
# restricted by time series type (strict subtype) and resolution.
function infrastore_list_owner_ids(
    store::Store,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = get_owner_category(owner_type)
    # Without a resolution filter, enumerate owner ids in the core (optionally
    # per concrete subtype). With one, the resolution is pushed into the core
    # key listing and the strict subtype match applied on the rows.
    if isnothing(resolution)
        isnothing(time_series_type) &&
            return InfraStore.list_owner_ids(store.inner, category)
        ids = Set{Int}()
        for t in _infrastore_subtype_types(time_series_type)
            union!(
                ids,
                InfraStore.list_owner_ids(store.inner, category; time_series_type = t),
            )
        end
        return collect(ids)
    end
    # Same `Deterministic`-family semantics as the branch above (the core widens a
    # pushed `Deterministic` filter to DST rows), so the answer does not change with
    # the presence of a `resolution` filter.
    ids = Set{Int}()
    for row in
        InfraStore.list_keys(store.inner; owner_category = category,
        time_series_type = _infrastore_pushable_type(time_series_type),
        resolution = resolution)
        if !isnothing(time_series_type)
            _infrastore_type_matches(
                _infrastore_is_type(row.time_series_type),
                time_series_type,
            ) || continue
        end
        push!(ids, Int(row.owner_id))
    end
    return collect(ids)
end

# (owner_id, key) for every time series of the given owner category, optionally
# restricted by time series type (strict subtype) and resolution. Owner category,
# resolution, and — when the type maps to a single core filter — the time series
# type are pushed into the core query; the pushed set is a superset of the strict
# match (`Deterministic`-family semantics), so the strict type filter is still
# applied on the returned keys.
function infrastore_list_keys_with_owner(
    store::Store,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = get_owner_category(owner_type)
    rows = InfraStore.list_keys(store.inner; owner_category = category,
        time_series_type = _infrastore_pushable_type(time_series_type),
        resolution = resolution)
    out = NamedTuple[]
    query_type =
        isnothing(time_series_type) ? nothing : _unparameterized_type(time_series_type)
    for row in rows
        if !isnothing(query_type)
            _infrastore_is_type(row.time_series_type) <: query_type || continue
        end
        push!(out, (owner_id = Int(row.owner_id), metadata = _key_from_row(row)))
    end
    return out
end

# Bulk catalog removal for a query type: one core `remove_by_filter` call per
# stored InfraStore type the query matches (`Deterministic`-family semantics,
# like the listing paths), or a single unfiltered call when the query spans
# every stored type. Each call removes all matching associations and frees the
# newly unreferenced arrays in one store transaction — this is the fast path
# for removals; per-key `remove_time_series!` pays a full transaction (WAL
# commit and array free) per series. Returns the number of associations
# removed.
function _infrastore_remove_by_filter!(
    store::Store,
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}};
    owner_id::Union{Nothing, Integer} = nothing,
    owner_category::Union{Nothing, InfraStore.OwnerCategory} = nothing,
    name::Union{Nothing, String} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features::AbstractDict = Dict{String, Any}(),
)
    remove =
        t -> InfraStore.remove_by_filter!(
            store.inner;
            owner_id = owner_id,
            owner_category = owner_category,
            time_series_type = t,
            name = name,
            resolution = resolution,
            interval = interval,
            features = features,
        )
    return _infrastore_remove_types!(remove, _infrastore_query_types(time_series_type))
end

_infrastore_remove_types!(remove, ::AllStoredTypes) = remove(nothing)

# A query no stored type can match must remove nothing, not remove unfiltered.
_infrastore_remove_types!(_remove, ::NoStoredTypes) = 0

function _infrastore_remove_types!(remove, types::Tuple)
    count = 0
    for t in types
        count += remove(t)
    end
    return count
end

# Derive DeterministicSingleTimeSeries views over the stored component
# SingleTimeSeries, or (with `dry_run`) report whether that would succeed
# without writing anything.
#
# The store owns the whole of the validation — horizon fit and divisibility,
# interval divisibility and length, per-resolution grid uniformity, and
# conflicts with forecasts already stored. The two policy flags are IS's
# contract on top of that: a single-window interval is stored as zero (the form
# IS looks views up by), and one system holds one forecast grid.
#
# The store's parameter and integrity failures become IS's ConflictingInputsError,
# which is the type callers dispatch on.
function infrastore_transform_single_time_series!(
    store::Store,
    horizon::Dates.Period,
    interval::Dates.Period;
    resolution::Union{Nothing, Dates.Period} = nothing,
    dry_run::Bool = false,
)
    return try
        InfraStore.transform_single_time_series!(
            store.inner,
            horizon,
            interval;
            owner_category = InfraStore.Component,
            resolution = resolution,
            normalize_single_window = true,
            require_uniform_forecast_grid = true,
            dry_run = dry_run,
        )
    catch e
        (e isa InfraStore.InvalidParameterError || e isa InfraStore.IntegrityError) ||
            rethrow()
        throw(ConflictingInputsError(e.msg))
    end
end

# Verify that, per resolution, all SingleTimeSeries share an initial timestamp and
# length; return `(initial_timestamp, length)`. Series at different resolutions have
# legitimately different grids, so with more than one resolution present the caller must
# pass `resolution` to name the grid it wants. One DISTINCT query in the core.
function infrastore_check_consistency(
    store::Store,
    ::Type{<:SingleTimeSeries};
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    grids = try
        InfraStore.check_static_consistency(store.inner; resolution = resolution)
    catch e
        e isa InfraStore.IntegrityError || rethrow()
        throw(InvalidValue(e.msg))
    end
    isempty(grids) && return (Dates.DateTime(Dates.Minute(0)), 0)
    if length(grids) > 1
        resolutions =
            join([string(Dates.canonicalize(g.resolution)) for g in grids], ", ")
        throw(
            InvalidValue(
                "SingleTimeSeries exist at multiple resolutions ($resolutions); " *
                "pass `resolution` to check one grid",
            ),
        )
    end
    return (grids[1].initial_timestamp, grids[1].length)
end

function infrastore_check_consistency(
    ::Store,
    ::Type{<:Forecast};
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    return nothing
end
