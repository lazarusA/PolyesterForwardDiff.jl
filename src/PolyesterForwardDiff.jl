module PolyesterForwardDiff

using Polyester
import ForwardDiff

const DiffResult = ForwardDiff.DiffResults.DiffResult

function cld_fast(a::A,b::B) where {A,B}
    T = promote_type(A,B)
    cld_fast(a%T,b%T)
end
function cld_fast(n::T, d::T) where {T}
    x = Base.udiv_int(n, d)
    x += n != d*x
end

tag(check::Val{false},f,x) = nothing
tag(check::Val{true},f,x::AbstractArray{V}) where V = ForwardDiff.Tag(f, V)

store_val!(r::Base.RefValue{T}, x::T) where {T} = (r[] = x)
store_val!(r::Ptr{T}, x::T) where {T} = Base.unsafe_store!(r, x)

function evaluate_chunks!(f::F, (r,Δx,x), start, stop, ::ForwardDiff.Chunk{C}, check::Val{B}) where {F,C,B}
    Tag = tag(check, f, x)
    TagType = typeof(Tag)
    cfg = ForwardDiff.GradientConfig(f, x, ForwardDiff.Chunk{C}(), Tag)
    N = length(x)
    last_stop = cld_fast(N, C)
    is_last = last_stop == stop
    stop -= is_last

    xdual = cfg.duals
    seeds = cfg.seeds
    ForwardDiff.seed!(xdual, x)
    for c ∈ start:stop
        i = (c-1) * C + 1
        ForwardDiff.seed!(xdual, x, i, seeds)
        ydual = f(xdual)
        ForwardDiff.extract_gradient_chunk!(TagType, Δx, ydual, i, C)
        ForwardDiff.seed!(xdual, x, i)
    end
    if is_last
        lastchunksize = C + N - last_stop*C
        lastchunkindex = N - lastchunksize + 1
        ForwardDiff.seed!(xdual, x, lastchunkindex, seeds, lastchunksize)
        _ydual = f(xdual)
        ForwardDiff.extract_gradient_chunk!(TagType, Δx, _ydual, lastchunkindex, lastchunksize)
        store_val!(r, ForwardDiff.value(_ydual))
    end
end

function threaded_gradient!(f::F, Δx::AbstractArray, x::AbstractArray, ::ForwardDiff.Chunk{C}, check = Val{false}()) where {F,C}
    N = length(x)
    d = cld_fast(N, C)
    r = Ref{eltype(Δx)}()
    function gradient_worker(rΔxx, start, stop, f, C, check)
        evaluate_chunks!(f, rΔxx, start, stop, ForwardDiff.Chunk{C}(), check)
    end
    batch(gradient_worker, (1, min(d, Threads.nthreads())), r, Δx, x, f, C, check)
    r[]
end

#### in-place jac, out-of-place f ####

function evaluate_jacobian_chunks!(f::F, (Δx,x), start, stop, ::ForwardDiff.Chunk{C}, check::Val{B}) where {F,C,B}
    Tag = tag(check, f, x)
    TagType = typeof(Tag)
    cfg = ForwardDiff.JacobianConfig(f, x, ForwardDiff.Chunk{C}(), Tag)
    # figure out loop bounds
    N = length(x)
    last_stop = cld_fast(N, C)
    is_last = last_stop == stop
    stop -= is_last

    # seed work arrays
    xdual = cfg.duals
    ForwardDiff.seed!(xdual, x)
    seeds = cfg.seeds

    # handle intermediate chunks
    for c ∈ start:stop
        # compute xdual
        i = (c-1) * C + 1
        ForwardDiff.seed!(xdual, x, i, seeds)

        # compute ydual
        ydual = f(xdual)

        # extract part of the Jacobian
        Δx_reshaped = ForwardDiff.reshape_jacobian(Δx, ydual, xdual)
        ForwardDiff.extract_jacobian_chunk!(TagType, Δx_reshaped, ydual, i, C)
        ForwardDiff.seed!(xdual, x, i)
    end

    # handle the last chunk
    if is_last
        lastchunksize = C + N - last_stop*C
        lastchunkindex = N - lastchunksize + 1

        # compute xdual
        ForwardDiff.seed!(xdual, x, lastchunkindex, seeds, lastchunksize)

        # compute ydual
        _ydual = f(xdual)

        # extract part of the Jacobian
        _Δx_reshaped = ForwardDiff.reshape_jacobian(Δx, _ydual, xdual)
        ForwardDiff.extract_jacobian_chunk!(TagType, _Δx_reshaped, _ydual, lastchunkindex, lastchunksize)
    end
end

function threaded_jacobian!(f::F, Δx::AbstractArray, x::AbstractArray, ::ForwardDiff.Chunk{C}, check = Val{false}()) where {F,C}
    N = length(x)
    d = cld_fast(N, C)
    batch((d, min(d, Threads.nthreads())), Δx, x, f, check) do Δxx, start, stop, f, check
        evaluate_jacobian_chunks!(f, Δxx, start, stop, ForwardDiff.Chunk{C}(), check)
    end
    return Δx
end

# # #### in-place jac, in-place f ####

function evaluate_f_and_jacobian_chunks!(f!::F, (y,Δx,x), start, stop, ::ForwardDiff.Chunk{C}, check::Val{B}) where {F,C,B}
    Tag = tag(check, f!, x)
    TagType = typeof(Tag)
    cfg = ForwardDiff.JacobianConfig(f!, y, x, ForwardDiff.Chunk{C}(), Tag)

    # figure out loop bounds
    N = length(x)
    last_stop = cld_fast(N, C)
    is_last = last_stop == stop
    stop -= is_last

    # seed work arrays
    ydual, xdual = cfg.duals
    ForwardDiff.seed!(xdual, x)
    seeds = cfg.seeds
    Δx_reshaped = ForwardDiff.reshape_jacobian(Δx, ydual, xdual)

    # handle intermediate chunks
    for c ∈ start:stop
        # compute xdual
        i = (c-1) * C + 1
        ForwardDiff.seed!(xdual, x, i, seeds)

        # compute ydual
        f!(ForwardDiff.seed!(ydual, y), xdual)

        # extract part of the Jacobian
        ForwardDiff.extract_jacobian_chunk!(TagType, Δx_reshaped, ydual, i, C)
        ForwardDiff.seed!(xdual, x, i)
    end

    # handle the last chunk
    if is_last
        lastchunksize = C + N - last_stop*C
        lastchunkindex = N - lastchunksize + 1

        # compute xdual
        ForwardDiff.seed!(xdual, x, lastchunkindex, seeds, lastchunksize)

        # compute ydual
        f!(ForwardDiff.seed!(ydual, y), xdual)

        # extract part of the Jacobian
        ForwardDiff.extract_jacobian_chunk!(TagType, Δx_reshaped, ydual, lastchunkindex, lastchunksize)
        map!(ForwardDiff.value, y, ydual)
    end
end

function threaded_jacobian!(f!::F, y::AbstractArray, Δx::AbstractArray, x::AbstractArray, ::ForwardDiff.Chunk{C},check = Val{false}()) where {F,C}
    N = length(x)
    d = cld_fast(N, C)
    batch((d, min(d, Threads.nthreads())), y, Δx, x, f!, check) do yΔxx, start, stop, f!, check
        evaluate_f_and_jacobian_chunks!(f!, yΔxx, start, stop, ForwardDiff.Chunk{C}(), check)
    end
    Δx
end

end
