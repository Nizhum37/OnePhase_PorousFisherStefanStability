# Control function for 2D Porous-Fisher-Stefan level-set solutions
# Nizhum Rahman and Alex Tam, 08/12/2023

# Load packages
using Parameters
using Printf
using Dierckx
using LinearAlgebra
using DifferentialEquations
using Measures
using LaTeXStrings
using DelimitedFiles
using Roots

# Include external files
include("twic.jl")
include("domain.jl")
include("porous-fisher.jl")
include("velocity_extension.jl")
include("interface_density.jl")
include("interface_speed.jl")
include("level-set.jl")
include("reinitialisation.jl")

"Data structure for parameters"
@with_kw struct Params
    D::Float64 = 1.0 # [-] Diffusion coefficient
    m::Float64 = 1.0 # [-] Nonlinear diffusion exponent, D(u) = u^m
    λ::Float64 = 1.0 # [-] Reaction rate
    κ::Float64 = 0.1 # [-] Inverse Stefan number
    γ::Float64 = 0.0 # [-] Surface tension coefficient
    β::Float64 = 0.0 # [-] Initial interface position
    uf::Float64 = 1e-6 # [-] Background density at interface
    θb::Float64 = 0.01 # [-] Threshold for whether a grid point is close to interface (relative to Δx)
    θ::Float64 = 1.99 # [-] Parameter for minmod flux-limiter
    Lx::Float64 = 10.0 # [-] Spatial domain limit (x) (-Lx,Lx)
    Ly::Float64 = 10.0 # [-] Spatial domain limit (y)
    Lξ::Float64 = 10.0 # [-] Domain width for travelling wave (ξ)
    T::Float64 = 90.0 # [-] End time
    Nx::Int = 401 # [-] Number of grid points (x)
    Ny::Int = 201 # [-] Number of grid points (y)
    Nt::Int = 1801.0 # [-] Number of time steps
    Nξ::Int = 101 # [-] Number of grid points for travelling wave (ξ)
    a::Float64 = 1e-2 # [-] Parameter for geometric progression
    V_Iterations::Int = 20 # [-] Number of iterations for velocity extrapolation PDE
    ϕ_Iterations::Int = 20 # [-] Number of iterations for reinitialisation PDE
    ε::Float64 = 0.0#0.1 # [-] Small amplitude of perturbations
    q::Float64 = 0.0#2*pi/5 # [-] Wave number of perturbations
end

"Interpolate to obtain initial condition"
function ic(par, x, y)
    U = Array{Float64}(undef, par.Nx, par.Ny) # Pre-allocate 2D array of U
    ϕ = Array{Float64}(undef, par.Nx, par.Ny) # Pre-allocate 2D array of ϕ
    # Compute ϕ = ξ at each grid point
    for i in eachindex(x)
        for j in eachindex(y)
            ϕ[i,j] = x[i] - par.β - par.ε*cos(par.q*y[j])
        end
    end
    # Interpolate travelling wave to obtain initial densities
    for i in eachindex(x)
        for j in eachindex(y)
            if ϕ[i,j] < 0 # If grid point is in Ω(0)
                U[i,j] = 1.0 # Perturbed travelling wave
            else # If grid point is not in Ω(0)
                U[i,j] = par.uf
            end
        end
    end
    return U, ϕ
end

"Build vector from matrix, ordered by entries in D"
function build_vector(U::Array{Float64}, D)
    u = Vector{Float64}() # Pre-allocate empty vector
    for gp in D
        push!(u, U[gp.xInd, gp.yInd])
    end
    return u
end

"Build matrix from vector ordered by entries in D"
function build_u_matrix(u::Vector, y, par, D)
    U = zeros(par.Nx, par.Ny) # Pre-allocate (incorporate a Dirichlet condition on right boundary)
    U[par.Nx,:] .= par.uf # Dirichlet condition on right boundary
    U[1,:] .= 1.0 # Dirichlet condition on left boundary
    for i in eachindex(D)
        U[D[i].xInd, D[i].yInd] = u[i]
    end
    return U
end

