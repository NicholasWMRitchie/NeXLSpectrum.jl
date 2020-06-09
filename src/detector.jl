using NeXLCore
using PeriodicTable
import Polynomials: Polynomial, fit, printpoly, roots

"""
    EnergyScale

An EnergyScale is a way of representing the energy axis associated with X-ray
data. The scale may be linear, polynomial or ??? to handle the various different
non-linearities that happen with EDS detectors plus we can also handle WDS
wavescans.

Implements:

    channel(eV::AbstractFloat, sc::EnergyScale)::Int
    energy(ch::Int, sc::EnergyScale)::Float64
"""
abstract type EnergyScale end

"""
    LinearEnergyScale

An EnergyScale implementation parameterized by channel width and offset.
"""
struct LinearEnergyScale <: EnergyScale
    offset::Float64
    width::Float64
"""
    LinearEnergyScale(off::Float64, width::Float64)

Construct a LinearEnergyScale from the zero offset (in eV) and channel width (in
eV/channel).
"""
    function LinearEnergyScale(off::Float64, width::Float64)
        @assert width>0.0 "Channel width must be greater than 0 in LinearEnergyScale."
        return new(off,width)
    end
end

Base.show(io::IO, es::LinearEnergyScale) =
    print(io, "E[ch] = ",es.offset," + ",es.width,"⋅ch")

Base.hash(les::LinearEnergyScale, h::UInt64) = hash(les.offset, hash(les.width,h))

"""
    channel(eV::AbstractFloat, sc::LinearEnergyScale)

    Returns the integer index of the channel for the specified energy X-ray (in
eV).
"""
channel(eV::AbstractFloat, sc::LinearEnergyScale)::Int =
    1 + floor(Int, (eV - sc.offset)/sc.width)


"""
    energy(ch::Integer, sc::LinearEnergyScale)

Returns the energy (in eV) for the low energy side of the bin representing the
ch-th channel.

Example:

    les = LinearEnergyScale(3.0, 10.1)
    energy(101,lsc) == 10.1*101 + 3.0
    energy(101,lsc) - energy(100,lsc) == 10.1
"""
NeXLCore.energy(ch::Int, sc::LinearEnergyScale)::Float64 =
    (ch-1)*sc.width+sc.offset


"""
    PolyEnergyScale

An energy scale based on a polynomial function of the channel index.
"""
struct PolyEnergyScale <: EnergyScale
    poly::Polynomial
    PolyEnergyScale(vec::AbstractVector{<:AbstractFloat}) = new(Polynomial(vec,:ch))
end

function Base.show(io::IO, pes::PolyEnergyScale)
    print(io, "E[ch] = ")
    printpoly(io, pes.poly)
end

"""
    channel(eV::AbstractFloat, sc::PolyEnergyScale)

    Returns the integer index of the channel for the specified energy X-ray (in
eV).
"""
function channel(eV::AbstractFloat, sc::PolyEnergyScale)::Int
    cp=Vector(coeffs(sc.poly))
    cp[1]-=eV
    rts = roots(Polynomial(cp))
    best = 100000
    for rt in rts
        if !(rt isa Complex)
            best = (rt>=-1000.0) && (rt<best) ? 1+floor(rt) : best
        end
    end
    return best
end


"""
    energy(ch::Integer, sc::PolyEnergyScale)

Returns the energy (in eV) for the low energy side of the bin representing the
ch-th channel.

Example:

    pes = PolyEnergyScale([ 3.0, 10.1, 0.001])
    energy(101,pes) ==  3.0 + 10.0*101 + 0.001*101^2
"""
NeXLCore.energy(ch::Integer, sc::PolyEnergyScale)::Float64 =
    sc.poly(convert(Float64,ch-1))


"""
    energyscale(es::EnergyScale, channels)

Computes the energy associated with a range of channel indexes and returns
it as an Array.
"""
energyscale(es::EnergyScale, channels) =
    collect(energy(ch, es) for ch in channels)

"""
    Resolution

An abstract type describing the channel dependence of the resolution of an EDS
detector.

Implements:

    resolution(eV::Float64, res::Resolution)::Float # Resolution at specified energy
    profile(energy::Float64, xrayE::Float64, res::Resolution) # Amplitude for a signal at the specified energy at the specified energy
    extent(xrayE::Float64, res::Resolution, ampl::Float64)::Tuple{2,Float} # The range of channels over which the signal exceeds ampl
"""
abstract type Resolution end
# Implements linewidth(eV::Float64, res::Resolution)::Float

