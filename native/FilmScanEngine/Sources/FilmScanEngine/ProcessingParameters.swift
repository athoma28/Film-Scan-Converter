import Foundation

public enum FilmType: Int, Codable, CaseIterable, Hashable, Sendable {
  case blackAndWhiteNegative
  case colourNegative
  case slide
  case cropOnly

  public var supportsToneCorrections: Bool {
    self != .cropOnly
  }

  public var supportsColorCorrections: Bool {
    self == .colourNegative || self == .slide
  }
}

public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
  public var input: Double
  public var output: Double

  public init(input: Double, output: Double) {
    self.input = input
    self.output = output
  }
}

public struct ColorWheel: Codable, Equatable, Sendable {
  public var hue: Double
  public var strength: Double

  public init(hue: Double = 0, strength: Double = 0) {
    self.hue = hue
    self.strength = strength
  }

  public var isNeutral: Bool { strength == 0 }
}

public enum NormalizedCropCoordinateSpace: String, Codable, Equatable, Sendable {
  /// Conventional image coordinates: x and width use image width; y and
  /// height use image height.
  case imageAxes

  /// Compatibility for crop rectangles saved before image-axis normalization
  /// was introduced. Those values used image height for x/width and image
  /// width for y/height.
  case legacyTransposedAxes
}

public enum FilmNegativeRendering: String, Codable, Equatable, Sendable {
  /// The original RawTherapee-derived per-channel power-law rendering.
  case powerLaw

  /// A colour curve calibrated from manually inverted Camera Raw pairs.
  case calibratedColor

  /// A monochrome-only curve calibrated from manually inverted Camera Raw pairs.
  case calibratedMonochrome

  /// Density-domain inversion: dye unmix, independent channel stretch, H&D print.
  case densityPrint
}

/// Selects the paired-reference curve and film-base anchor used by the
/// calibrated colour-negative renderer. Alternate cases are intentionally
/// explicit so saved edits remain stable as more stocks are added later.
public enum CalibratedColorNegativeProfile: String, Codable, Equatable, Sendable {
  case generic
  case fuji400Fresh
  case fuji200Expired
  case cinestill800T
  case harmanPhoenixII
}

/// Selects the paired-reference curve and exposure anchor used by the
/// calibrated monochrome-negative renderer. Stock-specific cases keep their
/// own curve and base anchor so saved edits remain stable as stocks are added.
public enum CalibratedMonochromeProfile: String, Codable, Equatable, Sendable {
  case generic
  case shanghaiGP3
}