"Build matrix from vector ordered by entries in D"
function build_v_matrix(v::Vector, par, D)
    V = zeros(par.Nx, par.Ny) # Pre-allocate (incorporate a Dirichlet condition on computational boundary)
    for i in eachindex(D)
        V[D[i].xInd, D[i].yInd] = v[i]
    end
    return V
end

"Locate interface position"
function front_position(x, ϕ, par, ny, dx)
    L = 0.0 # Pre-allocate front-position
    Lmax = 0.0 # Pre-allocate max front position
    Lmin = par.Lx # Pre-allocate min front position
    # Find front position using x-direction slice
    for j = 1:par.Ny # Loop over y
        ϕv = ϕ[:,j] # Obtain 1D vector of ϕ
        for i = 1:par.Nx
            if (ϕv[i] < 0) && (ϕv[i+1] >= 0)
                θ = ϕv[i]/(ϕv[i] - ϕv[i+1])
                Lj = x[i] + θ*dx
                if Lj <= Lmin
                    Lmin = Lj
                end
                if Lj >= Lmax
                    Lmax = Lj
                end
                if j == ny
                    L = Lj
                end
            end
        end
    end
    return L, (Lmax-Lmin)/2 # Return amplitude of perturbation
end

"Compute a solution"
function porous_fisher_stefan_2d()
    # Parameters and domain
    par = Params() # Initialise data structure of model parameters
    nx::Int = (par.Nx-1)/2; ny::Int = (par.Ny-1)/2 # Indices for slice plots
    x = range(-par.Lx, par.Lx, length = par.Nx); dx = abs(x[2] - x[1]) # Computational domain (x)
    y = range(0, par.Ly, length = par.Ny); dy = y[2] - y[1] # Computational domain (y)
    t = range(0, par.T, length = par.Nt); dt = t[2] - t[1] # Time domain
    writedlm("x.csv", x); writedlm("y.csv", y); writedlm("t.csv", t) # Write data to files
    # Initial condition
    U, ϕ = ic(par, x, y) # Obtain initial density and ϕ
    Φ = U.^(par.m+1) # Φ(x,y,t)
    writedlm("U-0.csv", Φ); writedlm("Phi-0.csv", ϕ) # Write data to files
    plot_times = Vector{Int}() # Vector of time-steps at which data is obtained
    writedlm("plot_times.csv", plot_times)
    L = Vector{Float64}() # Preallocate empty vector of interface position
    Amp = Vector{Float64}() # Preallocate empty vector of perturbation amplitude
    Li, amp = front_position(x, ϕ, par, ny, dx)
    push!(L, Li); push!(Amp, amp)
    # Time stepping
    for i = 1:par.Nt-1
        # 1. Find Ω, dΩ, and irregular grid points
        D = find_domain(par, ϕ)
        dΩ = find_interface(par, D, ϕ)
        # 2. Solve Porous-Fisher equation on Ω
        uf = interface_density(dΩ, ϕ, par, dx, dy) # Density on interface for BC
        @time Φ = pf(D, dΩ, Φ, ϕ, uf, y, par, dx, dy, dt, i)
        # 3. Compute extension velocity field
        V = extend_velocity(D, dΩ, Φ, ϕ, par, dx, dy)
        # 4. Solve level-set equation
        ϕ = level_set(V, ϕ, par, dx, dy, dt)
        # 5. Re-initialise level-set function as a signed-distance function
        if mod(i, 1) == 0
            ϕ = reinitialisation(ϕ, par, dx, dy, par.ϕ_Iterations)
        end
        # Optional: Post-processing
        if mod(i, 600) == 0
            writedlm("ux-$i.csv", Φ[:,ny])
            writedlm("uy-$i.csv", Φ[nx,:])
            writedlm("U-$i.csv", Φ)
            writedlm("V-$i.csv", V)
            writedlm("Phi-$i.csv", ϕ)
            push!(plot_times, i)
            writedlm("plot_times.csv", plot_times)
        end
        Li, amp = front_position(x, ϕ, par, ny, dx)
        push!(L, Li)
        push!(Amp, amp)
        writedlm("L.csv", L)
        writedlm("Amp.csv", Amp)
        #writedlm("m.csv", par.m)
    end
end

@time porous_fisher_stefan_2d()