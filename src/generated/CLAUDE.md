# Generated code — never hand-edit

Every file here is generated from `src/descriptors/structs.json` by
`src/utils/generate_structs.jl`. Edits are silently destroyed on the next regeneration.

```sh
julia bin/generate_structs.jl src/descriptors/structs.json src/generated/
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

PowerSystems (and PSIP) fork their own copy of this generator/template rather than sharing this
one — see `PowerSystems.jl/src/generate_structs.jl` (module `PowerSystems.StructGeneration`).
A template edit here does **not** propagate automatically; if the change is one PSY should also
carry, port it to PSY's copy by hand in the same change set.

The `needs_conversion` codegen contract (two getter variants, a setter that takes no `units`
argument, and the `exclude_getter` / `_unitful` export gate) is documented in `.claude/CLAUDE.md`.
No descriptor inside IS uses `needs_conversion` — PowerSystems is the first consumer, and the
branch is covered only by the synthetic-descriptor test in `test/test_generate_structs.jl`.
