# The Sienna archive: a flat directory of files, zipped into one `.sn`.
#
# The container only — nothing here knows what the members are. A package decides that: a
# PowerSystems archive holds a system document plus its time-series sidecars, a portfolio
# archive holds whatever a portfolio needs. What is shared, and what lives here, is the
# extension the format is recognized by, the guards a write has to pass, and the compression
# itself.

"""Extension a Sienna archive is recognized by, on write and on read."""
const SIENNA_ARCHIVE_EXTENSION = ".sn"

"""HDF5 are already compressed; don't recompress for archive."""
const NO_COMPRESS_EXTENSIONS = (".h5", ".hdf5")

"""
$(TYPEDSIGNATURES)

Whether `path` names a Sienna archive, by its extension.
"""
is_sienna_archive(path::AbstractString) =
    lowercase(splitext(path)[2]) == SIENNA_ARCHIVE_EXTENSION

_should_compress_member(name::AbstractString) =
    lowercase(splitext(name)[2]) ∉ NO_COMPRESS_EXTENSIONS

"""
$(TYPEDSIGNATURES)

Archive a directory into the single zip archive at `path`, calling `fill!` to populate it.

`fill!` receives a temporary directory that does not exist yet and writes the
archive's members into the top-level so the archive is kept flat. Members are
compressed except for the extensions in [`NO_COMPRESS_EXTENSIONS`](@ref).

Refuses, before calling `fill!`, a `path` that is not `$SIENNA_ARCHIVE_EXTENSION`, a
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
        ZipArchives.ZipWriter(path) do archive
            for name in readdir(staging)
                ZipArchives.zip_newfile(
                    archive,
                    name;
                    compress = _should_compress_member(name),
                )
                open(joinpath(staging, name), "r") do io
                    write(archive, io)
                end
            end
        end
    end
    return nothing
end

"""
$(TYPEDSIGNATURES)

Extract the Sienna archive at `path` into `directory` and return it. The
caller owns `directory` and its lifetime.
"""
function extract_sienna_archive(path::AbstractString; directory::AbstractString)
    if !isfile(path)
        throw(DataFormatError("$path does not exist"))
    end
    open(path, "r") do io
        archive = ZipArchives.ZipReader(Mmap.mmap(io))
        for i in 1:ZipArchives.zip_nentries(archive)
            name = ZipArchives.zip_name(archive, i)
            _check_archive_member_name(name)
            ZipArchives.zip_openentry(archive, i) do member
                open(joinpath(directory, name), "w") do io
                    write(io, member)
                end
            end
        end
    end
    return directory
end

function _check_archive_member_name(name::AbstractString)
    if isempty(name) || name in (".", "..") || name != basename(name)
        throw(
            DataFormatError(
                "archive member name $(repr(name)) is not a flat filename; " *
                "Sienna archives contain only top-level members",
            ),
        )
    end
    return nothing
end
