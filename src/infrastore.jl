# InfraStore-backed time series storage.
#
# InfraStore manages both the time series data and the associations between components /
# supplemental attributes and that data. The `Store` type (declared in `store.jl`)
# delegates BOTH array data and metadata to it, via the `InfraStore.jl` binding package.
# InfraStore owns both: arrays land in a NetCDF4 `.nc` file (content-addressed by SHA-256
# hash) and metadata in a sibling `.sqlite` file. Time series *data* identity is the
# array content hash, not a UUID. Persisting a system writes the `.nc` + `.sqlite` pair
# directly.
#
# This file holds the IS-specific glue (owner/feature conversion, window
# flatten/reshape, manager routing). All low-level FFI lives in `InfraStore`.

# ---- Store construction ----------------------------------------------------

"""
    open_infrastore_store(path; read_only=false)

Open an existing on-disk InfraStore store from its `.nc` base path.
"""
function open_infrastore_store(path::AbstractString; read_only::Bool = false)
    # Open with an absolute path so the InfraStore handle's backing path survives later
    # `cd`s (e.g. a deserialize that opens a relative basename, then a re-serialize
    # elsewhere). Opening relative leaves the handle resolving its source relative to
    # the cwd at open time, so a later `persist!` fails once the cwd changes.
    abs_path = abspath(String(path))
    inner = InfraStore.open_store(abs_path; read_only = read_only)
    return Store(inner)
end

# The store's backing path (nothing for an in-memory store). InfraStore owns this state
# now; IS no longer duplicates it.
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
artifacts are opened in place. Otherwise the `.nc` (+ sidecar `.sqlite`) are
copied to an isolated working location under `directory` (or `tempdir()`) and the
copy is opened writable, so mutating the deserialized system cannot corrupt the
source file (e.g. a cached system shared by later builds).
"""
function open_deserialized_infrastore_store(
    source::AbstractString,
    directory::Union{Nothing, AbstractString},
    read_only::Bool,
)
    read_only && return open_infrastore_store(source; read_only = true)
    dir = isnothing(directory) ? tempdir() : String(directory)
    mkpath(dir)
    dst = joinpath(dir, string(UUIDs.uuid4()) * "_time_series.nc")
    cp(source, dst; force = true)
    src_sqlite = source * ".sqlite"
    isfile(src_sqlite) && cp(src_sqlite, dst * ".sqlite"; force = true)
    return open_infrastore_store(dst; read_only = false)
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
    directory = isnothing(path) ? tempdir() : dirname(path)
    dst = joinpath(directory, string(UUIDs.uuid4()) * "_time_series.nc")
    InfraStore.persist!(store.inner, dst)
    new_store = open_infrastore_store(dst; read_only = false)
    dict[store] = new_store
    return new_store
end

# ---- Conversions -----------------------------------------------------------

# Owner category of an association owner, as the `InfraStore.OwnerCategory`
# enum the binding takes everywhere. Accepts an owner instance or its type.
get_owner_category(
    ::Union{InfrastructureSystemsComponent, Type{<:InfrastructureSystemsComponent}},
) = InfraStore.Component
get_owner_category(
    ::Union{SupplementalAttribute, Type{<:SupplementalAttribute}},
) = InfraStore.SupplementalAttribute

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
    error("InfraStore backend does not support time series element type $(eltype(v)) yet")

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
    error("InfraStore backend cannot decode forecast ext $ext")
end

# ---- Operations (thin delegations to InfraStore) ----------------------

# The InfraStore destination an IS-level write lands on: the wrapped store handle,
# or an `AddBatch` staging a bulk commit.
_infrastore_sink(store::Store) = store.inner
_infrastore_sink(batch::InfraStore.AddBatch) = batch

"""
    serialize_single!(dest, owner_id, owner_type, owner_category, name, sts;
                      features=Dict(), units=nothing)

Add a `SingleTimeSeries` (data + metadata) to the InfraStore store. The array is
content-addressed; identical arrays are de-duplicated automatically.
`owner_category` is the `InfraStore.OwnerCategory` enum. `dest` is the
[`Store`](@ref) for an immediate write, or a `InfraStore.AddBatch` to stage the
series for a bulk commit. Returns the encoded array's byte size — the amount a
batch keeps buffered until it flushes.
"""
function serialize_single!(
    dest::Union{Store, InfraStore.AddBatch},
    owner_id::Integer,
    owner_type::AbstractString,
    owner_category::InfraStore.OwnerCategory,
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
    tss_ts = InfraStore.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        arr,
        name;
        ext = _encode_ext(logical),
    )
    InfraStore.add_time_series!(_infrastore_sink(dest), owner_id, owner_type,
        owner_category, tss_ts; features = features, units = units)
    # The encoded array is what a batch keeps buffered; its exact byte size
    # drives the auto-flush accounting.
    return sizeof(arr)
end

"""
    serialize_non_sequential!(dest, owner_id, owner_type, owner_category, name, nts;
                              features=Dict(), units=nothing)

