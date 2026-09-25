import Foundation

/// A named snapshot of the public Develop sliders, curves, and wheels.
/// Applying a recipe never changes film base or invert engine IDs.
public struct LookRecipe: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var summary: String
  public var recommendedFilmBases: [FilmBase]
  public var photoAdjustments: PhotoAdjustmentParameters
  public var curveEnabled: Bool
  public var curveControlPoints: [CurvePoint]
  public var redCurveEnabled: Bool
  public var redCurveControlPoints: [CurvePoint]
  public var greenCurveEnabled: Bool
  public var greenCurveControlPoints: [CurvePoint]
  public var blueCurveEnabled: Bool
  public var blueCurveControlPoints: [CurvePoint]
  public var highlightWheel: ColorWheel
  public var midtoneWheel: ColorWheel
  public var shadowWheel: ColorWheel
  public var castCleanup: Double
  public var colorSeparation: Double

  public init(
    id: String,
    title: String,
    summary: String,
    recommendedFilmBases: [FilmBase],
    photoAdjustments: PhotoAdjustmentParameters = PhotoAdjustmentParameters(),
    curveEnabled: Bool = false,
    curveControlPoints: [CurvePoint] = [],
    redCurveEnabled: Bool = false,
    redCurveControlPoints: [CurvePoint] = [],
    greenCurveEnabled: Bool = false,
    greenCurveControlPoints: [CurvePoint] = [],
    blueCurveEnabled: Bool = false,
    blueCurveControlPoints: [CurvePoint] = [],
    highlightWheel: ColorWheel = ColorWheel(),
    midtoneWheel: ColorWheel = ColorWheel(),
    shadowWheel: ColorWheel = ColorWheel(),
    castCleanup: Double = 0.5,
    colorSeparation: Double = 0.45
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.recommendedFilmBases = recommendedFilmBases
    self.photoAdjustments = photoAdjustments
    self.curveEnabled = curveEnabled
    self.curveControlPoints = curveControlPoints
    self.redCurveEnabled = redCurveEnabled
    self.redCurveControlPoints = redCurveControlPoints
    self.greenCurveEnabled = greenCurveEnabled
    self.greenCurveControlPoints = greenCurveControlPoints
    self.blueCurveEnabled = blueCurveEnabled
    self.blueCurveControlPoints = blueCurveControlPoints
    self.highlightWheel = highlightWheel
    self.midtoneWheel = midtoneWheel
    self.shadowWheel = shadowWheel
    self.castCleanup = castCleanup
    self.colorSeparation = colorSeparation
  }

  public static func capturing(
    _ parameters: ProcessingParameters,
    id: String,
    title: String,
    summary: String = "",
    recommendedFilmBases: [FilmBase] = FilmBase.allCases
  ) -> LookRecipe {
    LookRecipe(
      id: id,
      title: title,
      summary: summary,
      recommendedFilmBases: recommendedFilmBases,
      photoAdjustments: parameters.photoAdjustments,
      curveEnabled: parameters.curveEnabled,
      curveControlPoints: parameters.curveControlPoints,
      redCurveEnabled: parameters.redCurveEnabled,
      redCurveControlPoints: parameters.redCurveControlPoints,
      greenCurveEnabled: parameters.greenCurveEnabled,
      greenCurveControlPoints: parameters.greenCurveControlPoints,
      blueCurveEnabled: parameters.blueCurveEnabled,
      blueCurveControlPoints: parameters.blueCurveControlPoints,
      highlightWheel: parameters.highlightWheel,
      midtoneWheel: parameters.midtoneWheel,
      shadowWheel: parameters.shadowWheel,
      castCleanup: capturedCastCleanup(from: parameters),
      colorSeparation: capturedColorSeparation(from: parameters)
    )
  }

  private static func capturedCastCleanup(from parameters: ProcessingParameters) -> Double {
    let fn = parameters.filmNegativeParams
    guard
      FilmBase.resolved(from: parameters).usesDensityPrint
        || parameters.pendingFilmBaseInitialization == .preservingLook
    else { return 0.5 }
    let profile = NegativeDensityProfileCatalog.profile(id: fn.densityProfileID)
    return fn.densityCastRemovalStrength ?? profile.castRemovalStrength
  }

  private static func capturedColorSeparation(from parameters: ProcessingParameters) -> Double {
    let fn = parameters.filmNegativeParams
    guard
      FilmBase.resolved(from: parameters).usesDensityPrint
        || parameters.pendingFilmBaseInitialization == .preservingLook
    else { return 0.45 }
    let profile = NegativeDensityProfileCatalog.profile(id: fn.densityProfileID)
    return fn.densityUnmixStrength >= 0 ? fn.densityUnmixStrength : profile.unmixStrength
  }

  public func applying(to base: ProcessingParameters) -> ProcessingParameters {
    var result = base
    result.photoAdjustments = photoAdjustments
    result.curveEnabled = curveEnabled
    result.curveControlPoints = curveControlPoints
    result.redCurveEnabled = redCurveEnabled
    result.redCurveControlPoints = redCurveControlPoints
    result.greenCurveEnabled = greenCurveEnabled
    result.greenCurveControlPoints = greenCurveControlPoints
    result.blueCurveEnabled = blueCurveEnabled
    result.blueCurveControlPoints = blueCurveControlPoints
    result.highlightWheel = highlightWheel
    result.midtoneWheel = midtoneWheel
    result.shadowWheel = shadowWheel
    result.gamma = 0
    result.shadows = 0
    result.highlights = 0
    if FilmBase.resolved(from: result).usesDensityPrint
      || result.pendingFilmBaseInitialization == .preservingLook
    {
      result.filmNegativeParams.densityCastRemovalStrength = castCleanup
      result.filmNegativeParams.densityUnmixStrength = colorSeparation
      result.filmNegativeParams.densityNeutralProtection = true
    }
    result.syncLegacyColorFieldsFromPhotoAdjustments()
    return result
  }

  public func matches(_ parameters: ProcessingParameters) -> Bool {
    let other = LookRecipe.capturing(
      parameters, id: id, title: title, recommendedFilmBases: recommendedFilmBases)
    if other.photoAdjustments.normalized() != photoAdjustments.normalized() { return false }
    if other.curveEnabled != curveEnabled || other.curveControlPoints != curveControlPoints {
      return false
    }
    if other.redCurveEnabled != redCurveEnabled
      || other.redCurveControlPoints != redCurveControlPoints
    {
      return false
    }
    if other.greenCurveEnabled != greenCurveEnabled
      || other.greenCurveControlPoints != greenCurveControlPoints
    {
      return false
    }
    if other.blueCurveEnabled != blueCurveEnabled
      || other.blueCurveControlPoints != blueCurveControlPoints
    {
      return false
    }
    if other.highlightWheel != highlightWheel || other.midtoneWheel != midtoneWheel
      || other.shadowWheel != shadowWheel
    {
      return false
    }
    if FilmBase.resolved(from: parameters).usesDensityPrint {
      if abs(other.castCleanup - castCleanup) > 1e-9 { return false }
      if abs(other.colorSeparation - colorSeparation) > 1e-9 { return false }
    }
    return true
  }

  public static func recommended(for base: FilmBase) -> [LookRecipe] {
    factory.filter { $0.recommendedFilmBases.contains(base) }
  }

  public static func named(_ id: String) -> LookRecipe? {
    factory.first { $0.id == id }
  }
}

