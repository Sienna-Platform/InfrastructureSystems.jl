"""
Return the label that an outputs axis stores for a component or supplemental attribute: the
component name. A supplemental attribute type has no label rule in IS. A package that puts
attributes on a component axis implements `output_label` for its attribute types.
"""
function output_label end
output_label(c::InfrastructureSystemsComponent) = get_name(c)

function output_label(a::SupplementalAttribute)
    throw(
        ArgumentError(
            "supplemental attribute type $(typeof(a)) has no output label: implement IS.output_label for it",
        ),
    )
end

function _resolve_id(data::SystemData, id::Int, where_::String)
    # Components and supplemental attributes share one id stream, so an id names one object.
    if haskey(data.component_ids, id)
        return get_component(data, id)
    elseif any(d -> haskey(d, id), values(data.supplemental_attribute_manager.data))
        return get_supplemental_attribute(data, id)
    end
    throw(
        ArgumentError(
            "$where_: id $id is neither a component nor a supplemental attribute of the System",
        ),
    )
end

function _check_column(
    model_name::AbstractString,
    name::AbstractString,
    j::Int,
    ids::Matrix{Int64},
    labels::Matrix{String},
    data::SystemData,
)
    for i in axes(ids, 2)
        id = ids[j, i]
        where_ = "model $model_name axis $name column $j"
        label = output_label(_resolve_id(data, id, where_))
        if label != labels[j, i]
            throw(
                ArgumentError(
                    "$where_: id $id is named $label in the System, label is $(labels[j, i])",
                ),
            )
        end
    end
    return
end

function _validate_axis(
    ::HDF5.File,
    ::AbstractString,
    ::AbstractString,
    ::OutputAxis,
    ::SystemData,
)
    return
end

function _validate_axis(
    f::HDF5.File,
    model_name::AbstractString,
    name::AbstractString,
    axis::ComponentAxis,
    data::SystemData,
)
    axis_data = _read_axis_data(f, model_name, name, axis)
    expected = (length(axis.columns), axis_length(axis))
    if size(axis_data.labels) != expected
        throw(
            ArgumentError(
                "model $model_name axis $name: labels have size $(size(axis_data.labels)), expected $expected",
            ),
        )
    end
    if !any(column -> column.has_ids, axis.columns)
        return
    end
    if size(axis_data.ids) != expected
        throw(
            ArgumentError(
                "model $model_name axis $name: ids have size $(size(axis_data.ids)), expected $expected",
            ),
        )
    end
    for (j, column) in enumerate(axis.columns)
        if column.has_ids
            _check_column(model_name, name, j, axis_data.ids, axis_data.labels, data)
        end
    end
    return
end

"""
Check the component axes of the model `model_name` against `data`: for every column with
ids and every row, the label of the component or supplemental attribute with that id in
`data` (see `output_label`) must equal the stored label. Throw `ArgumentError` on the first
mismatch, missing id, or attribute type without a label rule. Return `nothing`.
The check is by id and label only, not by component type. Type checking belongs to the
PSY-aware layer.
"""
function validate_components(
    reader::OutputsReader,
    model_name::AbstractString,
    data::SystemData,
)
    model = _find_model(reader.document, model_name)
    HDF5.h5open(_h5_path(reader), "r") do f
        for axis in sort!(copy(model.axes); by = axis_name)
            _validate_axis(f, model_name, axis_name(axis), axis, data)
        end
    end
    return nothing
end
