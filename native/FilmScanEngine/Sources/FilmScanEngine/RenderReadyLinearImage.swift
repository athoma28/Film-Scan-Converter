import Foundation

/// An unclamped, scene-linear BGR image shared by inversion front-ends and
/// photographic adjustments. Bounds and gamut handling belong to the final
/// display or export transform, not this buffer.
public struct RenderReadyLinearImage: Equatable, Sendable {
  public static let statisticsSampleLimit = 65_536

  public let width: Int
  public let height: Int
  public var pixels: [Double]

  public init(width: Int, height: Int, pixels: [Double]) {
    precondition(width >= 0 && height >= 0, "Image dimensions must be nonnegative")
    precondition(
      pixels.count == width * height * 3,
      "Render-ready linear images must contain three-channel BGR pixels"
    )
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  public var pixelCount: Int { width * height }

  /// Slice 2 establishes the adjustment seam before Slice 3 adds operators.
  /// Its neutral path deliberately preserves all finite, negative, and
  /// over-range values without copying or clamping them.
  public func applyingNeutralAdjustments() -> RenderReadyLinearImage {
    self
  }

  /// Slice 4: safe luminance-preserving global tone controls on the shared
  /// unclamped linear seam. All operations multiply every channel equally so
  /// hue is preserved. The legacy integer gamma/shadows/highlights path is
  /// retained for compatibility fixtures; these semantic controls are the
  /// intended public API.
  public func applyingLinearToneAdjustments(
    _ parameters: PhotoAdjustmentParameters
  ) -> RenderReadyLinearImage {
    let hasToneAdjustment = parameters.exposureEV != 0
      || parameters.brightness != 0
      || parameters.contrast != 0
      || parameters.highlights != 0
      || parameters.shadows != 0
    guard hasToneAdjustment else { return self }

    let exposureGain = exp2(parameters.exposureEV)
    let brightnessOffset = parameters.brightness * 0.18
    let contrastGamma = exp2(parameters.contrast)
    let contrastActive = parameters.contrast != 0
    let highlightsActive = parameters.highlights != 0
    let shadowsActive = parameters.shadows != 0
    let highlightsScale = parameters.highlights * 0.8
    let shadowsScale = parameters.shadows * 0.8

    let pivot = 0.18
    let minGain = 0.0005

    var adjusted = [Double](repeating: 0, count: pixels.count)
    for pixelIndex in 0..<pixelCount {
      let base = pixelIndex * 3
      var b = pixels[base]
      var g = pixels[base + 1]
      var r = pixels[base + 2]

      b *= exposureGain
      g *= exposureGain
      r *= exposureGain

      b += brightnessOffset
      g += brightnessOffset
      r += brightnessOffset

      if contrastActive {
        let luminance = 0.2626983 * r + 0.6780 * g + 0.0593017 * b
        if luminance > 0 {
          let normalized = luminance / pivot
          let adjustedLuminance = Self.powClamped(normalized, contrastGamma) * pivot
          let scale = adjustedLuminance / luminance
          b *= scale
          g *= scale
          r *= scale
        }
      }

      if highlightsActive || shadowsActive {
        let luminance = 0.2626983 * r + 0.6780 * g + 0.0593017 * b
        if highlightsActive {
          let highlightWeight = Self.smoothstep(0.5, 2.0, luminance)
          let highlightGain = max(1 - highlightsScale * highlightWeight, minGain)
          b *= highlightGain
          g *= highlightGain
          r *= highlightGain
        }
        if shadowsActive {
          let shadowWeight = 1 - Self.smoothstep(0, 0.5, luminance)
          let shadowGain = max(1 + shadowsScale * shadowWeight, minGain)
          b *= shadowGain
          g *= shadowGain
          r *= shadowGain
        }
      }

      adjusted[base] = b
      adjusted[base + 1] = g
      adjusted[base + 2] = r
    }
    return RenderReadyLinearImage(width: width, height: height, pixels: adjusted)
  }

  private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = min(max((value - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
  }

  private static func powClamped(_ base: Double, _ exponent: Double) -> Double {
    let clampedBase = min(max(base, 1e-12), 1e12)
    let result = pow(clampedBase, exponent)
    if !result.isFinite { return clampedBase >= 1 ? 1e12 : 1e-12 }
    return result
  }

  /// Applies the Slice 3 color operators in a linear Rec.2020 opponent model.
  /// Luminance is held constant; chroma changes are attenuated in highlights
  /// and near the gamut boundary, then reduced toward the neutral axis when
  /// needed. The exact-neutral fast path preserves unclamped values bit-for-bit.
  public func applyingProtectedColorAdjustments(
    _ parameters: PhotoAdjustmentParameters
  ) -> RenderReadyLinearImage {
    let hasColorAdjustment = parameters.temperatureShiftMired != 0
      || parameters.tint != 0
      || parameters.saturation != 0
      || parameters.vibrance != 0
    guard hasColorAdjustment else { return self }

    var adjusted = [Double](repeating: 0, count: pixels.count)
    for pixelIndex in 0..<pixelCount {
      let base = pixelIndex * 3
      let output = ProtectedColorAdjustment.apply(
        blue: pixels[base],
        green: pixels[base + 1],
        red: pixels[base + 2],
        parameters: parameters
      )
      adjusted[base] = output.blue
      adjusted[base + 1] = output.green
      adjusted[base + 2] = output.red
    }
    return RenderReadyLinearImage(width: width, height: height, pixels: adjusted)
  }

  public func statistics(
    maximumSampleCount: Int = 65_536
  ) -> RenderReadyImageStatistics {
    precondition(maximumSampleCount > 0, "Maximum sample count must be positive")
    guard pixelCount > 0 else { return .empty }

    let sampleCount = min(pixelCount, maximumSampleCount, Self.statisticsSampleLimit)
    var luminances: [Double] = []
    var logLuminances: [Double] = []
    luminances.reserveCapacity(sampleCount)
    logLuminances.reserveCapacity(sampleCount)

    var lowClips = [Int](repeating: 0, count: 3)
    var highClips = [Int](repeating: 0, count: 3)
    let logFloor = exp2(-24.0)

    for sampleIndex in 0..<sampleCount {
      let pixelIndex: Int
      if sampleCount == 1 {
        pixelIndex = pixelCount / 2
      } else {
        pixelIndex = sampleIndex * (pixelCount - 1) / (sampleCount - 1)
      }
      let base = pixelIndex * 3
      let blue = sanitized(pixels[base])
      let green = sanitized(pixels[base + 1])
      let red = sanitized(pixels[base + 2])
      if blue <= 0 { lowClips[0] += 1 }
      if green <= 0 { lowClips[1] += 1 }
      if red <= 0 { lowClips[2] += 1 }
      if blue >= 1 { highClips[0] += 1 }
      if green >= 1 { highClips[1] += 1 }
      if red >= 1 { highClips[2] += 1 }

      // ITU-R BT.2020 linear-light luminance, with the buffer stored as BGR.
      let luminance = 0.0593017 * blue + 0.6780 * green + 0.2626983 * red
      luminances.append(luminance)
      logLuminances.append(log2(max(luminance, logFloor)))
    }

    luminances.sort()
    logLuminances.sort()
    let linear = PercentileTriplet(
      p01: percentile(luminances, fraction: 0.01),
      p50: percentile(luminances, fraction: 0.50),
      p99: percentile(luminances, fraction: 0.99)
    )
    let logarithmic = PercentileTriplet(
      p01: percentile(logLuminances, fraction: 0.01),
      p50: percentile(logLuminances, fraction: 0.50),
      p99: percentile(logLuminances, fraction: 0.99)
    )
    let logRange = logarithmic.p99 - logarithmic.p01
    let normalizedMidtone = logRange > 0
      ? min(max((logarithmic.p50 - logarithmic.p01) / logRange, 0), 1)
      : 0.5
    let divisor = Double(sampleCount)

    return RenderReadyImageStatistics(
      totalPixelCount: pixelCount,
      sampleCount: sampleCount,
      linearLuminance: linear,
      logLuminance: logarithmic,
      lowClippingRatios: BGRChannelValues(
        blue: Double(lowClips[0]) / divisor,
        green: Double(lowClips[1]) / divisor,
        red: Double(lowClips[2]) / divisor
      ),
      highClippingRatios: BGRChannelValues(
        blue: Double(highClips[0]) / divisor,
        green: Double(highClips[1]) / divisor,
        red: Double(highClips[2]) / divisor
      ),
      normalizedToneReferences: NormalizedToneReferences(
        shadow: 0,
        midtone: normalizedMidtone,
        highlight: 1
      )
    )
  }

  private func sanitized(_ value: Double) -> Double {
    let statisticsBound = exp2(24.0)
    if value.isNaN || value == -.infinity { return 0 }
    if value == .infinity { return statisticsBound }
    return min(max(value, -statisticsBound), statisticsBound)
  }

  private func percentile(_ sorted: [Double], fraction: Double) -> Double {
    guard sorted.count > 1 else { return sorted.first ?? 0 }
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    let amount = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * amount
  }
}

public enum ProtectedColorAdjustment {
  public static let blueLuminance = 0.0593017
  public static let greenLuminance = 0.6780
  public static let redLuminance = 0.2626983
  public static let opponentShiftScale = 0.08

  public static func apply(
    blue: Double,
    green: Double,
    red: Double,
    parameters: PhotoAdjustmentParameters
  ) -> (blue: Double, green: Double, red: Double) {
    let finiteBound = exp2(24.0)
    let b = finiteValue(blue, bound: finiteBound)
    let g = finiteValue(green, bound: finiteBound)
    let r = finiteValue(red, bound: finiteBound)
    let luminance = blueLuminance * b + greenLuminance * g + redLuminance * r
    guard luminance > 0 else { return (b, g, r) }

    let neutralB = luminance
    let neutralG = luminance
    let neutralR = luminance
    var chromaB = b - neutralB
    var chromaG = g - neutralG
    var chromaR = r - neutralR

    let maximum = max(b, g, r)
    let minimum = min(b, g, r)
    let saturationMetric = min(max((maximum - minimum) / max(abs(maximum), 1e-9), 0), 1)
    let gamutRiskProtection = 1 - 0.75 * smoothstep(0.75, 1, saturationMetric)
    let highlightProtection = 1 - 0.85 * smoothstep(0.75, 1.5, luminance)

    let saturation = min(max(parameters.saturation, -1), 1)
    let saturationFactor = exp2(saturation)
    let protectedSaturationFactor = 1
      + (saturationFactor - 1) * gamutRiskProtection * highlightProtection

    let vibrance = min(max(parameters.vibrance, -1), 1)
    let vibranceFactor: Double
    if vibrance >= 0 {
      let selectivity = pow(1 - saturationMetric, 2)
      vibranceFactor = 1 + vibrance * selectivity * gamutRiskProtection * highlightProtection
    } else {
      vibranceFactor = 1 + vibrance * highlightProtection
    }
    let chromaFactor = max(protectedSaturationFactor * vibranceFactor, 0)
    chromaB *= chromaFactor
    chromaG *= chromaFactor
    chromaR *= chromaFactor

    let temperature = min(max(parameters.temperatureShiftMired / 100, -1), 1)
    let tint = min(max(parameters.tint, -1), 1)
    let shiftMagnitude = opponentShiftScale * luminance * highlightProtection
    // Both axes have zero Rec.2020 luminance. Positive temperature is warm;
    // positive tint moves from green toward magenta.
    let temperatureGreen = -(redLuminance - blueLuminance) / greenLuminance
    let tintGreen = -(redLuminance + blueLuminance) / greenLuminance
    chromaB += (-temperature + tint) * shiftMagnitude
    chromaG += (temperature * temperatureGreen + tint * tintGreen) * shiftMagnitude
    chromaR += (temperature + tint) * shiftMagnitude

    let desired = (
      blue: neutralB + chromaB,
      green: neutralG + chromaG,
      red: neutralR + chromaR
    )
    let ceiling = max(1, luminance * 1.5)
    guard !isInGamut(desired, ceiling: ceiling) else { return desired }

    var lower = 0.0
    var upper = 1.0
    for _ in 0..<24 {
      let amount = (lower + upper) * 0.5
      let candidate = (
        blue: neutralB + chromaB * amount,
        green: neutralG + chromaG * amount,
        red: neutralR + chromaR * amount
      )
      if isInGamut(candidate, ceiling: ceiling) {
        lower = amount
      } else {
        upper = amount
      }
    }
    return (
      neutralB + chromaB * lower,
      neutralG + chromaG * lower,
      neutralR + chromaR * lower
    )
  }

  private static func finiteValue(_ value: Double, bound: Double) -> Double {
    if value.isNaN || value == -.infinity { return 0 }
    if value == .infinity { return bound }
    return min(max(value, -bound), bound)
  }

  private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = min(max((value - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
  }

  private static func isInGamut(
    _ value: (blue: Double, green: Double, red: Double),
    ceiling: Double
  ) -> Bool {
    value.blue >= 0 && value.green >= 0 && value.red >= 0
      && value.blue <= ceiling && value.green <= ceiling && value.red <= ceiling
  }
}

public struct PercentileTriplet: Equatable, Sendable {
  public let p01: Double
  public let p50: Double
  public let p99: Double

  public init(p01: Double, p50: Double, p99: Double) {
    self.p01 = p01
    self.p50 = p50
    self.p99 = p99
  }
}

public struct NormalizedToneReferences: Equatable, Sendable {
  public let shadow: Double
  public let midtone: Double
  public let highlight: Double

  public init(shadow: Double, midtone: Double, highlight: Double) {
    self.shadow = shadow
    self.midtone = midtone
    self.highlight = highlight
  }
}

public struct RenderReadyImageStatistics: Equatable, Sendable {
  public let totalPixelCount: Int
  public let sampleCount: Int
  public let linearLuminance: PercentileTriplet
  public let logLuminance: PercentileTriplet
  public let lowClippingRatios: BGRChannelValues
  public let highClippingRatios: BGRChannelValues
  public let normalizedToneReferences: NormalizedToneReferences

  public init(
    totalPixelCount: Int,
    sampleCount: Int,
    linearLuminance: PercentileTriplet,
    logLuminance: PercentileTriplet,
    lowClippingRatios: BGRChannelValues,
    highClippingRatios: BGRChannelValues,
    normalizedToneReferences: NormalizedToneReferences
  ) {
    self.totalPixelCount = totalPixelCount
    self.sampleCount = sampleCount
    self.linearLuminance = linearLuminance
    self.logLuminance = logLuminance
    self.lowClippingRatios = lowClippingRatios
    self.highClippingRatios = highClippingRatios
    self.normalizedToneReferences = normalizedToneReferences
  }

  public static let empty = RenderReadyImageStatistics(
    totalPixelCount: 0,
    sampleCount: 0,
    linearLuminance: PercentileTriplet(p01: 0, p50: 0, p99: 0),
    logLuminance: PercentileTriplet(p01: 0, p50: 0, p99: 0),
    lowClippingRatios: BGRChannelValues(blue: 0, green: 0, red: 0),
    highClippingRatios: BGRChannelValues(blue: 0, green: 0, red: 0),
    normalizedToneReferences: NormalizedToneReferences(shadow: 0, midtone: 0.5, highlight: 1)
  )
}
