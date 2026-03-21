# Sienna Programming Practices

This document describes general programming practices and conventions that apply across all Sienna packages (PowerSystems.jl, PowerSimulations.jl, PowerFlows.jl, PowerNetworkMatrices.jl, InfrastructureSystems.jl, etc.).

## Performance Requirements

**Priority:** Critical. See the [Julia Performance Tips](https://docs.julialang.org/en/v1/manual/performance-tips/).

### Anti-Patterns to Avoid

#### Type instability

Functions must return consistent concrete types. Check with `@code_warntype`.

- Bad: `f(x) = x > 0 ? 1 : 1.0`
- Good: `f(x) = x > 0 ? 1.0 : 1.0`

#### Abstract field types

Struct fields must have concrete types or be parameterized.

- Bad: `struct Foo; data::AbstractVector; end`
- Good: `struct Foo{T<:AbstractVector}; data::T; end`

#### Untyped containers

- Bad: `Vector{Any}()`, `Vector{Real}()`
- Good: `Vector{Float64}()`, `Vector{Int}()`

#### Non-const globals

- Bad: `THRESHOLD = 0.5`
- Good: `const THRESHOLD = 0.5`

#### Unnecessary allocations

- Use views instead of copies (`@view`, `@views`)
- Pre-allocate arrays instead of `push!` in loops
- Use in-place operations (functions ending with `!`)

#### Captured variables

Avoid closures that capture variables causing boxing. Pass variables as function arguments instead.

#### Splatting penalty

Avoid splatting (`...`) in performance-critical code.

#### Abstract return types

Avoid returning `Union` types or abstract types.

#### Runtime type checking (`isa` and `<:`)

**ABSOLUTELY FORBIDDEN unless the user explicitly asks for it.** Never write code that uses `isa` checks or `<:` (subtype) checks for type-based branching in function bodies. Both are wrong — use multiple dispatch instead.

Using `<:` inside a function body to branch on types is just `isa` with extra steps. Do not use it as a workaround.

- Bad: `if x isa Float64 ... elseif x isa Int ... end`
- Bad: `if typeof(x) <: AbstractVector ... end`
- Bad: `if T <: SomeAbstractType ... else ... end` (where `T` is a type parameter used for branching)
- Good: Use multiple dispatch with specific type signatures
- Bad: `function f(x); if x isa AbstractVector return sum(x) else return x end; end`
- Good: `f(x::AbstractVector) = sum(x); f(x::Number) = x`

**Why this matters:** `isa` and `<:` checks force the compiler to handle multiple code paths at runtime, losing type information and preventing specialization. This causes runtime compilation and defeats Julia's core performance model. Multiple dispatch allows the compiler to generate optimized, specialized code for each type at compile time. Any form of runtime type checking in function bodies — whether via `isa`, `typeof(x) <: T`, or passing type parameters to branch on — is an anti-pattern.

### Best Practices

- Use `@inbounds` when bounds are verified
- Use broadcasting (dot syntax) for element-wise operations
- Avoid `try-catch` in hot paths
- Use function barriers to isolate type instability

> Apply these guidelines with judgment. Not every function is performance-critical. Focus optimization efforts on hot paths and frequently called code.

## Code Conventions

Style guide: <https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/style/>

Formatter (JuliaFormatter): Use the formatter script provided in each package.

Key rules:

- Constructors: use `function Foo()` not `Foo() = ...`
- Asserts: prefer `InfrastructureSystems.@assert_op` over `@assert`
- Globals: `UPPER_CASE` for constants
- Exports: all exports in main module file
- Comments: complete sentences, describe why not how

## Documentation Practices and Requirements

Framework: [Diataxis](https://diataxis.fr/)

Sienna guide: <https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/docs_best_practices/explanation/>

Sienna guide for Diataxis-style tutorials: <https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/docs_best_practices/how-to/write_a_tutorial/>
Format for tutorial scripts: <https://fredrikekre.github.io/Literate.jl/v2/>
Sienna guide for Diataxis-style how-to's: <https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/docs_best_practices/how-to/write_a_how-to/>
Sienna guide for APIs: <https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/docs_best_practices/how-to/write_docstrings_org_api/>

Docstring requirements:

- Scope: all elements of public interface (IS is selective about exports)
- Include: function signatures and arguments list
- Automation: `DocStringExtensions.TYPEDSIGNATURES` (`TYPEDFIELDS` used sparingly in IS)
- See also: add links for functions with same name (multiple dispatch)

API docs:

- Public: typically in `docs/src/api/public.md` using `@autodocs` with `Public=true, Private=false`
- Internals: typically in `docs/src/api/internals.md`

## Design Principles

- Elegance and concision in both interface and implementation
- Fail fast with actionable error messages rather than hiding problems
- Validate invariants explicitly in subtle cases
- Avoid over-adherence to backwards compatibility for internal helpers

## Contribution Workflow

**Note:** The default branch for all Sienna packages is `main`, not `master`.

Branch naming: `feature/description` or `fix/description`

1. Create feature branch
2. Follow style guide and run formatter
3. Ensure tests pass
4. Submit pull request

## Testing Guidelines

**Test custom logic, not language guarantees.** Do not write tests that only verify Julia's
built-in behavior. Focus tests on code you wrote, not on things the compiler already ensures.

Avoid:
- `@test obj isa SomeType` when the type hierarchy makes it a tautology (e.g., testing that
  a `FooBar <: Bar` instance `isa Bar`).
- Testing that a struct constructed with a value stores that value, when the struct is a plain
  data holder with no validation or transformation.
- Testing `==` / `isequal` / `hash` when those methods are inherited from a parent type and
  the subtype adds no custom logic.
- Duplicating the same test with trivially different inputs that exercise no additional code
  path (e.g., constructing with two different subtypes of the same abstract field type when
  the struct does not distinguish between them).

Instead test:
- Custom dispatch logic and predicates you defined.
- Type-mapping tables and accessor functions that could have typos or wrong entries.
- Serialization round-trips (integration with the serialization infrastructure).
- Custom `show` / display output that formats domain-specific information.
- Validation logic, error paths, and edge cases.

## AI Agent Guidance

**Key priorities:** Read existing patterns first, maintain consistency, use concrete types in hot paths, run formatter, add docstrings to public API, ensure tests pass.

**Critical rules:**
- Always use `julia --project=<env>` (never bare `julia`)
- **NEVER use `isa` or `<:` for runtime type checking in function logic** — use multiple dispatch instead. This includes `typeof(x) <: T` and branching on type parameters. Absolutely forbidden unless the user explicitly asks for it.
- Never edit auto-generated files directly
- Verify type stability with `@code_warntype` for performance-critical code
- Consider downstream package impact

## Julia Environment Best Practices

**CRITICAL:** Always use `julia --project=<env>` when running Julia code in Sienna repositories. **NEVER** use bare `julia` or `julia --project` without specifying the environment. Each package typically defines dependencies in `test/Project.toml` for testing.

Common patterns:

```sh
# Run tests (using test environment)
julia --project=test test/runtests.jl

# Run specific test
julia --project=test test/runtests.jl test_file_name

# Run expression
julia --project=test -e 'using PackageName; ...'

# Instantiate environment
julia --project=test -e 'using Pkg; Pkg.instantiate()'

# Build docs (using docs environment)
julia --project=docs docs/make.jl
```

**Why this matters:** Running without `--project=<env>` will fail because required packages won't be available in the default environment. The test/docs environments contain all necessary dependencies for their respective tasks.

## Troubleshooting

**Type instability**
- Symptom: Poor performance, many allocations
- Diagnosis: `@code_warntype` on suspect function
- Solution: See performance anti-patterns above

**Formatter fails**
- Symptom: Formatter command returns error
- Solution: Run the formatter script provided in the package (e.g., `julia -e 'include("scripts/formatter/formatter_code.jl")'`)

**Test failures**
- Symptom: Tests fail unexpectedly
- Solution: `julia --project=test -e 'using Pkg; Pkg.instantiate()'`
