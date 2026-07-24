# Castore-backed time series storage.
#
# Castore manages both the time series data and the associations between components /
# supplemental attributes and that data. The `Store` type (declared in `store.jl`)
# delegates BOTH array data and metadata to it, via the `Castore.jl` binding package.
# Castore owns both: arrays land in a NetCDF4 `.nc` file (content-addressed by SHA-256
# hash) and metadata in a sibling `.sqlite` file. Time series *data* identity is the
# array content hash, not a UUID. Persisting a system writes the `.nc` + `.sqlite` pair
# directly.
#
# This file holds the IS-specific glue (owner/feature conversion, window
# flatten/reshape, manager routing). All low-level FFI lives in `Castore`.

# ---- Store construction ----------------------------------------------------

"""
    open_castore_store(path; read_only=false)

Open an existing on-disk Castore store from its `.nc` base path.
"""
function open_castore_store(path::AbstractString; read_only::Bool = false)
    # Open with an absolute path so BOTH the Castore handle's own backing path and the
    # wrapper's `path` field survive later `cd`s (e.g. a deserialize that opens a
    # relative basename, then a re-serialize elsewhere). Absolutizing only the
    # wrapper field leaves the handle resolving its source relative to the cwd at
    # open time, so a later `persist!` fails once the cwd changes.
    abs_path = abspath(String(path))
    inner = Castore.open_store(abs_path; read_only = read_only)
    return Store(inner, abs_path)
end

# Translate the `Castore.get_compression` NamedTuple back into a
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
    open_deserialized_castore_store(source, directory, read_only)

Open the Castore store for a deserialized system. In read-only mode the source
artifacts are opened in place. Otherwise the `.nc` (+ sidecar `.sqlite`) are
copied to an isolated working location under `directory` (or `tempdir()`) and the
copy is opened writable, so mutating the deserialized system cannot corrupt the
source file (e.g. a cached system shared by later builds).
"""
function open_deserialized_castore_store(
    source::AbstractString,
    directory::Union{Nothing, AbstractString},
    read_only::Bool,
)
    read_only && return open_castore_store(source; read_only = true)
    dir = isnothing(directory) ? tempdir() : String(directory)
    mkpath(dir)
    dst = joinpath(dir, string(UUIDs.uuid4()) * "_time_series.nc")
    cp(source, dst; force = true)
    src_sqlite = source * ".sqlite"
    isfile(src_sqlite) && cp(src_sqlite, dst * ".sqlite"; force = true)
    return open_castore_store(dst; read_only = false)
end

close!(store::Store) = Castore.close!(store.inner)

# The store is an opaque handle onto its backing artifacts, so the default field-wise
# `deepcopy` would hand the copy the SAME handle: mutating the copy (e.g.
# `clear_time_series!`) would then mutate the original. The backend exposes no clone API,
# so round-trip through `persist!` + `open_store` to give the copy its own artifacts.
function Base.deepcopy_internal(store::Store, dict::IdDict)
    haskey(dict, store) && return dict[store]

    # `persist!` copies an on-disk store's artifacts and materializes an in-memory one.
    # An in-memory store has no `path`, so its copy lands in `tempdir()` and is therefore
    # disk-backed: the backend gives us no way to clone in-memory state in place.
    directory = isnothing(store.path) ? tempdir() : dirname(store.path)
    dst = joinpath(directory, string(UUIDs.uuid4()) * "_time_series.nc")
    Castore.persist!(store.inner, dst)
    new_store = open_castore_store(dst; read_only = false)
    dict[store] = new_store
    return new_store
end

# ---- Conversions -----------------------------------------------------------

castore_category(category::String) =
    if category == "Component"
        Castore.Component
    elseif category == "SupplementalAttribute"
        Castore.SupplementalAttribute
    else
        error("unknown owner category $category")
    end

# Owner-category tag stored alongside each association ("Component" /
# "SupplementalAttribute"). Accepts an owner instance or its type.
get_owner_category(
    ::Union{InfrastructureSystemsComponent, Type{<:InfrastructureSystemsComponent}},
) = "Component"
get_owner_category(
    ::Union{SupplementalAttribute, Type{<:SupplementalAttribute}},
) = "SupplementalAttribute"

# ---- Element encoding ------------------------------------------------------
# Scalars store as a 1-D array tagged with their type name. Fixed-size
# FunctionData tuples store as a `(length, k)` Float64 array; reconstruction keys
# on the `ext` tag returned by `get_metadata`.

_storage_array(v::AbstractVector{<:Real}) = (collect(v), string(eltype(v)))

function _storage_array(v::AbstractVector{LinearFunctionData})
    mat = Matrix{Float64}(undef, length(v), 2)
    for (i, fd) in enumerate(v)
        mat[i, 1] = get_proportional_term(fd)
        mat[i, 2] = get_constant_term(fd)
    end
    return (mat, "LinearFunctionData")
end

function _storage_array(v::AbstractVector{QuadraticFunctionData})
    mat = Matrix{Float64}(undef, length(v), 3)
    for (i, fd) in enumerate(v)
        mat[i, 1] = get_quadratic_term(fd)
        mat[i, 2] = get_proportional_term(fd)
        mat[i, 3] = get_constant_term(fd)
    end
    return (mat, "QuadraticFunctionData")
end

# Ragged: each step has a variable number of (x, y) points. Store as a
# `(len, 1 + 2*max_points)` matrix padded with zeros; column 1 of each row is the
# point count, so `shape[0]` stays the timestep count.
function _storage_array(v::AbstractVector{PiecewiseLinearData})
    len = length(v)
    max_n = maximum(length(get_points(fd)) for fd in v; init = 0)
    mat = zeros(Float64, len, 1 + 2 * max_n)
    for (i, fd) in enumerate(v)
        pts = get_points(fd)
        mat[i, 1] = length(pts)
        for (j, p) in enumerate(pts)
            mat[i, 2j] = p.x
            mat[i, 2j + 1] = p.y
        end
    end
    return (mat, "PiecewiseLinearData")
end

# Ragged like PiecewiseLinearData, but the x- and y-coordinates have different
# lengths (`n` x-coords, `n - 1` y-coords/slopes). Store as a `(len, 2*max_n)`
# matrix: column 1 of each row is the x-coord count `n`, then the `n` x-coords,
# then the `n - 1` y-coords. Each row is self-describing, so decode needs no
# global width.
function _storage_array(v::AbstractVector{PiecewiseStepData})
    len = length(v)
    max_n = maximum(length(get_x_coords(fd)) for fd in v; init = 0)
    mat = zeros(Float64, len, max_n == 0 ? 1 : 2 * max_n)
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
    return (mat, "PiecewiseStepData")
end

# Fixed-arity `NTuple{N, Float64}` values — the storage form for tuple-shaped
# quantities (e.g. the hot/warm/cold start-up stages of a market bid). Dense, so unlike
# the ragged piecewise encodings every row is full width; the arity travels in the
# logical type so decode rebuilds the tuple without inferring it from the array shape.
function _storage_array(v::AbstractVector{NTuple{N, Float64}}) where {N}
    mat = Matrix{Float64}(undef, length(v), N)
    for (i, tup) in enumerate(v)
        for j in 1:N
            mat[i, j] = tup[j]
        end
    end
    return (mat, "NTuple{$N}")
end

_storage_array(v::AbstractVector) =
    error("Castore backend does not support time series element type $(eltype(v)) yet")

# Arity of an `NTuple{N}` reconstruction tag, or `nothing` when the tag is something else.
function _ntuple_arity(ext)
    ext isa AbstractString || return nothing
    m = match(r"^NTuple\{(\d+)\}$", ext)
    return isnothing(m) ? nothing : parse(Int, m.captures[1])
end

# The store's `ext` column is an opaque, package-owned payload it never interprets.
# IS wraps its reconstruction tag (a scalar eltype name, a FunctionData type name, or
# `"NTuple{N}"`) in a small JSON object under `function_type`, so more keys can be added
# later without a storage-format change. A missing tag (scalar forecast windows) stays
# unset. `_decode_ext` recovers the bare tag the reconstruction paths dispatch on.
_encode_ext(::Nothing) = nothing
_encode_ext(tag::AbstractString) = JSON.json(Dict("function_type" => tag))

_decode_ext(::Nothing) = nothing
function _decode_ext(payload::AbstractString)
    isempty(payload) && return nothing
    return get(JSON.parse(payload), "function_type", nothing)
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

# Reconstruct the full value vector from the stored array, keyed on ext.
function _read_values(
    store::Store,
    hash::Vector{UInt8},
    ext,
    dtype,
    len::Integer,
)
    if ext == "LinearFunctionData"
        mat = Castore.get_array_nd(store.inner, hash, Float64, (len, 2))
        return [LinearFunctionData(mat[i, 1], mat[i, 2]) for i in 1:len]
    elseif ext == "QuadraticFunctionData"
        mat = Castore.get_array_nd(store.inner, hash, Float64, (len, 3))
        return [QuadraticFunctionData(mat[i, 1], mat[i, 2], mat[i, 3]) for i in 1:len]
    elseif ext == "PiecewiseLinearData"
        flat = get_array_by_hash(store, hash, Float64)
        k = div(length(flat), len)  # 1 + 2*max_points (derived from the array size)
        mat = Castore.get_array_nd(store.inner, hash, Float64, (len, k))
        out = Vector{PiecewiseLinearData}(undef, len)
        for i in 1:len
            n = Int(round(mat[i, 1]))
            out[i] = PiecewiseLinearData([(mat[i, 2j], mat[i, 2j + 1]) for j in 1:n])
        end
        return out
    elseif ext == "PiecewiseStepData"
        flat = get_array_by_hash(store, hash, Float64)
        k = div(length(flat), len)
        mat = Castore.get_array_nd(store.inner, hash, Float64, (len, k))
        return [_decode_pwl_step_row(mat, i) for i in 1:len]
    elseif !isnothing(_ntuple_arity(ext))
        n = _ntuple_arity(ext)
        mat = Castore.get_array_nd(store.inner, hash, Float64, (len, n))
        return _decode_ntuples(mat, len, n)
    else
        return get_array_by_hash(store, hash, dtype)  # scalar
    end
end

# Decode an already-materialized static value array (the inverse of `_storage_array`),
# keyed on `ext`. Used by the non-sequential read path, where the backend
# returns the `(len, k)` FunctionData matrix (or scalar vector) in memory rather than
# by content hash. `len` is the timestep count (`size(arr, 1)`).
function _decode_static_values(arr, ext, len::Integer)
    if ext == "LinearFunctionData"
        return [LinearFunctionData(arr[i, 1], arr[i, 2]) for i in 1:len]
    elseif ext == "QuadraticFunctionData"
        return [QuadraticFunctionData(arr[i, 1], arr[i, 2], arr[i, 3]) for i in 1:len]
    elseif ext == "PiecewiseLinearData"
        out = Vector{PiecewiseLinearData}(undef, len)
        for i in 1:len
            n = Int(round(arr[i, 1]))
            out[i] = PiecewiseLinearData([(arr[i, 2j], arr[i, 2j + 1]) for j in 1:n])
        end
        return out
    elseif ext == "PiecewiseStepData"
        return [_decode_pwl_step_row(arr, i) for i in 1:len]
    elseif !isnothing(_ntuple_arity(ext))
        return _decode_ntuples(arr, len, _ntuple_arity(ext))
    else
        return arr  # scalar (1-D vector, or an N-D per-step array)
    end
end

# ---- Forecast element encoding ---------------------------------------------
# Forecast windows of scalars store as a `(horizon, count)` array (ext
# `nothing`). FunctionData windows store as `(horizon, count, k)` tagged with the
# logical type; each window column is encoded with the same scheme as a
# SingleTimeSeries via `_storage_array`.

_storage_forecast_array(windows::Vector{<:AbstractVector{<:Real}}) =
    (Float64.(reduce(hcat, windows)), nothing)

function _storage_forecast_array(windows::Vector{<:AbstractVector{<:FunctionData}})
    count = length(windows)
    encoded = [_storage_array(w) for w in windows]   # each: ((horizon, k) matrix, logical)
    logical = encoded[1][2]
    horizon = size(encoded[1][1], 1)
    k = maximum(size(e[1], 2) for e in encoded)      # pad ragged PWL to the widest
    arr = zeros(Float64, horizon, count, k)
    for c in 1:count
        m = encoded[c][1]
        @views arr[:, c, 1:size(m, 2)] .= m
    end
    return (arr, logical)
end

# Decode window `c` (1-based) of a `(horizon, count, k)` forecast array tagged
# with `ext` into a Vector of the corresponding FunctionData.
function _decode_forecast_window(arr::AbstractArray{<:Real, 3}, ext, c::Integer)
    horizon = size(arr, 1)
    if ext == "LinearFunctionData"
        return [LinearFunctionData(arr[h, c, 1], arr[h, c, 2]) for h in 1:horizon]
    elseif ext == "QuadraticFunctionData"
        return [
            QuadraticFunctionData(arr[h, c, 1], arr[h, c, 2], arr[h, c, 3]) for
            h in 1:horizon
        ]
    elseif ext == "PiecewiseLinearData"
        out = Vector{PiecewiseLinearData}(undef, horizon)
        for h in 1:horizon
            n = Int(round(arr[h, c, 1]))
            out[h] = PiecewiseLinearData([(arr[h, c, 2j], arr[h, c, 2j + 1]) for j in 1:n])
        end
        return out
    elseif ext == "PiecewiseStepData"
        slice = @view arr[:, c, :]  # (horizon, k) matrix for this window
        return [_decode_pwl_step_row(slice, h) for h in 1:horizon]
    end
    error("Castore backend cannot decode forecast ext $ext")
end

# ---- Operations (thin delegations to Castore) ----------------------

"""
    serialize_single!(store, owner_id, owner_type, owner_category, name, sts;
                      features=Dict(), units=nothing)

