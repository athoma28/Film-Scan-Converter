import Darwin
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
    let note: String
  }

  @Test("Nearest-rank app-path summaries keep stable p50 and p95 semantics")
  func nearestRankSummaryContract() {
    let summary = summarize([4, 1, 3, 2])
    #expect(summary.p50Milliseconds == 2)
    #expect(summary.p95Milliseconds == 4)
  }

  @Test(
    "Measure first paint, cached and uncached switching, and rapid-selection drain",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_APP_PATH_PERFORMANCE_TESTS"] == "1",
      "set RUN_APP_PATH_PERFORMANCE_TESTS=1 to run the real app-path benchmark")
  )
  func measureAppPathLatencyAndMemory() async throws {
    let rawDirectory = appPathBenchmarkRepositoryRoot.appending(path: "sample-raw")
    let rawFiles = try FileManager.default.contentsOfDirectory(
      at: rawDirectory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension.lowercased() == "raf" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    #expect(rawFiles.count >= 4, "The app-path benchmark needs at least four local RAF files")
    guard rawFiles.count >= 4 else { return }

    let repetitions = max(
      1,
      Int(ProcessInfo.processInfo.environment["APP_PATH_BENCHMARK_REPETITIONS"] ?? "3") ?? 3)
    let corpus = Array(rawFiles.prefix(max(4, min(10, rawFiles.count))))
    let memoryBefore = memorySample()
    var firstPaintSamples = [Double]()
    var cachedSamples = [Double]()
    var uncachedSamples = [Double]()
    var drainSamples = [Double]()
    var maximumPreviewCacheBytes = 0

    for repetition in 0..<repetitions {
      let ordered = rotated(corpus, by: repetition)

      let firstPaintModel = makeModel(cacheLimit: 2)
      let firstPaintStart = ContinuousClock.now
      firstPaintModel.importFiles([ordered[0]])
      try await waitForDisplayedPreview(
        in: firstPaintModel, file: ordered[0], afterDisplayedCount: 0)
      firstPaintSamples.append(milliseconds(since: firstPaintStart))
      maximumPreviewCacheBytes = max(
        maximumPreviewCacheBytes, firstPaintModel.previewCachePhysicalBytes)

      let cachedModel = makeModel(cacheLimit: 2)
      cachedModel.importFiles(Array(ordered.prefix(3)))
      try await waitForDisplayedPreview(
        in: cachedModel, file: ordered[0], afterDisplayedCount: 0)
      try await waitUntil("lookahead cache") { cachedModel.previewCacheSessionCount >= 2 }
      let cachedDisplayedCount = cachedModel.renderStats.displayedRenders
      let cachedStart = ContinuousClock.now
      cachedModel.selection = ordered[1]
      cachedModel.loadSelection()
      try await waitForDisplayedPreview(
        in: cachedModel, file: ordered[1], afterDisplayedCount: cachedDisplayedCount)
      cachedSamples.append(milliseconds(since: cachedStart))
      maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, cachedModel.previewCachePhysicalBytes)

      let uncachedModel = makeModel(cacheLimit: 2)
      uncachedModel.importFiles(Array(ordered.prefix(4)))
      try await waitForDisplayedPreview(
        in: uncachedModel, file: ordered[0], afterDisplayedCount: 0)
      try await waitUntil("bounded lookahead cache") {
        uncachedModel.previewCacheSessionCount >= 2
      }
      let uncachedDisplayedCount = uncachedModel.renderStats.displayedRenders
      let uncachedStart = ContinuousClock.now
      uncachedModel.selection = ordered[3]
      uncachedModel.loadSelection()
      try await waitForDisplayedPreview(
        in: uncachedModel, file: ordered[3], afterDisplayedCount: uncachedDisplayedCount)
      uncachedSamples.append(milliseconds(since: uncachedStart))
      maximumPreviewCacheBytes = max(
        maximumPreviewCacheBytes, uncachedModel.previewCachePhysicalBytes)

      let rapidModel = makeModel(cacheLimit: 2)
      rapidModel.importFiles(ordered)
      try await waitForDisplayedPreview(
        in: rapidModel, file: ordered[0], afterDisplayedCount: 0)
      let rapidDisplayedCount = rapidModel.renderStats.displayedRenders
      let rapidStart = ContinuousClock.now
      for file in ordered.dropFirst() {
        rapidModel.selection = file
        rapidModel.loadSelection()
      }
      let finalFile = try #require(ordered.last)
      try await waitForDisplayedPreview(
        in: rapidModel, file: finalFile, afterDisplayedCount: rapidDisplayedCount)
      drainSamples.append(milliseconds(since: rapidStart))
      maximumPreviewCacheBytes = max(maximumPreviewCacheBytes, rapidModel.previewCachePhysicalBytes)
    }

    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      hardware: hardwareDescription(),
      repetitions: repetitions,
      files: corpus.map(\.lastPathComponent),
      firstCorrectedPaint: summarize(firstPaintSamples),
      cachedSwitch: summarize(cachedSamples),
      uncachedSwitch: summarize(uncachedSamples),
      rapidSelectionDrain: summarize(drainSamples),
      memoryBefore: memoryBefore,
      memoryAfter: memorySample(),
      maximumPreviewCacheBytes: maximumPreviewCacheBytes,
      note: "Browsing uses bounded embedded-RAW previews; export performs independent full-resolution decode. No benchmark exports are written."
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let outputPath = ProcessInfo.processInfo.environment["APP_PATH_BENCHMARK_OUTPUT"] {
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
  }

  private func makeModel(cacheLimit: Int) -> AppModel {
    let suiteName = "fsc-app-path-benchmark-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    preferences.set(cacheLimit, forKey: "previewCacheLimit")
    return AppModel(preferences: preferences)
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
