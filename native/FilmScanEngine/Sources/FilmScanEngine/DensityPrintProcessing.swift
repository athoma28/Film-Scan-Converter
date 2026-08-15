import Dispatch
import Foundation

/// Per-frame density-print uniforms shared by the CPU inverter and the GPU kernel.
public struct DensityPrintAnalysis: Equatable, Sendable {
  public var unmixBlue: BGRChannelValues
  public var unmixGreen: BGRChannelValues
  public var unmixRed: BGRChannelValues
  public var floors: BGRChannelValues
  public var ceils: BGRChannelValues
  public var slopes: BGRChannelValues
  public var pivots: BGRChannelValues
  public var curvatures: BGRChannelValues
  public var paperDMin: BGRChannelValues
  public var paperDMax: Double
  public var paperMidtoneGamma: Double
  public var paperGammaWidth: Double
  public var toeSharpnessBase: Double
  public var shoulderSharpnessBase: Double
  public var toeHeight: Double
  public var shoulderHeight: Double
  public var dyeMixBlue: BGRChannelValues
  public var dyeMixGreen: BGRChannelValues
  public var dyeMixRed: BGRChannelValues
  public var referenceLinear: Double

  public init(
    unmixBlue: BGRChannelValues,
    unmixGreen: BGRChannelValues,
    unmixRed: BGRChannelValues,
    floors: BGRChannelValues,
    ceils: BGRChannelValues,
    slopes: BGRChannelValues,
    pivots: BGRChannelValues,
    curvatures: BGRChannelValues = BGRChannelValues(blue: 0, green: 0, red: 0),
    paperDMin: BGRChannelValues = BGRChannelValues(blue: 0, green: 0, red: 0),
    paperDMax: Double = DensityPrintProcessing.dMax,
    paperMidtoneGamma: Double = DensityPrintProcessing.paperMidtoneGamma,
    paperGammaWidth: Double = DensityPrintProcessing.paperGammaWidth,
    toeSharpnessBase: Double = DensityPrintProcessing.toeSharpnessBase,
    shoulderSharpnessBase: Double = DensityPrintProcessing.shoulderSharpnessBase,
    toeHeight: Double = DensityPrintProcessing.toeHeight,
    shoulderHeight: Double = DensityPrintProcessing.shoulderHeight,
    dyeMixBlue: BGRChannelValues = BGRChannelValues(blue: 1, green: 0, red: 0),
    dyeMixGreen: BGRChannelValues = BGRChannelValues(blue: 0, green: 1, red: 0),
    dyeMixRed: BGRChannelValues = BGRChannelValues(blue: 0, green: 0, red: 1),
    referenceLinear: Double = DensityPrintProcessing.referenceLinearValue()
  ) {
    self.unmixBlue = unmixBlue
    self.unmixGreen = unmixGreen
    self.unmixRed = unmixRed
    self.floors = floors
    self.ceils = ceils
    self.slopes = slopes
    self.pivots = pivots
    self.curvatures = curvatures
    self.paperDMin = paperDMin
    self.paperDMax = paperDMax
    self.paperMidtoneGamma = paperMidtoneGamma
    self.paperGammaWidth = paperGammaWidth
    self.toeSharpnessBase = toeSharpnessBase
    self.shoulderSharpnessBase = shoulderSharpnessBase
    self.toeHeight = toeHeight
    self.shoulderHeight = shoulderHeight
    self.dyeMixBlue = dyeMixBlue
    self.dyeMixGreen = dyeMixGreen
    self.dyeMixRed = dyeMixRed
    self.referenceLinear = referenceLinear
  }
}

/// Density-domain colour-negative inversion adapted from NegPy's print path
/// (GPL-3.0): log-density dye unmix, independent per-channel bounds, and an
/// asymmetric H&D paper curve. Camera-scan uint16 is linearized with the sRGB
/// TRC before the log, matching this project's LibRaw camera-scan gamma.
public enum DensityPrintProcessing {
  public static let epsilon = 1e-6
  public static let analysisLongEdge = 256
  /// Same rebate inset as calibrated colour/B&W inversion so camera scans
  /// with sprocket holes do not set the density floor to the film holder.
  public static let analyzeBorderPercent = 20.0
  public static let lumaR = 0.2126
  public static let lumaG = 0.7152
  public static let lumaB = 0.0722
  public static let dMax = 2.3
  public static let dMin = 0.0
  public static let assumedAnchor = 0.46
  public static let anchorTargetDensity = 0.75
  public static let anchorMeterStrength = 0.2
  public static let anchorMeterBand = 0.12
  public static let gradeContrastScale = 2.9
  public static let slopeMin = 2.0
  public static let slopeMax = 10.0
  public static let isoRMin = 50.0
  public static let isoRMax = 180.0
  public static let autoGradeTarget = 0.6
  public static let autoGradeStrength = 0.5
  public static let autoGradeNominalRatio = 2.0
  public static let paperMidtoneGamma = 0.15
  public static let paperGammaWidth = 0.6
  public static let toeSharpnessBase = 4.0
  public static let shoulderSharpnessBase = 3.0
  public static let toeShoulderWidthRef = 2.5
  public static let toeShoulderStrength = 0.85
  public static let toeHeight = 0.90
  public static let shoulderHeight = 0.35
  public static let toeGradeStrength = 0.15 * 0.35 / 0.90
  public static let shoulderGradeStrength = 0.12
  public static let baseLumaClip = 0.01
  public static let baseColorClip = 1.0
  public static let texturalRangeClip = 10.0
  public static let castRemovalMaxOffset = 0.1
  public static let midtoneCastMaxOffset = 0.2
  public static let neutralAxisCurvMaxRatio = 0.45
  public static let shadowNeutralPercentile = 98.0
  public static let densityMultiplier = 0.2
  public static let colorBoundsBandWidth = 4.0
  public static let neutralAxisChromaQuantile = 0.30
  public static let neutralAxisChromaCap = 0.29
  public static let neutralAxisFirstPassCap = 0.55
  public static let neutralAxisMinPixels = 64
  public static let neutralAxisConfidenceN0 = 256.0
  public static let neutralAxisAgreementDeadzone = 0.10
  public static let neutralAxisAgreementScale = 0.20
  public static let highlightLumaBand = (0.10, 0.30)
  public static let midtoneLumaBand = (0.40, 0.60)
  public static let shadowLumaBand = (0.72, 0.92)
  static let parallelPixelThreshold = 1_000_000