public struct FilmNegativeParams: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var redRatio: Double
  public var greenExp: Double
  public var blueRatio: Double
  public var rendering: FilmNegativeRendering
  public var calibratedColorProfile: CalibratedColorNegativeProfile
  public var calibratedMonochromeProfile: CalibratedMonochromeProfile
  /// Exposure applied to the scan before a calibrated decreasing curve.
  /// Positive values therefore produce a darker positive image.
  public var monochromeExposureEV: Double
  /// Bundled or user density-print profile id. Ignored unless `rendering` is
  /// `densityPrint`.
  public var densityProfileID: String
  /// Optional baked 3×3 RGB unmix (9 row-major entries). Empty uses the catalog.
  public var densityUnmixRGB: [Double]
  /// Dye-unmix blend in `[0, 1]`. Negative means "use the catalog default".
  public var densityUnmixStrength: Double
  /// Bundled RA4 / Neutral paper id. Ignored unless `rendering` is `densityPrint`.
  public var densityPaperID: String

  public var measuredMedians: BGRChannelValues?

  private enum CodingKeys: String, CodingKey {
    case enabled
    case redRatio
    case greenExp
    case blueRatio
    case rendering
    case calibratedColorProfile
    case calibratedMonochromeProfile
    case monochromeExposureEV
    case densityProfileID
    case densityUnmixRGB
    case densityUnmixStrength
    case densityPaperID
  }

  public init(
    enabled: Bool = false,
    redRatio: Double = 1.360,
    greenExp: Double = 1.5,
    blueRatio: Double = 0.86,
    rendering: FilmNegativeRendering = .powerLaw,
    calibratedColorProfile: CalibratedColorNegativeProfile = .generic,
    calibratedMonochromeProfile: CalibratedMonochromeProfile = .generic,
    monochromeExposureEV: Double = 0,
    densityProfileID: String = "generic_c41",
    densityUnmixRGB: [Double] = [],
    densityUnmixStrength: Double = -1,
    densityPaperID: String = DensityPaperProfileCatalog.neutral.id.rawValue,
    measuredMedians: BGRChannelValues? = nil
  ) {
    precondition(monochromeExposureEV.isFinite, "Monochrome exposure must be finite")
    self.enabled = enabled
    self.redRatio = redRatio
    self.greenExp = greenExp
    self.blueRatio = blueRatio
    self.rendering = rendering
    self.calibratedColorProfile = calibratedColorProfile
    self.calibratedMonochromeProfile = calibratedMonochromeProfile
    self.monochromeExposureEV = monochromeExposureEV
    self.densityProfileID = densityProfileID
    self.densityUnmixRGB = densityUnmixRGB
    self.densityUnmixStrength = densityUnmixStrength
    self.densityPaperID = densityPaperID
    self.measuredMedians = measuredMedians
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    redRatio = try container.decodeIfPresent(Double.self, forKey: .redRatio) ?? 1.360
    greenExp = try container.decodeIfPresent(Double.self, forKey: .greenExp) ?? 1.5
    blueRatio = try container.decodeIfPresent(Double.self, forKey: .blueRatio) ?? 0.86
    // Profiles and per-file settings written before this field existed used
    // the power-law renderer. Preserve that appearance during migration.
    rendering =
      try container.decodeIfPresent(
        FilmNegativeRendering.self, forKey: .rendering
      ) ?? .powerLaw
    calibratedColorProfile =
      try container.decodeIfPresent(
        CalibratedColorNegativeProfile.self, forKey: .calibratedColorProfile
      ) ?? .generic
    calibratedMonochromeProfile =
      try container.decodeIfPresent(
        CalibratedMonochromeProfile.self, forKey: .calibratedMonochromeProfile
      ) ?? .generic
    monochromeExposureEV =
      try container.decodeIfPresent(
        Double.self, forKey: .monochromeExposureEV
      ) ?? 0
    densityProfileID =
      try container.decodeIfPresent(String.self, forKey: .densityProfileID)
      ?? NegativeDensityProfileCatalog.genericC41.id.rawValue
    densityUnmixRGB =
      try container.decodeIfPresent([Double].self, forKey: .densityUnmixRGB) ?? []
    densityUnmixStrength =
      try container.decodeIfPresent(Double.self, forKey: .densityUnmixStrength) ?? -1
    densityPaperID =
      try container.decodeIfPresent(String.self, forKey: .densityPaperID)
      ?? DensityPaperProfileCatalog.neutral.id.rawValue
    measuredMedians = nil
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(redRatio, forKey: .redRatio)
    try container.encode(greenExp, forKey: .greenExp)
    try container.encode(blueRatio, forKey: .blueRatio)
    try container.encode(rendering, forKey: .rendering)
    try container.encode(calibratedColorProfile, forKey: .calibratedColorProfile)
    try container.encode(calibratedMonochromeProfile, forKey: .calibratedMonochromeProfile)
    try container.encode(monochromeExposureEV, forKey: .monochromeExposureEV)
    try container.encode(densityProfileID, forKey: .densityProfileID)
    try container.encode(densityUnmixRGB, forKey: .densityUnmixRGB)
    try container.encode(densityUnmixStrength, forKey: .densityUnmixStrength)
    try container.encode(densityPaperID, forKey: .densityPaperID)
  }

  public static func densityPrint(
    _ profile: NegativeDensityProfile,
    paper: DensityPaperProfile = DensityPaperProfileCatalog.neutral
  ) -> FilmNegativeParams {
    FilmNegativeParams(
      enabled: true,
      rendering: .densityPrint,
      densityProfileID: profile.id.rawValue,
      densityUnmixRGB: profile.unmixRGBFlat,
      densityUnmixStrength: profile.unmixStrength,
      densityPaperID: paper.id.rawValue
    )
  }

  public static let legacyColourNegative = FilmNegativeParams(
    enabled: true, redRatio: 1.360, greenExp: 1.5, blueRatio: 0.86
  )
  public static let colourNegative = FilmNegativeParams(
    enabled: true,
    redRatio: 1.360,
    greenExp: 1.5,
    blueRatio: 0.86,
    rendering: .calibratedColor
  )
  public static let fuji400FreshAlternate = FilmNegativeParams(
    enabled: true,
    rendering: .calibratedColor,
    calibratedColorProfile: .fuji400Fresh
  )
  public static let fuji200ExpiredAlternate = FilmNegativeParams(
    enabled: true,
    rendering: .calibratedColor,
    calibratedColorProfile: .fuji200Expired
  )
  public static let cinestill800TAlternate = FilmNegativeParams(
    enabled: true,
    rendering: .calibratedColor,
    calibratedColorProfile: .cinestill800T
  )
  public static let harmanPhoenixIIAlternate = FilmNegativeParams(
    enabled: true,
    rendering: .calibratedColor,
    calibratedColorProfile: .harmanPhoenixII
  )
  public static let densityPrintGenericC41 = FilmNegativeParams.densityPrint(
    NegativeDensityProfileCatalog.genericC41
  )
  public static let densityPrintHarmanPhoenixII = FilmNegativeParams.densityPrint(
    NegativeDensityProfileCatalog.harmanPhoenixII,
    paper: DensityPaperProfileCatalog.fujiCrystalArchive
  )
  public static let densityPrintFuji400 = FilmNegativeParams.densityPrint(
    NegativeDensityProfileCatalog.fujicolor400
  )
  public static let legacyBlackAndWhite = FilmNegativeParams(
    enabled: true, redRatio: 1.0, greenExp: 1.5, blueRatio: 1.0
  )
  public static let blackAndWhite = FilmNegativeParams(
    enabled: true,
    redRatio: 1.0,
    greenExp: 1.5,
    blueRatio: 1.0,
    rendering: .calibratedMonochrome
  )
  public static let shanghaiGP3Alternate = FilmNegativeParams(
    enabled: true,
    rendering: .calibratedMonochrome,
    calibratedMonochromeProfile: .shanghaiGP3
  )
}

