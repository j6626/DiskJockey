#!/usr/bin/env julia

# Uses the EnsembleSampler to explore the posterior.
# In contrast to codes like mach_three.jl, this architecture means that within each likelihood call, the global lnprob for all channels is evaluated in *serial*, while the walkers themselves are parallelized.

using ArgParse
using Distributed
@everywhere using Printf
@everywhere using Test

s = ArgParseSettings()
@add_arg_table s begin
    "--p", "-p"
    help = "number of processes to add"
    arg_type = Int
    default = 0
    "--run_index", "-r"
    help = "Output run index"
    arg_type = Int
    "--config"
    help = "a YAML configuration file"
    default = "config.yaml"
    "--cpus"
    help = "Which CPUS to add"
    arg_type = Array{Int,1}
    eval_arg = true
    "--optim"
    help = "Optimize instead of sample?"
    action = :store_true
    "--test"
    help = "Is this a test run of venus.jl? Allow using many fewer walkers for eval purposes."
    action = :store_true
    "--MPI"
    help = "Run the script using MPI"
    action = :store_true
end

parsed_args = parse_args(ARGS, s)

cpus = parsed_args["cpus"]

if cpus != nothing
    using ClusterManagers
    np = length(cpus)
    addprocs(LocalAffinityManager(;np = np, affinities = cpus))
end

# Since we've made this a #!/usr/bin/env julia script, we can no longer specify the extra
# processors via the julia executable, so we need to ghost this behavior back in.
if parsed_args["p"] > 0
    addprocs(parsed_args["p"])
end

# Use MPI as the transport mechanism--good for a cluster environment
if parsed_args["MPI"]
    import MPI
    MPI.Init()
    rank = MPI.Comm_rank(MPI.COMM_WORLD)
    size_workers = MPI.Comm_size(MPI.COMM_WORLD)

    manager = MPI.start_main_loop(MPI.MPI_TRANSPORT_ALL)
end

import YAML
config = YAML.load(open(parsed_args["config"]))

outfmt(run_index::Int) = config["out_base"] * @sprintf("run%02d/", run_index)

# This code is necessary for multiple simultaneous runs on a high performance cluster
# so that different runs do not write into the same output directory
if parsed_args["run_index"] == nothing
    global run_index = 0
    global outdir = outfmt(run_index)
    while ispath(outdir)
        println(outdir, " exists")
        global run_index += 1
        global outdir = outfmt(run_index)
    end
    # are we starting in a fresh directory?
    fresh = true
else
    global run_index = parsed_args["run_index"]
    global outdir = outfmt(run_index)
    if ispath(outdir)
        # we are not starting in a fresh directory, so try loading pos0.npy from this directory.
        fresh = false
    else
        fresh = true
    end
end

if fresh
    # make the output directory
    println("Creating ", outdir)
    mkdir(outdir)
    # Copy the config.yaml file here for future reference
    cp(parsed_args["config"], outdir * parsed_args["config"])
else
    println("$outdir exists, using current.")
end

@everywhere using AbstractFFTs
@everywhere using DiskJockey.constants
@everywhere using DiskJockey.visibilities
@everywhere using DiskJockey.image
@everywhere using DiskJockey.gridding
@everywhere using DiskJockey.model


# Determine if we will be including the User-defined prior
if isfile("prior.jl")
    println("Including user-defined prior from prior.jl")
    @everywhere include(pwd() * "/prior.jl")
    # Make a copy to the outdirectory for future reference
    cp("prior.jl", outdir * "prior.jl")
end

# load data and figure out how many channels
dvarr = DataVis(config["data_file"])
nchan = length(dvarr)


lam0 = lam0s[config["species"] * config["transition"]]
# calculate the velocities corresponding to dvarr
lams = Float64[dv.lam for dv in dvarr]
vels = c_kms * (lams .- lam0) / lam0

# create a mask that excludes channels we don't want
if haskey(config, "exclude")
    exclude = config["exclude"]
    vel_mask = generate_vel_mask(exclude, vels)
else
    vel_mask = trues(nchan)
end

println("Using the following channels (velocities in km/s): ", vels[vel_mask])

# This program is meant to be started with the -p option.
nchild = nworkers()
println("Workers allocated ", nchild)

