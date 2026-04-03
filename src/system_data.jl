
const TIME_SERIES_STORAGE_FILE = "time_series_storage.h5"
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
    "Contains all attached component UUIDs, regular and masked."
    component_uuids::Dict{Base.UUID, <:InfrastructureSystemsComponent}
    "User-defined subystems. Components can be regular or masked."
    subsystems::Dict{String, Set{Base.UUID}}
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
        Dict{Base.UUID, InfrastructureSystemsComponent}(),
        Dict{String, Set{Base.UUID}}(),
        supplemental_attribute_mgr,
        time_series_mgr,
        validation_descriptors,
        InfrastructureSystemsInternal(),
    )
end

function SystemData(
    validation_descriptors,
    time_series_manager,
    subsystems,
    supplemental_attribute_manager,
    internal,
)
    components = Components(time_series_manager, validation_descriptors)
    masked_components = Components(time_series_manager, validation_descriptors)
    return SystemData(
        components,
        masked_components,
        Dict{Base.UUID, InfrastructureSystemsComponent}(),
        subsystems,
        supplemental_attribute_manager,
        time_series_manager,
        validation_descriptors,
        internal,
    )
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
Adds time_series from a metadata file or metadata descriptors.

# Arguments

  - `data::SystemData`: system
  - `::Type{T}`: type of the component associated with time series data; may be abstract
  - `metadata_file::AbstractString`: metadata file for time series
    that includes an array of TimeSeriesFileMetadata instances or a vector.
  - `resolution::DateTime.Period=nothing`: skip time_series that don't match this resolution.
"""
function add_time_series_from_file_metadata!(
    data::SystemData,
    ::Type{T},
    metadata_file::AbstractString;
    resolution = nothing,
) where {T <: InfrastructureSystemsComponent}
    metadata = read_time_series_file_metadata(metadata_file)
    return add_time_series_from_file_metadata!(data, T, metadata; resolution = resolution)
end

"""
Adds time series data from a metadata file or metadata descriptors.

# Arguments

  - `data::SystemData`: system
  - `file_metadata::Vector{TimeSeriesFileMetadata}`: metadata for time series
  - `resolution::DateTime.Period=nothing`: skip time_series that don't match this resolution.
"""
function add_time_series_from_file_metadata!(
    data::SystemData,
    component_type::Type{<:InfrastructureSystemsComponent},
    file_metadata::Vector{TimeSeriesFileMetadata};
    resolution = nothing,
)
    return bulk_add_time_series!(
        data,
        _get_ts_associations_from_metadata(data, component_type, file_metadata, resolution),
    )
end

function _get_ts_associations_from_metadata(
    data::SystemData,
    component_type::Type{<:InfrastructureSystemsComponent},
    file_metadata,
    resolution,
)
    Channel() do channel
        cache = TimeSeriesParsingCache()
        for metadata in file_metadata
            if resolution === nothing || metadata.resolution == resolution
                for association in add_time_series_from_file_metadata_internal!(
                    data,
                    component_type,
                    cache,
                    metadata,
                )
                    put!(channel, association)
                end
            end
        end
    end
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

function add_time_series_from_file_metadata_internal!(
    data::SystemData,
    ::Type{T},
    cache::TimeSeriesParsingCache,
    file_metadata::TimeSeriesFileMetadata,
) where {T <: InfrastructureSystemsComponent}
    TimerOutputs.@timeit_debug SYSTEM_TIMERS "add_time_series_from_file_metadata_internal" begin
        set_component!(file_metadata, data, InfrastructureSystems)
        time_series = make_time_series!(cache, file_metadata)
        add_assignment!(cache, file_metadata)
        return [TimeSeriesAssociation(file_metadata.component, time_series)]
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
    features...,
) where {T <: TimeSeriesData}
    return remove_time_series!(
        data.time_series_manager,
        T,
        owner,
        name;
        resolution = resolution,
        features...,
    )
end

function remove_time_series!(
    data::SystemData,
    owner::TimeSeriesOwners,
    ts_metadata::TimeSeriesMetadata,
)
    return remove_time_series!(data.time_series_manager, owner, ts_metadata)
end

"""
Removes all time series of a particular type from a System.

# Arguments

  - `data::SystemData`: system
  - `type::Type{<:TimeSeriesData}`: Type of time series objects to remove.
  - `resolution::Union{Nothing, Dates.Period} = nothing`: Only remove time series with this
    resolution.