Add a `NonSequentialTimeSeries` (irregular timestamps + data) to the InfraStore store.
The array is content-addressed (and de-duplicated); the explicit timestamps are
carried on the association. `owner_category` is the `InfraStore.OwnerCategory`
enum. `dest` is the [`Store`](@ref) for an immediate write, or a
`InfraStore.AddBatch` to stage the series for a bulk commit. Returns the byte
size of the encoded array plus timestamps — the amount a batch keeps buffered
until it flushes.
"""
function serialize_non_sequential!(
    dest::Union{Store, InfraStore.AddBatch},
    owner_id::Integer,
    owner_type::AbstractString,
    owner_category::InfraStore.OwnerCategory,
    name::AbstractString,
    nts::NonSequentialTimeSeries;
    features = Dict{String, Any}(),
    units::Union{Nothing, AbstractString} = nothing,
)
    # Same element encoding as SingleTimeSeries: scalars stay 1-D; FunctionData
    # becomes a (length, k) Float64 matrix, with the logical-type tag driving the
    # reconstruction on read.
    arr, logical = _storage_array(get_array(nts))
    tss_ts = InfraStore.NonSequentialTimeSeries(
        get_timestamps(nts),
        arr,
        name;
        ext = _encode_ext(logical),
    )
    InfraStore.add_time_series!(_infrastore_sink(dest), owner_id, owner_type,
        owner_category, tss_ts; features = features, units = units)
    # As in `serialize_single!`: the staged bytes are the encoded array plus the
    # explicit timestamps the association carries.
    return sizeof(arr) + sizeof(get_timestamps(nts))
end

"""
    get_non_sequential(store, owner_id, owner_category, name; features=Dict()) -> NonSequentialTimeSeries

Reconstruct a `NonSequentialTimeSeries` (timestamps + decoded array) from the InfraStore
store. A non-sequential series is addressed by name + features (it has no resolution).
"""
function get_non_sequential(
    store::Store,
    owner_id::Integer,
    owner_category::InfraStore.OwnerCategory,
    name::AbstractString;
    features = Dict{String, Any}(),
)
    nts = InfraStore.get_time_series(InfraStore.NonSequentialTimeSeries, store.inner,
        owner_id,
        owner_category, name; features = features)
    len = length(nts.timestamps)
    values = _decode_static_values(nts.data, _decode_ext(nts.ext), len)
    return NonSequentialTimeSeries(String(name), nts.timestamps, values)
end

function get_num_time_series(store::Store)
    c = InfraStore.get_counts(store.inner)
    return c.static_time_series + c.forecasts
end

flush!(store::Store) = InfraStore.flush!(store.inner)

# Association rows count: the store holds supplemental attribute associations as well as
# time series, and `serialize(::SystemData)` skips writing the artifact entirely for an
# empty store. Ignoring associations here would silently drop them for a system that has
# attributes but no time series.
function Base.isempty(store::Store)
    return get_num_time_series(store) == 0 &&
           InfraStore.count_supplemental_attribute_associations(store.inner) == 0
end

# Compression is fixed when the store is created/opened (threaded through the FFI
# via `_infrastore_compression_kwargs`); report the policy the store carries.
get_compression_settings(store::Store) =
    _compression_settings(InfraStore.get_compression(store.inner))

"""
    serialize(store::Store, file_path)

Persist the store's two artifacts to `file_path` (the NetCDF arrays) and
`file_path * ".sqlite"` (the metadata). No HDF5 is produced.
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

# A hashable identity for one stored association (a `InfraStore.list_keys` row),
# used to diff the store before/after a batch update for rollback.
infrastore_row_identity(row) = (
    row.owner_id,
    row.owner_category,
    nameof(row.time_series_type),
    row.name,
    row.resolution === nothing ? nothing : Dates.Millisecond(row.resolution).value,
    Tuple(sort!([string(k) => v for (k, v) in row.features])),
)

