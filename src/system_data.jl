
# Rust backend: NetCDF arrays; metadata lives beside it as `<file>.sqlite`.
const RUST_TIME_SERIES_STORAGE_FILE = "time_series_storage.nc"
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
    component_ids::Dict{Int, <:InfrastructureSystemsComponent}
    "Next integer id to assign to a component. Independent of the supplemental attribute id stream. Starts at 1."
    next_component_id::Int
    "Next integer id to assign to a supplemental attribute. Independent of the component id stream. Starts at 1."
    next_supplemental_attribute_id::Int
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
    supplemental_attribute_mgr = SupplementalAttributeManager()
    masked_components = Components(time_series_mgr, validation_descriptors)
    return SystemData(
        components,
        masked_components,
        Dict{Int, InfrastructureSystemsComponent}(),
        1,
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
    next_component_id,
    next_supplemental_attribute_id,
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
        next_component_id,
        next_supplemental_attribute_id,
        subsystems,
        supplemental_attribute_manager,
        time_series_manager,
        validation_descriptors,
        internal,
    )
end

"""
Return the next integer id to assign to a component and advance the component counter.
"""
function get_next_component_id!(data::SystemData)
    id = data.next_component_id
    data.next_component_id += 1
    return id
end

"""
Return the next integer id to assign to a supplemental attribute and advance the
supplemental attribute counter.
"""
function get_next_supplemental_attribute_id!(data::SystemData)
    id = data.next_supplemental_attribute_id
    data.next_supplemental_attribute_id += 1
    return id
end

