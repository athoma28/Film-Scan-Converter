import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Open roll storage and coalesced persistence", .serialized)
@MainActor
struct OpenRollPersistenceTests {
  @Test("Roll state preserves order, selection, and offline paths through an atomic round trip")
  func roundTripAndNormalization() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OpenRollStore(baseDirectory: directory)
    #expect(try store.load() == nil)
    let first = directory.appendingPathComponent("first.RAF").path
    let second = directory.appendingPathComponent("second.png").path
    let alias = directory.appendingPathComponent("nested/../first.RAF").path
    let state = OpenRollStore.State(
      paths: [
        second, first, alias, "relative.png", "/tmp/readme.txt", "https://example.com/scan.jpg",
      ],
      selection: alias,
      selectedPaths: [second, "/tmp/outside.jpg"])
    #expect(state.paths == [second, first])
    #expect(state.selection == first)
    #expect(state.selectedPaths == [first, second])
    #expect(!FileManager.default.fileExists(atPath: first))
    try store.save(state)
    #expect(try store.load() == state)

    let noSelection = OpenRollStore.State(
      paths: [first], selection: second, selectedPaths: [second])
    #expect(noSelection.selection == nil)
    #expect(noSelection.selectedPaths.isEmpty)
    try store.save(noSelection)
    #expect(try store.load() == noSelection)
    try store.save(.init(paths: []))
    #expect(try store.load() == .init(paths: []))
  }

  @Test("Decoded paths are normalized without discarding currently unavailable scans")
  func normalizesDecodedState() throws {
    let data = Data(
      #"{"paths":["/offline/scans/a.RAF","/offline/scans/./a.RAF","/offline/scans/b.png","relative.jpg","/tmp/no.txt"],"selection":"/offline/scans/./a.RAF","selectedPaths":["/offline/scans/b.png","/missing/outside.tif"]}"#
        .utf8)
    let state = try JSONDecoder().decode(OpenRollStore.State.self, from: data)
    #expect(state.paths == ["/offline/scans/a.RAF", "/offline/scans/b.png"])
    #expect(state.selection == "/offline/scans/a.RAF")
    #expect(state.selectedPaths == ["/offline/scans/a.RAF", "/offline/scans/b.png"])
  }

  @Test("Unknown schema is rejected before attempting to decode its payload")
  func validatesVersionBeforePayload() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OpenRollStore(baseDirectory: directory)
    let original = Data(#"{"schemaVersion":99,"state":"a future payload"}"#.utf8)
    try original.write(to: store.fileURL)
    #expect(throws: OpenRollStore.StoreError.unsupportedSchemaVersion(99)) {
      try store.load()
    }
    #expect(throws: OpenRollStore.StoreError.unsupportedSchemaVersion(99)) {
      try store.save(.init(paths: []))
    }
    #expect(try Data(contentsOf: store.fileURL) == original)
  }

  @Test(
    "Every save preserves corrupt or incompatible existing roll documents",
    arguments: [
      "not json", #"{"state":{"paths":[]}}"#,
      #"{"schemaVersion":1,"state":{"paths":42}}"#,
      #"{"schemaVersion":1,"state":{"paths":[],"selectedPaths":42}}"#,
      #"{"schemaVersion":0,"state":{"paths":[]}}"#,
    ])
  func refusesToOverwriteUnreadableDocuments(document: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OpenRollStore(baseDirectory: directory)
    // A successful startup read cannot authorize a later destructive overwrite.
    try store.save(.init(paths: ["/offline/first.tif"]))
    _ = try store.load()
    let original = Data(document.utf8)
    try original.write(to: store.fileURL)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(.init(paths: [])) }
    #expect(try Data(contentsOf: store.fileURL) == original)
    try FileManager.default.removeItem(at: store.fileURL)
    let recovered = OpenRollStore.State(paths: ["/offline/recovered.jpg"])
    try store.save(recovered)
    #expect(try store.load() == recovered)
  }

  @Test("Navigation bursts keep one pending snapshot and save the latest off main")
  func coalescesSnapshots() async throws {
    let probe = OpenRollWriteProbe()
    let writer = OpenRollPersistence(debounce: 60, maximumDelay: 60, save: probe.save)
    var lastRevision: UInt64 = 0
    for index in 0..<1_000 {
      let revision = writer.submit(snapshot(index))
      #expect(revision > lastRevision)
      lastRevision = revision
    }
    #expect(writer.pendingSnapshotCount == 1)
    #expect(writer.hasUnsavedChanges)
    try await writer.flush()
    #expect(probe.states == [snapshot(999)])
    #expect(!probe.savedOnMainThread)
    #expect(!writer.hasUnsavedChanges)
    #expect(writer.pendingSnapshotCount == 0)
    try await writer.flush()
    #expect(probe.states.count == 1)
  }

  @Test("A newer snapshot or closing the roll during a slow save wins in the next write")
  func snapshotsDuringWrite() async throws {
    let probe = OpenRollWriteProbe(blockFirstWrite: true)
    defer { probe.releaseFirstWrite() }
    let writer = OpenRollPersistence(debounce: 60, maximumDelay: 60, save: probe.save)
    writer.submit(snapshot(1))
    writer.requestFlush()
    try await waitUntil { probe.startedCount == 1 }
    for index in 2..<500 { writer.submit(snapshot(index)) }
    writer.submit(.init(paths: []))
    #expect(writer.pendingSnapshotCount == 1)
    let flushed = Task { try await writer.flush() }
    probe.releaseFirstWrite()
    try await flushed.value
    #expect(probe.states == [snapshot(1), .init(paths: [])])
    #expect(!writer.hasUnsavedChanges)
  }

  @Test("A failed snapshot is retained and explicit flush retries the same revision")
  func retriesFailedSnapshot() async throws {
    let probe = OpenRollWriteProbe(failuresRemaining: 1)
    let writer = OpenRollPersistence(
      debounce: 60, maximumDelay: 60, save: probe.save, onCompletion: probe.recordCompletion)
    let revision = writer.submit(snapshot(2))
    do {
      try await writer.flush()
      Issue.record("The failed save unexpectedly succeeded")
    } catch {
      #expect(error is OpenRollWriteProbe.WriteFailure)
    }
    #expect(writer.hasUnsavedChanges)
    #expect(probe.completions == [.init(revision: revision, succeeded: false)])
    try await writer.flush()
    #expect(probe.states == [snapshot(2)])
    #expect(
      probe.completions == [
        .init(revision: revision, succeeded: false), .init(revision: revision, succeeded: true),
      ])
    #expect(!writer.hasUnsavedChanges)
  }

  @Test("A newer snapshot supersedes a failed save after storage recovers")
  func latestSnapshotWinsAfterStorageRecovery() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OpenRollStore(baseDirectory: directory)
    let original = Data("unreadable".utf8)
    try original.write(to: store.fileURL)
    let writer = OpenRollPersistence(debounce: 60, maximumDelay: 60, save: store.save)
    writer.submit(snapshot(1))
    do {
      try await writer.flush()
      Issue.record("Saving over the unreadable roll unexpectedly succeeded")
    } catch {}
    #expect(try Data(contentsOf: store.fileURL) == original)
    writer.submit(snapshot(2))
    try FileManager.default.removeItem(at: store.fileURL)
    try await writer.flush()
    #expect(try store.load() == snapshot(2))
    #expect(!writer.hasUnsavedChanges)
  }

  @Test("Debounce writes without an explicit flush and continuous navigation cannot starve saves")
  func debounceAndMaximumDelay() async throws {
    let probe = OpenRollWriteProbe()
    let writer = OpenRollPersistence(debounce: 0.15, maximumDelay: 0.4, save: probe.save)
    writer.submit(snapshot(1))
    try await waitUntil { probe.states.count == 1 }
    for index in 2...12 { writer.submit(snapshot(index)) }
    let started = ContinuousClock.now
    var index = 12
    while probe.states.count == 1 {
      index += 1
      writer.submit(snapshot(index))
      try #require(
        ContinuousClock.now - started < .seconds(3), "Continuous navigation starved saving")
      try await Task.sleep(for: .milliseconds(10))
    }
    writer.submit(snapshot(999))
    try await writer.flush()
    #expect(probe.states.last == snapshot(999))
  }

  private func snapshot(_ index: Int) -> OpenRollStore.State {
    .init(paths: ["/offline/scans/\(index).tif"], selection: "/offline/scans/\(index).tif")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-open-roll-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for open roll persistence")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class OpenRollWriteProbe: @unchecked Sendable {
  struct WriteFailure: Error {}
  struct Completion: Equatable {
    let revision: UInt64
    let succeeded: Bool
  }

  private let lock = NSLock()
  private let firstWriteGate = DispatchSemaphore(value: 0)
  private let blockFirstWrite: Bool
  private var savedStates: [OpenRollStore.State] = []
  private var completed: [Completion] = []
  private var started = 0
  private var failuresRemaining: Int
  private var wasOnMainThread = false

  init(blockFirstWrite: Bool = false, failuresRemaining: Int = 0) {
    self.blockFirstWrite = blockFirstWrite
    self.failuresRemaining = failuresRemaining
  }

  var states: [OpenRollStore.State] { lock.withLock { savedStates } }
  var startedCount: Int { lock.withLock { started } }
  var savedOnMainThread: Bool { lock.withLock { wasOnMainThread } }
  var completions: [Completion] { lock.withLock { completed } }

  func save(_ state: OpenRollStore.State) throws {
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

  func recordCompletion(_ revision: UInt64, _ result: Result<Void, Error>) {
    let succeeded: Bool
    switch result {
    case .success: succeeded = true
    case .failure: succeeded = false
    }
    lock.withLock { completed.append(.init(revision: revision, succeeded: succeeded)) }
  }

  func releaseFirstWrite() { firstWriteGate.signal() }
}
