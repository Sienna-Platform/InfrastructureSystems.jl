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

# ---- Element values ---------------------------------------------------------
#
# The store owns the `element_type` encodings and InfraStore.jl implements them
# (`docs/src/reference/element-types.md`, pinned by
# `conformance/element_type_vectors.json`). IS supplies only the two ends: how to
# write one of *its* `FunctionData` values into a row, and which of its types to
# build when reading one back.
#
# Encoding is open dispatch — three methods per type — so an IS value goes into a
# store constructor directly and is packed at the ABI boundary. Decoding is a
# lookup, because it starts from a tag string, so it is a table.

InfraStore.element_type_tag(::AbstractVector{<:LinearFunctionData}) = "linear_function"
InfraStore.element_row_width(::AbstractVector{<:LinearFunctionData}) = 2
function InfraStore.write_element_row!(row, fd::LinearFunctionData)
    row[1] = get_proportional_term(fd)
    row[2] = get_constant_term(fd)
    return
end

InfraStore.element_type_tag(::AbstractVector{<:QuadraticFunctionData}) =
    "quadratic_function"
InfraStore.element_row_width(::AbstractVector{<:QuadraticFunctionData}) = 3
function InfraStore.write_element_row!(row, fd::QuadraticFunctionData)
    row[1] = get_quadratic_term(fd)
    row[2] = get_proportional_term(fd)
    row[3] = get_constant_term(fd)
    return
end

InfraStore.element_type_tag(::AbstractVector{<:PiecewiseLinearData}) = "piecewise_linear"
InfraStore.element_row_width(values::AbstractVector{<:PiecewiseLinearData}) =
    1 + 2 * maximum(fd -> length(get_points(fd)), values; init = 0)
function InfraStore.write_element_row!(row, fd::PiecewiseLinearData)
    pts = get_points(fd)
    row[1] = length(pts)
    for (k, p) in enumerate(pts)
        row[2k] = p.x
        row[2k + 1] = p.y
    end
    return
end

InfraStore.element_type_tag(::AbstractVector{<:PiecewiseStepData}) = "piecewise_step"
function InfraStore.element_row_width(values::AbstractVector{<:PiecewiseStepData})
    widest = maximum(fd -> length(get_x_coords(fd)), values; init = 0)
    return max(2 * widest, 1)
end
function InfraStore.write_element_row!(row, fd::PiecewiseStepData)
    xs = get_x_coords(fd)
    ys = get_y_coords(fd)
    n = length(xs)
    row[1] = n
    row[2:(1 + n)] .= xs
    row[(2 + n):(1 + n + length(ys))] .= ys
    return
end

"""
The IS types a store read decodes composite element values into.

Their constructor signatures are the ones InfraStore.jl's codec calls, so a read
lands directly in IS's own `FunctionData` with no conversion between.
"""
const _IS_ELEMENT_TYPES = (
    linear_function = LinearFunctionData,
    quadratic_function = QuadraticFunctionData,
    piecewise_linear = PiecewiseLinearData,
    piecewise_step = PiecewiseStepData,
)

# Densify a Probabilistic/Scenarios forecast — a SortedDict of
# `(horizon_count, dim1)` window matrices — into the `(dim1, horizon_count,
# count)` array the store's forecast constructors take, in the windows' own
# element type, so a `Probabilistic{Int64}` round-trips as one instead of coming
# back widened to Float64.
function _dense_forecast_array(forecast::Forecast{T}, dim1::Integer) where {T}
    arr = Array{T, 3}(
        undef, dim1, get_horizon_count(forecast), get_count(forecast),
    )
    for (ix, window) in enumerate(values(get_data(forecast)))
        arr[:, :, ix] = transpose(window)
    end
    return arr
end

# ---- Operations (thin delegations to InfraStore) ----------------------

"""
    make_add_batch() -> batch

A client-side staging buffer for [`serialize_single!`](@ref) /
[`serialize_non_sequential!`](@ref), committed with [`commit_batch!`](@ref).
Exists so packages that write stores directly (e.g. a parser emitting a
serialized system) never touch the InfraStore module themselves.
"""
make_add_batch() = InfraStore.AddBatch()

# The bytes one staged array holds in the batch's buffer, which is what drives
# auto-flush. `sizeof` is the answer only for a plain numeric array: a composite
# element type is stored as one pointer per value but staged as a
# `length x element_row_width` matrix of `Float64`, so `sizeof` under-counts it by
# the row width — a factor that is unbounded for ragged piecewise data, and would
# let a block hold gigabytes past the byte threshold before flushing.
_staged_nbytes(values::AbstractArray) = sizeof(values)
_staged_nbytes(values::AbstractArray{<:StaticFunctionData}) = _encoded_nbytes(values)
_staged_nbytes(values::AbstractArray{<:Tuple{Vararg{Float64}}}) = _encoded_nbytes(values)

# `element_row_width` is defined on the flat vector of values the store packs, so
# a forecast's `(horizon, count)` matrix is measured through `vec` (a reshape, not
# a copy).
_encoded_nbytes(values::AbstractArray) =
    length(values) * InfraStore.element_row_width(vec(values)) * sizeof(Float64)

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
                      features=nothing, units=get_units(sts),
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
    features::Union{Nothing, Dict} = nothing,
    units::Union{Nothing, AbstractString} = get_units(sts),
    quantity_kind::Union{Nothing, AbstractString} = get_quantity_kind(sts),
    unit_system::Union{Nothing, AbstractUnitSystem} = get_unit_system(sts),
)
    # `get_array` returns the raw `Array{T, N}` (no TimeArray allocation). The
    # store names the element type from the values and packs them itself.
    values = get_array(sts)
    tss_ts = InfraStore.SingleTimeSeries(
        get_initial_timestamp(sts),
        get_resolution(sts),
        values,
        name,
    )
    InfraStore.add_time_series!(batch, owner_id, owner_type,
        owner_category, tss_ts; features = features, units = units,
        quantity_kind = quantity_kind,
        unit_system = _to_store_unit_system(unit_system))
    # Drives auto-flush; measured as the store packs it, not as Julia holds it.
    return _staged_nbytes(values)
end

