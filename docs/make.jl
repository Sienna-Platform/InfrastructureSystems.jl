using Documenter, InfrastructureSystems
import DataStructures: OrderedDict
using Literate
using DocumenterInterLinks

links = InterLinks(
    "Documenter" => "https://documenter.juliadocs.org/stable/",
    "Julia" => "https://docs.julialang.org/en/v1/",
    "JuliaFormatter" => "https://domluna.github.io/JuliaFormatter.jl/stable/",
    "PowerSystems" => "https://sienna-platform.github.io/PowerSystems.jl/stable/",
    "PowerSystemCaseBuilder" => "https://sienna-platform.github.io/PowerSystemCaseBuilder.jl/stable/",
    "DocumenterInterLinks" => "http://juliadocs.org/DocumenterInterLinks.jl/stable/",
)

if haskey(ENV, "GITHUB_ACTIONS")
    ENV["JULIA_DEBUG"] = "Documenter"
end

pages = OrderedDict(
        "Welcome Page" => "index.md",
        "Developer Guide" => Any[
            "dev_guide/components_and_container.md",
            "dev_guide/auto_generation.md",
            "dev_guide/time_series.md",
            "dev_guide/associations_database.md",
            "dev_guide/recorder.md",
            "dev_guide/tests.md",
            "dev_guide/retest_migration.md",
            "dev_guide/logging.md",
            "dev_guide/test_data_artifacts.md",
        ],
        "Style Guide" => "style.md",
        "Documentation Best Practices" => Any[
            "Explanation" => "docs_best_practices/explanation.md",
            "How to..." => Any[
                "Complete Basic Requirements Checklist" => "docs_best_practices/how-to/requirements_checklist.md",
                "Clean Up General Formatting" => "docs_best_practices/how-to/general_formatting.md",
                "Write a Tutorial" => "docs_best_practices/how-to/write_a_tutorial.md",
                "Write a How-To Guide" => "docs_best_practices/how-to/write_a_how-to.md",
                "Organize APIs and Write Docstrings" => "docs_best_practices/how-to/write_docstrings_org_api.md",
                "Troubleshoot Common Errors" => "docs_best_practices/how-to/troubleshoot.md",
                "Compile and View Documentation Locally" => "docs_best_practices/how-to/compile.md",
                "View Draft Documentation on Github" => "docs_best_practices/how-to/view_github.md",],
            "Reference" => Any["docs_best_practices/reference/useful_links.md",],
        ],
        "API" => "InfrastructureSystems.md"
)

# This code performs the automated addition of Literate - Generated Markdowns. The desired
# section name should be the name of the file for instance network_matrices.jl -> Network Matrices
# This code is generic to all Sienna documentation
julia_file_filter = x -> occursin(".jl", x)
folders = Dict(
    "Developer Guide" => filter(julia_file_filter, readdir("docs/src/dev_guide")),
)

for (section, folder) in folders
    for file in folder
        section_folder_name = lowercase(replace(section, " " => "_"))
        outputdir = joinpath(pwd(), "docs", "src", "$section_folder_name")
        inputfile = joinpath("$section_folder_name", "$file")
        outputfile = string("generated_", replace("$file", ".jl" => ""))
        Literate.markdown(joinpath(pwd(), "docs", "src", inputfile),
                          outputdir;
                          name = outputfile,
                          credit = false,
                          execute=true)
        subsection = titlecase(replace(split(file, ".")[1], "_" => " "))
        push!(pages[section], ("$subsection" =>  joinpath("$section_folder_name", "$(outputfile).md")))
    end
end

makedocs(
    modules = [InfrastructureSystems],
    format = Documenter.HTML(
        prettyurls = haskey(ENV, "GITHUB_ACTIONS"),
        size_threshold = nothing),
    sitename = "InfrastructureSystems.jl",
    pages = Any[p for p in pages],
    plugins = [links],
)


deploydocs(
    repo = "github.com/Sienna-Platform/InfrastructureSystems.jl.git",
    target = "build",
    branch = "gh-pages",
    devbranch = "main",
    devurl = "dev",
    versions = ["stable" => "v^", "v#.#"],
    push_preview = true,
)
