import Foundation

/// A scene-adaptive display look: keep the standard color-negative inversion,
/// then fit the visible frame into a target tone envelope and apply a light
/// split-tone. Prototype recipes were sampled from finished JPEGs in
/// `photo-inspo/`, not from paired RAW/XMP emulsion measurements.
public struct AdaptiveDisplayLook: Equatable, Sendable, Identifiable {
  public var id: String { name }

  public let name: String
  public let summary: String
  public let targetShadow: Double
  public let targetMidtone: Double
  public let targetHighlight: Double
  public let photoAdjustments: PhotoAdjustmentParameters
  public let highlightWheel: ColorWheel
  public let midtoneWheel: ColorWheel
  public let shadowWheel: ColorWheel

  public static let analysisMaximumDimension = 1_024

  public init(
    name: String,
    summary: String,
    targetShadow: Double,
    targetMidtone: Double,
    targetHighlight: Double,
    photoAdjustments: PhotoAdjustmentParameters,
    highlightWheel: ColorWheel = ColorWheel(),
    midtoneWheel: ColorWheel = ColorWheel(),
    shadowWheel: ColorWheel = ColorWheel()
  ) {
    self.name = name
    self.summary = summary
    self.targetShadow = targetShadow
    self.targetMidtone = targetMidtone
    self.targetHighlight = targetHighlight
    self.photoAdjustments = photoAdjustments
    self.highlightWheel = highlightWheel
    self.midtoneWheel = midtoneWheel
    self.shadowWheel = shadowWheel
  }

  /// The established Kodachrome-like Auto recipe. Kept byte-identical so the
  /// original control continues to apply the same correction.
  public static let kodachromeLike = AdaptiveDisplayLook(
    name: "Kodachrome-like Auto",
    summary: "Punchy midtones with modest protected saturation.",
    targetShadow: 0.058,
    targetMidtone: 0.285,
    targetHighlight: 0.790,
    photoAdjustments: PhotoAdjustmentParameters(saturation: 0.25, vibrance: 0.25)
  )

  /// Night streets, lanterns, and low-key cinema stills: teal shadows, warm
  /// practicals, darker midtones than Kodachrome-like Auto.
  public static let nightCinema = AdaptiveDisplayLook(
    name: "Night Cinema",
    summary: "Teal shadows, warm lights, low-key contrast.",
    targetShadow: 0.032,
    targetMidtone: 0.168,
    targetHighlight: 0.740,
    photoAdjustments: PhotoAdjustmentParameters(
      contrast: 0.12,
      temperatureShiftMired: -10,
      saturation: 0.10,
      vibrance: 0.28
    ),
    highlightWheel: ColorWheel(hue: 38, strength: 0.32),
    midtoneWheel: ColorWheel(hue: 210, strength: 0.12),
    shadowWheel: ColorWheel(hue: 198, strength: 0.38)
  )

  /// Golden-hour coastal and cream-highlight references: lifted blacks, warm
  /// highlights, softer global contrast.
  public static let goldenCream = AdaptiveDisplayLook(
    name: "Golden Cream",
    summary: "Lifted blacks, creamy highlights, late-day warmth.",
    targetShadow: 0.105,
    targetMidtone: 0.445,
    targetHighlight: 0.875,
    photoAdjustments: PhotoAdjustmentParameters(
      contrast: -0.06,
      highlights: -0.10,
      temperatureShiftMired: 16,
      saturation: 0.04,
      vibrance: 0.16
    ),
    highlightWheel: ColorWheel(hue: 42, strength: 0.28),
    shadowWheel: ColorWheel(hue: 195, strength: 0.16)
  )

  /// Overcast plazas and consumer C-41 daylight: airy whites, yellow-green
  /// midtones. A starting point for stocks such as Lucky C200.
  public static let daylightPrint = AdaptiveDisplayLook(
    name: "Daylight Print",
    summary: "Airy whites, olive-yellow midtones, mild green tint.",
    targetShadow: 0.095,
    targetMidtone: 0.430,
    targetHighlight: 0.910,
    photoAdjustments: PhotoAdjustmentParameters(
      brightness: 0.06,
      temperatureShiftMired: 8,
      tint: -0.10,
      saturation: 0.16,
      vibrance: 0.10
    ),
    highlightWheel: ColorWheel(hue: 48, strength: 0.18),
    midtoneWheel: ColorWheel(hue: 72, strength: 0.14),
    shadowWheel: ColorWheel(hue: 165, strength: 0.12)
  )

  /// Blue-hour cities and twilight architecture: cyan ambient, warm windows.
  public static let blueHour = AdaptiveDisplayLook(
    name: "Blue Hour",
    summary: "Cyan twilight with warm window lights.",
    targetShadow: 0.055,
    targetMidtone: 0.305,
    targetHighlight: 0.720,
    photoAdjustments: PhotoAdjustmentParameters(
      contrast: 0.08,
      temperatureShiftMired: -20,
      saturation: 0.08,
      vibrance: 0.20
    ),
    highlightWheel: ColorWheel(hue: 32, strength: 0.26),
    midtoneWheel: ColorWheel(hue: 200, strength: 0.18),
    shadowWheel: ColorWheel(hue: 205, strength: 0.42)
  )

