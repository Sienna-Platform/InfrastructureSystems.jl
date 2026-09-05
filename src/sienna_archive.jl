# The Sienna archive: a directory of files, tar'd and gzip'd into one `.sn`.
#
# The container only — nothing here knows what the members are. A package decides that: a
# PowerSystems archive holds a system document plus its time-series sidecars, a portfolio
# archive holds whatever a portfolio needs. What is shared, and what lives here, is the
# extension the format is recognized by, the guards a write has to pass, and the compression
# itself.

"""Extension a Sienna archive is recognized by, on write and on read."""
const SIENNA_ARCHIVE_EXTENSION = ".sn"

"""
$(TYPEDSIGNATURES)

Whether `path` names a Sienna archive, by its extension.

The extension is the whole test: a reader picks the archive path over the directory path from
this, so a writer is held to it too (see [`create_sienna_archive`](@ref)).
"""
is_sienna_archive(path::AbstractString) =
    lowercase(splitext(path)[2]) == SIENNA_ARCHIVE_EXTENSION

"""
$(TYPEDSIGNATURES)

Archive a directory into the single gzip'd tar at `path`, calling `fill!` to populate it.

`fill!` receives a staging directory that does not yet exist and writes the archive's members
into it; everything in it afterwards becomes the archive. The staging directory is temporary
and its name never reaches the archive — `Tar.create` archives a directory's *contents*, so
the members sit at the archive root rather than under a prefix.

Refuses, before calling `fill!`, a `path` that is not `$SIENNA_ARCHIVE_EXTENSION` (the reader
recognizes the format by extension, so a differently named archive could not be read back), a
`path` that is a directory, and an existing file unless `force`.

```julia
create_sienna_archive(joinpath(dir, "case.sn"); force = true) do staging
    write_my_document(joinpath(staging, "portfolio.json"))
end
```
"""
function create_sienna_archive(fill!::Function, path::AbstractString; force::Bool = false)
    if !is_sienna_archive(path)
        throw(
            DataFormatError(
                "$path does not end in $SIENNA_ARCHIVE_EXTENSION; a Sienna archive requires " *
                "that extension so it can be recognized on read.",
            ),
        )
    end
    if isdir(path)
        throw(DataFormatError("$path is a directory; a Sienna archive is a single file"))
    end
    if isfile(path) && !force
        throw(
            DataFormatError(
                "$path already exists; pass force = true to overwrite the archive",
            ),
        )
    end
    mkpath(dirname(path))
    mktempdir() do dir
        staging = joinpath(dir, "archive")
        fill!(staging)
        open(CodecZlib.GzipCompressorStream, path, "w") do io
            Tar.create(staging, io)
        end
    end
    return nothing
end

"""
$(TYPEDSIGNATURES)

Extract the Sienna archive at `path` and return the directory holding its members.

The directory lives for the rest of the session rather than the rest of this call.
`mktempdir()`'s default `cleanup = true` registers it for deletion at exit, which is what a
caller that keeps reading from the extracted files needs — a store opened in place out of the
archive, say — while still not leaking into the OS temp root permanently.
"""
function extract_sienna_archive(path::AbstractString)
    if !isfile(path)
        throw(DataFormatError("$path does not exist"))
    end
    dir = mktempdir()
    open(CodecZlib.GzipDecompressorStream, path, "r") do io
        Tar.extract(io, dir)
    end
    return dir
end
