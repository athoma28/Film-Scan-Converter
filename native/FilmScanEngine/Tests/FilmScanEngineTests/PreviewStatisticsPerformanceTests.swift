import CryptoKit
import Darwin
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Retained preview statistics", .serialized)
struct PreviewStatisticsMemoizationTests {
  @Test("Statistics stay lazy and are computed once for a retained raster")
  func resolvesOnlyOnce() throws {
    let expected = try fixtureStatistics()
    let state = StatisticsResolutionState()
    let sample = RenderedPreviewStatistics {
      state.beganComputation()
      return expected
    }
    #expect(sample.resolvedValue == nil)
    #expect(state.snapshot.computations == 0)

    let first = sample.resolve()
    #expect(first.didCompute)
    #expect(first.statistics == expected)
    #expect(sample.resolvedValue == expected)
    for _ in 0..<8 {
      let reused = sample.resolve()
      #expect(!reused.didCompute)
      #expect(reused.statistics == expected)
    }
    #expect(state.snapshot.computations == 1)
  }

  @Test("Concurrent resolutions share one result and publication never waits for sampling")
  func concurrentResolutionAndNonblockingRead() throws {
    let expected = try fixtureStatistics()
    let state = StatisticsResolutionState()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let probeReturned = DispatchSemaphore(value: 0)
    let completed = DispatchGroup()
    let sample = RenderedPreviewStatistics {
      state.beganComputation()
      entered.signal()
      if release.wait(timeout: .now() + 5) != .success {
        state.recordComputationTimeout()
      }
      return expected
    }
    // Every wait is bounded, including the gated compute, so a broken lock
    // contract fails this test without leaving the test process deadlocked.
    defer {
      release.signal()
      _ = completed.wait(timeout: .now() + 6)
    }
    for _ in 0..<8 {
      DispatchQueue.global(qos: .userInitiated).async(group: completed) {
        started.signal()
        let result = sample.resolve()
        state.record(result.statistics, didCompute: result.didCompute)
      }
    }
    try #require(entered.wait(timeout: .now() + 3) == .success)
    for _ in 0..<8 {
      try #require(started.wait(timeout: .now() + 3) == .success)
    }
    DispatchQueue.global(qos: .userInitiated).async(group: completed) {
      state.recordProbe(wasNil: sample.resolvedValue == nil)
      probeReturned.signal()
    }
    // This read must finish while compute still holds the lock, not after
    // release. That is the publication/main-actor nonblocking contract.
    #expect(probeReturned.wait(timeout: .now() + 1) == .success)
    release.signal()
    try #require(completed.wait(timeout: .now() + 3) == .success)
    let snapshot = state.snapshot
    #expect(snapshot.computations == 1)
    #expect(!snapshot.computationTimedOut)
    #expect(snapshot.probeWasNil == true)
    #expect(snapshot.results.count == 8)
    #expect(snapshot.results.allSatisfy { $0 == expected })
    #expect(snapshot.freshResults == 1)
    #expect(sample.resolvedValue == expected)
  }

  private func fixtureStatistics() throws -> RenderReadyImageStatistics {
    try #require(
      UInt16Image(
        width: 2, height: 2, channels: 3,
        pixels: [0, 200, 800, 1_000, 8_000, 16_000, 20_000, 24_000, 30_000, 65_535, 60_000, 55_000]
      ).previewStatistics())
  }
}

