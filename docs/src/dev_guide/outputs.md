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
        |                        write_outputs_document
        |                              |
        |                              v
        |                        to_openapi -> encode
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
        |                        read_outputs_document
        |                              |
        |                              v
        |                        decode -> from_openapi
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
| document        | The content of `outputs.json`, an `IS.OutputsDocument`                              |
| model           | One `IS.OutputsModel` of the document                                               |
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

## The OpenAPI serde

The IS types (`IS.OutputsDocument`, `IS.OutputsModel`, and the axis and dataset types) are the model of the artifact, and all IS logic uses them.
`src/outputs/openapi_serde.jl` is the only file that names `InfrastructureOutputSchemas`: `to_openapi` and `from_openapi` convert between the IS types and the generated structs, and the generated `encode` and `decode` read and write the JSON.
IS derives the axis `kind`, `group`, and `path` from the other fields, so a producer never sets them.

## Example

```julia
using InfrastructureSystems, Dates, Test
const IS = InfrastructureSystems

struct ExampleFlowVariable <: IS.Optimization.VariableType end
IS.Optimization.output_unit_system(::Type{ExampleFlowVariable}) = IS.NU
IS.Optimization.quantity_kind(::Type{ExampleFlowVariable}) = "VolumeFlow"
IS.Optimization.natural_units(::Type{ExampleFlowVariable}) = "m3/s"
struct ExamplePipe end

dir = mktempdir()
system_uuid = "11111111-2222-3333-4444-555555555555"
bundle = "system-1"

# 1. Declare the axes of the model.
time_axis = IS.TimeAxis(Dates.DateTime(2024, 1, 1), Dates.Hour(1), 3)
pipe_axis = IS.ComponentAxis([IS.ComponentAxisColumn("ExamplePipe", false)], 2)

# 2. Declare one dataset. It names its axes in storage order.
dataset = IS.dataset_descriptor(
    ExampleFlowVariable, ExamplePipe, "", IS.OutputAxis[time_axis, pipe_axis],
)

# 3. Put the model in a document.
model = IS.OutputsModel(;
    name = "model", model_type = "emulation", system_uuid = system_uuid,
    base_power = 100.0, supports_realized_values_post_calculation = false,
    settings = Dict{String, Any}(),
    axes = IS.OutputAxis[time_axis, pipe_axis], datasets = [dataset],
)
producer = IS.ProducerInfo("Example", "0.1.0", string(VERSION))
doc = IS.OutputsDocument("single", producer, Dict(system_uuid => bundle), [model])

# 4. Give the data of each component axis, by model name and axis name.
axis_data = Dict(
    ("model", IS.axis_name(pipe_axis)) =>
        IS.AxisData(zeros(Int64, 0, 0), ["pipe1" "pipe2"]),
)

# 5. Write. The array is in Julia order: the reverse of the dataset axes.
writer = IS.open_outputs_writer(dir, doc; axis_data = axis_data)
values = [1.0 2.0 3.0; 4.0 5.0 6.0]
IS.write_values!(writer, "model", IS.dataset_key(dataset), values)
mkpath(joinpath(dir, bundle))  # The package that owns the system writes its bundle here.
IS.finalize!(writer; status = IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED)

# 6. Read.
reader = IS.open_outputs_reader(dir)
read_values, axis_names =
    IS.read_dataset(reader, "model", "ExampleFlowVariable", "ExamplePipe")
@test read_values == values
@test axis_names == ["ExamplePipe", "time"]
@test IS.get_timestamps(IS.read_axis_data(reader, "model", "time")) ==
      IS.axis_timestamps(time_axis)
@test IS.get_labels(IS.read_axis_data(reader, "model", "ExamplePipe")) == ["pipe1" "pipe2"]
@test IS.get_status(IS.get_document(reader)) ==
      IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED
```

`test/test_outputs_example.jl` runs this code.
A producer that has a key type builds the dataset of step 2 with `IS.dataset_descriptor(T, U, meta, axes)`.
