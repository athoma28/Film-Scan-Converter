import Foundation

/// Versioned, render-independent intent for photographic adjustments.
///
/// These values do not replace the legacy integer operators yet. They provide
/// stable semantic units for the unclamped tone and color pipeline that follows.
public struct PhotoAdjustmentParameters: Codable, Equatable, Hashable, Sendable {
  public static let currentSchemaVersion = 1

  public static let exposureRangeEV = -4.0...4.0
  public static let brightnessRange = -1.0...1.0
  public static let contrastRange = -1.0...1.0
  public static let highlightsRange = -1.0...1.0
  public static let shadowsRange = -1.0...1.0
  public static let temperatureShiftRangeMired = -100.0...100.0
  public static let tintRange = -1.0...1.0
  public static let saturationRange = -1.0...1.0
  public static let vibranceRange = -1.0...1.0

  public var schemaVersion: Int
  public var exposureEV: Double
  public var brightness: Double
  public var contrast: Double
  public var highlights: Double
  public var shadows: Double
  /// Reciprocal-color-temperature shift. Positive values warm the image.
  public var temperatureShiftMired: Double
  public var tint: Double
  public var saturation: Double
  public var vibrance: Double

  public init(
    schemaVersion: Int = currentSchemaVersion,
    exposureEV: Double = 0,
    brightness: Double = 0,
    contrast: Double = 0,
    highlights: Double = 0,
    shadows: Double = 0,
    temperatureShiftMired: Double = 0,
    tint: Double = 0,
    saturation: Double = 0,
    vibrance: Double = 0
  ) {
    self.schemaVersion = schemaVersion
    self.exposureEV = exposureEV
    self.brightness = brightness
    self.contrast = contrast
    self.highlights = highlights
    self.shadows = shadows
    self.temperatureShiftMired = temperatureShiftMired
    self.tint = tint
    self.saturation = saturation
    self.vibrance = vibrance
  }

  public var isNeutral: Bool {
    exposureEV == 0 && brightness == 0 && contrast == 0 && highlights == 0
      && shadows == 0 && temperatureShiftMired == 0 && tint == 0
      && saturation == 0 && vibrance == 0
  }

  public var hasColorAdjustment: Bool {
    temperatureShiftMired != 0 || tint != 0 || saturation != 0 || vibrance != 0
  }

  public var hasToneAdjustment: Bool {
    exposureEV != 0 || brightness != 0 || contrast != 0
      || highlights != 0 || shadows != 0
  }

  /// Maps a normalized UI position through a center-weighted power curve.
  /// Limits are magnitudes so asymmetric semantic ranges remain explicit.
  public static func centerWeightedAmount(
    normalizedPosition: Double,
    negativeLimit: Double,
    positiveLimit: Double
  ) -> Double {
    precondition(negativeLimit >= 0 && positiveLimit >= 0)
    let position = min(max(normalizedPosition, -1), 1)
    if abs(position) < 1e-12 { return 0 }
    let magnitude = pow(abs(position), 1.35)
    return position < 0 ? -magnitude * negativeLimit : magnitude * positiveLimit
  }

  /// Converts old per-file integers into stable intent while retaining the old
  /// fields for the frozen compatibility renderer.
  public static func migratingLegacy(
    gamma: Int,
    shadows: Int,
    highlights: Int,
    temperature: Int,
    tint: Int,
    saturation: Int
  ) -> PhotoAdjustmentParameters {
    func normalized(_ value: Int) -> Double {
      min(max(Double(value) / 100, -1), 1)
    }

    return PhotoAdjustmentParameters(
      brightness: centerWeightedAmount(
        normalizedPosition: normalized(gamma), negativeLimit: 1, positiveLimit: 1),
      highlights: centerWeightedAmount(
        normalizedPosition: normalized(highlights), negativeLimit: 1, positiveLimit: 1),
      shadows: centerWeightedAmount(
        normalizedPosition: normalized(shadows), negativeLimit: 1, positiveLimit: 1),
      temperatureShiftMired: centerWeightedAmount(
        normalizedPosition: normalized(temperature), negativeLimit: 100, positiveLimit: 100),
      tint: centerWeightedAmount(
        normalizedPosition: normalized(tint), negativeLimit: 1, positiveLimit: 1),
      saturation: centerWeightedAmount(
        normalizedPosition: min(max(Double(saturation - 100) / 100, -1), 1),
        negativeLimit: 1,
        positiveLimit: 1
      )
    )
  }

  public mutating func updateColorIntentFromLegacy(
    temperature: Int,
    tint: Int,
    saturation: Int
  ) {
    let migrated = Self.migratingLegacy(
      gamma: 0,
      shadows: 0,
      highlights: 0,
      temperature: temperature,
      tint: tint,
      saturation: saturation
    )
    temperatureShiftMired = migrated.temperatureShiftMired
    self.tint = migrated.tint
    self.saturation = migrated.saturation
  }
}
