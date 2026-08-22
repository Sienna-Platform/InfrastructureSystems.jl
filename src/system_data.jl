
# InfraStore backend: HDF5 arrays; metadata lives beside it as `<file>.sqlite`.
const INFRASTORE_TIME_SERIES_STORAGE_FILE = "time_series_storage.h5"
const TIME_SERIES_DIRECTORY_ENV_VAR = "SIENNA_TIME_SERIES_DIRECTORY"
const VALIDATION_DESCRIPTOR_FILE = "validation_descriptors.json"
const SERIALIZATION_METADATA_KEY = "__serialization_metadata__"

"""
    mutable struct SystemData <: ComponentContainer
        components::Components
        "Masked components are attached to the system for overall management purposes but
        are not exposed in the standard library calls like [`get_components`](@ref).
        Examples are components in a subsystem."
        masked_components::Components
        validation_descriptors::Vector
        internal::InfrastructureSystemsInternal
    end

Container for system components and time series data
"""
mutable struct SystemData <: ComponentContainer
    components::Components
    masked_components::Components
    "Maps the integer id of every attached component, regular and masked, to the component."
    component_ids::Dict{Int, InfrastructureSystemsComponent}
    "Components and supplemental attributes share one id stream; starts at 1."
    next_id::Int
    "User-defined subsystems. Components can be regular or masked."
    subsystems::Dict{String, Set{Int}}
    supplemental_attribute_manager::SupplementalAttributeManager
    time_series_manager::TimeSeriesManager
    validation_descriptors::Vector
    internal::InfrastructureSystemsInternal
end

"""
Construct SystemData to store components and time series data.

# Arguments

  - `validation_descriptor_file = nothing`: Optionally, a file defining component validation
    descriptors.
  - `time_series_in_memory = false`: Controls whether time series data is stored in memory
    or in a file.
  - `time_series_directory = nothing`: Controls what directory time series data is stored
    in. Default is the environment variable `SIENNA_TIME_SERIES_DIRECTORY` or `tempdir()` if
    that isn't set.
  - `compression = CompressionSettings()`: Controls compression of time series data.
"""
function SystemData(;
    validation_descriptor_file = nothing,
    time_series_in_memory = false,
    time_series_directory = nothing,
    compression = CompressionSettings(),
)
    validation_descriptors = if isnothing(validation_descriptor_file)
        []
    else
        read_validation_descriptor(validation_descriptor_file)
    end

    time_series_mgr = TimeSeriesManager(;
        in_memory = time_series_in_memory,
        directory = time_series_directory,
        compression = compression,
    )
    components = Components(time_series_mgr, validation_descriptors)
    supplemental_attribute_mgr =
        SupplementalAttributeManager(get_data_store(time_series_mgr))
    masked_components = Components(time_series_mgr, validation_descriptors)
    return SystemData(
        components,
        masked_components,
        Dict{Int, InfrastructureSystemsComponent}(),
        1,
        Dict{String, Set{Int}}(),
        supplemental_attribute_mgr,
        time_series_mgr,
        validation_descriptors,
        InfrastructureSystemsInternal(),
    )
end

function SystemData(
    validation_descriptors,
    time_series_manager,
    next_id,
    subsystems,
    supplemental_attribute_manager,
    internal,
)
    components = Components(time_series_manager, validation_descriptors)
    masked_components = Components(time_series_manager, validation_descriptors)
    return SystemData(
        components,
        masked_components,
        Dict{Int, InfrastructureSystemsComponent}(),
        next_id,
        subsystems,
        supplemental_attribute_manager,
        time_series_manager,
        validation_descriptors,
        internal,
    )
end

"""
The [`Store`](@ref) backing this system's time series and association rows.
"""
get_data_store(data::SystemData) = get_data_store(data.time_series_manager)

"""
Return the next integer id and advance the counter. Components and supplemental attributes
share this one stream.
"""
function get_next_id!(data::SystemData)
    id = data.next_id
    data.next_id += 1
    return id
end

"""
Open a batch of time series work and run `func` on it, inside a store transaction.

Additions made through the yielded [`TimeSeriesContext`](@ref) are buffered and
written as one bulk call. The block commits when `func` returns; if it throws,
everything the block did is rolled back — **including removals**, which are
recoverable only in here.

Blocks nest innermost-first.

A batch that grows past `auto_flush_threshold` staged additions or
`auto_flush_bytes` of staged array data — whichever comes first — is written out
mid-block, so an arbitrarily large block holds a bounded amount of data in memory.
Flushed work stays inside the transaction and rolls back with it.

```julia
time_series_transaction(data) do txn
    for (component, profile) in profiles
        add_time_series!(txn, component, profile)
    end
end
```
"""
function time_series_transaction(func::Function, data::SystemData; kwargs...)
    # The transaction carries the system-level owner check, so adds made through it
    # validate exactly as adds made through `data` itself.
    return _time_series_transaction(
        func,
        data.time_series_manager,
        owner -> _validate(data, owner);
        kwargs...,
    )
end

"""
Add time series data to a component or supplemental attribute.

# Arguments

  - `data::SystemData`: SystemData
  - `owner::InfrastructureSystemsComponent`: will store the time series reference
  - `time_series::TimeSeriesData`: Any object of subtype TimeSeriesData

Throws ArgumentError if the owner is not stored in the system.
"""
function add_time_series!(
    data::SystemData,
    owner::TimeSeriesOwners,
    time_series::TimeSeriesData;
    features...,
)
    _validate(data, owner)
    return add_time_series!(data.time_series_manager, owner, time_series; features...)
end

"""
Add the same time series data to multiple components.

# Arguments

  - `data::SystemData`: SystemData
  - `components`: iterable of components that will store the same time series reference
  - `time_series::TimeSeriesData`: Any object of subtype TimeSeriesData

This is significantly more efficent than calling `add_time_series!` for each component
individually with the same data because in this case, only one time series array is stored.

Throws ArgumentError if a component is not stored in the system.
"""
function add_time_series!(
    data::SystemData,
    components,
    time_series::TimeSeriesData;
    features...,
)
    # A block opened for just this call, so the components land as one batch,
    # atomically. The transaction's dispatch stores the array once and validates
    # each component against `data`.
    return time_series_transaction(data) do txn
        add_time_series!(txn, components, time_series; features...)
    end