public enum FilmNegativePreset: Int, CaseIterable, Hashable, Sendable {
  case off
  case colourNegative
  case fuji400FreshAlternate
  case fuji200ExpiredAlternate
  case cinestill800TAlternate
  case harmanPhoenixIIAlternate
  case densityPrintGenericC41
  case densityPrintHarmanPhoenixII
  case densityPrintFuji400
  case legacyColourNegative
  case blackAndWhite
  case shanghaiGP3Alternate
  case legacyBlackAndWhite

  public var displayName: String {
    switch self {
    case .off: "Off"
    case .colourNegative: "Color Negative"
    case .fuji400FreshAlternate: "Alternate — Fuji 400 Fresh"
    case .fuji200ExpiredAlternate: "Alternate — Fuji 200 Expired"
    case .cinestill800TAlternate: "Alternate — CineStill 800T"
    case .harmanPhoenixIIAlternate: "Alternate — Harman Phoenix II"
    case .densityPrintGenericC41: "Physical — Generic C-41"
    case .densityPrintHarmanPhoenixII: "Physical — Harman Phoenix II"
    case .densityPrintFuji400: "Physical — Fujicolor 400"
    case .legacyColourNegative: "Color Negative (Legacy)"
    case .blackAndWhite: "Black & White"
    case .shanghaiGP3Alternate: "Alternate — Shanghai GP3"
    case .legacyBlackAndWhite: "Black & White (Legacy)"
    }
  }
}

public struct FilmClassification: Equatable, Sendable {
  public var filmType: FilmType
  public var filmNegativePreset: FilmNegativePreset
  public var confidence: Double

  public init(
    filmType: FilmType,
    filmNegativePreset: FilmNegativePreset,
    confidence: Double
  ) {
    self.filmType = filmType
    self.filmNegativePreset = filmNegativePreset
    self.confidence = confidence
  }
}

public struct ProcessingParameters: Codable, Equatable, Sendable {
  public var borderCrop: Double
  public var flip: Bool
  public var rotation: Int
  public var straightenAngle: Double
  public var filmType: FilmType
  public var gamma: Int
  public var shadows: Int
  public var highlights: Int
  public var temperature: Int
  public var tint: Int
  public var saturation: Int
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
  public var filmNegativeParams: FilmNegativeParams
  public var filmDyeMixing: FilmDyeMixingParameters
  public var photoAdjustments: PhotoAdjustmentParameters
  public var densityPipelineEnabled: Bool
  public var densityBaseDensity: BGRChannelValues?
  public var densityCorrection: DensityCorrectionMatrix
  public var densityC41Profile: GenericC41Profile
  public var densityDisplayParams: DisplayRenderingParameters
  public var darkThreshold: Int
  public var lightThreshold: Int
  public var cropRect: RotatedRect?
  public var cropRectCoordinateSpace: NormalizedCropCoordinateSpace
  public var perspectiveCrop: PerspectiveCrop?
  public var manualCrop: NormalizedCropRect?

