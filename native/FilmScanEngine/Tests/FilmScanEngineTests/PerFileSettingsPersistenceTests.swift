import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Coalesced per-file settings persistence", .serialized)
@MainActor
struct PerFileSettingsPersistenceTests {
  private let empty = PerFileSettingsStore.State(settingsByPath: [:], editedPaths: [])

  @Test("Input bursts keep one delta per path and encode only the final values off main")
  @MainActor
  func coalescesInputBursts() async throws {
    let probe = SettingsWriteProbe()
    let writer = PerFileSettingsPersistence(
      initialState: empty, debounce: 60, maximumDelay: 60, save: probe.save)
    var lastRevision: UInt64 = 0
    for index in 0..<1_000 {
      let revision = writer.submit(
        .set(path: "scan", parameters: parameters(exposure: Double(index)), edited: true))
      #expect(revision > lastRevision)
      lastRevision = revision
    }
    writer.submit(.set(path: "other", parameters: parameters(exposure: -1), edited: false))
    #expect(writer.pendingChangeCount == 2)
    try await writer.flush()
    #expect(probe.states.count == 1)
    #expect(probe.states.last?.settingsByPath["scan"]?.photoAdjustments.exposureEV == 999)
    #expect(probe.states.last?.settingsByPath["other"]?.photoAdjustments.exposureEV == -1)
    #expect(probe.states.last?.editedPaths == ["scan"])
    #expect(!probe.savedOnMainThread)
    #expect(!writer.hasUnsavedChanges)
    try await writer.flush()
    #expect(probe.states.count == 1)
  }

