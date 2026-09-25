import CoreGraphics
import Dispatch
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanPreviewRenderer

@Suite("Still preview invariant reuse")
struct StillPreviewPerformanceTests {
  @Test("Darkroom analysis reuses resolved values through exposure and color edits")
  func darkroomAnalysisReusesInvariantValues() {
    let image = source()
    let cache = DensityPrintAnalysisCache()
    var computations = 0
    func analyze(_ parameters: ProcessingParameters) -> DensityPrintAnalysis {
      let profile = DensityPrintProcessing.resolvedProfile(from: parameters.filmNegativeParams)
      let paper = DensityPrintProcessing.resolvedPaper(from: parameters.filmNegativeParams)
      return cache.analysis(profile: profile, paper: paper) {
        computations += 1
        return DensityPrintProcessing.analyze(image: image, profile: profile, paper: paper)
      }
    }

    var parameters = ProcessingParameters(
      filmType: .colourNegative, filmNegativeParams: .densityPrintGenericC41)
    let initial = analyze(parameters)
    parameters.photoAdjustments.exposureEV = 1.2
    parameters.photoAdjustments.temperatureShiftMired = 24
    parameters.highlightWheel = ColorWheel(hue: 45, strength: 0.35)
    #expect(analyze(parameters) == initial)
    #expect(computations == 1)

    // An unknown ID resolves to the same bundled fallback; raw identifiers
    // should not force another analysis of identical effective values.
    parameters.filmNegativeParams.densityProfileID = "unrecognized-profile"
    #expect(analyze(parameters) == initial)
    #expect(computations == 1)
  }

  @Test("Darkroom cache invalidates edited profile and paper values and stays bounded")
  func darkroomAnalysisInvalidatesResolvedProfileAndPaper() {
    let image = source()
    let cache = DensityPrintAnalysisCache()
    var computations = 0
    func analyze(
      _ profile: NegativeDensityProfile, _ paper: DensityPaperProfile
    ) -> DensityPrintAnalysis {
      cache.analysis(profile: profile, paper: paper) {
        computations += 1
        return DensityPrintProcessing.analyze(image: image, profile: profile, paper: paper)
      }
    }

    let profile = NegativeDensityProfileCatalog.genericC41
    let paper = DensityPaperProfileCatalog.neutral
    let initial = analyze(profile, paper)
    var editedProfile = profile
    editedProfile.printGrade += 20
    #expect(analyze(editedProfile, paper) != initial)
    #expect(computations == 2)
    var editedPaper = paper
    editedPaper.dMax += 0.2
    let edited = analyze(editedProfile, editedPaper)
    #expect(edited.paperDMax == editedPaper.dMax)
    #expect(computations == 3)
    #expect(analyze(editedProfile, editedPaper) == edited)
    #expect(computations == 3)

    // Revisiting an older combination recomputes it: the cache retains one
    // small entry instead of growing with the user's adjustment history.
    #expect(analyze(profile, paper) == initial)
    #expect(computations == 4)
  }

