# Generated code — never hand-edit

Every file here is generated from `src/descriptors/structs.json` by
`src/utils/generate_structs.jl`. Edits are silently destroyed on the next regeneration.

```sh
julia bin/generate_structs.jl src/descriptors/structs.json src/generated/
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

Template changes ripple downstream: PowerSystems regenerates its ~210 component types from this
same template, so a template edit requires regenerating PSY structs **in the same change set**.

The `needs_conversion` codegen contract (two getter variants, a setter that takes no `units`
argument, and the `exclude_getter` / `_unitful` export gate) is documented in `.claude/CLAUDE.md`.
No descriptor inside IS uses `needs_conversion` — PowerSystems is the first consumer, and the
branch is covered only by the synthetic-descriptor test in `test/test_generate_structs.jl`.