"""
    serialize_non_sequential!(batch, owner_id, owner_type, owner_category, name, nts;
                              features=nothing, units=get_units(nts),
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
    features::Union{Nothing, Dict} = nothing,
    units::Union{Nothing, AbstractString} = get_units(nts),
    quantity_kind::Union{Nothing, AbstractString} = get_quantity_kind(nts),
    unit_system::Union{Nothing, AbstractUnitSystem} = get_unit_system(nts),
)
    values = get_array(nts)
    tss_ts = InfraStore.NonSequentialTimeSeries(get_timestamps(nts), values, name)
    InfraStore.add_time_series!(batch, owner_id, owner_type,
        owner_category, tss_ts; features = features, units = units,
        quantity_kind = quantity_kind,
        unit_system = _to_store_unit_system(unit_system))
    # The staged bytes are the encoded array plus the timestamps the association carries.
    return _staged_nbytes(values) + sizeof(get_timestamps(nts))
end

# Rebuild the IS `NonSequentialTimeSeries` from whatever the store handed back,
# however the read was addressed.
_non_sequential_from_store(nts, name::AbstractString) = NonSequentialTimeSeries(
    String(name), nts.timestamps, nts.data;
    units = nts.units, quantity_kind = nts.quantity_kind,
    unit_system = _from_store_unit_system(nts.unit_system),
)

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
Remove exactly the association that a `TimeSeriesKey` names, and nothing else.

The key's `association_id` names one catalog row, so this is the store's
`remove_by_ids!` — a single id-addressed call that deletes that row and no
other. The attribute-addressed removal it replaces was blunter than the
docstring implied: an identity with no interval matches *any* interval, so a
keyed removal could sweep a whole forecast family, and a `nothing` resolution
likewise. Neither is reachable through an id.
"""
function infrastore_remove_time_series!(
    store::Store,
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
)
    # `owner` is an argument in its own right, so the removal is scoped to it:
    # the store confirms the row belongs to `owner` and deletes it in one
    # transaction. Checking here first would be a race — an id survives a
    # reassignment, so a row confirmed by one call can move before the next one
    # deletes it, and the removal would retire the new owner's series.
    try
        InfraStore.remove_by_ids!(
            store.inner, [Int64(get_association_id(key))];
            owner = _infrastore_owner_id_category(owner),
        )
    catch e
        # `catch`-block exception inspection: the core reports both conditions
        # through its own error types, which IS maps to the errors callers
        # dispatch on. The core's orphaned-DST guard is an
        # `InvalidParameterError`, but it is not the only one a removal can
        # raise — an id the core rejects outright is another — and only the guard
        # fires for a `SingleTimeSeries`. So the specific message is claimed only
        # for that case; every other `InvalidParameterError` keeps the core's own
        # message, which names what actually went wrong, under the `ArgumentError`
        # type the accessors contract for.
        if e isa InfraStore.InvalidParameterError
            get_time_series_type(key) <: SingleTimeSeries && throw(
                ArgumentError(
                    "Cannot remove the SingleTimeSeries named by " *
                    "association_id=$(get_association_id(key)) because it is " *
                    "attached to a DeterministicSingleTimeSeries."),
            )
            throw(ArgumentError(e.msg))
        elseif e isa InfraStore.NotFoundError
            throw(
                ArgumentError(
                    "TimeSeriesKey names association_id=$(get_association_id(key)), which " *
                    "is no longer in this store: $(summary(key)) on " *
                    "$(summary(owner)) may already have been removed."),
            )
        elseif e isa InfraStore.OwnerMismatchError
            throw(_not_this_owners_key(owner, key, e))
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
    features::Union{Nothing, Dict} = nothing,
)
    batch = InfraStore.AddBatch()
    staged, _ = _infrastore_stage!(
        batch,
        mgr,
        Dict{Tuple{Dates.Period, Dates.Period}, Any}(),
        owner,
        time_series;
        features = features,
    )
    added = try
        InfraStore.add_time_series_bulk!(mgr.data_store.inner, batch)
    catch e
        _infrastore_rethrow_duplicate(
            e,
            _infrastore_owner_args(owner)[2],
            get_name(time_series),
        )
    end
    # The row is written by the time we get here, so the key is built around the id
    # the catalog actually filed it under.
    return build_key(staged, only(added))
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
    throw(
        ArgumentError(
            "InfraStore backend supports SingleTimeSeries, NonSequentialTimeSeries, " *
            "Deterministic, DeterministicSingleTimeSeries, Probabilistic, and Scenarios " *
            "(requested $T)",
        ),
    )

# An abstract query type names a family rather than a stored type, so it cannot be read
# directly. Resolve it against the catalog first — `infrastore_get_time_series_key` errors
# when nothing matches and when the family is ambiguous for this owner — then read the
# resolved key. `Forecast` needs no method here: its own route already resolves the stored
# forecast type.
function _infrastore_get_time_series_via_key(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features::Union{Nothing, Dict} = nothing,
) where {T <: TimeSeriesData}
    key = infrastore_get_time_series_key(
        owner,
        T,
        name;
        resolution = resolution,
        interval = interval,
        features = features,
    )
    # The key came out of this owner's own listing, so the read is addressed by
    # the store: re-checking the owner would be a round trip that could only
    # confirm what the resolution already established.
    return _get_time_series_by_key(
        _owner_store(owner), key;
        start_time = start_time, len = len, count = count,
    )
end

# `StaticTimeSeries` (and any static subtype without its own route): resolve through the
# key. The `SingleTimeSeries` / `NonSequentialTimeSeries` methods below are more specific
# and still win.
infrastore_get_time_series(
    ::Type{T},
    owner::TimeSeriesOwners,
    name::AbstractString;
    kwargs...,
) where {T <: StaticTimeSeries} =
    _infrastore_get_time_series_via_key(T, owner, name; kwargs...)

# `TimeSeriesData` itself: the widest query, spanning static series and forecasts.
infrastore_get_time_series(
    ::Type{TimeSeriesData},
    owner::TimeSeriesOwners,
    name::AbstractString;
    kwargs...,
) = _infrastore_get_time_series_via_key(TimeSeriesData, owner, name; kwargs...)

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
    features::Union{Nothing, Dict} = nothing,
) where {T <: Forecast} = _infrastore_get_forecast(owner, name;
    time_series_type = T,
    start_time = start_time, len = len, count = count, resolution = resolution,
    interval = interval, features = features)

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
    interval::Union{Nothing, Dates.Period} = nothing,  # rejected when provided
    features::Union{Nothing, Dict} = nothing,
)
    _check_interval_supported(SingleTimeSeries, interval)
    # Resolve the unique series matching a possibly-partial (subset) feature /
    # resolution query, then read it by its exact stored attributes.
    key = infrastore_get_time_series_key(
        owner,
        SingleTimeSeries,
        name;
        resolution = resolution,
        features = features,
    )
    # Store-addressed: `infrastore_get_time_series_key` resolved the key out of
    # this owner's own listing, so its ownership is settled.
    return _infrastore_read_single(
        _owner_store(owner), key; start_time = start_time, len = len,
    )
end

# ---- Key addressing --------------------------------------------------------
# `association_id` is the identity of a stored association: the store mints it,
# never reissues it, and it is the whole of a `TimeSeriesKey`. So a key is
# addressed by its id alone — a name, resolution, interval or feature set is a
# column of the catalog row, never a lookup argument. A key handed to an accessor
# is otherwise taken as valid: nothing probes it for staleness first, and a
# dangling id surfaces as an error from the call that was already committed to
# acting on it.
#
# The exception is the owner. `owner` is an argument in its own right, so an
# accessor that takes both holds the key to it — without that,
# `remove_time_series!(sys, wrong_component, key)` would quietly delete a series
# off some other component. A key carries no owner (an owner cached on one would
# be a field to go stale when a series is reassigned, which is the whole reason a
# key is only its id), so the owner is passed INTO the store call rather than
# checked beside it: `read_by_id(...; owner)` and `remove_by_ids!(...; owner)`
# confirm and act as one operation, raising `OwnerMismatchError`, which the
# accessors map to their public `ArgumentError`.
#
# Checking first in a call of IS's own would be both slower and wrong. Slower
# because a `get_metadata_by_id` is a second round trip on every keyed accessor.
# Wrong because an id survives a reassignment: between the call that confirmed the
# owner and the call that acts, the row can move to another owner, and the removal
# then retires *that* owner's series — exactly what checking the owner was for.
# Every keyed accessor is therefore back to **one** store call, and the race is
# closed rather than narrowed.
#
# The by-name reads resolve their key out of a `list_metadata` scoped to one
# owner, which is where ownership is established; they take the `Store`-addressed
# read below, which sets no guard. Re-guarding would only re-confirm what the
# listing already said.
#
# `read_by_id` takes the slice as well as the id: it resolves `start_time` / `len`
# / `count` against the row its own primary-key lookup returned, so IS neither
# computes a time range nor fetches a grid to compute one from. `remove_by_ids!`
# is the same for removal, and `get_metadata_by_id` remains the catalog-row
# accessor (the content hash) for callers that want the row rather than the data —
# there the row IS the answer, so checking its owner is not a second call.
#
# The window arithmetic and its bounds checks live in the core: the store resolves
# `start_time` / `len` / `count` against the row it just looked up, and refuses a
# window that does not fit rather than clamping to one that does. IS's own copy of
# that arithmetic is gone, so there is exactly one read path and one place the
# window is resolved.

