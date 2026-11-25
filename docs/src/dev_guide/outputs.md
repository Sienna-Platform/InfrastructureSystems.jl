# Outputs Artifact

The outputs artifact is a directory with `outputs.json`, `outputs.h5`, and one bundle per serialized system.
Packages that run models write it with `OutputsWriter`, and any package can read it with `OutputsReader`.

## Call diagram

```text
Write
  dataset_descriptor
        |
        v
  OutputsDocument
        |
        v
  open_outputs_writer ..........> validate_document
        |
        v
  OutputsWriter
        |
        v
  write_execution! / write_values! / write_table!
        |
        |  for each execution (optional)
        |-----------------------> flush
        |
        v
  finalize! / abort!
        |
        v
    artifact
        |
        v
Read
  open_outputs_reader ..........> validate_document
        |
        v
  OutputsReader
        |------------------------------+
        v                              v
  read_dataset / read_table /     validate_components
  read_axis_data
```

## Glossary

| Term            | Meaning                                                                             |
|:--------------- |:----------------------------------------------------------------------------------- |
| artifact        | The directory with `outputs.json`, `outputs.h5`, and the system bundles             |
| document        | The content of `outputs.json`, an `OutputsDocument`                                 |
| model           | One `Model` object of the document                                                  |
| model name      | The `name` string of a model                                                        |
| dataset         | One dense array that a model declares                                               |
| HDF5 dataset    | One node of the HDF5 file                                                           |
| table           | A set of 1-D columns with one length                                                |
| dataset key     | The tuple `(entry_type, component_type, meta)` that identifies a dataset in a model |
| axis name       | The string that identifies an axis in a model                                       |
| key type        | A subtype of `IS.Optimization.OptimizationKeyType`                                  |
| id              | The integer id of a component or of a supplemental attribute in its system          |
| uuid            | The UUID of a system                                                                |
| execution index | The position on the execution axis, from 1                                          |
| label           | One string entry of a component axis or of a label axis                             |
| bundle          | The directory of one serialized system in the artifact                              |

## Example

```julia
using InfrastructureSystems, Dates, Test
import InfrastructureOutputSchemas
const IS = InfrastructureSystems

IOS = InfrastructureOutputSchemas
dir = mktempdir()
system_uuid = "11111111-2222-3333-4444-555555555555"
bundle = "system-1"

# 1. Declare the axes of the model.
time_axis = IOS.TimeAxis(;
    kind = "time", initial_timestamp = "2024-01-01T00:00:00", resolution = "PT1H",
    length = 3, group = "/model/axes/time",
)
bus_axis = IOS.ComponentAxis(;
    kind = "component", length = 2, group = "/model/axes/Bus",
    columns = [IOS.ComponentAxisColumnsItem(; component_type = "Bus", has_ids = false)],
)

# 2. Declare one dataset. It names its axes in storage order.
dataset = IOS.Dataset(;
    container = IOS.Container("variables"), entry_type = "PowerInjection",
    component_type = "Bus", meta = "", axes = ["time", "Bus"],
    dtype = IOS.Dtype("f64"), fill_value = "NaN", quantity_kind = "ActivePower",
    unit_system = IOS.UnitSystem("SYSTEM_BASE"), units = "pu",
    layout = IOS.DatasetLayout(; chunks = [3, 2], filters = ["shuffle"]),
    path = "/model/datasets/PowerInjection__Bus",
)

# 3. Put the model in a document.
model = IOS.Model(;
    name = "model", model_type = "emulation", system_uuid = system_uuid,
    base_power = 100.0, supports_realized_values_post_calculation = false,
    settings = IOS.ModelSettings(; additional_properties = Dict{String, Any}()),
    axes = [IOS.Axis(time_axis), IOS.Axis(bus_axis)], datasets = [dataset],
)
doc = IOS.OutputsDocument(;
    schema_version = IS.OUTPUTS_SCHEMA_VERSION, kind = "single",
    producer = IOS.ProducerInfo(;
        package = "Example", version = "0.1.0", julia = string(VERSION),
    ),
    created_at = IS.TimeZones.now(IS.TimeZones.TimeZone("UTC")),
    status = IOS.RunStatus("RUNNING"),
    systems = IOS.OutputsDocumentSystems(;
        additional_properties = Dict(system_uuid => bundle),
    ),
    models = [model],
)

# 4. Give the data of each time axis and each component axis, by model name and axis name.
timestamps = [Dates.DateTime(2024, 1, 1) + Dates.Hour(i) for i in 0:2]
axis_data = Dict(
    ("model", "time") => IS.AxisData(timestamps),
    ("model", "Bus") =>
        IS.AxisData(zeros(Int64, 0, 0), ["bus1" "bus2"], Dates.DateTime[]),
)

# 5. Write. The array is in Julia order: the reverse of the dataset axes.
writer = IS.open_outputs_writer(dir, doc; axis_data = axis_data)
values = [1.0 2.0 3.0; 4.0 5.0 6.0]
IS.write_values!(writer, "model", ("PowerInjection", "Bus", ""), values)
mkpath(joinpath(dir, bundle))  # The package that owns the system writes its bundle here.
IS.finalize!(writer; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)

# 6. Read.
reader = IS.open_outputs_reader(dir)
read_values, axis_names = IS.read_dataset(reader, "model", "PowerInjection", "Bus")
@test read_values == values
@test axis_names == ["Bus", "time"]
@test IS.read_axis_data(reader, "model", "time").timestamps == timestamps
@test IS.read_axis_data(reader, "model", "Bus").labels == ["bus1" "bus2"]
@test string(IS.get_document(reader).status) == "SUCCESSFULLY_FINALIZED"
```

`test/test_outputs_example.jl` runs this code.
A producer that has a key type builds the dataset of step 2 with `IS.dataset_descriptor(T, U, meta; model, axes, axis_lengths)`.
