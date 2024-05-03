module SequentialOutputChannels

using Base: concurrency_violation, notify_error, InvalidStateException

export SequentialOutputChannel

# This is mostly adapted from the SequentialOutputChannel definition in Base

"""
    SequentialOutputChannel{T=Any}(size::Int)

Constructs a `SequentialOutputChannel` with an internal buffer that can hold a maximum of `size` objects
of type `T`.
This is similar to SequentialOutputChannel but it does not extracts object in the order they were inserted, but in sequential order of priority/index.

The channel keeps internally a buffer capable of containing up to the next `size` objects from the last consumed index.

Each object inserted in the channel must be assigned a unique index/priority when calling [`put!`](@ref). Indices are unique so no two objects can be inserted with the same index. When trying to insert an object with an index that is more than `size` indices away from the last consumed one, the `put!` call will block until enough indices have been consumed by the channel.

Calls to [`take!`](@ref) will always return the inserted objects in increasing index (without gaps, i.e. the differences between indices of two subsequent `take!` calls is always 1). If the next index to be consumed has not been put yet in the channel, the [`take!`](@ref) call will block until the next index is inserted.

# Examples
```jldoctest
julia> c = SequentialOutputChannel{Int}(5)
SequentialOutputChannel{Int64}(5) (empty)

julia> out = Int[];

julia> @sync begin
            n = 15
            for i in 1:n 
                Threads.@spawn let
                    sleep(rand()/10) # This make the outputs come out of order
                    put!(c, i, i)
                end
            end
            Threads.@spawn for i in 1:n
                push!(out, take!(c))
            end
        end;

julia> issorted(out)
true
```
"""
mutable struct SequentialOutputChannel{T}
    cond_take::Threads.Condition                 # waiting for data to become available
    cond_put::Threads.Condition                  # waiting for a writeable slot
    @atomic state::Symbol
    excp::Union{Exception,Nothing}      # exception to be thrown when state !== :open

    data::Vector{T}
    valid_data::BitVector                # BitVector mapping valid elements within the buffer
    @atomic n_avail_items::Int           # Available items for taking, can be read without lock
    sz_max::Int                          # maximum size of channel
    @atomic last_output_idx::Int         # Index of the last element taken from the channel

    function SequentialOutputChannel{T}(sz::Integer) where {T}
        if sz <= 0
            throw(ArgumentError("SequentialOutputChannel size must be a positive Integer"))
        end
        lock = ReentrantLock()
        cond_put, cond_take = Threads.Condition(lock), Threads.Condition(lock)
        return new(cond_take, cond_put, :open, nothing, Vector{T}(undef, sz), falses(sz), 0, sz, 0)
    end
end
SequentialOutputChannel(sz::Int) = SequentialOutputChannel{Any}(sz)

closed_exception() = InvalidStateException("SequentialOutputChannel is closed.", :closed)


function check_channel_state(c::SequentialOutputChannel)
    if !isopen(c)
        # if the monotonic load succeed, now do an acquire fence
        (@atomic :acquire c.state) === :open && concurrency_violation()
        excp = c.excp
        excp !== nothing && throw(excp)
        throw(closed_exception())
    end
end

"""
    close(c::SequentialOutputChannel[, excp::Exception])

Close a SequentialOutputChannel. An exception (optionally given by `excp`), is thrown by:

* [`put!`](@ref) on a closed channel.
* [`take!`](@ref) on an empty, closed channel.
"""
Base.close(c::SequentialOutputChannel) = close(c, closed_exception()) # nospecialize on default arg seems to confuse makedocs

function Base.close(c::SequentialOutputChannel, @nospecialize(excp::Exception))
    lock(c)
    try
        c.excp = excp
        @atomic :release c.state = :closed
        notify_error(c.cond_take, excp)
        notify_error(c.cond_put, excp)
    finally
        unlock(c)
    end
    nothing
end

# Use acquire here to pair with release store in `close`, so that subsequent `isready` calls
# are forced to see `isready == true` if they see `isopen == false`. This means users must
# call `isopen` before `isready` if you are using the race-y APIs (or call `iterate`, which
# does this right for you).
Base.isopen(c::SequentialOutputChannel) = ((@atomic :acquire c.state) === :open)

Base.lock(c::SequentialOutputChannel) = lock(c.cond_take)
Base.lock(f, c::SequentialOutputChannel) = lock(f, c.cond_take)
Base.unlock(c::SequentialOutputChannel) = unlock(c.cond_take)
Base.trylock(c::SequentialOutputChannel) = trylock(c.cond_take)

