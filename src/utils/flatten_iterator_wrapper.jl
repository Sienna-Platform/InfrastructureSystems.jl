
"""
Wrapper around Iterators.Flatten to provide total length.
"""
struct FlattenIteratorWrapper{T, I}
    iter::Iterators.Flatten{I}
    length::Int
end

function FlattenIteratorWrapper(::Type{T}, vals::I) where {T, I}
    len = isempty(vals) ? 0 : sum((length(x) for x in vals))
    return FlattenIteratorWrapper{T, I}(Iterators.Flatten(vals), len)
end

Base.@propagate_inbounds function Base.iterate(
    iter::FlattenIteratorWrapper{T, I},
) where {T, I}
    Base.iterate(iter.iter)
end

Base.@propagate_inbounds function Base.iterate(
    iter::FlattenIteratorWrapper{T, I},
    state,
) where {T, I}
    Base.iterate(iter.iter, state)
end

Base.eltype(::FlattenIteratorWrapper{T, I}) where {T, I} = T
Base.length(iter::FlattenIteratorWrapper) = iter.length
Base.filter(f, iter::FlattenIteratorWrapper{T}) where {T} = T[x for x in iter if f(x)]