  @Test("Remove and reset cannot resurrect older deltas or edited markers")
  func removeAndResetOrdering() async throws {
    let probe = SettingsWriteProbe()
    let writer = PerFileSettingsPersistence(
      initialState: .init(settingsByPath: ["old": parameters(exposure: 2)], editedPaths: ["old"]),
      debounce: 60, maximumDelay: 60, save: probe.save)
    writer.submit(.set(path: "discarded", parameters: parameters(exposure: 1), edited: true))
    writer.submit(.reset)
    writer.submit(.set(path: "scan", parameters: parameters(exposure: 4), edited: true))
    writer.submit(.remove(path: "scan"))
    writer.submit(.set(path: "scan", parameters: parameters(exposure: -2), edited: false))
    writer.submit(.set(path: "removed", parameters: parameters(exposure: 8), edited: true))
    writer.submit(.remove(path: "removed"))
    try await writer.flush()
    #expect(
      probe.states.last
        == .init(
          settingsByPath: ["scan": parameters(exposure: -2)], editedPaths: []))
    writer.submit(.reset)
    try await writer.flush()
    #expect(probe.states.last == empty)
  }

  @Test("Edits and a reset received during a slow save stay bounded and win in the next save")
  func changesDuringWrite() async throws {
    let probe = SettingsWriteProbe(blockFirstWrite: true)
    defer { probe.releaseFirstWrite() }
    let writer = PerFileSettingsPersistence(
      initialState: empty, debounce: 60, maximumDelay: 60, save: probe.save)
    writer.submit(.set(path: "old", parameters: parameters(exposure: 1), edited: true))
    writer.requestFlush()
    try await waitUntil { probe.startedCount == 1 }
    writer.submit(.reset)
    for index in 0..<500 {
      writer.submit(
        .set(path: "scan", parameters: parameters(exposure: Double(index)), edited: true))
    }
    #expect(writer.pendingChangeCount == 2)
    let flushed = Task { try await writer.flush() }
    probe.releaseFirstWrite()
    try await flushed.value
    #expect(probe.states.count == 2)
    #expect(probe.states.first?.settingsByPath["old"] != nil)
    #expect(
      probe.states.last
        == .init(
          settingsByPath: ["scan": parameters(exposure: 499)], editedPaths: ["scan"]))
    #expect(!writer.hasUnsavedChanges)
  }

  @Test("Failures are reported, flush throws, and retry keeps the full latest state")
  func retriesFailureWithoutLosingDeltas() async throws {
    let probe = SettingsWriteProbe(failuresRemaining: 1)
    let writer = PerFileSettingsPersistence(
      initialState: empty, debounce: 60, maximumDelay: 60,
      save: probe.save, onFailure: probe.recordFailure)
    writer.submit(.set(path: "scan", parameters: parameters(exposure: 2), edited: true))
    do {
      try await writer.flush()
      Issue.record("The failed save unexpectedly succeeded")
    } catch {
      #expect(error is SettingsWriteProbe.WriteFailure)
    }
    #expect(writer.hasUnsavedChanges)
    #expect(probe.failureCount == 1)
    writer.submit(.set(path: "scan", parameters: parameters(exposure: 3), edited: false))
    writer.submit(.set(path: "other", parameters: parameters(exposure: -1), edited: true))
    try await writer.flush()
    #expect(probe.states.last?.settingsByPath["scan"]?.photoAdjustments.exposureEV == 3)
    #expect(probe.states.last?.settingsByPath["other"]?.photoAdjustments.exposureEV == -1)
    #expect(probe.states.last?.editedPaths == ["other"])
    #expect(!writer.hasUnsavedChanges)
  }

  @Test("Keyboard edits debounce and continuous gestures save before their release")
  func debounceAndPeriodicFlush() async throws {
    let probe = SettingsWriteProbe()
    let writer = PerFileSettingsPersistence(
      initialState: empty, debounce: 0.04, maximumDelay: 0.12, save: probe.save)
    writer.submit(.set(path: "scan", parameters: parameters(exposure: 1), edited: true))
    try await waitUntil { probe.states.count == 1 }

    let started = ContinuousClock.now
    var index = 0
    while probe.states.count == 1 {
      index += 1
      writer.submit(
        .set(path: "scan", parameters: parameters(exposure: Double(index)), edited: true))
      try #require(ContinuousClock.now - started < .seconds(3), "Periodic save was starved")
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(index > 1)
    writer.submit(.set(path: "scan", parameters: parameters(exposure: 999), edited: true))
    try await writer.flush()
    #expect(probe.states.last?.settingsByPath["scan"]?.photoAdjustments.exposureEV == 999)
  }

  @Test("Gesture release, reset, undo, and final flush survive relaunch with a 640-file history")
  @MainActor
  func representativeHistoryEventHandlerAndRelaunch() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    let input = directory.appendingPathComponent("synthetic-0.tif")
    let saved = Dictionary(
      uniqueKeysWithValues: (0..<640).map { index in
        (directory.appendingPathComponent("synthetic-\(index).tif").path, ProcessingParameters())
      })
    try store.save(.init(settingsByPath: saved, editedPaths: []))
    let model = AppModel(settingsStore: store)
    // Exercise the real setters without decoding or rendering a source image.
    model.selection = input
    model.beginEditingGesture(named: "Exposure")
    var timings: [Double] = []
    for index in 0..<120 {
      let started = ContinuousClock.now
      model.setExposureEV(Double(index) / 100)
      let elapsed = ContinuousClock.now - started
      timings.append(
        Double(elapsed.components.seconds) * 1_000
          + Double(elapsed.components.attoseconds) / 1e15)
    }
    model.endEditingGesture()
    try await waitUntil {
      (try? store.loadState().settingsByPath[input.path]?.photoAdjustments.exposureEV) == 1.19
    }
    model.resetCorrections()
    model.undo()
    #expect(model.parameters.photoAdjustments.exposureEV == 1.19)
    try await model.flushSettings()
    let relaunched = AppModel(settingsStore: store)
    relaunched.selection = input
    // loadSelection applies persisted parameters synchronously before any decode.
    relaunched.loadSelection()
    #expect(relaunched.parameters.photoAdjustments.exposureEV == 1.19)
    relaunched.selection = nil
    relaunched.loadSelection()
    let state = try store.loadState()
    #expect(state.settingsByPath.count == 640)
    #expect(state.editedPaths == [input.path])
    #expect(
      state.settingsByPath[directory.appendingPathComponent("synthetic-639.tif").path]
        == ProcessingParameters())
    print(
      "640-file history, 120 setter events (no decode/render): mean \(timings.reduce(0, +) / Double(timings.count)) ms, max \(timings.max() ?? 0) ms; flush and relaunch verified."
    )
  }

  @Test("The app reports save failures and an explicit flush can retry after storage recovers")
  @MainActor
  func appReportsFailureAndRetries() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let blockedDirectory = root.appendingPathComponent("settings")
    try Data("not a directory".utf8).write(to: blockedDirectory)
    let store = PerFileSettingsStore(baseDirectory: blockedDirectory)
    let model = AppModel(settingsStore: store)
    model.selection = root.appendingPathComponent("synthetic.tif")
    model.setExposureEV(1.25)
    do {
      try await model.flushSettings()
      Issue.record("The unwritable settings location unexpectedly succeeded")
    } catch {}
    try await waitUntil { model.settingsStatus.contains("could not be saved") }
    #expect(model.parameters.photoAdjustments.exposureEV == 1.25)
    try FileManager.default.removeItem(at: blockedDirectory)
    try await model.flushSettings()
    try await waitUntil { model.settingsStatus.isEmpty && model.statusKind != .error }
    #expect(
      try store.loadState().settingsByPath[model.selection!.path]?.photoAdjustments.exposureEV
        == 1.25)
  }

  @Test("Persistence completions ignore stale results and preserve unrelated status on recovery")
  func completionStatusOrdering() {
    let model = AppModel()
    let failure = Result<Void, Error>.failure(SettingsWriteProbe.WriteFailure())
    model.handleSettingsPersistenceCompletion(revision: 2, result: failure)
    let persistenceError = model.settingsStatus
    #expect(model.statusKind == .error)
    model.handleSettingsPersistenceCompletion(revision: 1, result: .success(()))
    #expect(model.settingsStatus == persistenceError)
    model.handleSettingsPersistenceCompletion(revision: 2, result: .success(()))
    #expect(model.settingsStatus.isEmpty)
    #expect(model.statusKind != .error)
    model.handleSettingsPersistenceCompletion(revision: 2, result: failure)
    model.handleSettingsPersistenceCompletion(revision: 1, result: failure)
    #expect(model.settingsStatus.isEmpty)
    #expect(model.statusKind != .error)

    model.handleSettingsPersistenceCompletion(revision: 3, result: failure)
    model.exportSelected()
    let exportError = model.status
    model.applyCurrentLookToSelectedFiles()
    let settingsNotice = model.settingsStatus
    model.handleSettingsPersistenceCompletion(revision: 3, result: .success(()))
    #expect(model.status == exportError)
    #expect(model.statusKind == .error)
    #expect(model.settingsStatus == settingsNotice)
  }

  private func parameters(exposure: Double) -> ProcessingParameters {
    var value = ProcessingParameters()
    value.photoAdjustments.exposureEV = exposure
    return value
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fsc-writer-\(UUID().uuidString)")
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for settings persistence")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// A bounded synthetic writer seam; only its first write can block.
private final class SettingsWriteProbe: @unchecked Sendable {
  struct WriteFailure: Error {}
  private let lock = NSLock()
  private let firstWriteGate = DispatchSemaphore(value: 0)
  private let blockFirstWrite: Bool
  private var savedStates: [PerFileSettingsStore.State] = []
  private var started = 0
  private var failuresRemaining: Int
  private var failures = 0
  private var wasOnMainThread = false

  init(blockFirstWrite: Bool = false, failuresRemaining: Int = 0) {
    self.blockFirstWrite = blockFirstWrite
    self.failuresRemaining = failuresRemaining
  }

  var states: [PerFileSettingsStore.State] { lock.withLock { savedStates } }
  var startedCount: Int { lock.withLock { started } }
  var failureCount: Int { lock.withLock { failures } }
  var savedOnMainThread: Bool { lock.withLock { wasOnMainThread } }

  func save(_ state: PerFileSettingsStore.State) throws {
    let first = lock.withLock {
      started += 1
      wasOnMainThread = wasOnMainThread || Thread.isMainThread
      return started == 1
    }
    if first && blockFirstWrite { firstWriteGate.wait() }
    try lock.withLock {
      if failuresRemaining > 0 {
        failuresRemaining -= 1
        throw WriteFailure()
      }
      savedStates.append(state)
    }
  }

  func releaseFirstWrite() { firstWriteGate.signal() }
  func recordFailure(_ error: Error) { lock.withLock { failures += 1 } }
}
