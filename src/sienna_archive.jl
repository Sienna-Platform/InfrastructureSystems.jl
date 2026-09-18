# The Sienna archive: a flat directory of files, zipped into one file.
#
# The container only — nothing here knows what the members are, nor what the file is called.
# A package decides both: PowerSystems writes `.sns` and holds a system document plus its
# time-series sidecars, PowerSystemsInvestmentsPortfolios writes `.snp`. What is shared, and
# what lives here, is the guards a write has to pass and the compression itself. The
# extension is the caller's, passed in, so a new one costs this file nothing.

"""HDF5 are already compressed; don't recompress for archive."""
const NO_COMPRESS_EXTENSIONS = (".h5", ".hdf5")

"""
$(TYPEDSIGNATURES)

Whether `path` names a Sienna archive spelled `extension` (`".sns"`, `".snp"`, ...).
"""
is_sienna_archive(path::AbstractString, extension::AbstractString) =
    lowercase(splitext(path)[2]) == lowercase(extension)

_should_compress_member(name::AbstractString) =
    lowercase(splitext(name)[2]) ∉ NO_COMPRESS_EXTENSIONS

"""
$(TYPEDSIGNATURES)

Archive a directory into the single zip archive at `path`, calling `fill!` to populate it.

`fill!` receives a temporary directory that does not exist yet and writes the
archive's members into the top-level so the archive is kept flat. Members are
compressed except for the extensions in [`NO_COMPRESS_EXTENSIONS`](@ref).

`extension` is the caller's own spelling — PowerSystems' `".sns"`, a portfolio's `".snp"` —
and is what `path` must end in. This file recognizes no extension of its own.

Refuses, before calling `fill!`, a `path` that does not end in `extension`, a `path` that is
a directory, and an existing file unless `force`.

```julia
create_sienna_archive(joinpath(dir, "case.snp"), ".snp"; force = true) do staging
    write_my_document(joinpath(staging, "portfolio.json"))
end
```
"""
function create_sienna_archive(
    fill!::Function,
    path::AbstractString,
    extension::AbstractString;
    force::Bool = false,
)
    if !is_sienna_archive(path, extension)
        throw(
            DataFormatError(
                "$path does not end in $extension; a Sienna archive requires that " *
                "extension so it can be recognized on read.",
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

Extract the Sienna archive at `path` into `directory` and return it.

`directory` defaults to a fresh temporary directory, which persists until the Julia session
ends. A caller passes its own when the extraction must not land in `/tmp` — an archive whose
HDF5 member is larger than `/tmp` (HPC), or one whose sidecar is opened in place and so has
to outlive this call.
"""
function extract_sienna_archive(
    path::AbstractString;
    directory::AbstractString = mktempdir(),
)
    if !isfile(path)
        throw(DataFormatError("$path does not exist"))
    end
    dir = mkpath(directory)
    bytes = open(Mmap.mmap, path)
    try
        archive = ZipArchives.ZipReader(bytes)
        for i in 1:ZipArchives.zip_nentries(archive)
            name = ZipArchives.zip_name(archive, i)
            ZipArchives.zip_openentry(archive, i) do member
                open(joinpath(dir, name), "w") do io
                    write(io, member)
                end
            end
        end
    finally
        # Ensures mmap is released on Windows
        # This is the recommended approach from JuliaLang/julia#54210
        # Julia 1.14 has munmap from JuliaLang/julia#60955
        finalize(bytes.ref.mem)
    end
    return dir
end