  public static func resolvedProfile(from params: FilmNegativeParams) -> NegativeDensityProfile {
    NegativeDensityProfileCatalog.profile(id: params.densityProfileID)
      .withUnmix(
        flatRGB: params.densityUnmixRGB,
        strength: params.densityUnmixStrength >= 0 ? params.densityUnmixStrength : nil
      )
  }

  public static func resolvedPaper(from params: FilmNegativeParams) -> DensityPaperProfile {
    DensityPaperProfileCatalog.profile(id: params.densityPaperID)
  }

  public static func analyze(
    image: UInt16Image,
    profile: NegativeDensityProfile,
    paper: DensityPaperProfile = DensityPaperProfileCatalog.neutral,
    borderPercent: Double = analyzeBorderPercent
  ) -> DensityPrintAnalysis {
    precondition(image.channels == 3, "Density print analysis requires BGR input")
    let unmix = profile.appliedUnmixBGR()
    let dyeMix = paper.appliedDyeMixBGR()
    let paperDMin = paper.paperDMinBGR
    let samples = sampledLogPixels(
      image: image,
      unmixBlue: unmix.0,
      unmixGreen: unmix.1,
      unmixRed: unmix.2,
      borderPercent: borderPercent
    )
    let bounds = logBounds(from: samples)
    let lumRange = luminanceRange(bounds)
    let textural = texturalRange(samples)
    let gradeRange = effectiveGradeRange(
      autoGrade: profile.autoGrade,
      floorCeilRange: lumRange,
      texturalRange: textural
    )
    let baseSlope = gradeToSlope(grade: profile.printGrade, densityRange: gradeRange)
    let vStar = referenceLinearValue(
      dMin: paper.dMin,
      dMax: paper.dMax,
      toeSharpness: paper.toeSharpnessBase,
      shoulderSharpness: paper.shoulderSharpnessBase
    )
    let anchor = profile.autoDensity ? meteredAnchor(samples, bounds: bounds) : assumedAnchor
    let gamma = paper.channelGammaBGR
    func clampedSlope(_ multiplier: Double) -> Double {
      min(max(baseSlope * multiplier, slopeMin), slopeMax)
    }
    var slopes = BGRChannelValues(
      blue: clampedSlope(gamma.blue),
      green: clampedSlope(gamma.green),
      red: clampedSlope(gamma.red)
    )
    func pivot(for slopeValue: Double) -> Double {
      anchor - vStar / slopeValue
    }
    var pivots = BGRChannelValues(
      blue: pivot(for: slopes.blue),
      green: pivot(for: slopes.green),
      red: pivot(for: slopes.red)
    )
    var curvatures = BGRChannelValues(blue: 0, green: 0, red: 0)
    if profile.castRemovalStrength > 0 {
      let refs = shadowRefs(samples)
      let axis = measureNeutralAxis(samples, bounds: bounds)
      let applied = applyCastRemoval(
        baseSlope: baseSlope,
        bounds: bounds,
        shadowRefs: refs,
        neutralAxis: axis,
        strength: profile.castRemovalStrength,
        anchor: anchor,
        channelGamma: gamma,
        referenceLinear: vStar
      )
      slopes = applied.slopes
      pivots = applied.pivots
      curvatures = applied.curvatures
    }
    return DensityPrintAnalysis(
      unmixBlue: unmix.0,
      unmixGreen: unmix.1,
      unmixRed: unmix.2,
      floors: bounds.floors,
      ceils: bounds.ceils,
      slopes: slopes,
      pivots: pivots,
      curvatures: curvatures,
      paperDMin: paperDMin,
      paperDMax: paper.dMax,
      paperMidtoneGamma: paper.paperMidtoneGamma,
      paperGammaWidth: paper.paperGammaWidth,
      toeSharpnessBase: paper.toeSharpnessBase,
      shoulderSharpnessBase: paper.shoulderSharpnessBase,
      toeHeight: paper.toeHeight,
      shoulderHeight: paper.shoulderHeight,
      dyeMixBlue: dyeMix.0,
      dyeMixGreen: dyeMix.1,
      dyeMixRed: dyeMix.2,
      referenceLinear: vStar
    )
  }

  public static func apply(
    image: UInt16Image,
    params: FilmNegativeParams
  ) -> UInt16Image {
    apply(
      image: image,
      analysis: analyze(
        image: image,
        profile: resolvedProfile(from: params),
        paper: resolvedPaper(from: params)
      )
    )
  }

