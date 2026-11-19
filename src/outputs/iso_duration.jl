# One to nine digits per part keep every value inside `Int64` milliseconds.
const _ISO_DURATION_REGEX = r"^P(?:(\d{1,9})D)?(?:T(?:(\d{1,9})H)?(?:(\d{1,9})M)?)?\z"

function _capture_value(c::AbstractString)
    return parse(Int, c)
end

function _capture_value(::Nothing)
    return 0
end

function _iso_part(n::Integer, unit::Char)
    if iszero(n)
        return ""
    end
    return string(n, unit)
end

"""
Return `true` when `s` has the `P[nD][T[nH][nM]]` form of the outputs schema, with at most
nine digits per part.
"""
function is_iso_duration(s::AbstractString)
    m = match(_ISO_DURATION_REGEX, s)
    return !isnothing(m) && !all(isnothing, m.captures) && !endswith(s, "T")
end

"""
Parse an ISO-8601 duration of days, hours, and minutes (for example `"P2DT30M"`) into
`Dates.Millisecond`. Throw `ArgumentError` when `is_iso_duration(s)` is `false`. It accepts
the `P[nD][T[nH][nM]]` form of the schema, which `from_iso_8601` does not, and is not a
general ISO-8601 codec. The minute is the smallest unit: seconds are not accepted. Years,
months, and weeks are not accepted, because a year and a month have no fixed length.
"""
function parse_iso_duration(s::AbstractString)
    if !is_iso_duration(s)
        throw(
            ArgumentError(
                "not an outputs duration: \"$s\". The format accepts days, hours, and minutes (P[nD][T[nH][nM]]), with at most nine digits each. It does not accept seconds, years, months, or weeks.",
            ),
        )
    end
    m = match(_ISO_DURATION_REGEX, s)
    d, h, mi = _capture_value.(m.captures)
    return Dates.Millisecond(((d * 24 + h) * 60 + mi) * 60_000)
end

"""
Format a `Dates.Period` as an ISO-8601 duration, largest unit first, omitting zero parts.
Throw `ArgumentError` when the period is negative or is not a whole number of minutes.
"""
function iso_duration(p::Dates.Period)
    ms = Dates.value(Dates.Millisecond(p))
    if ms < 0
        throw(ArgumentError("duration is negative: $p"))
    end
    if !iszero(mod(ms, 60_000))
        throw(ArgumentError("duration is not a whole number of minutes: $p"))
    end
    days, rem_min = divrem(div(ms, 60_000), 1440)
    hours, minutes = divrem(rem_min, 60)
    time_part = string(_iso_part(hours, 'H'), _iso_part(minutes, 'M'))
    if isempty(time_part)
        if iszero(days)
            return "PT0M"
        end
        return string("P", _iso_part(days, 'D'))
    end
    return string("P", _iso_part(days, 'D'), "T", time_part)
end
