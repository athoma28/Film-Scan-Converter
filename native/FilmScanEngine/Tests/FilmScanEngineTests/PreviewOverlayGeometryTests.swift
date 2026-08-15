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
}
