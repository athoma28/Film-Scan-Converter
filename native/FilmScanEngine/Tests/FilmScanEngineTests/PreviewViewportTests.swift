import CoreGraphics
import Testing
@testable import FilmScanConverterMac

@Suite("Preview viewport zoom")
struct PreviewViewportTests {
  @Test("Fit uses the limiting viewport dimension")
  func fitMagnification() {
    #expect(
      PreviewViewportZoom.fitMagnification(
        imageSize: CGSize(width: 2_000, height: 1_000),
        viewportSize: CGSize(width: 1_000, height: 800)) == 0.5)
    #expect(
      PreviewViewportZoom.fitMagnification(
        imageSize: CGSize(width: 1_000, height: 2_000),
        viewportSize: CGSize(width: 800, height: 1_000)) == 0.5)
  }

  @Test("Zoom steps are reversible and remain bounded")
  func boundedZoomSteps() {
    let zoomedIn = PreviewViewportZoom.steppedMagnification(from: 1, zoomingIn: true)
    #expect(zoomedIn == 1.25)
    #expect(
      PreviewViewportZoom.steppedMagnification(from: zoomedIn, zoomingIn: false) == 1)
    #expect(
      PreviewViewportZoom.steppedMagnification(from: 8, zoomingIn: true)
        == PreviewViewportZoom.maximumMagnification)
    #expect(
      PreviewViewportZoom.steppedMagnification(from: 0.02, zoomingIn: false)
        == PreviewViewportZoom.minimumMagnification)
  }

  @Test("Displayed percentages describe preview-pixel magnification")
  func zoomPercentage() {
    #expect(PreviewViewportZoom.percent(for: 1) == 100)
    #expect(PreviewViewportZoom.percent(for: 0.333) == 33)
    #expect(PreviewViewportZoom.percent(for: 2.005) == 201)
  }
}