  public init(
    borderCrop: Double = 0,
    flip: Bool = false,
    rotation: Int = 0,
    straightenAngle: Double = 0,
    filmType: FilmType = .cropOnly,
    gamma: Int = 0,
    shadows: Int = 0,
    highlights: Int = 0,
    temperature: Int = 0,
    tint: Int = 0,
    saturation: Int = 100,
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
    filmNegativeParams: FilmNegativeParams = FilmNegativeParams(),
    filmDyeMixing: FilmDyeMixingParameters = .neutral,
    photoAdjustments: PhotoAdjustmentParameters? = nil,
    densityPipelineEnabled: Bool = false,
    densityBaseDensity: BGRChannelValues? = nil,
    densityCorrection: DensityCorrectionMatrix = .identity,
    densityC41Profile: GenericC41Profile = .identity,
    densityDisplayParams: DisplayRenderingParameters = DisplayRenderingParameters(),
    darkThreshold: Int = 25,
    lightThreshold: Int = 100,
    cropRect: RotatedRect? = nil,
    cropRectCoordinateSpace: NormalizedCropCoordinateSpace = .imageAxes,
    perspectiveCrop: PerspectiveCrop? = nil,
    manualCrop: NormalizedCropRect? = nil
  ) {
    self.borderCrop = borderCrop
    self.flip = flip
    self.rotation = rotation
    self.straightenAngle = straightenAngle
    self.filmType = filmType
    self.gamma = gamma
    self.shadows = shadows
    self.highlights = highlights
    self.temperature = temperature
    self.tint = tint
    self.saturation = saturation
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
    self.filmNegativeParams = filmNegativeParams
    self.filmDyeMixing = filmDyeMixing.clamped()
    self.photoAdjustments =
      photoAdjustments
      ?? .migratingLegacy(
        gamma: gamma,
        shadows: shadows,
        highlights: highlights,
        temperature: temperature,
        tint: tint,
        saturation: saturation
      )
    self.densityPipelineEnabled = densityPipelineEnabled
    self.densityBaseDensity = densityBaseDensity
    self.densityCorrection = densityCorrection
    self.densityC41Profile = densityC41Profile
    self.densityDisplayParams = densityDisplayParams
    self.darkThreshold = darkThreshold
    self.lightThreshold = lightThreshold
    self.cropRect = cropRect
    self.cropRectCoordinateSpace = cropRectCoordinateSpace
    self.perspectiveCrop = perspectiveCrop
    self.manualCrop = manualCrop
  }