# Remove the single association described by a `InfraStore.list_keys` row.
function infrastore_remove_row!(store::Store, row)
    feats = Dict{String, Any}(row.features)
    # Pin the row's own interval: one name can carry several forecasts differing
    # only by interval, and the removal must hit exactly the row described.
    InfraStore.remove_time_series!(row.time_series_type, store.inner, row.owner_id,
        row.owner_category, row.name;
        resolution = row.resolution, interval = row.interval, features = feats)
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
Route a manager-level `add_time_series!` to the InfraStore store, dispatching on the
concrete time series type. Data identity is the array content hash.
"""
function infrastore_add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    throw_if_does_not_support_time_series(owner)
    check_time_series_data(time_series)
    return _infrastore_add!(mgr, owner, time_series; features...)
end

# Dispatch on the concrete series type. Forecasts and NonSequentialTimeSeries route
# to their dedicated handlers; SingleTimeSeries is stored below; anything else is
# unsupported on the InfraStore backend.
_infrastore_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    ts::Forecast;
    features...,
) =
    _infrastore_add_forecast!(mgr, owner, ts; features...)

_infrastore_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    ts::NonSequentialTimeSeries;
    features...,
) = _infrastore_add_non_sequential!(mgr, owner, ts; features...)

_infrastore_add!(::TimeSeriesManager, ::TimeSeriesOwners, ts::TimeSeriesData; features...) =
    error(
        "InfraStore backend supports SingleTimeSeries, NonSequentialTimeSeries, " *
        "Deterministic, Probabilistic, and Scenarios (got $(typeof(ts))). A " *
        "DeterministicSingleTimeSeries is derived in-store with " *
        "transform_single_time_series!.",
    )

# Map the store's duplicate-association rejection to the IS-level ArgumentError.
# The add paths rely on the store's unique constraint instead of paying a
# pre-existence catalog query per add; any other error propagates unchanged.
function _infrastore_rethrow_duplicate(e, owner_type, name)
    if e isa InfraStore.DuplicateAssociationError ||
       e isa InfraStore.DuplicateTimeSeriesError
        throw(
            ArgumentError(
                "Time series data with duplicate attributes are already stored: " *
                "$(owner_type)/$(name)"),
        )
    end
    rethrow()
end

function _infrastore_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::SingleTimeSeries;
    features...,
)
    store = mgr.data_store::Store
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(time_series)
    resolution = get_resolution(time_series)
    feats = _infrastore_features(features)

    try
        serialize_single!(store, owner_id, owner_type, category, name, time_series;
            features = feats)
    catch e
        _infrastore_rethrow_duplicate(e, owner_type, name)
    end
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
Route a manager-level `add_time_series!` of a `NonSequentialTimeSeries` to the InfraStore
store. Addressed by name + features (a non-sequential series has no resolution);
data identity is the array content hash.
"""
function _infrastore_add_non_sequential!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::NonSequentialTimeSeries;
    features...,
)
    store = mgr.data_store::Store
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(time_series)
    feats = _infrastore_features(features)

    try
        serialize_non_sequential!(store, owner_id, owner_type, category, name,
            time_series; features = feats)
    catch e
        _infrastore_rethrow_duplicate(e, owner_type, name)
    end
    return NonSequentialTimeSeriesKey(;
        time_series_type = NonSequentialTimeSeries,
        name = name,
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
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
    ::Type{<:Forecast},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) = _infrastore_get_forecast(owner, name;
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
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(key))

    start = isnothing(start_time) ? initial_timestamp : start_time
    index = compute_time_array_index(initial_timestamp, start, resolution)
    n = isnothing(len) ? (total - index + 1) : len
    if index < 1 || n < 1 || index + n - 1 > total
        throw(ArgumentError("requested index=$index len=$n exceeds range $total"))
    end
    # The store clamps an out-of-grid range rather than erroring, so the window is
    # validated above against the key before the sliced read.
    time_range = if (isnothing(start_time) && isnothing(len))
        nothing
    else
        (start, start + resolution * n)
    end
    sts = InfraStore.get_time_series(InfraStore.SingleTimeSeries, store.inner, owner_id,
        category, name;
        resolution = resolution, features = feats, time_range = time_range)
    # A plain vector is always scalar data; anything else decodes through the
    # `ext` reconstruction tag the read carries.
    values = if sts.data isa Vector
        sts.data
    else
        _decode_static_values(sts.data, _decode_ext(sts.ext), size(sts.data, 1))
    end
    return SingleTimeSeries(String(name), sts.initial_timestamp, sts.resolution, values)
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

# Key-addressed NonSequentialTimeSeries read (no catalog re-resolution). The
# timestamps are irregular, so `start_time`/`len` slice on the materialized
# series in Julia; the read itself is one store call.
function _infrastore_read_non_sequential(
    owner::TimeSeriesOwners,
    key::NonSequentialTimeSeriesKey;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(key))
    nts = get_non_sequential(store, owner_id, category, get_name(key); features = feats)
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
    return NonSequentialTimeSeries(
        String(get_name(key)), timestamps[index:(index + n - 1)], vals)
end

# ---- Forecasts --------------------------------------------------------------

# IS encodes a single-window forecast (count == 1) with `interval = Second(0)`,
# since there is no second window to step to. The InfraStore store, however, requires a
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

# Build the InfraStore object for a forecast, returning `(store_ts, count)`.
# `count` also feeds the returned key; for a `Deterministic` it is derived from
# the window data rather than read from the forecast.
function _storage_forecast(ts::Probabilistic, resolution, interval, name)
    arr = Float64.(get_array_for_hdf(ts))  # (percentile_count, horizon_count, count)
    prob = InfraStore.Probabilistic(get_initial_timestamp(ts), resolution,
        get_horizon(ts), interval, get_count(ts), Float64.(get_percentiles(ts)),
        arr, name)
    return prob, get_count(ts)
