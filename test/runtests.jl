using SequentialOutputChannels
using Test
using Aqua
using Random: randperm
using Base.Threads: @spawn

# Aqua.test_all(SequentialOutputChannels)

@testset "Basic Functionality" begin
    @testset "Lock" begin
        c = SequentialOutputChannel{Int}(5)
        @test trylock(c)
        unlock(c)
    end
    # Test ordered output
    @testset "Ordered Output" begin
        n = 15
        c = SequentialOutputChannel{Int}(n)
        # We put indices in random order
        for i in randperm(n)
            put!(c, i, i)
        end
        out = Int[]
        for _ in 1:n
            push!(out, take!(c))
        end
        # The output should be sorted
        @test issorted(out)
    end
    @testset "Empty/Ready" begin
        c = SequentialOutputChannel{Int}(5)
        @test isempty(c)
        @test !isready(c)
        put!(c, 3, 3) 
        @test !isempty(c)
        @test !isready(c)
        put!(c, 1, 1)
        @test isready(c)
        # We test that if there is available data it can be taken even with the closed channel
        close(c)
        @test isready(c)
        take!(c) # After taking idx 1, the channel is not ready anymore
        @test !isready(c)
    end
    @test eltype(SequentialOutputChannel(5)) === Any
    @test eltype(SequentialOutputChannel{Int}(5)) === Int
    @testset "Test Errors" begin
        c = SequentialOutputChannel{Int}(5)
        put!(c, 1, 1)
        @test_throws "The entry with idx 1 is already present" put!(c, 1, 1) 
        take!(c)
        @test_throws "idx 1 has already been consumed" put!(c, 1, 1)
    end
    @testset "Show" begin
        T = Int
        c = SequentialOutputChannel{T}(5)
        @test sprint(show, c) === "SequentialOutputChannel{$(T)}(5)"
        @test sprint((io, x) -> show(io, MIME"text/plain"(), x), c) === "SequentialOutputChannel{$(T)}(5) (empty)"
        put!(c, 2, 2)
        @test sprint((io, x) -> show(io, MIME"text/plain"(), x), c) === "SequentialOutputChannel{$(T)}(5) (next value not available)"
        put!(c, 1, 1)
        @test sprint((io, x) -> show(io, MIME"text/plain"(), x), c) === "SequentialOutputChannel{$(T)}(5) (2 items available)"
    end
    @testset "Ordered with @spawn" begin
    n = 55
	c = SequentialOutputChannel{Int}(5)
    out = Int[]
    @sync begin
        for i in 1:n
            @spawn let
                sleep(rand()/10)
                put!(c, i, i)
            end
        end
        @spawn for i in 1:n
            push!(out, take!(c))
        end
    end
    @test issorted(out)
    end
end