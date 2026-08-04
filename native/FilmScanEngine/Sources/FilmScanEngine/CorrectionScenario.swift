import Foundation

/// The five representative full-resolution correction scenarios from the
/// adjusted-correction evidence slice. Each scenario is a deterministic delta
/// over a caller-supplied base parameter set: it only changes the adjustment
/// seam, never the film type, film-negative parameters, or geometry, so
/// per-scenario output differences isolate correction passes and memory.
public enum CorrectionScenario: String, Codable, CaseIterable, Sendable {
  /// No photo adjustments and neutral dye mixing: the compact fused path.
  case neutral
  /// Semantic tone adjustments only (exposure, brightness, contrast,
  /// highlights, shadows), entering the linear tone seam.
  case tone
  /// Protected color adjustments only (temperature, tint, saturation,
  /// vibrance), entering the protected-color seam.
  case protectedColor
  /// Film-dye crossover only, entering the dye-mixing seam.
  case dyeMixing
  /// Tone, protected color, and dye mixing together.
  case combined

  public var displayName: String {
    switch self {
    case .neutral: "Neutral"
    case .tone: "Tone"
    case .protectedColor: "Protected Color"
    case .dyeMixing: "Dye Mixing"
    case .combined: "Combined"
    }
  }

  /// The correction passes this scenario activates, in pipeline order, using
  /// the same names as the linear seam's operation boundaries. Empty for the
  /// fused neutral path.
  public var passes: [String] {
    switch self {
    case .neutral: []
    case .tone: ["linearTone"]
    case .protectedColor: ["protectedColor"]
    case .dyeMixing: ["filmDyeMixing"]
    case .combined: ["filmDyeMixing", "linearTone", "protectedColor"]
    }
  }

  /// Applies the scenario's adjustment deltas on top of a base parameter set.
  /// The base's film type, film-negative parameters, and geometry are
  /// preserved untouched; only the photo adjustments and dye mixing change.
  public func processingParameters(base: ProcessingParameters)
    -> ProcessingParameters
  {
    var parameters = base
    switch self {
    case .neutral:
      parameters.photoAdjustments = PhotoAdjustmentParameters()
      parameters.filmDyeMixing = .neutral
    case .tone:
      parameters.photoAdjustments = PhotoAdjustmentParameters(
        exposureEV: -0.75,
        brightness: 0.2,
        contrast: 0.4,
        highlights: -0.3,
        shadows: 0.3
      )
      parameters.filmDyeMixing = .neutral
    case .protectedColor:
      parameters.photoAdjustments = PhotoAdjustmentParameters(
        temperatureShiftMired: 40,
        tint: 0.2,
        saturation: 0.5,
        vibrance: 0.4
      )
      parameters.filmDyeMixing = .neutral
    case .dyeMixing:
      parameters.photoAdjustments = PhotoAdjustmentParameters()
      parameters.filmDyeMixing = FilmDyeMixingParameters(
        redFromGreen: -0.08,
        redFromBlue: 0.04,
        greenFromRed: 0.03,
        greenFromBlue: -0.06,
        blueFromRed: 0.07,
        blueFromGreen: -0.03
      )
    case .combined:
      parameters.photoAdjustments = PhotoAdjustmentParameters(
        exposureEV: -0.75,
        brightness: 0.2,
        contrast: 0.4,
        highlights: -0.3,
        shadows: 0.3,
        temperatureShiftMired: 40,
        tint: 0.2,
        saturation: 0.5,
        vibrance: 0.4
      )
      parameters.filmDyeMixing = FilmDyeMixingParameters(
        redFromGreen: -0.08,
        redFromBlue: 0.04,
        greenFromRed: 0.03,
        greenFromBlue: -0.06,
        blueFromRed: 0.07,
        blueFromGreen: -0.03
      )
    }
    return parameters
  }
}