# The catalog row `id` names. `nothing` from the core means the row is gone, which
# is an error here: the caller is already committed to acting on it.
function _resolve_association(store::Store, key::TimeSeriesKey)
    id = get_association_id(key)
    row = InfraStore.get_metadata_by_id(store.inner, Int64(id))
    isnothing(row) && throw(
        ArgumentError(
            "TimeSeriesKey names association_id=$id, which is no longer in this " *
            "store: it was removed after the key was obtained.",
        ),
    )
    return row
end

# The `ArgumentError` a key that does not belong to `owner` raises, whether the
# store said so (the guarded read and removal) or the row did (the catalog-row
# accessors, which hold the row already). `detail` is what said it.
_not_this_owners_key(owner::TimeSeriesOwners, key::TimeSeriesKey, detail) = ArgumentError(
    "TimeSeriesKey (association_id=$(get_association_id(key))) does not name a " *
    "time series of $(summary(owner)): $(detail). Pass the owner it belongs to, " *
    "or look one up on this owner with list_metadata.",
)

# Confirm the association `key` names is attached to `owner`, against a catalog
# row the caller has already fetched. The category matters as well as the id,
# since a component and a supplemental attribute can share an integer id.
#
# Only for the accessors that want the row itself. Anything that *acts* on the
# association passes `owner` into the store call instead — see
# `_read_association_by_id` — because a check and an act in two calls have a
# window between them that a reassignment fits through.
function _check_association_owner(owner::TimeSeriesOwners, key::TimeSeriesKey, row)
    owner_id, category = _infrastore_owner_id_category(owner)
    (row.owner_id == owner_id && row.owner_category == category) && return row
    throw(
        _not_this_owners_key(
            owner, key,
            "it names '$(row.name)', which belongs to owner id=$(row.owner_id)",
        ),
    )
end

"The store the owner's time series manager holds."
_owner_store(owner::TimeSeriesOwners) =
    _get_time_series_manager_or_throw(owner).data_store

# The store an owner's manager holds, and the row `key`'s id resolves to in it —
# for the catalog-row accessors, which want the row itself rather than the data.
function _store_and_association(owner::TimeSeriesOwners, key::TimeSeriesKey)
    store = _owner_store(owner)
    return (store, _check_association_owner(owner, key, _resolve_association(store, key)))
end

# `len` and `count` are step and window COUNTS, and the store takes them as
# `UInt64`: a negative one fails in the ccall marshalling with an `InexactError`
# that names neither the argument nor the accessor, so the sign is checked here.
# Only the sign — whether a window of a legal size fits the row is the core's
# answer, and it gives the specific one.
_check_window_count(::Symbol, ::Nothing) = nothing

function _check_window_count(name::Symbol, n::Integer)
    n < 1 && throw(ArgumentError("`$name` must be >= 1; got $n"))
    return
end

# The association `key` names, or the window of it the accessor's arguments name,
# in ONE id-addressed call: no catalog round trip, and no attribute off the key.
# The core resolves the window against the row its primary-key lookup returned
# and rejects one that does not fit; it throws `NotFoundError` for a dangling id,
# which the public accessors map to an `ArgumentError`.
#
# Addressed by `Store`, so nothing is held to an owner — this is the read for a
# key whose owner is already established (one resolved from that owner's own
# listing). The `TimeSeriesOwners` method below is the guarded one.
_read_association_by_id(
    store::Store,
    key::TimeSeriesKey;
    start_time = nothing,
    len = nothing,
    count = nothing,
) = _read_association_by_id(
    store, key, nothing; start_time = start_time, len = len, count = count,
)

# The owner-guarded read. `owner` goes INTO the store call: the core takes the
# row's owner off the very row it materializes the values from, so the guard is
# free and cannot disagree with what is read. A `get_metadata_by_id` here instead
# would be both a second round trip and a weaker answer — it describes the row as
# it was, and an id survives a reassignment.
_read_association_by_id(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey;
    start_time = nothing,
    len = nothing,
    count = nothing,
) = _read_association_by_id(
    _owner_store(owner), key, owner;
    start_time = start_time, len = len, count = count,
)

function _read_association_by_id(
    store::Store,
    key::TimeSeriesKey,
    owner::Union{Nothing, TimeSeriesOwners};
    start_time = nothing,
    len = nothing,
    count = nothing,
)
    _check_window_count(:len, len)
    _check_window_count(:count, count)
    try
        return InfraStore.read_by_id(
            store.inner, Int64(get_association_id(key));
            start_time = start_time, len = len, count = count,
            owner = isnothing(owner) ? nothing : _infrastore_owner_id_category(owner),
            types = _IS_ELEMENT_TYPES,
        )
    catch e
        # `catch`-block exception inspection: the window checks moved into the
        # core with the read, so the caller's out-of-range `start_time` / `len` /
        # `count` now arrives as the store's own error. Its message is the
        # specific one — which grid, which index, how many are stored — so it is
        # carried through; only the type is remapped, to keep the accessors'
        # public `ArgumentError` contract.
        e isa InfraStore.InvalidParameterError && throw(ArgumentError(e.msg))
        # Only reachable on the owner-addressed path: a `nothing` owner sends no
        # owner into the read, so the core has nothing to mismatch it against.
        # Guarded anyway, so that if it ever does arrive here the handler reports
        # the store's error rather than raising a `MethodError` over it.
        e isa InfraStore.OwnerMismatchError && !isnothing(owner) &&
            throw(_not_this_owners_key(owner, key, e.msg))
        rethrow()
    end
end

# Rebuild the IS `SingleTimeSeries` from whatever the store handed back, however
# the read was addressed.
_single_from_store(sts, name::AbstractString) = SingleTimeSeries(
    String(name), sts.initial_timestamp, sts.resolution, sts.data;
    units = sts.units, quantity_kind = sts.quantity_kind,
    unit_system = _from_store_unit_system(sts.unit_system),
)

# Key-addressed SingleTimeSeries read: one store call, whether or not it slices
# (plus the owner check, when addressed by owner). The store resolves
# `(start_time, len)` against the grid on the row its own primary-key lookup
# returned, refuses a window that does not fit, and reads the half-open
# `[start, start + n·resolution)` steps — only those are read and decoded.
function _infrastore_read_single(
    target::KeyedReadTarget,
    key::TimeSeriesKey{<:SingleTimeSeries};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    sts = _read_association_by_id(
        target, key; start_time = start_time, len = len,
    )::InfraStore.SingleTimeSeries
    return _single_from_store(sts, sts.name)
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
    interval::Union{Nothing, Dates.Period} = nothing,  # rejected when provided
    features::Union{Nothing, Dict} = nothing,
)
    _check_interval_supported(NonSequentialTimeSeries, interval)
    # Resolve the unique series matching a possibly-partial (subset) feature query,
    # then read it by its exact stored attributes.
    key = infrastore_get_time_series_key(
        owner, NonSequentialTimeSeries, name; features = features)
    return _infrastore_read_non_sequential(
        _owner_store(owner), key; start_time = start_time, len = len,
    )
end

