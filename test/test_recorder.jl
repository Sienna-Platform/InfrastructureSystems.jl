@testset "Test recorder" begin
    filename = "test.log"
    try
        # Post event while disabled.
        IS.@record :test TestEvent("a", 1, 2.0)
        @test !isfile(filename)

        IS.register_recorder!(:test)
        IS.@record :test TestEvent("a", 1, 2.0)
        IS.unregister_recorder!(:test)

        @test isfile(filename)
        lines = readlines(filename)
        @test length(lines) == 1
        data = JSON.parse(lines[1]; dicttype = Dict{String, Any})
        @test data["name"] == "TestEvent"
        @test data["val1"] == "a"
        @test data["val2"] == 1
        @test data["val3"] == 2.0

        rm(filename)
        IS.@record :test TestEvent("a", 1, 2.0)
        @test !isfile(filename)
    finally
        IS.unregister_recorder!(:test)
        isfile(filename) && rm(filename)
    end
end

@testset "Test list_recorder_events" begin
    filename = "test.log"
    try
        IS.register_recorder!(:test)
        for _ in 1:5
            IS.@record :test TestEvent("a", 1, 2.0)
            IS.@record :test TestEvent2(5)
        end
        IS.unregister_recorder!(:test)
        @test isfile(filename)

        events = IS.list_recorder_events(TestEvent, filename)
        @test length(events) == 5
        @test events[1] isa TestEvent

        IS.show_recorder_events(devnull, TestEvent, filename)
    finally
        IS.unregister_recorder!(:test)
        isfile(filename) && rm(filename)
    end
end

@testset "Test list_recorder_events filter" begin
    filename = "test.log"
    try
        IS.register_recorder!(:test)
        for i in 1:5
            IS.@record :test TestEvent("a", i, 2.0)
            IS.@record :test TestEvent2(3)
        end
        IS.unregister_recorder!(:test)
        @test isfile(filename)

        events = IS.list_recorder_events(
            TestEvent,
            filename,
            x -> x.val2 == 3,
        )
        @test length(events) == 1

        IS.show_recorder_events(
            devnull,
            TestEvent,
            filename,
            x -> x.val2 > 0,
        )
    finally
        IS.unregister_recorder!(:test)
        isfile(filename) && rm(filename)
    end
end

@testset "Test show_recorder_events exclude_columns" begin
    filename = "test.log"
    try
        IS.register_recorder!(:test)
        for i in 1:5
            IS.@record :test TestEvent("a", i, 2.0)
            IS.@record :test TestEvent2(3)
        end
        IS.unregister_recorder!(:test)
        @test isfile(filename)

        buf1 = IOBuffer()
        IS.show_recorder_events(buf1, TestEvent, filename)
        text = String(take!(buf1))
        @test occursin("timestamp", text)

        buf2 = IOBuffer()
        IS.show_recorder_events(
            buf2,
            TestEvent,
            filename;
            exclude_columns = Set("timestamp"),
        )
        text = String(take!(buf1))
        @test !occursin("timestamp", text)
    finally
        IS.unregister_recorder!(:test)
        isfile(filename) && rm(filename)
    end
end

@testset "Test recorder flushes each event" begin
    filename = "test.log"
    try
        IS.register_recorder!(:test)
        IS.@record :test TestEvent("a", 1, 2.0)
        @test filesize(filename) > 0
        IS.@record :test TestEvent2(5)
        @test length(readlines(filename)) == 2
    finally
        IS.unregister_recorder!(:test)
        isfile(filename) && rm(filename)
    end
end

@testset "Test recorder round trip with NaN, vectors, and symbols" begin
    filename = "test.log"
    try
        IS.register_recorder!(:test)
        IS.@record :test TestEvent3(:UC, NaN, ["gen1", "gen2"], [1.5, NaN])
        IS.@record :test TestEvent3(:ED, 2.0, String[], [-Inf])
        IS.unregister_recorder!(:test)

        lines = readlines(filename)
        data = JSON.parse(lines[1]; dicttype = Dict{String, Any})
        @test data["model_name"] == "UC"
        @test data["value"] === nothing
        @test data["values"] == [1.5, nothing]

        events = IS.list_recorder_events(TestEvent3, filename)
        @test length(events) == 2
        @test events[1].model_name == :UC
        @test isnan(events[1].value)
        @test events[1].names == ["gen1", "gen2"]
        @test events[1].values[1] == 1.5
        @test isnan(events[1].values[2])
        @test events[2].value == 2.0
        @test isempty(events[2].names)
        @test events[2].values == [-Inf]
        @test IS.get_timestamp(events[1]) <= IS.get_timestamp(events[2])
        @test IS.to_json(events[2]) == lines[2]
    finally
        IS.unregister_recorder!(:test)
        isfile(filename) && rm(filename)
    end
end
