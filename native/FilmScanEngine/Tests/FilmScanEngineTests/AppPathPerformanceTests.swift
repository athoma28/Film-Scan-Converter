@preconcurrency import Darwin
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

private let appPathBenchmarkRepositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

@Suite("App path performance benchmark", .serialized)
@MainActor
struct AppPathPerformanceTests {
  private enum BenchmarkError: Error {
    case timedOut(String)
  }

  private struct MemorySample: Codable {
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let reusableBytes: UInt64
  }

  private struct LatencySummary: Codable {
    let samplesMilliseconds: [Double]
    let p50Milliseconds: Double
    let p95Milliseconds: Double
  }

  private struct PreviewCacheDepthSample: Codable {
    let configuredDepth: Int
    let availableFiles: Int
    let populatedSessions: Int
    let cachedPreviewBytes: Int
    let fillMilliseconds: Double
    let memoryBeforeFill: MemorySample
    let cachedSourceKinds: [String: String]
    let memoryAfterInitialLookahead: MemorySample
    let memoryAfterRelease: MemorySample
  }

  private struct RetainedNavigationSample: Codable {
    let files: [String]
    let warmupMilliseconds: Double
    let returnSwitch: LatencySummary
    let returnSwitchThroughStatistics: LatencySummary
    let viewportUpdateCount: Int
    let viewportUpdatesMilliseconds: Double
    let fullResolutionDecodesDuringNavigation: Int
    let correctionsDuringNavigation: Int
    let computationsDuringNavigation: Int
    let renderCacheHitsDuringNavigation: Int
    let cachedPreviewBytes: Int
    let cacheBudgetBytes: Int
    let memorySettled: MemorySample
    var memoryAfterRelease: MemorySample
  }

  private struct SaturatedCacheSample: Codable {
    let files: [String]
    let cachedSwitch: LatencySummary
    let backgroundDrain: LatencySummary
    let lookaheadRequestsDuringSwitch: [Int]
    let cachedSourceKinds: [String: String]
    let cachedPreviewBytes: Int
    let memoryAfterBackgroundDrain: MemorySample
  }

  private struct Report: Codable {
    let generatedAt: String
    let hardware: String
    let repetitions: Int
    let files: [String]
    let firstCorrectedPaint: LatencySummary
    let cachedSwitch: LatencySummary
    let uncachedSwitch: LatencySummary
    let rapidSelectionDrain: LatencySummary
    let memoryBefore: MemorySample
    let memoryAfter: MemorySample
    let maximumPreviewCacheBytes: Int
    let previewCacheDepths: [PreviewCacheDepthSample]
    let retainedNavigation: RetainedNavigationSample
    let saturatedCache: SaturatedCacheSample
    let note: String
  }

  @Test("Nearest-rank app-path summaries keep stable p50 and p95 semantics")
  func nearestRankSummaryContract() {
    let summary = summarize([4, 1, 3, 2])
    #expect(summary.p50Milliseconds == 2)
    #expect(summary.p95Milliseconds == 4)
  }

  @Test("Preview-cache depth sampling respects the bounded lookahead population")
  func previewCacheDepthPopulationContract() {
    #expect(expectedCachePopulation(limit: 2, fileCount: 6) == 2)
    #expect(expectedCachePopulation(limit: 8, fileCount: 6) == 4)
    #expect(expectedCachePopulation(limit: 32, fileCount: 6) == 4)
    #expect(expectedCachePopulation(limit: 8, fileCount: 3) == 3)
  }

