# Rust-backed time series storage.
#
# `RustTimeSeriesStore` delegates BOTH array data and metadata to the external
# `time-series-store` Rust engine, via the `TimeSeriesStore.jl` binding package.
# The Rust store owns both: arrays land in a NetCDF4 `.nc` file (content-addressed
# by SHA-256 hash) and metadata in a sibling `.sqlite` file. Time series *data*
# identity is the array content hash, not a UUID. Persisting a system writes the
# `.nc` + `.sqlite` pair directly; no HDF5 is involved.
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

_tss_category(category::AbstractString) =
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
    arr, logical = _storage_array(TimeSeries.values(get_data(sts)))
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
    get_single(store, owner_id, owner_category, name; resolution, features=Dict()) -> SingleTimeSeries

Reconstruct a `SingleTimeSeries` (metadata + array) from the Rust store.
"""
function get_single(
    store::RustTimeSeriesStore,
    owner_id::Integer,
    owner_category::TSS.OwnerCategory,
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    features = Dict{String, Any}(),
)
    meta =
        get_metadata(store, owner_id, owner_category, name;
            resolution = resolution, features = features)
    values = _read_values(store, meta.data_hash, meta.logical_type, meta.dtype, meta.length)
    timestamps = range(meta.initial_timestamp; length = meta.length, step = meta.resolution)
    sts = SingleTimeSeries(;
        name = String(name),
        data = TimeSeries.TimeArray(collect(timestamps), values),
        resolution = meta.resolution,
    )
    set_uuid!(get_internal(sts), _rust_ts_uuid(meta.data_hash))
    return sts
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

# A hashable identity for one stored association (a `TSS.list_metadata` row),
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
function _rust_array_sts_dst_counts(store::RustTimeSeriesStore, hash::Vector{UInt8})
    sts = 0
    dst = 0
    for row in TSS.list_metadata(store.inner)
        row.data_hash == hash || continue
        t = _rust_is_type(row.time_series_type)
        if t <: DeterministicSingleTimeSeries
            dst += 1
        elseif t <: SingleTimeSeries
            sts += 1
        end
    end
    return (sts = sts, dst = dst)
end

# Remove the single association described by a `TSS.list_metadata` row.
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

# ---- TimeSeriesManager routing (SingleTimeSeries only) ---------------------

"""
Route a manager-level `add_time_series!` to the Rust store. Only SingleTimeSeries
is supported; data identity is the array content hash (no `time_series_uuid`).
"""
function _rust_add_time_series!(
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    throw_if_does_not_support_time_series(owner)
    # A DeterministicSingleTimeSeries is a derived view over an already-validated
    # SingleTimeSeries (it has no raw `get_data`), so it skips the data check.
    time_series isa DeterministicSingleTimeSeries || check_time_series_data(time_series)
    if time_series isa Forecast
        return _rust_add_forecast!(mgr, owner, time_series; features...)
    end
    time_series isa SingleTimeSeries ||
        error(
            "Rust backend supports SingleTimeSeries, Deterministic, " *
            "DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
            "(got $(typeof(time_series)))",
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
    _rust_assign_stored_uuid!(store, time_series, owner_id, category, name,
        TSS.TS_TYPE_SINGLE; resolution = resolution, features = feats)
    return StaticTimeSeriesKey(;
        time_series_type = SingleTimeSeries,
        name = name,
        initial_timestamp = get_initial_timestamp(time_series),
        resolution = resolution,
        length = length(time_series),
        features = Dict{String, Any}(feats),
    )
end

# Anything other than SingleTimeSeries / Forecast is unsupported on the Rust backend.
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
# `count` slicing on the forecast window axis. `len` applies only to static
# series (a forecast always returns full horizon windows), so it is rejected.
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
    timestamps = range(t0; length = n, step = meta.resolution)
    sts = SingleTimeSeries(;
        name = String(name),
        data = TimeSeries.TimeArray(collect(timestamps), vals),
        resolution = meta.resolution,
    )
    set_uuid!(get_internal(sts), _rust_ts_uuid(meta.data_hash))
    return sts
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
        _rust_assign_stored_uuid!(store, ts, owner_id, category, name,
            TSS.TS_TYPE_PROBABILISTIC; resolution = resolution, features = feats)
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
    _rust_assign_stored_uuid!(store, ts, owner_id, category, name, ts_type;
        resolution = resolution, features = feats)
    return ForecastKey(;
        time_series_type = typeof(ts), name = name,
        initial_timestamp = get_initial_timestamp(ts), resolution = resolution,
        horizon = get_horizon(ts), interval = interval, count = count,
        features = Dict{String, Any}(feats))
end

# Validate `start_time` / `count` against a forecast's `total_count` windows
# (spaced by `interval` from `initial_timestamp`) and return the 1-based window
# index range `(start_idx, n)` to keep. Throws ArgumentError if `start_time` is
# not a window boundary or the requested range exceeds what is stored.
function _forecast_window_range(initial_timestamp, interval, total_count, start_time, count)
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
    return start_idx, n
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
        p = TSS.get_time_series(TSS.Probabilistic, store.inner, owner_id, category, name;
            resolution = resolution, features = feats)
        s, n = _forecast_window_range(
            p.initial_timestamp,
            p.interval,
            p.count,
            start_time,
            count,
        )
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in s:(s + n - 1)
            data[p.initial_timestamp + p.interval * (i - 1)] =
                _truncate(permutedims(p.data[:, :, i]))
        end
        result = Probabilistic(; name = String(name), data = data,
            percentiles = p.percentiles, resolution = p.resolution,
            interval = p.interval)
        _rust_assign_stored_uuid!(store, result, owner_id, category, name,
            TSS.TS_TYPE_PROBABILISTIC;
            resolution = resolution, features = feats)
        return result
    elseif has_typed(store, owner_id, category, name, TSS.TS_TYPE_DETERMINISTIC;
        resolution = resolution, features = feats)
        # `.data` is the canonical (horizon_count, count) array.
        d = TSS.get_time_series(TSS.Deterministic, store.inner, owner_id, category, name;
            resolution = resolution, features = feats)
        s, n = _forecast_window_range(
            d.initial_timestamp,
            d.interval,
            d.count,
            start_time,
            count,
        )
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
        data = SortedDict(
            d.initial_timestamp + d.interval * (i - 1) => window(i)
            for i in s:(s + n - 1)
        )
        result = Deterministic(; name = String(name), data = data,
            resolution = d.resolution, interval = d.interval)
        set_uuid!(get_internal(result), _rust_ts_uuid(fmeta.data_hash))
        return result
    elseif has_typed(store, owner_id, category, name, TSS.TS_TYPE_DETERMINISTIC_SINGLE;
        resolution = resolution, features = feats)
        # A DST shares the underlying SingleTimeSeries array; rebuild that series
        # and wrap it with the DST windowing parameters (read as a Deterministic).
        d = TSS.get_time_series(TSS.DeterministicSingleTimeSeries, store.inner, owner_id,
            category, name;
            resolution = resolution, features = feats)
        s, n = _forecast_window_range(
            d.initial_timestamp,
            d.interval,
            d.count,
            start_time,
            count,
        )
        # A DST is a view over the shared SingleTimeSeries array; its windows
        # cannot be truncated, so a partial `len` is rejected.
        if !isnothing(len)
            horizon_count = Int(d.horizon ÷ d.resolution)
            len == horizon_count || throw(
                ArgumentError(
                    "len=$len is not supported for DeterministicSingleTimeSeries; " *
                    "windows must be the full horizon ($horizon_count)"),
            )
        end
        sts = get_single(store, owner_id, category, name;
            resolution = resolution, features = feats)
        # When a single window spans the whole series (count == 1 and the interval
        # equals the horizon), IS represents the interval as `Second(0)`; otherwise
        # the stored interval is kept.
        result_interval = (n == 1 && d.interval == d.horizon) ? Dates.Second(0) : d.interval
        # DeterministicSingleTimeSeries has no internal UUID, so none is assigned.
        return DeterministicSingleTimeSeries(; single_time_series = sts,
            initial_timestamp = d.initial_timestamp + d.interval * (s - 1),
            interval = result_interval, count = n, horizon = d.horizon)
    elseif has_typed(store, owner_id, category, name, TSS.TS_TYPE_SCENARIOS;
        resolution = resolution, features = feats)
        # `.data` is the canonical (scenario_count, horizon_count, count) array.
        s_ts = TSS.get_time_series(TSS.Scenarios, store.inner, owner_id, category, name;
            resolution = resolution, features = feats)
        s, n = _forecast_window_range(s_ts.initial_timestamp, s_ts.interval, s_ts.count,
            start_time, count)
        data = SortedDict{Dates.DateTime, Matrix{Float64}}()
        for i in s:(s + n - 1)
            data[s_ts.initial_timestamp + s_ts.interval * (i - 1)] =
                _truncate(permutedims(s_ts.data[:, :, i]))
        end
        result = Scenarios(; name = String(name), data = data,
            scenario_count = s_ts.scenario_count,
            resolution = s_ts.resolution, interval = s_ts.interval)
        _rust_assign_stored_uuid!(store, result, owner_id, category, name,
            TSS.TS_TYPE_SCENARIOS;
            resolution = resolution, features = feats)
        return result
    end
    throw(RustTimeSeriesNotFound("no forecast for owner=$owner_id name=$name"))
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
_rust_ts_code(::Type{<:DeterministicSingleTimeSeries}) = TSS.TS_TYPE_DETERMINISTIC_SINGLE
_rust_ts_code(::Type{<:Deterministic}) = TSS.TS_TYPE_DETERMINISTIC
_rust_ts_code(::Type{<:Probabilistic}) = TSS.TS_TYPE_PROBABILISTIC
_rust_ts_code(::Type{<:Scenarios}) = TSS.TS_TYPE_SCENARIOS

# Name-less existence queries. `_rust_query_codes(T)` maps a query type to the
# stored TimeSeriesType codes to match (empty tuple = any type).
_rust_query_codes(::Type{<:SingleTimeSeries}) = (TSS.TS_TYPE_SINGLE,)
_rust_query_codes(::Type{<:DeterministicSingleTimeSeries}) =
    (TSS.TS_TYPE_DETERMINISTIC_SINGLE,)
_rust_query_codes(::Type{<:AbstractDeterministic}) =
    (TSS.TS_TYPE_DETERMINISTIC, TSS.TS_TYPE_DETERMINISTIC_SINGLE)
_rust_query_codes(::Type{<:Probabilistic}) = (TSS.TS_TYPE_PROBABILISTIC,)
_rust_query_codes(::Type{<:Scenarios}) = (TSS.TS_TYPE_SCENARIOS,)
_rust_query_codes(::Type{<:Forecast}) = (TSS.TS_TYPE_DETERMINISTIC,
    TSS.TS_TYPE_DETERMINISTIC_SINGLE, TSS.TS_TYPE_PROBABILISTIC, TSS.TS_TYPE_SCENARIOS)
_rust_query_codes(::Type{<:TimeSeriesData}) = ()

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
#
# The Rust store is content-addressed: a time series' identity is the SHA-256
# hash of its array, not a per-association UUID. IS still exposes
# `time_series_uuid`, so we derive a stable `Base.UUID` from the hash. A UUID is
# 16 bytes, so we use the hash's 16-byte prefix; identical arrays therefore share
# a UUID, consistent with the store's content-addressed de-duplication.
function _rust_ts_uuid(hash::Vector{UInt8})
    length(hash) >= 16 ||
        error("Rust data hash too short to derive a UUID: $(length(hash))")
    u = UInt128(0)
    @inbounds for i in 1:16
        u = (u << 8) | hash[i]
    end
    return Base.UUID(u)
end

# Give a just-stored time series object the content-addressed identity used on
# reconstruction (UUID derived from the array hash), so `get_uuid(original)`
# matches `get_uuid(get_time_series(...))`.
function _rust_assign_stored_uuid!(
    store::RustTimeSeriesStore,
    ts::TimeSeriesData,
    owner_id::Integer,
    owner_category::TSS.OwnerCategory,
    name::AbstractString,
    ts_type_code::Integer;
    resolution = nothing,
    features = Dict{String, Any}(),
)
    hash = if ts_type_code in (TSS.TS_TYPE_SINGLE, TSS.TS_TYPE_DETERMINISTIC_SINGLE)
        # A DST shares its underlying SingleTimeSeries array; use that hash.
        get_metadata(
            store,
            owner_id,
            owner_category,
            name;
            resolution = resolution,
            features = features,
        ).data_hash
    else
        TSS.get_forecast_metadata(store.inner, owner_id, owner_category, name, ts_type_code;
            resolution = resolution, features = features).data_hash
    end
    set_uuid!(get_internal(ts), _rust_ts_uuid(hash))
    return
end

# IS time series type for a `TimeSeriesStore` metadata-row type (matched by name).
_rust_is_type(t::Type) = _rust_is_type(nameof(t))
_rust_is_type(s::Symbol) =
    if s === :SingleTimeSeries
        SingleTimeSeries
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

# Build the matching IS `TimeSeriesMetadata` from a `TSS.list_metadata` row.
function _metadata_from_row(row)
    feats = Dict{String, Union{Bool, Int, String}}(row.features)
    uuid = _rust_ts_uuid(row.data_hash)
    is_type = _rust_is_type(row.time_series_type)
    if is_type <: SingleTimeSeries
        return SingleTimeSeriesMetadata(;
            name = row.name,
            resolution = row.resolution,
            initial_timestamp = row.initial_timestamp,
            time_series_uuid = uuid,
            length = row.length,
            features = feats,
        )
    elseif is_type <: AbstractDeterministic
        return DeterministicMetadata(;
            name = row.name,
            resolution = row.resolution,
            initial_timestamp = row.initial_timestamp,
            interval = row.interval,
            count = row.count,
            time_series_uuid = uuid,
            horizon = row.horizon,
            time_series_type = is_type,
            features = feats,
        )
    elseif is_type <: Probabilistic
        return ProbabilisticMetadata(;
            name = row.name,
            initial_timestamp = row.initial_timestamp,
            resolution = row.resolution,
            interval = row.interval,
            count = row.count,
            percentiles = row.percentiles,
            time_series_uuid = uuid,
            horizon = row.horizon,
            features = feats,
        )
    elseif is_type <: Scenarios
        # Scenarios store as (scenario_count, horizon, count); the row's `length`
        # is the array's leading dim, i.e. the scenario count.
        return ScenariosMetadata(;
            name = row.name,
            resolution = row.resolution,
            initial_timestamp = row.initial_timestamp,
            interval = row.interval,
            scenario_count = row.length,
            count = row.count,
            time_series_uuid = uuid,
            horizon = row.horizon,
            features = feats,
        )
    end
    error("Rust backend cannot reconstruct metadata for $(row.time_series_type)")
end

# True if a metadata row passes the optional type/name/resolution/interval/feature
# filters. `time_series_type` is an IS type; features match as a subset.
function _row_matches(row; time_series_type, name, resolution, interval, features)
    isnothing(name) || row.name == name || return false
    isnothing(resolution) || (row.resolution == resolution) || return false
    if !isnothing(interval)
        (row.interval !== nothing && row.interval == interval) || return false
    end
    if !isnothing(time_series_type)
        _rust_type_matches(_rust_is_type(row.time_series_type), time_series_type) ||
            return false
    end
    for (k, v) in features
        haskey(row.features, String(k)) && row.features[String(k)] == v || return false
    end
    return true
end

# All matching metadata for one owner, as IS `TimeSeriesMetadata` objects.
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
    rows = TSS.list_metadata(store.inner;
        owner_id = owner_id, owner_category = owner_category)
    out = TimeSeriesMetadata[]
    for row in rows
        _row_matches(row; time_series_type = time_series_type, name = name,
            resolution = resolution, interval = interval, features = features) || continue
        push!(out, _metadata_from_row(row))
    end
    return out
end

# Metadata for every time series in the store (all owners).
_rust_all_metadata(store::RustTimeSeriesStore) =
    [_metadata_from_row(row) for row in TSS.list_metadata(store.inner)]

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

# `get_time_series_keys` for an owner.
_rust_get_time_series_keys(owner::TimeSeriesOwners) =
    [make_time_series_key(m) for m in _rust_owner_list_metadata(owner)]

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
            ts = if m isa ForecastMetadata
                _rust_get_forecast(owner, get_name(m); resolution = get_resolution(m), feats...)
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

# Distinct, sorted resolutions across the store, optionally restricted to a type.
function _rust_get_time_series_resolutions(
    store::RustTimeSeriesStore;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
)
    res = Set{Dates.Period}()
    for row in TSS.list_metadata(store.inner)
        if !isnothing(time_series_type) &&
           !(_rust_is_type(row.time_series_type) <: time_series_type)
            continue
        end
        isnothing(row.resolution) || push!(res, Dates.Millisecond(row.resolution))
    end
    return sort!(collect(res))
end

# Counts of time series grouped by type name (parity with counts_by_type).
function _rust_get_time_series_counts_by_type(store::RustTimeSeriesStore)
    counts = OrderedDict{String, Int}()
    for row in TSS.list_metadata(store.inner)
        t = string(nameof(row.time_series_type))
        counts[t] = get(counts, t, 0) + 1
    end
    return [OrderedDict("type" => k, "count" => v) for (k, v) in sort!(OrderedDict(counts))]
end

# Number of distinct stored arrays (parity with get_num_time_series).
function _rust_get_num_time_series(store::RustTimeSeriesStore)
    hashes = Set{Vector{UInt8}}()
    for row in TSS.list_metadata(store.inner)
        push!(hashes, row.data_hash)
    end
    return length(hashes)
end

# Counts of distinct stored arrays (shared series count once) and owners by
# category, matching the metadata-store's `get_time_series_counts`.
function _rust_time_series_counts(store::RustTimeSeriesStore)
    static_hashes = Set{Vector{UInt8}}()
    forecast_hashes = Set{Vector{UInt8}}()
    component_owners = Set{Int}()
    attribute_owners = Set{Int}()
    for row in TSS.list_metadata(store.inner)
        if _rust_is_type(row.time_series_type) <: Forecast
            push!(forecast_hashes, row.data_hash)
        else
            push!(static_hashes, row.data_hash)
        end
        if row.owner_category == "Component"
            push!(component_owners, row.owner_id)
        else
            push!(attribute_owners, row.owner_id)
        end
    end
    return (
        components_with_time_series = length(component_owners),
        supplemental_attributes_with_time_series = length(attribute_owners),
        static_time_series_count = length(static_hashes),
        forecast_count = length(forecast_hashes),
    )
end

# Static-time-series summary DataFrame (parity with the metadata-store version).
function _rust_static_summary_table(store::RustTimeSeriesStore)
    groups = OrderedDict{Tuple, Int}()
    for row in TSS.list_metadata(store.inner)
        _rust_is_type(row.time_series_type) <: StaticTimeSeries || continue
        key = (row.owner_type, row.owner_category, row.name,
            string(nameof(row.time_series_type)), row.initial_timestamp,
            Dates.Millisecond(row.resolution), row.length)
        groups[key] = get(groups, key, 0) + 1
    end
    return DataFrames.DataFrame(;
        owner_type = [k[1] for k in keys(groups)],
        owner_category = [k[2] for k in keys(groups)],
        name = [k[3] for k in keys(groups)],
        time_series_type = [k[4] for k in keys(groups)],
        initial_timestamp = [k[5] for k in keys(groups)],
        resolution = [Dates.canonicalize(k[6]) for k in keys(groups)],
        count = collect(values(groups)),
        time_step_count = [k[7] for k in keys(groups)],
    )
end

# Forecast summary DataFrame (parity with the metadata-store version).
function _rust_forecast_summary_table(store::RustTimeSeriesStore)
    groups = OrderedDict{Tuple, Int}()
    for row in TSS.list_metadata(store.inner)
        _rust_is_type(row.time_series_type) <: Forecast || continue
        key = (row.owner_type, row.owner_category, row.name,
            string(nameof(row.time_series_type)), row.initial_timestamp,
            Dates.Millisecond(row.resolution), Dates.Millisecond(row.horizon),
            Dates.Millisecond(row.interval), row.count)
        groups[key] = get(groups, key, 0) + 1
    end
    return DataFrames.DataFrame(;
        owner_type = [k[1] for k in keys(groups)],
        owner_category = [k[2] for k in keys(groups)],
        name = [k[3] for k in keys(groups)],
        time_series_type = [k[4] for k in keys(groups)],
        initial_timestamp = [k[5] for k in keys(groups)],
        resolution = [Dates.canonicalize(k[6]) for k in keys(groups)],
        count = collect(values(groups)),
        horizon = [Dates.canonicalize(k[7]) for k in keys(groups)],
        interval = [Dates.canonicalize(k[8]) for k in keys(groups)],
        window_count = [k[9] for k in keys(groups)],
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
    for row in TSS.list_metadata(store.inner)
        _rust_is_type(row.time_series_type) <: Forecast || continue
        isnothing(resolution) || row.resolution == resolution || continue
        if !isnothing(interval)
            (row.interval !== nothing && row.interval == interval) || continue
        end
        return ForecastParameters(;
            horizon = Dates.Millisecond(row.horizon),
            initial_timestamp = row.initial_timestamp,
            interval = Dates.Millisecond(row.interval),
            count = row.count,
            resolution = Dates.Millisecond(row.resolution),
        )
    end
    return nothing
end

# Distinct owner ids of the given category that have time series, optionally
# restricted by time series type and resolution.
function _rust_list_owner_ids(
    store::RustTimeSeriesStore,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = _get_owner_category(owner_type)
    ids = Set{Int}()
    for row in TSS.list_metadata(store.inner)
        row.owner_category == category || continue
        if !isnothing(time_series_type)
            _rust_is_type(row.time_series_type) <: time_series_type || continue
        end
        isnothing(resolution) || row.resolution == resolution || continue
        push!(ids, Int(row.owner_id))
    end
    return collect(ids)
end

# (owner_id, metadata) for every time series of the given owner category,
# optionally restricted by time series type and resolution.
function _rust_list_metadata_with_owner(
    store::RustTimeSeriesStore,
    owner_type::Type;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    category = _get_owner_category(owner_type)
    out = NamedTuple[]
    for row in TSS.list_metadata(store.inner)
        row.owner_category == category || continue
        if !isnothing(time_series_type)
            _rust_is_type(row.time_series_type) <: time_series_type || continue
        end
        isnothing(resolution) || row.resolution == resolution || continue
        push!(
            out,
            (owner_id = Int(row.owner_id), metadata = _metadata_from_row(row)),
        )
    end
    return out
end

# Verify all SingleTimeSeries share an initial timestamp and length; return
# `(initial_timestamp, length)` (parity with the metadata-store check).
function _rust_check_consistency(store::RustTimeSeriesStore, ::Type{<:SingleTimeSeries})
    pairs = Set{Tuple{Dates.DateTime, Int}}()
    for row in TSS.list_metadata(store.inner)
        _rust_is_type(row.time_series_type) <: SingleTimeSeries || continue
        push!(pairs, (row.initial_timestamp, row.length))
    end
    isempty(pairs) && return (Dates.DateTime(Dates.Minute(0)), 0)
    if length(pairs) > 1
        throw(
            InvalidValue(
                "There are more than one sets of SingleTimeSeries initial times and lengths: $pairs",
            ),
        )
    end
    return first(pairs)
end

_rust_check_consistency(::RustTimeSeriesStore, ::Type{<:Forecast}) = nothing
