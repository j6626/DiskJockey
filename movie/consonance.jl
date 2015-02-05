# All necessary variables (ie, setup vars) should be defined here, to be
# shared between any disparate processes
push!(LOAD_PATH, "/home/ian/Grad/Research/Disks/JudithExcalibur/")
push!(LOAD_PATH, "/n/home07/iczekala/JudithExcalibur/")
push!(LOAD_PATH, "/pool/scout0/JudithExcalibur/")

module consonance

export pars, nframes, nframes_per_proc, nchan, vels, lams, vmax, homedir, scratchdir, outdir

using constants
using model

# For odyssey use
# homedir = "/n/home07/iczekala/JudithExcalibur/"
# scratchdir = "/scratch/"
# outdir = "/n/home07/iczekala/JudithExcalibur/output/movie/" #Where the images.out and images.png are stored

# For local use
homedir = "/home/ian/Grad/Research/Disks/JudithExcalibur/"
scratchdir = "/home/ian/Grad/Research/Disks/JudithExcalibur/movie/"
outdir = "/home/ian/Grad/Research/Disks/JudithExcalibur/movie/"

# For cfa0 use
# homedir = "/pool/scout0/JudithExcalibur/"
# scratchdir = "/pool/cf/iczekala/scratch/"
# outdir = "/pool/scout0/JudithExcalibur/output/movie/"

# How many frames per process?
nframes_per_proc = 4

global const nchan = 7
global const vels = linspace(-1.5, 1.5, nchan) # [km/s]
# CO 2-1 rest frame
lam0 = cc/230.538e9 * 1e4 # [microns]
# convert velocities to wavelengths
lams = lam0 * (vels/c_kms + 1)

M_star = 1.75 # [M_sun] stellar mass
r_c = 45. # [AU] characteristic radius
T_10 = 115. # [K] temperature at 10 AU
q = 0.63 # temperature gradient exponent
gamma = 1.0 # surface density gradient
logM_CO = 0.2 # [M_earth] disk mass of CO
ksi = 0.14 # [km/s] microturbulence
dpc = 73. # [pc] distance
incl = 45. # [degrees] inclination
PA = 0. # [degrees] position angle
vel = 0.0 # [km/s]
mu_RA = 0.0 # [arcsec] centroid location
mu_DEC = 0.0 # [arcsec]

# Given a starting parameter, vary it by steps dp to the low bound, then high
# bound, then back to where we started
function smooth_vary(start, low, high, dp)
    ndown1 = iround((start - low)/dp) + 1
    nup = iround((high - low)/dp) + 1
    ndown2 = iround((high - start)/dp) + 1

    return [linspace(start, low, ndown1)' linspace(low, high, nup)' linspace(high, start, ndown2)']
end

# Create a master parameter list
# First, adjust in radius
radiuses = smooth_vary(r_c, 25., 65., 0.5)
nradiuses = length(radiuses)

# then, adjust in inclination
incls = smooth_vary(incl, 0., 90., 1.)
nincls = length(incls)

# then, adjust in mass
masses = smooth_vary(M_star, 1.0, 2.5, 0.02)
nmasses = length(masses)

nframes = nradiuses + nincls + nmasses

# Now create a giant array of Parameters objects
pars = Array(Parameters, nframes)

for i=1:nframes
    if i <= nradiuses
        pars[i] = Parameters(M_star, radiuses[i], T_10, q, gamma, 10^logM_CO, ksi, dpc, incl, PA, vel, mu_RA, mu_DEC)
    elseif i <= (nincls + nradiuses)
        pars[i] = Parameters(M_star, r_c, T_10, q, gamma, 10^logM_CO, ksi, dpc, incls[i - nradiuses], PA, vel, mu_RA, mu_DEC)
    else
        pars[i] = Parameters(masses[i - (nradiuses + nincls)], r_c, T_10, q, gamma, 10^logM_CO, ksi, dpc, incl, PA, vel, mu_RA, mu_DEC)
    end
end

println("There are ", nframes, " frames to be generated.")
# println("Inclinations ", incls)
# println("Masses ", masses)
# println("Radiuses ", radiuses)

# Return a normalized instance that is symmetric about 0
# function scale(data)
#     s = maximum(abs(data))
#     return norm = plt.Normalize(vmin=-s, vmax=s, clip=false)
# end

# used as arg to imshow like: norm = scale(real(vis_analytic)))
vmax = 11.482251454475813

end # module