end

function _storage_forecast(ts::Deterministic, resolution, interval, name)
    windows = collect(values(get_data(ts)))
    # (horizon_count, count) for scalars; (horizon_count, count, k) tagged with
    # `logical` for FunctionData windows.
    arr, logical = _storage_forecast_array(windows)
    count = length(windows)
    d = InfraStore.Deterministic(get_initial_timestamp(ts), resolution,
        get_horizon(ts), interval, count, arr, name; ext = _encode_ext(logical))
    return d, count
end

function _storage_forecast(ts::Scenarios, resolution, interval, name)
    arr = Float64.(get_array_for_hdf(ts))  # (scenario_count, horizon_count, count)
    s = InfraStore.Scenarios(get_initial_timestamp(ts), resolution,
        get_horizon(ts), interval, get_count(ts), arr, name;
        ext = _encode_ext(nothing))
    return s, get_count(ts)
end

_storage_forecast(ts::Forecast, resolution, interval, name) =
    throw(
        ArgumentError(
            "Cannot add a forecast of type $(typeof(ts)). Supported types are " *
            "Deterministic, Probabilistic, and Scenarios; a " *
            "DeterministicSingleTimeSeries is derived in-store with " *
            "transform_single_time_series!.",
        ),
    )

"""Add a forecast via the InfraStore store."""
function _infrastore_add_forecast!(mgr::TimeSeriesManager, owner, ts; features...)
    store = mgr.data_store::Store
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(ts)
    resolution = get_resolution(ts)
    interval = get_interval(ts)
    feats = _infrastore_features(features)

    # All forecasts that share a (resolution, interval) group must agree on the
    # window parameters (count, horizon, initial timestamp).
    check_params_compatibility(
        infrastore_forecast_parameters(store; resolution = resolution, interval = interval),
        make_time_series_parameters(ts),
    )

    storage_interval = _storage_forecast_interval(interval, get_horizon(ts))
    tss_ts, count = _storage_forecast(ts, resolution, storage_interval, name)
    try
        InfraStore.add_time_series!(store.inner, owner_id, owner_type,
            category, tss_ts; features = feats)
    catch e
        _infrastore_rethrow_duplicate(e, owner_type, name)
    end
    return ForecastKey(;
        time_series_type = typeof(ts), name = name,
        initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
        horizon = get_horizon(ts), interval = interval, count = count,
        features = Dict{String, Any}(feats))
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
        if e isa InfraStore.DuplicateAssociationError ||
           e isa InfraStore.DuplicateTimeSeriesError
            throw(
                ArgumentError(
                    "Time series data with duplicate attributes are already stored"),
            )
        end
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
# resolution, horizon, storage_interval, name)` returns that object together
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
    obj, count = build(
        initial,
        resolution,
        horizon,
        _storage_forecast_interval(interval, horizon),
        name,
    )
    InfraStore.add_time_series!(batch, owner_id, owner_type, category, obj;
        features = feats)
    key = ForecastKey(;
        time_series_type = typeof(ts), name = name,
        initial_timestamp = initial, resolution = resolution,
        horizon = horizon, interval = interval, count = count,
        features = Dict{String, Any}(feats))
    # `obj.data` is the encoded dense array the batch buffers — its exact byte
    # size drives the auto-flush accounting.
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
    ) do initial, resolution, horizon, storage_interval, name
        arr = Float64.(get_array_for_hdf(ts))  # (percentile_count, horizon_count, count)
        prob = InfraStore.Probabilistic(initial, resolution, horizon, storage_interval,
            get_count(ts), Float64.(get_percentiles(ts)), arr, name)
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
    ) do initial, resolution, horizon, storage_interval, name
        windows = collect(values(get_data(ts)))
        arr, logical = _storage_forecast_array(windows)
        det = InfraStore.Deterministic(initial, resolution, horizon, storage_interval,
            length(windows), arr, name; ext = _encode_ext(logical))
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
    ) do initial, resolution, horizon, storage_interval, name
        arr = Float64.(get_array_for_hdf(ts))  # (scenario_count, horizon_count, count)
        scen = InfraStore.Scenarios(initial, resolution, horizon, storage_interval,
            get_count(ts), arr, name; ext = _encode_ext(nothing))
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
    "Deterministic, Probabilistic, and Scenarios in bulk adds (got $(typeof(ts)))",
)

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