# Key-addressed NonSequentialTimeSeries read: one call, whether or not it slices.
# `len` is a POINT COUNT, and turning it into an end timestamp needs to know which
# irregular timestamps exist — which is exactly what the store's own row carries,
# so it does that itself. IS used to read the whole suffix (behind a far-future
# sentinel, since the store has no "no upper bound") and slice client-side; now
# only the requested points cross.
function _infrastore_read_non_sequential(
    target::KeyedReadTarget,
    key::TimeSeriesKey{<:NonSequentialTimeSeries};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
)
    nts = _read_association_by_id(
        target, key; start_time = start_time, len = len,
    )::InfraStore.NonSequentialTimeSeries
    return _non_sequential_from_store(nts, nts.name)
end

# ---- Bulk staging ----------------------------------------------------------
# The bulk-add fast path stages every association onto a `InfraStore.AddBatch` and
# commits once: one metadata transaction, and the backend packs the arrays into
# batch-sized datasets with whole-chunk writes (no per-add read-modify-write).

"""
Commit a staged `AddBatch` to the store as one all-or-nothing bulk add, returning
the catalog `id` the store filed each request under, in the order they were staged.

The backend packs the arrays into batch-sized datasets written whole-chunk, so
this is materially cheaper than the same adds issued one at a time — which is why
the client-side buffer exists even though the store now has transactions.

Each returned id is the `association_id` the catalog minted for that row. That id
is the reason the write, not the staging, is where a `TimeSeriesKey` can first be
built: the store owns the id stream, so nothing before this call knows what a
staged association will be filed under.
"""
function _infrastore_commit_batch!(mgr::AbstractTimeSeriesManager, batch)
    added = try
        InfraStore.add_time_series_bulk!(mgr.data_store.inner, batch)
    catch e
        _infrastore_is_duplicate_error(e) && throw(
            ArgumentError("Time series data with duplicate attributes are already stored"),
        )
        rethrow()
    end
    flush!(mgr.data_store)
    return added
end

"""
Stage one `(owner, time_series)` association onto `batch`, applying the same
validation as the per-add path, and return its [`StagedKey`](@ref) together with
the bytes it buffered. The write happens when the batch is committed, and only
then does the association have an id to build a `TimeSeriesKey` around — see
[`build_key`](@ref). `params_cache` carries the forecast window parameters per
`(resolution, interval)` group so staged forecasts are checked for compatibility
against both the store and each other with one catalog query per group.
"""
function _infrastore_stage!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features::Union{Nothing, Dict} = nothing,
)
    throw_if_does_not_support_time_series(owner)
    check_time_series_data(time_series)
    return _infrastore_stage_data!(
        batch,
        mgr,
        params_cache,
        owner,
        time_series;
        features = features,
    )
end