end

"""
Remove the time series data for a component.
"""
function remove_time_series!(
    data::SystemData,
    ::Type{T},
    owner::TimeSeriesOwners,
    name::String;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
    features...,
) where {T <: TimeSeriesData}
    return remove_time_series!(
        data.time_series_manager,
        T,
        owner,
        name;
        resolution = resolution,
        interval = interval,
        features...,
    )
end

function remove_time_series!(
    data::SystemData,
    owner::TimeSeriesOwners,
    ts_key::TimeSeriesKey,
)
    return remove_time_series!(data.time_series_manager, owner, ts_key)
end

"""
Removes all time series of a particular type from a System.

# Arguments

  - `data::SystemData`: system
  - `type::Type{<:TimeSeriesData}`: Type of time series objects to remove.
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Only remove time series with this
    resolution.
  - `interval::Union{Nothing, Dates.Period} = nothing`: Only remove time series with this
    interval.
"""
function remove_time_series!(
    data::SystemData,
    ::Type{T};
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
) where {T <: TimeSeriesData}
    _throw_if_read_only(data.time_series_manager)
    # One bulk catalog removal per matching stored type instead of one store
    # transaction per (component, key). Scoped to component owners, matching
    # the per-component iteration this replaces; supplemental-attribute series
    # are left untouched. The core refuses to remove SingleTimeSeries whose
    # arrays still back a DeterministicSingleTimeSeries; surface that as the
    # IS-level error.
    try
        _infrastore_remove_by_filter!(
            get_data_store(data),
            T;
            owner_category = InfraStore.Component,
            resolution = resolution,
            interval = interval,
        )
    catch e
        if e isa InfraStore.InvalidParameterError
            throw(
                ArgumentError(
                    "Cannot remove SingleTimeSeries because they are attached to a " *
                    "DeterministicSingleTimeSeries."),
            )
        end
        rethrow()
    end
    return
end

"""
Checks that the component exists in data and is the same object.
"""
function _validate(
    data::SystemData,
    component::T,
) where {T <: InfrastructureSystemsComponent}
    name = get_name(component)
    comp = get_component(T, data.components, name)
    if isnothing(comp)
        comp = get_masked_component(T, data, name)
        if comp === nothing
            throw(ArgumentError("no $T with name=$name is stored"))
        end
    end

    if component !== comp
        throw(
            ArgumentError(
                "$(summary(component)) does not match the stored component of the same " *
                "type and name. Was it copied?",
            ),
        )
    end
end

function _validate(data::SystemData, attribute::SupplementalAttribute)
    _attribute = get_supplemental_attribute(data, get_id(attribute))
    if attribute !== _attribute
        throw(
            ArgumentError(
                "$(summary(attribute)) does not match the stored attribute of the same " *
                "type and name. Was it copied?",
            ),
        )
    end
end

function compare_values(
    match_fn::Union{Function, Nothing},
    x::SystemData,
    y::SystemData;
    compare_ids = false,
    exclude = Set{Symbol}(),
)
    match = true
    for name in fieldnames(SystemData)
        name in exclude && continue
        if name == :component_ids
            # These are not serialized. They get rebuilt when the parent package adds
            # the components.
            continue
        end
        if !compare_ids && name == :next_id
            # This counter is derived from the identities it hands out, so it only means
            # anything when the identities themselves are being compared. Reassigning ids
            # (`assign_new_ids`) advances it past the originals while leaving the data
            # identical — the same reason `id` itself is skipped unless `compare_ids`.
            continue
        end
        val_x = getproperty(x, name)
        val_y = getproperty(y, name)
        if !compare_values(
            match_fn,
            val_x,
            val_y;
            compare_ids = compare_ids,
            exclude = exclude,
        )
            @error "SystemData field = $name does not match" getproperty(x, name) getproperty(
                y,
                name,
            )
            match = false
        end
    end

    return match
end

function remove_component!(::Type{T}, data::SystemData, name) where {T}
    component = remove_component!(T, data.components, name)
    _handle_component_removal!(data, component)
    return component
end

function remove_component!(data::SystemData, component)
    component = remove_component!(data.components, component)
    _handle_component_removal!(data, component)
    return component
end

function remove_components!(::Type{T}, data::SystemData) where {T}
    components = remove_components!(T, data.components)
    for component in components
        _handle_component_removal!(data, component)
    end

    return components
end

function _handle_component_removal!(data::SystemData, component)
    id = get_id(component)
    if !haskey(data.component_ids, id)
        error("Bug: component = $(summary(component)) did not have its id stored $id")
    end

    pop!(data.component_ids, id)
    remove_component_from_subsystems!(data, component)
    set_shared_system_references!(component, nothing)
    return
end

"""
Removes the component from the main container and adds it to the masked container.
"""
function mask_component!(
    data::SystemData,
    component::InfrastructureSystemsComponent;
    remove_time_series = false,
    remove_supplemental_attributes = false,
)
    remove_component!(
        data.components,
        component;
        remove_time_series = remove_time_series,
        remove_supplemental_attributes = remove_supplemental_attributes,
    )
    _handle_component_removal!(data, component)
    return add_masked_component!(
        data,
        component;
        skip_validation = true,  # validation has already occurred
        allow_existing_time_series = true,
    )
end

clear_time_series!(data::SystemData) = clear_time_series!(data.time_series_manager)

"""
Reclaim the space that removed time series left behind, returning an
`InfraStore.CompactionReport` (`slots_reclaimed`, `feature_sets_reclaimed`,
`timestamp_sets_reclaimed`, `bytes_reclaimed`).

HDF5 cannot hand freed space back in place, so removing time series — including
[`clear_time_series!`](@ref) — leaves the `.h5` file the same size. For a system
whose time series are on disk, this rewrites that file from what the catalog
still references and replaces it, which is what actually shrinks it;
`bytes_reclaimed` reports by how much. A system holding its time series in
memory has no file to rewrite, and reports `0` bytes.

The rewrite assumes this process is the file's only user: another process with
the same artifact open keeps reading the pre-compaction file on Unix, and blocks
the replacement on Windows.
"""
compact_time_series!(data::SystemData) = compact_time_series!(data.time_series_manager)

