# Vendored conformance corpus

`element_type_vectors.json` is a verbatim copy of `conformance/element_type_vectors.json`
from the [infrastore](https://github.com/NatLabRockies/infrastore) repository, pinned at
commit `69dabce4e25f370bd10eabd672eaf48cece9542e` ("Make the logical element type a
first-class, store-owned concept").

It pins the byte layout and the neutral `element_type` names that every binding
(Rust core, Python, TypeScript, IS.jl) must agree on. `test/test_element_type_conformance.jl`
asserts IS's `_storage_array` / `_decode_static_values` against it.

The copy is vendored because IS depends on the *registered* InfraStore package, which does
not ship the corpus; without a local copy the parity check would never run — not here, and
not in CI.

## Refreshing

The corpus itself is generated, not hand-written. In an infrastore checkout:

```sh
UPDATE_CONFORMANCE_VECTORS=1 cargo test -p infrastore-core conformance
```

then copy the result over this file and update the commit above. Devs with an infrastore
checkout can point the tests at the live corpus instead — set
`INFRASTORE_CONFORMANCE_DIR=<infrastore>/conformance`, or just have InfraStore.jl `dev`ed
from that checkout, and the tests prefer it and warn when it has drifted from this copy.
