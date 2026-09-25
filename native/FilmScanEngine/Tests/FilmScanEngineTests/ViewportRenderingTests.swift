import AppKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanPreviewRenderer

@Suite("Viewport-sized correction and revision-bound diagnostics", .serialized)
struct ViewportRenderingTests {
  @Test("Fit demand uses backing pixels while inspection selects a bounded region")
  func demandGeometry() {
    let size = CGSize(width: 7752, height: 5184)
    let fit = PreviewRenderDemand(
      documentSize: size,
      visibleRect: CGRect(origin: .zero, size: size), backingScale: 2, magnification: 0.15)
    #expect(fit.overviewMaximumDimension == 2326)
    #expect(fit.detailRect == nil)
    let inspect = PreviewRenderDemand(
      documentSize: size,
      visibleRect: CGRect(x: 2000, y: 1500, width: 1200, height: 800),
      backingScale: 2, magnification: 1)
    let detail = inspect.detailRect!
    #expect(detail.contains(CGRect(x: 2000, y: 1500, width: 1200, height: 800)))
    #expect(detail.width < 1500 && detail.height < 1100)
    #expect(inspect.overviewMaximumDimension == 1024)
    let edge = PreviewRenderDemand(
      documentSize: size,
      visibleRect: CGRect(x: -100, y: -50, width: 300, height: 200),
      backingScale: 2, magnification: 1)
    #expect(edge.detailRect?.minX == 0 && edge.detailRect?.minY == 0)
  }

  @Test("Normalizing 40 MP source rectangles does not add a pixel at grid boundaries")
  func regionRounding() {
    for width in [7752, 3876, 7731] {
      let extent = CGRect(x: 0, y: 0, width: width, height: 5184)
      for x in stride(from: 64, to: width - 256, by: 64) {
        let region = CGRect(
          x: Double(x) / Double(width), y: 128.0 / 5184,
          width: 256.0 / Double(width), height: 256.0 / 5184)
        #expect(
          StillPreviewRenderer.regionBounds(region, in: extent)
            == CGRect(x: x, y: 4800, width: 256, height: 256))
      }
    }
  }

  @Test("Visible-region rendering matches the same pixels of a complete corrected raster")
  func regionMatchesFull() throws {
    let source = CPUPreparationPerformanceTests.image(width: 320, height: 240)
    let renderer = try #require(StillPreviewRenderer(image: source))
    for rotation in 0..<4 {
      var p = ProcessingParameters(rotation: rotation, filmType: .colourNegative)
      p.filmNegativeParams.enabled = true
      p.filmNegativeParams.rendering = .calibratedColor
      p.photoAdjustments.exposureEV = 0.3
      let full = try #require(renderer.render(parameters: p, showOriginal: false))
      let rect = CGRect(x: 32, y: 48, width: 96, height: 80)
      let region = CGRect(
        x: rect.minX / CGFloat(full.width), y: rect.minY / CGFloat(full.height),
        width: rect.width / CGFloat(full.width), height: rect.height / CGFloat(full.height))
      let detail = try #require(
        renderer.render(parameters: p, showOriginal: false, normalizedRegion: region))
      let expected = try #require(full.cropping(to: rect))
      #expect(detail.width == expected.width && detail.height == expected.height)
      #expect(try rgba(detail) == rgba(expected))
      let fit = try #require(
        renderer.render(parameters: p, showOriginal: false, maximumDimension: 80))
      #expect(max(fit.width, fit.height) <= 80)
    }
  }

  @Test("Settled previews pan without correction work; active edits refine to a complete raster")
  @MainActor
  func appViewportAndStatistics() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
    let size = try #require(model.previewImage?.size)
    let demand = PreviewRenderDemand(
      documentSize: size,
      visibleRect: CGRect(
        x: size.width * 0.25, y: size.height * 0.2,
        width: size.width * 0.3, height: size.height * 0.3), backingScale: 2, magnification: 1)
    let revision = model.publishedRenderRevision
    let correctionCount = model.previewCorrectionCount
    model.setPreviewRenderDemand(demand)
    #expect(!model.isRendering)
    #expect(model.previewCorrectionCount == correctionCount)
    #expect(model.publishedRenderRevision == revision)
    #expect(model.previewDetail == nil)
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.05)
    try await waitUntil { !model.isRendering && model.previewDetail != nil }
    #expect(model.previewImage?.size == size)
    #expect(model.previewDetail?.rect == demand.detailRect)
    for value in [0.1, 0.2, 0.4] { model.setExposureEV(value) }
    model.endEditingGesture()
    try await waitUntil {
      !model.isRendering && model.previewStatisticsRevision == model.publishedRenderRevision
    }
    #expect(model.previewStatistics.sampleCount > 0)
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(model.previewDetail == nil)
    let full = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    #expect(full.width == Int(size.width) && full.height == Int(size.height))
  }

  private func rgba(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(
      CGContext(
        data: &bytes, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }

  @MainActor private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !ready() {
      if ContinuousClock.now >= deadline { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
