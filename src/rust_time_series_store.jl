# Rust-backed time series storage.
#
# `RustTimeSeriesStore` delegates BOTH array data and metadata to the external
# `time-series-store` Rust engine, via the `TimeSeriesStore.jl` binding package.
# The Rust store owns both: arrays land in a NetCDF4 `.nc` file (content-addressed
# by SHA-256 hash) and metadata in a sibling `.sqlite` file. Time series *data*
# identity is the array content hash, not a UUID. Persisting a system writes the
# `.nc` + `.sqlite` pair directly.
#
# This file holds the IS-specific glue (owner/feature conversion, window
# flatten/reshape, manager routing). All low-level FFI lives in `TimeSeriesStore`.

const TSS = TimeSeriesStore

# Not-found is raised by the binding; alias keeps the IS-facing name + tests stable.
const RustTimeSeriesNotFound = TimeSeriesStore.NotFoundError

# ---- Store -----------------------------------------------------------------

mutable struct RustTimeSeriesStore <: TimeSeriesStorage
    inner::TSS.Store
    "Filesystem base path for the `.nc` / `.sqlite` pair (nothing if in-memory)."
    path::Union{Nothing, String}
    "Compression policy the store was created/opened with."
    compression::CompressionSettings
end

"""
    RustTimeSeriesStore(; in_memory=false, path=nothing, compression=CompressionSettings())

Create a Rust-backed time series store. When `in_memory=false`, `path` is the
base path for the on-disk artifacts (`<path>.nc` and `<path>.sqlite`).

`compression` is a [`CompressionSettings`](@ref). The Rust backend supports
`DEFLATE` (with `level` 0-9 and `shuffle`) or no compression (`enabled=false`);
`BLOSC` is not available and raises an error.
"""
function RustTimeSeriesStore(;
    in_memory::Bool = false,
    path = nothing,
    compression::CompressionSettings = CompressionSettings(),
)
    kwargs = _rust_compression_kwargs(compression)
    store = if in_memory
        TSS.Store(; in_memory = true, kwargs...)
    else
        TSS.Store(; in_memory = false, path = path, kwargs...)
    end
    return RustTimeSeriesStore(
        store,
        path === nothing ? nothing : String(path),
        compression,
    )
end

# Translate a `CompressionSettings` into the keyword arguments accepted by
# `TimeSeriesStore.Store`. BLOSC is not supported by the Rust backend.
function _rust_compression_kwargs(c::CompressionSettings)
    if !c.enabled
        return (; compression = :none)
    end
    if c.type == CompressionTypes.DEFLATE
        return (; compression = :deflate, compression_level = c.level, shuffle = c.shuffle)
    end
    error(
        "The Rust time-series-store backend does not support $(c.type) compression; " *
        "use CompressionTypes.DEFLATE or disable compression (enabled=false).",
    )
end

"""
    open_rust_store(path; read_only=false)

Open an existing on-disk Rust store from its `.nc` base path.
"""
function open_rust_store(path::AbstractString; read_only::Bool = false)
    inner = TSS.open_store(String(path); read_only = read_only)
    # Store an absolute path so the handle survives later `cd`s (e.g. a
    # deserialize that opens a relative basename, then a re-serialize elsewhere).
    return RustTimeSeriesStore(
        inner,
        abspath(String(path)),
        _compression_settings(TSS.get_compression(inner)),
    )
end

# Translate the `TimeSeriesStore.get_compression` NamedTuple back into a
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

close!(store::RustTimeSeriesStore) = TSS.close!(store.inner)

# ---- Conversions -----------------------------------------------------------

_tss_category(category::String) =
    if category == "Component"
        TSS.Component
    elseif category == "SupplementalAttribute"
        TSS.SupplementalAttribute
    else
        error("unknown owner category $category")
    end

# Owner-category tag stored alongside each association ("Component" /
# "SupplementalAttribute"). Accepts an owner instance or its type.
_get_owner_category(
    ::Union{InfrastructureSystemsComponent, Type{<:InfrastructureSystemsComponent}},
) = "Component"
_get_owner_category(
    ::Union{SupplementalAttribute, Type{<:SupplementalAttribute}},
) = "SupplementalAttribute"

# ---- Element encoding ------------------------------------------------------
# Scalars store as a 1-D array tagged with their type name. Fixed-size
# FunctionData tuples store as a `(length, k)` Float64 array; reconstruction keys
# on the `logical_type` tag returned by `get_metadata`.

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

_storage_array(v::AbstractVector) =
    error("Rust backend does not support time series element type $(eltype(v)) yet")

# Reconstruct the full value vector from the stored array, keyed on logical_type.
function _read_values(
    store::RustTimeSeriesStore,
    hash::Vector{UInt8},
    logical_type,
    dtype,
    len::Integer,
)
    if logical_type == "LinearFunctionData"
        mat = TSS.get_array_nd(store.inner, hash, Float64, (len, 2))
        return [LinearFunctionData(mat[i, 1], mat[i, 2]) for i in 1:len]
    elseif logical_type == "QuadraticFunctionData"
        mat = TSS.get_array_nd(store.inner, hash, Float64, (len, 3))
        return [QuadraticFunctionData(mat[i, 1], mat[i, 2], mat[i, 3]) for i in 1:len]
    elseif logical_type == "PiecewiseLinearData"
        flat = get_array_by_hash(store, hash, Float64)
        k = div(length(flat), len)  # 1 + 2*max_points (derived from the array size)
        mat = TSS.get_array_nd(store.inner, hash, Float64, (len, k))
        out = Vector{PiecewiseLinearData}(undef, len)
        for i in 1:len
            n = Int(round(mat[i, 1]))
            out[i] = PiecewiseLinearData([(mat[i, 2j], mat[i, 2j + 1]) for j in 1:n])
        end
        return out
    else
        return get_array_by_hash(store, hash, dtype)  # scalar
    end
end

