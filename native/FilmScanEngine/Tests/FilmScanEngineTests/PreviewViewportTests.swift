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

  @Test("Resolution pop-in keeps the same photo crop instead of preview-pixel zoom")
  func documentRemapPreservesVisibleRegion() {
    let previousSize = CGSize(width: 640, height: 427)
    let newSize = CGSize(width: 4_000, height: 2_669)
    let visible = CGRect(x: 180, y: 90, width: 320, height: 214)

    let magnification = PreviewViewportDocumentRemap.magnification(
      from: previousSize,
      to: newSize,
      magnification: 2)
    let expectedScale = min(640.0 / 4_000.0, 427.0 / 2_669.0)
    #expect(abs(magnification - 2 * expectedScale) < 0.0001)

    let center = PreviewViewportDocumentRemap.center(
      visibleRect: visible,
      from: previousSize,
      to: newSize)
    #expect(abs(center.x - 340.0 * 4_000.0 / 640.0) < 0.001)
    #expect(abs(center.y - 197.0 * 2_669.0 / 427.0) < 0.001)
  }

  @Test("Remapping an origin-sized visible rect does not stay pinned to the corner")
  func documentRemapUsesCapturedVisibleRect() {
    let previousSize = CGSize(width: 640, height: 427)
    let newSize = CGSize(width: 4_000, height: 2_669)
    let alreadyResetVisible = CGRect(x: 0, y: 0, width: 200, height: 134)
    let capturedVisible = CGRect(x: 180, y: 90, width: 320, height: 214)

    let resetCenter = PreviewViewportDocumentRemap.center(
      visibleRect: alreadyResetVisible,
      from: previousSize,
      to: newSize)
    let preservedCenter = PreviewViewportDocumentRemap.center(
      visibleRect: capturedVisible,
      from: previousSize,
      to: newSize)

    #expect(resetCenter.x < 700)
    #expect(resetCenter.y < 500)
    #expect(preservedCenter.x > 2_000)
    #expect(preservedCenter.y > 1_000)
  }
}