"""
function remove_time_series!(
    data::SystemData,
    ::Type{T};
    resolution::Union{Nothing, Dates.Period} = nothing,
) where {T <: TimeSeriesData}
    _throw_if_read_only(data.time_series_manager)
    for component in iterate_components_with_time_series(
        data;
        time_series_type = T,
        resolution = resolution,
    )
        for ts_metadata in get_time_series_metadata(
            component;
            time_series_type = T,
            resolution = resolution,
        )
            remove_time_series!(data, component, ts_metadata)
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
    _attribute = get_supplemental_attribute(data, get_uuid(attribute))
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
        if name == :component_uuids
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
    uuid = get_uuid(component)
    if !haskey(data.component_uuids, uuid)
        error("Bug: component = $(summary(component)) did not have its uuid stored $uuid")
    end

    pop!(data.component_uuids, uuid)
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
        x in list_owner_uuids_with_time_series(
            data.time_series_manager.metadata_store,
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
        x in list_owner_uuids_with_time_series(
            data.time_series_manager.metadata_store,
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
    check_consistency(data.time_series_manager.metadata_store, ts_type)

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

    all_metadata = Vector{DeterministicMetadata}(undef, length(items))
    components = Vector{InfrastructureSystemsComponent}(undef, length(items))
    for (i, item) in enumerate(items)
        if i > 1
            params1 = items[1].params
            params = item.params
            if params.count != params1.count
                msg =
                    "transform_single_time_series! with horizon = $horizon and " *
                    "interval = $interval will produce Deterministic forecasts with " *
                    "different values for count: $(params.count) $(params1.count)"
                throw(ConflictingInputsError(msg))
            end
            if params.initial_timestamp != params1.initial_timestamp
                msg =
                    "transform_single_time_series! is not supported when " *
                    "SingleTimeSeries have different initial timestamps: " *
                    "$(params.initial_timestamp) $(params1.initial_timestamp)"
                throw(ConflictingInputsError(msg))
            end
        end
        metadata = item.metadata
        params = item.params
        new_metadata = DeterministicMetadata(;
            name = get_name(metadata),
            resolution = get_resolution(metadata),
            initial_timestamp = params.initial_timestamp,
            interval = params.interval,
            count = params.count,
            time_series_uuid = get_time_series_uuid(metadata),
            horizon = params.horizon,
            time_series_type = DeterministicSingleTimeSeries,
            scaling_factor_multiplier = get_scaling_factor_multiplier(metadata),
            internal = InfrastructureSystemsInternal(),
        )
        all_metadata[i] = new_metadata
        components[i] = item.component
    end

    try
        begin_time_series_update(data.time_series_manager) do
            for (component, metadata) in zip(components, all_metadata)
                add_metadata!(data.time_series_manager.metadata_store, component, metadata)
            end
        end
    catch
        # Only remove the metadata entries that were added in this batch so that
        # pre-existing DeterministicSingleTimeSeries from prior calls are preserved.
        for (component, metadata) in zip(components, all_metadata)
            try
                remove_metadata!(
                    data.time_series_manager.metadata_store,
                    component,
                    metadata,
                )
            catch ex
                # The entry may not have been added yet; ignore.
                ex isa ErrorException || rethrow()
            end
        end
        rethrow()
    end
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
    items = list_metadata_with_owner_uuid(
        data.time_series_manager.metadata_store,
        InfrastructureSystemsComponent;
        time_series_type = SingleTimeSeries,
        resolution = resolution,
    )
    system_params = get_forecast_parameters(data.time_series_manager.metadata_store)
    components_with_params_and_metadata = NamedTuple[]
    for item in items
        params = _check_single_time_series_transformed_parameters(
            item.metadata,
            DeterministicSingleTimeSeries,
            horizon,
            interval,
        )
        check_params_compatibility(system_params, params)
        component = get_component(data, item.owner_uuid)

        # We do not allow a component to have both Deterministic and
        # DeterministicSingleTimeSeries with the same parameters.
        # The user might be calling this function because some components are missing
        # Deterministic forecasts. If other components already have Deterministic forecasts,
        # this check will fail.
        # transform_single_time_series! cannot be called at the component level.
        # Note: has_metadata with Deterministic matches both Deterministic and
        # DeterministicSingleTimeSeries due to abstract type dispatch. Use list_metadata
        # and filter to check only for actual Deterministic forecasts.
        ts_name = get_name(item.metadata)
        ts_resolution = get_resolution(item.metadata)
        ts_features = get_features(item.metadata)
        ts_features_symbols = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in ts_features)
        existing_det = list_metadata(
            data.time_series_manager.metadata_store,
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
                data.time_series_manager.metadata_store,
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
    metadata::SingleTimeSeriesMetadata,
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
Set the component value in metadata by looking up the category in module.
This requires that category be a string version of a component's abstract type.
Modules can override for custom behavior.
"""
function set_component!(metadata::TimeSeriesFileMetadata, data::SystemData, mod::Module)
    category = getproperty(mod, Symbol(metadata.category))
    if isconcretetype(category)
        metadata.component =
            get_component(category, data.components, metadata.component_name)
        if isnothing(metadata.component)
            @warn "no component category=$category name=$(metadata.component_name)"
        end
    else
        # Note: this could dispatch to higher-level modules that reimplement it.
        components = get_components_by_name(category, data, metadata.component_name)
        if length(components) == 0
            @warn "no component category=$category name=$(metadata.component_name)"
            metadata.component = nothing
        elseif length(components) == 1
            metadata.component = components[1]
        else
            throw(
                DataFormatError(
                    "duplicate names type=$(category) name=$(metadata.component_name)",
                ),
            )
        end
    end
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
    files = [
        filename,
        joinpath(directory, _get_secondary_basename(sys_base, TIME_SERIES_STORAGE_FILE)),
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

            if isempty(data.time_series_manager.data_store)
                json_data["time_series_compression_enabled"] =
                    get_compression_settings(data.time_series_manager.data_store).enabled
                json_data["time_series_in_memory"] =
                    data.time_series_manager.data_store isa InMemoryTimeSeriesStorage
            else
                time_series_base_name =
                    _get_secondary_basename(base, TIME_SERIES_STORAGE_FILE)
                time_series_storage_file = joinpath(directory, time_series_base_name)
                serialize(data.time_series_manager.data_store, time_series_storage_file)
                to_h5_file(
                    data.time_series_manager.metadata_store,
                    time_series_storage_file,
                )
                json_data["time_series_storage_file"] = time_series_base_name
                json_data["time_series_storage_type"] =
                    string(typeof(data.time_series_manager.data_store))
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

    if haskey(raw, "time_series_storage_file")
        if !isfile(raw["time_series_storage_file"])
            error("time series file $(raw["time_series_storage_file"]) does not exist")
        end
        # TODO: need to address this limitation
        if strip_module_name(raw["time_series_storage_type"]) == "InMemoryTimeSeriesStorage"
            @info "Deserializing with InMemoryTimeSeriesStorage is currently not supported. Using HDF"
            #hdf5_storage = Hdf5TimeSeriesStorage(raw["time_series_storage_file"], true)
            #time_series_storage = InMemoryTimeSeriesStorage(hdf5_storage)
        end
        time_series_storage = from_file(
            Hdf5TimeSeriesStorage,
            raw["time_series_storage_file"];
            directory = time_series_directory,
            read_only = time_series_read_only,
        )
        time_series_metadata_store = from_h5_file(
            TimeSeriesMetadataStore,
            time_series_storage.file_path,
            time_series_directory,
        )
    else
        time_series_storage = make_time_series_storage(;
            compression = CompressionSettings(;
                enabled = get(raw, "time_series_compression_enabled", DEFAULT_COMPRESSION),
            ),
            directory = time_series_directory,
        )
        time_series_metadata_store = nothing
    end

    time_series_manager = TimeSeriesManager(;
        data_store = time_series_storage,
        read_only = time_series_read_only,
        metadata_store = time_series_metadata_store,
    )
    subsystems = Dict(k => Set(Base.UUID.(v)) for (k, v) in raw["subsystems"])
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
        subsystems,
        supplemental_attribute_manager,
        internal,
    )
    attributes_by_uuid = Dict{Base.UUID, SupplementalAttribute}()
    for attr_dict in values(supplemental_attribute_manager.data)
        for attr in values(attr_dict)
            uuid = get_uuid(attr)
            if haskey(attributes_by_uuid, uuid)
                error("Bug: Found duplicate supplemental attribute UUID: $uuid")
            end
            attributes_by_uuid[uuid] = attr
        end
    end

    system_component_uuids = Set{Base.UUID}()
    for component in Iterators.Flatten((raw["components"], raw["masked_components"]))
        push!(system_component_uuids, UUIDs.UUID(component["internal"]["uuid"]["value"]))
    end

    for (name, subsystem_component_uuids) in sys.subsystems
        if !issubset(subsystem_component_uuids, system_component_uuids)
            diff = setdiff(subsystem_component_uuids, system_component_uuids)
            error("Subsystem $name has component UUIDs that are not in the system: $diff")
        end
    end

    # Note: components need to be deserialized by the parent so that they can go through
    # the proper checks.
    return sys
