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

  public static let fullFrame = NormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

  public enum Handle: Int, CaseIterable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
  }

  public var minX: Double { x }
  public var minY: Double { y }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }

  public func handlePosition(_ handle: Handle) -> (x: Double, y: Double) {
    switch handle {
    case .topLeft: (minX, minY)
    case .top: ((minX + maxX) / 2, minY)
    case .topRight: (maxX, minY)
    case .right: (maxX, (minY + maxY) / 2)
    case .bottomRight: (maxX, maxY)
    case .bottom: ((minX + maxX) / 2, maxY)
    case .bottomLeft: (minX, maxY)
    case .left: (minX, (minY + maxY) / 2)
    }
  }

  public func movingHandle(
    _ handle: Handle,
    to point: (x: Double, y: Double),
    minSize: Double = 0.02
  ) -> NormalizedCropRect {
    movingHandle(handle, to: point, minWidth: minSize, minHeight: minSize)
  }

  public func movingHandle(
    _ handle: Handle,
    to point: (x: Double, y: Double),
    minWidth: Double,
    minHeight: Double
  ) -> NormalizedCropRect {
    let px = min(max(point.x, 0), 1)
    let py = min(max(point.y, 0), 1)
    var nextMinX = minX
    var nextMinY = minY
    var nextMaxX = maxX
    var nextMaxY = maxY
    switch handle {
    case .topLeft:
      nextMinX = px
      nextMinY = py
    case .top: nextMinY = py
    case .topRight:
      nextMaxX = px
      nextMinY = py
    case .right: nextMaxX = px
    case .bottomRight:
      nextMaxX = px
      nextMaxY = py
    case .bottom: nextMaxY = py
    case .bottomLeft:
      nextMinX = px
      nextMaxY = py
    case .left: nextMinX = px
    }
    if nextMinX > nextMaxX { swap(&nextMinX, &nextMaxX) }
    if nextMinY > nextMaxY { swap(&nextMinY, &nextMaxY) }
    return NormalizedCropRect(
      x: nextMinX,
      y: nextMinY,
      width: nextMaxX - nextMinX,
      height: nextMaxY - nextMinY
    ).enforcingMinSize(
      minWidth: min(max(minWidth, 0.000_001), 1),
      minHeight: min(max(minHeight, 0.000_001), 1)
    )
  }

  public func translated(dx: Double, dy: Double) -> NormalizedCropRect {
    NormalizedCropRect(
      x: min(max(x + dx, 0), max(0, 1 - width)),
      y: min(max(y + dy, 0), max(0, 1 - height)),
      width: width,
      height: height
    )
  }

  private func enforcingMinSize(minWidth: Double, minHeight: Double) -> NormalizedCropRect {
    var nextMinX = minX
    var nextMinY = minY
    var nextMaxX = maxX
    var nextMaxY = maxY
    if nextMaxX - nextMinX < minWidth {
      let mid = (nextMinX + nextMaxX) / 2
      nextMinX = mid - minWidth / 2
      nextMaxX = mid + minWidth / 2
    }
    if nextMaxY - nextMinY < minHeight {
      let mid = (nextMinY + nextMaxY) / 2
      nextMinY = mid - minHeight / 2
      nextMaxY = mid + minHeight / 2
    }
    nextMinX = max(0, nextMinX)
    nextMinY = max(0, nextMinY)
    nextMaxX = min(1, nextMaxX)
    nextMaxY = min(1, nextMaxY)
    if nextMaxX - nextMinX < minWidth {
      if nextMinX <= 0 {
        nextMinX = 0
        nextMaxX = minWidth
      } else {
        nextMaxX = 1
        nextMinX = 1 - minWidth
      }
    }
    if nextMaxY - nextMinY < minHeight {
      if nextMinY <= 0 {
        nextMinY = 0
        nextMaxY = minHeight
      } else {
        nextMaxY = 1
        nextMinY = 1 - minHeight
      }
    }
    return NormalizedCropRect(
      x: nextMinX, y: nextMinY, width: nextMaxX - nextMinX, height: nextMaxY - nextMinY)
  }
}

public enum ImageGeometry {
  public enum StraightenAxis: Equatable, Sendable {
    case horizontal
    case vertical
  }

  /// Angle to add to `straightenAngle` so this segment becomes axis-aligned.
  /// Screen Y grows downward, so a line that slopes down to the right is a
  /// positive (clockwise) tilt. Positive values rotate the image
  /// counterclockwise because processing applies `-straightenAngle` clockwise.
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
      let bounds = pixelBounds(
        for: crop, imageWidth: dimensions.width, imageHeight: dimensions.height)
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
    let widthSpan =
      Double(max(0, source.width - 1)) * cosine
      + Double(max(0, source.height - 1)) * sine
    let heightSpan =
      Double(max(0, source.width - 1)) * sine
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
    let maxX = min(
      imageWidth,
      max(
        minX + 1,
        Int(((crop.x + crop.width) * Double(imageWidth)).rounded(.up))))
    let maxY = min(
      imageHeight,
      max(
        minY + 1,
        Int(((crop.y + crop.height) * Double(imageHeight)).rounded(.up))))
    return (minX, minY, maxX - minX, maxY - minY)
  }

  private static func initialCropDimensions(
    source: PixelDimensions,
    parameters: ProcessingParameters
  ) -> PixelDimensions {
    if let crop = parameters.perspectiveCrop, crop.isValid {
      let inset = crop.inset(borderPercent: parameters.borderCrop)
      guard inset.isValid else { return source }
      let size = inset.outputPixelSize(imageWidth: source.width, imageHeight: source.height)
      return PixelDimensions(width: size.width, height: size.height)
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
      return PixelDimensions(
        width: max(1, Int(rect.width * (1 - yCrop / 100))),
        height: max(1, Int(rect.height * (1 - xCrop / 100))))
    }
    return source
  }
}
