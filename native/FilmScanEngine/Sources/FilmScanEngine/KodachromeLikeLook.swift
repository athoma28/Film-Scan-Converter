import Foundation

/// A scene-adaptive display look derived from successful camera-JPEG negative
/// conversions. It keeps the proven RawTherapee power-law inversion, then
/// normalizes the visible frame into the repeatable tone envelope shared by
/// the reference conversions.
public enum KodachromeLikeLook {
  public static let targetShadow = 0.058
  public static let targetMidtone = 0.285
  public static let targetHighlight = 0.790
  public static let analysisMaximumDimension = 1_024

  public static func parameters(
    for image: UInt16Image,
    preserving base: ProcessingParameters,
    borderPercent: Double = 20
  ) -> ProcessingParameters {
    precondition(image.channels == 3, "The Kodachrome-like look requires a color image")

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
    result.photoAdjustments = PhotoAdjustmentParameters(saturation: 0.25, vibrance: 0.25)
    result.curveEnabled = false
    result.curveControlPoints = []
    result.redCurveEnabled = false
    result.redCurveControlPoints = []
    result.greenCurveEnabled = false
    result.greenCurveControlPoints = []
    result.blueCurveEnabled = false
    result.blueCurveControlPoints = []
    result.highlightWheel = ColorWheel()
    result.midtoneWheel = ColorWheel()
    result.shadowWheel = ColorWheel()

    let analysisImage: UInt16Image
    if max(image.width, image.height) > analysisMaximumDimension {
      let scale = Double(analysisMaximumDimension) / Double(max(image.width, image.height))
      analysisImage = image.resized(
        width: max(1, Int((Double(image.width) * scale).rounded())),
        height: max(1, Int((Double(image.height) * scale).rounded()))
      )
    } else {
      analysisImage = image
    }
    let baseline = FilmProcessing.correctedPreview(image: analysisImage, parameters: result)
    guard let curve = adaptiveCurve(for: baseline, borderPercent: borderPercent) else {
      return result
    }
    result.curveEnabled = true
    result.curveControlPoints = curve
    return result
  }

  public static func adaptiveCurve(
    for displayImage: UInt16Image,
    borderPercent: Double = 20,
    maximumSampleCount: Int = 65_536
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
      luminances.append(0.0722 * blue + 0.7152 * green + 0.2126 * red)
    }
    luminances.sort()

    let shadow = percentile(luminances, fraction: 0.05)
    let midtone = percentile(luminances, fraction: 0.50)
    let highlight = percentile(luminances, fraction: 0.95)
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

  private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    let amount = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * amount
  }
}
