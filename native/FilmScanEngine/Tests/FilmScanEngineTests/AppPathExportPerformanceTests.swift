import Darwin
import Foundation
import Testing

@testable import FilmScanConverterMac

private let appPathExportBenchmarkRepositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

@Suite("App path export performance benchmark", .serialized)
@MainActor
struct AppPathExportPerformanceTests {
  private enum BenchmarkError: Error {
    case timedOut(String)
  }

  private struct MemorySample: Codable {
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let reusableBytes: UInt64
  }

  private struct FootprintSummary: Codable {
    let samplesBytes: [UInt64]
    let firstToLastGrowthBytes: Int64
    let minimumBytes: UInt64
    let maximumBytes: UInt64
  }

  private struct QueueCompletionSample: Codable {
    let queueIndex: Int
    let filename: String
    let completionMillisecondsSinceStart: Double
    let memoryAtProgressObservation: MemorySample
    let outputArtifactsRemoved: Int
  }

  private struct SequentialExportSample: Codable {
    let totalMilliseconds: Double
    let queueCompletions: [QueueCompletionSample]
    let observedPhysicalFootprint: FootprintSummary
    let memoryBeforeExport: MemorySample
    let memoryAfterExport: MemorySample
    let memoryAfterModelRelease: MemorySample
    let outputArtifactsRemoved: Int
    let outputArtifactsRemaining: Int
    let exportErrors: [String]
    let finalStatus: String
  }

  private struct CancellationSample: Codable {
    let requestDelayMilliseconds: Int
    let requestToCompletionMilliseconds: Double
    let progressAtRequest: Int
    let progressAtCompletion: Int
    let memoryBeforeExport: MemorySample
    let memoryAtRequest: MemorySample
    let memoryAfterCompletion: MemorySample
    let memoryAfterModelRelease: MemorySample
    let outputArtifactsRemoved: Int
    let outputArtifactsRemaining: Int
    let finalStatus: String
  }

  private struct Report: Codable {
    let generatedAt: String
    let hardware: String
    let uniqueFiles: [String]
    let queuedFiles: [String]
    let format: String
    let sequentialExport: SequentialExportSample
    let cancellation: CancellationSample
    let note: String
  }

