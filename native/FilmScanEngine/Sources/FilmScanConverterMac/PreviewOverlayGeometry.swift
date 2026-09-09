import CoreGraphics
import FilmScanEngine

enum PreviewOverlayGeometry {
  static let handleScreenLength: CGFloat = 28
  static let handleHitPadding: CGFloat = 10
  static let loupeScreenLength: CGFloat = 144
  static let assistScreenLength: CGFloat = 18
  static let straightenDotScreenLength: CGFloat = 12
  static let minStraightenScreenLength: CGFloat = 8
  static let minCropScreenLength: CGFloat = 4
  static let cropHandleScreenLength: CGFloat = 14
  static let strokeScreenLength: CGFloat = 2

  static func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

    let scale = min(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height
    )
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: (containerSize.width - size.width) / 2,
      y: (containerSize.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  static func documentRect(
    for crop: NormalizedCropRect,
    in imageRect: CGRect
  ) -> CGRect {
    CGRect(
      x: imageRect.minX + crop.x * imageRect.width,
      y: imageRect.minY + crop.y * imageRect.height,
      width: crop.width * imageRect.width,
      height: crop.height * imageRect.height
    )
  }

  static func normalizedCrop(
    for rect: CGRect,
    in imageRect: CGRect
  ) -> NormalizedCropRect {
    NormalizedCropRect(
      x: (rect.minX - imageRect.minX) / imageRect.width,
      y: (rect.minY - imageRect.minY) / imageRect.height,
      width: rect.width / imageRect.width,
      height: rect.height / imageRect.height
    )
  }

  /// Uses the same constraint for the drag reticle and its committed rectangle.
  /// The ratio is in normalized canvas coordinates, derived from output pixels.
  static func drawnCropRect(
    from start: CGPoint, to end: CGPoint, in imageRect: CGRect, aspectRatio: Double?
  ) -> CGRect {
    let start = clampedPoint(start, to: imageRect)
    let end = clampedPoint(end, to: imageRect)
    let freeRect = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y))
    guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0,
      imageRect.width > 0, imageRect.height > 0
    else { return freeRect }
    let ratio = aspectRatio * imageRect.width / imageRect.height
    let growsRight = end.x >= start.x
    let growsDown = end.y >= start.y
    let availableWidth = growsRight ? imageRect.maxX - start.x : start.x - imageRect.minX
    let availableHeight = growsDown ? imageRect.maxY - start.y : start.y - imageRect.minY
    let width = min(
      availableWidth, availableHeight * ratio, max(freeRect.width, freeRect.height * ratio))
    let height = width / ratio
    return CGRect(
      x: growsRight ? start.x : start.x - width,
      y: growsDown ? start.y : start.y - height,
      width: width, height: height)
  }

  static func documentPoint(
    _ point: (x: Double, y: Double),
    in imageRect: CGRect
  ) -> CGPoint {
    CGPoint(
      x: imageRect.minX + point.x * imageRect.width,
      y: imageRect.minY + point.y * imageRect.height
    )
  }

  static func normalizedPoint(
    _ point: CGPoint,
    in imageRect: CGRect
  ) -> (x: Double, y: Double) {
    (
      (point.x - imageRect.minX) / imageRect.width,
      (point.y - imageRect.minY) / imageRect.height
    )
  }

  /// Replacement drags start in the dimmed area outside the crop, including a
  /// handle-sized margin so edge handles are not stolen by a new rectangle.
  static func cropCanvasDragReplacesExisting(
    start: CGPoint,
    crop: NormalizedCropRect,
    imageRect: CGRect,
    handleHitPadding: CGFloat
  ) -> Bool {
    let existing = documentRect(for: crop, in: imageRect)
    let handleRegion = existing.insetBy(dx: -handleHitPadding, dy: -handleHitPadding)
    return !handleRegion.contains(start)
  }

  static func clampedPoint(_ point: CGPoint, to rect: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(point.x, rect.minX), rect.maxX),
      y: min(max(point.y, rect.minY), rect.maxY)
    )
  }

  static func displayedPoint(
    _ point: PerspectiveCrop.Point,
    rotation: Int,
    flipHorizontally: Bool
  ) -> CGPoint {
    let turns = normalizedQuarterTurns(rotation)
    var result: CGPoint
    switch turns {
    case 1: result = CGPoint(x: 1 - point.y, y: point.x)
    case 2: result = CGPoint(x: 1 - point.x, y: 1 - point.y)
    case 3: result = CGPoint(x: point.y, y: 1 - point.x)
    default: result = CGPoint(x: point.x, y: point.y)
    }
    if flipHorizontally { result.x = 1 - result.x }
    return result
  }

  static func sourcePoint(
    fromDisplayed point: PerspectiveCrop.Point,
    rotation: Int,
    flipHorizontally: Bool
  ) -> PerspectiveCrop.Point {
    let displayX = flipHorizontally ? 1 - point.x : point.x
    switch normalizedQuarterTurns(rotation) {
    case 1: return .init(x: point.y, y: 1 - displayX)
    case 2: return .init(x: 1 - displayX, y: 1 - point.y)
    case 3: return .init(x: 1 - point.y, y: displayX)
    default: return .init(x: displayX, y: point.y)
    }
  }

  /// Converts a screen-pixel length into document pixels so handles, strokes,
  /// and snap distances stay the same size on screen as the preview zooms.
  static func documentLength(
    _ screenLength: CGFloat,
    magnification: CGFloat,
    minimum: CGFloat = 1
  ) -> CGFloat {
    max(minimum, screenLength / max(magnification, 0.02))
  }

  /// SwiftUI drag locations embedded in a magnifying `NSScrollView` arrive in
  /// viewport points even though the overlay is laid out in document pixels.
  static func documentGesturePoint(
    _ point: CGPoint,
    magnification: CGFloat
  ) -> CGPoint {
    let scale = max(magnification, 0.02)
    return CGPoint(x: point.x / scale, y: point.y / scale)
  }

  static func nearestCropHandle(
    to point: CGPoint,
    crop: NormalizedCropRect,
    imageRect: CGRect,
    hitRadius: CGFloat
  ) -> NormalizedCropRect.Handle? {
    NormalizedCropRect.Handle.allCases.min { first, second in
      distance(
        from: point,
        to: documentPoint(crop.handlePosition(first), in: imageRect))
        < distance(
          from: point,
          to: documentPoint(crop.handlePosition(second), in: imageRect))
    }.flatMap { handle in
      distance(
        from: point,
        to: documentPoint(crop.handlePosition(handle), in: imageRect)) <= hitRadius
        ? handle : nil
    }
  }

  static func nearestPointIndex(
    to point: CGPoint,
    points: [CGPoint],
    hitRadius: CGFloat
  ) -> Int? {
    points.indices.min { first, second in
      distance(from: point, to: points[first]) < distance(from: point, to: points[second])
    }.flatMap { index in
      distance(from: point, to: points[index]) <= hitRadius ? index : nil
    }
  }

  private static func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
  }

  private static func normalizedQuarterTurns(_ rotation: Int) -> Int {
    ((rotation % 4) + 4) % 4
  }
}
