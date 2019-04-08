# Notations from Walker & Ni, "Anderson acceleration for fixed-point iterations", SINUM 2011
# Attempts to accelerate the iteration xₙ₊₁ = xₙ + beta*f(xₙ)

struct Anderson{Tm, Tb}
    m::Tm
    beta::Tb
end
struct AndersonCache{Txs, Tx, Tr, Ta, Tf} <: AbstractSolverCache
    xs::Txs
    gs::Txs
    old_x::Tx
    residuals::Tr
    alphas::Ta
    fx::Tf
end
function AndersonCache(df, method::Anderson)
    m = method.m
    N = length(df.x_f)
    T = eltype(df.x_f)

    xs = zeros(T, N, m+1) #ring buffer storing the iterates, from newest to oldest
    gs = zeros(T, N, m+1) #ring buffer storing the g of the iterates, from newest to oldest
    old_x = xs[:,1]
    if m > 0
        residuals = zeros(T, N, m) #matrix of residuals used for the least-squares problem
        alphas = zeros(T, m) #coefficients obtained by least-squares
    else
        residuals = nothing
        alphas = nothing
    end
    fx = similar(df.x_f, N) # temp variable to store f!

    AndersonCache(xs, gs, old_x, residuals, alphas, fx)
end

@views function anderson_(df::Union{NonDifferentiable, OnceDifferentiable},
                             x0::AbstractArray{T},
                             xtol::T,
                             ftol::T,
                             iterations::Integer,
                             store_trace::Bool,
                             show_trace::Bool,
                             extended_trace::Bool,
                             m::Integer,
                             beta::Real,
                             cache = AndersonCache(df, Anderson(m, beta))) where T
    picard_iteration = cache.alphas == nothing
    copyto!(cache.xs[:,1], x0)
    iters = 0
    tr = SolverTrace()
    tracing = store_trace || show_trace || extended_trace
    x_converged, f_converged, converged = false, false, false

    errs = zeros(iterations)

    for n = 1:iterations
        iters += 1
        # fixed-point iteration
        value!!(df, cache.fx, cache.xs[:,1])

        cache.gs[:,1] .= cache.xs[:,1] .+ beta.*cache.fx

        x_converged, f_converged, converged = assess_convergence(cache.gs[:,1], cache.old_x, cache.fx, xtol, ftol)

        if tracing
            dt = Dict()
            if extended_trace
                dt["x"] = copy(cache.xs[:,1])
                dt["f(x)"] = copy(cache.fx)
            end
            update!(tr,
                    n,
                    maximum(abs,cache.fx),
                    n > 1 ? sqeuclidean(cache.xs[:,1],cache.old_x) : convert(T,NaN),
                    dt,
                    store_trace,
                    show_trace)
        end

        if converged
            break
        end

        new_x = copy(cache.gs[:,1])

        if !picard_iteration
            #update of new_x
            m_eff = min(n-1,m)
            if m_eff > 0
                cache.residuals[:, 1:m_eff] .= (cache.gs[:,2:m_eff+1] .- cache.xs[:,2:m_eff+1]) .- (cache.gs[:,1] .- cache.xs[:,1])
                cache.alphas[1:m_eff] .= cache.residuals[:,1:m_eff] \ (cache.xs[:,1] .- cache.gs[:,1])
                for i = 1:m_eff
                    new_x .+= cache.alphas[i].*(cache.gs[:,i+1] .- cache.gs[:,1])
                end
            end

            cache.xs .= circshift(cache.xs,(0,1)) # no in-place circshift, unfortunately...
            cache.gs .= circshift(cache.gs,(0,1))

            if m > 1
                copyto!(cache.old_x, cache.xs[:,2])
            else
                copyto!(cache.old_x, cache.xs[:,1])
            end
            copyto!(cache.xs[:,1], new_x)
        else
            copyto!(cache.old_x, cache.xs[:,1])
            copyto!(cache.xs[:,1], cache.gs[:,1])
        end
    end

    # returning gs[:,1] rather than xs[:,1] would be better here if
    # xₙ₊₁ = xₙ + beta*f(xₙ) is convergent, but the convergence
    # criterion is not guaranteed

    x = similar(x0) # this is done to ensure that the final x is oftype(x0)
    copyto!(x, cache.xs[:,1])
    return SolverResults("Anderson m=$m beta=$beta",
                         x0, x, maximum(abs,cache.fx),
                         iters, x_converged, xtol, f_converged, ftol, tr,
                         first(df.f_calls), 0)
end

function anderson(df::Union{NonDifferentiable, OnceDifferentiable},
                     initial_x::AbstractArray{T},
                     xtol::Real,
                     ftol::Real,
                     iterations::Integer,
                     store_trace::Bool,
                     show_trace::Bool,
                     extended_trace::Bool,
                     m::Integer,
                     beta::Real,
                     cache = AndersonCache(df, Anderson(m, beta))) where T
    anderson_(df, initial_x, convert(T, xtol), convert(T, ftol), iterations, store_trace, show_trace, extended_trace, m, beta, cache)
end
