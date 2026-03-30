isdefined(Base, :__precompile__) && __precompile__()

module InfrastructureSystems

# Cost aliases don't display properly unless they are exported from IS
export LinearCurve, QuadraticCurve
export PiecewisePointCurve, PiecewiseIncrementalCurve, PiecewiseAverageCurve

# Unit types for explicit units in getters/setters
export MW, Mvar, MVA, kV, OHMS, SIEMENS
export DU, SU, DeviceBaseUnit, SystemBaseUnit
export AbstractRelativeUnit, RelativeQuantity
export ustrip

import Base: @kwdef
import CSV
import DataFrames
import DataFrames: DataFrame
import Dates
import JSON3
import Logging
import Random
import Pkg
import PrettyTables
import Printf: @sprintf
import SHA
import StringTemplates
import StructTypes
import TerminalLoggers: TerminalLogger, ProgressLevel
import TimeSeries
import TimerOutputs
import TOML
using DataStructures: OrderedDict, SortedDict
import SQLite
import Tables
using LinearAlgebra: norm, dot

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

# IS should not export any function since it can have name clashes with other packages.
# Do not add export statements.

"""
Base type for any struct in the Sienna packages.
All structs must implement a kwarg-only constructor to allow deserializing from a Dict.
"""
abstract type InfrastructureSystemsType end

"""
Base type for structs that are stored in a system.

Required interface functions for subtypes:

  Note: InfrastructureSystems provides default implementations for these methods that
  depend on the struct field names `name` and `internal`.
  If subtypes have different field names, they must implement these methods.
  - get_name()
  - set_name_internal!()
  - get_internal()

Warning: Subtypes should not implement the function
  set_name!(::InfrastructureSystemsComponent, name).
  InfrastructureSystems uses the component name in internal data structures, so it is not
  safe to change the name of a component after it has been added to a system.
  InfrastructureSystems provides set_name!(data::SystemData, component, name) for this
  purpose.

Optional interface functions:

  The default function returns true because some get_components functions need to return
  all "available" and all components that don't explicitly have that attribute should be
  returned.
  - get_available()
  The default function is a no-op.
  - set_available!()

Subtypes may contain time series and be associated with supplemental attributes.
Those behaviors can be modified with these methods:
  - supports_supplemental_attributes()
  - supports_time_series()
"""
abstract type InfrastructureSystemsComponent <: InfrastructureSystemsType end

"""
Base type for auxillary structs. These should not be stored in a system.
"""
abstract type DeviceParameter <: InfrastructureSystemsType end

"""
Base type for structs that store supplemental attributes

Required interface functions for subtypes:

  - get_internal()

Optional interface functions:

  - get_uuid()

Subtypes may contain time series. Which requires

  - `supports_time_series(::SupplementalAttribute)`

All subtypes must include an instance of ComponentUUIDs in order to track
components attached to each attribute.
"""
abstract type SupplementalAttribute <: InfrastructureSystemsType end

"Return true if the component is available."
get_available(value::InfrastructureSystemsComponent) = true

"Set the availability of the component."
set_available!(value::InfrastructureSystemsComponent) = true

"Return the name of the component."
get_name(value::InfrastructureSystemsComponent) = value.name

"Return true if the component supports supplemental attributes."
supports_supplemental_attributes(::InfrastructureSystemsComponent) = true

"Return true if the component supports time series."
supports_time_series(::InfrastructureSystemsComponent) = false

"Return true if the supplemental attribute supports time series."
supports_time_series(::SupplementalAttribute) = false

"Set the name of the component. Must only be called by InfrastructureSystems."
function set_name_internal!(value::InfrastructureSystemsComponent, name)
    value.name = name
    return
end

get_internal(value::InfrastructureSystemsComponent) = value.internal

include("common.jl")
include("random_seed.jl")
include("utils/timers.jl")
include("utils/assert_op.jl")
include("utils/recorder_events.jl")
include("utils/flatten_iterator_wrapper.jl")
include("utils/generate_struct_files.jl")
include("utils/generate_structs.jl")
include("utils/lazy_dict_from_iterator.jl")
include("utils/logging.jl")
include("utils/stdout_redirector.jl")
include("utils/sqlite.jl")
include("function_data/function_data.jl")
include("utils/utils.jl")
include("definitions.jl")
include("internal.jl")
include("time_series_storage.jl")
include("abstract_time_series.jl")
include("forecasts.jl")
include("static_time_series.jl")
include("time_series_parameters.jl")
include("containers.jl")
include("component_container.jl")
include("component_uuids.jl")
include("geographic_supplemental_attribute.jl")
include("generated/includes.jl")
include("time_series_parser.jl")
include("single_time_series.jl")
include("deterministic_single_time_series.jl")
include("deterministic.jl")
include("probabilistic.jl")
include("scenarios.jl")
include("deterministic_metadata.jl")
include("hdf5_time_series_storage.jl")
include("in_memory_time_series_storage.jl")
include("time_series_structs.jl")
include("time_series_formats.jl")
include("time_series_metadata_store.jl")
include("time_series_manager.jl")
include("time_series_interface.jl")
include("time_series_cache.jl")
include("time_series_utils.jl")
include("supplemental_attribute_associations.jl")
include("supplemental_attribute_manager.jl")
include("components.jl")
include("iterators.jl")
include("component.jl")
include("serialization.jl")
include("system_data.jl")
include("subsystems.jl")
include("validation.jl")
include("component_selector.jl")
include("results.jl")
include("utils/print.jl")
@static if pkgversion(PrettyTables).major == 2
    # When PrettyTables v2 is more widely adopted in the ecosystem, we can remove this file.
    # In this case, we should also update the compat bounds in Project.toml to list only
    # PrettyTables v3.
    include("utils/print_pt_v2.jl")
else
    include("utils/print_pt_v3.jl")
end
include("utils/test.jl")
include("units.jl")
include("value_curve.jl")
include("cost_aliases.jl")
include("function_data/convexity_checks.jl")
include("production_variable_cost_curve.jl")
include("function_data/make_convex.jl")
include("deprecated.jl")
include("Optimization/Optimization.jl")
include("Simulation/Simulation.jl")

# Register custom Unitful units (Mvar, MVA) so conversions work properly
# TODO: cleaner way? seems like overkill to register the whole module.
function __init__()
    Unitful.register(@__MODULE__)
end

end # module
