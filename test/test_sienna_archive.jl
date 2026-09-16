# The container takes its extension from the caller, so these tests name one the way a
# consumer does. `.sns` is PowerSystems'; `.snp` stands in for any other package's.
const TEST_ARCHIVE_EXTENSION = ".sns"

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
        path = joinpath(dir, "case.sns")
        IS.create_sienna_archive(_fill_test_archive, path, TEST_ARCHIVE_EXTENSION)
        @test isfile(path)

        extracted = IS.extract_sienna_archive(path)
        staging = joinpath(dir, "expected")
        _fill_test_archive(staging)
        for member in ("document.json", "arrays.h5", "extras.json")
            @test read(joinpath(extracted, member)) == read(joinpath(staging, member))
        end
        # The staging directory's own name must not become a prefix inside the archive.
        @test sort(readdir(extracted)) == ["arrays.h5", "document.json", "extras.json"]

        # An explicit destination is used as given, rather than a fresh temp dir.
        into = mkpath(joinpath(dir, "into"))
        @test IS.extract_sienna_archive(path; directory = into) == into
        @test sort(readdir(into)) == ["arrays.h5", "document.json", "extras.json"]

        # Make sure Windows isn't locking any files
        rm(path)
        @test !isfile(path)
    end
end

@testset "Test Sienna archive compresses everything but HDF5" begin
    mktempdir() do dir
        path = joinpath(dir, "case.sns")
        IS.create_sienna_archive(_fill_test_archive, path, TEST_ARCHIVE_EXTENSION)

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

@testset "Test Sienna archive write guards" begin
    mktempdir() do dir
        filled = Ref(false)
        filler = staging -> (filled[] = true; mkpath(staging))

        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "case.zip"),
            TEST_ARCHIVE_EXTENSION,
        )
        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "case"),
            TEST_ARCHIVE_EXTENSION,
        )
        # Another package's Sienna extension is not this caller's: the guard compares against
        # what was asked for, so the two archive kinds cannot be written through each other.
        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "case.snp"),
            TEST_ARCHIVE_EXTENSION,
        )
        @test !filled[]

        mkpath(joinpath(dir, "directory.sns"))
        @test_throws IS.DataFormatError IS.create_sienna_archive(
            filler,
            joinpath(dir, "directory.sns"),
            TEST_ARCHIVE_EXTENSION,
        )
        @test !filled[]

        path = joinpath(dir, "case.sns")
        IS.create_sienna_archive(_fill_test_archive, path, TEST_ARCHIVE_EXTENSION)
        @test_throws IS.DataFormatError IS.create_sienna_archive(
            _fill_test_archive, path, TEST_ARCHIVE_EXTENSION,
        )

        IS.create_sienna_archive(path, TEST_ARCHIVE_EXTENSION; force = true) do staging
            mkpath(staging)
            write(joinpath(staging, "only.json"), "{}")
        end
        @test readdir(IS.extract_sienna_archive(path)) == ["only.json"]
    end
end
