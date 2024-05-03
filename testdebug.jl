using Random, SequentialOutputChannels
using Base.Threads: @spawn

let n = 55
	c = SequentialOutputChannel{Int}(5)
	# c = Channel{Int}(5)
    out = Int[]
    @sync begin
        for i in 1:n
            @spawn let
                sleep(rand()/10)
                if c isa Channel
                    put!(c, i)
                else
                    put!(c, i, i)
                end
            end
        end
        @spawn for i in 1:n
            push!(out, take!(c))
        end
    end
    out
    issorted(out), out
end

let
    c = SequentialOutputChannel{Int}(5)
    @spawn let c = c
        lock(c)
        for _ in 1:1
            rand(1000,1000)*rand(1000,1000)
        end
        unlock(c)
    end
    islocked(c.cond_take)
    # trylock(c)
end