end

# Redirect functions to Components

function add_component!(data::SystemData, component; kwargs...)
    _check_add_component(data, component)
    add_component!(data.components, component; kwargs...)
    data.component_uuids[get_uuid(component)] = component
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
    data.component_uuids[get_uuid(component)] = component
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
    _check_duplicate_component_uuid(data, component)
    if !isnothing(get_shared_system_references(component))
        error("$(summary(component)) is already attached to a system")
    end
end

function _check_duplicate_component_uuid(data::SystemData, component)
    uuid = get_uuid(component)
    if haskey(data.component_uuids, uuid)
        throw(ArgumentError("Component $(summary(component)) uuid=$uuid is already stored"))
    end
end

iterate_components(data::SystemData) = iterate_components(data.components)

get_component(::Type{T}, data::SystemData, args...) where {T} =
    get_component(T, data.components, args...)

function get_component(data::SystemData, uuid::Base.UUID)
    component = get(data.component_uuids, uuid, nothing)
    if isnothing(component)
        throw(ArgumentError("No component with uuid = $uuid is stored."))
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
    return get_uuid(component) in keys(data.component_uuids)
end

function assign_new_uuid!(data::SystemData, component::InfrastructureSystemsComponent)
    orig_uuid = get_uuid(component)
    if isnothing(pop!(data.component_uuids, orig_uuid, nothing))
        throw(ArgumentError("component with uuid = $orig_uuid is not stored."))
    end

    assign_new_uuid_internal!(component)
    data.component_uuids[get_uuid(component)] = component
    return