  public static let prototypes: [AdaptiveDisplayLook] = [
    nightCinema,
    goldenCream,
    daylightPrint,
    blueHour,
  ]

  public func parameters(
    for image: UInt16Image,
    preserving base: ProcessingParameters,
    borderPercent: Double = 20
  ) -> ProcessingParameters {
    precondition(image.channels == 3, "Adaptive display looks require a color image")

    var result = base
    result.filmType = .colourNegative
    result.filmNegativeParams = .colourNegative
    result.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
      image: image,
      borderPercent: borderPercent
    )
    result.densityPipelineEnabled = false

    // Start from a known correction state. Geometry remains frame-specific.
    result.gamma = 0
    result.shadows = 0
    result.highlights = 0
    result.temperature = 0
    result.tint = 0
    result.saturation = 100
    result.photoAdjustments = photoAdjustments
    result.curveEnabled = false
    result.curveControlPoints = []
    result.redCurveEnabled = false
    result.redCurveControlPoints = []
    result.greenCurveEnabled = false
    result.greenCurveControlPoints = []
    result.blueCurveEnabled = false
    result.blueCurveControlPoints = []
    result.highlightWheel = highlightWheel
    result.midtoneWheel = midtoneWheel
    result.shadowWheel = shadowWheel

    let analysisImage: UInt16Image
    if max(image.width, image.height) > Self.analysisMaximumDimension {
      let scale = Double(Self.analysisMaximumDimension) / Double(max(image.width, image.height))
      analysisImage = image.resized(
        width: max(1, Int((Double(image.width) * scale).rounded())),
        height: max(1, Int((Double(image.height) * scale).rounded()))
      )
    } else {
      analysisImage = image
    }
    let baseline = FilmProcessing.correctedPreview(image: analysisImage, parameters: result)
    guard
      let curve = Self.adaptiveCurve(
        for: baseline,
        borderPercent: borderPercent,
        targetShadow: targetShadow,
        targetMidtone: targetMidtone,
        targetHighlight: targetHighlight
      )
    else {
      return result
    }
    result.curveEnabled = true
    result.curveControlPoints = curve
    return result
  }

  public static func adaptiveCurve(
    for displayImage: UInt16Image,
    borderPercent: Double = 20,
    maximumSampleCount: Int = 65_536,
    targetShadow: Double,
    targetMidtone: Double,
    targetHighlight: Double
  ) -> [CurvePoint]? {
    precondition(displayImage.channels == 3, "Adaptive tone analysis requires a color image")
    precondition(borderPercent >= 0 && borderPercent < 50)
    precondition(maximumSampleCount > 0)

    let insetX = Int(Double(displayImage.width) * borderPercent / 100)
    let insetY = Int(Double(displayImage.height) * borderPercent / 100)
    let minX = min(insetX, max(displayImage.width - 1, 0))
    let maxX = max(minX + 1, displayImage.width - insetX)
    let minY = min(insetY, max(displayImage.height - 1, 0))
    let maxY = max(minY + 1, displayImage.height - insetY)
    let sampleWidth = maxX - minX
    let sampleHeight = maxY - minY
    let available = sampleWidth * sampleHeight
    guard available > 2 else { return nil }

    let sampleCount = min(available, maximumSampleCount)
    var luminances: [Double] = []
    luminances.reserveCapacity(sampleCount)
    let luminanceWeights = LuminanceStandards.rec709
    for sample in 0..<sampleCount {
      let linearIndex =
        sampleCount == 1
        ? available / 2
        : sample * (available - 1) / (sampleCount - 1)
      let x = minX + linearIndex % sampleWidth
      let y = minY + linearIndex / sampleWidth
      let pixel = (y * displayImage.width + x) * 3
      let blue = Double(displayImage.pixels[pixel]) / 65_535
      let green = Double(displayImage.pixels[pixel + 1]) / 65_535
      let red = Double(displayImage.pixels[pixel + 2]) / 65_535
      luminances.append(
        luminanceWeights.blue * blue
          + luminanceWeights.green * green
          + luminanceWeights.red * red
      )
    }
    luminances.sort()

    let shadow = ScalarMath.percentile(inSorted: luminances, fraction: 0.05)
    let midtone = ScalarMath.percentile(inSorted: luminances, fraction: 0.50)
    let highlight = ScalarMath.percentile(inSorted: luminances, fraction: 0.95)
    guard shadow.isFinite, midtone.isFinite, highlight.isFinite,
      shadow < midtone, midtone < highlight
    else {
      return nil
    }

    // CurveInterpolator requires strictly increasing inputs. A minimum gap
    // keeps nearly-flat frames well-conditioned without changing normal scans.
    let gap = 0.01
    let x1 = min(max(shadow, gap), 1 - gap * 3)
    let x2 = min(max(midtone, x1 + gap), 1 - gap * 2)
    let x3 = min(max(highlight, x2 + gap), 1 - gap)
    guard x1 < x2, x2 < x3 else { return nil }
    return [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: x1, output: targetShadow),
      CurvePoint(input: x2, output: targetMidtone),
      CurvePoint(input: x3, output: targetHighlight),
      CurvePoint(input: 1, output: 1),
    ]
  }
}