# make the values of run_index and config available on all processes
for process in procs()
    @spawnat process global run_id = run_index
    @spawnat process global cfg = config
    @spawnat process global vmask = vel_mask
end

# Convert the parameter values from the config.yaml file from Dict{String, Float64} to
# Dict{Symbol, Float64} so that they may be splatted as extra args into the convert_vector method
@everywhere xargs = Dict{Symbol,Float64}(Symbol(index) => value for (index, value) in pairs(cfg["parameters"]))

# Read the fixed and free parameters from the config.yaml file
@everywhere fix_params = cfg["fix_params"]

# Set the correct model, and the parameters that will be fixed
@everywhere function convert_p(p::Vector{Float64})
    return convert_vector(p, cfg["model"], fix_params; xargs...)
end

# Now, redo this to only load the dvarr for the keys that we need, and conjugate
# @everywhere dvarr = DataVis(cfg["data_file"], kl)
@everywhere dvarr = DataVis(cfg["data_file"], vmask)
@everywhere visibilities.conj!(dvarr)
@everywhere nchan = length(dvarr)

@everywhere const global species = cfg["species"]

@everywhere const global npix = cfg["npix"] # number of pixels, can alternatively specify x and y separately

# Keep track of the current home directory
@everywhere const global homedir = pwd() * "/"

# Create the model grid
@everywhere grd = cfg["grid"]
@everywhere grid = Grid(grd)

# calculate the interpolation closures, since we are keeping the angular size of the image
# fixed thoughout the entire simulation.
# calculate dl and dm (assuming they are equal).
@everywhere dl = cfg["size_arcsec"] * arcsec / cfg["npix"] # [radians/pixel]

# Determine dRA and dDEC from the image and distance
# These will be used to correct for the half-pixel offset
@everywhere half_pix = dl / (arcsec * 2.) # [arcsec/half-pixel]

@everywhere uu = fftshift(visibilities.fftfreq(npix, dl)) * 1e-3 # [kλ]
@everywhere vv = fftshift(visibilities.fftfreq(npix, dl)) * 1e-3 # [kλ]

# For each channel, calculate the interpolation closures
@everywhere int_arr = Array{Function}(undef, nchan)
@everywhere for (i, dset) in enumerate(dvarr)
    int_arr[i] = plan_interpolate(dset, uu, vv)
end