# The type parameter a key gets for `ts`: its kind carrying the value element
# type, rank left free — the rank belongs to the stored array, not to a reference
# to it. This is what `_key_from_row` derives from a catalog row too, so a key
# handed back by a write and a key listed from the catalog for the same series are
# the same type as well as equal.
_key_type(ts::TimeSeriesData) = Base.typename(typeof(ts)).wrapper{eltype(ts)}

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    ::AbstractDict,
    owner::TimeSeriesOwners,
    time_series::SingleTimeSeries;
    features::Union{Nothing, Dict} = nothing,
)
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(time_series)
    feats = _infrastore_features(features)
    nbytes = serialize_single!(batch, owner_id, owner_type, category, name,
        time_series; features = feats)
    staged = StagedKey{_key_type(time_series)}()
    return staged, nbytes
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    ::AbstractDict,
    owner::TimeSeriesOwners,
    time_series::NonSequentialTimeSeries;
    features::Union{Nothing, Dict} = nothing,
)
    owner_id, owner_type, category = _infrastore_owner_args(owner)
    name = get_name(time_series)
    feats = _infrastore_features(features)
    nbytes = serialize_non_sequential!(batch, owner_id, owner_type, category, name,
        time_series; features = feats)
    staged = StagedKey{_key_type(time_series)}()
    return staged, nbytes
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
# `(StagedKey, staged_nbytes)` pair around it are shared. `build(initial,
# resolution, horizon, interval, name)` returns that object together
# with its window count, which is the one field the callers disagree on.
function _infrastore_stage_forecast!(
    build,
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    ts::Forecast;
    features::Union{Nothing, Dict} = nothing,
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
    staged = StagedKey{_key_type(ts)}()
    # `obj.data` is the dense window array the batch buffers; its encoded byte size
    # drives auto-flush.
    return staged, _staged_nbytes(obj.data)
end

function _infrastore_stage_data!(
    batch::InfraStore.AddBatch,
    mgr::TimeSeriesManager,
    params_cache::AbstractDict,
    owner::TimeSeriesOwners,
    ts::Probabilistic;
    features::Union{Nothing, Dict} = nothing,
)
    return _infrastore_stage_forecast!(
        batch, mgr, params_cache, owner, ts; features = features,
    ) do initial, resolution, horizon, interval, name
        prob = InfraStore.Probabilistic(initial, resolution, horizon, interval,
            get_count(ts), Float64.(get_percentiles(ts)),
            _dense_forecast_array(ts, length(get_percentiles(ts))), name;
            units = get_units(ts),
            quantity_kind = get_quantity_kind(ts),
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
    features::Union{Nothing, Dict} = nothing,
)
    return _infrastore_stage_forecast!(
        batch, mgr, params_cache, owner, ts; features = features,
    ) do initial, resolution, horizon, interval, name
        # (horizon_count, count) for scalars; (horizon_count, count, k) tagged
        # with the element type for FunctionData and NTuple windows.
        # `(horizon_count, count)` of whatever the windows hold; a composite
        # element type is packed across a further axis by the store.
        windows = collect(values(get_data(ts)))
        det = InfraStore.Deterministic(initial, resolution, horizon, interval,
            length(windows), reduce(hcat, windows), name;
            units = get_units(ts),
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
    features::Union{Nothing, Dict} = nothing,
)
    return _infrastore_stage_forecast!(
        batch, mgr, params_cache, owner, ts; features = features,
    ) do initial, resolution, horizon, interval, name
        scen = InfraStore.Scenarios(initial, resolution, horizon, interval,
            get_count(ts), _dense_forecast_array(ts, get_scenario_count(ts)), name;
            units = get_units(ts), quantity_kind = get_quantity_kind(ts),
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
    features::Union{Nothing, Dict} = nothing,
) = error(
    "InfraStore backend supports SingleTimeSeries, NonSequentialTimeSeries, " *
    "Deterministic, Probabilistic, and Scenarios (got $(typeof(ts))). A " *
    "DeterministicSingleTimeSeries is derived in-store with " *
    "transform_single_time_series!.",
)

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

# Key-addressed forecast read: the forecast `key` names, reconstructed as its
# STORED type, honoring `start_time` / `count` on the window axis and `len` on
# the horizon. `read_by_id` resolves the window on the row its own primary-key
# lookup returned, so nothing here computes a time range or fetches a grid to
# compute one from. Addressed by owner (checked) or by store (already-owned key),
# like the static readers.
function _infrastore_read_forecast(
    target::KeyedReadTarget,
    key::TimeSeriesKey{<:Forecast};
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
)
    # `count` is checked by the read below; `len` never reaches the store on this
    # path — it truncates the windows here — so it is checked here.
    _check_window_count(:len, len)
    raw = _read_association_by_id(
        target, key; start_time = start_time, count = count,
    )
    return _forecast_from_store(raw, String(raw.name), len)
end

"""Reconstruct a forecast from the InfraStore store (matches the STORED type),
honoring `start_time` / `count` slicing on the window axis.

The forecast is resolved by name against `owner`'s own listing and then read by
the key that resolution returns — two store calls, and the second does not
re-check an ownership the listing established."""
function _infrastore_get_forecast(
    owner, name = nothing;
    time_series_type::Type{<:Forecast} = Forecast,
    start_time::Union{Nothing, Dates.DateTime} = nothing,
    len::Union{Nothing, Int} = nothing,
    count::Union{Nothing, Int} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features::Union{Nothing, Dict} = nothing,
)
    # Resolve the unique forecast of the requested type matching a possibly-partial
    # (subset) feature / resolution / interval query, then read the key that names.
    # `interval` matters when one series name carries several forecasts that differ
    # only by interval (`transform_single_time_series!` with `delete_existing =
    # false`); without it the lookup is ambiguous. The type is part of the lookup
    # too: one name can carry a Deterministic and a Probabilistic. Resolving to a
    # key and reading that keeps a single read path — an attribute-addressed
    # forecast read would need the interval pinned to avoid matching more than one
    # of those siblings, which the id cannot match at all.
    matched = infrastore_get_time_series_key(
        owner, time_series_type, name;
        resolution = resolution, interval = interval, features = features,
    )
    return _infrastore_read_forecast(
        _owner_store(owner), matched;
        start_time = start_time, len = len, count = count,
    )
end

# `len`, when given, truncates a window to its first `len` horizon steps (the
# horizon is the leading axis of a window vector or matrix).
_truncate_window(w, ::Nothing) = w
_truncate_window(w::AbstractVector, len::Int) = w[1:len]
_truncate_window(w::AbstractMatrix, len::Int) = w[1:len, :]

# A Probabilistic/Scenarios window is stored `(member, horizon)` and transposed to the
# `(horizon, member)` matrix IS hands users.
_member_window(data::AbstractArray{<:Any, 3}, i) = permutedims(@view data[:, :, i])

# `Probabilistic` and `Scenarios` windows are per-member scalars: the stored array is
# handed back in its own element type (any scalar dtype), but an encoded element type
# (FunctionData / NTuple rows, written by another InfraStore client) has no IS member
# window shape, so name it rather than let the reconstruction mis-slice it.
function _check_member_window_type(forecast_type, name, element_type)
    InfraStore.is_composite_element_type(element_type) || return nothing
    throw(
        ArgumentError(
            "$forecast_type '$name' is stored with element type $element_type; IS reads " *
            "$forecast_type windows as per-member scalar matrices only. It was likely " *
            "written by another InfraStore client.",
        ),
    )
end

# Reconstruct a forecast read from the store as its user-facing type. Every
# InfraStore read below is already sliced to the requested window range.
# ---- Forecast decoding -----------------------------------------------------
# Decoding is split from fetching so both addressings share it: the keyed read
# hands over what one `read_by_id` returned, the by-name read what an
# attribute-addressed `get_time_series` returned, and the same methods below
# turn either into the IS forecast. Dispatch is on the `InfraStore` struct the
# store built, which already names the stored type.

# Per-window horizon step count of a decoded forecast, for validating `len`
# against the shape actually returned rather than against a catalog row.
_store_horizon_count(d::InfraStore.Deterministic) = size(d.data, 1)
_store_horizon_count(p::InfraStore.Probabilistic) = size(p.data, 2)
_store_horizon_count(s::InfraStore.Scenarios) = size(s.data, 2)

# `len` truncates each window to its first `len` steps; validated against the
# horizon here rather than letting the slice fail with a BoundsError (or
# silently return empty windows for `len = 0`), matching the static read path.
_check_forecast_len(_raw, ::Nothing) = nothing

function _check_forecast_len(raw, len::Int)
    horizon_count = _store_horizon_count(raw)
    (len < 1 || len > horizon_count) && throw(
        ArgumentError(
            "requested len=$len is outside the forecast horizon of $horizon_count steps",
        ),
    )
    return nothing
end

# A `Deterministic`'s decoded values are the `(horizon_count, count)` matrix whose
# columns are its windows. A read hands back a higher-rank array when the row's
# `element_type` did not decode to the values it was packed from — the packing
# axis is still there, and slicing a column off it would either fail or, worse,
# hand back the wrong numbers. That is a storage inconsistency, so it is named
# here rather than left to surface as a bare `BoundsError` from the slice.
_check_deterministic_window_shape(::AbstractMatrix, ::String, _element_type) = nothing

_check_deterministic_window_shape(data::AbstractArray, name::String, element_type) =
    throw(
        ArgumentError(
            "Deterministic '$name' read back as a $(ndims(data))-dimensional array " *
            "with element type $(something(element_type, "f64")); a Deterministic's " *
            "windows are the columns of a (horizon_count, count) matrix. Its stored " *
            "element type does not describe the values it holds.",
        ),
    )

# A DeterministicSingleTimeSeries is an internal storage optimization: it shares
# the underlying SingleTimeSeries array instead of materializing the overlapping
# windows. On read it is always returned as a regular `Deterministic` — the
# InfraStore store expands the shared array into the canonical
# (horizon_count, count) window matrix (honoring the requested window) — so there
# is no DST method here, and none is reachable.
#
# This does NOT cost the storage optimization on a copy: `copy_time_series!`
# clones the association row inside the store, so the stored type survives
# without ever round-tripping through these Julia objects.
function _forecast_from_store(d::InfraStore.Deterministic, name::String, len)
    _check_forecast_len(d, len)
    _check_deterministic_window_shape(d.data, name, d.element_type)
    # Resolved once per read: the tag is the same for every window.
    # `d.data` is `(horizon_count, count)` of values, decoded by the read, so a
    # window is a column of it. Materialized, not a view: the window becomes the
    # `Vector` a `Deterministic`'s SortedDict holds, and a `SubArray` there would
    # keep the whole forecast array alive behind every window.
    window(i) = _truncate_window(d.data[:, i], len)
    data = _assemble_forecast_windows(d.initial_timestamp, d.interval, d.count, window)
    return Deterministic(; name = name, data = data,
        resolution = d.resolution, interval = d.interval, units = d.units,
        quantity_kind = d.quantity_kind,
        unit_system = _from_store_unit_system(d.unit_system))
end

# `.data` is the canonical (percentile_count, horizon_count, count) array.
function _forecast_from_store(p::InfraStore.Probabilistic, name::String, len)
    _check_forecast_len(p, len)
    _check_member_window_type(Probabilistic, name, p.element_type)
    window(i) = _truncate_window(_member_window(p.data, i), len)
    data = _assemble_forecast_windows(p.initial_timestamp, p.interval, p.count, window)
    # The positional constructor infers `{T, N}` from the windows; the keyword form pins
    # `Matrix{Float64}`.
    return Probabilistic(
        name, data, p.percentiles, p.resolution, p.interval;
        units = p.units, quantity_kind = p.quantity_kind,
        unit_system = _from_store_unit_system(p.unit_system),
    )
end

# `.data` is the canonical (scenario_count, horizon_count, count) array.
function _forecast_from_store(s_ts::InfraStore.Scenarios, name::String, len)
    _check_forecast_len(s_ts, len)
    _check_member_window_type(Scenarios, name, s_ts.element_type)
    window(i) = _truncate_window(_member_window(s_ts.data, i), len)
    data = _assemble_forecast_windows(
        s_ts.initial_timestamp, s_ts.interval, s_ts.count, window,
    )
    return Scenarios(
        name, data, s_ts.scenario_count, s_ts.resolution, s_ts.interval;
        units = s_ts.units, quantity_kind = s_ts.quantity_kind,
        unit_system = _from_store_unit_system(s_ts.unit_system),
    )
end

_forecast_from_store(raw, name::String, _len) =
    error("unreachable: $name resolved to unexpected stored data $(typeof(raw))")

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
#
# A reader hands back the stored packing — it is the per-timestamp path, where a
# decode per group would be a cost in the loop it exists to make cheap — so this
# is where the element type is resolved for a reader window.
_decode_forecast_reader_window(::Type{<:Probabilistic}, raw, _element_type) =
    permutedims(raw)

_decode_forecast_reader_window(::Type{<:Scenarios}, raw, _element_type) = permutedims(raw)

_decode_forecast_reader_window(::Type{<:AbstractDeterministic}, raw, element_type) =
    InfraStore.decode_element_values(
        raw, something(element_type, "f64"); types = _IS_ELEMENT_TYPES,
    )

_decode_forecast_reader_window(::Type{T}, raw, _element_type) where {T <: Forecast} =
    throw(ArgumentError("InfraStore backend cannot decode a window of forecast type $T"))

"""
One forecast in a [`ForecastReader`], bound to its owner. `slot` is the 1-based
index of the deduplicated window read backing this entry; entries that share a
forecast array (and read plan) report the same `slot`.
"""
struct ForecastReaderEntry
    owner::TimeSeriesOwners
    key::TimeSeriesKey{<:Forecast}
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
    element_types::Vector{Union{Nothing, String}}
    "Per-slot materialized window cache; reset on each read."
    windows::Vector{Any}
    has_read::Bool
end

# The metadata row behind each of a reader's entries, in entry order — ONE core
# catalog query for the whole reader, addressed by the association ids its
# entries carry. `list_metadata_by_ids` answers one row per id asked for, in the
# order asked, and throws if any id has gone stale (none can here: the reader
# holds the store's own rows).
_infrastore_reader_metadata(store::Store, ids::Vector{Int64}) =
    InfraStore.list_metadata_by_ids(store.inner, ids)

# Build a reader from the store. `id_to_owner(owner_id::Int, category::String)`
# resolves each entry's owner object (the system holds the owner maps). Per-entry
# metadata (owner, key, element_type) is resolved once here, off the read path.
function infrastore_build_forecast_reader(
    store::Store,
    id_to_owner,
    ::Type{T};
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features::Union{Nothing, Dict} = nothing,
) where {T <: Forecast}
    inner = InfraStore.build_forecast_reader(store.inner, _tss_forecast_type(T);
        resolution = resolution, name = name, features = features)
    tss_entries = InfraStore.forecast_entries(inner)
    metas = _infrastore_reader_metadata(store, Int64[e.id for e in tss_entries])
    n = length(tss_entries)
    entries = Vector{ForecastReaderEntry}(undef, n)
    element_types = Vector{Union{Nothing, String}}(undef, n)
    for (i, (e, fmeta)) in enumerate(zip(tss_entries, metas))
        owner = id_to_owner(Int(fmeta.owner_id), fmeta.owner_category)
        element_types[i] = fmeta.element_type
        # `e.slot` is 0-based in the InfraStore store; carry it 1-based for Julia.
        entries[i] = ForecastReaderEntry(owner, _key_from_row(fmeta), e.slot + 1)
    end
    windows = Vector{Any}(nothing, InfraStore.forecast_num_slots(inner))
    return ForecastReader{T}(inner, store, entries, element_types, windows, false)
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
        _decode_forecast_reader_window(T, raw, reader.element_types[entry_index])
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
    key::TimeSeriesKey{<:SingleTimeSeries}
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
    element_types::Vector{Union{Nothing, String}}
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
    features::Union{Nothing, Dict} = nothing,
)
    inner = InfraStore.build_static_reader(store.inner;
        resolution = resolution, name = name, features = features)
    entries = StaticTimeSeriesReaderEntry[]
    element_types = Union{Nothing, String}[]
    groups = InfraStore.static_groups(inner)
    metas = _infrastore_reader_metadata(
        store,
        Int64[id for group in groups for id in group.ids],
    )
    i = 0
    for (gi, group) in enumerate(groups)
        for col in eachindex(group.ids)
            i += 1
            smeta = metas[i]
            owner = id_to_owner(Int(smeta.owner_id), smeta.owner_category)
            push!(
                entries,
                StaticTimeSeriesReaderEntry(owner, _key_from_row(smeta), gi, col),
            )
            push!(element_types, smeta.element_type)
        end
    end
    values = Vector{Any}(nothing, length(groups))
    return StaticTimeSeriesReader(
        inner, store, entries, element_types, values, false,
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
        vals, entry.column, reader.element_types[entry_index],
    )