extension PhotoAdjustmentParameters {
  fileprivate func normalized() -> PhotoAdjustmentParameters {
    var copy = self
    copy.warmHueRecovery = warmHueRecovery ?? 0
    return copy
  }
}

extension LookRecipe {
  public static let cleanInvert = LookRecipe(
    id: "cleanInvert",
    title: "Clean Invert",
    summary: "Straight invert with modest cast cleanup. The default starting point.",
    recommendedFilmBases: [.colorC41, .colorCyanMask, .slide],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2, highlights: -0.08, shadows: 0.04, vibrance: 0.08)
  )

  public static let softPeople = LookRecipe(
    id: "softPeople",
    title: "Soft People",
    summary: "Gentler contrast, quieter color, a little warmth.",
    recommendedFilmBases: [.colorC41, .colorCyanMask, .slide],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      contrast: -0.10, highlights: -0.18, shadows: 0.10,
      temperatureShiftMired: 7, saturation: -0.06, vibrance: 0.04)
  )

  public static let punchyPrint = LookRecipe(
    id: "punchyPrint",
    title: "Punchy Print",
    summary: "Stronger midtones and protected saturation.",
    recommendedFilmBases: [.colorC41, .colorCyanMask, .slide],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      contrast: 0.06, highlights: -0.10, saturation: 0.12, vibrance: 0.18),
    curveEnabled: true,
    curveControlPoints: [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.25, output: 0.20),
      CurvePoint(input: 0.50, output: 0.48),
      CurvePoint(input: 0.75, output: 0.80),
      CurvePoint(input: 1, output: 1),
    ]
  )

  public static let warm = LookRecipe(
    id: "warm",
    title: "Warm",
    summary: "Golden warmth and richer color.",
    recommendedFilmBases: [.colorC41, .colorCyanMask, .slide],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      contrast: 0.08, highlights: -0.12, temperatureShiftMired: 18, saturation: 0.06, vibrance: 0.14
    )
  )

  public static let cool = LookRecipe(
    id: "cool",
    title: "Cool",
    summary: "Cooler color and softer bright lights.",
    recommendedFilmBases: [.colorC41, .colorCyanMask, .slide],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      contrast: 0.04, highlights: -0.24, shadows: 0.05,
      temperatureShiftMired: -14, saturation: -0.10, vibrance: 0.10)
  )

  public static let foliage = LookRecipe(
    id: "foliage",
    title: "Foliage",
    summary: "Pull copper greens toward olive. Lower foliage recovery if wood or skin shifts.",
    recommendedFilmBases: [.colorC41],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      highlights: -0.08, shadows: 0.04, tint: -0.06, saturation: -0.04, vibrance: 0.06,
      warmHueRecovery: 0.55)
  )

  public static let nightLift = LookRecipe(
    id: "nightLift",
    title: "Night Lift",
    summary: "Open a dark frame and keep lamp warmth. Does not add a cinema split-tone.",
    recommendedFilmBases: [.colorC41, .colorCyanMask],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      exposureEV: 1.20, highlights: -0.22, shadows: 0.30, temperatureShiftMired: 20, vibrance: 0.16)
  )

  public static let bwPrint = LookRecipe(
    id: "bwPrint",
    title: "B&W Print",
    summary: "Monochrome with print contrast. Highlights stay restrained.",
    recommendedFilmBases: [.blackAndWhite],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      contrast: 0.18, highlights: -0.04, shadows: 0.04, saturation: -1)
  )

  public static let bwSoft = LookRecipe(
    id: "bwSoft",
    title: "B&W Soft",
    summary: "Open, gentle monochrome.",
    recommendedFilmBases: [.blackAndWhite],
    photoAdjustments: PhotoAdjustmentParameters(
      schemaVersion: 2,
      contrast: -0.08, highlights: -0.10, shadows: 0.12, saturation: -1)
  )

  public static let factory: [LookRecipe] = [
    cleanInvert, softPeople, punchyPrint, warm, cool, foliage, nightLift, bwPrint, bwSoft,
  ]
}
