function show_time_series_data(io::IO, data::SystemData; kwargs...)
    table = get_static_time_series_summary_table(data)
    if !isempty(table)
        PrettyTables.pretty_table(
            io,
            table;
            title = "StaticTimeSeries Summary",
            alignment = :l,
            kwargs...,
        )
    end
    table = get_forecast_summary_table(data)
    if !isempty(table)
        PrettyTables.pretty_table(
            io,
            table;
            title = "Forecast Summary",
            alignment = :l,
            kwargs...,
        )
    end
    return
end

function show_supplemental_attributes_data(io::IO, data::SystemData; kwargs...)
    table = get_supplemental_attribute_summary_table(data)
    if !isempty(table)
        PrettyTables.pretty_table(
            io,
            table;
            title = "Supplemental Attribute Summary",
            alignment = :l,
            kwargs...,
        )
    end
    return
end

function show_container_table(io::IO, container::InfrastructureSystemsContainer; kwargs...)
    column_labels = ["Type", "Count", "Has Static Time Series", "Has Forecasts"]
    data = Array{Any, 2}(undef, length(container.data), length(column_labels))

    type_names = [(strip_module_name(x), x) for x in keys(container.data)]
    sort!(type_names; by = x -> x[1])
    for (i, (type_name, type)) in enumerate(type_names)
        vals = container.data[type]
        has_sts = false
        has_forecasts = false
        for val in values(vals)
            if has_time_series(val, StaticTimeSeries)
                has_sts = true
            end
            if has_time_series(val, Forecast)
                has_forecasts = true
            end
            if has_sts && has_forecasts
                break
            end
        end
        data[i, 1] = type_name
        data[i, 2] = length(vals)
        data[i, 3] = has_sts
        data[i, 4] = has_forecasts
    end

    PrettyTables.pretty_table(
        io,
        data;
        column_labels = column_labels,
        alignment = :l,
        kwargs...,
    )
    return
end

# Resolve each additional column's getter function and units argument once for a
# concrete `component_type` — the units trait is constant across rows. Returns a vector
# of `(column, getter_func, arg)` tuples. The getter logic enables application of system
# units in PowerSystems through its getter functions. Dict-form `additional_columns`
# carry their own accessor closures, so there is nothing to resolve (returns `nothing`).
_resolve_column_accessors(::Type, ::Dict) = nothing

function _resolve_column_accessors(component_type::Type, additional_columns::Vector)
    parent = parentmodule(component_type)
    return map(additional_columns) do column
        getter_name = Symbol("get_$column")
        getter_func = if hasproperty(parent, getter_name)
            Base.getproperty(parent, getter_name)
        else
            nothing
        end
        arg = if getter_func === nothing
            missing
        else
            display_units_arg(getter_func, component_type)
        end
        (column, getter_func, arg)
    end
end

# Resolve a single cell value for `column` on `component`. Nested components and
# component vectors are summarized; otherwise the resolved getter is applied, passing
# the units argument when one is available.
function _populate_column_value(component, column, getter_func, arg)
    val = Base.getproperty(component, column)
    if val isa InfrastructureSystemsType ||
       val isa Vector{<:InfrastructureSystemsComponent}
        return summary(val)
    elseif getter_func !== nothing
        if ismissing(arg)
            return getter_func(component)
        else
            return getter_func(component, arg)
        end
    end
    return val
end