struct MnKaResolution <: Resolution
    fwhmatmnka::Float64
end

Base.show(io::IO, mnka::MnKaResolution) = print(io, "$(mnka.fwhmatmnka) eV @ Mn Kα")

""""
    resolution(eV::Float64, res::MnKaResolution)

The FWHM at eV for the MnKaResolution model.  Uses Chuck Fiori's simple function relating the FWHM at eV to the FWHM at
another energy.
"""
resolution(eV::Float64, res::MnKaResolution) =
    sqrt((2.45 * (eV - 5898.7)) + (res.fwhmatmnka * res.fwhmatmnka))
"""
    gaussianwidth(fwhm::Float64)

Converts full-width half-max to Gaussian width.
"""
gaussianwidth(fwhm::Float64) =
    fwhm / 2.354820045030949382023138652918

""""
    profile(energy::Float64, xrayE::Float64, res::MnKaResolution)
Calculates a Gaussian profile for an X-ray of xrayE (eV) for a detector
with the specified resolution.  Maintains normalization to a sum of unity.
"""
function profile(energy::Float64, xrayE::Float64, res::MnKaResolution)
    σ = gaussianwidth(resolution(xrayE, res))
    return exp(-0.5*((energy-xrayE)/σ)^2)/(σ*sqrt(2.0π))
end

"""
    extent(xrayE::Float64, res::MnKaPlusICC, ampl::Float64)
Calculates the extent of the peak interval for an x-ray of the specified
energy.
"""
function extent(xrayE::Float64, res::MnKaResolution, ampl::Float64)
    w=gaussianwidth(resolution(xrayE, res))*sqrt(-2.0*log(ampl))
    return (xrayE-w, xrayE+w)
end

struct MnKaPlusICC <: Resolution
    fwhmatmnka::Float64
    icc::Float64
    iccmax::Float64
    MnKaPlusICC(fwhm::Float64, icc::Float64=70.0, iccmax::Float64=1500.0) = new(fwhm, icc, iccmax)
end

""""
    resolution(eV::Float64, res::MnKaPlusICC)

The FWHM at eV in the MnKaPlusICC model.  Uses Chuck Fiori's simple function relating the FWHM at eV to the FWHM at
another energy plus a term to account for incomplete charge collection.
"""
resolution(eV::Float64, res::MnKaPlusICC) =
    sqrt((2.45 * (eV - 5898.7)) + (res.fwhmatmnka * res.fwhmatmnka)) + max(0.0, res.icc*(1.0-max(0.0,eV)/res.iccmax))

""""
    profile(energy::Float64, xrayE::Float64, res::MnKaPlusICC)

Calculates a Gaussian profile for an X-ray of xrayE (eV) for a detector
with the specified resolution.
"""
function profile(energy::Float64, xrayE::Float64, res::MnKaPlusICC)
    σ = gaussianwidth(resolution(xrayE, res))
    return exp(-0.5*((energy-xrayE)/σ)^2)/(σ*sqrt(2.0π))
end
"""
    extent(xrayE::Float64, res::MnKaPlusICC, ampl::Float64)

Calculates the extent of the peak interval for an x-ray of the specified
energy.  This includes extra at the low-energy side to account for ICC.
"""
function extent(xrayE::Float64, res::MnKaPlusICC, ampl::Float64)
    w=gaussianwidth(resolution(xrayE, res))*sqrt(-2.0*log(ampl))
    icc=gaussianwidth(res.icc*(1.0-max(0.0,xrayE)/res.iccmax))
    return (xrayE-(w+max(0.0,icc)), xrayE+w)
end

"""
    extent(cxr::CharXRay, res::Resolution, ampl::Float64)::Tuple{2,Float64}

Computes the energy range encompassed by the specified x-ray
down to an intensity of ampl.  Relative line weights are taken into account.
"""
extent(cxr::CharXRay, res::Resolution, ampl::Float64) =
    extent(energy(cxr), res, min(0.999,ampl/weight(cxr)))

