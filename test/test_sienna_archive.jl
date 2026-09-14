"""Members exercising both compression paths, written into `staging`."""
function _fill_test_archive(staging::AbstractString)
    mkpath(staging)
    write(joinpath(staging, "document.json"), repeat("{\"a\": 1}", 500))
    write(joinpath(staging, "arrays.h5"), UInt8[(37 * i) % 256 for i in 1:4096])
    write(joinpath(staging, "extras.json"), "{}")
    return nothing
end

@testset "Test Sienna archive round trip" begin
    mktempdir() do dir
        path = joinpath(dir, "case.sn")
        IS.create_sienna_archive(_fill_test_archive, path)
        @test isfile(path)

        extracted = IS.extract_sienna_archive(path; directory = mktempdir(dir))
        staging = joinpath(dir, "expected")
        _fill_test_archive(staging)
        for member in ("document.json", "arrays.h5", "extras.json")
            @test read(joinpath(extracted, member)) == read(joinpath(staging, member))
        end
        # The staging directory's own name must not become a prefix inside the archive.
        @test sort(readdir(extracted)) == ["arrays.h5", "document.json", "extras.json"]
    end
end

@testset "Test Sienna archive compresses everything but HDF5" begin
    mktempdir() do dir
        path = joinpath(dir, "case.sn")
        IS.create_sienna_archive(_fill_test_archive, path)

        archive = IS.ZipArchives.ZipReader(read(path))
        compressed = Dict(
            IS.ZipArchives.zip_name(archive, i) =>
                IS.ZipArchives.zip_iscompressed(archive, i) for
            i in 1:IS.ZipArchives.zip_nentries(archive)
        )
        @test compressed["document.json"]
        @test compressed["extras.json"]
        @test !compressed["arrays.h5"]
    end
end

@testset "Test Sienna archive rejects unsafe member names" begin
    # Unit-test the guard directly — ZipArchives refuses to write some of these,
    # but a hostile archive built with any other tool could still carry them.
    for bad_name in
        ("../escape.json", "sub/nested.json", "/absolute.json", ".", "..", "")
        @test_throws IS.DataFormatError IS._check_archive_member_name(bad_name)
    end
    @test IS._check_archive_member_name("system.json") === nothing

    # End-to-end: an archive we can actually construct with a nested-path member
    # is refused on extraction.
    mktempdir() do dir
        path = joinpath(dir, "malicious.sn")
        IS.ZipArchives.ZipWriter(path) do archive
            IS.ZipArchives.zip_newfile(archive, "sub/nested.json")
            write(archive, "payload")
        end
        @test_throws IS.DataFormatError IS.extract_sienna_archive(
            path;
            directory = mktempdir(dir),
        )
    end
end

@testset "Test Sienna archive write guards" begin
    mktempdir() do dir
        filled = Ref(false)
        filler = staging -> (filled[] = true; mkpath(staging))

        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "case.zip"),
        )
        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "case"),
        )
        @test !filled[]

        mkpath(joinpath(dir, "directory.sn"))
        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "directory.sn"),
        )
        @test !filled[]

        path = joinpath(dir, "case.sn")
        IS.create_sienna_archive(_fill_test_archive, path)
        @test_throws IS.DataFormatError IS.create_sienna_archive(_fill_test_archive, path)

        IS.create_sienna_archive(path; force = true) do staging
            mkpath(staging)
            write(joinpath(staging, "only.json"), "{}")
        end
        @test readdir(IS.extract_sienna_archive(path; directory = mktempdir(dir))) ==
              ["only.json"]
    end
end
