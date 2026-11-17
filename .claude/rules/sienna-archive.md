---
paths:
  - "src/sienna_archive.jl"
  - "src/infrastore.jl"
  - "src/serialization.jl"
---

## The Sienna archive and the store's two halves

`src/sienna_archive.jl` owns the Sienna archive container: a directory of files, zipped into one
file. The caller passes the extension (PowerSystems: `.sns`). The container lives here because
nothing about it is specific to a `System`; reimplementing the rules per package is how two
archives end up disagreeing.

```julia
is_sienna_archive(path, extension)                            # extension test a reader dispatches on
create_sienna_archive(fill!, path, extension; force = false)  # fill! populates a staging dir; that becomes the archive
extract_sienna_archive(path; directory = mktempdir())         # -> directory holding the members
```

Four things to know before touching it:

- **`fill!` decides the contents, this file decides nothing about them.** Keep it that way; a member
  list belongs to the package that writes it.
- **Zip, because compression is a per-member choice.** Members are deflated except for the
  extensions in `NO_COMPRESS_EXTENSIONS` (`.h5`, `.hdf5`), which are stored as they are: an archive
  is mostly its HDF5 sidecar, and deflating it walks every byte to save almost nothing. A gzip'd tar
  is one stream over the concatenated members and compresses all of them or none, which is why the
  format changed.
- **The extension is enforced on write** because it is the whole read-side test. An archive named
  otherwise could not be found again, so a path without the caller's `extension` is a
  `DataFormatError`, not a warning.
- **`extract_sienna_archive`'s directory outlives the call.** `mktempdir()`'s default
  `cleanup = true` registers it for atexit deletion, which a caller that keeps reading from the
  extracted files needs — a store opened in place out of the archive, say. Do not wrap it in a
  `do` block.

`ZipArchives` and `Mmap` are dependencies for this and nothing else (`extract_sienna_archive` maps
the archive rather than reading it into memory, since a stored HDF5 member makes an archive as large
as the data it holds).

### Arrays with and without the catalog

An InfraStore artifact is an HDF5 file plus a `.sqlite` catalog, and `serialize` writes both. A writer
whose own document already carries the catalog's association rows does not need the second half:

- `serialize_arrays(store, path)` writes the array half alone. Atomic, unlike `serialize`.
- `deserialize_arrays(path)` opens such an artifact and mints an empty catalog for a document's rows.
- `import_time_series_association_rows!(store_or_data, json)` replays them — the counterpart of
  `import_supplemental_attribute_association_rows!`.

`open_deserialized_infrastore_store` detects a source with no `.sqlite` beside it and mints rather than
copying one that is not there. Such a source is copied out and given a fresh catalog **`read_only` or
not**: there is no catalog to open in place, and minting one into the caller's directory is exactly the
mutation `read_only` exists to prevent.
