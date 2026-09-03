import AppKit
import SwiftUI
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

@Suite("Native preview scroll view", .serialized)
@MainActor
struct PreviewScrollViewTests {
  @Test(
    "A panned view retains its photo region through draft, inspect, and full-resolution upgrades")
  func resolutionUpgradesPreservePan() {
    let coordinator = PreviewViewport<Color>.Coordinator(rootView: .black) { _, _ in }
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    scrollView.layoutSubtreeIfNeeded()
    var size = CGSize(width: 640, height: 426)
    coordinator.updateDocumentSize(size, previousVisibleRect: .zero, previousMagnification: 1)
    coordinator.apply(.init(sequence: 0, action: .actualSize))
    scrollView.setMagnification(3, centeredAt: CGPoint(x: 390, y: 250))
    let initial = normalizedVisibleRect(scrollView, size: size)
    #expect(initial.minX > 0.1)
    #expect(initial.minY > 0.1)

    for nextSize in [CGSize(width: 3_876, height: 2_580), CGSize(width: 7_728, height: 5_152)] {
      coordinator.updateDocumentSize(
        nextSize, previousVisibleRect: scrollView.documentVisibleRect,
        previousMagnification: scrollView.magnification)
      scrollView.layoutSubtreeIfNeeded()
      size = nextSize
      let visible = normalizedVisibleRect(scrollView, size: size)
      #expect(abs(visible.midX - initial.midX) < 0.005)
      #expect(abs(visible.midY - initial.midY) < 0.005)
      #expect(abs(visible.width - initial.width) < 0.005)
      #expect(abs(visible.height - initial.height) < 0.005)
    }

    let beforeComparison = scrollView.documentVisibleRect
    coordinator.hostingView.rootView = .white
    coordinator.updateDocumentSize(
      size, previousVisibleRect: beforeComparison,
      previousMagnification: scrollView.magnification)
    #expect(scrollView.documentVisibleRect == beforeComparison)

    coordinator.apply(.init(sequence: 1, action: .fit))
    #expect(abs(scrollView.magnification - 600 / size.width) < 0.001)
  }

  @Test("Fit follows window resize and pinch leaves fit mode")
  func fitResizeAndPinch() async throws {
    var reports: [(percent: Int, isFit: Bool)] = []
    let coordinator = PreviewViewport<Color>.Coordinator(rootView: .black) { percent, isFit in
      reports.append((percent, isFit))
    }
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    scrollView.layoutSubtreeIfNeeded()
    let size = CGSize(width: 2_000, height: 1_000)
    coordinator.updateDocumentSize(size, previousVisibleRect: .zero, previousMagnification: 1)
    coordinator.apply(.init(sequence: 0, action: .fit))
    #expect(abs(scrollView.magnification - 0.4) < 0.001)
    scrollView.frame.size = CGSize(width: 1_000, height: 700)
    scrollView.layoutSubtreeIfNeeded()
    #expect(abs(scrollView.magnification - 0.5) < 0.001)

    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
    scrollView.setMagnification(1.5, centeredAt: CGPoint(x: 1_200, y: 600))
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    scrollView.frame.size = CGSize(width: 900, height: 600)
    scrollView.layoutSubtreeIfNeeded()
    #expect(scrollView.magnification == 1.5)
    coordinator.apply(.init(sequence: 1, action: .actualSize))
    #expect(scrollView.magnification == 1)
    let deadline = ContinuousClock.now + .seconds(2)
    while reports.last?.percent != 100 {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reports.map(\.percent) == [40, 50, 150, 100])
    #expect(reports.map(\.isFit) == [true, true, false, false])
  }

  private func normalizedVisibleRect(_ scrollView: NSScrollView, size: CGSize) -> CGRect {
    let visible = scrollView.documentVisibleRect
    return CGRect(
      x: visible.minX / size.width, y: visible.minY / size.height,
      width: visible.width / size.width, height: visible.height / size.height)
  }
}