  @Test("A short local corpus expands deterministically to ten queued jobs")
  func tenItemQueueContract() {
    let corpus = (0..<6).map { URL(fileURLWithPath: "/tmp/scan-\($0).raf") }
    let queue = expandedQueue(from: corpus, targetCount: 10)

    #expect(queue.count == 10)
    #expect(queue.map(\.lastPathComponent) == [
      "scan-0.raf", "scan-1.raf", "scan-2.raf", "scan-3.raf", "scan-4.raf",
      "scan-5.raf", "scan-0.raf", "scan-1.raf", "scan-2.raf", "scan-3.raf",
    ])
  }

  @Test("Post-file footprint summaries preserve signed growth")
  func footprintSummaryContract() {
    let growing = summarizeFootprint([100, 130, 120])
    #expect(growing.firstToLastGrowthBytes == 20)
    #expect(growing.minimumBytes == 100)
    #expect(growing.maximumBytes == 130)

    let shrinking = summarizeFootprint([130, 120, 90])
    #expect(shrinking.firstToLastGrowthBytes == -40)
    #expect(shrinking.minimumBytes == 90)
    #expect(shrinking.maximumBytes == 130)
  }

  @Test(
    "Measure ten sequential app exports and active-stage cancellation",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS"] == "1",
      "set RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS=1 to run the real app export benchmark")
  )
  func measureSequentialExportAndCancellation() async throws {
    let rawDirectory = appPathExportBenchmarkRepositoryRoot.appending(path: "sample-raw")
    let rawFiles = try FileManager.default.contentsOfDirectory(
      at: rawDirectory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension.lowercased() == "raf" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    #expect(rawFiles.count >= 4, "The app export benchmark needs at least four local RAF files")
    guard rawFiles.count >= 4 else { return }

    let corpus = Array(rawFiles.prefix(10))
    let queue = expandedQueue(from: corpus, targetCount: 10)
    let sequential = try await measureSequentialExport(corpus: corpus, queue: queue)
    let cancellation = try await measureCancellation(corpus: corpus, queue: queue)
    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      hardware: hardwareDescription(),
      uniqueFiles: corpus.map(\.lastPathComponent),
      queuedFiles: queue.map(\.lastPathComponent),
      format: "tiff",
      sequentialExport: sequential,
      cancellation: cancellation,
      note: "The app path imports the available local RAF corpus, starts Export All, and appends repeated source jobs only when fewer than ten unique RAFs are available. Every job independently performs the production full-resolution camera-scan decode, correction, geometry, and TIFF writer path. Completion observations may overlap the next decode; post-run and post-model-release physical footprint are the live-memory gates. Temporary outputs are removed after each observed completion and again at teardown. Cancellation is requested during the first full-resolution decode after the configured delay."
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let outputPath = ProcessInfo.processInfo.environment["APP_PATH_EXPORT_BENCHMARK_OUTPUT"] {
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
  }

  private func measureSequentialExport(
    corpus: [URL],
    queue: [URL]
  ) async throws -> SequentialExportSample {
    let workDirectory = try makeWorkDirectory(label: "sequential")
    defer { try? FileManager.default.removeItem(at: workDirectory) }
    let destination = workDirectory.appending(path: "output", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: true)

    let memoryBeforeExport = memorySample()
    var model: AppModel? = makeModel(cacheLimit: 2)
    try #require(model).importFiles(corpus)
    try await waitForInitialPreview(in: #require(model))
    try #require(model).setExportDestinationDirectory(destination)
    try #require(model).setExportFormat(.tiff)

    let start = ContinuousClock.now
    try beginQueue(queue, corpus: corpus, in: #require(model))
    var completions = [QueueCompletionSample]()
    var totalArtifactsRemoved = 0

    for queueIndex in queue.indices {
      try await waitUntil(
        "sequential export item \(queueIndex + 1)", timeout: .seconds(120)
      ) {
        model?.exportProgressCurrent ?? 0 >= queueIndex + 1 || model?.isExporting == false
      }
      let removed = try removeOutputArtifacts(in: destination)
      totalArtifactsRemoved += removed
      await Task.yield()
      try await Task.sleep(for: .milliseconds(25))
      completions.append(QueueCompletionSample(
        queueIndex: queueIndex + 1,
        filename: queue[queueIndex].lastPathComponent,
        completionMillisecondsSinceStart: milliseconds(since: start),
        memoryAtProgressObservation: memorySample(),
        outputArtifactsRemoved: removed
      ))
    }

    try await waitUntil("sequential export completion", timeout: .seconds(30)) {
      model?.isExporting == false
    }
    totalArtifactsRemoved += try removeOutputArtifacts(in: destination)
    let totalMilliseconds = milliseconds(since: start)
    let memoryAfterExport = memorySample()
    let exportErrors = try #require(model).exportErrors
    let finalStatus = try #require(model).status
    let finalProgress = try #require(model).exportProgressCurrent
    let finalTotal = try #require(model).exportProgressTotal
    let remainingBeforeRelease = try outputArtifactCount(in: destination)

    #expect(finalProgress == queue.count)
    #expect(finalTotal == queue.count)
    #expect(exportErrors.isEmpty)
    #expect(remainingBeforeRelease == 0)

    model = nil
    await Task.yield()
    try await Task.sleep(for: .milliseconds(100))
    let memoryAfterModelRelease = memorySample()
    let remainingAfterRelease = try outputArtifactCount(in: destination)

    return SequentialExportSample(
      totalMilliseconds: totalMilliseconds,
      queueCompletions: completions,
      observedPhysicalFootprint: summarizeFootprint(
        completions.map(\.memoryAtProgressObservation.physicalFootprintBytes)),
      memoryBeforeExport: memoryBeforeExport,
      memoryAfterExport: memoryAfterExport,
      memoryAfterModelRelease: memoryAfterModelRelease,
      outputArtifactsRemoved: totalArtifactsRemoved,
      outputArtifactsRemaining: remainingAfterRelease,
      exportErrors: exportErrors,
      finalStatus: finalStatus
    )
  }

  private func measureCancellation(
    corpus: [URL],
    queue: [URL]
  ) async throws -> CancellationSample {
    let workDirectory = try makeWorkDirectory(label: "cancellation")
    defer { try? FileManager.default.removeItem(at: workDirectory) }
    let destination = workDirectory.appending(path: "output", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: true)

    let delay = max(
      0,
      Int(ProcessInfo.processInfo.environment["APP_PATH_EXPORT_CANCEL_DELAY_MS"] ?? "250")
        ?? 250)
    let memoryBeforeExport = memorySample()
    var model: AppModel? = makeModel(cacheLimit: 2)
    try #require(model).importFiles(corpus)
    try await waitForInitialPreview(in: #require(model))
    try #require(model).setExportDestinationDirectory(destination)
    try #require(model).setExportFormat(.tiff)
    try beginQueue(queue, corpus: corpus, in: #require(model))

    try await Task.sleep(for: .milliseconds(delay))
    let progressAtRequest = try #require(model).exportProgressCurrent
    let memoryAtRequest = memorySample()
    let cancellationStart = ContinuousClock.now
    try #require(model).cancelExport()
    try await waitUntil("active-stage export cancellation", timeout: .seconds(120)) {
      model?.isExporting == false
    }
    let latency = milliseconds(since: cancellationStart)
    let memoryAfterCompletion = memorySample()
    let progressAtCompletion = try #require(model).exportProgressCurrent
    let finalStatus = try #require(model).status
    let removed = try removeOutputArtifacts(in: destination)

    #expect(try #require(model).exportQueueCount == 0)
    #expect(try #require(model).activeExportFilename == nil)
    #expect(finalStatus.localizedCaseInsensitiveContains("cancel"))
    #expect(try outputArtifactCount(in: destination) == 0)

    model = nil
    await Task.yield()
    try await Task.sleep(for: .milliseconds(100))
    let memoryAfterModelRelease = memorySample()
    let remaining = try outputArtifactCount(in: destination)

    return CancellationSample(
      requestDelayMilliseconds: delay,
      requestToCompletionMilliseconds: latency,
      progressAtRequest: progressAtRequest,
      progressAtCompletion: progressAtCompletion,
      memoryBeforeExport: memoryBeforeExport,
      memoryAtRequest: memoryAtRequest,
      memoryAfterCompletion: memoryAfterCompletion,
      memoryAfterModelRelease: memoryAfterModelRelease,
      outputArtifactsRemoved: removed,
      outputArtifactsRemaining: remaining,
      finalStatus: finalStatus
    )
  }

  private func beginQueue(
    _ queue: [URL],
    corpus: [URL],
    in model: AppModel
  ) throws {
    #expect(queue.starts(with: corpus))
    model.exportAll()
    #expect(model.isExporting)

    for url in queue.dropFirst(corpus.count) {
      model.selection = url
      model.selectedFiles = [url]
      model.addSelectedToExportQueue()
    }

    #expect(model.exportProgressTotal == queue.count)
  }

  private func expandedQueue(from corpus: [URL], targetCount: Int) -> [URL] {
    guard !corpus.isEmpty, targetCount > 0 else { return [] }
    return (0..<targetCount).map { corpus[$0 % corpus.count] }
  }

  private func summarizeFootprint(_ samples: [UInt64]) -> FootprintSummary {
    guard let first = samples.first, let last = samples.last else {
      return FootprintSummary(
        samplesBytes: samples,
        firstToLastGrowthBytes: 0,
        minimumBytes: 0,
        maximumBytes: 0)
    }
    return FootprintSummary(
      samplesBytes: samples,
      firstToLastGrowthBytes: Int64(last) - Int64(first),
      minimumBytes: samples.min() ?? 0,
      maximumBytes: samples.max() ?? 0)
  }

  private func makeModel(cacheLimit: Int) -> AppModel {
    let suiteName = "fsc-app-path-export-benchmark-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    preferences.set(cacheLimit, forKey: "previewCacheLimit")
    return AppModel(preferences: preferences)
  }

  private func makeWorkDirectory(label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "fsc-app-path-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func waitForInitialPreview(in model: AppModel) async throws {
    try await waitUntil("initial corrected preview", timeout: .seconds(30)) {
      model.previewImage != nil && model.renderStats.displayedRenders > 0
        && !model.isLoading && !model.isRendering
    }
  }

  private func waitUntil(
    _ label: String,
    timeout: Duration,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else { throw BenchmarkError.timedOut(label) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func removeOutputArtifacts(in directory: URL) throws -> Int {
    let artifacts = try outputArtifacts(in: directory)
    for artifact in artifacts {
      try FileManager.default.removeItem(at: artifact)
    }
    return artifacts.count
  }

  private func outputArtifactCount(in directory: URL) throws -> Int {
    try outputArtifacts(in: directory).count
  }

  private func outputArtifacts(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) * 1_000
      + Double(elapsed.components.attoseconds) / 1e15
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