function iterate_components_with_time_series(
    data::SystemData;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    return (
        get_component(data, x) for
        x in infrastore_list_owner_ids(
            get_data_store(data),
            InfrastructureSystemsComponent;
            time_series_type = time_series_type,
            resolution = resolution,
        )
    )
end

function iterate_supplemental_attributes_with_time_series(
    data::SystemData,
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
)
    return (
        get_supplemental_attribute(data, x) for
        x in infrastore_list_owner_ids(
            get_data_store(data),
            SupplementalAttribute;
            time_series_type = time_series_type,
        )
    )
end

"""
Returns an iterator of `TimeSeriesData` instances attached to the system.

Note that passing a filter function can be much slower than the other filtering parameters
because it reads time series data from media.

Call `collect` on the result to get an array.

# Arguments

  - `data::SystemData`: system
  - `filter_func = nothing`: Only return time_series for which this returns true.
  - `type = nothing`: Only return time_series with this type.
  - `name = nothing`: Only return time_series matching this value.

See also: [`get_time_series_multiple` from an individual component or attribute](@ref get_time_series_multiple(
    owner::TimeSeriesOwners,
    filter_func = nothing;
    type = nothing,
    name = nothing,
))
"""
function get_time_series_multiple(
    data::SystemData,
    filter_func = nothing;
    type = nothing,
    name = nothing,
)
    Channel() do channel
        for component in iterate_components_with_time_series(data; time_series_type = type)
            for time_series in
                get_time_series_multiple(component, filter_func; type = type, name = name)
                put!(channel, time_series)
            end
        end
    end
end

"""
Verify that, per resolution, all time series of `ts_type` share one
`(initial_timestamp, length)` grid, and return that pair. Time series at
different resolutions have legitimately different grids; when more than one
resolution is present, pass `resolution` to name the grid to check and return.
"""
check_time_series_consistency(
    data::SystemData,
    ts_type;
    resolution::Union{Nothing, Dates.Period} = nothing,
) = infrastore_check_consistency(
    get_data_store(data),
    ts_type;
    resolution = resolution,
)

"""
Transform all instances of SingleTimeSeries to DeterministicSingleTimeSeries.
If all SingleTimeSeries instances cannot be transformed then none will be.

By default, any existing DeterministicSingleTimeSeries forecasts will be deleted before the
transform (`delete_existing = true`). Set `delete_existing = false` to preserve existing
DeterministicSingleTimeSeries; entries with matching name, resolution, features, horizon, and
interval are skipped, allowing multiple calls with different resolutions to coexist.
"""
function transform_single_time_series!(
    data::SystemData,
    ::Type{<:DeterministicSingleTimeSeries},
    horizon::Dates.Period,
    interval::Dates.Period;
    resolution::Union{Nothing, Dates.Period} = nothing,
    delete_existing::Bool = true,
)
    if is_irregular_period(horizon) || is_irregular_period(interval) ||
       (!isnothing(resolution) && is_irregular_period(resolution))
        throw(
            ArgumentError(
                "transform_single_time_series! does not support irregular periods for " *
                "horizon, interval, and resolution",
            ),
        )
    end
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "transform_single_time_series" begin
        _transform_single_time_series!(
            data,
            DeterministicSingleTimeSeries,
            horizon,
            interval;
            resolution = resolution,
            delete_existing = delete_existing,
        )
    end
end

"""
Check whether a call to `transform_single_time_series!` with the given parameters would
complete successfully.

Return `true` if the transform is valid, `false` otherwise.
"""
function check_transform_single_time_series(
    data::SystemData,
    ::Type{<:DeterministicSingleTimeSeries},
    horizon::Dates.Period,
    interval::Dates.Period;
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    if is_irregular_period(horizon) || is_irregular_period(interval) ||
       (!isnothing(resolution) && is_irregular_period(resolution))
        return false
    end
    try
        # A dry run in the store: every check the real transform would run,
        # nothing written.
        infrastore_transform_single_time_series!(
            get_data_store(data),
            horizon,
            interval;
            resolution = resolution,
            dry_run = true,
        )
    catch e
        e isa ConflictingInputsError && return false
        rethrow()
    end
    return true
end

function _transform_single_time_series!(
    data::SystemData,
    ::Type{<:DeterministicSingleTimeSeries},
    horizon::Dates.Period,
    interval::Dates.Period;
    resolution::Union{Nothing, Dates.Period} = nothing,
    delete_existing::Bool = true,
)
    # The store derives a DeterministicSingleTimeSeries view over every stored
    # component SingleTimeSeries that shares the array (no data is copied); the
    # window parameters are recorded in the metadata. Supplemental-attribute
    # series are left untouched, matching the metadata-store behavior.
    #
    # The two policy flags are IS's contract, not store invariants: the single-window
    # interval is stored as zero (what IS looks views up by), and one system holds one
    # forecast grid.
    #
    # The removal of the previous transforms and the new transform are one store
    # transaction: if the store rejects the new parameters, the old views are still
    # there, which is the all-or-nothing promise in the docstring.
    outcome = time_series_transaction(data) do _
        if delete_existing
            remove_time_series!(
                data,
                DeterministicSingleTimeSeries;
                resolution = resolution,
            )
        end
        infrastore_transform_single_time_series!(
            get_data_store(data),
            horizon,
            interval;
            resolution = resolution,
        )
    end

    if iszero(outcome.sources)
        @warn "There are no SingleTimeSeries arrays to transform"
        return
    end
    if outcome.interval_normalized
        @warn "There is only one forecast window. Setting interval = $(Dates.canonicalize(outcome.interval))"
    end
    return
end

"""
Parent object should call this prior to serialization so that SystemData can store the
appropriate path information for the time series data.
"""
function prepare_for_serialization_to_file!(
    data::SystemData,
    filename::AbstractString;
    force = false,
)
    directory = dirname(filename)
    if !isdir(directory)
        mkpath(directory)
    end

    sys_base = _get_system_basename(filename)
    ts_base = joinpath(
        directory,
        _get_secondary_basename(sys_base, INFRASTORE_TIME_SERIES_STORAGE_FILE),
    )
    files = [
        filename,
        ts_base,                # HDF5 arrays
        ts_base * ".sqlite",    # sidecar metadata
    ]
    for file in files
        if !force && isfile(file)
            error("$file already exists. Set force=true to overwrite.")
        end
    end

    ext = get_ext(data.internal)
    if haskey(ext, SERIALIZATION_METADATA_KEY)
        error("Bug: key = $SERIALIZATION_METADATA_KEY should not be present")
    end
    ext[SERIALIZATION_METADATA_KEY] = Dict{String, Any}(
        "serialization_directory" => directory,
        "basename" => _get_system_basename(filename),
    )
    return
end

"""
Serialize all system and component data to a dictionary.
"""
function to_dict(data::SystemData)
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "SystemData to_dict" begin
        serialized_data = Dict{String, Any}()
        for field in
            (
            :components,
            :masked_components,
            :next_id,
            :subsystems,
            :supplemental_attribute_manager,
            :internal,
        )
            serialized_data[string(field)] = serialize(getproperty(data, field))
        end

        serialized_data["version_info"] = serialize_julia_info()
        return serialized_data
    end
end

function serialize(data::SystemData)
    @debug "serialize SystemData" _group = LOG_GROUP_SERIALIZATION
    json_data = to_dict(data)
    ext = get_ext(data.internal)
    # This key will exist if the user is serializing to a file but not if the
    # user is serializing to a string.
    pop!(ext, SERIALIZATION_METADATA_KEY, nothing)
    isempty(ext) && clear_ext!(data.internal)

    if json_data["internal"]["ext"] isa Dict
        if (
            haskey(json_data["internal"]["ext"], SERIALIZATION_METADATA_KEY) &&
            haskey(
                json_data["internal"]["ext"][SERIALIZATION_METADATA_KEY],
                "serialization_directory",
            )
        )
            metadata = json_data["internal"]["ext"][SERIALIZATION_METADATA_KEY]
            directory = metadata["serialization_directory"]
            base = metadata["basename"]

            store = get_data_store(data)
            if isempty(store)
                json_data["time_series_compression_enabled"] =
                    get_compression_settings(store).enabled
                json_data["time_series_in_memory"] = isnothing(_store_path(store))
            else
                # InfraStore backend: write the .h5 arrays + standalone .sqlite metadata.
                time_series_base_name =
                    _get_secondary_basename(base, INFRASTORE_TIME_SERIES_STORAGE_FILE)
                time_series_storage_file = joinpath(directory, time_series_base_name)
                serialize(store, time_series_storage_file)
                json_data["time_series_storage_file"] = time_series_base_name
                # Stable on-disk discriminator for the storage backend, intentionally
                # decoupled from the `Store` Julia type name.
                json_data["time_series_storage_type"] = "InfraStore"
            end
        end
        pop!(json_data["internal"]["ext"], SERIALIZATION_METADATA_KEY, nothing)
    end

    return json_data
end

function deserialize(
    ::Type{SystemData},
    raw::Dict;
    time_series_read_only = false,
    time_series_directory = nothing,
    validation_descriptor_file = nothing,
    kwargs...,
)
    @debug "deserialize" raw _group = LOG_GROUP_SERIALIZATION

    if haskey(raw, "time_series_storage_file") &&
       strip_module_name(get(raw, "time_series_storage_type", "")) == "InfraStore"
        if !isfile(raw["time_series_storage_file"])
            error("time series file $(raw["time_series_storage_file"]) does not exist")
        end
        # InfraStore backend: open the .h5 + sidecar .sqlite. When the system is not
        # read-only, isolate it from the source file by opening a working copy so
        # that adding/removing time series cannot corrupt a shared/cached store.
        time_series_manager = TimeSeriesManager(;
            data_store = open_deserialized_infrastore_store(
                raw["time_series_storage_file"],
                time_series_directory,
                time_series_read_only,
            ),
            read_only = time_series_read_only,
        )
    elseif haskey(raw, "time_series_storage_file")
        error(
            "This system was serialized with the legacy HDF5 time series storage " *
            "(type = $(get(raw, "time_series_storage_type", "unknown"))), which is no " *
            "longer supported. HDF5 storage has been removed in favor of the InfraStore backend.",
        )
    else
        # The serialized store was empty; create a fresh InfraStore store honoring the
        # recorded in-memory flag and compression setting.
        time_series_manager = TimeSeriesManager(;
            in_memory = get(raw, "time_series_in_memory", true),
            directory = time_series_directory,
            read_only = time_series_read_only,
            compression = CompressionSettings(;
                enabled = get(raw, "time_series_compression_enabled", DEFAULT_COMPRESSION),
            ),
        )
    end
    subsystems = Dict(k => Set(Int.(v)) for (k, v) in raw["subsystems"])
    if !haskey(raw, "next_id")
        throw(
            DataFormatError(
                "The serialized system predates the single id stream (it carries " *
                "`next_component_id`/`next_supplemental_attribute_id`); regenerate it " *
                "with this version of InfrastructureSystems.",
            ),
        )
    end
    next_id = Int(raw["next_id"])
    supplemental_attribute_manager = deserialize(
        SupplementalAttributeManager,
        get(
            raw,
            "supplemental_attribute_manager",
            Dict("attributes" => [], "associations" => []),
        ),
        time_series_manager,
    )
    internal = deserialize(InfrastructureSystemsInternal, raw["internal"])
    validation_descriptors = if isnothing(validation_descriptor_file)
        []
    else
        read_validation_descriptor(validation_descriptor_file)
    end
    @debug "deserialize" _group = LOG_GROUP_SERIALIZATION time_series_storage internal
    sys = SystemData(
        validation_descriptors,
        time_series_manager,
        next_id,
        subsystems,
        supplemental_attribute_manager,
        internal,
    )
    attributes_by_id = Dict{Int, SupplementalAttribute}()
    for attr_dict in values(supplemental_attribute_manager.data)
        for attr in values(attr_dict)
            id = get_id(attr)
            if haskey(attributes_by_id, id)
                error("Bug: Found duplicate supplemental attribute id: $id")
            end
            attributes_by_id[id] = attr
        end
    end

    system_component_ids = Set{Int}()
    for component in Iterators.Flatten((raw["components"], raw["masked_components"]))
        push!(system_component_ids, Int(component["internal"]["id"]))
    end

    for (name, subsystem_component_ids) in sys.subsystems
        if !issubset(subsystem_component_ids, system_component_ids)
            diff = setdiff(subsystem_component_ids, system_component_ids)
            error("Subsystem $name has component ids that are not in the system: $diff")
        end
    end

    # Note: components need to be deserialized by the parent so that they can go through
    # the proper checks.
    return sys
end

# Redirect functions to Components

"""
Advance `data`'s shared id counter past `id` if `id` has not already been passed. Called
whenever an entity (component or supplemental attribute) enters `data` carrying a pre-set id,
so a later fresh mint from [`get_next_id!`](@ref) can never collide with it.
"""
function _advance_next_id_past!(data::SystemData, id::Int)
    if id >= data.next_id
        data.next_id = id + 1
    end
    return
end

"""
Assign an integer id to a component or supplemental attribute being attached to `data`.

A freshly constructed object has [`UNASSIGNED_ID`](@ref) and receives the next id. An object
that already carries an id (for example, one restored during deserialization, or one an
importer set explicitly with [`set_id!`](@ref) from a document) keeps it; the counter is
advanced past it so future ids do not collide. Components and supplemental attributes draw
from the same stream, so an id is unique across both kinds.
"""
function assign_id!(
    data::SystemData,
    obj::Union{InfrastructureSystemsComponent, SupplementalAttribute},
)
    id = get_id(obj)
    if id == UNASSIGNED_ID
        id = get_next_id!(data)
        set_id!(obj, id)
    else
        _advance_next_id_past!(data, id)
    end
    return id
end

"""
Add a component to a [`SystemData`](@ref) instance.

Assigns the component's integer id, wires [`SharedSystemReferences`](@ref) for time series
and supplemental attributes, and delegates storage to the underlying [`Components`](@ref)
container.

See also: [`add_component!`](@ref) on [`Components`](@ref)
"""
function add_component!(data::SystemData, component; kwargs...)
    _check_add_component(data, component)
    add_component!(data.components, component; kwargs...)
    data.component_ids[assign_id!(data, component)] = component
    refs = SharedSystemReferences(;
        time_series_manager = data.time_series_manager,
        supplemental_attribute_manager = data.supplemental_attribute_manager,
    )
    set_shared_system_references!(component, refs)
    return
end

function add_masked_component!(data::SystemData, component; kwargs...)
    _check_add_component(data, component)
    add_component!(
        data.masked_components,
        component;
        allow_existing_time_series = true,
        kwargs...,
    )
    data.component_ids[assign_id!(data, component)] = component
    refs = SharedSystemReferences(;
        time_series_manager = data.time_series_manager,
        supplemental_attribute_manager = data.supplemental_attribute_manager,
    )
    set_shared_system_references!(component, refs)
    return
end

function remove_masked_component!(data::SystemData, component)
    component = remove_component!(data.masked_components, component)
    _handle_component_removal!(data, component)
    return component
end

function _check_add_component(data::SystemData, component)
    _check_duplicate_component_id(data, component)
    if !isnothing(get_shared_system_references(component))
        error("$(summary(component)) is already attached to a system")
    end
end

function _check_duplicate_component_id(data::SystemData, component)
    id = get_id(component)
    if id != UNASSIGNED_ID && haskey(data.component_ids, id)
        throw(ArgumentError("Component $(summary(component)) id=$id is already stored"))
    end
end

iterate_components(data::SystemData) = iterate_components(data.components)

get_component(::Type{T}, data::SystemData, args...) where {T} =
    get_component(T, data.components, args...)

function get_component(data::SystemData, id::Int)
    component = get(data.component_ids, id, nothing)
    if isnothing(component)
        throw(ArgumentError("No component with id = $id is stored."))
    end

    return component
end

"""
Check to see if a component exists.
"""
has_component(
    data::SystemData,
    T::Type{<:InfrastructureSystemsComponent},
    name::AbstractString,
) = has_component(data.components, T, name)

function has_component(data::SystemData, component::InfrastructureSystemsComponent)
    return get_id(component) in keys(data.component_ids)
end

function assign_new_id!(data::SystemData, component::InfrastructureSystemsComponent)
    orig_id = get_id(component)
    if isnothing(pop!(data.component_ids, orig_id, nothing))
        throw(ArgumentError("component with id = $orig_id is not stored."))
    end

    assign_new_id_internal!(data, component)
    data.component_ids[get_id(component)] = component
    return
end

function get_components(
    filter_func::Function,
    ::Type{T},
    data::SystemData;
    subsystem_name::Union{Nothing, AbstractString} = nothing,
) where {T}
    ids = if isnothing(subsystem_name)
        nothing
    else
        get_component_ids(data, subsystem_name)
    end
    return get_components(filter_func, T, data.components; component_ids = ids)
end

function get_components(
    ::Type{T},
    data::SystemData;
    subsystem_name::Union{Nothing, AbstractString} = nothing,
) where {T}
    ids = if isnothing(subsystem_name)
        nothing
    else
        get_component_ids(data, subsystem_name)
    end
    return get_components(T, data.components; component_ids = ids)
end

get_components_by_name(::Type{T}, data::SystemData, args...) where {T} =
    get_components_by_name(T, data.components, args...)

function get_associated_components(
    data::SystemData,
    attribute_type::Type{<:SupplementalAttribute};
    component_type::Union{Nothing, Type{<:InfrastructureSystemsComponent}} = nothing,
)
    return [
        get_component(data, x) for x in
        list_associated_component_ids(
            data.supplemental_attribute_manager,
            attribute_type,
            component_type,
        )
    ]
end

"""
Return all supplemental attributes associated with the components of the given type, optionally filtered by `attribute_type`.

# Arguments
- `data::SystemData`: the `SystemData` to search
- `component_type`::Type{<:InfrastructureSystemsComponent}: Only return attributes
 associated with the components of this type.
- `attribute_type`::Union{Nothing, Type{<:SupplementalAttribute}}`: Optional, type of the
  attributes to return. Can be concrete or abstract.
"""
function get_associated_supplemental_attributes(
    data::SystemData,
    component_type::Type{<:InfrastructureSystemsComponent};
    attribute_type::Union{Nothing, Type{<:SupplementalAttribute}} = nothing,
)
    return [
        get_supplemental_attribute(data, x) for x in
        list_associated_supplemental_attribute_ids(
            data.supplemental_attribute_manager,
            component_type,
            attribute_type,
        )
    ]
end

"""
Return all components associated with the attribute that match `component_type`.

# Arguments
- `data::SystemData`: the `SystemData` to search
- `attribute::SupplementalAttribute`: Only return components associated with this attribute.
- `component_type::Union{Nothing, Type{<:InfrastructureSystemsComponent}}`: Optional, type of the
  components to return. Can be concrete or abstract.
"""
function get_associated_components(
    data::SystemData,
    attribute::SupplementalAttribute;
    component_type::Union{Nothing, Type{<:InfrastructureSystemsComponent}} = nothing,
)
    return [
        get_component(data, x) for x in
        list_associated_component_ids(
            data.supplemental_attribute_manager.associations,
            attribute,
            component_type,
        )
    ]
end

"""
Return a vector of NamedTuples with pairs of components and supplemental attributes that
are associated with each other. Limit by `components` and `attributes` if provided.

The return type is `NamedTuple{(:component, :supplemental_attribute), Tuple{T, U}}[]`
where `T` is the component type and `U` is the supplemental attribute type.
"""
function get_component_supplemental_attribute_pairs(
    ::Type{T},
    ::Type{U},
    data::SystemData;
    components = nothing,
    attributes = nothing,
) where {T <: InfrastructureSystemsComponent, U <: SupplementalAttribute}
    ca_pairs = NamedTuple{(:component, :supplemental_attribute), Tuple{T, U}}[]
    c_ids = if isnothing(components)
        Set{Int}()
    else
        Set(get_id.(components))
    end
    a_ids = if isnothing(attributes)
        Set{Int}()
    else
        Set(get_id.(attributes))
    end
    for (component_id, attribute_id) in
        list_associated_pair_ids(
        data.supplemental_attribute_manager.associations,
        U,
        T,
    )
        if !isnothing(components) && !(component_id in c_ids)
            continue
        end
        if !isnothing(attributes) && !(attribute_id in a_ids)
            continue
        end
        component = get_component(data, component_id)

        attribute = get_supplemental_attribute(data, attribute_id)
        push!(ca_pairs, (component = component, supplemental_attribute = attribute))
    end

    return ca_pairs
end

function get_masked_components(
    ::Type{T},
    data::SystemData,
) where {T}
    return get_components(T, data.masked_components)
end

function get_masked_components(
    filter_func::Function,
    ::Type{T},
    data::SystemData,
) where {T}
    return get_components(filter_func, T, data.masked_components)
end

get_masked_components_by_name(::Type{T}, data::SystemData, args...) where {T} =
    get_components_by_name(T, data.masked_components, args...)

get_masked_component(::Type{T}, data::SystemData, name) where {T} =
    get_component(T, data.masked_components, name)

function get_masked_component(data::SystemData, id::Int)
    # `component_ids` indexes masked components too, so this is the same O(1) lookup as
    # `get_component`, narrowed to the masked container.
    component = get(data.component_ids, id, nothing)
    if isnothing(component) || !is_attached(component, data.masked_components)
        @error "no masked component with id $id is stored"
        return nothing
    end

    return component
end

get_forecast_parameters(
    data::SystemData;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
) = infrastore_forecast_parameters(
    get_data_store(data);
    resolution = resolution,
    interval = interval,
)

function get_forecast_initial_times(data::SystemData; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    isnothing(params) && return []
    return get_initial_times(params.initial_timestamp, params.count, params.interval)
end

# One body for the four single-field forecast accessors. Each returns `nothing` when the
# system holds no forecasts, which is their long-standing contract.
function _forecast_parameter(data::SystemData, field::Symbol; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    if isnothing(params)
        return nothing
    end
    return getproperty(params, field)
end

get_forecast_window_count(data::SystemData; kwargs...) =
    _forecast_parameter(data, :count; kwargs...)

get_forecast_horizon(data::SystemData; kwargs...) =
    _forecast_parameter(data, :horizon; kwargs...)

get_forecast_initial_timestamp(data::SystemData; kwargs...) =
    _forecast_parameter(data, :initial_timestamp; kwargs...)

get_forecast_interval(data::SystemData; kwargs...) =
    _forecast_parameter(data, :interval; kwargs...)

get_time_series_resolutions(
    data::SystemData;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
) = infrastore_get_time_series_resolutions(
    get_data_store(data);
    time_series_type = time_series_type,
)

# The store reports an owner as `(id, category)`; resolve that back to the Julia object.
# Passed as a closure to the store-side readers and hash grouping.
function _make_id_to_owner(data::SystemData)
    return (id, category) -> if category == InfraStore.Component
        get_component(data, id)
    else
        get_supplemental_attribute(data, id)
    end
end

"""
$(TYPEDSIGNATURES)
Group the time series in `data` by the array they are stored in. Returns a
`Dict` mapping each content hash (a 64-character lowercase hex string) to the
`(owner, key)` pairs that resolve to that one array.

With `only_shared = true` (the default) the result contains only the groups with
more than one `(owner, key)` pair — the time series that actually share data,
whether across owners or within one owner. Pass `only_shared = false` to get
every stored array, including the arrays referenced exactly once.

`DeterministicSingleTimeSeries` is excluded: it is a view of its own
`SingleTimeSeries` and always reports that array's hash, which says nothing about
data being shared between time series.

Resolved by a single catalog query (no per-series reads).

See also [`get_time_series_hash`](@ref) for the hash of one `(owner, key)`.
"""
function get_time_series_array_groups(data::SystemData; only_shared = true)
    store = get_data_store(data)
    id_to_owner = _make_id_to_owner(data)
    return infrastore_group_by_hash(store, id_to_owner; only_shared = only_shared)
end

"""
$(TYPEDSIGNATURES)
Build a [`ForecastReader`](@ref) over every forecast in `data` of
`time_series_type` (`Deterministic`, `Probabilistic`, `Scenarios`, or
`DeterministicSingleTimeSeries`; a `Deterministic` reader also includes any
`DeterministicSingleTimeSeries`). `resolution` is required and pins the reader to
one forecast resolution; `name` and `features` further narrow the match. All
matched forecasts must share one window timeline.

The reader serves the simulation pattern "at each window timestamp, get every
component's forecast": drive it with [`read_forecast_window!`](@ref) and read each
entry with [`get_forecast_window`](@ref). Forecasts that share an underlying array
(deduplicated data, or a `DeterministicSingleTimeSeries` over its
`SingleTimeSeries`) are read from disk once per timestamp regardless of how many
components reference them — see [`get_time_series_array_groups`](@ref).
"""
function build_forecast_reader(
    data::SystemData,
    ::Type{T};
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features...,
) where {T <: Forecast}
    store = get_data_store(data)
    id_to_owner = _make_id_to_owner(data)
    return infrastore_build_forecast_reader(
        store,
        id_to_owner,
        T;
        resolution = resolution,
        name = name,
        features = Dict{String, Any}(string(k) => v for (k, v) in features),
    )
end

"""
$(TYPEDSIGNATURES)
Build a [`StaticTimeSeriesReader`](@ref) over every `SingleTimeSeries` in
`data`. `resolution` is required and pins the reader to one resolution; `name`
and `features` further narrow the match. All matched series must share one time
grid (`initial_timestamp` + `length`).

The reader serves the simulation pattern "at each timestamp, get every
component's value": drive it with [`read_static_time_series_values!`](@ref) and
read each entry with [`get_static_time_series_value`](@ref). Series with the
same element type are packed into one columnar group and served by a single
storage read per timestamp.
"""
function build_static_time_series_reader(
    data::SystemData;
    resolution::Dates.Period,
    name::Union{Nothing, AbstractString} = nothing,
    features...,
)
    store = get_data_store(data)
    id_to_owner = _make_id_to_owner(data)
    return infrastore_build_static_time_series_reader(
        store,
        id_to_owner;
        resolution = resolution,
        name = name,
        features = Dict{String, Any}(string(k) => v for (k, v) in features),
    )
end

function get_forecast_total_period(
    data::SystemData;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
)
    params = get_forecast_parameters(data; resolution = resolution, interval = interval)
    isnothing(params) && return Dates.Second(0)
    return get_total_period(
        params.initial_timestamp,
        params.count,
        params.interval,
        params.horizon,
        params.resolution,
    )
end

clear_components!(data::SystemData) = clear_components!(data.components)

function check_components(data::SystemData, args...)
    check_components(data.components, args...)
    check_components(data.masked_components, args...)
    return
end

check_component(data::SystemData, component) = check_component(data.components, component)

get_compression_settings(data::SystemData) =
    get_compression_settings(get_data_store(data))

set_name!(data::SystemData, component, name) = set_name!(data.components, component, name)

function get_component_counts_by_type(data::SystemData)
    counts = Dict{String, Int}()
    for (component_type, components) in iterate_components_by_type(data.components)
        counts[strip_module_name(component_type)] = length(components)
    end

    return [
        OrderedDict("type" => x, "count" => counts[x]) for x in sort(collect(keys(counts)))
    ]
end

get_num_supplemental_attributes(data::SystemData) =
    get_num_attributes(data.supplemental_attribute_manager.associations)
get_supplemental_attribute_counts_by_type(data::SystemData) =
    get_attribute_counts_by_type(data.supplemental_attribute_manager.associations)
get_supplemental_attribute_summary_table(data::SystemData) =
    get_attribute_summary_table(data.supplemental_attribute_manager.associations)
get_num_components_with_supplemental_attributes(data::SystemData) =
    get_num_components_with_attributes(data.supplemental_attribute_manager.associations)

get_num_time_series(data::SystemData) =
    InfraStore.num_distinct_arrays(get_data_store(data).inner)
function get_time_series_counts(data::SystemData)
    c = InfraStore.time_series_counts(get_data_store(data).inner)
    return TimeSeriesCounts(;
        components_with_time_series = c.components_with_time_series,
        supplemental_attributes_with_time_series = c.supplemental_attributes_with_time_series,
        static_time_series_count = c.static_time_series_count,
        forecast_count = c.forecast_count,
    )
end
get_time_series_counts_by_type(data::SystemData) =
    infrastore_get_time_series_counts_by_type(get_data_store(data))
get_static_time_series_summary_table(data::SystemData) =
    infrastore_static_summary_table(get_data_store(data))
get_forecast_summary_table(data::SystemData) =
    infrastore_forecast_summary_table(get_data_store(data))

_get_system_basename(system_file) = splitext(basename(system_file))[1]
_get_secondary_basename(system_basename, name) = system_basename * "_" * name

"""
$(TYPEDSIGNATURES)

Create a brand-new association between `component` and `attribute`, minting a fresh id
for `attribute` and writing a new association row. Use [`attach_supplemental_attribute!`](@ref)
instead when `attribute` already carries an id and the association row already exists,
e.g. when adopting a document on import.
"""
function add_supplemental_attribute!(data::SystemData, component, attribute; kwargs...)
    # Note that we do not support adding attributes to masked components
    # and this check doesn't look at those.
    throw_if_not_attached(data.components, component)
    assign_id!(data, attribute)
    add_supplemental_attribute!(
        data.supplemental_attribute_manager,
        component,
        attribute;
        kwargs...,
    )
    set_shared_system_references!(
        attribute,
        SharedSystemReferences(;
            supplemental_attribute_manager = data.supplemental_attribute_manager,
            time_series_manager = data.time_series_manager,
        ),
    )
    return
end

"""
$(TYPEDSIGNATURES)

Attach `attribute` to `component` when the store's `supplemental_attribute_associations`
table ALREADY holds this exact pairing — the shape an importer adopting a sidecar store
needs, as opposed to [`add_supplemental_attribute!`](@ref), which mints a fresh id for
`attribute` and writes a new association row.

Does everything [`add_supplemental_attribute!`](@ref) does EXCEPT `assign_id!` and any
association-table write or probe: `attribute` must already carry an id (call [`set_id!`](@ref)
on it from the document before attaching, mirroring how components are adopted on import) —
an `UNASSIGNED_ID` is always a caller bug here and throws `ArgumentError`. Because no
association row is written, `attribute` ends up attached to `data` without a matching
`(component, attribute)` row unless the caller already put one in the store; this function
does not check that either.

Use [`add_supplemental_attribute!`](@ref) instead when creating a brand-new attribute and its
association for the first time.
"""
function attach_supplemental_attribute!(
    data::SystemData,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute;
    allow_existing_time_series::Bool = false,
)
    throw_if_not_attached(data.components, component)
    _attach_attribute!(
        data.supplemental_attribute_manager,
        attribute;
        allow_existing_time_series = allow_existing_time_series,
    )
    # `attribute` already carries its id (checked by `_attach_attribute!`); advance the
    # shared counter past it exactly like `assign_id!` does for the minted-fresh path.
    _advance_next_id_past!(data, get_id(attribute))
    set_shared_system_references!(
        attribute,
        SharedSystemReferences(;
            supplemental_attribute_manager = data.supplemental_attribute_manager,
            time_series_manager = data.time_series_manager,
        ),
    )
    return
end

"""
Defer supplemental-attribute association inserts until `func` returns, then write them in
one store call. See [`begin_association_batch`](@ref) for the write-buffering mechanics and
its read-side limits.

Unlike the associations-level form, this SystemData form is fully transactional over BOTH the
attribute manager and the store: it runs inside
[`begin_supplemental_attributes_update`](@ref), which snapshots `mgr.data` (deep-copying each
attribute already stored) before `func` runs and restores it, together with the association
rows, if `func` throws. That closes a gap the associations-level form leaves open on its own —
`add_supplemental_attribute!` attaches the attribute to `mgr.data` *before* buffering its
association row, so a throw partway through a batch (a duplicate pair, say) would otherwise
leave an attribute attached in `mgr.data` with no association row for it, and no way to reach
it back out. The snapshot costs O(attributes already stored) — zero on the common import path,
where the manager starts empty.

Use this around a bulk attach — replaying a document's association table, say — where the
per-attach probe-then-insert pair would otherwise cost two store round trips per row.
"""
begin_association_batch(func::Function, data::SystemData) =
    begin_supplemental_attributes_update(data.supplemental_attribute_manager) do
        begin_association_batch(
            func, data.supplemental_attribute_manager.associations,
        )
    end

function get_supplemental_attributes(
    filter_func::Function,
    ::Type{T},
    data::SystemData,
) where {T <: SupplementalAttribute}
    return get_supplemental_attributes(filter_func, T, data.supplemental_attribute_manager)
end

function get_supplemental_attributes(
    ::Type{T},
    data::SystemData,
) where {T <: SupplementalAttribute}
    return get_supplemental_attributes(T, data.supplemental_attribute_manager)
end

function get_supplemental_attribute(data::SystemData, id::Int)
    return get_supplemental_attribute(data.supplemental_attribute_manager, id)
end

function iterate_supplemental_attributes(data::SystemData)
    return iterate_supplemental_attributes(data.supplemental_attribute_manager)
end

remove_supplemental_attribute!(
    data::SystemData,
    component::InfrastructureSystemsComponent,
    attribute::SupplementalAttribute;
) = remove_supplemental_attribute!(
    data.supplemental_attribute_manager,
    component,
    attribute,
)

remove_supplemental_attributes!(
    data::SystemData,
    type::Type{<:SupplementalAttribute};
) = remove_supplemental_attributes!(data.supplemental_attribute_manager, type)

"""
Remove all supplemental attributes.
"""
clear_supplemental_attributes!(data::SystemData) =
    clear_supplemental_attributes!(data.supplemental_attribute_manager)

stores_time_series_in_memory(data::SystemData) =
    isnothing(_store_path(get_data_store(data)))

"""
Make a `deepcopy` of a [`SystemData`](@ref) more quickly by skipping the copying of time
series and/or supplemental attributes.

# Arguments

  - `data::SystemData`: the `SystemData` to copy
  - `skip_time_series::Bool = true`: whether to skip copying time series
  - `skip_supplemental_attributes::Bool = true`: whether to skip copying supplemental
    attributes

Note that setting both `skip_time_series` and `skip_supplemental_attributes` to `false`
results in the same behavior as `deepcopy` with no performance improvement.
"""
function fast_deepcopy_system(
    data::SystemData;
    skip_time_series::Bool = true,
    skip_supplemental_attributes::Bool = true,
)
    # Swap the data we don't want copied for blank data, deepcopy, then swap back: a fresh
    # instance with different fields would not fix up the references held by components.
    # Both managers share one store, which carries time series AND association rows, so each
    # flag combination has to decide which store the copy sees.
    old_time_series_manager = data.time_series_manager
    old_supplemental_attribute_manager = data.supplemental_attribute_manager

    new_time_series_manager = if skip_time_series
        TimeSeriesManager(; in_memory = true, read_only = true)
    else
        old_time_series_manager
    end
    new_store = get_data_store(new_time_series_manager)
    new_supplemental_attribute_manager = if skip_supplemental_attributes
        SupplementalAttributeManager(new_store)
    elseif skip_time_series
        # Keep the attributes, drop the series: seed the fresh store with the rows.
        associations = SupplementalAttributeAssociations(new_store)
        copy_associations!(associations, old_supplemental_attribute_manager.associations)
        SupplementalAttributeManager(old_supplemental_attribute_manager.data, associations)
    else
        old_supplemental_attribute_manager
    end

    data.time_series_manager = new_time_series_manager
    data.supplemental_attribute_manager = new_supplemental_attribute_manager

    old_refs = Dict{Tuple{DataType, String}, SharedSystemReferences}()
    for comp in iterate_components(data)
        old_refs[(typeof(comp), get_name(comp))] =
            comp.internal.shared_system_references
        new_refs = SharedSystemReferences(;
            time_series_manager = new_time_series_manager,
            supplemental_attribute_manager = new_supplemental_attribute_manager,
        )
        set_shared_system_references!(comp, new_refs)
    end

    new_data = try
        deepcopy(data)
    finally
        data.time_series_manager = old_time_series_manager
        data.supplemental_attribute_manager = old_supplemental_attribute_manager

        for comp in iterate_components(data)
            set_shared_system_references!(comp,
                old_refs[(typeof(comp), get_name(comp))])
        end
    end

    # The only combination that cannot be arranged before the copy: the real store had to
    # be copied for its time series, so it brought the association rows with it.
    if skip_supplemental_attributes && !skip_time_series
        clear_associations!(new_data.supplemental_attribute_manager.associations)
    end
    return new_data
end