function open_time_series_store!(
    func::Function,
    data::SystemData,
    mode = "r",
    args...;
    kwargs...,
)
    open_store!(
        func,
        data.time_series_manager.data_store,
        mode,
        args...;
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
    return add_time_series!(
        data.time_series_manager,
        owner,
        time_series;
        features...,
    )
end

function bulk_add_time_series!(
    data::SystemData,
    associations;
    batch_size = ADD_TIME_SERIES_BATCH_SIZE,
)
    bulk_add_time_series!(data.time_series_manager, associations; batch_size = batch_size)
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
    key = nothing
    for component in components
        # Component information is not embedded into the key and so it will always be the
        # same.
        key = add_time_series!(
            data,
            component,
            time_series;
            features...,
        )
    end

    return key
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
    for component in iterate_components_with_time_series(
        data;
        time_series_type = T,
        resolution = resolution,
    )
        for ts_key in get_time_series_keys(
            component;
            time_series_type = T,
            resolution = resolution,
        )
            ts_interval = get_interval(ts_key)
            if !isnothing(interval) && ts_interval != interval
                continue
            end
            remove_time_series!(data, component, ts_key)
        end
    end
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
    compare_uuids = false,
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
        val_x = getproperty(x, name)
        val_y = getproperty(y, name)
        if !compare_values(
            match_fn,
            val_x,
            val_y;
            compare_uuids = compare_uuids,
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

function iterate_components_with_time_series(
    data::SystemData;
    time_series_type::Union{Nothing, Type{<:TimeSeriesData}} = nothing,
    resolution::Union{Nothing, Dates.Period} = nothing,
)
    return (
        get_component(data, x) for
        x in _rust_list_owner_ids(
            data.time_series_manager.data_store,
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
        x in _rust_list_owner_ids(
            data.time_series_manager.data_store,
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

check_time_series_consistency(data::SystemData, ts_type) =
    _rust_check_consistency(data.time_series_manager.data_store, ts_type)

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
        _check_transform_single_time_series(
            data,
            DeterministicSingleTimeSeries,
            horizon,
            interval,
            resolution;
            skip_existing = true,
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
    if delete_existing
        remove_time_series!(data, DeterministicSingleTimeSeries; resolution = resolution)
    end
    # Validate eligibility and cross-series consistency before committing.
    items = _check_transform_single_time_series(
        data,
        DeterministicSingleTimeSeries,
        horizon,
        interval,
        resolution;
        skip_existing = !delete_existing,
    )

    if isempty(items)
        @warn "There are no SingleTimeSeries arrays to transform"
        return
    end

    for i in 2:length(items)
        params1 = items[1].params
        params = items[i].params
        if params.count != params1.count
            throw(
                ConflictingInputsError(
                    "transform_single_time_series! with horizon = $horizon and " *
                    "interval = $interval will produce Deterministic forecasts with " *
                    "different values for count: $(params.count) $(params1.count)"),
            )
        end
        if params.initial_timestamp != params1.initial_timestamp
            throw(
                ConflictingInputsError(
                    "transform_single_time_series! is not supported when " *
                    "SingleTimeSeries have different initial timestamps: " *
                    "$(params.initial_timestamp) $(params1.initial_timestamp)"),
            )
        end
    end

    # The Rust store derives a DeterministicSingleTimeSeries view over every
    # stored component SingleTimeSeries that shares the array (no data is copied);
    # the window parameters are recorded in the metadata. Supplemental-attribute
    # series are left untouched, matching the metadata-store behavior.
    TSS.transform_single_time_series!(
        data.time_series_manager.data_store.inner,
        horizon,
        interval;
        owner_category = TSS.Component,
        resolution = resolution,
    )
    return
end

"""
Check that all existing SingleTimeSeries can be converted to DeterministicSingleTimeSeries
with the given horizon and interval.

Throw ConflictingInputsError if any time series cannot be converted.

Return a Vector of NamedTuple of component, time series metadata, and forecast parameters
for all matches.
"""
function _check_transform_single_time_series(
    data::SystemData,
    ::Type{DeterministicSingleTimeSeries},
    horizon::Dates.Period,
    interval::Dates.Period,
    resolution::Union{Nothing, Dates.Period};
    skip_existing::Bool = false,
)
    items = _rust_list_metadata_with_owner(
        data.time_series_manager.data_store,
        InfrastructureSystemsComponent;
        time_series_type = SingleTimeSeries,
        resolution = resolution,
    )
    components_with_params_and_metadata = NamedTuple[]
    for item in items
        params = _check_single_time_series_transformed_parameters(
            item.metadata,
            DeterministicSingleTimeSeries,
            horizon,
            interval,
        )
        system_params = get_forecast_parameters(
            data;
            resolution = params.resolution,
            interval = params.interval,
        )
        check_params_compatibility(system_params, params)
        component = get_component(data, item.owner_id)

        # We do not allow a component to have both Deterministic and
        # DeterministicSingleTimeSeries with the same parameters.
        # The user might be calling this function because some components are missing
        # Deterministic forecasts. If other components already have Deterministic forecasts,
        # this check will fail.
        # transform_single_time_series! cannot be called at the component level.
        # Note: has_metadata with Deterministic matches both Deterministic and
        # DeterministicSingleTimeSeries. Use list_metadata and filter to check only for
        # actual Deterministic forecasts.
        ts_name = get_name(item.metadata)
        ts_resolution = get_resolution(item.metadata)
        ts_features = get_features(item.metadata)
        ts_features_symbols = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in ts_features)
        existing_det = list_metadata(
            data.time_series_manager,
            component;
            time_series_type = Deterministic,
            name = ts_name,
            resolution = ts_resolution,
            ts_features_symbols...,
        )
        if any(m -> get_time_series_type(m) === Deterministic, existing_det)
            throw(
                ConflictingInputsError(
                    "Cannot transform SingleTimeSeries to DeterministicSingleTimeSeries: " *
                    "A Deterministic forecast already exists for component $(summary(component)) " *
                    "with name='$ts_name', resolution=$ts_resolution, and features=$ts_features",
                ),
            )
        end

        # If skip_existing is true, skip SingleTimeSeries entries that already have a
        # DeterministicSingleTimeSeries with the same name, resolution, features,
        # horizon, and interval.
        if skip_existing
            existing = list_metadata(
                data.time_series_manager,
                component;
                time_series_type = DeterministicSingleTimeSeries,
                name = ts_name,
                resolution = ts_resolution,
                ts_features_symbols...,
            )
            if any(
                m ->
                    get_horizon(m) == params.horizon &&
                        get_interval(m) == params.interval,
                existing,
            )
                continue
            end
        end

        push!(
            components_with_params_and_metadata,
            (component = component, params = params, metadata = item.metadata),
        )
    end

    return components_with_params_and_metadata
end

function _check_single_time_series_transformed_parameters(
    metadata::StaticTimeSeriesKey,
    ::Type{DeterministicSingleTimeSeries},
    desired_horizon::Dates.Period,
    desired_interval::Dates.Period,
)
    resolution = get_resolution(metadata)
    len = length(metadata)
    max_horizon = len * resolution
    if desired_horizon > max_horizon
        throw(
            ConflictingInputsError(
                "TimeSeries: $(get_name(metadata)) desired horizon = $(Dates.canonicalize(desired_horizon)) is greater than max horizon = $(Dates.canonicalize(max_horizon))",
            ),
        )
    end

    if desired_horizon % resolution != Dates.Millisecond(0)
        throw(
            ConflictingInputsError(
                "TimeSeries: $(get_name(metadata)) desired horizon = $(Dates.canonicalize(desired_horizon)) is not evenly divisible by resolution = $(Dates.canonicalize(resolution))",
            ),
        )
    end

    horizon_count = get_horizon_count(desired_horizon, resolution)
    max_interval = desired_horizon
    if len == horizon_count && desired_interval == max_interval
        desired_interval = Dates.Second(0)
        @warn "There is only one forecast window. Setting interval = $(Dates.canonicalize(desired_interval))"
    elseif desired_interval > max_interval
        throw(
            ConflictingInputsError(
                "TimeSeries: $(get_name(metadata)) interval = $(Dates.canonicalize(desired_interval)) is bigger than the max of $(Dates.canonicalize(max_interval))",
            ),
        )
    end

    initial_timestamp = get_initial_timestamp(metadata)
    count = get_forecast_window_count(
        initial_timestamp,
        desired_interval,
        resolution,
        len,
        horizon_count,
    )
    return ForecastParameters(;
        initial_timestamp = initial_timestamp,
        count = count,
        horizon = desired_horizon,
        interval = desired_interval,
        resolution = resolution,
    )
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
        _get_secondary_basename(sys_base, RUST_TIME_SERIES_STORAGE_FILE),
    )
    files = [
        filename,
        ts_base,                # NetCDF arrays
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
            :next_component_id,
            :next_supplemental_attribute_id,
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

            store = data.time_series_manager.data_store
            if isempty(store)
                json_data["time_series_compression_enabled"] =
                    get_compression_settings(store).enabled
                json_data["time_series_in_memory"] = isnothing(store.path)
            else
                # Rust backend: write the .nc arrays + standalone .sqlite metadata.
                time_series_base_name =
                    _get_secondary_basename(base, RUST_TIME_SERIES_STORAGE_FILE)
                time_series_storage_file = joinpath(directory, time_series_base_name)
                serialize(store, time_series_storage_file)
                json_data["time_series_storage_file"] = time_series_base_name
                json_data["time_series_storage_type"] = "RustTimeSeriesStore"
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
       strip_module_name(get(raw, "time_series_storage_type", "")) == "RustTimeSeriesStore"
        if !isfile(raw["time_series_storage_file"])
            error("time series file $(raw["time_series_storage_file"]) does not exist")
        end
        # Rust backend: open the .nc + sidecar .sqlite directly.
        time_series_manager = TimeSeriesManager(;
            data_store = open_rust_store(raw["time_series_storage_file"];
                read_only = time_series_read_only),
            read_only = time_series_read_only,
        )
    elseif haskey(raw, "time_series_storage_file")
        error(
            "This system was serialized with the legacy HDF5 time series storage " *
            "(type = $(get(raw, "time_series_storage_type", "unknown"))), which is no " *
            "longer supported. HDF5 storage has been removed in favor of the Rust backend.",
        )
    else
        # The serialized store was empty; create a fresh Rust store honoring the
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
    next_component_id = Int(get(raw, "next_component_id", 1))
    next_supplemental_attribute_id = Int(get(raw, "next_supplemental_attribute_id", 1))
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
        next_component_id,
        next_supplemental_attribute_id,
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
Assign an integer id to a component being attached to `data`, drawn from the component id
stream.

A freshly constructed component has [`UNASSIGNED_ID`](@ref) and receives the next component
id. A component that already carries an id (for example, one restored during
deserialization) keeps it; the counter is advanced past it so future ids do not collide.
Components and supplemental attributes have independent id streams, so a component and an
attribute may share a numeric id.
"""
function assign_id!(data::SystemData, component::InfrastructureSystemsComponent)
    id = get_id(component)
    if id == UNASSIGNED_ID
        id = get_next_component_id!(data)
        set_id!(component, id)
    elseif id >= data.next_component_id
        data.next_component_id = id + 1
    end
    return id
end

"""
Assign an integer id to a supplemental attribute being attached to `data`, drawn from the
supplemental attribute id stream (independent of the component id stream).
"""
function assign_id!(data::SystemData, attribute::SupplementalAttribute)
    id = get_id(attribute)
    if id == UNASSIGNED_ID
        id = get_next_supplemental_attribute_id!(data)
        set_id!(attribute, id)
    elseif id >= data.next_supplemental_attribute_id
        data.next_supplemental_attribute_id = id + 1
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
    ids = isnothing(subsystem_name) ? nothing : get_component_ids(data, subsystem_name)
    return get_components(filter_func, T, data.components; component_ids = ids)
end

function get_components(
    ::Type{T},
    data::SystemData;
    subsystem_name::Union{Nothing, AbstractString} = nothing,
) where {T}
    ids = isnothing(subsystem_name) ? nothing : get_component_ids(data, subsystem_name)
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
    c_ids = isnothing(components) ? Set{Int}() : Set(get_id.(components))
    a_ids = isnothing(attributes) ? Set{Int}() : Set(get_id.(attributes))
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
    for component in get_masked_components(InfrastructureSystemsComponent, data)
        if get_id(component) == id
            return component
        end
    end

    @error "no component with id $id is stored"
    return nothing
end

get_forecast_parameters(
    data::SystemData;
    resolution::Union{Nothing, Dates.Period} = nothing,
    interval::Union{Nothing, Dates.Period} = nothing,
) = _rust_forecast_parameters(
    data.time_series_manager.data_store;
    resolution = resolution,
    interval = interval,
)

function get_forecast_initial_times(data::SystemData; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    isnothing(params) && return []
    return get_initial_times(params.initial_timestamp, params.count, params.interval)
end
function get_forecast_window_count(data::SystemData; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    return isnothing(params) ? nothing : params.count
end
function get_forecast_horizon(data::SystemData; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    return isnothing(params) ? nothing : params.horizon
end
function get_forecast_initial_timestamp(data::SystemData; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    return isnothing(params) ? nothing : params.initial_timestamp
end
function get_forecast_interval(data::SystemData; kwargs...)
    params = get_forecast_parameters(data; kwargs...)
    return isnothing(params) ? nothing : params.interval
end

get_time_series_resolutions(
    data::SystemData;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
) = _rust_get_time_series_resolutions(
    data.time_series_manager.data_store;
    time_series_type = time_series_type,
)

"""
$(TYPEDSIGNATURES)
Group every time series in `data` by the array it is stored in. Returns a
`Dict` mapping each content hash (a 64-character lowercase hex string) to the
`(owner, key)` pairs that resolve to that one shared array.

Time series that share their underlying data appear together: identical data
that was deduplicated, and a `SingleTimeSeries` together with any
`DeterministicSingleTimeSeries` derived from it. A group with more than one
`(owner, key)` pair is therefore a set of time series that share data — across
owners. Resolved by a single catalog query (no per-series reads).

See also [`get_time_series_hash`](@ref) for the hash of one `(owner, key)`.
"""
function get_shared_time_series(data::SystemData)
    store = data.time_series_manager.data_store::RustTimeSeriesStore
    id_to_owner =
        (id, category) -> if category == "Component"
            get_component(data, id)
        else
            get_supplemental_attribute(data, id)
        end
    return _rust_group_by_hash(store, id_to_owner)
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
    get_compression_settings(data.time_series_manager.data_store)

set_name!(data::SystemData, component, name) = set_name!(data.components, component, name)

function get_component_counts_by_type(data::SystemData)
    counts = Dict{String, Int}()
    for (component_type, components) in data.components.data
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
    _rust_get_num_time_series(data.time_series_manager.data_store)
function get_time_series_counts(data::SystemData)
    c = _rust_time_series_counts(data.time_series_manager.data_store)
    return TimeSeriesCounts(;
        components_with_time_series = c.components_with_time_series,
        supplemental_attributes_with_time_series = c.supplemental_attributes_with_time_series,
        static_time_series_count = c.static_time_series_count,
        forecast_count = c.forecast_count,
    )
end
get_time_series_counts_by_type(data::SystemData) =
    _rust_get_time_series_counts_by_type(data.time_series_manager.data_store)
get_static_time_series_summary_table(data::SystemData) =
    _rust_static_summary_table(data.time_series_manager.data_store)
get_forecast_summary_table(data::SystemData) =
    _rust_forecast_summary_table(data.time_series_manager.data_store)

_get_system_basename(system_file) = splitext(basename(system_file))[1]
_get_secondary_basename(system_basename, name) = system_basename * "_" * name

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
    isnothing(data.time_series_manager.data_store.path)

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
    # The approach taken here is to swap out the data we don't want to copy with blank data,
    # then do a deepcopy, then swap it back. We can't just construct a new instance with
    # different fields because we also need to change references within components.
    old_time_series_manager = data.time_series_manager
    old_supplemental_attribute_manager = data.supplemental_attribute_manager

    new_time_series_manager = if skip_time_series
        TimeSeriesManager(; in_memory = true, read_only = true)
    else
        old_time_series_manager
    end
    new_supplemental_attribute_manager = if skip_supplemental_attributes
        SupplementalAttributeManager()
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
    return new_data
end
