import AppKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Retained preview memory and invalidation", .serialized)
@MainActor
struct PreviewRetentionTests {
  @Test("Cache budgets scale for 16 and 24 GB Macs and stop at 3 GB")
  func memoryBudgets() {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    #expect(AppModel.previewMemoryBudget(physicalMemory: 16 * gib) == Int(2 * gib))
    #expect(AppModel.previewMemoryBudget(physicalMemory: 24 * gib) == Int(3 * gib))
    #expect(AppModel.previewMemoryBudget(physicalMemory: 64 * gib) == Int(3 * gib))
    #expect(AppModel.previewMemoryBudget(physicalMemory: 8 * gib) == Int(gib))
  }

  @Test("Full caches skip neighbour work, preserve rasters, and resume after expansion")
  func lookaheadAdmissionPrecedesDecode() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixtureURL()
    let urls = try (0..<3).map { index in
      let url = directory.appendingPathComponent("\(index).png")
      try FileManager.default.copyItem(at: fixture, to: url)
      return url
    }
    let suiteName = "fsc-preview-admission-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(preferences: preferences)
    model.setPreviewCacheLimit(2)
    model.importFiles(urls)
    try await settledIncludingBackgroundWork(model)
    #expect(model.previewCacheSessionCount == 2)
    #expect(model.hasCachedPreview(for: urls[0]))
    #expect(model.hasCachedPreview(for: urls[1]))
    #expect(model.lookaheadPreviewRequestCount == 1)