  private enum CodingKeys: String, CodingKey {
    case borderCrop, flip, rotation, straightenAngle, filmType
    case gamma, shadows, highlights
    case temperature, tint, saturation
    case curveEnabled, curveControlPoints
    case redCurveEnabled, redCurveControlPoints
    case greenCurveEnabled, greenCurveControlPoints
    case blueCurveEnabled, blueCurveControlPoints
    case highlightWheel, midtoneWheel, shadowWheel
    case filmNegativeParams, filmDyeMixing
    case photoAdjustments
    case densityPipelineEnabled, densityBaseDensity
    case densityCorrection, densityC41Profile, densityDisplayParams
    case darkThreshold, lightThreshold, cropRect, cropRectCoordinateSpace
    case perspectiveCrop, manualCrop
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    borderCrop = try container.decodeIfPresent(Double.self, forKey: .borderCrop) ?? 0
    flip = try container.decodeIfPresent(Bool.self, forKey: .flip) ?? false
    rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
    straightenAngle = try container.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? 0
    filmType = try container.decodeIfPresent(FilmType.self, forKey: .filmType) ?? .cropOnly
    gamma = try container.decodeIfPresent(Int.self, forKey: .gamma) ?? 0
    shadows = try container.decodeIfPresent(Int.self, forKey: .shadows) ?? 0
    highlights = try container.decodeIfPresent(Int.self, forKey: .highlights) ?? 0
    temperature = try container.decodeIfPresent(Int.self, forKey: .temperature) ?? 0
    tint = try container.decodeIfPresent(Int.self, forKey: .tint) ?? 0
    saturation = try container.decodeIfPresent(Int.self, forKey: .saturation) ?? 100
    curveEnabled = try container.decodeIfPresent(Bool.self, forKey: .curveEnabled) ?? false
    curveControlPoints =
      try container.decodeIfPresent([CurvePoint].self, forKey: .curveControlPoints) ?? []
    redCurveEnabled = try container.decodeIfPresent(Bool.self, forKey: .redCurveEnabled) ?? false
    redCurveControlPoints =
      try container.decodeIfPresent([CurvePoint].self, forKey: .redCurveControlPoints) ?? []
    greenCurveEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .greenCurveEnabled) ?? false
    greenCurveControlPoints =
      try container.decodeIfPresent([CurvePoint].self, forKey: .greenCurveControlPoints) ?? []
    blueCurveEnabled = try container.decodeIfPresent(Bool.self, forKey: .blueCurveEnabled) ?? false
    blueCurveControlPoints =
      try container.decodeIfPresent([CurvePoint].self, forKey: .blueCurveControlPoints) ?? []
    highlightWheel =
      try container.decodeIfPresent(ColorWheel.self, forKey: .highlightWheel) ?? ColorWheel()
    midtoneWheel =
      try container.decodeIfPresent(ColorWheel.self, forKey: .midtoneWheel) ?? ColorWheel()
    shadowWheel =
      try container.decodeIfPresent(ColorWheel.self, forKey: .shadowWheel) ?? ColorWheel()
    filmNegativeParams =
      try container.decodeIfPresent(FilmNegativeParams.self, forKey: .filmNegativeParams)
      ?? FilmNegativeParams()
    filmDyeMixing =
      try container.decodeIfPresent(
        FilmDyeMixingParameters.self,
        forKey: .filmDyeMixing
      )?.clamped() ?? .neutral
    photoAdjustments =
      try container.decodeIfPresent(
        PhotoAdjustmentParameters.self, forKey: .photoAdjustments
      )
      ?? .migratingLegacy(
        gamma: gamma,
        shadows: shadows,
        highlights: highlights,
        temperature: temperature,
        tint: tint,
        saturation: saturation
      )
    densityPipelineEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .densityPipelineEnabled) ?? false
    densityBaseDensity = try container.decodeIfPresent(
      BGRChannelValues.self, forKey: .densityBaseDensity)
    densityCorrection =
      try container.decodeIfPresent(
        DensityCorrectionMatrix.self, forKey: .densityCorrection
      ) ?? .identity
    densityC41Profile =
      try container.decodeIfPresent(GenericC41Profile.self, forKey: .densityC41Profile) ?? .identity
    densityDisplayParams =
      try container.decodeIfPresent(DisplayRenderingParameters.self, forKey: .densityDisplayParams)
      ?? DisplayRenderingParameters()
    darkThreshold = try container.decodeIfPresent(Int.self, forKey: .darkThreshold) ?? 25
    lightThreshold = try container.decodeIfPresent(Int.self, forKey: .lightThreshold) ?? 100
    cropRect = try container.decodeIfPresent(RotatedRect.self, forKey: .cropRect)
    cropRectCoordinateSpace =
      try container.decodeIfPresent(
        NormalizedCropCoordinateSpace.self,
        forKey: .cropRectCoordinateSpace
      ) ?? (cropRect == nil ? .imageAxes : .legacyTransposedAxes)
    perspectiveCrop = try container.decodeIfPresent(PerspectiveCrop.self, forKey: .perspectiveCrop)
    manualCrop = try container.decodeIfPresent(NormalizedCropRect.self, forKey: .manualCrop)
  }

  /// Keeps the frozen integer color fields aligned with semantic intent so the
  /// display-referred fallback path still has a usable temperature/tint/sat.
  public mutating func syncLegacyColorFieldsFromPhotoAdjustments() {
    temperature = Int(photoAdjustments.temperatureShiftMired.rounded())
    tint = Int((photoAdjustments.tint * 100).rounded())
    saturation = Int((photoAdjustments.saturation * 100).rounded()) + 100
  }
}

public struct RenderParameters: Codable, Equatable, Sendable {
  public var framePercent: Int
  public var aspectRatio: AspectRatio?

  public init(framePercent: Int = 0, aspectRatio: AspectRatio? = nil) {
    self.framePercent = framePercent
    self.aspectRatio = aspectRatio
  }
}

public struct AspectRatio: Codable, Equatable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    precondition(width > 0 && height > 0, "Aspect ratio dimensions must be positive")
    self.width = width
    self.height = height
  }
}
