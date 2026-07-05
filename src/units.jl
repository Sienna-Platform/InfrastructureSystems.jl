time_period_conversion(time_period::Union{Dates.TimePeriod, Dates.DatePeriod}) =
    convert(Dates.Millisecond, time_period)
time_period_conversion(time_periods::Dict{String, <:Dates.Period}) =
    convert(Dict{String, Dates.Millisecond}, time_periods)

"""
    default_units(owner)

The default unit system for `owner`, used by unit-aware accessors when the caller does not
pass a `units` argument. Domain packages override this per owner type (e.g. PowerSystems
returns `SU` for `Component`s). The IS fallback returns `nothing`.
"""
default_units(::Any) = nothing