# Decode an already-materialized static value array (the inverse of `_storage_array`),
# keyed on `logical_type`. Used by the non-sequential read path, where the backend
# returns the `(len, k)` FunctionData matrix (or scalar vector) in memory rather than
# by content hash. `len` is the timestep count (`size(arr, 1)`).
function _decode_static_values(arr, logical_type, len::Integer)
    if logical_type == "LinearFunctionData"
        return [LinearFunctionData(arr[i, 1], arr[i, 2]) for i in 1:len]
    elseif logical_type == "QuadraticFunctionData"
        return [QuadraticFunctionData(arr[i, 1], arr[i, 2], arr[i, 3]) for i in 1:len]
    elseif logical_type == "PiecewiseLinearData"
        out = Vector{PiecewiseLinearData}(undef, len)
        for i in 1:len
            n = Int(round(arr[i, 1]))
            out[i] = PiecewiseLinearData([(arr[i, 2j], arr[i, 2j + 1]) for j in 1:n])
        end
        return out
    else
        return arr  # scalar (1-D vector, or an N-D per-step array)
    end
end

# ---- Forecast element encoding ---------------------------------------------
# Forecast windows of scalars store as a `(horizon, count)` array (logical_type
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
# with `logical_type` into a Vector of the corresponding FunctionData.
function _decode_forecast_window(arr::AbstractArray{<:Real, 3}, logical_type, c::Integer)
    horizon = size(arr, 1)
    if logical_type == "LinearFunctionData"
        return [LinearFunctionData(arr[h, c, 1], arr[h, c, 2]) for h in 1:horizon]
    elseif logical_type == "QuadraticFunctionData"
        return [
            QuadraticFunctionData(arr[h, c, 1], arr[h, c, 2], arr[h, c, 3]) for
            h in 1:horizon
        ]
    elseif logical_type == "PiecewiseLinearData"
        out = Vector{PiecewiseLinearData}(undef, horizon)
        for h in 1:horizon
            n = Int(round(arr[h, c, 1]))
            out[h] = PiecewiseLinearData([(arr[h, c, 2j], arr[h, c, 2j + 1]) for j in 1:n])
        end
        return out
    end
    error("Rust backend cannot decode forecast logical_type $logical_type")
end

# ---- Operations (thin delegations to TimeSeriesStore) ----------------------

"""
    serialize_single!(store, owner_id, owner_type, owner_category, name, sts;
                      features=Dict(), units=nothing)

Add a `SingleTimeSeries` (data + metadata) to the Rust store. The array is
content-addressed; identical arrays are de-duplicated automatically.
`owner_category` is the String tag ("Component" / "SupplementalAttribute").
"""
function serialize_single!(
    store::RustTimeSeriesStore,
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
    tss_ts = TSS.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        arr,
        name;
        logical_type = logical,
    )
    TSS.add_time_series!(store.inner, owner_id, owner_type, _tss_category(owner_category),
        tss_ts; features = features, units = units)
    return
end