end

# One entry's value out of its group's materialized array. A vector group is
# scalar data (one value per column); a higher-rank group is one of two things,
# told apart by the tag rather than by the rank:
#   - a composite element type — one element row per column, decoded through the
#     entry's encoding (same scheme as `_decode_static_values`, at `len == 1`);
#   - a multidimensional scalar series — a `SingleTimeSeries{Float64, N}` holds an
#     `N-1`-dimensional slice per step, and there is nothing to decode, so the
#     slice *is* the value. Decoding one would hand back the slice unchanged and
#     then `only` it, which throws for every width above 1.
_static_group_element(vals::AbstractVector, column::Integer, _element_type) =
    vals[column]

function _static_group_element(vals::AbstractArray, column::Integer, element_type)
    colons = ntuple(_ -> Colon(), ndims(vals) - 1)
    slice = vals[column, colons...]
    InfraStore.is_composite_element_type(element_type) || return slice
    return only(
        InfraStore.decode_element_values(
            reshape(slice, 1, :), element_type; types = _IS_ELEMENT_TYPES,
        ),
    )
end

"""Route a narrowed `has_time_series` query to the InfraStore store — the general
catalog filter, serving every query the owner-scoped probe in `infrastore_has_any`
cannot. Honors partial (subset) feature / resolution queries: matches if any stored
series of type `T` carries at least the requested features. Each of `name`,
`resolution`, `interval`, and `features` is optional; `name = nothing` probes across
all names. `mgr` is the caller's already-resolved manager: the public entry point
null-checks one before reaching here, so re-resolving it would be a second lookup per
probe."""
function infrastore_has_time_series(
    ::Type{T},
    mgr::TimeSeriesManager,
    owner::TimeSeriesOwners,
    name::Union{Nothing, AbstractString};
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features::Union{Nothing, Dict} = nothing,
) where {T <: TimeSeriesData}
    _check_interval_supported(T, interval)
    store = mgr.data_store::Store
    owner_id, category = _infrastore_owner_id_category(owner)
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

# `SingleTimeSeries{Float64, 1}` -> `SingleTimeSeries`; a UnionAll is returned as is. A
# `Union` is normalized member-wise, so a parameterized concrete inside one is narrowed
# like a bare one — `Union{SingleTimeSeries{Float64, 1}, Probabilistic}` must not quietly
# match nothing. A `Union` type's own type is `Union`, which is what separates the two
# methods.
_unparameterized_type(u::Union) =
    Union{map(_unparameterized_type, Base.uniontypes(u))...}

_unparameterized_type(::Type{T}) where {T} = Base.typename(T).wrapper

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

# The query type as the store answers it. Both normalizations are pure widenings, and
# both are constants per query type:
#
#   - a parameterized concrete (`SingleTimeSeries{Float64, 1}`, i.e. `typeof(ts)`) matches
#     the same rows as its UnionAll, because the catalog does not key on the element type
#     — the parameters can only restate what the stored array is, never select between
#     arrays;
#   - a `Deterministic` query also matches a `DeterministicSingleTimeSeries`, which reads
#     back as a `Deterministic`. DST is `Deterministic`'s sibling under
#     `AbstractDeterministic` rather than its subtype, so widening to their common parent
#     is how that rule is stated in the type domain rather than as a special case in the
#     comparison below.
#
# A `DeterministicSingleTimeSeries` query is not widened, and so still matches DST alone.
_infrastore_query_bound(::Type{T}) where {T} = _unparameterized_type(T)