Add a `SingleTimeSeries` (data + metadata) to the Castore store. The array is
content-addressed; identical arrays are de-duplicated automatically.
`owner_category` is the String tag ("Component" / "SupplementalAttribute").
"""
function serialize_single!(
    store::Store,
    owner_id::Integer,
    owner_type::AbstractString,
    owner_category::AbstractString,
    name::AbstractString,
    sts::SingleTimeSeries;
    features = Dict{String, Any}(),
    units::Union{Nothing, AbstractString} = nothing,
)
    # Encode the values: scalars stay 1-D; FunctionData becomes a (length, k)
    # Float64 matrix. The logical-type tag drives reconstruction on read.
    # `get_array` returns the raw `Array{T, N}` (no TimeArray allocation).
    arr, logical = _storage_array(get_array(sts))
    # `name` is carried on the binding struct (matching the
    # InfrastructureSystems.jl object shape), not on add_time_series!.
    tss_ts = Castore.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        arr,
        name;
        ext = _encode_ext(logical),
    )
    Castore.add_time_series!(store.inner, owner_id, owner_type,
        castore_category(owner_category),
        tss_ts; features = features, units = units)
    return
end

"""
    get_metadata(store, owner_id, owner_category, name; resolution, features=Dict())

Return `(; initial_timestamp, resolution, length, data_hash, ext, dtype)`
for a stored SingleTimeSeries. Throws `Castore.NotFoundError` if absent.
"""
get_metadata(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    Castore.get_metadata(
        store.inner,
        owner_id,
        owner_category,
        name;
        resolution = resolution,
        features = features,
    )

get_array_by_hash(
    store::Store,
    data_hash::Vector{UInt8},
    ::Type{T} = Float64,
) where {T} =
    Castore.get_array_by_hash(store.inner, data_hash, T)

"""
    serialize_non_sequential!(store, owner_id, owner_type, owner_category, name, nts;
                              features=Dict(), units=nothing)

Add a `NonSequentialTimeSeries` (irregular timestamps + data) to the Castore store.
The array is content-addressed (and de-duplicated); the explicit timestamps are
carried on the association. `owner_category` is the String tag ("Component" /
"SupplementalAttribute").
"""
function serialize_non_sequential!(
    store::Store,
    owner_id::Integer,
    owner_type::AbstractString,
    owner_category::AbstractString,
    name::AbstractString,
    nts::NonSequentialTimeSeries;
    features = Dict{String, Any}(),
    units::Union{Nothing, AbstractString} = nothing,
)
    # Same element encoding as SingleTimeSeries: scalars stay 1-D; FunctionData
    # becomes a (length, k) Float64 matrix, with the logical-type tag driving the
    # reconstruction on read.
    arr, logical = _storage_array(get_array(nts))
    tss_ts = Castore.NonSequentialTimeSeries(
        get_timestamps(nts),
        arr,
        name;
        ext = _encode_ext(logical),
    )
    Castore.add_time_series!(store.inner, owner_id, owner_type,
        castore_category(owner_category),
        tss_ts; features = features, units = units)
    return
end

"""
    get_non_sequential(store, owner_id, owner_category, name; features=Dict()) -> NonSequentialTimeSeries