"""
    Detector

An abstract type defining the characteristics of an X-ray detector.

Implements:

    channelcount(det::Detector)::Int
    scale(det::Detector)::EnergyScale
    resolution(eV::Float64, det::Detector)::Float64 # FWHM at eV
    energy(ch::Int, det::Detector)::Float64
    channel(eV::Float64, det::Detector)::Int
    profile(energy::Float64, xrayE::Float64, det::Detector)
    lld(det::Detector)::Int
    visible(sf::SpectrumFeature, det::Detector)
"""
abstract type Detector end

"""
    extent(escape::EscapeArtifact, res::Resolution, ampl::Float64)::Tuple{2,Float64}

The extent of an escape artifact is determined by the resolution of the detector at the energy of the escape peak.
"""
extent(esc::EscapeArtifact, res::Resolution, ampl::Float64=0.01) =
    extent(energy(esc), res, min(0.999,ampl/weight(esc.xray)))

"""
    extent(escape::ComptonArtifact, res::Resolution, ampl::Float64)::Tuple{2,Float64}

The extent of a Compton artifact is determined by the resolution of the detector at the energy of the Compton peak.
"""
extent(ca::ComptonArtifact, res::Resolution, ampl::Float64=1.0e-4) =
    extent(energy(ca), res, min(0.999,ampl/weight(ca.xray)))

"""
    extent(sf::SpectrumFeature, det::Detector, ampl::Float64)::Tuple{Float64, Float64}

Computes the channel range encompassed by the specified set of x-ray transitions
down to an intensity of ampl.  Relative line weights are taken into account.
"""
extent(sf::SpectrumFeature, det::Detector, ampl::Float64)::Tuple{Float64, Float64} =
    extent(sf, det.resolution, ampl)
"""
    EDSDetector

Types extending EDSDetector must have member variables

    channelcount::Int # Number of channels
    scale::EnergyScale # Detector calibration funtion
    resolution::Resolution # Detector lineshape function
    lld::Int # low level discriminator
"""
abstract type EDSDetector <: Detector end

"""
    channelcount(det::EDSDetector)

Number of detector channels.
"""
channelcount(det::EDSDetector) =
    det.channelcount

Base.eachindex(det::EDSDetector) = Base.OneTo(det.channelcount)

"""
    scale(det::EDSDetector)

EnergyScale associated with this detector.
"""
scale(det::EDSDetector)::EnergyScale =
    det.scale

energyscale(det::EDSDetector) =
    energyscale(det.scale, eachindex(det))

"""
    lld(det::EDSDetector)

Low level detector in channels
"""
lld(det::EDSDetector) = det.lld

"""
    resolution(eV::Float64, det::EDSDetector)

Resolution (FWHM) of the detector in eV at the specified energy.
"""
resolution(eV::Float64, det::EDSDetector) =
    resolution(eV, det.resolution)


"""
    energy(ch::Int, det::EDSDetector)

Energy of the low-energy side of the ch-th detector bin.
"""
NeXLCore.energy(ch::Int, det::EDSDetector) =
    energy(ch, det.scale)

"""
    channel(eV::Float64, det::EDSDetector)

The channel index in which the specified energy X-ray belongs.
"""
channel(eV::Float64, det::EDSDetector) =
    channel(eV, det.scale)
channel(sf::SpectrumFeature, det::EDSDetector) =
    channel(energy(sf), det.scale)


""""
    profile(ch::Int, xrayE::Float64, det::EDSDetector)

Calculates the profile for an X-ray of xrayE (eV) for a detector
with the specified resolution.  Performs a crude integration to account for
the channel width.
"""
function profile(ch::Int, xrayE::Float64, det::EDSDetector)
    eh, el = energy(ch+1, det), energy(ch,det)
    return 0.5 * (profile(eh, xrayE, det.resolution) + profile(el, xrayE, det.resolution)) * (eh-el)
end
profile(nrg::Float64, xrayE::Float64, det::EDSDetector) =
    profile(channel(nrg, det), xrayE, det.resolution)


"""
    visible(cxrs::AbstractVector{<:SpectrumFeature}, det::Detector)

Returns the characteristic x-rays that are visible on the specified detector (ie. Between the LLD and the maximum
channel).
"""
visible(sfs::AbstractVector{<:SpectrumFeature}, det::Detector) =
    filter(sf->visible(sf,det), sfs)

