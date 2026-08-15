import CoreGraphics
import FilmScanEngine

enum PreviewOverlayGeometry {
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

  private static func normalizedQuarterTurns(_ rotation: Int) -> Int {
    ((rotation % 4) + 4) % 4
  }
}
