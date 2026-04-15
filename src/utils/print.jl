
const MAX_SHOW_COMPONENTS = 10
const MAX_SHOW_FORECASTS = 10
const MAX_SHOW_FORECAST_INITIAL_TIMES = 1

function Base.summary(container::InfrastructureSystemsContainer)
    return "$(typeof(container)): $(get_num_members(container))"
end

function Base.show(io::IO, container::InfrastructureSystemsContainer)
    i = 1
    for component in iterate_container(container)
        if i <= MAX_SHOW_COMPONENTS
            show(io, component)
            println(io)
        end
        i += 1
    end

    if i > MAX_SHOW_COMPONENTS
        num = i - MAX_SHOW_COMPONENTS
        println(io, "\n***Omitted $num $(get_display_string(container))***\n")
    end
end

function Base.show(io::IO, ::MIME"text/plain", container::InfrastructureSystemsContainer)
    num_members = get_num_members(container)
    title = get_display_string(container)
    member_str = get_member_string(container)
    println(io, title)
    println(io, "="^length(title))
    println(io, "Num $member_str: $num_members")
    if num_members > 0
        println(io)
        show_container_table(io, container; backend = :auto)
    end
end

function Base.show(io::IO, ::MIME"text/html", container::InfrastructureSystemsContainer)
    num_members = get_num_members(container)
    member_str = get_member_string(container)
    println(io, "<h2>Members</h2>")
    println(io, "<p><b>Num $member_str</b>: $num_members</p>")
    if num_members > 0
        show_container_table(io, container; backend = :html, stand_alone = false)
    end
end

make_label(type::Type{<:InfrastructureSystemsType}, name) = "$(nameof(type)): $name"
Base.summary(x::InfrastructureSystemsComponent) = make_label(typeof(x), get_name(x))
Base.summary(x::SupplementalAttribute) = make_label(typeof(x), get_uuid(x))
Base.summary(x::TimeSeriesData) = make_label(typeof(x), get_name(x))
Base.summary(x::TimeSeriesMetadata) = make_label(typeof(x), get_name(x))

function Base.summary(x::Forecast)
    label = make_label(typeof(x), get_name(x))
    resolution = Dates.canonicalize(get_resolution(x))
    interval = Dates.canonicalize(get_interval(x))
    return "$(label) resolution=$(resolution) interval=$(interval)"
end

function Base.summary(x::ForecastMetadata)
    label = make_label(typeof(x), get_name(x))
    resolution = Dates.canonicalize(get_resolution(x))
    interval = Dates.canonicalize(get_interval(x))
    return "$(label) resolution=$(resolution) interval=$(interval)"
end

function Base.show(io::IO, data::SystemData)
    show(io, data.components)
    println(io, "\n")
    show_time_series_data(io, data)
    show_supplemental_attributes_data(io, data)
end

function Base.show(io::IO, ::MIME"text/plain", data::SystemData)
    show(io, MIME"text/plain"(), data.components)
    println(io, "\n")
    show(io, MIME"text/plain"(), data.supplemental_attribute_manager)
    println(io, "\n")
    show_time_series_data(io, data; backend = :auto)
    show_supplemental_attributes_data(io, data; backend = :auto)
end

function Base.show(io::IO, ::MIME"text/html", data::SystemData)
    show(io, MIME"text/html"(), data.components)
    println(io, "\n")
    show(io, MIME"text/html"(), data.supplemental_attribute_manager)
    println(io, "\n")
    show_time_series_data(io, data; backend = :html, stand_alone = false)
    show_supplemental_attributes_data(io, data; backend = :html, stand_alone = false)
end

function Base.show(io::IO, ::MIME"text/plain", system_units::SystemUnitsSettings)
    print(io, summary(system_units), ":")
    for name in fieldnames(typeof(system_units))
        val = getproperty(system_units, name)
        print(io, "\n      ", name, ": ", val)
    end
end

function Base.show(io::IO, ::MIME"text/plain", ist::TimeSeriesOwners)
    print(io, summary(ist), ":")
    for name in fieldnames(typeof(ist))
        obj = getfield(ist, name)
        if obj isa InfrastructureSystemsInternal
            continue
        elseif obj isa InfrastructureSystemsType
            val = summary(getproperty(ist, name))
        elseif obj isa Vector{<:InfrastructureSystemsComponent}
            val = summary(getproperty(ist, name))
        else
            val = getproperty(ist, name)
        end
        print(io, "\n   ", name, ": ", val)
    end
    print(io, "\n   ", "has_time_series", ": ", string(has_time_series(ist)))
end

function Base.show(io::IO, ist::TimeSeriesOwners)
    print(io, strip_module_name(typeof(ist)), "(")
    is_first = true
    for (name, field_type) in zip(fieldnames(typeof(ist)), fieldtypes(typeof(ist)))
        if field_type <: InfrastructureSystemsInternal
            continue
        else
            val = getproperty(ist, name)
        end
        if is_first
            is_first = false
        else
            print(io, ", ")
        end
        print(io, val)
    end
    print(io, ")")
    return
end

function Base.show(io::IO, ::MIME"text/plain", internal::InfrastructureSystemsInternal)
    print(io, summary(internal), ":")
    for name in fieldnames(typeof(internal))
        name == :shared_system_references && continue
        val = getproperty(internal, name)
        print(io, "\n   ", name, ": ", val)
    end
end

function Base.show(io::IO, ::MIME"text/plain", it::FlattenIteratorWrapper)
    println(io, "$(eltype(it)) Counts: ")
    for (ctype, count) in _get_type_counts(it)
        println(io, "$ctype: $count")
    end
end

function _get_type_counts(it::FlattenIteratorWrapper)
    data = SortedDict()
    for component in it
        ctype = string(typeof(component))
        if !haskey(data, ctype)
            data[ctype] = 1
        else
            data[ctype] += 1
        end
    end

    return data
end

"""
Show a table with supplemental attributes attached to the component.
"""
function show_supplemental_attributes(component::InfrastructureSystemsComponent)
    show_supplemental_attributes(stdout, component)
end

"""
Show a table with time series data attached to the component.
"""
function show_time_series(owner::TimeSeriesOwners)
    show_time_series(stdout, owner)
end

## This function takes in a time period or date period and returns a compound period
function convert_compound_period(period::Union{Dates.TimePeriod, Dates.DatePeriod})
    period = time_period_conversion(period)

    milli_weeks = period - (period % Dates.Millisecond(604800000))
    weeks = convert(Dates.Week, milli_weeks)
    period -= milli_weeks

    milli_days = period - (period % Dates.Millisecond(86400000))
    days = convert(Dates.Day, milli_days)
    period -= milli_days

    milli_hours = period - (period % Dates.Millisecond(3600000))
    hours = convert(Dates.Hour, milli_hours)
    period -= milli_hours

    milli_minutes = period - (period % Dates.Millisecond(60000))
    minutes = convert(Dates.Minute, milli_minutes)
    period -= milli_minutes

    seconds = period - (period % Dates.Millisecond(1000)) # finding the seconds
    seconds = convert(Dates.Second, seconds)
    remainder = period % Dates.Millisecond(1000) #finding the remainding milliseconds
    total = weeks + days + hours + minutes + seconds + remainder
    return total
end
