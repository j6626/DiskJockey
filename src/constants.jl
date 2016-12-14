#Physical constants

module constants

export M_sun, M_earth, AU, pc, G, kB, amu, c_ang, cc, c_kms, mu_gas, m_H, m_CO, m_12CO, m_13CO, m_C18O, number_densities, molnames, arcsec, deg, fftspace, MCO, lam0_12CO, lam0_13CO, lam0_C18O, lam0s, nyquist_factor, r_out_factor, Av_sigmaH, n_z_interpolator, X_H2, rho_gas_critical
export RADMC_SIZEAU_SHIFT
export DiskJockeyException, ModelException, ImageException
export DISKJOCKEY_VERSION

DISKJOCKEY_VERSION = v"0.1.3"

# Conversion from astronomical units to CGS units
M_sun = 1.99e33 # [g]
M_earth = 5.97219e27 # [g]
AU = 1.4959787066e13 # [cm]
pc = 3.0856776e18 # [cm]
G = 6.67259e-8 # [cm3 g-1 s-2]
kB = 1.380658e-16 # [erg K^-1] Boltzmann constant
c_ang = 2.99792458e18 # [A s^-1]
cc = 2.99792458e10 # [cm s^-1]
c_kms = 2.99792458e5 # [km s^-1]

# Conversion from degrees to radians
deg = pi/180. # [radians]

mu_gas = 2.37 # mean molecular weight of circumstellar gas
m_H = 1.6733e-24 # g mass of hydrogen atom

#Atomic
amu = 1.6605402e-24 # [g]

#CO
m_CO = 28.01 * amu #molecular weight of CO in g

m_12CO = 27.9949 * amu # [g]
m_13CO = 28.9983 * amu # [g]
m_C18O = 29.9992 * amu # [g]

atomic_massses = Dict([("12CO", m_12CO), ("13CO", m_13CO), ("C18O", m_C18O)])

# Using numbers from Charlie Qi
# Number ratios measured relative to all single H nuclei (not H2) [unitless]
f_12CO = 7.5e-5
X_12CO = 2 * f_12CO
X_13CO = 1/69. * X_12CO
X_C18O = 1/557. * X_12CO

# molecular hydrogen number ratio to gas [unitless]
# [n_H2/n_gas] = 0.8
X_H2 = 0.8

# To go from rho_gas to n_12CO
# n_12CO = rho_gas * X_H2 *

# Old number densities calculated as
# 12CO = 7.5e-5 / (mu_gas * amu)

# New number density calculated as
# 12CO = 0.8 * (2 * 7.5e-5)/ (mu_gas * amu)

# new/old = 1.6
# This means that the new total disk mass we use will be 1/1.6 times smaller than the old time.

# Use this to multiply against rho_gas to get n_12CO or n_13CO
number_densities = Dict{String, Float64}([("12CO", X_H2 * X_12CO/(mu_gas * amu)), ("13CO", X_H2 * X_13CO/(mu_gas * amu)), ("C18O", X_H2 * X_C18O/(mu_gas * amu))])

molnames = Dict{String, String}([("12CO", "co"), ("13CO", "13co"), ("C18O", "c18o")])

# Species can be "12CO", "13CO", etc.
# Transition can be "3-2", "2-1", etc.

# Key to this dictionary is then species * transition

# Rest frame wavelengths
lam0s = Dict{String, Float64}([("12CO2-1", cc/230.538e9 * 1e4 ),
            ("13CO2-1", cc/220.39868e9 * 1e4),
            ("13CO3-2", cc/330.58797e9 * 1e4),
            ("C18O2-1", cc/219.56036e9 * 1e4),
            ("12CO3-2", cc/345.79599e9 * 1e4)]) # microns


# Convert from Av to hydrogen *nuclei* column density for interstellar dust
# Av_sigmaH = 1.59e21 # [cm^-2] # "standard" number
Av_sigmaH = 1.0e20 # [cm^-2] # Charlie's number

# convert from arcseconds to radians
arcsec = pi / (180. * 3600) # [radians]  = 1/206265 radian/arcsec

# Used when determining the necessary number of pixels in an image, given distance. Anything below
# 2 is not Nyquist sampled. This is currently set to 2.2 to provide a degree of oversampling.
nyquist_factor = 2.2

# The bound at which to force the density to zero
# n_H2 = 100 [1/cm^3] average H2 number density in diffuse ISM
rho_gas_critical = (100./X_H2) * mu_gas * amu # [g/cm^3]

# The number of z points to use for the density interpolator
n_z_interpolator = 64
rho_gas_zero = 1e-50

# Fractional shift that exists between commanded size of image and actual size (actual size bigger)
# Therefore, use this to demand a size that is slightly smaller, so that the actual synthesized
# image comes out being the proper size.
RADMC_SIZEAU_SHIFT = 1.4233758746704833e-5

# Oftentimes it is necessary to get a symmetric coordinate array that spans N
# elements from -width to +width, but makes sure that the middle point lands
# on 0. The indices go from 0 to N -1.
# `linspace` returns  the end points inclusive, wheras we want to leave out the
# right endpoint, because we are sampling the function in a cyclic manner.
function fftspace(width::Real, N::Int)
    @assert(N % 2 == 0, "N must be even.")

    dx = width * 2. / N
    xx = Array(Float64, N)
    for i=1:N
        xx[i] = -width + (i - 1) * dx
    end
    return xx
end

# Convert result from MCMC to M_sun
function MCO(logCO::Float64)
    # Convert to Earth mass
    CO_earth = 10^logCO

    # Convert from Earth to M_sun
    CO_sun = CO_earth * M_earth/M_sun

    # Convert from 12CO to total gas mass using the mass ratio of 1e-4
    gas_mass = CO_sun / X_12CO

    logM_gas = log10(gas_mass)

    return logM_gas
end

# Abstract exception that serves as a catch-all for any error generated by the DiskJockey package.
abstract DiskJockeyException <: Exception

# Define the various types of Errors that we can Raise
type ModelException <: DiskJockeyException
    msg::String
end

type ImageException <: DiskJockeyException
    msg::String
end

end # Module