Reconstruct a `NonSequentialTimeSeries` (timestamps + decoded array) from the Castore
store. A non-sequential series is addressed by name + features (it has no resolution).
"""
function get_non_sequential(
    store::Store,
    owner_id::Integer,
    owner_category::Castore.OwnerCategory,
    name::AbstractString;
    features = Dict{String, Any}(),
)
    nts = Castore.get_time_series(Castore.NonSequentialTimeSeries, store.inner, owner_id,
        owner_category, name; features = features)
    len = length(nts.timestamps)
    values = _decode_static_values(nts.data, _decode_ext(nts.ext), len)
    return NonSequentialTimeSeries(String(name), nts.timestamps, values)
end

has_time_series(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    Castore.has_time_series(
        store.inner,
        owner_id,
        owner_category,
        name;
        resolution = resolution,
        features = features,
    )

remove_single!(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    Castore.remove_time_series!(store.inner, owner_id, owner_category, name;
        resolution = resolution, features = features)

get_counts(store::Store) = Castore.get_counts(store.inner)

function get_num_time_series(store::Store)
    c = get_counts(store)
    return c.static_time_series + c.forecasts
end

flush!(store::Store) = Castore.flush!(store.inner)

# Association rows count: the store holds supplemental attribute associations as well as
# time series, and `serialize(::SystemData)` skips writing the artifact entirely for an
# empty store. Ignoring associations here would silently drop them for a system that has
# attributes but no time series.
function Base.isempty(store::Store)
    return get_num_time_series(store) == 0 &&
           Castore.count_supplemental_attribute_associations(store.inner) == 0
end

# Compression is fixed when the store is created/opened (threaded through the FFI
# via `_castore_compression_kwargs`); report the policy the store carries.
get_compression_settings(store::Store) =
    _compression_settings(Castore.get_compression(store.inner))

"""
    serialize(store::Store, file_path)