end

function get_components(
    filter_func::Function,
    ::Type{T},
    data::SystemData;
    subsystem_name::Union{Nothing, AbstractString} = nothing,
) where {T}
    uuids = isnothing(subsystem_name) ? nothing : get_component_uuids(data, subsystem_name)
    return get_components(filter_func, T, data.components; component_uuids = uuids)
end

function get_components(
    ::Type{T},
    data::SystemData;
    subsystem_name::Union{Nothing, AbstractString} = nothing,
) where {T}
    uuids = isnothing(subsystem_name) ? nothing : get_component_uuids(data, subsystem_name)
    return get_components(T, data.components; component_uuids = uuids)
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
        list_associated_component_uuids(
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
        list_associated_supplemental_attribute_uuids(
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
        list_associated_component_uuids(
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
    c_uuids = isnothing(components) ? Set{Base.UUID}() : Set(get_uuid.(components))
    a_uuids = isnothing(attributes) ? Set{Base.UUID}() : Set(get_uuid.(attributes))
    for (component_uuid, attribute_uuid) in
        list_associated_pair_uuids(
        data.supplemental_attribute_manager.associations,
        U,
        T,
    )
        if !isnothing(components) && !(component_uuid in c_uuids)
            continue
        end
        if !isnothing(attributes) && !(attribute_uuid in a_uuids)
            continue
        end
        component = get_component(data, component_uuid)

        attribute = get_supplemental_attribute(data, attribute_uuid)
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

function get_masked_component(data::SystemData, uuid::Base.UUID)
    for component in get_masked_components(InfrastructureSystemsComponent, data)
        if get_uuid(component) == uuid
            return component
        end
    end

    @error "no component with UUID $uuid is stored"
    return nothing
end

get_forecast_initial_times(data::SystemData) =
    get_forecast_initial_times(data.time_series_manager.metadata_store)
get_forecast_window_count(data::SystemData) =
    get_forecast_window_count(data.time_series_manager.metadata_store)
get_forecast_horizon(data::SystemData) =
    get_forecast_horizon(data.time_series_manager.metadata_store)
get_forecast_initial_timestamp(data::SystemData) =
    get_forecast_initial_timestamp(data.time_series_manager.metadata_store)
get_forecast_interval(data::SystemData) =
    get_forecast_interval(data.time_series_manager.metadata_store)

get_time_series_resolutions(
    data::SystemData;
    time_series_type::Union{Type{<:TimeSeriesData}, Nothing} = nothing,
) = get_time_series_resolutions(
    data.time_series_manager.metadata_store;
    time_series_type = time_series_type,
)

function get_forecast_total_period(data::SystemData)
    params = get_forecast_parameters(data.time_series_manager.metadata_store)
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
    get_num_time_series(data.time_series_manager.metadata_store)
get_time_series_counts(data::SystemData) =
    get_time_series_counts(data.time_series_manager.metadata_store)
get_time_series_counts_by_type(data::SystemData) =
    get_time_series_counts_by_type(data.time_series_manager.metadata_store)
get_static_time_series_summary_table(data::SystemData) =
    get_static_time_series_summary_table(data.time_series_manager.metadata_store)
get_forecast_summary_table(data::SystemData) =
    get_forecast_summary_table(data.time_series_manager.metadata_store)

_get_system_basename(system_file) = splitext(basename(system_file))[1]
_get_secondary_basename(system_basename, name) = system_basename * "_" * name

function add_supplemental_attribute!(data::SystemData, component, attribute; kwargs...)
    # Note that we do not support adding attributes to masked components
    # and this check doesn't look at those.
    throw_if_not_attached(data.components, component)
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

function get_supplemental_attribute(data::SystemData, uuid::Base.UUID)
    return get_supplemental_attribute(data.supplemental_attribute_manager, uuid)
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
    data.time_series_manager.data_store isa InMemoryTimeSeriesStorage

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
        TimeSeriesManager(InMemoryTimeSeriesStorage(), TimeSeriesMetadataStore(), true, nothing)
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
