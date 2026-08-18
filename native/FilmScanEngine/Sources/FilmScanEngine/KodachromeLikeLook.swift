import Foundation

/// A scene-adaptive display look derived from successful camera-JPEG negative
/// conversions. It keeps the standard color-negative inversion, then
/// normalizes the visible frame into the repeatable tone envelope shared by
/// the reference conversions.
public enum KodachromeLikeLook {
  public static let targetShadow = AdaptiveDisplayLook.kodachromeLike.targetShadow
  public static let targetMidtone = AdaptiveDisplayLook.kodachromeLike.targetMidtone
  public static let targetHighlight = AdaptiveDisplayLook.kodachromeLike.targetHighlight
  public static let analysisMaximumDimension = AdaptiveDisplayLook.analysisMaximumDimension

  public static func parameters(
    for image: UInt16Image,
    preserving base: ProcessingParameters,
    borderPercent: Double = 20
  ) -> ProcessingParameters {
    AdaptiveDisplayLook.kodachromeLike.parameters(
      for: image,
      preserving: base,
      borderPercent: borderPercent
    )
  }

  public static func adaptiveCurve(
    for displayImage: UInt16Image,
    borderPercent: Double = 20,
    maximumSampleCount: Int = 65_536
  ) -> [CurvePoint]? {
    AdaptiveDisplayLook.adaptiveCurve(
      for: displayImage,
      borderPercent: borderPercent,
      maximumSampleCount: maximumSampleCount,
      targetShadow: targetShadow,
      targetMidtone: targetMidtone,
      targetHighlight: targetHighlight
    )
  }
}
