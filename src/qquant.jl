using Base.Threads

# Schamber's Vector quant algorithm - It foregoes the a weighted least squares fit for a simple
# homoskedastic fit.  In doing this it can precompute a fitting matrix which requires nothing
# more than a single matrix multiplication to perform the fit.  This makes this mechanism
# extremely quick. This makes it ideal for processing in real-time or HyperSpectrum objects.

struct VectorQuant
    # Vector(label[1], roi[2], charonly[3], sum(charonly)[4], scale[5])
    references::Vector{Tuple{ReferenceLabel,UnitRange,Vector{Float64},Float64,Float64}}
    vectors::Matrix{Float64}

    """
        VectorQuant(frefs::Vector{FilteredReference}, filt::TopHatFilter)

    Constructs a structure used to perform accelerated filtered spectrum fits based on the specified
    collection of `FilteredReference`(s), and a `TopHatFilter`.
    """
    function VectorQuant(frefs::Vector{FilteredReference}, filt::TopHatFilter)
        refs = [(fref.identifier, fref.roi, fref.charonly, sum(fref.charonly), fref.scale) for fref in frefs]
        x = zeros(Float64, (length(filt.filters), length(frefs)))
        for (c, fref) in enumerate(frefs)
            x[fref.ffroi, c] = fref.filtered
        end
        # ((ch × ne)T * (ch × ne))^(-1) * (ch × ne) * (ch × ch) => (ne × ch)
        xTxIxf = pinv(transpose(x) * x) * transpose(x) * NeXLSpectrum.filterdata(filt, 1:length(filt.filters))
        return new(refs, xTxIxf)
    end
end

NeXLCore.minproperties(::VectorQuant) = (:BeamEnergy, :TakeOffAngle, :)

Base.show(io::IO, vq::VectorQuant) =
    print(io, "VectorQuant[\n" * join(map(r -> "\t" * repr(r[1]), vq.references), ",\n") * "\n]")

function NeXLSpectrum.fit(vq::VectorQuant, spec::Spectrum, zero = x -> max(0.0, x))::FilterFitResult
    raw = counts(spec, Float64)
    krs = zero.(vq.vectors * raw)
    spsc = dose(spec)
    residual = copy(raw)
    for (i, (_, roi, co, _, _)) in enumerate(vq.references)
        residual[roi] -= krs[i] * co
    end
    peakback = Dict{ReferenceLabel,NTuple{2,Float64}}()
    dkrs = zeros(Float64, length(vq.references))
    for (i, (lbl, roi, _, ico, _)) in enumerate(vq.references)
        ii, bb = krs[i] * ico, sum(residual[roi])
        peakback[lbl] = (ii, bb)
        dkrs[i] = sqrt(max(0.0, ii + bb)) / ico
    end
    kratios = uvs(
        map(ref -> ref[1], vq.references), #
        map(i -> krs[i] / (vq.references[i][5] * spsc), eachindex(krs)), #
        map(i -> (dkrs[i] / (vq.references[i][5] * spsc))^2, eachindex(krs)),
    )
    return FilterFitResult(UnknownLabel(spec), kratios, 1:length(raw), raw, residual, peakback)
end

function NeXLSpectrum.fit(vq::VectorQuant, hs::HyperSpectrum, zero = x -> max(0.0, x))::Array{KRatios}
    krs = zeros(Float32, length(vq.references), size(hs)...)
    vecs = vq.vectors[:, 1:depth(hs)]
    scales = [ dose(hs)*vq.references[i][5] for i in eachindex(vq.references) ]
    # @threads seems to slow this (maybe cache misses??)
    for ci in CartesianIndices(hs)
        @avx krs[:, ci] = (vecs * hs.counts[:,ci])./scales
    end
    map!(zero, krs, krs)
    res = KRatios[]
    for i in filter(ii->vq.references[ii][1] isa CharXRayLabel, eachindex(vq.references))
        k, lbl = krs[i], vq.references[i][1]
        rprops = properties(spectrum(lbl))
        push!(res, KRatios(xrays(lbl), properties(hs), rprops, rprops[:Composition], krs[i,:,:]))
    end
    return res
end
