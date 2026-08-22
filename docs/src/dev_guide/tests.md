# Running Tests

## Standard test execution

Unit tests can be executed in the REPL by executing the following:

```julia
julia> ] test

```

## Interactive test execution

While developing code and tests it can be convenient to run a subset of tests.
You can do this with a combination of TestEnv.jl and ReTest.jl.

**Note**: Per recommendations from the developers of TestEnv.jl, install the package
in your global julia environment. Do the same for Revise.jl.

```console
$ julia
julia> ]
(@v1.10) pkg> add TestEnv Revise
```

Start the environment with the InfrastructureSystems.jl environment.

```console
$ julia --project
```

Load the test environment.

```
julia> using TestEnv
julia> TestEnv.activate()
```

Load the tests through ReTest.jl and Revise.jl.

```julia
julia> include("test/load_tests.jl")

```

Run all tests.

```julia
julia> run_tests()

```

Run a subset of tests with a regular expression. This pattern matches multiple testset definitions.
The `run_tests` function forwards all arguments and keyword arguments to `ReTest.retest`.

```
julia> run_tests(r"Test.*components")
```

Refer to the [ReTest documentation](https://juliatesting.github.io/ReTest.jl/stable/) for more
information.

## Change logging levels

```julia
julia> InfrastructureSystems.make_logging_config_file("logging_config.toml")
julia> ENV["SIENNA_LOGGING_CONFIG"] = "logging_config.toml"
```

Edit the file to suit your preferences and rerun.

```julia
julia> run_tests()

```

**Note** that you can filter out noisy log groups in this file.

## Noisy log messages

The unit test module appends a summary of all log message counts to the log
file.  If a message is logged too frequently then consider tagging that message
with maxlog=X to suppress it.
