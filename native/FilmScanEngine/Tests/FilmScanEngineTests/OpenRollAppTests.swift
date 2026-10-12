import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Open roll app integration", .serialized)
@MainActor
struct OpenRollAppTests {
  @Test("Relaunch restores sidebar order, selections, and edits with empty history")
  func relaunchRestoresOpenRoll() async throws {
    let fixture = try Fixture(count: 3)
    defer { fixture.cleanUp() }
    let first = fixture.model()
    defer { first.closeAllScans() }

    first.importFiles(fixture.files)
    try await waitUntil { first.previewImage != nil && !first.isRendering }
    first.moveSidebarFiles(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    let expectedOrder = [fixture.files[2], fixture.files[0], fixture.files[1]]
    first.selection = fixture.files[1]
    first.selectedFiles = [fixture.files[1], fixture.files[2]]
    first.loadSelection()
    try await waitUntil { first.previewImage != nil && !first.isRendering }
    first.setFilmType(.colourNegative)
    first.setExposureEV(1.25)
    first.setVibrance(0.4)
    #expect(first.canUndo)
    try await first.flushSettings()

    let restored = fixture.model()
    defer { restored.closeAllScans() }

    #expect(restored.files == expectedOrder)
    #expect(restored.selection == fixture.files[1])
    #expect(restored.selectedFiles == [fixture.files[1], fixture.files[2]])
    #expect(restored.parameters.filmType == .colourNegative)
    #expect(restored.parameters.photoAdjustments.exposureEV == 1.25)
    #expect(restored.parameters.photoAdjustments.vibrance == 0.4)
    #expect(restored.hasEdits(for: fixture.files[1]))
    #expect(!restored.canUndo)
    #expect(!restored.canRedo)
    try await waitUntil { restored.previewImage != nil && !restored.isRendering }
    #expect(restored.parameters.photoAdjustments.exposureEV == 1.25)

    restored.loadSelection()
    try await restored.flushSettings()
    let saved = try #require(try fixture.rollStore.load())
    #expect(saved.paths == expectedOrder.map(\.path))
    #expect(saved.selection == fixture.files[1].path)
    #expect(saved.selectedPaths == Set([fixture.files[1].path, fixture.files[2].path]))
    first.closeAllScans()
    try await first.flushSettings()
    restored.closeAllScans()
    try await restored.flushSettings()
  }

  @Test("Closing a roll persists an empty session while retaining corrections for reimport")
  func closeKeepsPerFileCorrections() async throws {
    let fixture = try Fixture(count: 2)
    defer { fixture.cleanUp() }
    let model = fixture.model()
    defer { model.closeAllScans() }
    let input = fixture.files[0]

    model.importFiles(fixture.files)
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    model.setExposureEV(0.75)
    model.requestThumbnail(for: input)
    try await waitUntil { model.thumbnail(for: input) != nil }
    #expect(model.previewCacheSessionCount > 0)

    model.closeAllScans()
    #expect(model.files.isEmpty)
    #expect(model.selection == nil)
    #expect(model.selectedFiles.isEmpty)
    #expect(model.decodedImage == nil)
    #expect(model.previewImage == nil)
    #expect(model.previewCacheSessionCount == 0)
    #expect(model.thumbnailImages.isEmpty)
    #expect(model.thumbnailLoadingPaths.isEmpty)
    #expect(!model.previewBackgroundWorkIsActive)
    #expect(!model.isAnalyzingScanStacks)
    try await model.flushSettings()

    let saved = try #require(try fixture.rollStore.load())
    #expect(saved.paths.isEmpty)
    #expect(saved.selection == nil)
    #expect(saved.selectedPaths.isEmpty)
    let corrections = try fixture.settingsStore.loadState()
    #expect(corrections.settingsByPath[input.path]?.photoAdjustments.exposureEV == 0.75)
    #expect(corrections.editedPaths.contains(input.path))

    let restored = fixture.model()
    defer { restored.closeAllScans() }
    #expect(restored.files.isEmpty)
    #expect(restored.selection == nil)
    restored.importFiles([input])
    #expect(restored.parameters.photoAdjustments.exposureEV == 0.75)
    #expect(restored.hasEdits(for: input))
    #expect(!restored.canUndo)
    try await waitUntil { restored.previewImage != nil && !restored.isRendering }
    #expect(restored.parameters.photoAdjustments.exposureEV == 0.75)
    restored.closeAllScans()
    try await restored.flushSettings()
  }

  @Test("An offline active scan keeps its place and selections after restore and save")
  func restoreRetainsMissingActiveScan() async throws {
    let fixture = try Fixture(count: 2)
    defer { fixture.cleanUp() }
    let missing = fixture.files[0]
    try FileManager.default.removeItem(at: missing)
    let state = OpenRollStore.State(
      paths: fixture.files.map(\.path), selection: missing.path,
      selectedPaths: Set(fixture.files.map(\.path)))
    try fixture.rollStore.save(state)

    let model = fixture.model()
    defer { model.closeAllScans() }
    #expect(model.files == fixture.files)
    #expect(model.selection == missing)
    #expect(model.selectedFiles == Set(fixture.files))
    try await waitUntil { !model.isLoading && model.statusKind == .error }
    #expect(model.previewImage == nil)
    #expect(model.status.contains(missing.lastPathComponent))
    try await model.flushSettings()

    let saved = try #require(try fixture.rollStore.load())
    #expect(saved == state)
    #expect(model.files == fixture.files)
    #expect(model.selection == missing)
    model.closeAllScans()
    try await model.flushSettings()
  }

  @Test("Unreadable roll state remains protected while a new session imports and edits")
  func corruptRollIsNotOverwritten() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.cleanUp() }
    let original = Data("this is not a roll document".utf8)
    try original.write(to: fixture.rollStore.fileURL)