"""
    put!(c::SequentialOutputChannel, v, idx::Int)

Insert an item `v` in channel `c` with index/priority `idx`. Blocks if the channel's buffer is not big enough to hold the `idx`-th element until enough items are consumed from the channel.

Throws an error if `idx` has already been consumed or if is not consumed yet but has previously been inserted.
"""
Base.put!(c::SequentialOutputChannel, v, idx::Int) = _put!(c, v, idx)

# This function assumes that we hold the lock onto the channel, it will simply try to put in the provided element at the provided idx. It will returns true if it succeded or false if the provided idx is beyond the current buffer capability
function _locked_put!(c::SequentialOutputChannel, v, idx::Int)
    check_channel_state(c)
    last_out = c.last_output_idx
    idx <= last_out && error("SequentialOutputChannel: idx $idx has already been consumed from the channel")
    offset_from_last = idx - last_out
    did_buffer = false
    if offset_from_last <= c.sz_max
        c.valid_data[offset_from_last] && error("The entry with idx $idx is already present in the SequentialOutputChannel's buffer")
        c.valid_data[offset_from_last] = true
        c.data[offset_from_last] = v
        did_buffer = true
    end
    return did_buffer
end

function _put!(c::SequentialOutputChannel, v, idx::Int)
    lock(c)
    try
        # We try putting, and repeat until we are able to insert in the buffer
        while !(_locked_put!(c, v, idx))
            wait(c.cond_put)
        end
        new_avail = findfirst(!, c.valid_data)
        new_avail = new_avail === nothing ? c.sz_max : new_avail - 1
        @atomic :monotonic c.n_avail_items = new_avail
        if new_avail > 0
            # We notify only the first listener as we do not envisage supporting fetch for this channel
            notify(c.cond_take, nothing, false, false)
        end
    finally
        unlock(c)
    end
    return v
end


"""
    take!(c::SequentialOutputChannel)

Removes and returns a value from a [`SequentialOutputChannel`](@ref) in order of index/priority (as provided to [`put!`](@ref)). Blocks until data is available.

# Examples

Buffered channel:
```jldoctest
julia> c = SequentialOutputChannel(2);

julia> put!(c, :second, 2); # Inserted first but with index 2

julia> put!(c, :first, 1);

julia> take!(c)
:first
```
"""
Base.take!(c::SequentialOutputChannel) = _take!(c)

function _take!(c::SequentialOutputChannel)
    lock(c)
    try
        while n_avail(c) === 0
            check_channel_state(c)
            wait(c.cond_take)
        end
        # We circshift the buffer to have all other elements gets up the list and extract the last element (which was the first one before the shift)
        v = first(c.data)
        circshift!(c.data, -1)
        # We circshift the mask as well and tag the last position as containing invalid data
        circshift!(c.valid_data, -1)[end] = false
        # Decrease available and increase last outputted idx
        new_avail = c.n_avail_items - 1
        @atomic :monotonic c.n_avail_items = new_avail
        if new_avail > 0
            notify(c.cond_take, nothing, false, false)
        end
        new_output = c.last_output_idx + 1
        @atomic :monotonic c.last_output_idx = new_output
        # We notify all put! listeners, as we don't know which one, if any, has the right idx to be put in
        notify(c.cond_put, nothing, true, false)
        return v
    finally
        unlock(c)
    end
end

"""
    isready(c::SequentialOutputChannel)

Determines whether a [`SequentialOutputChannel`](@ref) has a value stored in it for the next index supposed to be sent (considering the sequential idx ordering).
Returns immediately, does not block.

# Examples

```jldoctest
julia> c = SequentialOutputChannel(5);

julia> isready(c)
false

julia> put!(c, 3, 3); # Put an element with idx 3, but we never sent idx 1 out

julia> isready(c)
false

julia> put!(c, 1, 1); # Put an element with idx 1, we can now consume the first element

julia> isready(c)
true
```

"""
Base.isready(c::SequentialOutputChannel) = n_avail(c) > 0
function Base.isempty(c::SequentialOutputChannel)
    lock(c) do
        !any(c.valid_data)
    end
end
n_avail(c::SequentialOutputChannel) = @atomic :monotonic c.n_avail_items

Base.eltype(::Type{SequentialOutputChannel{T}}) where {T} = T

Base.show(io::IO, c::SequentialOutputChannel) = print(io, typeof(c), "(", c.sz_max, ")")

function Base.show(io::IO, ::MIME"text/plain", c::SequentialOutputChannel)
    show(io, c)
    if !(get(io, :compact, false)::Bool)
        if !isopen(c)
            print(io, " (closed)")
        else
            n = n_avail(c)
            if n == 0
                if isempty(c)
                    print(io, " (empty)")
                else
                    print(io, " (next value not available)")
                end
            else
                s = n == 1 ? "" : "s"
                print(io, " (", n, " item$s available)")
            end
        end
    end
end

end # module SequentialOutputChannels
