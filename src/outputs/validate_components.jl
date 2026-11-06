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

# Components and supplemental attributes share one id stream, so an id names one object.
function _has_attribute_id(data::SystemData, id::Int)
    return any(d -> haskey(d, id), values(data.supplemental_attribute_manager.data))
end

function _resolve_id(data::SystemData, id::Int, where_::String)
    if haskey(data.component_ids, id)
        return get_component(data, id)
    elseif _has_attribute_id(data, id)
        return get_supplemental_attribute(data, id)
    end
    throw(
        ArgumentError(
            "$where_: id $id is neither a component nor a supplemental attribute of the System",
        ),
    )
end

function _check_column(
    model::AbstractString,
    key::AbstractString,
    j::Int,
    ids::Matrix{Int64},
    labels::Matrix{String},
    data::SystemData,
)
    for i in axes(ids, 2)
        id = ids[j, i]
        where_ = "model $model axis $key column $j"
        name = output_label(_resolve_id(data, id, where_))
        if name != labels[j, i]
            throw(
                ArgumentError(
                    "$where_: id $id is named $name in the System, label is $(labels[j, i])",
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
    ::AbstractAxis,
    ::SystemData,
)
    return
end

function _validate_axis(
    f::HDF5.File,
    model::AbstractString,
    key::AbstractString,
    ax::ComponentAxis,
    data::SystemData,
)
    ad = _read_axis_data(f, model, key, ax)
    if !any(c -> c.has_ids, ax.columns)
        return
    end
    if size(ad.ids) != size(ad.labels)
        throw(
            ArgumentError(
                "model $model axis $key: ids have size $(size(ad.ids)), labels have size $(size(ad.labels))",
            ),
        )
    end
    for (j, col) in enumerate(ax.columns)
        if col.has_ids
            _check_column(model, key, j, ad.ids, ad.labels, data)
        end
    end
    return
end

"""
Check the component axes of `model` against `data`: for every column with ids and every
row, the label of the component or supplemental attribute with that id in `data` (see
`output_label`) must equal the stored label. Throw `ArgumentError` on the first mismatch,
missing id, or attribute type without a label rule. Return `nothing`.
The check is by id and label only, not by component type. Type checking belongs to the
PSY-aware layer.
"""
function validate_components(
    a::OutputArtifact,
    model::AbstractString,
    data::SystemData,
)
    entry = _model_entry(a.metadata, model)
    HDF5.h5open(_h5_path(a), "r") do f
        for (key, ax) in sort!(collect(entry.axes); by = first)
            _validate_axis(f, model, key, ax, data)
        end
    end
    return nothing
end
