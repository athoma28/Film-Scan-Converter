import CoreGraphics
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Preview overlay geometry")
struct PreviewOverlayGeometryTests {
  @Test("Aspect fit centers the image using the limiting dimension")
  func aspectFitRect() {
    #expect(
      PreviewOverlayGeometry.aspectFitRect(
        imageSize: CGSize(width: 2_000, height: 1_000),
        containerSize: CGSize(width: 1_000, height: 1_000)
      ) == CGRect(x: 0, y: 250, width: 1_000, height: 500)
    )
    #expect(
      PreviewOverlayGeometry.aspectFitRect(
        imageSize: CGSize(width: 0, height: 1_000),
        containerSize: CGSize(width: 1_000, height: 1_000)
      ) == .zero
    )
  }

  @Test("Point clamping keeps overlay input inside the displayed image")
  func clampedPoint() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
    #expect(
      PreviewOverlayGeometry.clampedPoint(CGPoint(x: -5, y: 100), to: rect)
        == CGPoint(x: 10, y: 70)
    )
    #expect(
      PreviewOverlayGeometry.clampedPoint(CGPoint(x: 40, y: 30), to: rect)
        == CGPoint(x: 40, y: 30)
    )
  }

  @Test("Perspective coordinates round-trip through every display orientation")
  func perspectiveRoundTrip() {
    let source = PerspectiveCrop.Point(x: 0.17, y: 0.73)

    for rotation in -1...4 {
      for flipHorizontally in [false, true] {
        let displayed = PreviewOverlayGeometry.displayedPoint(
          source,
          rotation: rotation,
          flipHorizontally: flipHorizontally
        )
        let roundTrip = PreviewOverlayGeometry.sourcePoint(
          fromDisplayed: PerspectiveCrop.Point(
            x: Double(displayed.x),
            y: Double(displayed.y)
          ),
          rotation: rotation,
          flipHorizontally: flipHorizontally
        )

        #expect(abs(roundTrip.x - source.x) < 1e-12)
        #expect(abs(roundTrip.y - source.y) < 1e-12)
      }
    }
  }

  @Test("Document lengths grow when zoomed out and shrink when zoomed in")
  func documentLengthCompensatesMagnification() {
    #expect(
      PreviewOverlayGeometry.documentLength(28, magnification: 1) == 28)
    #expect(
      abs(PreviewOverlayGeometry.documentLength(28, magnification: 0.25) - 112) < 0.001)
    #expect(
      abs(PreviewOverlayGeometry.documentLength(28, magnification: 2) - 14) < 0.001)
    #expect(
      PreviewOverlayGeometry.documentLength(2, magnification: 8, minimum: 1) == 1)
  }

  @Test("Normalized crop rects round-trip through document space")
  func cropRectRoundTrip() {
    let imageRect = CGRect(x: 10, y: 20, width: 200, height: 100)
    let crop = NormalizedCropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
    let document = PreviewOverlayGeometry.documentRect(for: crop, in: imageRect)
    #expect(abs(document.minX - 30) < 1e-9)
    #expect(abs(document.minY - 40) < 1e-9)
    #expect(abs(document.width - 100) < 1e-9)
    #expect(abs(document.height - 40) < 1e-9)

    let roundTrip = PreviewOverlayGeometry.normalizedCrop(for: document, in: imageRect)
    #expect(abs(roundTrip.x - crop.x) < 1e-12)
    #expect(abs(roundTrip.y - crop.y) < 1e-12)
    #expect(abs(roundTrip.width - crop.width) < 1e-12)
    #expect(abs(roundTrip.height - crop.height) < 1e-12)

    let point = PreviewOverlayGeometry.documentPoint((0.25, 0.75), in: imageRect)
    #expect(abs(point.x - 60) < 1e-9)
    #expect(abs(point.y - 95) < 1e-9)
    let normalized = PreviewOverlayGeometry.normalizedPoint(point, in: imageRect)
    #expect(abs(normalized.x - 0.25) < 1e-12)
    #expect(abs(normalized.y - 0.75) < 1e-12)
  }

  @Test("A new crop rectangle starts outside the existing handles")
  func cropCanvasDragIgnoresHandleHits() {
    let imageRect = CGRect(x: 10, y: 20, width: 200, height: 100)
    let crop = NormalizedCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
    let handlePadding: CGFloat = 8
    let topLeft = PreviewOverlayGeometry.documentPoint(crop.handlePosition(.topLeft), in: imageRect)
    let interior = PreviewOverlayGeometry.documentPoint((0.4, 0.45), in: imageRect)
    let outside = PreviewOverlayGeometry.documentPoint((0.9, 0.9), in: imageRect)

    #expect(
      !PreviewOverlayGeometry.cropCanvasDragReplacesExisting(
        start: topLeft, crop: crop, imageRect: imageRect, handleHitPadding: handlePadding))
    #expect(
      !PreviewOverlayGeometry.cropCanvasDragReplacesExisting(
        start: interior, crop: crop, imageRect: imageRect, handleHitPadding: handlePadding))
    #expect(
      PreviewOverlayGeometry.cropCanvasDragReplacesExisting(
        start: outside, crop: crop, imageRect: imageRect, handleHitPadding: handlePadding))
  }

  @Test("Viewport gesture points convert to document pixels at every zoom")
  func gesturePointCompensatesMagnification() {
    let point = CGPoint(x: 48, y: 27)
    #expect(
      PreviewOverlayGeometry.documentGesturePoint(point, magnification: 1) == point)
    let fitPoint = PreviewOverlayGeometry.documentGesturePoint(point, magnification: 0.12)
    #expect(abs(fitPoint.x - 400) < 0.001)
    #expect(abs(fitPoint.y - 225) < 0.001)
    let zoomedPoint = PreviewOverlayGeometry.documentGesturePoint(point, magnification: 2)
    #expect(abs(zoomedPoint.x - 24) < 0.001)
    #expect(abs(zoomedPoint.y - 13.5) < 0.001)
  }

  @Test("Crop handle routing chooses only a nearby handle")
  func cropHandleRouting() {
    let imageRect = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let crop = NormalizedCropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
    #expect(
      PreviewOverlayGeometry.nearestCropHandle(
        to: CGPoint(x: 108, y: 166), crop: crop, imageRect: imageRect, hitRadius: 12)
        == .topLeft)
    #expect(
      PreviewOverlayGeometry.nearestCropHandle(
        to: CGPoint(x: 450, y: 165), crop: crop, imageRect: imageRect, hitRadius: 12)
        == .top)
    #expect(
      PreviewOverlayGeometry.nearestCropHandle(
        to: CGPoint(x: 450, y: 400), crop: crop, imageRect: imageRect, hitRadius: 12)
        == nil)
  }

  @Test("Perspective routing chooses the nearest corner within its radius")
  func perspectiveCornerRouting() {
    let points = [
      CGPoint(x: 100, y: 100), CGPoint(x: 900, y: 100),
      CGPoint(x: 900, y: 700), CGPoint(x: 100, y: 700),
    ]
    #expect(
      PreviewOverlayGeometry.nearestPointIndex(
        to: CGPoint(x: 892, y: 106), points: points, hitRadius: 12) == 1)
    #expect(
      PreviewOverlayGeometry.nearestPointIndex(
        to: CGPoint(x: 500, y: 400), points: points, hitRadius: 12) == nil)
    #expect(
      PreviewOverlayGeometry.nearestPointIndex(
        to: .zero, points: [], hitRadius: 12) == nil)
  }
}
