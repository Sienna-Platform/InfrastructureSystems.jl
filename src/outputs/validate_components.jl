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
        name = try
            get_name(get_component(data, id))
        catch e
            if e isa ArgumentError
                throw(
                    ArgumentError(
                        "model $model axis $key column $j: id $id: $(e.msg)",
                    ),
                )
            end
            rethrow()
        end
        if name != labels[j, i]
            throw(
                ArgumentError(
                    "model $model axis $key column $j: id $id is named $name in the System, label is $(labels[j, i])",
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
    ad = _read_axis_data(f["/$model/axes/$key"], model, key, ax)
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
row, the name of the component with that id in `data` must equal the stored label.
Throw `ArgumentError` on the first mismatch or missing id. Return `nothing`.
The check is by id and name only, not by component type. Type checking belongs to the
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