function show_components(
    io::IO,
    components::Components,
    component_type::Type{<:InfrastructureSystemsComponent},
    additional_columns::Union{Dict, Vector} = [];
    kwargs...,
)
    if !isconcretetype(component_type)
        error("$component_type must be a concrete type")
    end

    title = strip_module_name(component_type)
    column_labels = ["name"]
    has_available = false
    if :available in fieldnames(component_type)
        push!(column_labels, "available")
        has_available = true
    end

    if additional_columns isa Dict
        columns = sort!(collect(keys(additional_columns)))
    else
        columns = additional_columns
    end

    for column in columns
        push!(column_labels, string(column))
    end

    comps = get_components(component_type, components)
    data = Array{Any, 2}(undef, length(comps), length(column_labels))

    # Resolve each column's getter and units argument once, not per cell.
    column_accessors = _resolve_column_accessors(component_type, additional_columns)

    for (i, component) in enumerate(comps)
        data[i, 1] = get_name(component)
        j = 2
        if has_available
            data[i, 2] = Base.getproperty(component, :available)
            j += 1
        end

        if additional_columns isa Dict
            for column in columns
                data[i, j] = additional_columns[column](component)
                j += 1
            end
        else
            for (column, getter_func, arg) in column_accessors
                data[i, j] = _populate_column_value(component, column, getter_func, arg)
                j += 1
            end
        end
    end

    PrettyTables.pretty_table(
        io,
        data;
        column_labels = column_labels,
        title = title,
        alignment = :l,
        kwargs...,
    )
    return
end

function show_supplemental_attributes(io::IO, component::InfrastructureSystemsComponent)
    data_by_type = Dict{Any, Vector{OrderedDict{String, Any}}}()
    for attribute in get_supplemental_attributes(component)
        if !haskey(data_by_type, typeof(attribute))
            data_by_type[typeof(attribute)] = Vector{OrderedDict{String, Any}}()
        end
        data = OrderedDict{String, Any}()
        for field in fieldnames(typeof(attribute))
            if field != :internal
                data[string(field)] = Base.getproperty(attribute, field)
            end
        end
        push!(data_by_type[typeof(attribute)], data)
    end
    for (type, rows) in data_by_type
        PrettyTables.pretty_table(io, DataFrame(rows); title = string(nameof(type)))
    end
end

function show_time_series(io::IO, owner::TimeSeriesOwners)
    data_by_type = Dict{Any, Vector{OrderedDict{String, Any}}}()
    for key in get_time_series_keys(owner)
        ts_type = get_time_series_type(key)
        if !haskey(data_by_type, ts_type)
            data_by_type[ts_type] = Vector{OrderedDict{String, Any}}()
        end
        data = OrderedDict{String, Any}()
        for (fname, ftype) in zip(fieldnames(typeof(key)), fieldtypes(typeof(key)))
            if ftype <: Type{<:TimeSeriesData}
                data[string(fname)] = string(nameof(Base.getproperty(key, fname)))
            else
                data[string(fname)] = Base.getproperty(key, fname)
            end
        end
        push!(data_by_type[ts_type], data)
    end
    for rows in values(data_by_type)
        PrettyTables.pretty_table(io, DataFrame(rows))
    end
end

function show_recorder_events(
    io::IO,
    events::Vector{T};
    exclude_columns = Set{String}(),
    kwargs...,
) where {T <: AbstractRecorderEvent}
    if isempty(events)
        @warn "Found no events of type $T"
        return
    end

    column_labels = [x for x in ("timestamp", "name") if !(x in exclude_columns)]
    for (fieldname, fieldtype) in zip(fieldnames(T), fieldtypes(T))
        if !(fieldtype <: RecorderEventCommon)
            push!(column_labels, string(fieldname))
        end
    end

    data = Array{Any, 2}(undef, length(events), length(column_labels))
    for (i, event) in enumerate(events)
        col_index = 1
        if !("timestamp" in exclude_columns)
            data[i, col_index] = get_timestamp(event)
            col_index += 1
        end
        if !("name" in exclude_columns)
            data[i, col_index] = get_name(event)
            col_index += 1
        end
        for (fieldname, fieldtype) in zip(fieldnames(T), fieldtypes(T))
            if !(fieldtype <: RecorderEventCommon) && !(fieldname in exclude_columns)
                data[i, col_index] = getproperty(event, fieldname)
                col_index += 1
            end
        end
    end

    PrettyTables.pretty_table(io, data; column_labels = column_labels, kwargs...)
    return
end