  public static func apply(
    image: UInt16Image,
    analysis: DensityPrintAnalysis
  ) -> UInt16Image {
    precondition(image.channels == 3, "Density print inversion requires BGR input")
    let pixelCount = image.width * image.height
    var output = [UInt16](repeating: 0, count: image.pixels.count)
    let workerCount = min(8, ProcessInfo.processInfo.activeProcessorCount)

    @Sendable func processPixel(_ pixelIndex: Int, output: UnsafeMutablePointer<UInt16>) {
      let base = pixelIndex * 3
      let rendered = renderPixel(
        blue: image.pixels[base],
        green: image.pixels[base + 1],
        red: image.pixels[base + 2],
        analysis: analysis
      )
      output[base] = rendered.blue
      output[base + 1] = rendered.green
      output[base + 2] = rendered.red
    }

    output.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      if pixelCount >= parallelPixelThreshold, workerCount > 1 {
        let sendableBuffer = SendableMutableBuffer(baseAddress)
        let pixelsPerWorker = (pixelCount + workerCount - 1) / workerCount
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
          let start = worker * pixelsPerWorker
          let end = min(start + pixelsPerWorker, pixelCount)
          guard start < end else { return }
          for pixelIndex in start..<end {
            processPixel(pixelIndex, output: sendableBuffer.baseAddress)
          }
        }
      } else {
        for pixelIndex in 0..<pixelCount {
          processPixel(pixelIndex, output: baseAddress)
        }
      }
    }
    return UInt16Image(width: image.width, height: image.height, channels: 3, pixels: output)
  }

  public static func renderPixel(
    blue: UInt16,
    green: UInt16,
    red: UInt16,
    analysis: DensityPrintAnalysis
  ) -> (blue: UInt16, green: UInt16, red: UInt16) {
    let linearB = max(FilmNegativeProcessing.sRGBToLinear(Double(blue) / 65_535.0), epsilon)
    let linearG = max(FilmNegativeProcessing.sRGBToLinear(Double(green) / 65_535.0), epsilon)
    let linearR = max(FilmNegativeProcessing.sRGBToLinear(Double(red) / 65_535.0), epsilon)
    let logB = log10(linearB)
    let logG = log10(linearG)
    let logR = log10(linearR)
    let unmixedB =
      analysis.unmixBlue.blue * logB + analysis.unmixBlue.green * logG
      + analysis.unmixBlue.red * logR
    let unmixedG =
      analysis.unmixGreen.blue * logB + analysis.unmixGreen.green * logG
      + analysis.unmixGreen.red * logR
    let unmixedR =
      analysis.unmixRed.blue * logB + analysis.unmixRed.green * logG
      + analysis.unmixRed.red * logR
    let normB = normalizeLog(unmixedB, floor: analysis.floors.blue, ceil: analysis.ceils.blue)
    let normG = normalizeLog(unmixedG, floor: analysis.floors.green, ceil: analysis.ceils.green)
    let normR = normalizeLog(unmixedR, floor: analysis.floors.red, ceil: analysis.ceils.red)
    let densityB = printDensity(
      normB,
      slope: analysis.slopes.blue,
      pivot: analysis.pivots.blue,
      curvature: analysis.curvatures.blue,
      dMin: analysis.paperDMin.blue,
      dMax: analysis.paperDMax,
      midtoneGamma: analysis.paperMidtoneGamma,
      gammaWidth: analysis.paperGammaWidth,
      toeSharpness: analysis.toeSharpnessBase,
      shoulderSharpness: analysis.shoulderSharpnessBase,
      toeHeight: analysis.toeHeight,
      shoulderHeight: analysis.shoulderHeight,
      referenceLinear: analysis.referenceLinear
    )
    let densityG = printDensity(
      normG,
      slope: analysis.slopes.green,
      pivot: analysis.pivots.green,
      curvature: analysis.curvatures.green,
      dMin: analysis.paperDMin.green,
      dMax: analysis.paperDMax,
      midtoneGamma: analysis.paperMidtoneGamma,
      gammaWidth: analysis.paperGammaWidth,
      toeSharpness: analysis.toeSharpnessBase,
      shoulderSharpness: analysis.shoulderSharpnessBase,
      toeHeight: analysis.toeHeight,
      shoulderHeight: analysis.shoulderHeight,
      referenceLinear: analysis.referenceLinear
    )
    let densityR = printDensity(
      normR,
      slope: analysis.slopes.red,
      pivot: analysis.pivots.red,
      curvature: analysis.curvatures.red,
      dMin: analysis.paperDMin.red,
      dMax: analysis.paperDMax,
      midtoneGamma: analysis.paperMidtoneGamma,
      gammaWidth: analysis.paperGammaWidth,
      toeSharpness: analysis.toeSharpnessBase,
      shoulderSharpness: analysis.shoulderSharpnessBase,
      toeHeight: analysis.toeHeight,
      shoulderHeight: analysis.shoulderHeight,
      referenceLinear: analysis.referenceLinear
    )
    let excessB = densityB - analysis.paperDMin.blue
    let excessG = densityG - analysis.paperDMin.green
    let excessR = densityR - analysis.paperDMin.red
    let mixedB =
      analysis.paperDMin.blue + analysis.dyeMixBlue.blue * excessB
      + analysis.dyeMixBlue.green * excessG + analysis.dyeMixBlue.red * excessR
    let mixedG =
      analysis.paperDMin.green + analysis.dyeMixGreen.blue * excessB
      + analysis.dyeMixGreen.green * excessG + analysis.dyeMixGreen.red * excessR
    let mixedR =
      analysis.paperDMin.red + analysis.dyeMixRed.blue * excessB
      + analysis.dyeMixRed.green * excessG + analysis.dyeMixRed.red * excessR
    return (
      encodeReflectance(mixedB, paperDMax: analysis.paperDMax),
      encodeReflectance(mixedG, paperDMax: analysis.paperDMax),
      encodeReflectance(mixedR, paperDMax: analysis.paperDMax)
    )
  }

  public static func printDensity(_ x: Double, slope: Double, pivot: Double) -> Double {
    printDensity(
      x,
      slope: slope,
      pivot: pivot,
      curvature: 0,
      dMin: dMin,
      dMax: dMax,
      midtoneGamma: paperMidtoneGamma,
      gammaWidth: paperGammaWidth,
      toeSharpness: toeSharpnessBase,
      shoulderSharpness: shoulderSharpnessBase,
      toeHeight: toeHeight,
      shoulderHeight: shoulderHeight,
      referenceLinear: referenceLinearValue()
    )
  }

  public static func printDensity(
    _ x: Double,
    slope: Double,
    pivot: Double,
    curvature: Double,
    dMin: Double,
    dMax: Double,
    midtoneGamma: Double,
    gammaWidth: Double,
    toeSharpness: Double,
    shoulderSharpness: Double,
    toeHeight: Double,
    shoulderHeight: Double,
    referenceLinear: Double
  ) -> Double {
    let (toe, shoulder) = gradeCoupledShape(slope: slope)
    let ts = toeShoulderStrength
    let width = toeShoulderWidthRef
    let aHL = shoulderSharpness * width / max(width, 1e-6)
    let aSHBase = toeSharpness * width / max(width, 1e-6)
    let dMinEff = max(0, dMin + shoulder * ts * shoulderHeight)
    let toeEff = toe * ts
    let dMaxEff: Double
    let aSH: Double
    if toeEff >= 0 {
      dMaxEff = dMax - toeEff * toeHeight
      aSH = aSHBase
    } else {
      dMaxEff = dMax
      aSH = aSHBase * (1 - toeEff * 4)
    }
    let dMaxBound = max(dMaxEff, dMinEff + 0.1)
    var v = slope * (x - pivot) + curvature * x * x
    v +=
      midtoneGamma * gammaWidth
      * tanh((v - referenceLinear) / gammaWidth)
    let v1 = dMinEff + softplus(aHL * (v - dMinEff)) / aHL
    return dMaxBound - softplus(aSH * (dMaxBound - v1)) / aSH
  }

  public static func encodeReflectance(
    _ density: Double,
    paperDMax: Double = dMax
  ) -> UInt16 {
    var transmittance = pow(10, -density)
    let black = pow(10, -paperDMax)
    transmittance = (transmittance - black) / (1 - black)
    let encoded = FilmNegativeProcessing.linearToSRGB(min(max(transmittance, 0), 1))
    return UInt16(min(max(encoded * 65_535.0, 0), 65_535.0).rounded())
  }

  public static func referenceLinearValue(
    dMin: Double = dMin,
    dMax: Double = dMax,
    toeSharpness: Double = toeSharpnessBase,
    shoulderSharpness: Double = shoulderSharpnessBase
  ) -> Double {
    let target = anchorTargetDensity
    let aHL = shoulderSharpness
    let aSH = toeSharpness
    let v1 = dMax - inverseSoftplus(aSH * (dMax - target)) / aSH
    return dMin + inverseSoftplus(aHL * (v1 - dMin)) / aHL
  }

  public static func gradeToSlope(grade: Double, densityRange: Double) -> Double {
    let exposureRange = min(max(grade, isoRMin), isoRMax) / 100
    let range = min(max(abs(densityRange), 0.3), 3.5)
    return min(max(gradeContrastScale * range / exposureRange, slopeMin), slopeMax)
  }

  public static func gradeCoupledShape(slope: Double) -> (toe: Double, shoulder: Double) {
    let slopeNorm = min(max((slope - slopeMin) / (slopeMax - slopeMin), 0), 1)
    return (toeGradeStrength * slopeNorm, shoulderGradeStrength * slopeNorm)
  }

  static func normalizeLog(_ value: Double, floor: Double, ceil: Double) -> Double {
    var delta = ceil - floor
    if abs(delta) < epsilon {
      delta = delta >= 0 ? epsilon : -epsilon
    }
    return (value - floor) / delta
  }

  static func softplus(_ x: Double) -> Double {
    if x > 20 { return x }
    if x < -20 { return exp(x) }
    return log(1 + exp(x))
  }

  static func inverseSoftplus(_ y: Double) -> Double {
    if y > 20 { return y }
    return log(max(exp(y) - 1, epsilon))
  }

  static func defaultGradeRange() -> Double {
    autoGradeTarget * autoGradeNominalRatio
  }

  static func effectiveGradeRange(
    autoGrade: Bool,
    floorCeilRange: Double,
    texturalRange: Double
  ) -> Double {
    guard autoGrade else { return floorCeilRange }
    if texturalRange < epsilon {
      return 3.5
    }
    let ratio = abs(floorCeilRange) / texturalRange
    return autoGradeTarget * (autoGradeNominalRatio + autoGradeStrength * (ratio - autoGradeNominalRatio))
  }

  static func luminanceRange(_ bounds: (floors: BGRChannelValues, ceils: BGRChannelValues)) -> Double
  {
    lumaB * abs(bounds.ceils.blue - bounds.floors.blue)
      + lumaG * abs(bounds.ceils.green - bounds.floors.green)
      + lumaR * abs(bounds.ceils.red - bounds.floors.red)
  }

  static func logBounds(
    from samples: [(blue: Double, green: Double, red: Double)]
  ) -> (floors: BGRChannelValues, ceils: BGRChannelValues) {
    let luma = percentileBounds(samples, clip: baseLumaClip)
    var color = percentileBounds(samples, clip: baseColorClip)
    if let gated = samePixelColorFloors(
      samples,
      lumaFloors: luma.floors,
      lumaCeils: luma.ceils,
      thinEnd: color.ceils,
      colorClip: baseColorClip
    ) {
      color.floors = gated
    }
    let meanLF = (luma.floors.blue + luma.floors.green + luma.floors.red) / 3
    let meanLC = (luma.ceils.blue + luma.ceils.green + luma.ceils.red) / 3
    let colorFloors = [color.floors.blue, color.floors.green, color.floors.red].sorted()
    let colorCeils = [color.ceils.blue, color.ceils.green, color.ceils.red].sorted()
    let meanCF = colorFloors[1]
    let meanCC = colorCeils[1]
    return (
      BGRChannelValues(
        blue: meanLF + (color.floors.blue - meanCF),
        green: meanLF + (color.floors.green - meanCF),
        red: meanLF + (color.floors.red - meanCF)
      ),
      BGRChannelValues(
        blue: meanLC + (color.ceils.blue - meanCC),
        green: meanLC + (color.ceils.green - meanCC),
        red: meanLC + (color.ceils.red - meanCC)
      )
    )
  }

  static func percentileBounds(
    _ samples: [(blue: Double, green: Double, red: Double)],
    clip: Double
  ) -> (floors: BGRChannelValues, ceils: BGRChannelValues) {
    let clipped = min(max(clip, 0.00001), 50)
    return (
      BGRChannelValues(
        blue: percentile(samples.map(\.blue), clipped),
        green: percentile(samples.map(\.green), clipped),
        red: percentile(samples.map(\.red), clipped)
      ),
      BGRChannelValues(
        blue: percentile(samples.map(\.blue), 100 - clipped),
        green: percentile(samples.map(\.green), 100 - clipped),
        red: percentile(samples.map(\.red), 100 - clipped)
      )
    )
  }

  static func texturalRange(_ samples: [(blue: Double, green: Double, red: Double)]) -> Double {
    let luma = samples.map { lumaB * $0.blue + lumaG * $0.green + lumaR * $0.red }
    return abs(
      percentile(luma, 100 - texturalRangeClip) - percentile(luma, texturalRangeClip))
  }

  static func meteredAnchor(
    _ samples: [(blue: Double, green: Double, red: Double)],
    bounds: (floors: BGRChannelValues, ceils: BGRChannelValues)
  ) -> Double {
    let luma = samples.map { sample in
      lumaB * normalizeLog(sample.blue, floor: bounds.floors.blue, ceil: bounds.ceils.blue)
        + lumaG
        * normalizeLog(sample.green, floor: bounds.floors.green, ceil: bounds.ceils.green)
        + lumaR * normalizeLog(sample.red, floor: bounds.floors.red, ceil: bounds.ceils.red)
    }
    let measured = percentile(luma, 50)
    let pulled = assumedAnchor + anchorMeterStrength * (measured - assumedAnchor)
    return min(max(pulled, assumedAnchor - anchorMeterBand), assumedAnchor + anchorMeterBand)
  }

  static func shadowRefs(
    _ samples: [(blue: Double, green: Double, red: Double)]
  ) -> BGRChannelValues {
    BGRChannelValues(
      blue: percentile(samples.map(\.blue), shadowNeutralPercentile),
      green: percentile(samples.map(\.green), shadowNeutralPercentile),
      red: percentile(samples.map(\.red), shadowNeutralPercentile)
    )
  }

  static func applyCastRemoval(
    baseSlope: Double,
    bounds: (floors: BGRChannelValues, ceils: BGRChannelValues),
    shadowRefs: BGRChannelValues,
    neutralAxis: NeutralAxisMeasurement?,
    strength: Double,
    anchor: Double,
    channelGamma: BGRChannelValues,
    referenceLinear: Double
  ) -> (slopes: BGRChannelValues, pivots: BGRChannelValues, curvatures: BGRChannelValues) {
    let appliedStrength: Double
    if let axis = neutralAxis {
      appliedStrength = axis.confidence * strength
    } else {
      appliedStrength = strength
    }
    if appliedStrength > 0, let axis = neutralAxis {
      return quadraticCastRemoval(
        baseSlope: baseSlope,
        axis: axis,
        strength: appliedStrength,
        channelGamma: channelGamma,
        referenceLinear: referenceLinear,
        bounds: bounds,
        anchor: anchor
      )
    }
    func normalized(_ value: Double, floor: Double, ceil: Double) -> Double {
      normalizeLog(value, floor: floor, ceil: ceil)
    }
    let refs = BGRChannelValues(
      blue: normalized(shadowRefs.blue, floor: bounds.floors.blue, ceil: bounds.ceils.blue),
      green: normalized(shadowRefs.green, floor: bounds.floors.green, ceil: bounds.ceils.green),
      red: normalized(shadowRefs.red, floor: bounds.floors.red, ceil: bounds.ceils.red)
    )
    let rGreen = refs.green
    let numer = anchor - rGreen
    func channelSlope(_ ref: Double, gamma: Double) -> Double {
      let cast = min(max(appliedStrength * (rGreen - ref), -castRemovalMaxOffset), castRemovalMaxOffset)
      let denom = anchor - (rGreen - cast)
      let tilted: Double
      if abs(denom) < epsilon {
        tilted = baseSlope
      } else {
        tilted = baseSlope * numer / denom
      }
      return min(max(tilted * gamma, slopeMin), slopeMax)
    }
    let slopeB = channelSlope(refs.blue, gamma: channelGamma.blue)
    let slopeG = min(max(baseSlope * channelGamma.green, slopeMin), slopeMax)
    let slopeR = channelSlope(refs.red, gamma: channelGamma.red)
    return (
      BGRChannelValues(blue: slopeB, green: slopeG, red: slopeR),
      BGRChannelValues(
        blue: anchor - referenceLinear / slopeB,
        green: anchor - referenceLinear / slopeG,
        red: anchor - referenceLinear / slopeR
      ),
      BGRChannelValues(blue: 0, green: 0, red: 0)
    )
  }

  struct NeutralAxisMeasurement {
    var midtone: BGRChannelValues
    var shadow: BGRChannelValues
    var highlight: BGRChannelValues?
    var confidence: Double
  }

  static func quadraticCastRemoval(
    baseSlope: Double,
    axis: NeutralAxisMeasurement,
    strength: Double,
    channelGamma: BGRChannelValues,
    referenceLinear: Double,
    bounds: (floors: BGRChannelValues, ceils: BGRChannelValues),
    anchor: Double
  ) -> (slopes: BGRChannelValues, pivots: BGRChannelValues, curvatures: BGRChannelValues) {
    func norm(_ refs: BGRChannelValues) -> BGRChannelValues {
      BGRChannelValues(
        blue: normalizeLog(refs.blue, floor: bounds.floors.blue, ceil: bounds.ceils.blue),
        green: normalizeLog(refs.green, floor: bounds.floors.green, ceil: bounds.ceils.green),
        red: normalizeLog(refs.red, floor: bounds.floors.red, ceil: bounds.ceils.red)
      )
    }
    let mid = norm(axis.midtone)
    let shadow = norm(axis.shadow)
    let highlight = axis.highlight.map(norm)
    let slopeG = min(max(baseSlope * channelGamma.green, slopeMin), slopeMax)
    let pivotG = anchor - referenceLinear / max(slopeG, epsilon)
    func greenTarget(_ g: Double) -> Double {
      slopeG * (g - pivotG)
    }
    let tMid = greenTarget(mid.green)
    let tShadow = greenTarget(shadow.green)
    func clampDev(_ greenRef: Double, _ channelRef: Double) -> Double {
      greenRef + min(max(strength * (channelRef - greenRef), -midtoneCastMaxOffset), midtoneCastMaxOffset)
    }
    func solveChannel(_ channelMid: Double, _ channelShadow: Double, _ channelHighlight: Double?, gamma: Double)
      -> (slope: Double, pivot: Double, curv: Double)
    {
      let uM = clampDev(mid.green, channelMid)
      let uS = clampDev(shadow.green, channelShadow)
      var curv = 0.0
      if let highlight, let channelHighlight {
        let uH = clampDev(highlight.green, channelHighlight)
        curv = quadraticCoefficient(
          x0: uH, y0: greenTarget(highlight.green),
          x1: uM, y1: tMid,
          x2: uS, y2: tShadow
        )
        let limit = neutralAxisCurvMaxRatio * slopeG
        curv = min(max(curv, -limit), limit)
      }
      let du = uM - uS
      var slope: Double
      if abs(du) < epsilon {
        slope = slopeG
      } else {
        slope = ((tMid - tShadow) - curv * (uM * uM - uS * uS)) / du
      }
      slope = min(max(slope * gamma, slopeMin), slopeMax)
      let curvCh = curv * gamma
      let pivot = abs(slope) > epsilon ? uM - (tMid - curvCh * uM * uM) / slope : pivotG
      return (slope, pivot, curvCh)
    }
    let blue = solveChannel(mid.blue, shadow.blue, highlight?.blue, gamma: channelGamma.blue)
    let red = solveChannel(mid.red, shadow.red, highlight?.red, gamma: channelGamma.red)
    return (
      BGRChannelValues(blue: blue.slope, green: slopeG, red: red.slope),
      BGRChannelValues(blue: blue.pivot, green: pivotG, red: red.pivot),
      BGRChannelValues(blue: blue.curv, green: 0, red: red.curv)
    )
  }

  static func quadraticCoefficient(
    x0: Double, y0: Double,
    x1: Double, y1: Double,
    x2: Double, y2: Double
  ) -> Double {
    let d01 = x0 - x1
    let d12 = x1 - x2
    let d02 = x0 - x2
    if abs(d01) < epsilon || abs(d12) < epsilon || abs(d02) < epsilon {
      return 0
    }
    return ((y0 - y1) / d01 - (y1 - y2) / d12) / d02
  }

  static func samePixelColorFloors(
    _ samples: [(blue: Double, green: Double, red: Double)],
    lumaFloors: BGRChannelValues,
    lumaCeils: BGRChannelValues,
    thinEnd: BGRChannelValues,
    colorClip: Double
  ) -> BGRChannelValues? {
    let minPixels = min(neutralAxisMinPixels, max(8, samples.count / 20))
    guard samples.count >= minPixels else { return nil }
    let norms = samples.map { sample in
      (
        blue: normalizeLog(sample.blue, floor: lumaFloors.blue, ceil: lumaCeils.blue),
        green: normalizeLog(sample.green, floor: lumaFloors.green, ceil: lumaCeils.green),
        red: normalizeLog(sample.red, floor: lumaFloors.red, ceil: lumaCeils.red)
      )
    }
    let luma = norms.map { lumaB * $0.blue + lumaG * $0.green + lumaR * $0.red }
    let clip = min(max(colorClip, 0.00001), 50.0 - colorBoundsBandWidth)
    let lo = percentile(luma, clip)
    let hi = percentile(luma, clip + colorBoundsBandWidth)
    let band = samples.indices.filter { luma[$0] >= lo && luma[$0] <= hi }
    guard band.count >= minPixels else { return nil }

    func select(gammaB: Double, gammaG: Double, gammaR: Double) -> (indices: [Int], chroma: Double)? {
      let gB = abs(gammaB) < epsilon ? epsilon : gammaB
      let gG = abs(gammaG) < epsilon ? epsilon : gammaG
      let gR = abs(gammaR) < epsilon ? epsilon : gammaR
      let chroma = band.map { index in
        let dB = (samples[index].blue - thinEnd.blue) / gB
        let dG = (samples[index].green - thinEnd.green) / gG
        let dR = (samples[index].red - thinEnd.red) / gR
        return rmsChroma(blue: dB, green: dG, red: dR)
      }
      let threshold = percentile(chroma, neutralAxisChromaQuantile * 100)
      let selected = zip(band, chroma).compactMap { $0.1 <= threshold ? $0.0 : nil }
      guard selected.count >= minPixels else { return nil }
      let selectedChroma = selected.map { index -> Double in
        let pos = band.firstIndex(of: index).map { chroma[$0] } ?? 0
        return pos
      }
      return (selected, percentile(selectedChroma, 50))
    }

    let first = select(
      gammaB: lumaFloors.blue - thinEnd.blue,
      gammaG: lumaFloors.green - thinEnd.green,
      gammaR: lumaFloors.red - thinEnd.red
    )
    guard let first, first.chroma <= neutralAxisFirstPassCap else { return nil }
    let provisionalB = median(first.indices.map { samples[$0].blue - thinEnd.blue })
    let provisionalG = median(first.indices.map { samples[$0].green - thinEnd.green })
    let provisionalR = median(first.indices.map { samples[$0].red - thinEnd.red })
    if abs(provisionalB) < epsilon || abs(provisionalG) < epsilon || abs(provisionalR) < epsilon {
      return nil
    }
    let second = select(gammaB: provisionalB, gammaG: provisionalG, gammaR: provisionalR)
    guard let second, second.chroma <= neutralAxisChromaCap else { return nil }
    return BGRChannelValues(
      blue: thinEnd.blue + median(second.indices.map { samples[$0].blue - thinEnd.blue }),
      green: thinEnd.green + median(second.indices.map { samples[$0].green - thinEnd.green }),
      red: thinEnd.red + median(second.indices.map { samples[$0].red - thinEnd.red })
    )
  }

  static func measureNeutralAxis(
    _ samples: [(blue: Double, green: Double, red: Double)],
    bounds: (floors: BGRChannelValues, ceils: BGRChannelValues)
  ) -> NeutralAxisMeasurement? {
    let minPixels = min(neutralAxisMinPixels, max(8, samples.count / 20))
    guard samples.count >= minPixels else { return nil }
    let norms = samples.map { sample in
      (
        blue: normalizeLog(sample.blue, floor: bounds.floors.blue, ceil: bounds.ceils.blue),
        green: normalizeLog(sample.green, floor: bounds.floors.green, ceil: bounds.ceils.green),
        red: normalizeLog(sample.red, floor: bounds.floors.red, ceil: bounds.ceils.red)
      )
    }
    let luma = norms.map { lumaB * $0.blue + lumaG * $0.green + lumaR * $0.red }
    let chroma = norms.map { rmsChroma(blue: $0.blue, green: $0.green, red: $0.red) }

    func bandRefs(
      lo: Double,
      hi: Double,
      chromaValues: [Double],
      cap: Double
    ) -> (refs: BGRChannelValues, chroma: Double, count: Int)? {
      let band = luma.indices.filter { luma[$0] >= lo && luma[$0] <= hi }
      guard band.count >= minPixels else { return nil }
      let bandChroma = band.map { chromaValues[$0] }
      let threshold = percentile(bandChroma, neutralAxisChromaQuantile * 100)
      let selected = zip(band, bandChroma).compactMap { $0.1 <= threshold ? $0.0 : nil }
      let nearNeutral = selected.isEmpty ? cap : percentile(selected.map { chromaValues[$0] }, 50)
      guard selected.count >= minPixels, nearNeutral <= cap else { return nil }
      return (
        BGRChannelValues(
          blue: median(selected.map { samples[$0].blue }),
          green: median(selected.map { samples[$0].green }),
          red: median(selected.map { samples[$0].red })
        ),
        nearNeutral,
        selected.count
      )
    }

    guard
      let mid1 = bandRefs(
        lo: midtoneLumaBand.0, hi: midtoneLumaBand.1, chromaValues: chroma,
        cap: neutralAxisFirstPassCap),
      let sh1 = bandRefs(
        lo: shadowLumaBand.0, hi: shadowLumaBand.1, chromaValues: chroma,
        cap: neutralAxisFirstPassCap)
    else { return nil }

    func normRef(_ refs: BGRChannelValues) -> BGRChannelValues {
      BGRChannelValues(
        blue: normalizeLog(refs.blue, floor: bounds.floors.blue, ceil: bounds.ceils.blue),
        green: normalizeLog(refs.green, floor: bounds.floors.green, ceil: bounds.ceils.green),
        red: normalizeLog(refs.red, floor: bounds.floors.red, ceil: bounds.ceils.red)
      )
    }
    let nm = normRef(mid1.refs)
    let ns = normRef(sh1.refs)
    func correctedChannel(_ channel: Double, mid: Double, shadow: Double, midG: Double, shadowG: Double)
      -> Double
    {
      let du = mid - shadow
      if abs(du) < epsilon {
        return channel + (midG - mid)
      }
      let a = (midG - shadowG) / du
      let b = midG - a * mid
      return a * channel + b
    }
    let correctedChroma = zip(norms.indices, norms).map { _, sample in
      let blue = correctedChannel(
        sample.blue, mid: nm.blue, shadow: ns.blue, midG: nm.green, shadowG: ns.green)
      let red = correctedChannel(
        sample.red, mid: nm.red, shadow: ns.red, midG: nm.green, shadowG: ns.green)
      return rmsChroma(blue: blue, green: sample.green, red: red)
    }

    guard
      let mid = bandRefs(
        lo: midtoneLumaBand.0, hi: midtoneLumaBand.1, chromaValues: correctedChroma,
        cap: neutralAxisChromaCap),
      let shadow = bandRefs(
        lo: shadowLumaBand.0, hi: shadowLumaBand.1, chromaValues: correctedChroma,
        cap: neutralAxisChromaCap)
    else { return nil }
    let highlight = bandRefs(
      lo: highlightLumaBand.0, hi: highlightLumaBand.1, chromaValues: correctedChroma,
      cap: neutralAxisChromaCap)

    let tight = min(max(1.0 - max(mid.chroma, shadow.chroma) / neutralAxisChromaCap, 0), 1)
    let sizeTerm = Double(mid.count) / (Double(mid.count) + neutralAxisConfidenceN0)
    let dm = normRef(mid.refs)
    let ds = normRef(shadow.refs)
    let spread = max(
      abs((dm.blue - dm.green) - (ds.blue - ds.green)),
      abs((dm.red - dm.green) - (ds.red - ds.green))
    )
    let agree =
      1.0 - min(max(spread - neutralAxisAgreementDeadzone, 0) / neutralAxisAgreementScale, 1)
    let confidence = min(max(tight * sizeTerm * agree, 0), 1)
    return NeutralAxisMeasurement(
      midtone: mid.refs,
      shadow: shadow.refs,
      highlight: highlight?.refs,
      confidence: confidence
    )
  }

  static func rmsChroma(blue: Double, green: Double, red: Double) -> Double {
    sqrt(((red - green) * (red - green) + (green - blue) * (green - blue) + (red - blue) * (red - blue)) / 3)
  }

  static func median(_ values: [Double]) -> Double {
    percentile(values, 50)
  }

  static func sampledLogPixels(
    image: UInt16Image,
    unmixBlue: BGRChannelValues,
    unmixGreen: BGRChannelValues,
    unmixRed: BGRChannelValues,
    borderPercent: Double
  ) -> [(blue: Double, green: Double, red: Double)] {
    let insetX = Int(Double(image.width) * min(max(borderPercent, 0), 30) / 100)
    let insetY = Int(Double(image.height) * min(max(borderPercent, 0), 30) / 100)
    let minX = min(insetX, max(image.width / 2 - 1, 0))
    let minY = min(insetY, max(image.height / 2 - 1, 0))
    let maxX = max(image.width - minX, minX + 1)
    let maxY = max(image.height - minY, minY + 1)
    let usableW = max(maxX - minX, 1)
    let usableH = max(maxY - minY, 1)
    let step = max(1, max(usableW, usableH) / analysisLongEdge)
    var samples: [(blue: Double, green: Double, red: Double)] = []
    samples.reserveCapacity((usableW / step + 1) * (usableH / step + 1))
    var y = minY
    while y < maxY {
      var x = minX
      while x < maxX {
        let base = (y * image.width + x) * 3
        let linearB = max(
          FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[base]) / 65_535.0),
          epsilon
        )
        let linearG = max(
          FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[base + 1]) / 65_535.0),
          epsilon
        )
        let linearR = max(
          FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[base + 2]) / 65_535.0),
          epsilon
        )
        let logB = log10(linearB)
        let logG = log10(linearG)
        let logR = log10(linearR)
        samples.append(
          (
            unmixBlue.blue * logB + unmixBlue.green * logG + unmixBlue.red * logR,
            unmixGreen.blue * logB + unmixGreen.green * logG + unmixGreen.red * logR,
            unmixRed.blue * logB + unmixRed.green * logG + unmixRed.red * logR
          )
        )
        x += step
      }
      y += step
    }
    if samples.isEmpty {
      samples.append((log10(epsilon), log10(epsilon), log10(epsilon)))
    }
    return samples
  }

  static func percentile(_ values: [Double], _ percent: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clamped = min(max(percent, 0), 100)
    let position = (Double(sorted.count - 1) * clamped) / 100
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let t = position - Double(lower)
    return sorted[lower] * (1 - t) + sorted[upper] * t
  }
}