  @Test("Concurrent Darkroom requests compute an invariant once")
  func darkroomAnalysisCoalescesConcurrentRequests() {
    let image = source()
    let cache = DensityPrintAnalysisCache()
    let counter = AnalysisCounter()
    let profile = NegativeDensityProfileCatalog.genericC41
    let paper = DensityPaperProfileCatalog.neutral
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      _ = cache.analysis(profile: profile, paper: paper) {
        counter.increment()
        return DensityPrintProcessing.analyze(image: image, profile: profile, paper: paper)
      }
    }
    #expect(counter.count == 1)
  }

  @Test("Retained Darkroom rendering matches a fresh renderer after edits and source upgrades")
  func darkroomCachedRendererMatchesFreshSources() throws {
    let image = source()
    let renderer = try #require(StillPreviewRenderer(image: image))
    var parameters = ProcessingParameters(
      filmType: .colourNegative, filmNegativeParams: .densityPrintGenericC41)
    _ = try #require(renderer.render(parameters: parameters, showOriginal: false))
    parameters.photoAdjustments.exposureEV = 0.75
    parameters.midtoneWheel = ColorWheel(hue: 205, strength: 0.2)
    try expectFreshPixels(renderer, image: image, parameters: parameters)
    parameters.filmNegativeParams.densityUnmixStrength = 0.25
    parameters.filmNegativeParams.densityUnmixRGB = [
      1.1, -0.1, 0, 0, 1.1, -0.1, -0.1, 0, 1.1,
    ]
    try expectFreshPixels(renderer, image: image, parameters: parameters)

    // A new renderer must analyze its own source even with identical settings.
    let upgraded = source(width: 59, height: 43)
    let upgradedRenderer = try #require(StillPreviewRenderer(image: upgraded))
    try expectFreshPixels(upgradedRenderer, image: upgraded, parameters: parameters)
    let gpu = try #require(upgradedRenderer.render(parameters: parameters, showOriginal: false))
    let cpu = try #require(
      FilmProcessing.correctedPreview(image: upgraded, parameters: parameters).makePreviewCGImage())
    let differences = zip(try pixels(gpu), try pixels(cpu)).map { abs(Int($0) - Int($1)) }
    #expect((differences.max() ?? 0) <= 2)
  }

  @Test("Renderer reports its retained RGBA backing independently of shared source arrays")
  func rendererAccountsForRetainedRGBABacking() throws {
    let image = source()
    let renderer = try #require(StillPreviewRenderer(image: image, analysisImage: image))
    #expect(renderer.retainedRGBAByteCount == image.width * image.height * 4 * 2)
    let other = try #require(
      StillPreviewRenderer(image: image, analysisImage: source(width: 8, height: 8)))
    #expect(other.retainedRGBAByteCount == renderer.retainedRGBAByteCount)
  }

  @Test(
    "GPU manual crop matches CPU orientation and outward pixel bounds", arguments: 0..<4,
    [false, true])
  func gpuManualCropMatchesCPU(rotation: Int, flip: Bool) throws {
    let image = source()
    let renderer = try #require(StillPreviewRenderer(image: image))
    let crops: [NormalizedCropRect] = [
      .init(x: 0.137, y: 0.219, width: 0.543, height: 0.612),
      .init(x: 0.811, y: 0.901, width: 0.189, height: 0.099),
      .fullFrame,
    ]
    for crop in crops {
      var parameters = ProcessingParameters(
        flip: flip, rotation: rotation, filmType: .colourNegative,
        photoAdjustments: .init(exposureEV: 0.6))
      parameters.manualCrop = crop
      #expect(StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
      let gpu = try #require(renderer.render(parameters: parameters, showOriginal: false))
      let cpuImage = FilmProcessing.correctedPreview(image: image, parameters: parameters)
      let cpu = try #require(cpuImage.makePreviewCGImage())
      let expectedDimensions = ImageGeometry.outputDimensions(
        source: .init(width: image.width, height: image.height), parameters: parameters)
      #expect(gpu.width == expectedDimensions.width)
      #expect(gpu.height == expectedDimensions.height)
      #expect(gpu.width == cpu.width)
      #expect(gpu.height == cpu.height)
      let differences = zip(try pixels(gpu), try pixels(cpu)).map { abs(Int($0) - Int($1)) }
      #expect((differences.max() ?? 0) <= 2)
    }
  }

  @Test("Manual-cropped Original and Darkroom preserve their CPU contracts")
  func gpuManualCropPreservesCPUFallbacks() throws {
    let renderer = try #require(StillPreviewRenderer(image: source()))
    var parameters = ProcessingParameters(filmType: .colourNegative)
    parameters.manualCrop = .init(x: 0.15, y: 0.1, width: 0.6, height: 0.7)
    #expect(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: true))
    #expect(renderer.render(parameters: parameters, showOriginal: true) == nil)
    parameters.filmType = .cropOnly
    #expect(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
    #expect(renderer.render(parameters: parameters, showOriginal: false) == nil)
    parameters.filmType = .colourNegative
    parameters.filmNegativeParams = .legacyColourNegative
    #expect(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
    parameters.filmNegativeParams.measuredMedians = .init(blue: 20_000, green: 25_000, red: 30_000)
    #expect(StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
    parameters.filmNegativeParams = .densityPrintGenericC41
    #expect(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
    #expect(renderer.render(parameters: parameters, showOriginal: false) == nil)
    parameters.manualCrop = nil
    #expect(StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
    parameters.perspectiveCrop = .init(
      topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1),
      bottomRight: .init(x: 0.9, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9))
    #expect(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
  }

  private func expectFreshPixels(
    _ renderer: StillPreviewRenderer,
    image: UInt16Image,
    parameters: ProcessingParameters
  ) throws {
    let fresh = try #require(StillPreviewRenderer(image: image))
    let cachedOutput = try #require(renderer.render(parameters: parameters, showOriginal: false))
    let freshOutput = try #require(fresh.render(parameters: parameters, showOriginal: false))
    #expect(try pixels(cachedOutput) == pixels(freshOutput))
  }

  private func source(width: Int = 47, height: Int = 31) -> UInt16Image {
    let values = (0..<(width * height * 3)).map { UInt16(3_000 + ($0 * 3571) % 57_000) }
    return UInt16Image(width: width, height: height, channels: 3, pixels: values)
  }

  private func pixels(_ image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data)
    let pointer = try #require(CFDataGetBytePtr(data))
    return (0..<image.height).flatMap { row in
      Array(UnsafeBufferPointer(start: pointer + row * image.bytesPerRow, count: image.width * 4))
    }
  }
}

private final class AnalysisCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    value += 1
  }
}