_infrastore_query_bound(u::Union) = _unparameterized_type(u)

_infrastore_query_bound(::Type{<:Deterministic}) = AbstractDeterministic

# Subtyping, with dispatch rather than a `<:` expression deciding it: a row type that is
# a subtype of the (normalized) query type selects the first method. Both answers are
# constants, so a query type known at compile time folds the match away entirely.
_infrastore_matches_bound(::Type{<:B}, ::Type{B}) where {B} = true

_infrastore_matches_bound(::Type, ::Type) = false

# Whether a stored row of concrete type `R` satisfies a query for type `Q`. Defined here
# rather than beside the other row helpers because `_infrastore_query_types` generates
# against it, and a generated function may only call methods that already exist when it
# is defined.
_infrastore_type_matches(::Type{R}, ::Type{Q}) where {R <: TimeSeriesData, Q} =
    _infrastore_matches_bound(R, _infrastore_query_bound(Q))

# The stored InfraStore types a query for `T` should match, under the same
# `Deterministic`-matches-DST semantics as `_infrastore_type_matches`. `AllStoredTypes()`
# / `NoStoredTypes()` for the two degenerate answers; otherwise a non-empty tuple.
_infrastore_query_types(::Nothing) = AllStoredTypes()

# The answer is a pure function of the query type, so compute it once per `T` at compile
# time and splice in the literal. `@generated` rather than a table of baked methods
# because the answer must be constant for *every* spelling a caller can pass — including
# parameterized concretes (`SingleTimeSeries{Float64, 1}`) and `Union`s, neither of which
# is enumerable up front and both of which a method table would leave on a ~2 µs runtime
# match loop, real money on the `has_time_series` per-component hot path.
@generated function _infrastore_query_types(::Type{T}) where {T <: TimeSeriesData}
    types = Tuple(c for (c, k) in _INFRASTORE_TYPE_PAIRS if _infrastore_type_matches(k, T))
    length(types) == length(_INFRASTORE_TYPE_PAIRS) && return :(AllStoredTypes())
    isempty(types) && return :(NoStoredTypes())
    collapsed = _infrastore_collapse_family(types)
    return :($collapsed)
end

# The single InfraStore type to push into the core `list_metadata` filter for a query
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
function infrastore_has_any(mgr::TimeSeriesManager, owner; time_series_type = nothing)
    store = mgr.data_store::Store
    owner_id, category = _infrastore_owner_id_category(owner)
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

# The IS time series type named by a catalog row's `time_series_type` string,
# for deserializing a key that travels as (id, type).
_time_series_type_from_name(name::AbstractString) = _infrastore_is_type(Symbol(name))

# The IS counterpart of a store value type. The four composite ones are the
# types `InfraStore.DEFAULT_ELEMENT_TYPES` decodes into and IS substitutes its
# own `FunctionData` for; everything else — the scalar dtypes, and the `NTuple`s
# a `tuple(N,f64)` row decodes to — is already the type IS uses.
_is_element_type(::Type{InfraStore.LinearFunction}) = LinearFunctionData
_is_element_type(::Type{InfraStore.QuadraticFunction}) = QuadraticFunctionData
_is_element_type(::Type{InfraStore.PiecewiseLinear}) = PiecewiseLinearData
_is_element_type(::Type{InfraStore.PiecewiseStep}) = PiecewiseStepData
_is_element_type(::Type{T}) where {T} = T

# The IS value element type a catalog row's values decode to — the `T` of a
# `TimeSeriesData{T}`, and so of the `TimeSeriesKey{<:TimeSeriesData{T}}` naming
# the series.
#
# Read off the row's own `time_series_type`, which the store has already resolved
# its `element_type` string into (`InfraStore.SingleTimeSeries{PiecewiseLinear,
# 1}` for a `piecewise_linear` row). That leaves only store type -> IS type to
# translate, over types InfraStore exports, and keeps the `element_type`
# vocabulary — which spellings are composite, which dtype each names — inside the
# store, where it is owned: IS never parses the tag, so a spelling added or
# respelled there needs no matching edit here.
#
# A row whose type the store left unparameterized is one whose `element_type`
# this version of the store does not recognize; its values come back as the raw
# numbers they are stored as, which is `Float64` unless something says otherwise.
_element_value_type(::Type{<:InfraStore.SingleTimeSeries{T}}) where {T} =
    _is_element_type(T)
_element_value_type(::Type{<:InfraStore.NonSequentialTimeSeries{T}}) where {T} =
    _is_element_type(T)
_element_value_type(::Type{<:InfraStore.Deterministic{T}}) where {T} =
    _is_element_type(T)
_element_value_type(::Type{<:InfraStore.DeterministicSingleTimeSeries{T}}) where {T} =
    _is_element_type(T)
_element_value_type(::Type{<:InfraStore.Probabilistic{T}}) where {T} =
    _is_element_type(T)
_element_value_type(::Type{<:InfraStore.Scenarios{T}}) where {T} = _is_element_type(T)
_element_value_type(::Type) = Float64

# Build the matching IS `TimeSeriesKey` from a catalog row — a `list_metadata`
# row, which is the store's one listing shape and carries the `id` a key is
# addressed by. A key is the id plus the stored type; every other column of the
# row stays on the row, where a caller reads it without risk of the two drifting.
#
# The type parameter carries the *value* element type as well as the kind, so a
# key names what a read of it hands back: a `piecewise_linear` row becomes a
# `TimeSeriesKey{SingleTimeSeries{PiecewiseLinearData}}`. The array rank is left
# free — it is a property of the stored array, not of the reference.
function _key_from_row(row)
    kind = _infrastore_is_type(row.time_series_type)
    value_type = _element_value_type(row.time_series_type)
    return TimeSeriesKey{kind{value_type}}(row.id)
end

_row_features(row) = Dict{String, Any}(string(k) => v for (k, v) in row.features)

# The IS `TimeSeriesMetadata` for a store catalog row: the key, plus the
# descriptive columns translated into IS's vocabulary. The translation is the
# point — a raw store row names *InfraStore's* `SingleTimeSeries`, and IS exports
# its own, so handing one back unconverted would give callers a type that fails
# every `<: SingleTimeSeries` test they write.
function _metadata_from_row(row)
    key = _key_from_row(row)
    return TimeSeriesMetadata(
        key,
        Int(row.owner_id),
        String(row.owner_type),
        row.owner_category,
        String(row.name),
        row.initial_timestamp,
        row.resolution,
        row.horizon,
        row.interval,
        isnothing(row.count) ? nothing : Int(row.count),
        isnothing(row.length) ? nothing : Int(row.length),
        row.percentiles,
        _row_features(row),
        String(row.element_type),
        row.data_hash,
        row.units,
        row.quantity_kind,
        _from_store_unit_system(row.unit_system),
        row.component_field,
        Dims(row.element_shape),
        row.time_reference,
        row.application_data,
    )
end

"""
Resolve a wire `association_id` to the full `TimeSeriesKey` it names, from the
store's catalog. The id is minted by the store that holds the association, so it
is meaningful only against that store — resolve it against the same artifact the
document was exported from.
"""
function get_time_series_key(store::Store, association_id::Integer)
    # `nothing`, not a raised error: the store treats a stale reference as an answer
    # to "does this still resolve?". Resolving one is past that question, so the miss
    # becomes an error here.
    row = InfraStore.get_metadata_by_id(store.inner, Int64(association_id))
    isnothing(row) && throw(
        ArgumentError(
            "association_id=$association_id: no association in this store carries this id",
        ),
    )
    return _key_from_row(row)
