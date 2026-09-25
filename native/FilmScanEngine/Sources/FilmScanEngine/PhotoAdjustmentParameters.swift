import Foundation

/// Versioned, render-independent intent for photographic adjustments.
///
/// Version 1 preserves saved edits. Version 2 uses the photographic float pipeline.
/// Version 3 is an explicit focused highlight/shadow response candidate.
/// Version 4 is the new-edit default and adds distinct grading point controls;
/// factory looks can pin an older version to preserve their original appearance.
public struct PhotoAdjustmentParameters: Codable, Equatable, Hashable, Sendable {
  public static let currentSchemaVersion = 4
  public static let maximumSupportedSchemaVersion = 4

  public static let exposureRangeEV = -4.0...4.0
  public static let brightnessRange = -1.0...1.0
  public static let contrastRange = -1.0...1.0
  public static let highlightsRange = -1.0...1.0
  public static let shadowsRange = -1.0...1.0
  public static let gradingPointRange = -1.0...1.0
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
  public var whites: Double
  public var blacks: Double
  /// Positive values lift the black output point, creating softer shadows.
  public var shadowFloor: Double
  /// Adjusts the grading midtone level separately from overall brightness.
  public var midtoneLevel: Double
  /// Negative values lower the white output point, softening highlights.
  public var highlightCeiling: Double
  /// Reciprocal-color-temperature shift. Positive values warm the image.
  public var temperatureShiftMired: Double
  public var tint: Double
  public var saturation: Double
  public var vibrance: Double
  /// Selective orange/yellow-to-olive recovery, 0...1. Nil keeps older edits unchanged.
  /// This is a color-family adjustment, not a semantic foliage or skin mask.
  public var warmHueRecovery: Double?

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
    vibrance: Double = 0,
    warmHueRecovery: Double? = nil,
    whites: Double = 0,
    blacks: Double = 0,
    shadowFloor: Double = 0,
    midtoneLevel: Double = 0,
    highlightCeiling: Double = 0
  ) {
    self.schemaVersion = schemaVersion
    self.exposureEV = exposureEV
    self.brightness = brightness
    self.contrast = contrast
    self.highlights = highlights
    self.shadows = shadows
    self.whites = whites
    self.blacks = blacks
    self.shadowFloor = shadowFloor
    self.midtoneLevel = midtoneLevel
    self.highlightCeiling = highlightCeiling
    self.temperatureShiftMired = temperatureShiftMired
    self.tint = tint
    self.saturation = saturation
    self.vibrance = vibrance
    self.warmHueRecovery = warmHueRecovery
  }

  public var isNeutral: Bool {
    !hasToneAdjustment && !hasColorAdjustment
  }

  public var hasColorAdjustment: Bool {
    temperatureShiftMired != 0 || tint != 0 || saturation != 0 || vibrance != 0
      || (warmHueRecovery ?? 0) != 0
  }

  public var hasToneAdjustment: Bool {
    exposureEV != 0 || brightness != 0 || contrast != 0
      || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0
      || shadowFloor != 0 || midtoneLevel != 0 || highlightCeiling != 0
  }

  public var usesPhotographicTone: Bool { schemaVersion >= 2 }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, exposureEV, brightness, contrast, highlights, shadows, whites, blacks
    case shadowFloor, midtoneLevel, highlightCeiling
    case temperatureShiftMired, tint, saturation, vibrance, warmHueRecovery
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard (1...Self.maximumSupportedSchemaVersion).contains(version) else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: values,
        debugDescription: "Unsupported photo adjustment version \(version)")
    }
    func optionalNumber(_ key: CodingKeys) throws -> Double? {
      guard let value = try values.decodeIfPresent(Double.self, forKey: key) else { return nil }
      guard value.isFinite else {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: values,
          debugDescription: "Adjustment must be finite")
      }
      return value
    }
    func number(_ key: CodingKeys) throws -> Double { try optionalNumber(key) ?? 0 }
    self.init(
      schemaVersion: version,
      exposureEV: try number(.exposureEV), brightness: try number(.brightness),
      contrast: try number(.contrast), highlights: try number(.highlights),
      shadows: try number(.shadows), temperatureShiftMired: try number(.temperatureShiftMired),
      tint: try number(.tint), saturation: try number(.saturation), vibrance: try number(.vibrance),
      warmHueRecovery: try optionalNumber(.warmHueRecovery),
      whites: try number(.whites), blacks: try number(.blacks),
      shadowFloor: try number(.shadowFloor), midtoneLevel: try number(.midtoneLevel),
      highlightCeiling: try number(.highlightCeiling))
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
      schemaVersion: 1,
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

}