"""Reconstruct a forecast from the InfraStore store (matches the STORED type),
honoring `start_time` / `count` slicing on the window axis. Pass `key` (a
previously resolved `ForecastKey`) to skip the catalog resolution query."""
function _infrastore_get_forecast(
    owner, name;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    key::Union{Nothing, ForecastKey} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, category = _infrastore_owner_args(owner)
    # Resolve the unique forecast matching a possibly-partial (subset) feature /
    # resolution / interval query, then read it by its exact stored attributes.
    # `interval` matters when one series name carries several forecasts that differ only
    # by interval (`transform_single_time_series!` with `delete_existing = false`);
    # without it the lookup is ambiguous.
    matched = if isnothing(key)
        infrastore_get_time_series_key(
            owner, Forecast, name;
            resolution = resolution, interval = interval, features...,
        )
    else
        key
    end
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(matched))
    resolution = get_resolution(matched)
    # Pin every store lookup below to the resolved forecast's exact (stored) interval.
    # One name can carry several forecasts differing only by interval, and the typed
    # lookups match on attributes, so without this they would match more than one.
    # A single-window forecast is presented with `interval == Second(0)` (e.g. on a
    # key returned by `add_time_series!`) but stored with `interval == horizon`;
    # map it back to the storage form for the lookups.
    matched_interval =
        _storage_forecast_interval(get_interval(matched), get_horizon(matched))
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
        matched_interval,
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
# windows carry trailing coefficient dims (3D). The stored `ext`/`logical` tag
# may be set even when the data is scalar (a DST inherits the metadata of the
# SingleTimeSeries it shares), so key the decode on the array rank instead.
_forecast_window(data::AbstractMatrix, logical, i) = data[:, i]
_forecast_window(data::AbstractArray{<:Any, 3}, logical, i) =
    _decode_forecast_window(data, logical, i)

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
    data = SortedDict{Dates.DateTime, Matrix{Float64}}()
    for i in 1:(p.count)
        data[p.initial_timestamp + p.interval * (i - 1)] =
            _truncate_window(permutedims(p.data[:, :, i]), len)
    end
    return Probabilistic(; name = name, data = data,
        percentiles = p.percentiles, resolution = p.resolution,
        interval = _forecast_display_interval(p.count, p.interval, p.horizon))
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
    logical = _decode_ext(d.ext)  # `nothing` for scalar windows
    window(i) = _truncate_window(_forecast_window(d.data, logical, i), len)
    data = _assemble_forecast_windows(d.initial_timestamp, d.interval, d.count, window)
    return Deterministic(; name = name, data = data,
        resolution = d.resolution,
        interval = _forecast_display_interval(d.count, d.interval, d.horizon))
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
    data = SortedDict{Dates.DateTime, Matrix{Float64}}()
    for i in 1:(s_ts.count)
        data[s_ts.initial_timestamp + s_ts.interval * (i - 1)] =
            _truncate_window(permutedims(s_ts.data[:, :, i]), len)
    end
    return Scenarios(; name = name, data = data,
        scenario_count = s_ts.scenario_count, resolution = s_ts.resolution,
        interval = _forecast_display_interval(s_ts.count, s_ts.interval, s_ts.horizon))
end

# ---- ForecastReader --------------------------------------------------------
# A timestamp-oriented reader over the forecasts matching a filter, for the
# simulation pattern "at each window timestamp, get every component's forecast".
# It wraps the InfraStore `ForecastReader`, which deduplicates the physical `.nc` read:
# components that share a forecast array (and read plan) collapse to one window
# slot, so the data is read once per timestamp no matter how many components
# reference it. This wrapper carries that dedup up to Julia — each unique slot's
# window is materialized (and FunctionData-decoded) at most once per read.

# Map an IS forecast type to the `InfraStore` reader type. A `Deterministic`
# (or the `AbstractDeterministic` abstraction) reader is abstract and also
# includes `DeterministicSingleTimeSeries`; a DST query is exact.
_tss_forecast_type(::Type{<:DeterministicSingleTimeSeries}) =
    InfraStore.DeterministicSingleTimeSeries
_tss_forecast_type(::Type{<:AbstractDeterministic}) = InfraStore.Deterministic
_tss_forecast_type(::Type{<:Probabilistic}) = InfraStore.Probabilistic
_tss_forecast_type(::Type{<:Scenarios}) = InfraStore.Scenarios

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
    error("InfraStore backend cannot decode forecast ext $ext")
end

# The `ext` tags that mean a window is FunctionData (stored as a
# `(horizon, k)` matrix). Any other tag (`nothing`, or a scalar dtype string like
# "Float64" carried by a SingleTimeSeries-backed DST) is a plain scalar window.
const _INFRASTORE_FUNCTIONDATA_LOGICAL =
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
    (ext in _INFRASTORE_FUNCTIONDATA_LOGICAL) || return raw
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
mutable struct ForecastReader{T <: Forecast}
    inner::InfraStore.ForecastReader
    store::Store
    entries::Vector{ForecastReaderEntry}
    "ext for each entry (parallel to `entries`); `nothing` for scalars."
    exts::Vector{Union{Nothing, String}}
    "Per-slot materialized window cache; reset on each read."
    windows::Vector{Any}
    has_read::Bool
end