end

# Every matching catalog row, as IS `TimeSeriesMetadata`. The core
# `list_metadata` query filters owner / name / resolution / interval / features
# (periods are canonicalized to ISO-8601 on both write and query, so a regular
# `Hour(1)` matches a stored `Minute(60)`); an abstract `time_series_type` (or
# `Deterministic`, which also matches a DST) is not a catalog filter column, so
# it is applied as a residual on the already-narrowed rows.
#
# This is the ONE place a `time_series_type` filter is translated, which is why
# both the owner-scoped and the store-wide entry points route through it: the
# store's filter column takes the store's own types, and every IS caller — public
# or internal — names IS's. Any remaining keyword (`owner_id`, `owner_category`,
# `name`, `resolution`, `interval`, `name_glob`, `component_field`, `zoneless`)
# is a filter the store takes as-is and is forwarded untouched.
function _infrastore_list_metadata(
    store::Store;
    time_series_type = nothing,
    features::Union{Nothing, Dict} = nothing,
    kwargs...,
)
    type_filter = _infrastore_pushable_type(time_series_type)
    feats = _infrastore_features(features)
    rows =
        InfraStore.list_metadata(store.inner; time_series_type = type_filter,
            features = feats, kwargs...)
    out = TimeSeriesMetadata[]
    for row in rows
        if !isnothing(time_series_type)
            _infrastore_type_matches(
                _infrastore_is_type(row.time_series_type),
                time_series_type,
            ) ||
                continue
        end
        push!(out, _metadata_from_row(row))
    end
    return out
end

# Owner-level `list_metadata` entry point.
function infrastore_owner_list_metadata(
    owner::TimeSeriesOwners;
    time_series_type = nothing,
    name = nothing,
    resolution = nothing,
    interval = nothing,
    features::Union{Nothing, Dict} = nothing,
)
    !isnothing(time_series_type) &&
        _check_interval_supported(time_series_type, interval)
    mgr = _get_time_series_manager_or_throw(owner)
    store = mgr.data_store
    owner_id, _, category = _infrastore_owner_args(owner)
    return _infrastore_list_metadata(store;
        owner_id = owner_id, owner_category = category,
        time_series_type = time_series_type, name = name, resolution = resolution,
        interval = interval, features = features)
end

# Single matching time series key; throws when zero or more than one match.
function infrastore_get_time_series_key(
    owner::TimeSeriesOwners,
    ::Type{T},
    name::AbstractString;
    resolution = nothing,
    interval = nothing,
    features::Union{Nothing, Dict} = nothing,
) where {T <: TimeSeriesData}
    items = infrastore_owner_list_metadata(owner; time_series_type = T, name = name,
        resolution = resolution, interval = interval, features = features)
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
    return get_time_series_key(items[1])
end

# The catalog row `key` resolves to under `owner`, translated into IS's
# `TimeSeriesMetadata`. One primary-key fetch: the row that answers the call is
# the same row the owner is checked against, so there is no second lookup for the
# two to disagree about.
function infrastore_get_time_series_metadata(
    owner::TimeSeriesOwners,
    key::TimeSeriesKey,
)
    _, row = _store_and_association(owner, key)
    return _metadata_from_row(row)
end

# Content hash (64-char lowercase hex, the documented public form of the
# wrapper's 32-byte hash) of the array `key` resolves to under `owner`. The
# catalog row the `association_id` names carries the hash, so this is one
# primary-key fetch — no filtered listing, and no in-memory type residual or
# whole-feature-set match to sift its results with.
function infrastore_get_time_series_hash(owner::TimeSeriesOwners, key::TimeSeriesKey)
    _, row = _store_and_association(owner, key)
    return bytes2hex(row.data_hash)
end

# Content hashes for a homogeneous collection of owners, resolved by ONE catalog
# query (`list_metadata` filtered on category/type/name/resolution/interval,
# whose every row carries the array's `data_hash`) instead of one per owner.
# Returns `get_id(owner) => 64-char hex hash` for every owner in `owners` with a
# stored series matching the filters; owners with no
# match are simply absent. Two matches with the same hash are fine (they resolve
# to the same array); two matches with different hashes mean the filters
# underdetermine the series for that owner, so that is an error.
function infrastore_get_time_series_hashes(
    owners,
    ::Type{T},
    name::AbstractString;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features::Union{Nothing, Dict} = nothing,
) where {T <: TimeSeriesData}
    _check_interval_supported(T, interval)
    hashes = Dict{Int, String}()
    isempty(owners) && return hashes
    owner = first(owners)
    mgr = _get_time_series_manager_or_throw(owner)
    store = mgr.data_store
    # The single-query design filters on ONE owner category, so a mixed collection would
    # silently drop every owner of the other kind. The id collection already walks
    # `owners`, so checking the category costs nothing.
    category = get_owner_category(owner)
    ids = Set{Int}()
    for o in owners
        get_owner_category(o) == category || throw(
            ArgumentError(
                "get_time_series_hashes requires owners of one kind; " *
                "$(summary(owner)) is a $category but $(summary(o)) is a " *
                "$(get_owner_category(o)). Call it once per owner kind.",
            ),
        )
        push!(ids, get_id(o))
    end
    rows = InfraStore.list_metadata(store.inner;
        owner_category = category,
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
    for md in list_metadata(store)
        get_time_series_type(md) <: DeterministicSingleTimeSeries && continue
        owner = id_to_owner(get_owner_id(md), get_owner_category(md))
        pairs = get!(
            () -> Tuple{TimeSeriesOwners, TimeSeriesKey}[], groups,
            get_data_hash(md))
        push!(pairs, (owner, get_time_series_key(md)))
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
    metas = infrastore_owner_list_metadata(owner; time_series_type = type, name = name,
        resolution = resolution, interval = interval)
    store = _owner_store(owner)
    Channel() do channel
        for m in metas
            ts = _infrastore_read_key(store, get_time_series_key(m))
            (isnothing(filter_func) || filter_func(ts)) && put!(channel, ts)
        end
    end
end

# Read one series by its already-resolved key — no catalog re-resolution, and
# store-addressed, since every key here came from the owner's own listing.
_infrastore_read_key(store::Store, key::TimeSeriesKey{<:Forecast}) =
    _infrastore_read_forecast(store, key)

_infrastore_read_key(store::Store, key::TimeSeriesKey{<:NonSequentialTimeSeries}) =
    _infrastore_read_non_sequential(store, key)

_infrastore_read_key(store::Store, key::TimeSeriesKey{<:SingleTimeSeries}) =
    _infrastore_read_single(store, key)

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
    # Answered in the core, which takes both filters: one DISTINCT query, or one
    # per concrete subtype when the strict `<:` match spans several. Listing the
    # matching rows to collect their owner ids would decode a full catalog row —
    # feature dict, hash bytes, every period column — per association, to read one
    # integer off each.
    isnothing(time_series_type) &&
        return InfraStore.list_owner_ids(store.inner, category; resolution = resolution)
    ids = Set{Int}()
    for t in _infrastore_subtype_types(time_series_type)
        union!(
            ids,
            InfraStore.list_owner_ids(
                store.inner, category; time_series_type = t, resolution = resolution,
            ),
        )
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
    rows = InfraStore.list_metadata(store.inner; owner_category = category,
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
    features::Union{Nothing, Dict} = nothing,
)
    !isnothing(time_series_type) &&
        _check_interval_supported(time_series_type, interval)
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