    model.selection = urls[1]
    model.loadSelection()
    try await settledIncludingBackgroundWork(model)
    #expect(model.lookaheadPreviewRequestCount == 1)
    #expect(!model.hasCachedPreview(for: urls[2]))
    #expect(model.hasCachedPreview(for: urls[0]))
    #expect(model.hasCachedPreview(for: urls[1]))
    let corrections = model.previewCorrectionCount
    let cacheHits = model.previewRenderCacheHits
    for url in [urls[0], urls[1]] {
      model.selection = url
      model.loadSelection()
      try await settledIncludingBackgroundWork(model)
    }
    #expect(model.lookaheadPreviewRequestCount == 1)
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.previewRenderCacheHits == cacheHits + 2)

    // Foreground loading still admits a requested source and evicts the LRU.
    model.selection = urls[2]
    model.loadSelection()
    try await settledIncludingBackgroundWork(model)
    #expect(model.hasCachedPreview(for: urls[2]))
    #expect(model.hasCachedPreview(for: urls[1]))
    #expect(!model.hasCachedPreview(for: urls[0]))
    #expect(model.lookaheadPreviewRequestCount == 1)

    model.setPreviewCacheLimit(3)
    try await settledIncludingBackgroundWork(model)
    #expect(model.previewCacheSessionCount == 3)
    #expect(model.hasCachedPreview(for: urls[0]))
    #expect(model.lookaheadPreviewRequestCount == 2)
  }

  @Test("A selected preview over its byte budget skips neighbour requests")
  func exhaustedByteBudgetSkipsLookahead() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-byte-admission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixtureURL()
    let urls = try (0..<2).map { index in
      let url = directory.appendingPathComponent("\(index).png")
      try FileManager.default.copyItem(at: fixture, to: url)
      return url
    }
    let model = AppModel(previewMemoryBudget: 1)
    model.importFiles(urls)
    try await settledIncludingBackgroundWork(model)
    #expect(model.previewCachePhysicalBytes > model.previewMemoryByteLimit)
    #expect(model.previewCacheSessionCount == 1)
    #expect(model.lookaheadPreviewRequestCount == 0)

    model.selection = urls[1]
    model.loadSelection()
    try await settledIncludingBackgroundWork(model)
    #expect(model.hasCachedPreview(for: urls[1]))
    #expect(!model.hasCachedPreview(for: urls[0]))
    #expect(model.lookaheadPreviewRequestCount == 0)
  }

  @Test("Completed corrections are reused, while edits, geometry, and flat fields invalidate them")
  func renderedCacheInvalidation() async throws {
    let fixture = try fixtureURL()
    let model = AppModel()
    model.importFiles([fixture])
    try await settled(model)
    model.setFilmBase(.colorC41)
    model.applyLookRecipe(.cleanInvert)
    model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    try await settled(model)
    #expect(model.status.contains("GPU"))
    let size = try #require(model.previewImage?.size)
    let submissions = model.renderStats.submittedSnapshots
    for offset in 0..<100 {
      model.setPreviewRenderDemand(
        PreviewRenderDemand(
          documentSize: size,
          visibleRect: CGRect(
            x: CGFloat(offset), y: CGFloat(offset), width: size.width / 3, height: size.height / 3),
          backingScale: 2, magnification: 2))
    }
    #expect(model.renderStats.submittedSnapshots == submissions)
    let corrections = model.previewCorrectionCount
    model.loadSelection()
    try await settled(model)
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.previewRenderCacheHits > 0)
    model.setExposureEV(0.5)
    try await settled(model)
    #expect(model.previewCorrectionCount == corrections + 1)
    model.rotateClockwise()
    try await settled(model)
    #expect(model.previewCorrectionCount == corrections + 2)
    model.showOriginal = true
    try await settled(model)
    #expect(model.previewCorrectionCount == corrections + 3)
    model.showOriginal = false
    try await settled(model)
    let beforeFlatField = model.previewCorrectionCount
    model.clearFlatField()
    try await settled(model)
    #expect(model.previewCorrectionCount == beforeFlatField + 1)
    #expect(model.publishedPreviewParameters == model.parameters)
  }

  @Test(
    "Retained switches reuse diagnostics while edits and Original compute current statistics")
  func retainedStatisticsFollowRenderedRaster() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-statistics-retention-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var urls: [URL] = []
    for index in 0..<2 {
      let url = directory.appendingPathComponent("\(index).png")
      var pixels = [UInt16]()
      for sample in 0..<(48 * 32 * 3) {
        let value = 8_000 + index * 12_000 + (sample * 37) % 18_000
        pixels.append(UInt16(value))
      }
      let image = UInt16Image(width: 48, height: 32, channels: 3, pixels: pixels)
      try image.write(
        to: url, format: .png, parameters: .init(format: .png))
      urls.append(url)
    }
    let store = PerFileSettingsStore(baseDirectory: directory.appendingPathComponent("settings"))
    let parameters = ProcessingParameters(filmType: .slide, photoAdjustments: .init())
    try store.save(
      .init(
        settingsByPath: Dictionary(
          uniqueKeysWithValues: urls.map { ($0.standardizedFileURL.path, parameters) }),
        editedPaths: []))
    let suiteName = "fsc-statistics-retention-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(settingsStore: store, preferences: preferences)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.setPreviewCacheLimit(2)
    model.importFiles(urls)
    try await settledIncludingStatistics(model)
    let firstStatistics = model.previewStatistics
    model.selection = urls[1]
    model.loadSelection()
    try await settledIncludingStatistics(model)
    let secondStatistics = model.previewStatistics
    #expect(firstStatistics != secondStatistics)
    let computations = model.previewStatisticsComputationCount
    let corrections = model.previewCorrectionCount
    let decodes = model.fullResolutionPreviewDecodeCount
    let hits = model.previewRenderCacheHits

    for index in [0, 1, 0] {
      model.selection = urls[index]
      model.loadSelection()
      try await settledIncludingStatistics(model)
      #expect(model.previewStatistics == (index == 0 ? firstStatistics : secondStatistics))
      #expect(model.previewStatisticsComputationCount == computations)
    }
    #expect(model.previewRenderCacheHits == hits + 3)
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.fullResolutionPreviewDecodeCount == decodes)

    model.setExposureEV(1)
    try await settledIncludingStatistics(model)
    let editedStatistics = model.previewStatistics
    #expect(editedStatistics != firstStatistics)
    #expect(model.previewStatisticsComputationCount == computations + 1)
    #expect(model.publishedPreviewParameters == model.parameters)

    model.showOriginal = true
    try await settledIncludingStatistics(model)
    #expect(model.previewStatistics != editedStatistics)
    #expect(model.previewStatisticsComputationCount == computations + 2)
    model.showOriginal = false
    try await settledIncludingStatistics(model)
    #expect(model.previewStatistics == editedStatistics)
    #expect(model.previewStatisticsComputationCount == computations + 3)

    model.selection = urls[1]
    model.loadSelection()
    try await settledIncludingStatistics(model)
    #expect(model.previewStatistics == secondStatistics)
    model.selection = urls[0]
    model.loadSelection()
    try await settledIncludingStatistics(model)
    #expect(model.previewStatistics == editedStatistics)
    #expect(model.previewStatisticsComputationCount == computations + 3)
    try await model.flushSettings()
  }

  @Test(
    "Byte limits evict old previews, speculation stays bounded, and pressure preserves selection")
  func memoryEviction() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-memory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try fixtureURL()
    let urls = try (0..<4).map { index in
      let url = directory.appendingPathComponent("\(index).png")
      try FileManager.default.copyItem(at: fixture, to: url)
      return url
    }
    let probe = AppModel()
    probe.importFiles([fixture])
    try await settled(probe)
    // Enough for two sources and their corrected rasters, not three sources.
    let budget = probe.previewCachePhysicalBytes * 2
    let model = AppModel(previewMemoryBudget: budget)
    model.setPreviewCacheLimit(8)
    model.importFiles(urls)
    try await settledIncludingBackgroundWork(model)
    for url in urls {
      model.selection = url
      model.loadSelection()
      try await settledIncludingBackgroundWork(model)
      #expect(model.previewCachePhysicalBytes <= budget)
    }
    #expect(!model.hasCachedPreview(for: urls[0]))
    #expect(model.hasCachedPreview(for: urls[3]))
    let corrections = model.previewCorrectionCount
    model.handlePreviewMemoryPressure(isUnderPressure: true)
    #expect(model.previewCacheSessionCount == 1)
    #expect(model.hasCachedPreview(for: urls[3]))
    model.loadSelection()
    try await settled(model)
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.previewCacheSessionCount == 1)
    model.handlePreviewMemoryPressure(isUnderPressure: false)
  }

  private func fixtureURL() throws -> URL {
    try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
  }

  private func settled(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.previewImage == nil || model.isLoading || model.isRendering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func settledIncludingBackgroundWork(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.previewImage == nil || model.isLoading || model.isRendering
      || model.previewBackgroundWorkIsActive
    {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func settledIncludingStatistics(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.previewImage == nil || model.isLoading || model.isRendering
      || model.previewBackgroundWorkIsActive
      || model.previewStatisticsRevision != model.publishedRenderRevision
    {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