# Build a reader from the store. `id_to_owner(owner_id::Int, category::String)`
# resolves each entry's owner object (the system holds the owner maps). Per-entry
# metadata (owner, key, ext) is resolved once here, off the read path.
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
    n = length(tss_entries)
    entries = Vector{ForecastReaderEntry}(undef, n)
    exts = Vector{Union{Nothing, String}}(undef, n)
    for (i, e) in enumerate(tss_entries)
        info = InfraStore.key_info(e.key)
        owner = id_to_owner(Int(info.owner_id), info.owner_category)
        is_type = _infrastore_is_type(info.time_series_type)
        feats = Dict{String, Any}(info.features)
        fmeta = InfraStore.get_metadata(info.time_series_type, store.inner, info.owner_id,
            info.owner_category, info.name;
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
        # `e.slot` is 0-based in the InfraStore store; carry it 1-based for Julia.
        entries[i] = ForecastReaderEntry(owner, key, e.slot + 1)
    end
    windows = Vector{Any}(nothing, InfraStore.forecast_num_slots(inner))
    return ForecastReader{T}(inner, store, entries, exts, windows, false)
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
    cached === nothing || return cached
    raw = InfraStore.forecast_values(reader.inner, entry_index)
    window = _decode_forecast_reader_window(T, raw, reader.exts[entry_index])
    reader.windows[entry.slot] = window
    return window
end

# ---- StaticTimeSeriesReader ------------------------------------------------
# The static counterpart of the ForecastReader, for the simulation pattern
# "at each timestamp, get every component's value". It wraps the InfraStore
# `StaticReader`, which packs the matching series into columnar
# `(dtype, element_shape)` groups so a whole group is served by one physical
# `.nc` read per timestamp. This wrapper carries that grouping up to Julia —
# each group's values are materialized at most once per read.

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

The matched series are packed into columnar groups; one physical `.nc` read per
group serves every entry in it at a timestamp — see
[`get_num_static_time_series_groups`](@ref).
"""
mutable struct StaticTimeSeriesReader
    inner::InfraStore.StaticReader
    store::Store
    entries::Vector{StaticTimeSeriesReaderEntry}
    "ext for each entry (parallel to `entries`); decode tag for FunctionData/tuple rows."
    exts::Vector{Union{Nothing, String}}
    "Per-group materialized values cache; reset on each read."
    values::Vector{Any}
    has_read::Bool
end

# Build a reader from the store. `id_to_owner(owner_id::Int, category)` resolves
# each entry's owner object (the system holds the owner maps). Per-entry metadata
# (owner, key, ext) is resolved once here, off the read path.
function infrastore_build_static_time_series_reader(
    store::Store,
    id_to_owner;
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features = Dict{String, Any}(),
)
    inner = InfraStore.build_static_reader(store.inner;
        resolution = resolution, name = name, features = features)
    entries = StaticTimeSeriesReaderEntry[]
    exts = Union{Nothing, String}[]
    groups = InfraStore.static_groups(inner)
    for (gi, group) in enumerate(groups)
        for (col, k) in enumerate(group.keys)
            info = InfraStore.key_info(k)
            owner = id_to_owner(Int(info.owner_id), info.owner_category)
            feats = Dict{String, Any}(info.features)
            smeta = InfraStore.get_metadata(InfraStore.SingleTimeSeries, store.inner,
                info.owner_id, info.owner_category, info.name;
                resolution = info.resolution, features = feats)
            key = StaticTimeSeriesKey(;
                time_series_type = SingleTimeSeries,
                name = info.name,
                initial_timestamp = smeta.initial_timestamp,
                resolution = smeta.resolution,
                length = smeta.length,
                features = feats,
            )
            push!(entries, StaticTimeSeriesReaderEntry(owner, key, gi, col))
            push!(exts, _decode_ext(smeta.ext))
        end
    end
    values = Vector{Any}(nothing, length(groups))
    return StaticTimeSeriesReader(inner, store, entries, exts, values, false)
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
The number of columnar groups — the count of physical `.nc` reads
[`read_static_time_series_values!`](@ref) performs per timestamp. Series with
the same element type collapse into one group, so this is
`≤ length(get_static_time_series_reader_entries(reader))` (typically 1).
"""
get_num_static_time_series_groups(reader::StaticTimeSeriesReader) =
    length(reader.values)

Base.length(reader::StaticTimeSeriesReader) = length(reader.entries)

"""
$(TYPEDSIGNATURES)
Read the value of every entry at `timestamp`, performing one `.nc` read per
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
    if vals === nothing
        vals = InfraStore.static_values(reader.inner, entry.group)
        reader.values[entry.group] = vals
    end
    # A vector group is scalar data (one value per column); a higher-rank group
    # carries one encoded element row per column, decoded through the ext tag
    # (same scheme as `_decode_static_values`).
    vals isa AbstractVector && return vals[entry.column]
    colons = ntuple(_ -> Colon(), ndims(vals) - 1)
    element = vals[entry.column, colons...]
    ext = reader.exts[entry_index]
    isnothing(ext) && return element
    return _decode_static_values(reshape(element, 1, :), ext, 1)[1]
end

"""Route `has_time_series(owner, T, name; ...)` to the InfraStore store. Honors partial
(subset) feature / resolution queries: matches if any stored series of type `T`
contains at least the requested features."""
function infrastore_has_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, category = _infrastore_owner_args(owner)
    feats = _infrastore_features(features)
    # Pure existence probe — a covering-index `SELECT 1 ... LIMIT 1` in the
    # store; nothing is listed, hydrated, or marshaled, so this is safe in hot
    # per-component loops. A query type that is not one stored type (an
    # abstract family, or `Deterministic`, which also matches a stored DST)
    # expands to one probe per candidate; the empty tuple means every type
    # matches, i.e. one unfiltered probe.
    probe =
        t -> InfraStore.has_any_time_series(store.inner;
            owner_id = owner_id, owner_category = category,
            time_series_type = t, name = name, resolution = resolution,
            interval = interval, features = feats)
    types = _infrastore_query_types(T)
    isempty(types) && return probe(nothing)
    return any(probe, types)
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

# All InfraStore types whose IS type is a subtype of `T` (strict `<:` semantics —
# distinct from `_infrastore_type_matches`, which treats a `Deterministic` query
# as also matching a `DeterministicSingleTimeSeries`). Used by the store-wide
# filters (`resolutions`, `list_owner_ids`) that key on subtyping.
_infrastore_subtype_types(::Type{T}) where {T <: TimeSeriesData} =
    Tuple(c for (c, k) in _INFRASTORE_TYPE_PAIRS if k <: T)

# Name-less existence queries: the stored InfraStore types a query for `T` should
# match, under the same `Deterministic`-matches-DST semantics as
# `_infrastore_type_matches`. A match on every type is returned as the empty
# tuple, the caller's signal to issue one unfiltered query instead of six.
function _infrastore_query_types(::Type{T}) where {T <: TimeSeriesData}
    types = Tuple(c for (c, k) in _INFRASTORE_TYPE_PAIRS if _infrastore_type_matches(k, T))
    return length(types) == length(_INFRASTORE_TYPE_PAIRS) ? () : types
end

# The single InfraStore type to push into the core `list_keys` filter for a query
# type, or `nothing` when the type cannot be expressed as one stored type: an
# abstract family, or `Deterministic` (which also matches a stored
# `DeterministicSingleTimeSeries`). When `nothing`, the caller applies the
# residual `_infrastore_type_matches` filter on the (already narrowed) rows.
function _infrastore_pushable_type(::Type{T}) where {T <: TimeSeriesData}
    types = _infrastore_query_types(T)
    return length(types) == 1 ? only(types) : nothing
end

# True iff `owner` has any time series, optionally restricted to type `T`.
function infrastore_has_any(owner; time_series_type::Union{Nothing, Type} = nothing)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
    owner_id, _, category = _infrastore_owner_args(owner)
    types =
        time_series_type === nothing ? () : _infrastore_query_types(time_series_type)
    isempty(types) && return InfraStore.has_for_owner(store.inner, owner_id, category)
    return any(
        t ->
            InfraStore.has_for_owner(store.inner, owner_id, category; time_series_type = t),
        types,
    )
end

# ---- Metadata reconstruction (parity with the SQLite metadata store) --------
# IS time series type for a `InfraStore` metadata-row type (matched by name) —
# the inverse of `_infrastore_type`, over the same table.
const _INFRASTORE_IS_TYPES =
    Dict(nameof(c) => k for (c, k) in _INFRASTORE_TYPE_PAIRS)
_infrastore_is_type(t::Type) = _infrastore_is_type(nameof(t))
_infrastore_is_type(s::Symbol) =
    get(_INFRASTORE_IS_TYPES, s) do
        error("InfraStore backend does not support time series type $s")
    end

# Whether a stored row of concrete type `row_type` satisfies a query for type `T`.
# Mirrors the metadata-store semantics: a `Deterministic` (or `AbstractDeterministic`)
# query also matches a `DeterministicSingleTimeSeries` (which reads as a
# `Deterministic`), while a `DeterministicSingleTimeSeries` query matches DST only.
_infrastore_type_matches(row_type::Type, ::Type{T}) where {T <: TimeSeriesData} =
    if T <: DeterministicSingleTimeSeries
        row_type <: DeterministicSingleTimeSeries
    elseif T <: AbstractDeterministic
        row_type <: AbstractDeterministic
    else
        row_type <: T
    end

# Build the matching IS `TimeSeriesKey` from a `InfraStore.list_keys` row. The key is
# the single descriptor for a stored association; forecast-only fields
# (percentiles, scenario_count) are not carried — they come from the data on read.
function _key_from_row(row)
    feats = Dict{String, Any}(string(k) => v for (k, v) in row.features)
    is_type = _infrastore_is_type(row.time_series_type)
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
    error("InfraStore backend cannot build a key for $(row.time_series_type)")
end

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
    type_filter =
        isnothing(time_series_type) ? nothing : _infrastore_pushable_type(time_series_type)
    feats = Dict{String, Any}(string(k) => v for (k, v) in features)
    rows =
        InfraStore.list_keys(store.inner; owner_id = owner_id,
            owner_category = owner_category, time_series_type = type_filter,
            name = name, resolution = resolution, interval = interval,
            features = feats)
    out = TimeSeriesKey[]
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

# A key for every time series in the store (all owners).
_infrastore_all_metadata(store::Store) =
    [_key_from_row(row) for row in InfraStore.list_keys(store.inner)]

# Owner-level `list_metadata` entry point (mirrors the metadata-store signature).
function infrastore_owner_list_keys(
    owner::TimeSeriesOwners;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::Store
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
# wrapper's 32-byte hash) of the array `key` resolves to under `owner`. Narrows
# the catalog to the owner + the key's type/name in one query, then matches the
# exact resolution + features in-memory.
function infrastore_get_time_series_hash(owner::TimeSeriesOwners, key::TimeSeriesKey)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) &&
        throw(InfraStore.NotFoundError("owner has no time series to hash"))
    store = mgr.data_store::Store
    owner_id, _, category = _infrastore_owner_args(owner)
    T = get_time_series_type(key)
    rows = InfraStore.list_array_groups(store.inner; owner_id = owner_id,
        owner_category = category,
        time_series_type = _infrastore_pushable_type(T), name = get_name(key))
    target_res = get_resolution(key)
    target_feats = get_features(key)
    for row in rows
        _infrastore_type_matches(_infrastore_is_type(row.time_series_type), T) || continue
        row.resolution == target_res || continue
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
    store = mgr.data_store::Store
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
            # Each key is already fully resolved, so read key-addressed — no
            # catalog re-resolution per series.
            ts = if m isa ForecastKey
                _infrastore_get_forecast(owner, get_name(m); key = m)
            elseif m isa NonSequentialTimeSeriesKey
                _infrastore_read_non_sequential(owner, m)
            else
                _infrastore_read_single(owner, m)
            end
            (isnothing(filter_func) || filter_func(ts)) && put!(channel, ts)
        end
    end
end

# ---- Store-wide aggregates (parity with the SQLite metadata store) ----------

# Distinct, sorted resolutions across the store, optionally restricted to a type
# (strict subtype). One DISTINCT query per concrete subtype code, in the core.
function infrastore_get_time_series_resolutions(
    store::Store;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
)
    isnothing(time_series_type) && return sort!(InfraStore.get_resolutions(store.inner))
    res = Set{Dates.Millisecond}()
    for t in _infrastore_subtype_types(time_series_type)
        union!(res, InfraStore.get_resolutions(store.inner; time_series_type = t))
    end
    return sort!(collect(res))
end

# Counts of time series grouped by type name (parity with counts_by_type).
function infrastore_get_time_series_counts_by_type(store::Store)
    counts = OrderedDict{String, Int}()
    for r in InfraStore.counts_by_type(store.inner)
        counts[string(nameof(r.time_series_type))] = r.count
    end
    return [OrderedDict("type" => k, "count" => v) for (k, v) in sort!(OrderedDict(counts))]
end

# Static-time-series summary DataFrame (parity with the metadata-store version).
# The core groups the rows; we shape them into the DataFrame.
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

# Forecast summary DataFrame (parity with the metadata-store version).
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

# First forecast's parameters, optionally filtered by resolution/interval. The
# store keeps a single forecast window configuration, mirroring the legacy
# `get_forecast_parameters`.
function infrastore_forecast_parameters(
    store::Store;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    # The first forecast key matching `resolution`/`interval`, compared with
    # `Period` equality. The store preserves the calendar-aware `Period` type, so
    # the stored periods are passed through unchanged — converting them to
    # `Millisecond` would throw for irregular `Month`/`Year` resolutions.
    for row in InfraStore.list_keys(store.inner)
        _infrastore_is_type(row.time_series_type) <: Forecast || continue
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
    ids = Set{Int}()
    for row in
        InfraStore.list_keys(store.inner; owner_category = category,
        resolution = resolution)
        if !isnothing(time_series_type)
            _infrastore_is_type(row.time_series_type) <: time_series_type || continue
        end
        push!(ids, Int(row.owner_id))
    end
    return collect(ids)
end

# (owner_id, key) for every time series of the given owner category, optionally
# restricted by time series type (strict subtype) and resolution. Owner category
# and resolution are pushed into the core query; the strict type filter is applied
# on the returned keys.
function infrastore_list_keys_with_owner(
    store::Store,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = get_owner_category(owner_type)
    rows = InfraStore.list_keys(store.inner; owner_category = category,
        resolution = resolution)
    out = NamedTuple[]
    for row in rows
        if !isnothing(time_series_type)
            _infrastore_is_type(row.time_series_type) <: time_series_type || continue
        end
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
