import CoreGraphics
import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Bounded factory look previews", .serialized)
struct PresetPreviewTests {
  @Test("Factory tiles use production pixels and preserve local geometry and calibration")
  func productionPixels() throws {
    let source = image(width: 144, height: 96)
    for density in [false, true] {
      var parameters = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
      parameters.rotation = 1
      parameters.flip = true
      parameters.straightenAngle = 2.3
      parameters.manualCrop = .init(x: 0.08, y: 0.12, width: 0.8, height: 0.75)
      parameters.perspectiveCrop = .init(
        topLeft: .init(x: 0.04, y: 0.05), topRight: .init(x: 0.94, y: 0.08),
        bottomRight: .init(x: 0.92, y: 0.95), bottomLeft: .init(x: 0.05, y: 0.92))
      parameters.filmNegativeParams.measuredMedians = .init(blue: 0.2, green: 0.35, red: 0.5)
      parameters.dustRepairs = [
        .init(points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.6, 0.5))
      ]
      if density {
        parameters.densityPipelineEnabled = true
        parameters.filmNegativeParams.rendering = .powerLaw
        parameters.densityBaseDensity = .init(blue: 0.1, green: 0.2, red: 0.3)
      }
      let field = density ? image(width: 144, height: 96) : nil
      let original = parameters
      let request = request(source: source, parameters: parameters, flatField: field)
      guard case .completed(let batch) = PresetPreviewRenderer.render(request, budget: .seconds(10))
      else {
        Issue.record("Production strip did not complete")
        return
      }
      #expect(batch.thumbnails.map(\.id) == LookRecipe.factory.map(\.id))
      #expect(parameters == original)
      for tile in batch.thumbnails {
        let expected = try #require(
          FilmProcessing.correctedPreview(
            image: source, parameters: tile.recipe.applying(to: parameters), flatField: field
          ).resizedToFit(maxDimension: PresetPreviewRenderer.maximumDimension).makePreviewCGImage())
        #expect(tile.image.width == expected.width)
        #expect(tile.image.height == expected.height)
        #expect(bytes(tile.image) == bytes(expected))
      }
    }
  }

  @Test("Small tiles retain the full sensor's inversion analysis")
  func immutableSensorAnalysis() throws {
    let source = image(width: 320, height: 240)
    for base in [FilmBase.colorC41, .blackAndWhite] {
      let parameters = base.applyingInvert(to: ProcessingParameters(borderCrop: 0))
      let request = request(source: source, parameters: parameters)
      guard case .completed(let batch) = PresetPreviewRenderer.render(request, budget: .seconds(10))
      else {
        Issue.record("Analysis strip did not complete")
        return
      }
      for tile in batch.thumbnails.prefix(2) {
        let expected = try #require(
          FilmProcessing.correctedPreview(
            image: source, parameters: tile.recipe.applying(to: parameters)
          ).resizedToFit(maxDimension: PresetPreviewRenderer.maximumDimension).makePreviewCGImage())
        #expect(bytes(tile.image) == bytes(expected))
      }
    }
  }

  @Test("Keys change for local settings and sources, but not replaced look controls")
  func invalidationKey() {
    let parameters = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
    let initial = request(parameters: parameters).key
    #expect(request(parameters: LookRecipe.warm.applying(to: parameters)).key == initial)
    var framed = parameters
    framed.rotation = 1
    #expect(request(parameters: framed).key != initial)
    var calibrated = parameters
    calibrated.filmNegativeParams.measuredMedians = .init(blue: 0.2, green: 0.3, red: 0.4)
    #expect(request(parameters: calibrated).key != initial)
    #expect(request(parameters: parameters, sourceGeneration: 2).key != initial)
  }

  @Test("A depleted budget produces no partial strip")
  func depletedBudget() {
    guard case .budgetExceeded = PresetPreviewRenderer.render(request(), budget: .zero) else {
      Issue.record("A zero budget must reject the complete strip")
      return
    }
  }

  @Test("App requests retain the selected source and invalidate only relevant changes")
  @MainActor
  func appRequestInvalidation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fsc-preset-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "fsc-preset-preview-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory), preferences: preferences,
      previewMemoryBudget: 1)
    defer {
      model.closeAllScans()
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    #expect(model.presetPreviewRequest == nil)
    let input = directory.appendingPathComponent("source.tiff")
    try image(width: 144, height: 96).write(
      to: input, format: .tiff, parameters: ExportParameters(format: .tiff))
    model.importFiles([input])
    try await waitUntil { model.hasPreviewImage && !model.isLoading && !model.isRendering }
    model.setFilmBase(.colorC41)
    let initial = try #require(model.presetPreviewRequest)
    model.setExposureEV(0.3)
    #expect(model.presetPreviewRequest?.key == initial.key)
    model.applyLookRecipe(.warm)
    #expect(model.presetPreviewRequest?.key == initial.key)
    model.rotateClockwise()
    let rotated = try #require(model.presetPreviewRequest)
    #expect(rotated.key != initial.key)
    model.setFlatField(initial.source, url: directory.appendingPathComponent("field.tiff"))
    let calibrated = try #require(model.presetPreviewRequest)
    #expect(calibrated.key != rotated.key)
    #expect(calibrated.flatField == initial.source)
    model.beginManualCropEditing()
    #expect(model.presetPreviewRequest == nil)
    model.endManualCropEditing()
    #expect(model.presetPreviewRequest != nil)
    model.setFilmBase(.original)
    #expect(model.presetPreviewRequest == nil)
    model.closeAllScans()
    #expect(model.presetPreviewRequest == nil)
  }

  @Test("Late old renders cannot publish over the newest source")
  @MainActor
  func stalePublication() async throws {
    let first = request(sourceGeneration: 1)
    let second = request(sourceGeneration: 2)
    let old = try batch(milliseconds: 20)
    let new = try batch(milliseconds: 10)
    let gate = PresetPreviewWorkerGate()
    defer { gate.release() }
    let store = PresetPreviewStore { request in
      if request.key.sourceGeneration == 1 {
        gate.wait()
        return .completed(old)
      }
      return .completed(new)
    }
    store.update(first)
    try await waitUntil { gate.started }
    #expect(store.thumbnails.isEmpty)
    store.update(second)
    #expect(store.thumbnails.isEmpty)
    try await waitUntil { store.lastElapsedMilliseconds == 10 }
    gate.release()
    try await waitUntil { gate.finished }
    // Let the old worker return through its main-actor publication guard.
    try await Task.sleep(for: .milliseconds(25))
    #expect(store.lastElapsedMilliseconds == 10)
    #expect(store.thumbnails.count == LookRecipe.factory.count)
    store.update(nil)
    #expect(store.thumbnails.isEmpty)
  }

  @Test("An expensive strip falls back once for the whole session")
  @MainActor
  func budgetCircuitBreaker() async throws {
    let probe = PresetPreviewCallCount()
    let store = PresetPreviewStore { _ in
      probe.increment()
      return .budgetExceeded(elapsedMilliseconds: 501)
    }
    store.update(request())
    try await waitUntil { store.disabledForSession }
    #expect(store.thumbnails.isEmpty)
    #expect(!store.isRendering)
    store.update(request(sourceGeneration: 2))
    store.update(nil)
    store.update(request(sourceGeneration: 3))
    #expect(probe.count == 1)
    #expect(store.thumbnails.isEmpty)
    #expect(!store.isRendering)
  }

  @Test(
    "Measure complete factory-strip preparation, rendering, and display packing",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PRESET_PREVIEW_BENCHMARK"] == "1",
      "set RUN_PRESET_PREVIEW_BENCHMARK=1 with a release build"))
  func benchmark() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let corpus: [(String, FilmBase)] = [
      ("fuji400-fresh/DSCF2833.RAF", .colorC41),
      ("harmanphoenixii/DSCF3086.RAF", .colorCyanMask),
      ("proimage/DSCF5800.RAF", .colorC41),
      ("shanghaigp3/DSCF3192.RAF", .blackAndWhite),
    ]
    var rows: [PresetPreviewBenchmarkRow] = []
    let synthetic = image(width: 1_200, height: 800)
    for base in [FilmBase.colorC41, .colorCyanMask, .blackAndWhite, .slide] {
      rows.append(try measure(source: synthetic, base: base, name: "synthetic-\(base.rawValue)"))
    }
    rows.append(
      try measure(
        source: synthetic, base: .colorC41, name: "synthetic-density-field-repair-perspective",
        densityField: synthetic))
    for (relativePath, base) in corpus {
      let row = try autoreleasepool {
        let url = root.appending(path: "sample-raw/\(relativePath)")
        #expect(FileManager.default.fileExists(atPath: url.path), "Missing RAW: \(relativePath)")
        // Decode once before measuring, matching the app's retained source.
        let source = try RawImageDecoder.decode(
          url, profile: .rawTherapeeCameraScan,
          maxDimension: AppModel.rawFullPreviewDecodeBound
        ).image
        return try measure(source: source, base: base, name: relativePath)
      }
      rows.append(row)
    }
    let output = ProcessInfo.processInfo.environment["PRESET_PREVIEW_BENCHMARK_OUTPUT"]
    if let output {
      let url = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let report = PresetPreviewBenchmarkReport(
        createdAt: ISO8601DateFormatter().string(from: Date()),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        processorCount: ProcessInfo.processInfo.activeProcessorCount,
        pixelBound: PresetPreviewRenderer.maximumDimension,
        recipeCount: LookRecipe.factory.count, rows: rows,
        note:
          "Each sample includes source/analysis/field preparation, all nine production CPU renders, and CGImage packing. RAW decoding is outside the measured hot path. First and repeated samples are retained; no warm-up discarded."
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: url)
      print("Preset preview benchmark: \(url.path)")
    }
    for row in rows {
      print("PRESET_STRIP \(row.name): \(row.samplesMilliseconds) ms")
      #expect(row.samplesMilliseconds.count == 5)
      #expect(row.samplesMilliseconds.allSatisfy { $0 <= 500 })
    }
  }

  private func measure(
    source: UInt16Image, base: FilmBase, name: String, densityField: UInt16Image? = nil
  ) throws
    -> PresetPreviewBenchmarkRow
  {
    var parameters = base.applyingInvert(to: ProcessingParameters())
    parameters.manualCrop = .init(x: 0.04, y: 0.03, width: 0.92, height: 0.94)
    parameters.straightenAngle = 1.2
    if densityField != nil {
      parameters.densityPipelineEnabled = true
      parameters.filmNegativeParams.rendering = .powerLaw
      parameters.densityBaseDensity = .init(blue: 0.1, green: 0.2, red: 0.3)
      parameters.perspectiveCrop = .init(
        topLeft: .init(x: 0.04, y: 0.05), topRight: .init(x: 0.94, y: 0.08),
        bottomRight: .init(x: 0.92, y: 0.95), bottomLeft: .init(x: 0.05, y: 0.92))
      parameters.dustRepairs = [
        .init(points: [SIMD2(0.5, 0.5)], radius: 0.025, sourcePoint: SIMD2(0.6, 0.5))
      ]
    }
    let request = request(source: source, parameters: parameters, flatField: densityField)
    var samples: [Double] = []
    for _ in 0..<5 {
      guard case .completed(let batch) = PresetPreviewRenderer.render(request) else {
        Issue.record("\(name) exceeded the 500ms complete-strip budget or failed")
        break
      }
      #expect(batch.thumbnails.count == LookRecipe.factory.count)
      samples.append(batch.elapsedMilliseconds)
    }
    return PresetPreviewBenchmarkRow(
      name: name, width: source.width, height: source.height, samplesMilliseconds: samples)
  }

  private func request(
    source: UInt16Image? = nil, parameters: ProcessingParameters = ProcessingParameters(),
    flatField: UInt16Image? = nil, sourceGeneration: Int = 1
  ) -> PresetPreviewRequest {
    PresetPreviewRequest(
      key: PresetPreviewKey(
        sourceURL: URL(fileURLWithPath: "/preset-preview.tiff"),
        sourceGeneration: sourceGeneration, parameters: parameters),
      source: source ?? image(width: 12, height: 8), parameters: parameters, flatField: flatField)
  }

  private func image(width: Int, height: Int) -> UInt16Image {
    var pixels = [UInt16]()
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 {
          pixels.append(UInt16(3_000 + (x * 137 + y * 211 + channel * 6_311) % 55_000))
        }
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private func batch(milliseconds: Double) throws -> PresetPreviewBatch {
    let bitmap = try #require(image(width: 2, height: 2).makePreviewCGImage())
    return PresetPreviewBatch(
      thumbnails: LookRecipe.factory.map { .init(recipe: $0, image: bitmap) },
      elapsedMilliseconds: milliseconds)
  }

  private func bytes(_ image: CGImage) -> Data? {
    image.dataProvider?.data.map { $0 as Data }
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw PresetPreviewTestError.timedOut }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private enum PresetPreviewTestError: Error { case timedOut }

private struct PresetPreviewBenchmarkRow: Codable {
  let name: String
  let width: Int
  let height: Int
  let samplesMilliseconds: [Double]
}

private struct PresetPreviewBenchmarkReport: Codable {
  let createdAt: String
  let operatingSystem: String
  let processorCount: Int
  let pixelBound: Int
  let recipeCount: Int
  let rows: [PresetPreviewBenchmarkRow]
  let note: String
}

private final class PresetPreviewWorkerGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var didStart = false
  private var didFinish = false
  var started: Bool { lock.withLock { didStart } }
  var finished: Bool { lock.withLock { didFinish } }
  func wait() {
    lock.withLock { didStart = true }
    semaphore.wait()
    lock.withLock { didFinish = true }
  }
  func release() { semaphore.signal() }
}

private final class PresetPreviewCallCount: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func increment() { lock.withLock { value += 1 } }
}