Persist the store's two artifacts to `file_path` (the NetCDF arrays) and
`file_path * ".sqlite"` (the metadata). No HDF5 is produced.
"""
function serialize(store::Store, file_path::AbstractString)
    # `persist!` copies the two artifacts for an on-disk store and materializes an
    # in-memory store to disk, so either kind of System can be serialized.
    Castore.persist!(store.inner, file_path)
    @info "Serialized Castore store to $file_path (+ .sqlite)"
    return
end

"""Remove all time series (data + metadata) from the store."""
clear_time_series!(store::Store) = Castore.clear!(store.inner)

# Remove every time series owned by `(owner_id, owner_category)` in one shot
# (order-independent, so it is not blocked by the SingleTimeSeries/DST removal guard).
castore_clear_owner!(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory) =
    Castore.clear!(store.inner; owner_id = owner_id, owner_category = owner_category)

# A hashable identity for one stored association (a `Castore.list_keys` row),
# used to diff the store before/after a batch update for rollback.
castore_row_identity(row) = (
    row.owner_id,
    row.owner_category,
    nameof(row.time_series_type),
    row.name,
    row.resolution === nothing ? nothing : Dates.Millisecond(row.resolution).value,
    Tuple(sort!([string(k) => v for (k, v) in row.features])),
)

# Counts of SingleTimeSeries and DeterministicSingleTimeSeries associations that
# reference the given content hash, across all owners. Used to decide whether a
# SingleTimeSeries can be removed without orphaning a DST that shares its array.
# Resolved by a single catalog query in the Castore core rather than scanning every
# association here.
castore_array_sts_dst_counts(store::Store, hash::Vector{UInt8}) =
    Castore.count_array_references(store.inner, hash)

# Remove the single association described by a `Castore.list_keys` row.
function castore_remove_row!(store::Store, row)
    feats = Dict{String, Any}(row.features)
    category = castore_category(row.owner_category)
    if _castore_is_type(row.time_series_type) <: SingleTimeSeries
        remove_single!(store, row.owner_id, category, row.name;
            resolution = row.resolution, features = feats)
    else
        # Pin the row's own interval: one name can carry several forecasts differing only
        # by interval, and the removal must hit exactly the row described.
        remove_typed!(store, row.owner_id, category, row.name,
            castore_ts_code(_castore_is_type(row.time_series_type));
            resolution = row.resolution, interval = row.interval, features = feats)
    end
    return
end

# The store handle / file path differ across a serialize→deserialize round-trip,
# so compare structurally by counts. Element-level equality is covered by the
# Castore integration tests.
function compare_values(
    match_fn::Union{Function, Nothing},
    x::Store,
    y::Store;
    kwargs...,
)
    return get_counts(x) == get_counts(y)
end

# ---- TimeSeriesManager routing ---------------------------------------------

# Validate the raw time series array before storing. A DeterministicSingleTimeSeries
# is a derived view over an already-validated SingleTimeSeries (it has no raw
# `get_data`), so it skips the check.
_castore_check_time_series_data(time_series::TimeSeriesData) =
    check_time_series_data(time_series)
_castore_check_time_series_data(::DeterministicSingleTimeSeries) = nothing

"""
Route a manager-level `add_time_series!` to the Castore store, dispatching on the
concrete time series type. Data identity is the array content hash.
"""
function castore_add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    throw_if_does_not_support_time_series(owner)
    _castore_check_time_series_data(time_series)
    return _castore_add!(mgr, owner, time_series; features...)
end

# Dispatch on the concrete series type. Forecasts (including
# DeterministicSingleTimeSeries) and NonSequentialTimeSeries route to their
# dedicated handlers; SingleTimeSeries is stored below; anything else is
# unsupported on the Castore backend.
_castore_add!(mgr::TimeSeriesManager, owner::TimeSeriesOwners, ts::Forecast; features...) =
    _castore_add_forecast!(mgr, owner, ts; features...)

_castore_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    ts::NonSequentialTimeSeries;
    features...,
) = _castore_add_non_sequential!(mgr, owner, ts; features...)

_castore_add!(::TimeSeriesManager, ::TimeSeriesOwners, ts::TimeSeriesData; features...) =
    error(
        "Castore backend supports SingleTimeSeries, NonSequentialTimeSeries, " *
        "Deterministic, DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
        "(got $(typeof(ts)))",
    )

function _castore_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::SingleTimeSeries;
    features...,
)
    store = mgr.data_store::Store
    owner_id, owner_type, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    name = get_name(time_series)
    resolution = get_resolution(time_series)
    feats = _castore_features(features)

    if has_time_series(store, owner_id, category, name;
        resolution = resolution, features = feats)
        throw(
            ArgumentError(
                "Time series data with duplicate attributes are already stored: " *
                "$(owner_type)/$(name) resolution=$(resolution) features=$(feats)"),
        )
    end

    serialize_single!(store, owner_id, owner_type, owner_category, name, time_series;
        features = feats)
    return StaticTimeSeriesKey(;
        time_series_type = SingleTimeSeries,
        name = name,
        initial_timestamp = get_initial_timestamp(time_series),
        resolution = resolution,
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
end

"""
Route a manager-level `add_time_series!` of a `NonSequentialTimeSeries` to the Castore
store. Addressed by name + features (a non-sequential series has no resolution);
data identity is the array content hash.
"""
function _castore_add_non_sequential!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::NonSequentialTimeSeries;
    features...,
)
    store = mgr.data_store::Store
    owner_id, owner_type, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    name = get_name(time_series)
    feats = _castore_features(features)

    if has_typed(store, owner_id, category, name, Castore.CASTORE_TYPE_NON_SEQUENTIAL;
        features = feats)
        throw(
            ArgumentError(
                "Time series data with duplicate attributes are already stored: " *
                "$(owner_type)/$(name) features=$(feats)"),
        )
    end

    serialize_non_sequential!(store, owner_id, owner_type, owner_category, name,
        time_series; features = feats)
    return NonSequentialTimeSeriesKey(;
        time_series_type = NonSequentialTimeSeries,
        name = name,
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
end

# Anything other than SingleTimeSeries / NonSequentialTimeSeries / Forecast is
# unsupported on the Castore backend.
castore_get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    kwargs...,
) where {T <: TimeSeriesData} =
    error(
        "Castore backend supports SingleTimeSeries, Deterministic, " *
        "DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
        "(requested $T)",
    )

# Forecasts reconstruct from the stored forecast type, honoring `start_time` /
# `count` slicing on the forecast window axis. `len`, when given, truncates each
# window to its first `len` horizon steps. A forecast stored as a
# DeterministicSingleTimeSeries is materialized into a regular `Deterministic`.
castore_get_time_series(
    ::Type{<:Forecast},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = _castore_get_forecast(owner, name;
    start_time = start_time, len = len, count = count, resolution = resolution,
    interval = interval, features...)

"""
Route a public `get_time_series(SingleTimeSeries, owner, name; ...)` to the Castore
store, honoring `start_time` / `len` slicing on the time axis.
"""
function castore_get_time_series(
    ::Type{<:SingleTimeSeries},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,  # not applicable to a static series; ignored
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    # Resolve the unique series matching a possibly-partial (subset) feature /
    # resolution query, then read it by its exact stored attributes.
    matched = castore_get_metadata(
        owner,
        SingleTimeSeries,
        name;
        resolution = resolution,
        features...,
    )
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(matched))
    meta = get_metadata(store, owner_id, category, name;
        resolution = get_resolution(matched), features = feats)
    full =
        _read_values(store, meta.data_hash, _decode_ext(meta.ext), meta.dtype, meta.length)

    start = isnothing(start_time) ? meta.initial_timestamp : start_time
    index = compute_time_array_index(meta.initial_timestamp, start, meta.resolution)
    n = isnothing(len) ? (meta.length - index + 1) : len
    if index < 1 || index + n - 1 > meta.length
        throw(ArgumentError("requested index=$index len=$n exceeds range $(meta.length)"))
    end
    vals = full[index:(index + n - 1)]
    t0 = meta.initial_timestamp + meta.resolution * (index - 1)
    sts = SingleTimeSeries(
        String(name),
        t0,
        meta.resolution,
        vals,
    )
    return sts
end

"""
Route a public `get_time_series(NonSequentialTimeSeries, owner, name; ...)` to the
Castore store, honoring `start_time` / `len` slicing on the (irregular) time axis.
"""
function castore_get_time_series(
    ::Type{<:NonSequentialTimeSeries},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,  # not applicable to a static series; ignored
    resolution::Union{Nothing, Dates.Period} = nothing,  # not applicable; ignored
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    # Resolve the unique series matching a possibly-partial (subset) feature query,
    # then read it by its exact stored attributes.
    matched = castore_get_metadata(owner, NonSequentialTimeSeries, name; features...)
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(matched))
    nts = get_non_sequential(store, owner_id, category, name; features = feats)
    (isnothing(start_time) && isnothing(len)) && return nts

    # Slice on the explicit, strictly-increasing timestamps. The values are sliced
    # directly (not via a TimeArray) so FunctionData / N-D series slice too.
    timestamps = get_timestamps(nts)
    full = get_array(nts)
    total = size(full, 1)
    start = isnothing(start_time) ? timestamps[1] : start_time
    index = searchsortedfirst(timestamps, start)
    (index <= total && timestamps[index] == start) ||
        throw(ArgumentError("start_time=$start is not a timestamp in the series"))
    n = isnothing(len) ? (total - index + 1) : len
    if n < 1 || index + n - 1 > total
        throw(ArgumentError("requested index=$index len=$n exceeds range $total"))
    end
    colons = ntuple(_ -> Colon(), ndims(full) - 1)
    vals = full[index:(index + n - 1), colons...]
    return NonSequentialTimeSeries(String(name), timestamps[index:(index + n - 1)], vals)
end

# ---- Forecasts (Deterministic / DeterministicSingleTimeSeries) -------------

has_typed(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory, name::AbstractString,
    ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    Castore.has_typed(store.inner, owner_id, owner_category, name, ts_type;
        resolution = resolution, interval = interval, features = features)

remove_typed!(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory, name::AbstractString,
    ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    Castore.remove_typed!(store.inner, owner_id, owner_category, name, ts_type;
        resolution = resolution, interval = interval, features = features)

# Copy an association onto another owner (optionally renaming) entirely inside the
# store. Arrays are content-addressed, so no data is duplicated and the stored type
# is preserved exactly — notably a DeterministicSingleTimeSeries stays one, whereas
# a get_time_series/add_time_series! round-trip through Julia would materialize it
# into a dense Deterministic.
copy_typed!(store::Store, owner_id::Integer,
    owner_category::Castore.OwnerCategory, name::AbstractString, ts_type::Integer,
    dst_owner_id::Integer, dst_owner_type::AbstractString;
    new_name::Union{Nothing, AbstractString} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    Castore.copy_time_series!(store.inner, owner_id, owner_category, name, ts_type,
        dst_owner_id, dst_owner_type; new_name = new_name,
        resolution = resolution, interval = interval, features = features)

# IS encodes a single-window forecast (count == 1) with `interval = Second(0)`,
# since there is no second window to step to. The Castore store, however, requires a
# strictly-positive interval. Store such a forecast with `interval = horizon` (the
# DeterministicSingleTimeSeries convention) so it validates, and map it back to
# `Second(0)` on read via `_forecast_display_interval`. `Dates.value` reads the raw
# count without unit conversion, so this is safe for calendar intervals too.
_storage_forecast_interval(interval::Dates.Period, horizon::Dates.Period) =
    Dates.value(interval) == 0 ? horizon : interval

# Inverse of `_storage_forecast_interval`: a stored single-window forecast carries
# `interval == horizon`; present it to IS as `Second(0)`.
_forecast_display_interval(count::Integer, interval::Dates.Period, horizon::Dates.Period) =
    (count == 1 && interval == horizon) ? Dates.Second(0) : interval

"""Add a Deterministic or DeterministicSingleTimeSeries via the Castore store."""
function _castore_add_forecast!(mgr::TimeSeriesManager, owner, ts; features...)
    store = mgr.data_store::Store
    owner_id, owner_type, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    name = get_name(ts)
    resolution = get_resolution(ts)
    interval = get_interval(ts)
    feats = _castore_features(features)

    # All forecasts that share a (resolution, interval) group must agree on the
    # window parameters (count, horizon, initial timestamp).
    check_params_compatibility(
        castore_forecast_parameters(store; resolution = resolution, interval = interval),
        make_time_series_parameters(ts),
    )

    if ts isa Probabilistic
        if has_typed(store, owner_id, category, name, Castore.CASTORE_TYPE_PROBABILISTIC;
            resolution = resolution, features = feats)
            throw(
                ArgumentError(
                    "Time series data with duplicate attributes are already stored",
                ),
            )
        end
        arr = Float64.(get_array_for_hdf(ts))  # (percentile_count, horizon_count, count)
        prob =
            Castore.Probabilistic(get_initial_timestamp(ts), resolution, get_horizon(ts),
                _storage_forecast_interval(interval, get_horizon(ts)), get_count(ts),
                Float64.(get_percentiles(ts)), arr, name)
        Castore.add_time_series!(store.inner, owner_id, owner_type,
            category, prob; features = feats)
        return ForecastKey(;
            time_series_type = typeof(ts), name = name,
            initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
            horizon = get_horizon(ts), interval = interval, count = get_count(ts),
            features = Dict{String, Any}(feats))
    elseif ts isa Deterministic
        windows = collect(values(get_data(ts)))
        # (horizon_count, count) for scalars; (horizon_count, count, k) tagged with
        # `logical` for FunctionData windows.
        arr, logical = _storage_forecast_array(windows)
        count = length(windows)
        ts_type = Castore.CASTORE_TYPE_DETERMINISTIC
    elseif ts isa DeterministicSingleTimeSeries
        if has_typed(store, owner_id, category, name,
            Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE;
            resolution = resolution, features = feats)
            throw(
                ArgumentError(
                    "Time series data with duplicate attributes are already stored",
                ),
            )
        end
        # The Castore store derives a DeterministicSingleTimeSeries from a stored
        # SingleTimeSeries (sharing the array) via transform_single_time_series!,
        # rather than persisting a separate forecast array. Ensure the underlying
        # series is present, then derive the DST.
        underlying = get_single_time_series(ts)
        has_time_series(
            store,
            owner_id,
            category,
            name;
            resolution = resolution,
            features = feats,
        ) ||
            serialize_single!(store, owner_id, owner_type, owner_category, name,
                underlying;
                features = feats)
        Castore.transform_single_time_series!(store.inner, get_horizon(ts), interval;
            owner_category = category, resolution = resolution)
        # DeterministicSingleTimeSeries has no internal UUID, so nothing to assign.
        return ForecastKey(;
            time_series_type = typeof(ts), name = name,
            initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
            horizon = get_horizon(ts), interval = interval, count = get_count(ts),
            features = Dict{String, Any}(feats))
    elseif ts isa Scenarios
        arr = Float64.(get_array_for_hdf(ts))  # (scenario_count, horizon_count, count)
        logical = nothing
        count = get_count(ts)
        ts_type = Castore.CASTORE_TYPE_SCENARIOS
    else
        error("unsupported forecast type $(typeof(ts))")
    end

    if has_typed(
        store,
        owner_id,
        category,
        name,
        ts_type;
        resolution = resolution,
        features = feats,
    )
        throw(
            ArgumentError("Time series data with duplicate attributes are already stored"),
        )
    end
    storage_interval = _storage_forecast_interval(interval, get_horizon(ts))
    tss_ts = if ts_type == Castore.CASTORE_TYPE_DETERMINISTIC
        Castore.Deterministic(get_initial_timestamp(ts), resolution, get_horizon(ts),
            storage_interval, count, arr, name; ext = _encode_ext(logical))
    else
        Castore.Scenarios(get_initial_timestamp(ts), resolution, get_horizon(ts),
            storage_interval, count, arr, name; ext = _encode_ext(logical))
    end
    Castore.add_time_series!(store.inner, owner_id, owner_type,
        category, tss_ts; features = feats)
    return ForecastKey(;
        time_series_type = typeof(ts), name = name,
        initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
        horizon = get_horizon(ts), interval = interval, count = count,
        features = Dict{String, Any}(feats))
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

    if isnothing(start_time)
        start_idx = 1
    else
        offset = start_time - initial_timestamp  # Millisecond
        interval_ms = Dates.Millisecond(interval).value
        if start_time < initial_timestamp ||
           (interval_ms != 0 && rem(offset.value, interval_ms) != 0)
            throw(
                ArgumentError(
                    "start_time=$start_time is not a forecast window timestamp"),
            )
        end
        start_idx = interval_ms == 0 ? 1 : div(offset.value, interval_ms) + 1
    end
    if start_idx < 1 || start_idx > total_count
        throw(ArgumentError(
            "start_time=$start_time is out of range (count=$total_count)"))
    end
    n = isnothing(count) ? total_count - start_idx + 1 : count
    if n < 1 || start_idx + n - 1 > total_count
        throw(
            ArgumentError(
                "requested count=$n from start_time=$start_time exceeds the " *
                "$total_count stored forecast windows"),
        )
    end

    # A zero interval is IS's single-window sentinel (count == 1): window
    # arithmetic below collapses to a zero-width `[initial, initial)` range that
    # selects nothing. The request has already been validated against
    # `total_count`, so read the whole (single-window) series instead of slicing.
    Dates.value(interval) == 0 && return nothing

    start_ts = initial_timestamp + interval * (start_idx - 1)
    end_ts = initial_timestamp + interval * (start_idx - 1 + n)  # exclusive
    return (start_ts, end_ts)
end

# Assemble forecast windows into a `SortedDict` with a concrete value type.
# Building it from a generator yields `SortedDict{Any, Any}`, which
# `Deterministic`'s `convert_data` then coerces to `Vector{Float64}` — corrupting
# FunctionData windows. Materializing first pins the value type to the actual
# window vector type (`Vector{Float64}` or `Vector{<:FunctionData}`).
function _assemble_forecast_windows(initial_timestamp, interval, count, window)
    windows = [window(i) for i in 1:count]
    V = isempty(windows) ? Vector{Float64} : typeof(windows[1])
    data = SortedDict{Dates.DateTime, V}()
    for i in 1:count
        data[initial_timestamp + interval * (i - 1)] = windows[i]
    end
    return data
end

"""Reconstruct a forecast from the Castore store (matches the STORED type),
honoring `start_time` / `count` slicing on the window axis."""
function _castore_get_forecast(
    owner, name;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    # Resolve the unique forecast matching a possibly-partial (subset) feature /
    # resolution / interval query, then read it by its exact stored attributes.
    # `interval` matters when one series name carries several forecasts that differ only
    # by interval (`transform_single_time_series!` with `delete_existing = false`);
    # without it the lookup is ambiguous.
    matched = castore_get_metadata(
        owner, Forecast, name;
        resolution = resolution, interval = interval, features...,
    )
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(matched))
    resolution = get_resolution(matched)
    # Pin every store lookup below to the resolved forecast's exact (stored) interval.
    # One name can carry several forecasts differing only by interval, and the typed
    # lookups match on attributes, so without this they would match more than one.
    matched_interval = get_interval(matched)
    # `len`, when given, truncates each window to its first `len` horizon steps
    # (the horizon is the leading axis of a window vector or matrix).
    _truncate(w) = isnothing(len) ? w : (ndims(w) == 1 ? w[1:len] : w[1:len, :])

    if has_typed(store, owner_id, category, name, Castore.CASTORE_TYPE_PROBABILISTIC;
        resolution = resolution, interval = matched_interval, features = feats)
        # `.data` is the canonical (percentile_count, horizon_count, count) array.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        p = Castore.get_time_series(Castore.Probabilistic, store.inner, owner_id, category,
            name;
            resolution = resolution, interval = matched_interval, features = feats,
            time_range = tr)
        # `p` is already sliced to the requested window range by the store.
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(p.count)
            data[p.initial_timestamp + p.interval * (i - 1)] =
                _truncate(permutedims(p.data[:, :, i]))
        end
        result = Probabilistic(; name = String(name), data = data,
            percentiles = p.percentiles, resolution = p.resolution,
            interval = _forecast_display_interval(p.count, p.interval, p.horizon))
        return result
    elseif has_typed(store, owner_id, category, name, Castore.CASTORE_TYPE_DETERMINISTIC;
        resolution = resolution, interval = matched_interval, features = feats)
        # `.data` is the canonical (horizon_count, count) array.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        d = Castore.get_time_series(Castore.Deterministic, store.inner, owner_id, category,
            name;
            resolution = resolution, interval = matched_interval, features = feats,
            time_range = tr)
        fmeta = Castore.get_forecast_metadata(store.inner, owner_id, category, name,
            Castore.CASTORE_TYPE_DETERMINISTIC; resolution = resolution,
            interval = matched_interval, features = feats)
        logical = _decode_ext(fmeta.ext)  # `nothing` for scalar windows
        window(i) = _truncate(
            if isnothing(logical)
                d.data[:, i]
            else
                _decode_forecast_window(d.data, logical, i)
            end,
        )
        # `d` is already sliced to the requested window range by the store.
        data = _assemble_forecast_windows(
            d.initial_timestamp, d.interval, d.count, window)
        result = Deterministic(; name = String(name), data = data,
            resolution = d.resolution,
            interval = _forecast_display_interval(d.count, d.interval, d.horizon))
        return result
    elseif has_typed(store, owner_id, category, name,
        Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE;
        resolution = resolution, interval = matched_interval, features = feats)
        # A DeterministicSingleTimeSeries is an internal storage optimization: it
        # shares the underlying SingleTimeSeries array instead of materializing the
        # overlapping windows. On read it is always returned as a regular
        # `Deterministic` — the Castore store expands the shared array into the
        # canonical (horizon_count, count) window matrix (honoring `time_range`),
        # so the reconstruction below is identical to the `Deterministic` branch.
        #
        # This does NOT cost the storage optimization on a copy: `copy_time_series!`
        # clones the association row inside the store, so the stored type survives
        # without ever round-tripping through these Julia objects.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        d = Castore.get_time_series(Castore.DeterministicSingleTimeSeries, store.inner,
            owner_id,
            category, name;
            resolution = resolution, interval = matched_interval, features = feats,
            time_range = tr)
        fmeta = Castore.get_forecast_metadata(store.inner, owner_id, category, name,
            Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE; resolution = resolution,
            interval = matched_interval, features = feats,
        )
        logical = _decode_ext(fmeta.ext)
        # Scalar windows come back as a 2D `(horizon_count, count)` array; encoded
        # FunctionData windows carry trailing coefficient dims (3D). A DST inherits
        # the shared SingleTimeSeries metadata, whose `ext` may be set even
        # for scalar data, so key the decode on the array rank rather than `logical`.
        dst_window(i) = _truncate(
            if ndims(d.data) == 3
                _decode_forecast_window(d.data, logical, i)
            else
                d.data[:, i]
            end,
        )
        # A single window has no step between window starts, so IS represents that
        # interval as `Second(0)`; otherwise the stored window interval is kept.
        # `d` is already sliced to the requested window range by the store.
        data = _assemble_forecast_windows(
            d.initial_timestamp, d.interval, d.count, dst_window)
        return Deterministic(; name = String(name), data = data,
            resolution = d.resolution,
            interval = _forecast_display_interval(d.count, d.interval, d.horizon))
    elseif has_typed(store, owner_id, category, name, Castore.CASTORE_TYPE_SCENARIOS;
        resolution = resolution, interval = matched_interval, features = feats)
        # `.data` is the canonical (scenario_count, horizon_count, count) array.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        s_ts = Castore.get_time_series(Castore.Scenarios, store.inner, owner_id, category,
            name;
            resolution = resolution, interval = matched_interval, features = feats,
            time_range = tr)
        # `s_ts` is already sliced to the requested window range by the store.
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(s_ts.count)
            data[s_ts.initial_timestamp + s_ts.interval * (i - 1)] =
                _truncate(permutedims(s_ts.data[:, :, i]))
        end
        result = Scenarios(; name = String(name), data = data,
            scenario_count = s_ts.scenario_count, resolution = s_ts.resolution,
            interval = _forecast_display_interval(s_ts.count, s_ts.interval, s_ts.horizon))
        return result
    end
    throw(Castore.NotFoundError("no forecast for owner=$owner_id name=$name"))
end

# ---- ForecastReader --------------------------------------------------------
# A timestamp-oriented reader over the forecasts matching a filter, for the
# simulation pattern "at each window timestamp, get every component's forecast".
# It wraps the Castore `ForecastReader`, which deduplicates the physical `.nc` read:
# components that share a forecast array (and read plan) collapse to one window
# slot, so the data is read once per timestamp no matter how many components
# reference it. This wrapper carries that dedup up to Julia — each unique slot's
# window is materialized (and FunctionData-decoded) at most once per read.

# Owner-category String tag for a `Castore.OwnerCategory` enum (the inverse of
# `castore_category`), used to resolve a reader entry back to its owner object.
_owner_category_string(c::Castore.OwnerCategory) =
    c == Castore.Component ? "Component" : "SupplementalAttribute"

# Map an IS forecast type to the `Castore` reader type. A `Deterministic`
# (or the `AbstractDeterministic` abstraction) reader is abstract and also
# includes `DeterministicSingleTimeSeries`; a DST query is exact.
_tss_forecast_type(::Type{<:DeterministicSingleTimeSeries}) =
    Castore.DeterministicSingleTimeSeries
_tss_forecast_type(::Type{<:AbstractDeterministic}) = Castore.Deterministic
_tss_forecast_type(::Type{<:Probabilistic}) = Castore.Probabilistic
_tss_forecast_type(::Type{<:Scenarios}) = Castore.Scenarios

# Decode a single `(horizon, k)` FunctionData window matrix (the per-window analog
# of `_decode_forecast_window`, which slices a `(horizon, count, k)` array).
function _decode_forecast_window_matrix(mat::AbstractMatrix{<:Real}, ext)
    horizon = size(mat, 1)
    if ext == "LinearFunctionData"
        return [LinearFunctionData(mat[h, 1], mat[h, 2]) for h in 1:horizon]
    elseif ext == "QuadraticFunctionData"
        return [QuadraticFunctionData(mat[h, 1], mat[h, 2], mat[h, 3]) for h in 1:horizon]
    elseif ext == "PiecewiseLinearData"
        out = Vector{PiecewiseLinearData}(undef, horizon)
        for h in 1:horizon
            n = Int(round(mat[h, 1]))
            out[h] = PiecewiseLinearData([(mat[h, 2j], mat[h, 2j + 1]) for j in 1:n])
        end
        return out
    end
    error("Castore backend cannot decode forecast ext $ext")
end

# The `ext` tags that mean a window is FunctionData (stored as a
# `(horizon, k)` matrix). Any other tag (`nothing`, or a scalar dtype string like
# "Float64" carried by a SingleTimeSeries-backed DST) is a plain scalar window.
const _CASTORE_FUNCTIONDATA_LOGICAL =
    ("LinearFunctionData", "QuadraticFunctionData", "PiecewiseLinearData")

# Orient + decode one raw window into IS's canonical per-window value (matching a
# single `get_time_series(...).data[timestamp]`): Probabilistic/Scenarios windows
# are stored `(count_member, horizon)` and transposed to `(horizon, member)`;
# Deterministic/DST windows are a horizon vector, or a FunctionData column decoded
# via `ext`.
function _decode_forecast_reader_window(
    ::Type{T},
    raw,
    ext,
) where {T <: Forecast}
    if T <: Probabilistic || T <: Scenarios
        return permutedims(raw)
    end
    (ext in _CASTORE_FUNCTIONDATA_LOGICAL) || return raw
    return _decode_forecast_window_matrix(raw, ext)
end

"""
One forecast in a [`ForecastReader`], bound to its owner. `slot` is the 1-based
index of the deduplicated window read backing this entry; entries that share a
forecast array (and read plan) report the same `slot`.
"""
struct ForecastReaderEntry
    owner::TimeSeriesOwners
    key::TimeSeriesKey
    slot::Int
end

"""
A timestamp-oriented reader over every forecast matching a build filter. Drive it
with [`read_forecast_window!`](@ref), then pull each entry's window with
[`get_forecast_window`](@ref). Build one with `build_forecast_reader(data, T; ...)`.