"""
    get_metadata(store, owner_id, owner_category, name; resolution, features=Dict())

Return `(; initial_timestamp, resolution, length, data_hash, logical_type, dtype)`
for a stored SingleTimeSeries. Throws `RustTimeSeriesNotFound` if absent.
"""
get_metadata(store::RustTimeSeriesStore, owner_id::Integer,
    owner_category::TSS.OwnerCategory, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    TSS.get_metadata(
        store.inner,
        owner_id,
        owner_category,
        name;
        resolution = resolution,
        features = features,
    )

get_array_by_hash(
    store::RustTimeSeriesStore,
    data_hash::Vector{UInt8},
    ::Type{T} = Float64,
) where {T} =
    TSS.get_array_by_hash(store.inner, data_hash, T)

"""
    serialize_non_sequential!(store, owner_id, owner_type, owner_category, name, nts;
                              features=Dict(), units=nothing)

Add a `NonSequentialTimeSeries` (irregular timestamps + data) to the Rust store.
The array is content-addressed (and de-duplicated); the explicit timestamps are
carried on the association. `owner_category` is the String tag ("Component" /
"SupplementalAttribute").
"""
function serialize_non_sequential!(
    store::RustTimeSeriesStore,
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
    tss_ts = TSS.NonSequentialTimeSeries(
        get_timestamps(nts),
        arr,
        name;
        logical_type = logical,
    )
    TSS.add_time_series!(store.inner, owner_id, owner_type, _tss_category(owner_category),
        tss_ts; features = features, units = units)
    return
end

"""
    get_non_sequential(store, owner_id, owner_category, name; features=Dict()) -> NonSequentialTimeSeries

Reconstruct a `NonSequentialTimeSeries` (timestamps + decoded array) from the Rust
store. A non-sequential series is addressed by name + features (it has no resolution).
"""
function get_non_sequential(
    store::RustTimeSeriesStore,
    owner_id::Integer,
    owner_category::TSS.OwnerCategory,
    name::AbstractString;
    features = Dict{String, Any}(),
)
    nts = TSS.get_time_series(TSS.NonSequentialTimeSeries, store.inner, owner_id,
        owner_category, name; features = features)
    len = length(nts.timestamps)
    values = _decode_static_values(nts.data, nts.logical_type, len)
    return NonSequentialTimeSeries(String(name), nts.timestamps, values)
end

has_time_series(store::RustTimeSeriesStore, owner_id::Integer,
    owner_category::TSS.OwnerCategory, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    TSS.has_time_series(
        store.inner,
        owner_id,
        owner_category,
        name;
        resolution = resolution,
        features = features,
    )

remove_single!(store::RustTimeSeriesStore, owner_id::Integer,
    owner_category::TSS.OwnerCategory, name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing, features = Dict{String, Any}()) =
    TSS.remove_time_series!(store.inner, owner_id, owner_category, name;
        resolution = resolution, features = features)

get_counts(store::RustTimeSeriesStore) = TSS.get_counts(store.inner)

function get_num_time_series(store::RustTimeSeriesStore)
    c = get_counts(store)
    return c.static_time_series + c.forecasts
end

flush!(store::RustTimeSeriesStore) = TSS.flush!(store.inner)

Base.isempty(store::RustTimeSeriesStore) = get_num_time_series(store) == 0

# Compression is fixed when the store is created/opened (threaded through the FFI
# via `_rust_compression_kwargs`); report the policy the store carries.
get_compression_settings(store::RustTimeSeriesStore) = store.compression

"""
    serialize(store::RustTimeSeriesStore, file_path)

Persist the store's two artifacts to `file_path` (the NetCDF arrays) and
`file_path * ".sqlite"` (the metadata). No HDF5 is produced.
"""
function serialize(store::RustTimeSeriesStore, file_path::AbstractString)
    isnothing(store.path) && error(
        "cannot serialize an in-memory RustTimeSeriesStore; create the System " *
        "with time_series_in_memory=false")
    flush!(store)
    cp(store.path, file_path; force = true)
    cp(store.path * ".sqlite", file_path * ".sqlite"; force = true)
    @info "Serialized Rust time series store to $file_path (+ .sqlite)"
    return
end

"""Remove all time series (data + metadata) from the store."""
clear_time_series!(store::RustTimeSeriesStore) = TSS.clear!(store.inner)

# Remove every time series owned by `(owner_id, owner_category)` in one shot
# (order-independent, so it is not blocked by the SingleTimeSeries/DST removal guard).
_rust_clear_owner!(store::RustTimeSeriesStore, owner_id::Integer,
    owner_category::TSS.OwnerCategory) =
    TSS.clear!(store.inner; owner_id = owner_id, owner_category = owner_category)

# A hashable identity for one stored association (a `TSS.list_keys` row),
# used to diff the store before/after a batch update for rollback.
_rust_row_identity(row) = (
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
# Resolved by a single catalog query in the Rust core rather than scanning every
# association here.
_rust_array_sts_dst_counts(store::RustTimeSeriesStore, hash::Vector{UInt8}) =
    TSS.count_array_references(store.inner, hash)

# Remove the single association described by a `TSS.list_keys` row.
function _rust_remove_row!(store::RustTimeSeriesStore, row)
    feats = Dict{String, Any}(row.features)
    category = _tss_category(row.owner_category)
    if _rust_is_type(row.time_series_type) <: SingleTimeSeries
        remove_single!(store, row.owner_id, category, row.name;
            resolution = row.resolution, features = feats)
    else
        remove_typed!(store, row.owner_id, category, row.name,
            _rust_ts_code(_rust_is_type(row.time_series_type));
            resolution = row.resolution, features = feats)
    end
    return
end

# The store handle / file path differ across a serialize→deserialize round-trip,
# so compare structurally by counts. Element-level equality is covered by the
# Rust integration tests (`test/rust/rust_system_integration.jl`).
function compare_values(
    match_fn::Union{Function, Nothing},
    x::RustTimeSeriesStore,
    y::RustTimeSeriesStore;
    kwargs...,
)
    return get_counts(x) == get_counts(y)
end

# ---- TimeSeriesManager routing ---------------------------------------------

# Validate the raw time series array before storing. A DeterministicSingleTimeSeries
# is a derived view over an already-validated SingleTimeSeries (it has no raw
# `get_data`), so it skips the check.
_rust_check_time_series_data(time_series::TimeSeriesData) =
    check_time_series_data(time_series)
_rust_check_time_series_data(::DeterministicSingleTimeSeries) = nothing

"""
Route a manager-level `add_time_series!` to the Rust store, dispatching on the
concrete time series type. Data identity is the array content hash (no
`time_series_uuid`).
"""
function _rust_add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    throw_if_does_not_support_time_series(owner)
    _rust_check_time_series_data(time_series)
    return _rust_add!(mgr, owner, time_series; features...)
end

# Dispatch on the concrete series type. Forecasts (including
# DeterministicSingleTimeSeries) and NonSequentialTimeSeries route to their
# dedicated handlers; SingleTimeSeries is stored below; anything else is
# unsupported on the Rust backend.
_rust_add!(mgr::TimeSeriesManager, owner::TimeSeriesOwners, ts::Forecast; features...) =
    _rust_add_forecast!(mgr, owner, ts; features...)

_rust_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    ts::NonSequentialTimeSeries;
    features...,
) = _rust_add_non_sequential!(mgr, owner, ts; features...)

_rust_add!(::TimeSeriesManager, ::TimeSeriesOwners, ts::TimeSeriesData; features...) =
    error(
        "Rust backend supports SingleTimeSeries, NonSequentialTimeSeries, " *
        "Deterministic, DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
        "(got $(typeof(ts)))",
    )

function _rust_add!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::SingleTimeSeries;
    features...,
)
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, owner_type, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    name = get_name(time_series)
    resolution = get_resolution(time_series)
    feats = _rust_features(features)

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
Route a manager-level `add_time_series!` of a `NonSequentialTimeSeries` to the Rust
store. Addressed by name + features (a non-sequential series has no resolution);
data identity is the array content hash.
"""
function _rust_add_non_sequential!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::NonSequentialTimeSeries;
    features...,
)
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, owner_type, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    name = get_name(time_series)
    feats = _rust_features(features)

    if has_typed(store, owner_id, category, name, TSS.TS_TYPE_NON_SEQUENTIAL;
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
# unsupported on the Rust backend.
_rust_get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    kwargs...,
) where {T <: TimeSeriesData} =
    error(
        "Rust backend supports SingleTimeSeries, Deterministic, " *
        "DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
        "(requested $T)",
    )

# Forecasts reconstruct from the stored forecast type, honoring `start_time` /
# `count` slicing on the forecast window axis. `len`, when given, truncates each
# window to its first `len` horizon steps. A forecast stored as a
# DeterministicSingleTimeSeries is materialized into a regular `Deterministic`.
_rust_get_time_series(
    ::Type{<:Forecast},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
) = _rust_get_forecast(owner, name;
    start_time = start_time, len = len, count = count, resolution = resolution,
    features...)

"""
Route a public `get_time_series(SingleTimeSeries, owner, name; ...)` to the Rust
store, honoring `start_time` / `len` slicing on the time axis.
"""
function _rust_get_time_series(
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
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, _, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    # Resolve the unique series matching a possibly-partial (subset) feature /
    # resolution query, then read it by its exact stored attributes.
    matched = _rust_get_metadata(
        owner,
        SingleTimeSeries,
        name;
        resolution = resolution,
        features...,
    )
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(matched))
    meta = get_metadata(store, owner_id, category, name;
        resolution = get_resolution(matched), features = feats)
    full = _read_values(store, meta.data_hash, meta.logical_type, meta.dtype, meta.length)

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
Rust store, honoring `start_time` / `len` slicing on the (irregular) time axis.
"""
function _rust_get_time_series(
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
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, _, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    # Resolve the unique series matching a possibly-partial (subset) feature query,
    # then read it by its exact stored attributes.
    matched = _rust_get_metadata(owner, NonSequentialTimeSeries, name; features...)
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

has_typed(store::RustTimeSeriesStore, owner_id::Integer,
    owner_category::TSS.OwnerCategory, name::AbstractString,
    ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    TSS.has_typed(store.inner, owner_id, owner_category, name, ts_type;
        resolution = resolution, features = features)

remove_typed!(store::RustTimeSeriesStore, owner_id::Integer,
    owner_category::TSS.OwnerCategory, name::AbstractString,
    ts_type::Integer; resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}()) =
    TSS.remove_typed!(store.inner, owner_id, owner_category, name, ts_type;
        resolution = resolution, features = features)

"""Add a Deterministic or DeterministicSingleTimeSeries via the Rust store."""
function _rust_add_forecast!(mgr::TimeSeriesManager, owner, ts; features...)
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, owner_type, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    name = get_name(ts)
    resolution = get_resolution(ts)
    interval = get_interval(ts)
    feats = _rust_features(features)

    # All forecasts that share a (resolution, interval) group must agree on the
    # window parameters (count, horizon, initial timestamp).
    check_params_compatibility(
        _rust_forecast_parameters(store; resolution = resolution, interval = interval),
        make_time_series_parameters(ts),
    )

    if ts isa Probabilistic
        if has_typed(store, owner_id, category, name, TSS.TS_TYPE_PROBABILISTIC;
            resolution = resolution, features = feats)
            throw(
                ArgumentError(
                    "Time series data with duplicate attributes are already stored",
                ),
            )
        end
        arr = Float64.(get_array_for_hdf(ts))  # (percentile_count, horizon_count, count)
        prob = TSS.Probabilistic(get_initial_timestamp(ts), resolution, get_horizon(ts),
            interval, get_count(ts), Float64.(get_percentiles(ts)), arr, name)
        TSS.add_time_series!(store.inner, owner_id, owner_type,
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
        ts_type = TSS.TS_TYPE_DETERMINISTIC
    elseif ts isa DeterministicSingleTimeSeries
        if has_typed(store, owner_id, category, name, TSS.TS_TYPE_DETERMINISTIC_SINGLE;
            resolution = resolution, features = feats)
            throw(
                ArgumentError(
                    "Time series data with duplicate attributes are already stored",
                ),
            )
        end
        # The Rust store derives a DeterministicSingleTimeSeries from a stored
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
        TSS.transform_single_time_series!(store.inner, get_horizon(ts), interval;
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
        ts_type = TSS.TS_TYPE_SCENARIOS
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
    tss_ts = if ts_type == TSS.TS_TYPE_DETERMINISTIC
        TSS.Deterministic(get_initial_timestamp(ts), resolution, get_horizon(ts),
            interval, count, arr, name; logical_type = logical)
    else
        TSS.Scenarios(get_initial_timestamp(ts), resolution, get_horizon(ts),
            interval, count, arr, name; logical_type = logical)
    end
    TSS.add_time_series!(store.inner, owner_id, owner_type,
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

    start_ts = initial_timestamp + interval * (start_idx - 1)
    end_ts = initial_timestamp + interval * (start_idx - 1 + n)  # exclusive
    return (start_ts, end_ts)
end

"""Reconstruct a forecast from the Rust store (matches the STORED type),
honoring `start_time` / `count` slicing on the window axis."""
function _rust_get_forecast(
    owner, name;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, _, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    # Resolve the unique forecast matching a possibly-partial (subset) feature /
    # resolution query, then read it by its exact stored attributes.
    matched =
        _rust_get_metadata(owner, Forecast, name; resolution = resolution, features...)
    feats = Dict{String, Any}(string(k) => v for (k, v) in get_features(matched))
    resolution = get_resolution(matched)
    # `len`, when given, truncates each window to its first `len` horizon steps
    # (the horizon is the leading axis of a window vector or matrix).
    _truncate(w) = isnothing(len) ? w : (ndims(w) == 1 ? w[1:len] : w[1:len, :])

    if has_typed(store, owner_id, category, name, TSS.TS_TYPE_PROBABILISTIC;
        resolution = resolution, features = feats)
        # `.data` is the canonical (percentile_count, horizon_count, count) array.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        p = TSS.get_time_series(TSS.Probabilistic, store.inner, owner_id, category, name;
            resolution = resolution, features = feats, time_range = tr)
        # `p` is already sliced to the requested window range by the store.
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(p.count)
            data[p.initial_timestamp + p.interval * (i - 1)] =
                _truncate(permutedims(p.data[:, :, i]))
        end
        result = Probabilistic(; name = String(name), data = data,
            percentiles = p.percentiles, resolution = p.resolution,
            interval = p.interval)
        return result
    elseif has_typed(store, owner_id, category, name, TSS.TS_TYPE_DETERMINISTIC;
        resolution = resolution, features = feats)
        # `.data` is the canonical (horizon_count, count) array.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        d = TSS.get_time_series(TSS.Deterministic, store.inner, owner_id, category, name;
            resolution = resolution, features = feats, time_range = tr)
        fmeta = TSS.get_forecast_metadata(store.inner, owner_id, category, name,
            TSS.TS_TYPE_DETERMINISTIC; resolution = resolution, features = feats)
        logical = fmeta.logical_type  # `nothing` for scalar windows
        window(i) = _truncate(
            if isnothing(logical)
                d.data[:, i]
            else
                _decode_forecast_window(d.data, logical, i)
            end,
        )
        # `d` is already sliced to the requested window range by the store.
        data = SortedDict(
            d.initial_timestamp + d.interval * (i - 1) => window(i)
            for i in 1:(d.count)
        )
        result = Deterministic(; name = String(name), data = data,
            resolution = d.resolution, interval = d.interval)
        return result
    elseif has_typed(store, owner_id, category, name, TSS.TS_TYPE_DETERMINISTIC_SINGLE;
        resolution = resolution, features = feats)
        # A DeterministicSingleTimeSeries is an internal storage optimization: it
        # shares the underlying SingleTimeSeries array instead of materializing the
        # overlapping windows. On read it is always returned as a regular
        # `Deterministic` — the Rust store expands the shared array into the
        # canonical (horizon_count, count) window matrix (honoring `time_range`),
        # so the reconstruction below is identical to the `Deterministic` branch.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        d = TSS.get_time_series(TSS.DeterministicSingleTimeSeries, store.inner, owner_id,
            category, name;
            resolution = resolution, features = feats, time_range = tr)
        fmeta = TSS.get_forecast_metadata(store.inner, owner_id, category, name,
            TSS.TS_TYPE_DETERMINISTIC_SINGLE; resolution = resolution, features = feats,
        )
        logical = fmeta.logical_type
        # Scalar windows come back as a 2D `(horizon_count, count)` array; encoded
        # FunctionData windows carry trailing coefficient dims (3D). A DST inherits
        # the shared SingleTimeSeries metadata, whose `logical_type` may be set even
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
        result_interval =
            (d.count == 1 && d.interval == d.horizon) ? Dates.Second(0) : d.interval
        # `d` is already sliced to the requested window range by the store.
        data = SortedDict(
            d.initial_timestamp + d.interval * (i - 1) => dst_window(i)
            for i in 1:(d.count)
        )
        return Deterministic(; name = String(name), data = data,
            resolution = d.resolution, interval = result_interval)
    elseif has_typed(store, owner_id, category, name, TSS.TS_TYPE_SCENARIOS;
        resolution = resolution, features = feats)
        # `.data` is the canonical (scenario_count, horizon_count, count) array.
        tr = _forecast_time_range(get_initial_timestamp(matched), get_interval(matched),
            get_count(matched), start_time, count)
        s_ts = TSS.get_time_series(TSS.Scenarios, store.inner, owner_id, category, name;
            resolution = resolution, features = feats, time_range = tr)
        # `s_ts` is already sliced to the requested window range by the store.
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in 1:(s_ts.count)
            data[s_ts.initial_timestamp + s_ts.interval * (i - 1)] =
                _truncate(permutedims(s_ts.data[:, :, i]))
        end
        result = Scenarios(; name = String(name), data = data,
            scenario_count = s_ts.scenario_count,
            resolution = s_ts.resolution, interval = s_ts.interval)
        return result
    end
    throw(RustTimeSeriesNotFound("no forecast for owner=$owner_id name=$name"))
end

# ---- ForecastReader --------------------------------------------------------
# A timestamp-oriented reader over the forecasts matching a filter, for the
# simulation pattern "at each window timestamp, get every component's forecast".
# It wraps the Rust `ForecastReader`, which deduplicates the physical `.nc` read:
# components that share a forecast array (and read plan) collapse to one window
# slot, so the data is read once per timestamp no matter how many components
# reference it. This wrapper carries that dedup up to Julia — each unique slot's
# window is materialized (and FunctionData-decoded) at most once per read.

# Owner-category String tag for a `TSS.OwnerCategory` enum (the inverse of
# `_tss_category`), used to resolve a reader entry back to its owner object.
_owner_category_string(c::TSS.OwnerCategory) =
    c == TSS.Component ? "Component" : "SupplementalAttribute"

# Map an IS forecast type to the `TimeSeriesStore` reader type. A `Deterministic`
# (or the `AbstractDeterministic` abstraction) reader is abstract and also
# includes `DeterministicSingleTimeSeries`; a DST query is exact.
_tss_forecast_type(::Type{<:DeterministicSingleTimeSeries}) =
    TSS.DeterministicSingleTimeSeries
_tss_forecast_type(::Type{<:AbstractDeterministic}) = TSS.Deterministic
_tss_forecast_type(::Type{<:Probabilistic}) = TSS.Probabilistic
_tss_forecast_type(::Type{<:Scenarios}) = TSS.Scenarios

# Decode a single `(horizon, k)` FunctionData window matrix (the per-window analog
# of `_decode_forecast_window`, which slices a `(horizon, count, k)` array).
function _decode_forecast_window_matrix(mat::AbstractMatrix{<:Real}, logical_type)
    horizon = size(mat, 1)
    if logical_type == "LinearFunctionData"
        return [LinearFunctionData(mat[h, 1], mat[h, 2]) for h in 1:horizon]
    elseif logical_type == "QuadraticFunctionData"
        return [QuadraticFunctionData(mat[h, 1], mat[h, 2], mat[h, 3]) for h in 1:horizon]
    elseif logical_type == "PiecewiseLinearData"
        out = Vector{PiecewiseLinearData}(undef, horizon)
        for h in 1:horizon
            n = Int(round(mat[h, 1]))
            out[h] = PiecewiseLinearData([(mat[h, 2j], mat[h, 2j + 1]) for j in 1:n])
        end
        return out
    end
    error("Rust backend cannot decode forecast logical_type $logical_type")
end

# The `logical_type` tags that mean a window is FunctionData (stored as a
# `(horizon, k)` matrix). Any other tag (`nothing`, or a scalar dtype string like
# "Float64" carried by a SingleTimeSeries-backed DST) is a plain scalar window.
const _RUST_FUNCTIONDATA_LOGICAL =
    ("LinearFunctionData", "QuadraticFunctionData", "PiecewiseLinearData")

# Orient + decode one raw window into IS's canonical per-window value (matching a
# single `get_time_series(...).data[timestamp]`): Probabilistic/Scenarios windows
# are stored `(count_member, horizon)` and transposed to `(horizon, member)`;
# Deterministic/DST windows are a horizon vector, or a FunctionData column decoded
# via `logical_type`.
function _decode_forecast_reader_window(
    ::Type{T},
    raw,
    logical_type,
) where {T <: Forecast}
    if T <: Probabilistic || T <: Scenarios
        return permutedims(raw)
    end
    (logical_type in _RUST_FUNCTIONDATA_LOGICAL) || return raw
    return _decode_forecast_window_matrix(raw, logical_type)
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
    inner::TSS.ForecastReader
    store::RustTimeSeriesStore
    entries::Vector{ForecastReaderEntry}
    "logical_type for each entry (parallel to `entries`); `nothing` for scalars."
    logical_types::Vector{Union{Nothing, String}}
    "The IS forecast type the reader was built for (drives window orientation)."
    reported_type::Type
    "Per-slot materialized window cache; reset on each read."
    windows::Vector{Any}
    has_read::Bool
end

# Build a reader from the store. `id_to_owner(owner_id::Int, category::String)`
# resolves each entry's owner object (the system holds the owner maps). Per-entry
# metadata (owner, key, logical_type) is resolved once here, off the read path.
function _rust_build_forecast_reader(
    store::RustTimeSeriesStore,
    id_to_owner,
    ::Type{T};
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features = Dict{String, Any}(),
) where {T <: Forecast}
    inner = TSS.build_forecast_reader(store.inner, _tss_forecast_type(T);
        resolution = resolution, name = name, features = features)
    tss_entries = TSS.forecast_entries(inner)
    n = length(tss_entries)
    entries = Vector{ForecastReaderEntry}(undef, n)
    logical_types = Vector{Union{Nothing, String}}(undef, n)
    for (i, e) in enumerate(tss_entries)
        info = TSS.key_info(e.key)
        owner = id_to_owner(Int(info.owner_id), _owner_category_string(info.owner_category))
        is_type = _rust_is_type(nameof(info.time_series_type))
        feats = Dict{String, Any}(info.features)
        fmeta = TSS.get_forecast_metadata(store.inner, info.owner_id,
            info.owner_category, info.name, _rust_ts_code(is_type);
            resolution = info.resolution, features = feats)
        logical_types[i] = fmeta.logical_type
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
        # `e.slot` is 0-based in the Rust store; carry it 1-based for Julia.
        entries[i] = ForecastReaderEntry(owner, key, e.slot + 1)
    end
    windows = Vector{Any}(nothing, TSS.forecast_num_slots(inner))
    return ForecastReader(inner, store, entries, logical_types, T, windows, false)
end

"""
$(TYPEDSIGNATURES)
The reader's window timeline as `(; initial_timestamp, resolution, interval,
count)`. Valid read timestamps are `initial_timestamp + k·interval` for
`k in 0:count-1`.
"""
get_forecast_reader_timeline(reader::ForecastReader) = TSS.forecast_timeline(reader.inner)

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
    TSS.forecast_read!(reader.inner, timestamp)
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
    raw = TSS.forecast_values(reader.inner, entry_index)
    window = _decode_forecast_reader_window(
        reader.reported_type, raw, reader.logical_types[entry_index])
    reader.windows[entry.slot] = window
    return window
end

"""Route `has_time_series(owner, T, name; ...)` to the Rust store. Honors partial
(subset) feature / resolution queries: matches if any stored series of type `T`
contains at least the requested features."""
function _rust_has_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    return !isempty(
        _rust_owner_list_metadata(owner;
            time_series_type = T, name = name, resolution = resolution, features...),
    )
end

# The single stored TimeSeriesType code for a concrete IS time series type.
_rust_ts_code(::Type{<:SingleTimeSeries}) = TSS.TS_TYPE_SINGLE
_rust_ts_code(::Type{<:NonSequentialTimeSeries}) = TSS.TS_TYPE_NON_SEQUENTIAL
_rust_ts_code(::Type{<:DeterministicSingleTimeSeries}) = TSS.TS_TYPE_DETERMINISTIC_SINGLE
_rust_ts_code(::Type{<:Deterministic}) = TSS.TS_TYPE_DETERMINISTIC
_rust_ts_code(::Type{<:Probabilistic}) = TSS.TS_TYPE_PROBABILISTIC
_rust_ts_code(::Type{<:Scenarios}) = TSS.TS_TYPE_SCENARIOS

# Name-less existence queries. `_rust_query_codes(T)` maps a query type to the
# stored TimeSeriesType codes to match (empty tuple = any type).
_rust_query_codes(::Type{<:SingleTimeSeries}) = (TSS.TS_TYPE_SINGLE,)
_rust_query_codes(::Type{<:NonSequentialTimeSeries}) = (TSS.TS_TYPE_NON_SEQUENTIAL,)
_rust_query_codes(::Type{<:DeterministicSingleTimeSeries}) =
    (TSS.TS_TYPE_DETERMINISTIC_SINGLE,)
_rust_query_codes(::Type{<:AbstractDeterministic}) =
    (TSS.TS_TYPE_DETERMINISTIC, TSS.TS_TYPE_DETERMINISTIC_SINGLE)
_rust_query_codes(::Type{<:Probabilistic}) = (TSS.TS_TYPE_PROBABILISTIC,)
_rust_query_codes(::Type{<:Scenarios}) = (TSS.TS_TYPE_SCENARIOS,)
_rust_query_codes(::Type{<:Forecast}) = (TSS.TS_TYPE_DETERMINISTIC,
    TSS.TS_TYPE_DETERMINISTIC_SINGLE, TSS.TS_TYPE_PROBABILISTIC, TSS.TS_TYPE_SCENARIOS)
_rust_query_codes(::Type{<:StaticTimeSeries}) =
    (TSS.TS_TYPE_SINGLE, TSS.TS_TYPE_NON_SEQUENTIAL)
_rust_query_codes(::Type{<:TimeSeriesData}) = ()

# The single stored TimeSeriesType code to push into the core `list_keys` filter
# for a query type, or `nothing` when the type cannot be expressed as one code:
# an abstract family, or `Deterministic` (which, under the metadata-store
# semantics encoded in `_rust_type_matches`, also matches a stored
# `DeterministicSingleTimeSeries`). When `nothing`, the caller applies the
# residual `_rust_type_matches` filter on the (already narrowed) rows.
_rust_pushable_code(::Type{<:SingleTimeSeries}) = TSS.TS_TYPE_SINGLE
_rust_pushable_code(::Type{<:NonSequentialTimeSeries}) = TSS.TS_TYPE_NON_SEQUENTIAL
_rust_pushable_code(::Type{<:DeterministicSingleTimeSeries}) =
    TSS.TS_TYPE_DETERMINISTIC_SINGLE
_rust_pushable_code(::Type{<:Probabilistic}) = TSS.TS_TYPE_PROBABILISTIC
_rust_pushable_code(::Type{<:Scenarios}) = TSS.TS_TYPE_SCENARIOS
_rust_pushable_code(::Type{<:TimeSeriesData}) = nothing

# All stored TimeSeriesType codes whose IS type is a subtype of `T` (strict `<:`
# semantics — distinct from `_rust_type_matches`, which treats a `Deterministic`
# query as also matching a `DeterministicSingleTimeSeries`). Used by the
# store-wide filters (`resolutions`, `list_owner_ids`) that key on subtyping.
const _RUST_CODE_TYPES = (
    (TSS.TS_TYPE_SINGLE, SingleTimeSeries),
    (TSS.TS_TYPE_NON_SEQUENTIAL, NonSequentialTimeSeries),
    (TSS.TS_TYPE_DETERMINISTIC, Deterministic),
    (TSS.TS_TYPE_DETERMINISTIC_SINGLE, DeterministicSingleTimeSeries),
    (TSS.TS_TYPE_PROBABILISTIC, Probabilistic),
    (TSS.TS_TYPE_SCENARIOS, Scenarios),
)
_rust_subtype_codes(::Type{T}) where {T <: TimeSeriesData} =
    Tuple(c for (c, k) in _RUST_CODE_TYPES if k <: T)

# True iff `owner` has any time series, optionally restricted to type `T`.
function _rust_has_any(owner; time_series_type::Union{Nothing, Type} = nothing)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, _, owner_category = _rust_owner_args(owner)
    category = _tss_category(owner_category)
    codes = time_series_type === nothing ? () : _rust_query_codes(time_series_type)
    isempty(codes) && return TSS.has_for_owner(store.inner, owner_id, category)
    return any(
        c -> TSS.has_for_owner(store.inner, owner_id, category; time_series_type = c),
        codes,
    )
end

# ---- Metadata reconstruction (parity with the SQLite metadata store) --------
# IS time series type for a `TimeSeriesStore` metadata-row type (matched by name).
_rust_is_type(t::Type) = _rust_is_type(nameof(t))
_rust_is_type(s::Symbol) =
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
        error("Rust backend does not support time series type $s")
    end

# Whether a stored row of concrete type `row_type` satisfies a query for type `T`.
# Mirrors the metadata-store semantics: a `Deterministic` (or `AbstractDeterministic`)
# query also matches a `DeterministicSingleTimeSeries` (which reads as a
# `Deterministic`), while a `DeterministicSingleTimeSeries` query matches DST only.
_rust_type_matches(row_type::Type, ::Type{T}) where {T <: TimeSeriesData} =
    if T <: DeterministicSingleTimeSeries
        row_type <: DeterministicSingleTimeSeries
    elseif T <: AbstractDeterministic
        row_type <: AbstractDeterministic
    else
        row_type <: T
    end

# Build the matching IS `TimeSeriesKey` from a `TSS.list_keys` row. The key is
# the single descriptor for a stored association; forecast-only fields
# (percentiles, scenario_count) are not carried — they come from the data on read.
function _key_from_row(row)
    feats = Dict{String, Any}(string(k) => v for (k, v) in row.features)
    is_type = _rust_is_type(row.time_series_type)
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
    error("Rust backend cannot build a key for $(row.time_series_type)")
end

# All matching associations for one owner, as `TimeSeriesKey` objects. The core
# `list_keys` query filters owner / name / resolution / features; an abstract
# `time_series_type` (or `Deterministic`, which also matches a DST) and `interval`
# are not catalog filter columns, so they are applied as a residual on the
# already-narrowed rows.
function _rust_list_metadata(
    store::RustTimeSeriesStore,
    owner_id::Integer,
    owner_category::TSS.OwnerCategory;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features = (),
)
    type_code =
        isnothing(time_series_type) ? nothing : _rust_pushable_code(time_series_type)
    feats = Dict{String, Any}(string(k) => v for (k, v) in features)
    rows = TSS.list_keys(store.inner; owner_id = owner_id, owner_category = owner_category,
        time_series_type = type_code, name = name, features = feats)
    out = TimeSeriesKey[]
    for row in rows
        if !isnothing(time_series_type)
            _rust_type_matches(_rust_is_type(row.time_series_type), time_series_type) ||
                continue
        end
        # `resolution`/`interval` are matched here, not pushed into the catalog
        # query, so `Period` equality is used (a regular `Hour(1)` equals the
        # stored `Millisecond`, while an irregular `Month`/`Year` does not — the
        # Rust store keys on milliseconds and cannot represent those exactly).
        isnothing(resolution) || row.resolution == resolution || continue
        if !isnothing(interval)
            (row.interval !== nothing && row.interval == interval) || continue
        end
        push!(out, _key_from_row(row))
    end
    return out
end

# A key for every time series in the store (all owners).
_rust_all_metadata(store::RustTimeSeriesStore) =
    [_key_from_row(row) for row in TSS.list_keys(store.inner)]

# Owner-level `list_metadata` entry point (mirrors the metadata-store signature).
function _rust_owner_list_metadata(
    owner::TimeSeriesOwners;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features...,
)
    mgr = get_time_series_manager(owner)
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, _, owner_category = _rust_owner_args(owner)
    return _rust_list_metadata(store, owner_id, _tss_category(owner_category);
        time_series_type = time_series_type, name = name, resolution = resolution,
        interval = interval, features = _rust_features(features))
end

# Single matching metadata; throws when zero or more than one match (parity with
# `TimeSeriesMetadataStore.get_metadata`).
function _rust_get_metadata(
    owner::TimeSeriesOwners,
    ::Type{T},
    name::AbstractString;
    resolution = nothing,
    interval = nothing,
    features...,
) where {T <: TimeSeriesData}
    items = _rust_owner_list_metadata(owner; time_series_type = T, name = name,
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

# `get_time_series_keys` for an owner. `_rust_owner_list_metadata` already returns keys.
_rust_get_time_series_keys(owner::TimeSeriesOwners) = _rust_owner_list_metadata(owner)

# Content hash (hex) of the array `key` resolves to under `owner`. Narrows the
# catalog to the owner + the key's type/name in one query, then matches the exact
# resolution + features in-memory (Period equality, as in `_rust_list_metadata`).
function _rust_get_time_series_hash(owner::TimeSeriesOwners, key::TimeSeriesKey)
    mgr = get_time_series_manager(owner)
    isnothing(mgr) &&
        throw(RustTimeSeriesNotFound("owner has no time series to hash"))
    store = mgr.data_store::RustTimeSeriesStore
    owner_id, _, owner_category = _rust_owner_args(owner)
    T = get_time_series_type(key)
    rows = TSS.list_array_groups(store.inner; owner_id = owner_id,
        owner_category = _tss_category(owner_category),
        time_series_type = _rust_pushable_code(T), name = get_name(key))
    target_res = get_resolution(key)
    target_feats = get_features(key)
    for row in rows
        _rust_type_matches(_rust_is_type(row.time_series_type), T) || continue
        row.resolution == target_res || continue
        row.features == target_feats || continue
        return row.data_hash
    end
    throw(RustTimeSeriesNotFound("no stored array matches key name=$(get_name(key))"))
end

# Group every stored association by content hash, as `(owner, key)` pairs. The
# `id_to_owner` callback resolves an `(owner_id, owner_category)` row back to the
# owner object (the system holds the component / supplemental-attribute maps).
# One catalog query returns the hash on every row, so no per-row metadata fetch.
function _rust_group_by_hash(store::RustTimeSeriesStore, id_to_owner)
    groups = Dict{String, Vector{Tuple{TimeSeriesOwners, TimeSeriesKey}}}()
    for row in TSS.list_array_groups(store.inner)
        owner = id_to_owner(Int(row.owner_id), row.owner_category)
        pairs = get!(
            () -> Tuple{TimeSeriesOwners, TimeSeriesKey}[], groups, row.data_hash)
        push!(pairs, (owner, _key_from_row(row)))
    end
    return groups
end

# Reconstruct each matching time series for an owner; applies `filter_func`.
function _rust_get_time_series_multiple(
    owner::TimeSeriesOwners,
    filter_func;
    type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
)
    metas = _rust_owner_list_metadata(owner; time_series_type = type, name = name,
        resolution = resolution, interval = interval)
    Channel() do channel
        for m in metas
            feats = (Symbol(k) => v for (k, v) in get_features(m))
            ts = if m isa ForecastKey
                _rust_get_forecast(owner, get_name(m); resolution = get_resolution(m), feats...)
            elseif m isa NonSequentialTimeSeriesKey
                _rust_get_time_series(NonSequentialTimeSeries, owner, get_name(m); feats...)
            else
                _rust_get_time_series(SingleTimeSeries, owner, get_name(m);
                    resolution = get_resolution(m), feats...)
            end
            (isnothing(filter_func) || filter_func(ts)) && put!(channel, ts)
        end
    end
end

# Reassign every time series from `old_id` to `new_id` (component re-id). Components
# are always the Component owner category.
function _rust_replace_component_id!(
    store::RustTimeSeriesStore,
    old_id::Int,
    new_id::Int,
)
    TSS.replace_owner!(store.inner, old_id, new_id, TSS.Component)
    return
end

# ---- Store-wide aggregates (parity with the SQLite metadata store) ----------

# Distinct, sorted resolutions across the store, optionally restricted to a type
# (strict subtype). One DISTINCT query per concrete subtype code, in the core.
function _rust_get_time_series_resolutions(
    store::RustTimeSeriesStore;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
)
    isnothing(time_series_type) && return sort!(TSS.get_resolutions(store.inner))
    codes = _rust_subtype_codes(time_series_type)
    res = Set{Dates.Millisecond}()
    for code in codes
        union!(res, TSS.get_resolutions(store.inner; time_series_type = code))
    end
    return sort!(collect(res))
end

# Counts of time series grouped by type name (parity with counts_by_type).
function _rust_get_time_series_counts_by_type(store::RustTimeSeriesStore)
    counts = OrderedDict{String, Int}()
    for r in TSS.counts_by_type(store.inner)
        counts[string(nameof(r.time_series_type))] = r.count
    end
    return [OrderedDict("type" => k, "count" => v) for (k, v) in sort!(OrderedDict(counts))]
end

# Number of distinct stored arrays (parity with get_num_time_series).
_rust_get_num_time_series(store::RustTimeSeriesStore) = TSS.num_distinct_arrays(store.inner)

# Counts of distinct stored arrays (shared series count once) and owners by
# category, matching the metadata-store's `get_time_series_counts`.
_rust_time_series_counts(store::RustTimeSeriesStore) = TSS.time_series_counts(store.inner)

# Static-time-series summary DataFrame (parity with the metadata-store version).
# The core groups the rows; we shape them into the DataFrame.
function _rust_static_summary_table(store::RustTimeSeriesStore)
    rows = TSS.static_summary(store.inner)
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
function _rust_forecast_summary_table(store::RustTimeSeriesStore)
    rows = TSS.forecast_summary(store.inner)
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
function _rust_forecast_parameters(
    store::RustTimeSeriesStore;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    # The first forecast key matching `resolution`/`interval`, compared with
    # `Period` equality. The store preserves the calendar-aware `Period` type, so
    # the stored periods are passed through unchanged — converting them to
    # `Millisecond` would throw for irregular `Month`/`Year` resolutions.
    for row in TSS.list_keys(store.inner)
        _rust_is_type(row.time_series_type) <: Forecast || continue
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
function _rust_list_owner_ids(
    store::RustTimeSeriesStore,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = _tss_category(_get_owner_category(owner_type))
    # Without a resolution filter, enumerate owner ids in the core (optionally per
    # concrete subtype code). With one, scan the category's keys so `Period`
    # equality is used for the resolution match (see `_rust_list_metadata`).
    if isnothing(resolution)
        isnothing(time_series_type) && return TSS.list_owner_ids(store.inner, category)
        ids = Set{Int}()
        for code in _rust_subtype_codes(time_series_type)
            union!(ids, TSS.list_owner_ids(store.inner, category; time_series_type = code))
        end
        return collect(ids)
    end
    ids = Set{Int}()
    for row in TSS.list_keys(store.inner; owner_category = category)
        if !isnothing(time_series_type)
            _rust_is_type(row.time_series_type) <: time_series_type || continue
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
function _rust_list_metadata_with_owner(
    store::RustTimeSeriesStore,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = _tss_category(_get_owner_category(owner_type))
    rows = TSS.list_keys(store.inner; owner_category = category)
    out = NamedTuple[]
    for row in rows
        if !isnothing(time_series_type)
            _rust_is_type(row.time_series_type) <: time_series_type || continue
        end
        isnothing(resolution) || row.resolution == resolution || continue
        push!(out, (owner_id = Int(row.owner_id), metadata = _key_from_row(row)))
    end
    return out
end

# Verify all SingleTimeSeries share an initial timestamp and length; return
# `(initial_timestamp, length)` (parity with the metadata-store check). Resolved
# by a single DISTINCT query in the core.
function _rust_check_consistency(store::RustTimeSeriesStore, ::Type{<:SingleTimeSeries})
    result = try
        TSS.check_static_consistency(store.inner)
    catch e
        e isa TSS.IntegrityError || rethrow()
        throw(InvalidValue(e.msg))
    end
    isnothing(result) && return (Dates.DateTime(Dates.Minute(0)), 0)
    return (result.initial_timestamp, result.length)
end

_rust_check_consistency(::RustTimeSeriesStore, ::Type{<:Forecast}) = nothing
