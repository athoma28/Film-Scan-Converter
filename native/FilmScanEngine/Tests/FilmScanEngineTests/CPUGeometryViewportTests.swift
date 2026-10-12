import AppKit
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("CPU geometry viewport correction", .serialized)
struct CPUGeometryViewportTests {
  @Test("Visible pixels equal full CPU correction with immutable sensor analysis")
  func visiblePixelsMatchFull() throws {
    let source = CPUPreparationPerformanceTests.image(width: 320, height: 240)
    let rect = ImageRegion(x: 37, y: 29, width: 96, height: 80)
    for version in [2, 3, 4] {
      for base in [FilmBase.colorC41, .colorCyanMask, .blackAndWhite] {
        for perspective in [false, true] {
          var p = base.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
          p.photoAdjustments.schemaVersion = version
          p.straightenAngle = 2.7
          p.rotation = 1
          p.flip = true
          p.manualCrop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
          if perspective {
            p.perspectiveCrop = .init(
              topLeft: .init(x: 0.04, y: 0.05), topRight: .init(x: 0.94, y: 0.08),
              bottomRight: .init(x: 0.92, y: 0.95), bottomLeft: .init(x: 0.05, y: 0.92))
          }
          let cache = CPUPreviewPreparationCache(image: source)
          for ev in [-0.3, 0.2] {
            p.photoAdjustments.exposureEV = ev
            p.photoAdjustments.contrast = 0.15
            let full = FilmProcessing.correctedPreview(image: source, parameters: p)
            let viewport = try #require(
              cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: 64))
            #expect(viewport.detail == crop(full, to: rect))
            #expect(
              viewport.overview
                == full.resizedToFit(maxDimension: 2_048).resizedToFit(maxDimension: 64))
          }
          #expect(cache.geometryBuildCount == 1)
          #expect(cache.retainedGeometryByteCount > 0)
          #expect(
            cache.render(parameters: p)
              == FilmProcessing.correctedPreview(image: source, parameters: p))
          p.straightenAngle = -1.3
          let full = FilmProcessing.correctedPreview(image: source, parameters: p)
          let changed = try #require(
            cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: 64))
          #expect(changed.detail == crop(full, to: rect))
          #expect(
            changed.overview
              == full.resizedToFit(maxDimension: 2_048).resizedToFit(maxDimension: 64))
          #expect(cache.geometryBuildCount == 2)
        }
      }
    }
  }

  @Test("Overview bounds preserve exact sample coordinates and retain only requested pixels")
  func overviewBoundsAndBytes() throws {
    for size in [(2_053, 37), (47, 31)] {
      for channels in [1, 3] {
        var pixels = (0..<(size.0 * size.1 * channels)).map {
          UInt16(2_000 + ($0 * 7919) % 62_000)
        }
        for channel in 0..<channels { pixels[channel] = 0 }
        let source = UInt16Image(
          width: size.0, height: size.1, channels: channels, pixels: pixels)
        let base = channels == 1 ? FilmBase.blackAndWhite : .colorC41
        var p = base.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
        p.photoAdjustments.exposureEV = 0.3
        p.photoAdjustments.contrast = 0.2
        p.photoAdjustments.saturation = 0.15
        p.filmDyeMixing.blueFromRed = 0.12
        p.highlightWheel = .init(hue: 45, strength: 0.2)
        p.curveEnabled = true
        p.curveControlPoints = [
          .init(input: 0, output: 0.03), .init(input: 0.5, output: 0.46),
          .init(input: 1, output: 0.97),
        ]
        #expect(p.filmNegativeParams.measuredMedians == nil)
        let full = FilmProcessing.correctedPreview(image: source, parameters: p)
        let cache = CPUPreviewPreparationCache(image: source)
        let rect = ImageRegion(x: 0, y: 0, width: 32, height: 12)
        for bound in [1, 513, 1_024, 2_048, 4_096, 8_192, 1_024, 1_024] {
          let expected = full.resizedToFit(maxDimension: 2_048).resizedToFit(maxDimension: bound)
          let viewport = try #require(
            cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: bound))
          #expect(viewport.overview == expected)
          #expect(viewport.detail == crop(full, to: rect))
          // With identity geometry an unchanged-size overview shares source storage.
          let sharesSource = expected.width == source.width && expected.height == source.height
          let expectedBytes =
            sharesSource
            ? 0
            : expected.width * expected.height * channels * MemoryLayout<UInt16>.stride
          #expect(cache.retainedGeometryByteCount == expectedBytes)
          #expect(cache.geometryBuildCount == 1)
          if size.0 == 2_053, bound == 1_024 {
            // Direct sampling would give 1024x18 and change the existing raster.
            #expect(viewport.overview.width == 1_024 && viewport.overview.height == 19)
          }
        }
      }
    }
  }

  @Test("Viewport sampling preserves calibrated, power-law, disabled, and positive rendering")
  func viewportRenderingModes() throws {
    let source = CPUPreparationPerformanceTests.image(width: 79, height: 61)
    let cache = CPUPreviewPreparationCache(image: source)
    let modes: [(FilmType, FilmNegativeParams)] = [
      (.colourNegative, .colourNegative),
      (.colourNegative, .legacyColourNegative),
      (.blackAndWhiteNegative, .blackAndWhite),
      (.blackAndWhiteNegative, .legacyBlackAndWhite),
      (.colourNegative, .init(enabled: false)),
      (.blackAndWhiteNegative, .init(enabled: false)),
      (.slide, .init(enabled: false)),
    ]
    let regions = [
      ImageRegion(x: 0, y: 0, width: source.width, height: source.height),
      ImageRegion(x: source.width - 1, y: source.height - 1, width: 1, height: 1),
    ]
    for version in 2...4 {
      for (filmType, inversion) in modes {
        let parameters = ProcessingParameters(
          filmType: filmType, filmNegativeParams: inversion,
          photoAdjustments: .init(schemaVersion: version, exposureEV: 0.4, contrast: 0.2))
        #expect(parameters.filmNegativeParams.measuredMedians == nil)
        let full = FilmProcessing.correctedPreview(image: source, parameters: parameters)
        for region in regions {
          let viewport = try #require(
            cache.renderViewport(
              parameters: parameters, region: region, overviewMaximumDimension: 31))
          #expect(viewport.detail == crop(full, to: region))
          #expect(viewport.overview == full.resizedToFit(maxDimension: 31))
        }
      }
    }
    #expect(cache.geometryBuildCount == 1)
  }

  @Test("Viewport analysis invalidates across saved tone versions and resolved density edits")
  func viewportAnalysisInvalidation() throws {
    let source = CPUPreparationPerformanceTests.image(width: 79, height: 61)
    let cache = CPUPreviewPreparationCache(image: source)
    var parameters = FilmBase.colorC41.applyingInvert(
      to: ProcessingParameters(photoAdjustments: .init(schemaVersion: 1)))
    parameters.manualCrop = .init(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
    #expect(
      cache.render(parameters: parameters)
        == FilmProcessing.correctedPreview(image: source, parameters: parameters))
    let region = ImageRegion(x: 3, y: 7, width: 13, height: 11)
    var expectedAnalyses = 1
    for version in [2, 3, 4, 2] {
      parameters.photoAdjustments.schemaVersion = version
      for strength in [0.1, 0.6] {
        parameters.filmNegativeParams.densityUnmixStrength = strength
        let full = FilmProcessing.correctedPreview(image: source, parameters: parameters)
        let viewport = try #require(
          cache.renderViewport(
            parameters: parameters, region: region, overviewMaximumDimension: 31))
        #expect(viewport.detail == crop(full, to: region))
        #expect(viewport.overview == full.resizedToFit(maxDimension: 31))
        expectedAnalyses += 1
        #expect(cache.analysisBuildCount == expectedAnalyses)
        #expect(cache.geometryBuildCount == 1)
      }
    }
  }

  @Test("Legacy and sensor-space density paths retain complete rendering")
  func unsupportedCases() {
    let source = CPUPreparationPerformanceTests.image(width: 64, height: 48)
    let cache = CPUPreviewPreparationCache(image: source)
    var p = FilmBase.colorC41.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
    let rect = ImageRegion(x: 1, y: 1, width: 16, height: 16)
    p.photoAdjustments.schemaVersion = 1
    #expect(cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: 32) == nil)
    p.photoAdjustments.schemaVersion = 4
    p.densityPipelineEnabled = true
    #expect(cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: 32) == nil)
    p.densityPipelineEnabled = false
    #expect(cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: 0) == nil)
    #expect(cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: -1) == nil)
    for invalidRegion in [
      ImageRegion(x: -1, y: 0, width: 16, height: 16),
      ImageRegion(x: 0, y: -1, width: 16, height: 16),
      ImageRegion(x: 0, y: 0, width: 0, height: 16),
      ImageRegion(x: 0, y: 0, width: 16, height: -1),
      ImageRegion(x: source.width, y: 0, width: 1, height: 1),
      ImageRegion(x: 0, y: source.height, width: 1, height: 1),
      ImageRegion(x: source.width - 1, y: 0, width: 2, height: 1),
      ImageRegion(x: 0, y: source.height - 1, width: 1, height: 2),
      ImageRegion(x: Int.max, y: 0, width: 1, height: 1),
    ] {
      #expect(
        cache.renderViewport(
          parameters: p, region: invalidRegion, overviewMaximumDimension: 32) == nil)
    }
    p.filmType = .cropOnly
    #expect(cache.renderViewport(parameters: p, region: rect, overviewMaximumDimension: 32) == nil)
  }

  @Test("Geometry gestures show exact visible detail then refine to the complete CPU raster")
  @MainActor
  func appRefinesGeometryViewport() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cpu-viewport-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let input = work.appendingPathComponent("scan.tiff")
    try CPUPreparationPerformanceTests.image(width: 512, height: 384).write(
      to: input, format: .tiff, parameters: .init())
    let suite = "cpu-viewport-\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
    model.setFilmBase(.colorC41)
    model.setStraightenAngle(2.7)
    try await waitUntil { !model.isRendering }
    let size = try #require(model.previewImage?.size)
    let demand = PreviewRenderDemand(
      documentSize: size, visibleRect: CGRect(x: 120, y: 90, width: 100, height: 80),
      backingScale: 2, magnification: 1)
    model.setPreviewRenderDemand(demand)
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.3)
    try await waitUntil { !model.isRendering && model.previewDetail != nil }
    #expect(model.status.contains("CPU viewport"))
    let detail = try #require(model.previewDetail.flatMap { PreviewBitmap.cgImage(from: $0.image) })
    let rect = try #require(demand.detailRect)
    #expect(detail.width == Int(rect.width) && detail.height == Int(rect.height))
    model.endEditingGesture()
    try await waitUntil { !model.isRendering && model.previewDetail == nil }
    let full = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    #expect(full.width == Int(size.width) && full.height == Int(size.height))
    #expect(model.publishedPreviewParameters == model.parameters)
    let expected = try #require(full.cropping(to: rect))
    #expect(try rgba(detail) == rgba(expected))
  }

  private func crop(_ image: UInt16Image, to rect: ImageRegion) -> UInt16Image {
    var pixels = [UInt16]()
    for y in rect.y..<(rect.y + rect.height) {
      let start = (y * image.width + rect.x) * image.channels
      pixels.append(contentsOf: image.pixels[start..<(start + rect.width * image.channels)])
    }
    return UInt16Image(
      width: rect.width, height: rect.height, channels: image.channels, pixels: pixels)
  }

  private func rgba(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(
      CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
