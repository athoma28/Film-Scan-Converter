import Foundation

public struct NormalizedCropRect: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && x >= 0 && y >= 0 && width > 0 && height > 0
      && x + width <= 1.000_001 && y + height <= 1.000_001
  }
}

public enum ImageGeometry {
  public enum StraightenAxis: Equatable, Sendable {
    case horizontal
    case vertical
  }

  public static func straightenGuide(
    deltaX: Double,
    deltaY: Double
  ) -> (deviation: Double, axis: StraightenAxis)? {
    guard deltaX.isFinite, deltaY.isFinite, hypot(deltaX, deltaY) > 0 else { return nil }
    var angle = atan2(deltaY, deltaX) * 180 / .pi
    angle = angle.truncatingRemainder(dividingBy: 180)
    if angle > 90 { angle -= 180 }
    if angle < -90 { angle += 180 }
    if abs(angle) <= 45 {
      return (angle, .horizontal)
    }
    return (angle > 0 ? angle - 90 : angle + 90, .vertical)
  }

  public static func outputDimensions(
    source: PixelDimensions,
    parameters: ProcessingParameters
  ) -> PixelDimensions {
    var dimensions = initialCropDimensions(source: source, parameters: parameters)
    if abs(parameters.rotation) % 2 == 1 {
      dimensions = PixelDimensions(width: dimensions.height, height: dimensions.width)
    }
    dimensions = rotatedCanvasDimensions(
      dimensions, clockwiseDegrees: -parameters.straightenAngle)
    if let crop = parameters.manualCrop,
      let bounds = pixelBounds(for: crop, imageWidth: dimensions.width, imageHeight: dimensions.height)
    {
      dimensions = PixelDimensions(width: bounds.width, height: bounds.height)
    }
    return dimensions
  }

  public static func framedDimensions(
    _ source: PixelDimensions,
    framePercent: Int,
    aspectRatio: AspectRatio?
  ) -> PixelDimensions {
    guard framePercent != 0 || aspectRatio != nil else { return source }
    let frameSize = max(1, Int(Double(min(source.width, source.height) * framePercent) / 100))
    var width = source.width + frameSize * 2
    var height = source.height + frameSize * 2
    if let aspectRatio {
      let targetRatio = Double(aspectRatio.width) / Double(aspectRatio.height)
      if Double(width) / Double(height) > targetRatio {
        height = Int(Double(width) / targetRatio)
      } else {
        width = Int(Double(height) * targetRatio)
      }
    }
    return PixelDimensions(width: width, height: height)
  }

  public static func rotatedCanvasDimensions(
    _ source: PixelDimensions,
    clockwiseDegrees: Double
  ) -> PixelDimensions {
    guard clockwiseDegrees.isFinite else { return source }
    let normalized = clockwiseDegrees.truncatingRemainder(dividingBy: 360)
    guard abs(normalized) > 0.000_001 else { return source }
    let quarterTurns = (normalized / 90).rounded()
    if abs(normalized - quarterTurns * 90) < 0.000_001 {
      return abs(Int(quarterTurns)) % 2 == 1
        ? PixelDimensions(width: source.height, height: source.width)
        : source
    }
    let radians = normalized * .pi / 180
    let cosine = abs(cos(radians))
    let sine = abs(sin(radians))
    let widthSpan = Double(max(0, source.width - 1)) * cosine
      + Double(max(0, source.height - 1)) * sine
    let heightSpan = Double(max(0, source.width - 1)) * sine
      + Double(max(0, source.height - 1)) * cosine
    return PixelDimensions(
      width: max(1, Int(widthSpan.rounded(.up)) + 1),
      height: max(1, Int(heightSpan.rounded(.up)) + 1)
    )
  }

  static func pixelBounds(
    for crop: NormalizedCropRect,
    imageWidth: Int,
    imageHeight: Int
  ) -> (x: Int, y: Int, width: Int, height: Int)? {
    guard crop.isValid, imageWidth > 0, imageHeight > 0 else { return nil }
    let minX = min(imageWidth - 1, max(0, Int((crop.x * Double(imageWidth)).rounded(.down))))
    let minY = min(imageHeight - 1, max(0, Int((crop.y * Double(imageHeight)).rounded(.down))))
    let maxX = min(imageWidth, max(minX + 1,
      Int(((crop.x + crop.width) * Double(imageWidth)).rounded(.up))))
    let maxY = min(imageHeight, max(minY + 1,
      Int(((crop.y + crop.height) * Double(imageHeight)).rounded(.up))))
    return (minX, minY, maxX - minX, maxY - minY)
  }

  private static func initialCropDimensions(
    source: PixelDimensions,
    parameters: ProcessingParameters
  ) -> PixelDimensions {
    if let crop = parameters.perspectiveCrop, crop.isValid {
      let insetScale = max(0, 1 - max(0, parameters.borderCrop) / 100)
      let centerX = crop.points.map(\.x).reduce(0, +) / 4
      let centerY = crop.points.map(\.y).reduce(0, +) / 4
      let points = crop.points.map { point in
        PerspectiveCrop.Point(
          x: centerX + (point.x - centerX) * insetScale,
          y: centerY + (point.y - centerY) * insetScale)
      }
      func distance(_ a: PerspectiveCrop.Point, _ b: PerspectiveCrop.Point) -> Double {
        hypot(
          (a.x - b.x) * Double(max(0, source.width - 1)),
          (a.y - b.y) * Double(max(0, source.height - 1)))
      }
      return PixelDimensions(
        width: max(1, Int(((distance(points[0], points[1]) + distance(points[3], points[2])) / 2).rounded()) + 1),
        height: max(1, Int(((distance(points[0], points[3]) + distance(points[1], points[2])) / 2).rounded()) + 1)
      )
    }
    if let crop = parameters.cropRect {
      let rect = ContourDetection.denormalize(
        crop,
        imageWidth: source.width,
        imageHeight: source.height,
        coordinateSpace: parameters.cropRectCoordinateSpace
      )
      guard rect.width > 1, rect.height > 1 else { return source }
      let xCrop: Double
      let yCrop: Double
      if source.height > source.width {
        xCrop = parameters.borderCrop
        yCrop = parameters.borderCrop * Double(source.width) / Double(source.height)
      } else {
        yCrop = parameters.borderCrop
        xCrop = parameters.borderCrop * Double(source.height) / Double(source.width)
      }
      var result = PixelDimensions(
        width: max(1, Int(rect.width * (1 - yCrop / 100))),
        height: max(1, Int(rect.height * (1 - xCrop / 100))))
      if rect.angle > 45 {
        result = PixelDimensions(width: result.height, height: result.width)
      }
      return result
    }
    return source
  }
}
