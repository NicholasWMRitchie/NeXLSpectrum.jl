"""
    NeXLMatrixCorrection.quantify(
      ffr::FitResult;
      strip::AbstractVector{Element} = [],
      mc::Type{<:MatrixCorrection} = XPP,
      fl::Type{<:FluorescenceCorrection} = ReedFluorescence,
      kro::KRatioOptimizer = SimpleKRatioOptimizer(1.5),
    )::IterationResult

Facilitates converting `FilterFitResult` or `BasicFitResult` objects into estimates of composition by extracting
k-ratios from measured spectra and applying matrix correction algorithms.
"""
function NeXLMatrixCorrection.quantify(
    ffr::FitResult;
    strip::AbstractVector{Element} = Element[],
    mc::Type{<:MatrixCorrection} = XPP,
    fc::Type{<:FluorescenceCorrection} = ReedFluorescence,
    cc::Type{<:CoatingCorrection} = Coating,
    kro::KRatioOptimizer = SimpleKRatioOptimizer(1.5),
    unmeasured::UnmeasuredElementRule = NullUnmeasuredRule(),
    coating::Union{Nothing, Pair{CharXRay, <:Material}}=nothing
)::IterationResult
    iter = Iteration(mc, fc, cc, unmeasured = unmeasured)
    krs = optimizeks(kro, filter(kr -> !(element(kr) in strip), kratios(ffr)))
    return quantify(iter, ffr.label, krs, coating=coating)
end

"""
    NeXLMatrixCorrection.quantify(
        spec::Union{Spectrum,AbstractVector{<:Spectrum}},
        ffp::FilterFitPacket;
        kwargs...
    )::IterationResult

Failitates quantifying spectra.  First filter fits and then matrix corrects.
"""
function NeXLMatrixCorrection.quantify(
    spec::Spectrum,
    ffp::FilterFitPacket;
    kwargs...,
)::IterationResult
    return quantify(fit_spectrum(spec, ffp); kwargs...)
end
function NeXLMatrixCorrection.quantify(
    specs::AbstractVector{<:Spectrum},
    ffp::FilterFitPacket;
    kwargs...,
)::Vector{IterationResult}
    return map(spec->quantify(fit_spectrum(spec, ffp); kwargs...), specs)
end