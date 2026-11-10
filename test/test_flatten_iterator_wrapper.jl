
function run_test(T, a, b)
    c = [values(a), values(b)]
    len = length(a) + length(b)
    iter = IS.FlattenIteratorWrapper(T, c)
    @test length(iter) == len
    @test eltype(iter) == T

    i = 0
    for x in iter
        i += 1
    end
    @test i == len
end

@testset "Test IS.FlattenIteratorWrapper dictionaries" begin
    run_test(Int, Dict("1" => 1, "2" => 2, "3" => 3), Dict("4" => 4, "5" => 5, "6" => 6))
    run_test(Int, Dict{String, Int}(), Dict{String, Int}())
end

@testset "Test IS.FlattenIteratorWrapper vectors" begin
    run_test(Int, [1, 2, 3], [4, 5, 6])
    run_test(Int, [], [])
end

@testset "Test IS.FlattenIteratorWrapper filter" begin
    iter = IS.FlattenIteratorWrapper(Int, [[1, 2, 3], [4, 5, 6]])
    evens = filter(iseven, iter)
    @test typeof(evens) == Vector{Int}
    @test evens == [2, 4, 6]
    @test filter(x -> x > 2, evens) == [4, 6]
    empty_result = filter(x -> x > 10, iter)
    @test typeof(empty_result) == Vector{Int}
    @test isempty(empty_result)
end