Forecasts that share an underlying array read the `.nc` file once per timestamp
(and materialize once in Julia); inspect the sharing via the entries' `slot`
field or [`get_num_forecast_slots`](@ref).
"""
mutable struct ForecastReader
    inner::Castore.ForecastReader
    store::Store
    entries::Vector{ForecastReaderEntry}
    "ext for each entry (parallel to `entries`); `nothing` for scalars."
    exts::Vector{Union{Nothing, String}}
    "The IS forecast type the reader was built for (drives window orientation)."
    reported_type::Type
    "Per-slot materialized window cache; reset on each read."
    windows::Vector{Any}
    has_read::Bool
end

# Build a reader from the store. `id_to_owner(owner_id::Int, category::String)`
# resolves each entry's owner object (the system holds the owner maps). Per-entry
# metadata (owner, key, ext) is resolved once here, off the read path.
function castore_build_forecast_reader(
    store::Store,
    id_to_owner,
    ::Type{T};
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features = Dict{String, Any}(),
) where {T <: Forecast}
    inner = Castore.build_forecast_reader(store.inner, _tss_forecast_type(T);
        resolution = resolution, name = name, features = features)
    tss_entries = Castore.forecast_entries(inner)
    n = length(tss_entries)
    entries = Vector{ForecastReaderEntry}(undef, n)
    exts = Vector{Union{Nothing, String}}(undef, n)
    for (i, e) in enumerate(tss_entries)
        info = Castore.key_info(e.key)
        owner = id_to_owner(Int(info.owner_id), _owner_category_string(info.owner_category))
        is_type = _castore_is_type(nameof(info.time_series_type))
        feats = Dict{String, Any}(info.features)
        fmeta = Castore.get_forecast_metadata(store.inner, info.owner_id,
            info.owner_category, info.name, castore_ts_code(is_type);
            resolution = info.resolution, features = feats)
        exts[i] = _decode_ext(fmeta.ext)
        key = ForecastKey(;
            time_series_type = is_type,
            name = info.name,
            initial_timestamp = fmeta.initial_timestamp,
            resolution = fmeta.resolution,
            horizon = fmeta.horizon,
            interval = fmeta.interval,
            count = fmeta.count,
            features = feats,
        )
        # `e.slot` is 0-based in the Castore store; carry it 1-based for Julia.
        entries[i] = ForecastReaderEntry(owner, key, e.slot + 1)
    end
    windows = Vector{Any}(nothing, Castore.forecast_num_slots(inner))
    return ForecastReader(inner, store, entries, exts, T, windows, false)
end

"""
$(TYPEDSIGNATURES)
The reader's window timeline as `(; initial_timestamp, resolution, interval,
count)`. Valid read timestamps are `initial_timestamp + k·interval` for
`k in 0:count-1`.
"""
get_forecast_reader_timeline(reader::ForecastReader) =
    Castore.forecast_timeline(reader.inner)

"""
$(TYPEDSIGNATURES)
The reader's entries, one per matching forecast, each bound to its owner.
"""
get_forecast_reader_entries(reader::ForecastReader) = reader.entries

"""
$(TYPEDSIGNATURES)
The number of deduplicated window slots — the count of physical `.nc` reads
[`read_forecast_window!`](@ref) performs per timestamp. Entries that share a
forecast array collapse to one slot, so this is `≤ length(get_forecast_reader_entries(reader))`.
"""
get_num_forecast_slots(reader::ForecastReader) = length(reader.windows)

Base.length(reader::ForecastReader) = length(reader.entries)

"""
$(TYPEDSIGNATURES)
Read the forecast window at `timestamp` for every entry, performing one `.nc`
read per unique slot. Follow with [`get_forecast_window`](@ref). Throws if
`timestamp` is off the window timeline.
"""
function read_forecast_window!(reader::ForecastReader, timestamp::Dates.DateTime)
    Castore.forecast_read!(reader.inner, timestamp)
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
function get_forecast_window(reader::ForecastReader, entry_index::Integer)
    reader.has_read || throw(
        ArgumentError("call read_forecast_window! before reading window values"))
    entry = reader.entries[entry_index]
    cached = reader.windows[entry.slot]
    cached === nothing || return cached
    raw = Castore.forecast_values(reader.inner, entry_index)
    window = _decode_forecast_reader_window(
        reader.reported_type, raw, reader.exts[entry_index])
    reader.windows[entry.slot] = window
    return window
end

"""Route `has_time_series(owner, T, name; ...)` to the Castore store. Honors partial
(subset) feature / resolution queries: matches if any stored series of type `T`
contains at least the requested features."""
function castore_has_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    return !isempty(
        castore_owner_list_metadata(owner;
            time_series_type = T, name = name, resolution = resolution,
            interval = interval, features...),
    )
end

# The single stored TimeSeriesType code for a concrete IS time series type.
castore_ts_code(::Type{<:SingleTimeSeries}) = Castore.CASTORE_TYPE_SINGLE
castore_ts_code(::Type{<:NonSequentialTimeSeries}) = Castore.CASTORE_TYPE_NON_SEQUENTIAL
castore_ts_code(::Type{<:DeterministicSingleTimeSeries}) =
    Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE
castore_ts_code(::Type{<:Deterministic}) = Castore.CASTORE_TYPE_DETERMINISTIC
castore_ts_code(::Type{<:Probabilistic}) = Castore.CASTORE_TYPE_PROBABILISTIC
castore_ts_code(::Type{<:Scenarios}) = Castore.CASTORE_TYPE_SCENARIOS

# Name-less existence queries. `_castore_query_codes(T)` maps a query type to the
# stored TimeSeriesType codes to match (empty tuple = any type).
_castore_query_codes(::Type{<:SingleTimeSeries}) = (Castore.CASTORE_TYPE_SINGLE,)
_castore_query_codes(::Type{<:NonSequentialTimeSeries}) =
    (Castore.CASTORE_TYPE_NON_SEQUENTIAL,)
_castore_query_codes(::Type{<:DeterministicSingleTimeSeries}) =
    (Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE,)
_castore_query_codes(::Type{<:AbstractDeterministic}) =
    (Castore.CASTORE_TYPE_DETERMINISTIC, Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE)
_castore_query_codes(::Type{<:Probabilistic}) = (Castore.CASTORE_TYPE_PROBABILISTIC,)
_castore_query_codes(::Type{<:Scenarios}) = (Castore.CASTORE_TYPE_SCENARIOS,)
_castore_query_codes(::Type{<:Forecast}) = (Castore.CASTORE_TYPE_DETERMINISTIC,
    Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE, Castore.CASTORE_TYPE_PROBABILISTIC,
    Castore.CASTORE_TYPE_SCENARIOS)
_castore_query_codes(::Type{<:StaticTimeSeries}) =
    (Castore.CASTORE_TYPE_SINGLE, Castore.CASTORE_TYPE_NON_SEQUENTIAL)
_castore_query_codes(::Type{<:TimeSeriesData}) = ()

# The single stored TimeSeriesType code to push into the core `list_keys` filter
# for a query type, or `nothing` when the type cannot be expressed as one code:
# an abstract family, or `Deterministic` (which, under the metadata-store
# semantics encoded in `_castore_type_matches`, also matches a stored
# `DeterministicSingleTimeSeries`). When `nothing`, the caller applies the
# residual `_castore_type_matches` filter on the (already narrowed) rows.
_castore_pushable_code(::Type{<:SingleTimeSeries}) = Castore.CASTORE_TYPE_SINGLE
_castore_pushable_code(::Type{<:NonSequentialTimeSeries}) =
    Castore.CASTORE_TYPE_NON_SEQUENTIAL
_castore_pushable_code(::Type{<:DeterministicSingleTimeSeries}) =
    Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE
_castore_pushable_code(::Type{<:Probabilistic}) = Castore.CASTORE_TYPE_PROBABILISTIC
_castore_pushable_code(::Type{<:Scenarios}) = Castore.CASTORE_TYPE_SCENARIOS
_castore_pushable_code(::Type{<:TimeSeriesData}) = nothing

# All stored TimeSeriesType codes whose IS type is a subtype of `T` (strict `<:`
# semantics — distinct from `_castore_type_matches`, which treats a `Deterministic`
# query as also matching a `DeterministicSingleTimeSeries`). Used by the
# store-wide filters (`resolutions`, `list_owner_ids`) that key on subtyping.
const _CASTORE_CODE_TYPES = (
    (Castore.CASTORE_TYPE_SINGLE, SingleTimeSeries),
    (Castore.CASTORE_TYPE_NON_SEQUENTIAL, NonSequentialTimeSeries),
    (Castore.CASTORE_TYPE_DETERMINISTIC, Deterministic),
    (Castore.CASTORE_TYPE_DETERMINISTIC_SINGLE, DeterministicSingleTimeSeries),
    (Castore.CASTORE_TYPE_PROBABILISTIC, Probabilistic),
    (Castore.CASTORE_TYPE_SCENARIOS, Scenarios),
)
_castore_subtype_codes(::Type{T}) where {T <: TimeSeriesData} =
    Tuple(c for (c, k) in _CASTORE_CODE_TYPES if k <: T)

# True iff `owner` has any time series, optionally restricted to type `T`.
function castore_has_any(owner; time_series_type::Union{Nothing, Type} = nothing)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, owner_category = _castore_owner_args(owner)
    category = castore_category(owner_category)
    codes = time_series_type === nothing ? () : _castore_query_codes(time_series_type)
    isempty(codes) && return Castore.has_for_owner(store.inner, owner_id, category)
    return any(
        c -> Castore.has_for_owner(store.inner, owner_id, category; time_series_type = c),
        codes,
    )
end

# ---- Metadata reconstruction (parity with the SQLite metadata store) --------
# IS time series type for a `Castore` metadata-row type (matched by name).
_castore_is_type(t::Type) = _castore_is_type(nameof(t))
_castore_is_type(s::Symbol) =
    if s === :SingleTimeSeries
        SingleTimeSeries
    elseif s === :NonSequentialTimeSeries
        NonSequentialTimeSeries
    elseif s === :Deterministic
        Deterministic
    elseif s === :DeterministicSingleTimeSeries
        DeterministicSingleTimeSeries
    elseif s === :Probabilistic
        Probabilistic
    elseif s === :Scenarios
        Scenarios
    else
        error("Castore backend does not support time series type $s")
    end

# Whether a stored row of concrete type `row_type` satisfies a query for type `T`.
# Mirrors the metadata-store semantics: a `Deterministic` (or `AbstractDeterministic`)
# query also matches a `DeterministicSingleTimeSeries` (which reads as a
# `Deterministic`), while a `DeterministicSingleTimeSeries` query matches DST only.
_castore_type_matches(row_type::Type, ::Type{T}) where {T <: TimeSeriesData} =
    if T <: DeterministicSingleTimeSeries
        row_type <: DeterministicSingleTimeSeries
    elseif T <: AbstractDeterministic
        row_type <: AbstractDeterministic
    else
        row_type <: T
    end

# Build the matching IS `TimeSeriesKey` from a `Castore.list_keys` row. The key is
# the single descriptor for a stored association; forecast-only fields
# (percentiles, scenario_count) are not carried — they come from the data on read.
function _key_from_row(row)
    feats = Dict{String, Any}(string(k) => v for (k, v) in row.features)
    is_type = _castore_is_type(row.time_series_type)
    if is_type <: NonSequentialTimeSeries
        return NonSequentialTimeSeriesKey(;
            time_series_type = is_type,
            name = row.name,
            length = row.length,
            features = feats,
        )
    elseif is_type <: StaticTimeSeries
        return StaticTimeSeriesKey(;
            time_series_type = is_type,
            name = row.name,
            initial_timestamp = row.initial_timestamp,
            resolution = row.resolution,
            length = row.length,
            features = feats,
        )
    elseif is_type <: Forecast
        return ForecastKey(;
            time_series_type = is_type,
            name = row.name,
            initial_timestamp = row.initial_timestamp,
            resolution = row.resolution,
            horizon = row.horizon,
            interval = row.interval,
            count = row.count,
            features = feats,
        )
    end
    error("Castore backend cannot build a key for $(row.time_series_type)")
end

# All matching associations for one owner, as `TimeSeriesKey` objects. The core
# `list_keys` query filters owner / name / resolution / features; an abstract
# `time_series_type` (or `Deterministic`, which also matches a DST) and `interval`
# are not catalog filter columns, so they are applied as a residual on the
# already-narrowed rows.
function _castore_list_metadata(
    store::Store,
    owner_id::Integer,
    owner_category::Castore.OwnerCategory;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features = (),
)
    type_code =
        isnothing(time_series_type) ? nothing : _castore_pushable_code(time_series_type)
    feats = Dict{String, Any}(string(k) => v for (k, v) in features)
    rows =
        Castore.list_keys(store.inner; owner_id = owner_id, owner_category = owner_category,
            time_series_type = type_code, name = name, features = feats)
    out = TimeSeriesKey[]
    for row in rows
        if !isnothing(time_series_type)
            _castore_type_matches(
                _castore_is_type(row.time_series_type),
                time_series_type,
            ) ||
                continue
        end
        # `resolution`/`interval` are matched here, not pushed into the catalog
        # query, so `Period` equality is used (a regular `Hour(1)` equals the
        # stored `Millisecond`, while an irregular `Month`/`Year` does not — the
        # Castore store keys on milliseconds and cannot represent those exactly).
        isnothing(resolution) || row.resolution == resolution || continue
        if !isnothing(interval)
            (row.interval !== nothing && row.interval == interval) || continue
        end
        push!(out, _key_from_row(row))
    end
    return out
end

# A key for every time series in the store (all owners).
_castore_all_metadata(store::Store) =
    [_key_from_row(row) for row in Castore.list_keys(store.inner)]

# Owner-level `list_metadata` entry point (mirrors the metadata-store signature).
function castore_owner_list_metadata(
    owner::TimeSeriesOwners;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, owner_category = _castore_owner_args(owner)
    return _castore_list_metadata(store, owner_id, castore_category(owner_category);
        time_series_type = time_series_type, name = name, resolution = resolution,
        interval = interval, features = _castore_features(features))
end

# Single matching metadata; throws when zero or more than one match (parity with
# `TimeSeriesMetadataStore.get_metadata`).
function castore_get_metadata(
    owner::TimeSeriesOwners,
    ::Type{T},
    name::AbstractString;
    resolution = nothing,
    interval = nothing,
    features...,
) where {T <: TimeSeriesData}
    items = castore_owner_list_metadata(owner; time_series_type = T, name = name,
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

# Content hash (hex) of the array `key` resolves to under `owner`. Narrows the
# catalog to the owner + the key's type/name in one query, then matches the exact
# resolution + features in-memory (Period equality, as in `_castore_list_metadata`).
function castore_get_time_series_hash(owner::TimeSeriesOwners, key::TimeSeriesKey)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) &&
        throw(Castore.NotFoundError("owner has no time series to hash"))
    store = mgr.data_store::Store
    owner_id, _, owner_category = _castore_owner_args(owner)
    T = get_time_series_type(key)
    rows = Castore.list_array_groups(store.inner; owner_id = owner_id,
        owner_category = castore_category(owner_category),
        time_series_type = _castore_pushable_code(T), name = get_name(key))
    target_res = get_resolution(key)
    target_feats = get_features(key)
    for row in rows
        _castore_type_matches(_castore_is_type(row.time_series_type), T) || continue
        row.resolution == target_res || continue
        row.features == target_feats || continue
        return row.data_hash
    end
    throw(Castore.NotFoundError("no stored array matches key name=$(get_name(key))"))
end

# Group every stored association by content hash, as `(owner, key)` pairs. The
# `id_to_owner` callback resolves an `(owner_id, owner_category)` row back to the
# owner object (the system holds the component / supplemental-attribute maps).
# One catalog query returns the hash on every row, so no per-row metadata fetch.
#
# `DeterministicSingleTimeSeries` rows are excluded: such a forecast is a view of
# its own `SingleTimeSeries` and so always reports that array's hash, which is an
# artifact of the transformation rather than data shared between time series.
function castore_group_by_hash(
    store::Store,
    id_to_owner;
    only_shared = true,
)
    groups = Dict{String, Vector{Tuple{TimeSeriesOwners, TimeSeriesKey}}}()
    for row in Castore.list_array_groups(store.inner)
        _castore_is_type(row.time_series_type) <: DeterministicSingleTimeSeries && continue
        owner = id_to_owner(Int(row.owner_id), row.owner_category)
        pairs = get!(
            () -> Tuple{TimeSeriesOwners, TimeSeriesKey}[], groups, row.data_hash)
        push!(pairs, (owner, _key_from_row(row)))
    end
    only_shared && filter!(x -> length(x.second) > 1, groups)
    return groups
end

# Reconstruct each matching time series for an owner; applies `filter_func`.
function castore_get_time_series_multiple(
    owner::TimeSeriesOwners,
    filter_func;
    type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
)
    metas = castore_owner_list_metadata(owner; time_series_type = type, name = name,
        resolution = resolution, interval = interval)
    Channel() do channel
        for m in metas
            feats = (Symbol(k) => v for (k, v) in get_features(m))
            ts = if m isa ForecastKey
                # Pin the read to this key's own interval: a name may carry several
                # forecasts differing only by interval, which would otherwise be
                # ambiguous here.
                _castore_get_forecast(owner, get_name(m);
                    resolution = get_resolution(m), interval = get_interval(m), feats...,
                )
            elseif m isa NonSequentialTimeSeriesKey
                castore_get_time_series(NonSequentialTimeSeries, owner, get_name(m); feats...)
            else
                castore_get_time_series(SingleTimeSeries, owner, get_name(m);
                    resolution = get_resolution(m), feats...)
            end
            (isnothing(filter_func) || filter_func(ts)) && put!(channel, ts)
        end
    end
end

# Reassign every time series from `old_id` to `new_id` (component re-id). Components
# are always the Component owner category.
function castore_replace_component_id!(
    store::Store,
    old_id::Int,
    new_id::Int,
)
    Castore.replace_owner!(store.inner, old_id, new_id, Castore.Component)
    return
end

# ---- Store-wide aggregates (parity with the SQLite metadata store) ----------

# Distinct, sorted resolutions across the store, optionally restricted to a type
# (strict subtype). One DISTINCT query per concrete subtype code, in the core.
function castore_get_time_series_resolutions(
    store::Store;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
)
    isnothing(time_series_type) && return sort!(Castore.get_resolutions(store.inner))
    codes = _castore_subtype_codes(time_series_type)
    res = Set{Dates.Millisecond}()
    for code in codes
        union!(res, Castore.get_resolutions(store.inner; time_series_type = code))
    end
    return sort!(collect(res))
end

# Counts of time series grouped by type name (parity with counts_by_type).
function castore_get_time_series_counts_by_type(store::Store)
    counts = OrderedDict{String, Int}()
    for r in Castore.counts_by_type(store.inner)
        counts[string(nameof(r.time_series_type))] = r.count
    end
    return [OrderedDict("type" => k, "count" => v) for (k, v) in sort!(OrderedDict(counts))]
end

# Number of distinct stored arrays (parity with get_num_time_series).
castore_get_num_time_series(store::Store) =
    Castore.num_distinct_arrays(store.inner)

# Counts of distinct stored arrays (shared series count once) and owners by
# category, matching the metadata-store's `get_time_series_counts`.
castore_time_series_counts(store::Store) =
    Castore.time_series_counts(store.inner)

# Static-time-series summary DataFrame (parity with the metadata-store version).
# The core groups the rows; we shape them into the DataFrame.
function castore_static_summary_table(store::Store)
    rows = Castore.static_summary(store.inner)
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

# Forecast summary DataFrame (parity with the metadata-store version).
function castore_forecast_summary_table(store::Store)
    rows = Castore.forecast_summary(store.inner)
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

# First forecast's parameters, optionally filtered by resolution/interval. The
# store keeps a single forecast window configuration, mirroring the legacy
# `get_forecast_parameters`.
function castore_forecast_parameters(
    store::Store;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    # The first forecast key matching `resolution`/`interval`, compared with
    # `Period` equality. The store preserves the calendar-aware `Period` type, so
    # the stored periods are passed through unchanged — converting them to
    # `Millisecond` would throw for irregular `Month`/`Year` resolutions.
    for row in Castore.list_keys(store.inner)
        _castore_is_type(row.time_series_type) <: Forecast || continue
        isnothing(resolution) || row.resolution == resolution || continue
        if !isnothing(interval)
            (row.interval !== nothing && row.interval == interval) || continue
        end
        return ForecastParameters(;
            horizon = row.horizon,
            initial_timestamp = row.initial_timestamp,
            interval = row.interval,
            count = row.count,
            resolution = row.resolution,
        )
    end
    return nothing
end

# Distinct owner ids of the given category that have time series, optionally
# restricted by time series type (strict subtype) and resolution.
function castore_list_owner_ids(
    store::Store,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = castore_category(get_owner_category(owner_type))
    # Without a resolution filter, enumerate owner ids in the core (optionally per
    # concrete subtype code). With one, scan the category's keys so `Period`
    # equality is used for the resolution match (see `_castore_list_metadata`).
    if isnothing(resolution)
        isnothing(time_series_type) && return Castore.list_owner_ids(store.inner, category)
        ids = Set{Int}()
        for code in _castore_subtype_codes(time_series_type)
            union!(
                ids,
                Castore.list_owner_ids(store.inner, category; time_series_type = code),
            )
        end
        return collect(ids)
    end
    ids = Set{Int}()
    for row in Castore.list_keys(store.inner; owner_category = category)
        if !isnothing(time_series_type)
            _castore_is_type(row.time_series_type) <: time_series_type || continue
        end
        row.resolution == resolution || continue
        push!(ids, Int(row.owner_id))
    end
    return collect(ids)
end

# (owner_id, key) for every time series of the given owner category, optionally
# restricted by time series type (strict subtype) and resolution. Owner category
# and resolution are pushed into the core query; the strict type filter is applied
# on the returned keys.
function castore_list_metadata_with_owner(
    store::Store,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = castore_category(get_owner_category(owner_type))
    rows = Castore.list_keys(store.inner; owner_category = category)
    out = NamedTuple[]
    for row in rows
        if !isnothing(time_series_type)
            _castore_is_type(row.time_series_type) <: time_series_type || continue
        end
        isnothing(resolution) || row.resolution == resolution || continue
        push!(out, (owner_id = Int(row.owner_id), metadata = _key_from_row(row)))
    end
    return out
end

# Verify that, per resolution, all SingleTimeSeries share an initial timestamp
# and length; return `(initial_timestamp, length)` (parity with the
# metadata-store check). SingleTimeSeries at different resolutions have
# legitimately different grids, so with more than one resolution present the
# caller must pass `resolution` to name the grid it wants. Resolved by a single
# DISTINCT query in the core.
function castore_check_consistency(
    store::Store,
    ::Type{<:SingleTimeSeries};
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    grids = try
        Castore.check_static_consistency(store.inner; resolution = resolution)
    catch e
        e isa Castore.IntegrityError || rethrow()
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

function castore_check_consistency(
    ::Store,
    ::Type{<:Forecast};
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    return nothing
end