  @Test(
    "Measure first paint, cached and uncached switching, and rapid-selection drain",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_APP_PATH_PERFORMANCE_TESTS"] == "1",
      "set RUN_APP_PATH_PERFORMANCE_TESTS=1 to run the real app-path benchmark")
  )
  func measureAppPathLatencyAndMemory() async throws {
    let rawDirectory = appPathBenchmarkRepositoryRoot.appending(path: "sample-raw")
    let rawFiles = try RecursiveFileDiscovery.files(
      under: rawDirectory,
      extensions: ["raf"]
    )

    #expect(rawFiles.count >= 4, "The app-path benchmark needs at least four local RAF files")
    guard rawFiles.count >= 4 else { return }

    let repetitions = max(
      1,
      Int(ProcessInfo.processInfo.environment["APP_PATH_BENCHMARK_REPETITIONS"] ?? "3") ?? 3)
    let corpus = Array(rawFiles.prefix(max(4, min(10, rawFiles.count))))
    let memoryBefore = memorySample()
    let previewCacheDepths = try await measurePreviewCacheDepths(corpus: corpus)
    var firstPaintSamples = [Double]()
    var cachedSamples = [Double]()
    var uncachedSamples = [Double]()
    var drainSamples = [Double]()
    var maximumPreviewCacheBytes = 0

    for repetition in 0..<repetitions {
      let ordered = rotated(corpus, by: repetition)

      let firstPaint = try await withModel(cacheLimit: 2) { model in
        let start = ContinuousClock.now
        model.importFiles([ordered[0]])
        try await waitForDisplayedPreview(in: model, file: ordered[0], afterDisplayedCount: 0)
        return (milliseconds(since: start), model.previewCachePhysicalBytes)
      }
      firstPaintSamples.append(firstPaint.0)
      maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, firstPaint.1)

      let cached = try await withModel(cacheLimit: 2) { model in
        model.importFiles(Array(ordered.prefix(3)))
        try await waitForDisplayedPreview(in: model, file: ordered[0], afterDisplayedCount: 0)
        try await waitUntil("lookahead cache", timeout: .seconds(45)) {
          model.hasCachedPreview(for: ordered[1])
        }
        let displayed = model.renderStats.displayedRenders
        let start = ContinuousClock.now
        model.selection = ordered[1]
        model.loadSelection()
        try await waitForDisplayedPreview(
          in: model, file: ordered[1], afterDisplayedCount: displayed)
        return (milliseconds(since: start), model.previewCachePhysicalBytes)
      }
      cachedSamples.append(cached.0)
      maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, cached.1)

      let uncached = try await withModel(cacheLimit: 2) { model in
        model.importFiles(Array(ordered.prefix(4)))
        try await waitForDisplayedPreview(in: model, file: ordered[0], afterDisplayedCount: 0)
        try await waitUntil("bounded lookahead cache", timeout: .seconds(45)) {
          model.hasCachedPreview(for: ordered[1])
        }
        try #require(!model.hasCachedPreview(for: ordered[3]))
        let displayed = model.renderStats.displayedRenders
        let start = ContinuousClock.now
        model.selection = ordered[3]
        model.loadSelection()
        try await waitForDisplayedPreview(
          in: model, file: ordered[3], afterDisplayedCount: displayed)
        return (milliseconds(since: start), model.previewCachePhysicalBytes)
      }
      uncachedSamples.append(uncached.0)
      maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, uncached.1)

      let rapid = try await withModel(cacheLimit: 2) { model in
        model.importFiles(ordered)
        try await waitForDisplayedPreview(in: model, file: ordered[0], afterDisplayedCount: 0)
        let displayed = model.renderStats.displayedRenders
        let start = ContinuousClock.now
        for file in ordered.dropFirst() {
          model.selection = file
          model.loadSelection()
        }
        let finalFile = try #require(ordered.last)
        try await waitForDisplayedPreview(
          in: model, file: finalFile, afterDisplayedCount: displayed)
        return (milliseconds(since: start), model.previewCachePhysicalBytes)
      }
      drainSamples.append(rapid.0)
      maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, rapid.1)
    }
    let retainedNavigation = try await measureRetainedNavigation(
      corpus: Array(corpus.prefix(2)), repetitions: repetitions)
    maximumPreviewCacheBytes = max(
      maximumPreviewCacheBytes, retainedNavigation.cachedPreviewBytes)

    let saturatedCache = try await measureSaturatedCache(
      corpus: Array(corpus.prefix(3)), repetitions: repetitions)
    maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, saturatedCache.cachedPreviewBytes)

    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      hardware: hardwareDescription(),
      repetitions: repetitions,
      files: corpus.map(relativeCorpusPath),
      firstCorrectedPaint: summarize(firstPaintSamples),
      cachedSwitch: summarize(cachedSamples),
      uncachedSwitch: summarize(uncachedSamples),
      rapidSelectionDrain: summarize(drainSamples),
      memoryBefore: memoryBefore,
      memoryAfter: memorySample(),
      maximumPreviewCacheBytes: maximumPreviewCacheBytes,
      previewCacheDepths: previewCacheDepths,
      retainedNavigation: retainedNavigation,
      saturatedCache: saturatedCache,
      note:
        "Real AppModel publication timings; native input and screen presentation are not measured. Each phase cancels selection work and waits for model release before the next phase. Initial cache-depth samples stop when bounded lookahead is populated; they are not full cache-capacity or settled-speculation measurements. Full-sensor sources and corrected rasters remain cached within the machine-dependent preview memory budget. Retained navigation warms two full previews, corrected rasters, and their diagnostics, then measures publication and current-statistics revisit timings plus viewport updates with decode/correction/statistics-computation counters. Saturated-cache switching measures speculative scheduler submissions and background drain with two retained sessions and an uncached neighbour. Three default repetitions yield descriptive nearest-rank summaries, not a tail-latency estimate. No exports are written."
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let outputPath = ProcessInfo.processInfo.environment["APP_PATH_BENCHMARK_OUTPUT"] {
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
  }

  private func measurePreviewCacheDepths(
    corpus: [URL]
  ) async throws -> [PreviewCacheDepthSample] {
    var samples = [PreviewCacheDepthSample]()
    for depth in [2, 8, 32] {
      let beforeFill = memorySample()
      let sample = try await withModel(cacheLimit: depth) { model in
        let fillStart = ContinuousClock.now
        model.importFiles(corpus)
        let firstFile = try #require(corpus.first)
        try await waitForDisplayedPreview(in: model, file: firstFile, afterDisplayedCount: 0)
        let expectedPopulation = expectedCachePopulation(limit: depth, fileCount: corpus.count)
        try await waitUntil("preview cache depth \(depth)", timeout: .seconds(45)) {
          model.previewCacheSessionCount == expectedPopulation
        }
        return (
          model.previewCacheSessionCount, model.previewCachePhysicalBytes,
          milliseconds(since: fillStart), cachedKinds(model: model, corpus: corpus), memorySample()
        )
      }
      samples.append(
        PreviewCacheDepthSample(
          configuredDepth: depth,
          availableFiles: corpus.count,
          populatedSessions: sample.0,
          cachedPreviewBytes: sample.1,
          fillMilliseconds: sample.2,
          memoryBeforeFill: beforeFill,
          cachedSourceKinds: sample.3,
          memoryAfterInitialLookahead: sample.4,
          memoryAfterRelease: memorySample()
        ))
    }
    return samples
  }

  private func relativeCorpusPath(_ file: URL) -> String {
    let prefix = appPathBenchmarkRepositoryRoot.appending(path: "sample-raw").path + "/"
    return file.path.hasPrefix(prefix)
      ? String(file.path.dropFirst(prefix.count)) : file.lastPathComponent
  }

  private func cachedKinds(model: AppModel, corpus: [URL]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: corpus.compactMap { file in
        model.cachedPreviewKind(for: file).map { (relativeCorpusPath(file), $0.rawValue) }
      })
  }

  private func measureRetainedNavigation(
    corpus: [URL], repetitions: Int
  ) async throws -> RetainedNavigationSample {
    var sample = try await withModel(cacheLimit: 2) { model in
      let first = corpus[0]
      let second = corpus[1]
      let warmupStart = ContinuousClock.now
      model.importFiles(corpus)
      try await waitUntil("two retained full previews", timeout: .seconds(120)) {
        model.previewSourceKind == .rawFull && !model.isRendering
          && !model.previewBackgroundWorkIsActive
          && corpus.allSatisfy { model.cachedPreviewKind(for: $0) == .rawFull }
      }
      // Publish both full rasters and finish their statistics before timing
      // revisits, so first correction, analysis, or tier upgrade is excluded.
      for file in [second, first] {
        let displayed = model.renderStats.displayedRenders
        model.selection = file
        model.loadSelection()
        try await waitForDisplayedPreview(in: model, file: file, afterDisplayedCount: displayed)
        try await waitUntil("retained warmup statistics") {
          model.previewStatisticsRevision == model.publishedRenderRevision
        }
      }
      try await waitUntil("settled retained statistics") {
        model.previewStatisticsRevision == model.publishedRenderRevision
          && !model.isAnalyzingScanStacks && !model.isRendering
          && !model.previewBackgroundWorkIsActive
      }
      let warmupMilliseconds = milliseconds(since: warmupStart)
      let decodeCount = model.fullResolutionPreviewDecodeCount
      let correctionCount = model.previewCorrectionCount
      let computationCount = model.previewStatisticsComputationCount
      let cacheHits = model.previewRenderCacheHits
      var switches: [Double] = []
      var switchesThroughStatistics: [Double] = []
      for _ in 0..<repetitions {
        for file in [second, first] {
          let displayed = model.renderStats.displayedRenders
          let start = ContinuousClock.now
          model.selection = file
          model.loadSelection()
          try await waitForDisplayedPreview(in: model, file: file, afterDisplayedCount: displayed)
          switches.append(milliseconds(since: start))
          try await waitUntil("retained switch statistics") {
            model.previewStatisticsRevision == model.publishedRenderRevision
          }
          switchesThroughStatistics.append(milliseconds(since: start))
        }
      }
      let dimensions = try #require(model.previewImage?.size)
      let published = model.publishedRenderRevision
      let viewportUpdates = 1_000
      let viewportStart = ContinuousClock.now
      for index in 0..<viewportUpdates {
        model.setPreviewRenderDemand(
          PreviewRenderDemand(
            documentSize: dimensions,
            visibleRect: CGRect(x: index * 2, y: index, width: 1_000, height: 800),
            backingScale: 2, magnification: 1))
      }
      let viewportMilliseconds = milliseconds(since: viewportStart)
      #expect(model.publishedRenderRevision == published)
      #expect(model.fullResolutionPreviewDecodeCount == decodeCount)
      #expect(model.previewCorrectionCount == correctionCount)
      #expect(model.previewRenderCacheHits - cacheHits == repetitions * 2)
      try await waitUntil("settled navigation statistics") {
        model.previewStatisticsRevision == model.publishedRenderRevision && !model.isRendering
          && !model.previewBackgroundWorkIsActive
      }
      #expect(model.previewStatisticsComputationCount == computationCount)
      return RetainedNavigationSample(
        files: corpus.map(relativeCorpusPath),
        warmupMilliseconds: warmupMilliseconds,
        returnSwitch: summarize(switches),
        returnSwitchThroughStatistics: summarize(switchesThroughStatistics),
        viewportUpdateCount: viewportUpdates,
        viewportUpdatesMilliseconds: viewportMilliseconds,
        fullResolutionDecodesDuringNavigation: model.fullResolutionPreviewDecodeCount - decodeCount,
        correctionsDuringNavigation: model.previewCorrectionCount - correctionCount,
        computationsDuringNavigation: model.previewStatisticsComputationCount - computationCount,
        renderCacheHitsDuringNavigation: model.previewRenderCacheHits - cacheHits,
        cachedPreviewBytes: model.previewCachePhysicalBytes,
        cacheBudgetBytes: model.previewMemoryByteLimit,
        memorySettled: memorySample(),
        memoryAfterRelease: memorySample())
    }
    sample.memoryAfterRelease = memorySample()
    return sample
  }

  private func measureSaturatedCache(
    corpus: [URL], repetitions: Int
  ) async throws -> SaturatedCacheSample {
    try await withModel(cacheLimit: 2) { model in
      model.importFiles(corpus)
      try await waitUntil("saturated retained cache", timeout: .seconds(120)) {
        model.previewSourceKind == .rawFull && !model.isRendering
          && !model.previewBackgroundWorkIsActive
          && corpus.prefix(2).allSatisfy { model.cachedPreviewKind(for: $0) == .rawFull }
      }
      try #require(model.previewCacheSessionCount == 2)
      try #require(!model.hasCachedPreview(for: corpus[2]))
      // Warm both corrected rasters and drain the associated speculation before
      // the timed revisits. The third source must remain absent from this cache.
      for file in [corpus[1], corpus[0]] {
        let displayed = model.renderStats.displayedRenders
        model.selection = file
        model.loadSelection()
        try await waitForDisplayedPreview(in: model, file: file, afterDisplayedCount: displayed)
        try await waitUntil("saturated-cache warmup drain", timeout: .seconds(90)) {
          !model.previewBackgroundWorkIsActive
        }
      }
      var switchSamples: [Double] = []
      var drainSamples: [Double] = []
      var requestSamples: [Int] = []
      for _ in 0..<repetitions {
        try #require(!model.hasCachedPreview(for: corpus[2]))
        let requests = model.lookaheadPreviewRequestCount
        let displayed = model.renderStats.displayedRenders
        let start = ContinuousClock.now
        model.selection = corpus[1]
        model.loadSelection()
        try await waitForDisplayedPreview(
          in: model, file: corpus[1], afterDisplayedCount: displayed)
        switchSamples.append(milliseconds(since: start))
        try await waitUntil("saturated-cache background drain", timeout: .seconds(90)) {
          !model.previewBackgroundWorkIsActive && !model.isRendering
            && model.previewStatisticsRevision == model.publishedRenderRevision
        }
        drainSamples.append(milliseconds(since: start))
        requestSamples.append(model.lookaheadPreviewRequestCount - requests)
        let beforeReturn = model.renderStats.displayedRenders
        model.selection = corpus[0]
        model.loadSelection()
        try await waitForDisplayedPreview(
          in: model, file: corpus[0], afterDisplayedCount: beforeReturn)
        try await waitUntil("saturated-cache return drain", timeout: .seconds(90)) {
          !model.previewBackgroundWorkIsActive && !model.isRendering
            && model.previewStatisticsRevision == model.publishedRenderRevision
        }
      }
      return SaturatedCacheSample(
        files: corpus.map(relativeCorpusPath),
        cachedSwitch: summarize(switchSamples),
        backgroundDrain: summarize(drainSamples),
        lookaheadRequestsDuringSwitch: requestSamples,
        cachedSourceKinds: cachedKinds(model: model, corpus: corpus),
        cachedPreviewBytes: model.previewCachePhysicalBytes,
        memoryAfterBackgroundDrain: memorySample())
    }
  }

  private func withModel<T>(
    cacheLimit: Int,
    operation: @MainActor (AppModel) async throws -> T
  ) async throws -> T {
    let suiteName = "fsc-app-path-benchmark-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    preferences.set(cacheLimit, forKey: "previewCacheLimit")
    var model: AppModel? = AppModel(preferences: preferences)
    weak var releasedModel = model
    do {
      let result = try await operation(try #require(model))
      model?.selection = nil
      model?.loadSelection()
      try await waitUntil("background stack analysis", timeout: .seconds(90)) {
        model?.isAnalyzingScanStacks == false
      }
      model = nil
      try await waitUntil("benchmark model release", timeout: .seconds(90)) {
        releasedModel == nil
      }
      return result
    } catch {
      model?.selection = nil
      model?.loadSelection()
      model = nil
      // Preserve the original failure, but still give in-flight native decodes
      // time to finish before another test can contend with this phase.
      try? await waitUntil("failed benchmark model release", timeout: .seconds(90)) {
        releasedModel == nil
      }
      throw error
    }
  }

  private func expectedCachePopulation(limit: Int, fileCount: Int) -> Int {
    guard fileCount > 0 else { return 0 }
    let upcoming = max(0, fileCount - 1)
    let budget = max(0, max(2, limit) - 1)
    let lookahead = min(AppModel.rawLookaheadDetailCount, min(budget, upcoming))
    return 1 + lookahead
  }

  private func waitForDisplayedPreview(
    in model: AppModel,
    file: URL,
    afterDisplayedCount: Int
  ) async throws {
    try await waitUntil("corrected preview for \(file.lastPathComponent)") {
      model.selection == file && model.previewImage != nil
        && model.renderStats.displayedRenders > afterDisplayedCount
        && !model.isLoading && !model.isRendering
    }
  }

  private func waitUntil(
    _ label: String,
    timeout: Duration = .seconds(15),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw BenchmarkError.timedOut(label) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) * 1_000
      + Double(elapsed.components.attoseconds) / 1e15
  }

  private func summarize(_ samples: [Double]) -> LatencySummary {
    let sorted = samples.sorted()
    return LatencySummary(
      samplesMilliseconds: samples,
      p50Milliseconds: nearestRank(sorted, fraction: 0.50),
      p95Milliseconds: nearestRank(sorted, fraction: 0.95))
  }

  private func nearestRank(_ sorted: [Double], fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
    return sorted[min(sorted.count - 1, rank - 1)]
  }

  private func rotated(_ values: [URL], by offset: Int) -> [URL] {
    guard !values.isEmpty else { return [] }
    let pivot = offset % values.count
    return Array(values[pivot...]) + Array(values[..<pivot])
  }

  private func memorySample() -> MemorySample {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return MemorySample(
        physicalFootprintBytes: 0, peakPhysicalFootprintBytes: 0, reusableBytes: 0)
    }
    return MemorySample(
      physicalFootprintBytes: UInt64(info.phys_footprint),
      peakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak)),
      reusableBytes: UInt64(info.reusable))
  }

  private func hardwareDescription() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self)
  }
}
