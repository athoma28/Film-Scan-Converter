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

    func waitForRelease(_ value: Int) throws {
      let token = try #require(RawDecodeCancellation.current)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !snapshot.contains(value) {
        try token.checkCancellation()
        try #require(ContinuousClock.now < deadline, "Decode gate was not released")
        Thread.sleep(forTimeInterval: 0.001)
      }
      try token.checkCancellation()
    }
  }

  @Test("Two workers overlap foreground and one neighbour without starting unbounded speculation")
  func boundedConcurrentDecodes() async throws {
    let scheduler = RawDecodeScheduler(maximumConcurrentDecodes: 2)
    let state = State()
    let foreground = Task {
      try await scheduler.run(priority: .selected) {
        state.append(0)
        try state.waitForRelease(9)
      }
    }
    defer { foreground.cancel() }
    try await waitUntil { state.snapshot.contains(0) }
    let neighbour = Task {
      try await scheduler.run(priority: .lookahead) {
        state.append(1)
        try state.waitForRelease(9)
      }
    }
    defer { neighbour.cancel() }
    try await waitUntil { state.snapshot.contains(1) }
    let pending = Task {
      try await scheduler.run(priority: .lookahead) { state.append(2) }
    }
    defer { pending.cancel() }
    try await waitUntil { await scheduler.queuedRequestCount == 1 }
    #expect(!state.snapshot.contains(2))
    // Export frees the speculative slot and runs before queued lookahead.
    let value = try await scheduler.run(priority: .export) {
      state.append(3)
      return 42
    }
    #expect(value == 42)
    do {
      try await neighbour.value
      Issue.record("Export should preempt the speculative worker")
    } catch is CancellationError {}
    state.append(9)
    try await foreground.value
    try await pending.value
    let order = state.snapshot
    let exportIndex = try #require(order.firstIndex(of: 3))
    let lookaheadIndex = try #require(order.firstIndex(of: 2))
    #expect(exportIndex < lookaheadIndex)
  }

  @Test("Selected work preserves a running neighbour when the second worker is free")
  func selectedUsesFreeWorkerWithoutCancellingLookahead() async throws {
    let scheduler = RawDecodeScheduler(maximumConcurrentDecodes: 2)
    let state = State()
    let neighbour = Task {
      try await scheduler.run(priority: .lookahead) {
        state.append(1)
        try state.waitForRelease(9)
        return 11
      }
    }
    defer { neighbour.cancel() }
    try await waitUntil { state.snapshot.contains(1) }

    let selected = Task {
      try await scheduler.run(priority: .selected) {
        state.append(2)
        return 42
      }
    }
    defer { selected.cancel() }
    // The selected request must start while the neighbour is still gated.
    try await waitUntil { state.snapshot.contains(2) }
    #expect(try await selected.value == 42)
    state.append(9)
    #expect(try await neighbour.value == 11)
    #expect(state.snapshot == [1, 2, 9])
  }

  @Test("Selected work preempts only the neighbour when both workers are occupied")
  func selectedPreemptsLookaheadWithBothWorkersBusy() async throws {
    let scheduler = RawDecodeScheduler(maximumConcurrentDecodes: 2)
    let state = State()
    let foreground = Task {
      try await scheduler.run(priority: .selected) {
        state.append(0)
        try state.waitForRelease(9)
        state.append(4)
        return 10
      }
    }
    defer { foreground.cancel() }
    try await waitUntil { state.snapshot.contains(0) }

    let neighbour = Task {
      try await scheduler.run(priority: .lookahead) {
        state.append(1)
        do {
          try state.waitForRelease(9)
        } catch is CancellationError {
          state.append(2)
          throw CancellationError()
        }
      }
    }
    defer { neighbour.cancel() }
    try await waitUntil { state.snapshot.contains(1) }

    let selected = Task {
      try await scheduler.run(priority: .selected) {
        state.append(3)
        return 42
      }
    }
    defer { selected.cancel() }
    try await waitUntil { state.snapshot.contains(3) }
    #expect(try await selected.value == 42)
    do {
      try await neighbour.value
      Issue.record("Selected work should preempt the speculative worker")
    } catch is CancellationError {}
    #expect(state.snapshot == [0, 1, 2, 3])

    // The original foreground worker remains alive and completes normally.
    state.append(9)
    #expect(try await foreground.value == 10)
    #expect(state.snapshot == [0, 1, 2, 3, 9, 4])
  }

  @Test("Cancelling a caller reaches its native cancellation flag")
  func activeCancellation() async throws {
    let scheduler = RawDecodeScheduler()
    let state = State()
    let task = Task {
      try await scheduler.run {
        state.append(1)
        try state.waitForRelease(9)
      }
    }
    defer { task.cancel() }
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
        try state.waitForRelease(9)
      }
    }
    defer { speculation.cancel() }
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
        try state.waitForRelease(9)
      }
    }
    defer { active.cancel() }
    try await waitUntil { state.snapshot == [0] }
    let selected = Task { try await scheduler.run(priority: .selected) { state.append(1) } }
    let cancelled = Task { try await scheduler.run(priority: .lookahead) { state.append(2) } }
    let export = Task { try await scheduler.run(priority: .export) { state.append(3) } }
    defer {
      selected.cancel()
      cancelled.cancel()
      export.cancel()
    }
    try await waitUntil { await scheduler.queuedRequestCount == 3 }
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
    defer { task.cancel() }
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

  private func waitUntil(_ ready: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !ready() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for scheduler state")
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}
