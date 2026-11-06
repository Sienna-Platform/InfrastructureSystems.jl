# One to nine digits per part keep every value inside `Int64` milliseconds.
const _ISO_DURATION_REGEX =
    r"^P(?:(\d{1,9})D)?(?:T(?:(\d{1,9})H)?(?:(\d{1,9})M)?(?:(\d{1,9})S)?)?$"

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
Return `true` when `s` has the `P[nD][T[nH][nM][nS]]` form of the outputs schema, with at
most nine digits per part.
"""
function is_iso_duration(s::AbstractString)
    m = match(_ISO_DURATION_REGEX, s)
    return !isnothing(m) && !all(isnothing, m.captures) && !endswith(s, "T")
end

"""
Parse an ISO-8601 duration of days, hours, minutes and seconds (for example `"P2DT30M"`)
into `Dates.Millisecond`. Throw `ArgumentError` when `is_iso_duration(s)` is `false`. It
accepts the `P[nD][T[nH][nM][nS]]` form of the schema, which `from_iso_8601` does not, and
is not a general ISO-8601 codec.
"""
function parse_iso_duration(s::AbstractString)
    if !is_iso_duration(s)
        throw(ArgumentError("not an ISO-8601 duration: $s"))
    end
    m = match(_ISO_DURATION_REGEX, s)
    d, h, mi, sec = _capture_value.(m.captures)
    return Dates.Millisecond(((d * 24 + h) * 60 + mi) * 60_000 + sec * 1000)
end

"""
Format a `Dates.Period` as an ISO-8601 duration, largest unit first, omitting zero parts.
Throw `ArgumentError` when the period is negative or has a sub-second remainder.
"""
function iso_duration(p::Dates.Period)
    ms = Dates.value(Dates.Millisecond(p))
    if ms < 0
        throw(ArgumentError("duration is negative: $p"))
    end
    if !iszero(mod(ms, 1000))
        throw(ArgumentError("duration has a sub-second remainder: $p"))
    end
    days, rem_s = divrem(div(ms, 1000), 86_400)
    hours, rem_s = divrem(rem_s, 3600)
    minutes, seconds = divrem(rem_s, 60)
    time_part = string(
        _iso_part(hours, 'H'),
        _iso_part(minutes, 'M'),
        _iso_part(seconds, 'S'),
    )
    if isempty(time_part)
        if iszero(days)
            return "PT0S"
        end
        return string("P", _iso_part(days, 'D'))
    end
    return string("P", _iso_part(days, 'D'), "T", time_part)
end
