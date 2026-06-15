import Foundation

public enum FilmType: Int, Codable, CaseIterable, Hashable, Sendable {
  case blackAndWhiteNegative
  case colourNegative
  case slide
  case cropOnly
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

public struct ProcessingParameters: Codable, Equatable, Sendable {
  public var borderCrop: Double
  public var flip: Bool
  public var rotation: Int
  public var filmType: FilmType
  public var whitePoint: Int
  public var blackPoint: Int
  public var gamma: Int
  public var shadows: Int
  public var highlights: Int
  public var temperature: Int
  public var tint: Int
  public var saturation: Int
  public var removeDust: Bool
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

  public init(
    borderCrop: Double = 0,
    flip: Bool = false,
    rotation: Int = 0,
    filmType: FilmType = .cropOnly,
    whitePoint: Int = 0,
    blackPoint: Int = 0,
    gamma: Int = 0,
    shadows: Int = 0,
    highlights: Int = 0,
    temperature: Int = 0,
    tint: Int = 0,
    saturation: Int = 100,
    removeDust: Bool = false,
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
    shadowWheel: ColorWheel = ColorWheel()
  ) {
    self.borderCrop = borderCrop
    self.flip = flip
    self.rotation = rotation
    self.filmType = filmType
    self.whitePoint = whitePoint
    self.blackPoint = blackPoint
    self.gamma = gamma
    self.shadows = shadows
    self.highlights = highlights
    self.temperature = temperature
    self.tint = tint
    self.saturation = saturation
    self.removeDust = removeDust
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
