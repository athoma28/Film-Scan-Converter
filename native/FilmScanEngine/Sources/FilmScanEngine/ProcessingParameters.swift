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

public struct FilmNegativeParams: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var redRatio: Double
  public var greenExp: Double
  public var blueRatio: Double

  public var measuredMedians: BGRChannelValues?

  private enum CodingKeys: String, CodingKey {
    case enabled
    case redRatio
    case greenExp
    case blueRatio
  }

  public init(
    enabled: Bool = false,
    redRatio: Double = 1.360,
    greenExp: Double = 1.5,
    blueRatio: Double = 0.86,
    measuredMedians: BGRChannelValues? = nil
  ) {
    self.enabled = enabled
    self.redRatio = redRatio
    self.greenExp = greenExp
    self.blueRatio = blueRatio
    self.measuredMedians = measuredMedians
  }

  public static let colourNegative = FilmNegativeParams(
    enabled: true, redRatio: 1.360, greenExp: 1.5, blueRatio: 0.86
  )
  public static let blackAndWhite = FilmNegativeParams(
    enabled: true, redRatio: 1.0, greenExp: 1.5, blueRatio: 1.0
  )
}

public enum FilmNegativePreset: Int, CaseIterable, Hashable, Sendable {
  case off
  case colourNegative
  case blackAndWhite

  public var displayName: String {
    switch self {
    case .off: "Off"
    case .colourNegative: "Color Negative"
    case .blackAndWhite: "Black & White"
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
  public var photoAdjustments: PhotoAdjustmentParameters
  public var densityPipelineEnabled: Bool
  public var densityBaseDensity: BGRChannelValues?
  public var densityC41Profile: GenericC41Profile
  public var densityDisplayParams: DisplayRenderingParameters
  public var darkThreshold: Int
  public var lightThreshold: Int
  public var cropRect: RotatedRect?
  public var perspectiveCrop: PerspectiveCrop?

  public init(
    borderCrop: Double = 0,
    flip: Bool = false,
    rotation: Int = 0,
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
    photoAdjustments: PhotoAdjustmentParameters? = nil,
    densityPipelineEnabled: Bool = false,
    densityBaseDensity: BGRChannelValues? = nil,
    densityC41Profile: GenericC41Profile = .identity,
    densityDisplayParams: DisplayRenderingParameters = DisplayRenderingParameters(),
    darkThreshold: Int = 25,
    lightThreshold: Int = 100,
    cropRect: RotatedRect? = nil,
    perspectiveCrop: PerspectiveCrop? = nil
  ) {
    self.borderCrop = borderCrop
    self.flip = flip
    self.rotation = rotation
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
    self.photoAdjustments = photoAdjustments ?? .migratingLegacy(
      gamma: gamma,
      shadows: shadows,
      highlights: highlights,
      temperature: temperature,
      tint: tint,
      saturation: saturation
    )
    self.densityPipelineEnabled = densityPipelineEnabled
    self.densityBaseDensity = densityBaseDensity
    self.densityC41Profile = densityC41Profile
    self.densityDisplayParams = densityDisplayParams
    self.darkThreshold = darkThreshold
    self.lightThreshold = lightThreshold
    self.cropRect = cropRect
    self.perspectiveCrop = perspectiveCrop
  }

  private enum CodingKeys: String, CodingKey {
    case borderCrop, flip, rotation, filmType
    case gamma, shadows, highlights
    case temperature, tint, saturation
    case curveEnabled, curveControlPoints
    case redCurveEnabled, redCurveControlPoints
    case greenCurveEnabled, greenCurveControlPoints
    case blueCurveEnabled, blueCurveControlPoints
    case highlightWheel, midtoneWheel, shadowWheel
    case filmNegativeParams
    case photoAdjustments
    case densityPipelineEnabled, densityBaseDensity
    case densityC41Profile, densityDisplayParams
    case darkThreshold, lightThreshold, cropRect, perspectiveCrop
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    borderCrop = try container.decodeIfPresent(Double.self, forKey: .borderCrop) ?? 0
    flip = try container.decodeIfPresent(Bool.self, forKey: .flip) ?? false
    rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
    filmType = try container.decodeIfPresent(FilmType.self, forKey: .filmType) ?? .cropOnly
    gamma = try container.decodeIfPresent(Int.self, forKey: .gamma) ?? 0
    shadows = try container.decodeIfPresent(Int.self, forKey: .shadows) ?? 0
    highlights = try container.decodeIfPresent(Int.self, forKey: .highlights) ?? 0
    temperature = try container.decodeIfPresent(Int.self, forKey: .temperature) ?? 0
    tint = try container.decodeIfPresent(Int.self, forKey: .tint) ?? 0
    saturation = try container.decodeIfPresent(Int.self, forKey: .saturation) ?? 100
    curveEnabled = try container.decodeIfPresent(Bool.self, forKey: .curveEnabled) ?? false
    curveControlPoints = try container.decodeIfPresent([CurvePoint].self, forKey: .curveControlPoints) ?? []
    redCurveEnabled = try container.decodeIfPresent(Bool.self, forKey: .redCurveEnabled) ?? false
    redCurveControlPoints = try container.decodeIfPresent([CurvePoint].self, forKey: .redCurveControlPoints) ?? []
    greenCurveEnabled = try container.decodeIfPresent(Bool.self, forKey: .greenCurveEnabled) ?? false
    greenCurveControlPoints = try container.decodeIfPresent([CurvePoint].self, forKey: .greenCurveControlPoints) ?? []
    blueCurveEnabled = try container.decodeIfPresent(Bool.self, forKey: .blueCurveEnabled) ?? false
    blueCurveControlPoints = try container.decodeIfPresent([CurvePoint].self, forKey: .blueCurveControlPoints) ?? []
    highlightWheel = try container.decodeIfPresent(ColorWheel.self, forKey: .highlightWheel) ?? ColorWheel()
    midtoneWheel = try container.decodeIfPresent(ColorWheel.self, forKey: .midtoneWheel) ?? ColorWheel()
    shadowWheel = try container.decodeIfPresent(ColorWheel.self, forKey: .shadowWheel) ?? ColorWheel()
    filmNegativeParams = try container.decodeIfPresent(FilmNegativeParams.self, forKey: .filmNegativeParams) ?? FilmNegativeParams()
    photoAdjustments = try container.decodeIfPresent(
      PhotoAdjustmentParameters.self, forKey: .photoAdjustments
    ) ?? .migratingLegacy(
      gamma: gamma,
      shadows: shadows,
      highlights: highlights,
      temperature: temperature,
      tint: tint,
      saturation: saturation
    )
    densityPipelineEnabled = try container.decodeIfPresent(Bool.self, forKey: .densityPipelineEnabled) ?? false
    densityBaseDensity = try container.decodeIfPresent(BGRChannelValues.self, forKey: .densityBaseDensity)
    densityC41Profile = try container.decodeIfPresent(GenericC41Profile.self, forKey: .densityC41Profile) ?? .identity
    densityDisplayParams = try container.decodeIfPresent(DisplayRenderingParameters.self, forKey: .densityDisplayParams) ?? DisplayRenderingParameters()
    darkThreshold = try container.decodeIfPresent(Int.self, forKey: .darkThreshold) ?? 25
    lightThreshold = try container.decodeIfPresent(Int.self, forKey: .lightThreshold) ?? 100
    cropRect = try container.decodeIfPresent(RotatedRect.self, forKey: .cropRect)
    perspectiveCrop = try container.decodeIfPresent(PerspectiveCrop.self, forKey: .perspectiveCrop)
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
