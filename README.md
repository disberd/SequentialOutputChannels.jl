# SequentialOutputChannels

<!-- [![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://disberd.github.io/SequentialOutputChannels.jl/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://disberd.github.io/SequentialOutputChannels.jl/dev) -->
[![Build Status](https://github.com/disberd/SequentialOutputChannels.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/disberd/SequentialOutputChannels.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/disberd/SequentialOutputChannels.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/disberd/SequentialOutputChannels.jl)

This packages provides a single type `SequentialOutputChannel` which is a simple `Channel`-like object that takes potentially un-ordered items and outputs them in sequential order:

```julia
using Random: randperm
using SequentialOutputChannels

n = 15
c = SequentialOutputChannel{Int}(n)
# We put indices in random order
for i in randperm(n)
    put!(c, i, i) # third arugment represents the priority/idx
end
out = Int[]
for _ in 1:n
    push!(out, take!(c)) # outputs are always generated in sequential (idx) order from take!
end
# The output should be sorted
@test issorted(out)
```

The main use-case for this channel is for ordering/serializing output of multi-threaded computations that might be performed out-of-order but must be processed in order aftewards.

The following methods from Base are implemented for `SequentialOutputChannel`:
- `close(c::SequentialOutputChannel)`: Closes the channel
- `isopen(c::SequentialOutputChannel)`: Checks whether the channel is open
- `put!(c::SequentialOutputChannel, v, idx::Int)`: Put an element `v` in the channel with idx `idx`. If the provided idx is beyond the channel's buffer size, the call will block until enough entries have been consumed from the channel to allow insertion
- `take!(c::SequentialOutputChannel)`: Extracts the next idx from the channel. If the next idx is not available, blocks until it is inserted with `put!`
- `isready(c::SequentialOutputChannel)`: Checks whether the channel has the next idx ready for consumption
- `isempty(c::SequentialOutputChannel)`: Checks whether the channel's internal buffer contains any valid inserted element
- `eltype(c::SequentialOutputChannel)`: Returns the type of elements stored in the channel.
- `lock`: Like `lock` for a normal Channel
- `unlock`: Like `unlock` for a normal Channel
- `trylock`: Like `trylock` for a normal Channel