@Suite("Real RAW retained-statistics performance", .serialized)
struct PreviewStatisticsPerformanceTests {
  @Test(
    "Compare repeated full-preview sampling with memoized statistics",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PREVIEW_STATISTICS_BENCHMARK"] == "1",
      "set RUN_PREVIEW_STATISTICS_BENCHMARK=1 with the local Fuji 400 corpus")
  )
  func measureRetainedStatistics() throws {
    #if DEBUG
      try #require(false, "Statistics comparisons require swift test -c release")
    #endif
    let input = SampleRawCorpus.url(relativePath: "fuji400-fresh/DSCF2833.RAF")
    try #require(FileManager.default.fileExists(atPath: input.path), "Missing local RAW fixture")
    let decoded = try RawImageDecoder.decode(
      input, fullResolution: false, profile: .rawTherapeeCameraScan, maxDimension: 100_000)
    let source = decoded.image
    let analysis = source.resizedToFit(maxDimension: 256)
    let parameters = LookRecipe.cleanInvert.applying(
      to: FilmBase.colorC41.applyingInvert(to: ProcessingParameters()))
    try #require(parameters.photoAdjustments.schemaVersion == 2)
    StillPreviewRenderer.warmUp()
    let renderer = try #require(StillPreviewRenderer(image: source, analysisImage: analysis))
    try #require(renderer.supports(parameters: parameters, showOriginal: false))
    let raster = try #require(renderer.render(parameters: parameters, showOriginal: false))
    // Consume and warm this exact immutable CGImage before either timed arm.
    // Decode, rendering, first Core Image realization, and warmup are excluded.
    let expected = try #require(StillPreviewRenderer.statistics(for: raster))
    try #require(expected.sampleCount > 0)
    try #require(StillPreviewRenderer.statistics(for: raster) == expected)
    let state = StatisticsResolutionState()
    let retained = RenderedPreviewStatistics {
      state.beganComputation()
      return StillPreviewRenderer.statistics(for: raster) ?? .empty
    }
    let firstStart = ContinuousClock.now
    let first = retained.resolve()
    let initialResolutionMilliseconds = milliseconds(firstStart)
    try #require(first.didCompute && first.statistics == expected)

    let repetitions = 8
    var directSamples: [Double] = []
    var cachedSamples: [Double] = []
    var orders: [[String]] = []
    for index in 0..<repetitions {
      let order = index.isMultiple(of: 2) ? ["direct", "cached"] : ["cached", "direct"]
      orders.append(order)
      for mode in order {
        if mode == "direct" {
          let start = ContinuousClock.now
          let actual = StillPreviewRenderer.statistics(for: raster)
          directSamples.append(milliseconds(start))
          try #require(actual == expected, "Direct statistics changed for an immutable raster")
        } else {
          let start = ContinuousClock.now
          let actual = retained.resolve()
          cachedSamples.append(milliseconds(start))
          try #require(!actual.didCompute && actual.statistics == expected)
        }
      }
    }
    try #require(state.snapshot.computations == 1)
    let report: [String: Any] = [
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
      "hardware": hardwareDescription(),
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
      "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
      "configuration": "release",
      "sourceRevision": try gitOutput(["rev-parse", "HEAD"]),
      "workingTreeStatus": try gitOutput(["status", "--short"]),
      "input": "sample-raw/fuji400-fresh/DSCF2833.RAF",
      "inputSHA256": SHA256.hash(data: try Data(contentsOf: input, options: .mappedIfSafe))
        .map { String(format: "%02x", $0) }.joined(),
      "decodeProfile": "rawTherapeeCameraScan; fullResolution=false; maxDimension=100000",
      "decoderVersion": decoded.decoderVersion,
      "demosaicWorkers": decoded.demosaicWorkerCount,
      "unpackWorkers": decoded.unpackWorkerCount,
      "render": "Color C-41 / Clean Invert / photographic tone version 2 / no geometry edits",
      "previewDimensions": [raster.width, raster.height],
      "immutableAnalysisDimensions": [analysis.width, analysis.height],
      "statisticsMaximumDimension": 256,
      "statisticsSampleCount": expected.sampleCount,
      "warmupDirectCalls": 2,
      "repetitions": repetitions,
      "orders": orders,
      "initialMemoizedResolutionMilliseconds": initialResolutionMilliseconds,
      "direct": summary(directSamples),
      "cached": summary(cachedSamples),
      "memoizedComputationCount": state.snapshot.computations,
      "exactStatisticsAgreement": true,
      "note":
        "Eight counterbalanced pairs on one warmed immutable full-sensor one-pass preview raster. Direct calls repeat the production bounded CGContext statistics consumer; cached calls resolve the same already-computed RenderedPreviewStatistics. Initial memoized computation is reported separately and includes a test counter. Assertions and JSON assembly are outside timing. This measures avoided repeated diagnostics work only; it does not measure app navigation, input-to-screen latency, cold rendering, export, memory savings, or tail latency. No image files are written.",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let output = ProcessInfo.processInfo.environment["FSC_STATISTICS_BENCHMARK_OUTPUT"] {
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    print("PREVIEW_STATISTICS \(String(decoding: data, as: UTF8.self))")
  }

  private func summary(_ samples: [Double]) -> [String: Any] {
    let sorted = samples.sorted()
    return [
      "samplesMilliseconds": samples,
      "medianMilliseconds": (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2,
      "minimumMilliseconds": sorted[0],
      "maximumMilliseconds": sorted[sorted.count - 1],
    ]
  }

  private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
  }

  private func hardwareDescription() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "unavailable" }
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private func gitOutput(_ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", SampleRawCorpus.repositoryRoot.path] + arguments
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class StatisticsResolutionState: @unchecked Sendable {
  struct Snapshot {
    var computations = 0
    var computationTimedOut = false
    var results: [RenderReadyImageStatistics] = []
    var freshResults = 0
    var probeWasNil: Bool?
  }
  private let lock = NSLock()
  private var value = Snapshot()

  var snapshot: Snapshot { lock.withLock { value } }
  func beganComputation() { lock.withLock { value.computations += 1 } }
  func recordComputationTimeout() { lock.withLock { value.computationTimedOut = true } }
  func recordProbe(wasNil: Bool) { lock.withLock { value.probeWasNil = wasNil } }
  func record(_ statistics: RenderReadyImageStatistics, didCompute: Bool) {
    lock.withLock {
      value.results.append(statistics)
      if didCompute { value.freshResults += 1 }
    }
  }
}
