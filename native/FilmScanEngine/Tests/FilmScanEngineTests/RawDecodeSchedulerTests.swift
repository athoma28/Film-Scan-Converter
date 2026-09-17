import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Prioritized cancellable RAW work", .serialized)
struct RawDecodeSchedulerTests {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) {
      lock.lock()
      defer { lock.unlock() }
      values.append(value)
    }
    var snapshot: [Int] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  @Test("Cancelling a caller reaches its native cancellation flag")
  func activeCancellation() async throws {
    let scheduler = RawDecodeScheduler()
    let state = State()
    let task = Task {
      try await scheduler.run {
        state.append(1)
        let token = try #require(RawDecodeCancellation.current)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
          try token.checkCancellation()
          Thread.sleep(forTimeInterval: 0.001)
        }
        Issue.record("Cancellation did not reach the worker")
      }
    }
    try await waitUntil { state.snapshot == [1] }
    task.cancel()
    do {
      try await task.value
      Issue.record("Cancelled work succeeded")
    } catch is CancellationError {}
    let next = try await scheduler.run { 42 }
    #expect(next == 42)
  }

  @Test("Selected work preempts an active speculative decode")
  func selectedPreemptsLookahead() async throws {
    let scheduler = RawDecodeScheduler()
    let state = State()
    let speculation = Task {
      try await scheduler.run(priority: .lookahead) {
        state.append(1)
        let token = try #require(RawDecodeCancellation.current)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
          try token.checkCancellation()
          Thread.sleep(forTimeInterval: 0.001)
        }
        Issue.record("Speculative work was not interrupted")
      }
    }
    try await waitUntil { state.snapshot == [1] }
    let result = try await scheduler.run(priority: .selected) {
      state.append(2)
      return 7
    }
    #expect(result == 7)
    do {
      try await speculation.value
      Issue.record("Speculation should be cancelled")
    } catch is CancellationError {}
    #expect(state.snapshot == [1, 2])
  }

  @Test("Queued cancellation completes promptly and export precedes selected work")
  func queuedCancellationAndPriority() async throws {
    let scheduler = RawDecodeScheduler()
    let state = State()
    let active = Task {
      try await scheduler.run(priority: .export) {
        state.append(0)
        let token = try #require(RawDecodeCancellation.current)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
          try token.checkCancellation()
          Thread.sleep(forTimeInterval: 0.001)
        }
      }
    }
    defer { active.cancel() }
    try await waitUntil { state.snapshot == [0] }
    let selected = Task { try await scheduler.run(priority: .selected) { state.append(1) } }
    let cancelled = Task { try await scheduler.run(priority: .lookahead) { state.append(2) } }
    let export = Task { try await scheduler.run(priority: .export) { state.append(3) } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await scheduler.queuedRequestCount != 3 {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(1))
    }
    cancelled.cancel()
    do {
      try await cancelled.value
      Issue.record("Queued cancellation succeeded")
    } catch is CancellationError {}
    #expect(state.snapshot == [0])
    active.cancel()
    do {
      try await active.value
      Issue.record("Active cancellation succeeded")
    } catch is CancellationError {}
    try await selected.value
    try await export.value
    #expect(state.snapshot == [0, 3, 1])
  }

  @Test(
    "Real RAW cancellation releases the decoder and allows a subsequent decode",
    .enabled(if: !SampleRawCorpus.rawURLs().isEmpty))
  func nativeCancellation() async throws {
    let url = try #require(SampleRawCorpus.rawURLs().first)
    let scheduler = RawDecodeScheduler()
    let state = State()
    let task = Task {
      try await scheduler.run {
        state.append(1)
        return try RawImageDecoder.decode(
          url, fullResolution: true, profile: .rawTherapeeCameraScan)
      }
    }
    try await waitUntil { state.snapshot == [1] }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled RAW decode succeeded")
    } catch is CancellationError {}
    let result = try await scheduler.run {
      try RawImageDecoder.decode(url, profile: .rawTherapeeCameraScan, maxDimension: 640)
    }
    #expect(result.image.width > 0)
  }

  @Test(
    "Scheduled final-quality RAW keeps every direct decoder boundary hash",
    .enabled(if: !SampleRawCorpus.rawURLs().isEmpty))
  func scheduledDecodeParity() async throws {
    let url = try #require(SampleRawCorpus.rawURLs().first)
    let scheduler = RawDecodeScheduler()
    let scheduled = try await scheduler.run(priority: .export) {
      try RawImageDecoder.decode(
        url, fullResolution: true, profile: .rawTherapeeCameraScan,
        collectDiagnostics: true
      ).diagnostics
    }
    let direct = try RawImageDecoder.decode(
      url, fullResolution: true, profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    ).diagnostics
    #expect(scheduled?.hasCompleteStageDigests == true)
    #expect(scheduled == direct)
  }

  private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !ready() {
      if ContinuousClock.now >= deadline { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}
