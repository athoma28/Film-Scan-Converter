import Foundation

/// A manual-crop constraint. The saved rectangle remains the pixel-processing
/// authority; this choice controls subsequent edits without adding export padding.
public enum CropAspectRatio: String, Codable, CaseIterable, Sendable {
  case free = "Free"
  case square = "1:1"
  case landscape3x2 = "3:2"
  case portrait2x3 = "2:3"
  case landscape4x3 = "4:3"
  case portrait3x4 = "3:4"
  case landscape5x4 = "5:4"
  case portrait4x5 = "4:5"
  case landscape16x9 = "16:9"
  case portrait9x16 = "9:16"

  public var value: Double? {
    switch self {
    case .free: nil
    case .square: 1
    case .landscape3x2: 3.0 / 2
    case .portrait2x3: 2.0 / 3
    case .landscape4x3: 4.0 / 3
    case .portrait3x4: 3.0 / 4
    case .landscape5x4: 5.0 / 4
    case .portrait4x5: 4.0 / 5
    case .landscape16x9: 16.0 / 9
    case .portrait9x16: 9.0 / 16
    }
  }

  /// Normalized x and y span different pixel counts on a non-square canvas.
  public func normalizedRatio(in canvas: PixelDimensions) -> Double? {
    guard let value, canvas.width > 0, canvas.height > 0 else { return nil }
    return value * Double(canvas.height) / Double(canvas.width)
  }
}

extension NormalizedCropRect {
  /// Keeps the center and fits entirely within this rectangle.
  public func fitted(toAspectRatio ratio: Double) -> Self {
    guard isValid, ratio.isFinite, ratio > 0 else { return self }
    if abs(width / height - ratio) <= ratio * 1e-12 { return self }
    let fittedWidth = width / height > ratio ? height * ratio : width
    let fittedHeight = width / height > ratio ? height : width / ratio
    return Self(
      x: x + (width - fittedWidth) / 2, y: y + (height - fittedHeight) / 2,
      width: fittedWidth, height: fittedHeight)
  }

  /// Corners keep the opposite corner fixed. Edge handles keep the opposite
  /// edge's midpoint fixed and grow symmetrically across its perpendicular axis.
  /// Bounds take precedence over minimum size when the anchor is near an edge.
  public func movingHandle(
    _ handle: Handle, to point: (x: Double, y: Double),
    minWidth: Double, minHeight: Double, aspectRatio ratio: Double
  ) -> Self {
    guard isValid, ratio.isFinite, ratio > 0, point.x.isFinite, point.y.isFinite else {
      return self
    }
    let direction: (x: Double, y: Double)
    switch handle {
    case .topLeft: direction = (-1, -1)
    case .top: direction = (0, -1)
    case .topRight: direction = (1, -1)
    case .right: direction = (1, 0)
    case .bottomRight: direction = (1, 1)
    case .bottom: direction = (0, 1)
    case .bottomLeft: direction = (-1, 1)
    case .left: direction = (-1, 0)
    }
    let anchor = (
      x: direction.x < 0 ? maxX : direction.x > 0 ? minX : (minX + maxX) / 2,
      y: direction.y < 0 ? maxY : direction.y > 0 ? minY : (minY + maxY) / 2
    )
    let availableWidth =
      direction.x == 0
      ? 2 * min(anchor.x, 1 - anchor.x)
      : direction.x < 0 ? anchor.x : 1 - anchor.x
    let availableHeight =
      direction.y == 0
      ? 2 * min(anchor.y, 1 - anchor.y)
      : direction.y < 0 ? anchor.y : 1 - anchor.y
    let requestedWidth = max(0, (point.x - anchor.x) * direction.x)
    let requestedHeight = max(0, (point.y - anchor.y) * direction.y)
    let requestedSize: Double
    if direction.x == 0 {
      requestedSize = requestedHeight * ratio
    } else if direction.y == 0 {
      requestedSize = requestedWidth
    } else {
      // Follow the axis with the larger size change. Taking the larger size
      // itself would ignore an inward drag along just one axis of a corner.
      requestedSize =
        abs(requestedWidth - self.width) >= abs(requestedHeight * ratio - self.width)
        ? requestedWidth : requestedHeight * ratio
    }
    let width = min(
      availableWidth, availableHeight * ratio,
      max(requestedSize, minWidth, minHeight * ratio, 1e-9))
    let height = width / ratio
    guard width > 0, height > 0 else { return self }
    return Self(
      x: anchor.x - (direction.x < 0 ? width : direction.x == 0 ? width / 2 : 0),
      y: anchor.y - (direction.y < 0 ? height : direction.y == 0 ? height / 2 : 0),
      width: width, height: height)
  }
}