# This function is fed to the EnsembleSampler
# That means, using the currently available global processes, like the data visibilities,
# and it must create it's own temporary directory to write the necessary files for
# RADMC to run.
@everywhere function fprob(p::Vector{Float64})
    # Each walker needs to create it's own temporary directory
    # where all RADMC-3D files will reside and be driven from
    # It only needs to last for the duration of this function, so we use a tempdir
    keydir = mktempdir() * "/"

    lnp = try
        # Convert the vector to a specific type of pars, e.g. ParametersStandard, ParametersTruncated, etc, which will be used for multiple dispatch from here on out.
        pars = convert_p(p) # will raise an error if can't convert

        lnpr = lnprior(pars, grid)
        (sizeau_desired, sizeau_command) = size_au(cfg["size_arcsec"], pars.dpc, grid) # [AU]

        # Copy all relevant configuration scripts to the keydir so that RADMC-3D can run.
        # these are mainly setup files that will be static throughout the run
        # they were written by DJInitialize.jl and write_grid()
        for fname in ["radmc3d.inp", "wavelength_micron.inp", "lines.inp", "molecule_" * molnames[species] * ".inp"]
            run(`cp $(homedir)$fname $keydir`)
        end

        # change the subprocess to reside in this directory for the remainder of the run
        # where it will drive its own independent RADMC3D process for a subset of channels
        cd(keydir)

        # write the amr_grid.inp file
        write_grid(keydir, grid)

        # Compute disk structure files using model.jl, write to disk in current directory
        # Based upon typeof(pars), the subroutines within this function will dispatch to the correct model.
        write_model(pars, keydir, grid, species)

        # Doppler shift the dataset wavelengths to rest-frame wavelength
        beta = pars.vel / c_kms # relativistic Doppler formula
        lams = Array{Float64}(undef, nchan)
        for i = 1:nchan
            lams[i] =  dvarr[i].lam * sqrt((1. - beta) / (1. + beta)) # [microns]
        end

        write_lambda(lams, keydir) # write into current directory

        # Run RADMC-3D, redirect output to /dev/null
        run(pipeline(`radmc3d image incl $(pars.incl) posang $(pars.PA) npix $npix loadlambda sizeau $sizeau_command`, devnull))

        # Read the RADMC-3D images from disk
        img = try
            imread() # we should already be in the sub-directory, no path required
        # If the synthesized image is screwed up, just say there is zero probability.
        catch y
            if isa(y, SystemError)
                throw(ImageException("Failed to read synthesized image for parameters $pars"))
            else
                println("Unexpected error for $pars, exiting")
                throw(y)
            end
        end

        phys_size = img.pixsize_x * npix / AU

        # Convert raw images to the appropriate distance
        skim = imToSky(img, pars.dpc)

        # Apply the gridding correction function before doing the FFT
        # No shift needed, since we will shift the resampled visibilities
        corrfun!(skim)

        lnprobs = Array{Float64}(undef, nchan)
        # Do the Fourier domain stuff per channel
        for i = 1:nchan
            dv = dvarr[i]
            # FFT the appropriate image channel
            vis_fft = transform(skim, i)

            # Interpolate the `vis_fft` to the same locations as the DataSet
            mvis = int_arr[i](dv, vis_fft)

            # Apply the phase shift here, which includes a correction for the half-pixel offset
            # inherent to any image synthesized with RADMC3D.
            phase_shift!(mvis, pars.mu_RA + half_pix, pars.mu_DEC - half_pix)

            # Calculate the likelihood between these two using our chi^2 function.
            lnprobs[i] = lnprob(dv, mvis)
        end

        # Sum them all together
        # this quantity is assigned to the value of lnp at the start of the try/catch block
        sum(lnprobs) + lnpr

    catch y
        # If an error occured through some of the known routines in this package handle it and return -Inf
        if isa(y, DiskJockeyException)
            # print the error message and move on, returning -Inf
            println(y)
        else
            # if the error is not coming from one of the channels we 
            # designed, actually terminate the program after printing the 
            # parameter values at which the error occured
            println("Unforeseen error with parameter vector $p")
            println("Unforeseen error with parameter type $pars")
            throw(y)
        end

        # -Inf is returned as the value of lnp
        -Inf
    finally
        # regardless of whether we ignored the error or allowed it 
        # to terminate the program, change back to the home directory and 
        # then remove the temporary directory
        cd(homedir)
        run(`rm -rf $keydir`)
    end

    return lnp

end


# Decide if we're going to optimize the parameters or sample the posteriors.
if parsed_args["optim"]
    sparams = registered_params[cfg["model"]]

    # fit_params are the ones in sample_params that are not in fix_params
    fit_params = filter(x->!in(x, fix_params), sparams)

    # note the Float64 is how we prepend a type to the comprehension
    # p0 = Float64[cfg["parameters"][parname] for parname in fit_params]
    
    parrangesdict = cfg["parameter_ranges"]
    MaxFuncEvals = cfg["MaxFuncEvals"]

    # get the ranges
    sranges = [tuple(convert(Array{Float64,1}, cfg["parameter_ranges"][par])...) for par in fit_params]
    
    # get the number of parameters, starting pos, and bounding ranges
    # bounding ranges can be a dictionary in YAML
    nll = x->-fprob(x)
    @everywhere using BlackBoxOptim
    opt = bbsetup(nll; Method = :xnes, SearchRange = sranges, MaxFuncEvals = MaxFuncEvals, Workers = workers()) 
    res = bboptimize(opt)

    println(res)

else
    # instead, sample using MCMC
    using NPZ

    if fresh
        pos0 = npzread(config["pos0"])
    else
        pos0 = npzread(outdir * config["pos0"])
    end

    ndim, nwalkers = size(pos0)

    # Use the EnsembleSampler to do the optimization
    using DiskJockey.EnsembleSampler

    sampler = Sampler(nwalkers, ndim, fprob, parsed_args["test"])

    run_schedule(sampler, pos0, config["samples"], config["loops"], outdir)

    write_samples(sampler, outdir)

    if parsed_args["MPI"]
        MPI.stop_main_loop(manager)
    end
end