"""
    extents(cxrs::AbstractVector{<:SpectrumFeature},det::Detector,ampl::Float64)::Vector{UnitRange{Int}}

Determine the contiguous ranges of channels over which the specified collection of X-rays will be measured on
the specified detector.  The ampl determines the extent of each peak.
"""
function extents( #
    cxrs::AbstractVector{T},
    det::Detector, #
    ampl::Float64
)::Vector{UnitRange{Int}} where T <: SpectrumFeature
    function ascontiguous(rois)
        join(roi1, roi2) = min(roi1.start, roi2.start):max(roi1.stop, roi2.stop)
        srois = sort(rois)
        res = [srois[1]]
        for roi in srois[2:end]
            if length(intersect(res[end], roi)) > 0
                res[end] = join(roi, res[end])
            else
                push!(res, roi)
            end
        end
        return res
    end
    inrange(x) = (x.start <= channelcount(det)) && (x.stop > lld(det))
    # Note: extent(cxr,...) takes line weight into account
    es=map(cxr->extent(cxr, det, ampl), filter(cxr->weight(cxr)>ampl, visible(cxrs, det)))
    return filter(inrange, ascontiguous(map(ee->channel(ee[1],det):channel(ee[2],det),es)))
end

extents(elm::Element, det::Detector, ampl::Float64)::Vector{UnitRange{Int}} =
    extents(visible(characteristic(elm,alltransitions),det),det,ampl)

"""
    function labeledextents(
        cxrs::AbstractVector{T},
        det::Detector,
        ampl::Float64
    )::Vector{Tuple{Vector{T},UnitRange{Int}}} where T <: SpectrumFeature

Creates a vector containing pairs containing a vector of T <: SpectrumFeature and an interval. The interval represents a
contiguous interval over which all the X-rays in the interval are sufficiently close in energy that they will
interfere with each other on the specified detector.
"""
function labeledextents(
    cxrs::AbstractVector{T},
    det::Detector,
    ampl::Float64
)::Vector{Tuple{Vector{T},UnitRange{Int}}} where T <: SpectrumFeature
    fcxrs = filter(cxr-> weight(cxr)>ampl, visible(cxrs, det))
    es = map(xr -> extent(xr, det, ampl), fcxrs) # CharXRay -> energy ranges
    le = collect(zip(fcxrs, map(ee -> channel(ee[1], det):channel(ee[2], det), es))) # Energy ranges to channel ranges
    sort!(le, lt = (x1, x2) -> isless(energy(x1[1]), energy(x2[1]))) # sort by x-ray energy
    res = Vector{Tuple{Vector{T},UnitRange{Int}}}()
    if length(le) > 0
        curX, curInt = [le[1][1]], le[1][2]
        for (cxr, interval) in le[2:end]
            if length(intersect(interval, curInt)) > 0 # Add to current extent
                curInt = min(interval.start, curInt.start):max(interval.stop, curInt.stop)
                push!(curX, cxr)
            else # create a new extent
                push!(res, (curX, curInt))
                curX = [cxr]
                curInt = interval
            end
        end
        push!(res, (curX, curInt))
    end
    return res
end