    let model = fixture.model()
    defer { model.closeAllScans() }
    #expect(model.files.isEmpty)
    #expect(!model.openRollStatus.isEmpty)
    model.importFiles(fixture.files)
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    model.setExposureEV(0.5)
    do {
      try await model.flushSettings()
      Issue.record("Flushing an unreadable open-roll document should fail")
    } catch {
      #expect(!model.openRollStatus.isEmpty)
    }

    #expect(try Data(contentsOf: fixture.rollStore.fileURL) == original)
    #expect(model.files == fixture.files)
    #expect(model.parameters.photoAdjustments.exposureEV == 0.5)
    let corrections = try fixture.settingsStore.loadState()
    #expect(corrections.settingsByPath[fixture.files[0].path]?.photoAdjustments.exposureEV == 0.5)
    model.closeAllScans()
    do {
      try await model.flushSettings()
      Issue.record("Closing scans must not replace an unreadable open-roll document")
    } catch {}
    #expect(try Data(contentsOf: fixture.rollStore.fileURL) == original)
    #expect(!model.openRollStatus.isEmpty)
  }

  @Test("A cancelled thumbnail cannot clear the replacement request after closing scans")
  func staleThumbnailCannotClearReplacement() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let oldGate = ThumbnailGate()
    let replacementGate = ThumbnailGate()
    defer {
      oldGate.release()
      replacementGate.release()
      model.closeAllScans()
    }
    let input = fixture.files[0]
    model.thumbnailPreparationHook = oldGate.prepare
    let oldTask = try #require(model.requestThumbnail(for: input))
    try await waitUntil { oldGate.isHeld }

    model.closeAllScans()
    #expect(!model.isThumbnailLoading(for: input))
    model.thumbnailPreparationHook = replacementGate.prepare
    let replacementTask = try #require(model.requestThumbnail(for: input))
    try await waitUntil { replacementGate.isHeld }
    oldGate.release()
    await oldTask.value

    #expect(model.isThumbnailLoading(for: input))
    #expect(model.thumbnail(for: input) == nil)
    // Re-requesting while the replacement is held must keep that same worker.
    model.requestThumbnail(for: input)
    #expect(replacementGate.calls == 1)
    replacementGate.release()
    await replacementTask.value
    #expect(model.thumbnail(for: input) != nil)
    #expect(!model.isThumbnailLoading(for: input))
    model.closeAllScans()
    try await model.flushSettings()
  }

  @Test("Closing scans is refused until an active export finishes")
  func closeWaitsForExport() async throws {
    let fixture = try Fixture(count: 1)
    defer { fixture.cleanUp() }
    let model = fixture.model()
    defer {
      model.cancelExport()
      model.closeAllScans()
    }
    model.importFiles(fixture.files)
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    let output = fixture.directory.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    model.setExportDestinationDirectory(output)
    model.setExportFormat(.png)
    model.exportAll()
    #expect(model.isExporting)

    // Both calls run in the same actor turn, before the exporter can finish.
    model.closeAllScans()
    #expect(model.files == fixture.files)
    #expect(model.selection == fixture.files[0])
    #expect(model.statusKind == .error)
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)

    model.closeAllScans()
    try await model.flushSettings()
    #expect(model.files.isEmpty)
    #expect(try fixture.rollStore.load()?.paths.isEmpty == true)
  }

  private struct Fixture {
    let identifier = "fsc-open-roll-\(UUID().uuidString)"
    let directory: URL
    let files: [URL]
    let preferences: UserDefaults
    let settingsStore: PerFileSettingsStore
    let rollStore: OpenRollStore

    init(count: Int) throws {
      directory =
        FileManager.default.temporaryDirectory
        .appendingPathComponent(identifier, isDirectory: true).standardizedFileURL
      preferences = try #require(UserDefaults(suiteName: identifier))
      settingsStore = PerFileSettingsStore(baseDirectory: directory)
      rollStore = OpenRollStore(baseDirectory: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let source = try #require(
        Bundle.module.url(
          forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
      let destinationDirectory = directory
      files = try (0..<count).map { index in
        let destination = destinationDirectory.appendingPathComponent("scan-\(index).png")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
      }
    }

    @MainActor func model() -> AppModel {
      AppModel(
        profileStore: ProfileStore(baseDirectory: directory), settingsStore: settingsStore,
        openRollStore: rollStore, preferences: preferences, previewMemoryBudget: 1)
    }

    func cleanUp() {
      preferences.removePersistentDomain(forName: identifier)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private enum WaitError: Error { case timedOut }

  private func waitUntil(
    timeout: Duration = .seconds(10), condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        Issue.record("Timed out waiting for open-roll app state")
        throw WaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class ThumbnailGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var held = false
  private var count = 0

  var isHeld: Bool { lock.withLock { held } }
  var calls: Int { lock.withLock { count } }

  func prepare() {
    lock.withLock {
      count += 1
      held = true
    }
    _ = semaphore.wait(timeout: .now() + 10)
    lock.withLock { held = false }
  }

  func release() { semaphore.signal() }
}