"""
    function escapeextents(
        cxrs::AbstractVector{T},
        det::Detector,
        ampl::Float64
    )::Vector{Tuple{Vector{T},UnitRange{Int}}} where T <: SpectrumFeature

Creates a vector containing pairs containing a vector of T <: SpectrumFeature and an interval. The interval represents a
contiguous interval over which all the X-rays in the interval are sufficiently close in energy that they will
interfere with each other on the specified detector.
"""
function escapeextents(
    cxrs::AbstractVector{T},
    det::Detector,
    ampl::Float64,
    maxE::Float64,
    escape::CharXRay = n"Si K-L3",
    minweight::Float64=0.5
)::Vector{Tuple{Vector{EscapeArtifact},UnitRange{Int}}} where T <: SpectrumFeature
    escs = map(tr -> EscapeArtifact(tr, escape), filter(c->exists(EscapeArtifact, c, escape), cxrs))
    escs = filter(esc->visible(esc, det), escs)
    es = map(esc -> extent(energy(esc), det.resolution, 0.01), escs) # EscapeFeature -> energy ranges
    le = collect(zip(escs, map(ee -> channel(ee[1], det):channel(ee[2], det), es))) # Energy ranges to channel ranges
    sort!(le, lt = (x1, x2) -> isless(energy(x1[1]), energy(x2[1]))) # sort by x-ray energy
    res = Vector{Tuple{Vector{EscapeArtifact},UnitRange{Int}}}()
    if length(le) > 0
        curX, curInt = [le[1][1]], le[1][2]
        for (cxr, interval) in le[2:end]
            if length(intersect(interval, curInt)) > 0 # Add to current extent
                curInt = min(interval.start, curInt.start):max(interval.stop, curInt.stop)
                push!(curX, cxr)
            else # create a new extent
                push!(res, (curX, curInt))
                curX = [cxr]
                curInt = interval
            end
        end
        push!(res, (curX, curInt))
    end
    return res
end

"""
    simpleEDS(chCount::Integer, width::Float64, offset::Float64, fwhmatmnka::Float64, lld::Int = channel(150.0 eV))

Construct simple model of an EDS detector.
"""
function simpleEDS(chCount::Integer, width::Float64, offset::Float64, fwhmatmnka::Float64, lld::Int=-1)
    lld = lld<1 ? round(Int,(150.0-offset)/width) : lld
    BasicEDS(chCount, LinearEnergyScale(offset,width), MnKaResolution(fwhmatmnka), lld)
end

"""
    simpleEDSwICC(chCount::Integer, width::Float64, offset::Float64, fwhmatmnka::Float64, lld::Int=channel(150.0 eV))

Construct simple model of an EDS detector with incomplete charge collection at
low X-ray energies.
"""
function simpleEDSwICC(chCount::Integer, width::Float64, offset::Float64, fwhmatmnka::Float64, lld::Int=-1)
    lld = lld<1 ? round(Int,(150.0-offset)/width) : lld
    BasicEDS(chCount, LinearEnergyScale(offset,width), MnKaPlusICC(fwhmatmnka, 70.0, 1200.0), max(1,lld))
end

struct BasicEDS <: EDSDetector
    channelcount::Int
    scale::EnergyScale
    resolution::Resolution
    lld::Int # low level discriminator
    minByShell::Dict{Shell,Element} # Dict( Shell(1)=>n"Be", Shell(2)=>n"Sc", Shell(3)=>n"Ba", Shell(4)=>n"Pu" )
    function BasicEDS(
        channelcount::Int,
        zero::Float64,
        gain::Float64,
        fwhm::Float64,
        lld::Int,
        minByShell::Dict{Shell,Element} = Dict{Shell,Element}(),
    )
        mbs = merge(Dict{Shell,Element}(
            KShell => n"Be",
            LShell => n"Sc",
            MShell => n"Ba",
            NShell => n"Pu",
        ), minByShell)
        return new(channelcount, LinearEnergyScale(zero, gain), MnKaResolution(fwhm), lld, mbs)
    end
    function BasicEDS(
        channelcount::Int,
        scale::EnergyScale,
        resolution::Resolution,
        lld::Int,
        minByShell::Dict{Shell,Element} = Dict{Shell,Element}(),
    )
        mbs = merge(Dict{Shell,Element}(
            KShell => n"Be",
            LShell => n"Sc",
            MShell => n"Ba",
            NShell => n"Pu",
        ), minByShell)
        return new(channelcount, scale, resolution, lld, mbs)
    end
end

"""
    visible(sf::SpectrumFeature, det::Detector)

Is `sf` visible on the specified Detector?
"""
function visible(esc::EscapeArtifact, det::BasicEDS)
    ass=AtomicSubShell(det.minByShell[KShell], n"K1")
    return (energy(esc)>=energy(ass)) &&
    (energy(esc)>energy(lld(det), det)) && #
    (energy(esc)<energy(det.channelcount+1, det))
end

visible(cxr::CharXRay, det::BasicEDS) =
    (element(cxr)>=det.minByShell[shell(cxr)]) && #
    (energy(cxr)>energy(lld(det), det)) && #
    (energy(cxr)<energy(det.channelcount+1, det))
