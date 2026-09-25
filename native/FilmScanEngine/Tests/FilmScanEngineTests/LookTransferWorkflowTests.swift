import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Batch look transfer workflow", .serialized)
@MainActor
struct LookTransferWorkflowTests {
  @Test(
    "An unseen destination resolves its base after look transfer and relaunch; saved Original stays Original"
  )
  func unseenDestinationRetainsLookUntilClassification() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-look-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = (0..<3).map { directory.appendingPathComponent("\($0).png") }
    let image = UInt16Image(
      width: 8, height: 8, channels: 3,
      pixels: (0..<64).flatMap {
        $0.isMultiple(of: 2) ? [UInt16(9000), 18000, 41000] : [5000, 13000, 34000]
      })
    for url in urls {
      try image.write(to: url, format: .png, parameters: .init(format: .png))
    }
    let store = PerFileSettingsStore(baseDirectory: directory)
    // Historical Original documents need no new flag to preserve their meaning.
    try store.save(
      .init(settingsByPath: [urls[2].path: ProcessingParameters()], editedPaths: [urls[2].path]))
    let model = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles(urls)
    try await settled(model)
    model.setFilmBase(.colorC41)
    model.applyLookRecipe(.warm)
    model.setDensityCastRemovalStrength(0.21)
    model.setDensityUnmixStrength(0.73)
    let copied = CorrectionSettings(capturing: model.parameters)
    #expect(!model.hasCachedPreview(for: urls[1]))
    model.applyCurrentSettingsToAllOpenFiles()
    try await model.flushSettings()
    let stored = try store.loadState().settingsByPath
    #expect(stored[urls[1].path]?.pendingFilmBaseInitialization == .preservingLook)
    #expect(stored[urls[2].path]?.pendingFilmBaseInitialization == nil)
    let restored = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer {
      restored.selection = nil
      restored.loadSelection()
    }
    restored.importFiles([urls[1]])
    try await settled(restored)
    #expect(restored.parameters.pendingFilmBaseInitialization == nil)
    #expect(FilmBase.resolved(from: restored.parameters) == .colorC41)
    #expect(CorrectionSettings(capturing: restored.parameters) == copied)
    restored.importFiles([urls[2]])
    restored.selection = urls[2]
    restored.loadSelection()
    try await settled(restored)
    #expect(FilmBase.resolved(from: restored.parameters) == .original)

    model.selection = urls[1]
    model.loadSelection()
    try await settled(model)
    model.undo()
    #expect(model.parameters.pendingFilmBaseInitialization == nil)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(!model.hasEdits(for: urls[1]))
    model.redo()
    #expect(CorrectionSettings(capturing: model.parameters) == copied)
  }

  @Test(
    "Batch looks survive later roll hints, including after redo",
    arguments: [false, true]
  )
  func batchLookSurvivesFilmBaseHintChanges(selectedOnly: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("look-transfer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.png")
    let second = directory.appendingPathComponent("second.png")
    // This low-confidence mask takes a user-confirmed roll hint, so changing
    // the first scan's film base would ordinarily reclassify the second scan.
    let pixels = (0..<64).flatMap { index -> [UInt16] in
      index.isMultiple(of: 2) ? [20_000, 23_600, 27_800] : [18_000, 21_200, 25_000]
    }
    let image = UInt16Image(width: 8, height: 8, channels: 3, pixels: pixels)
    for url in [first, second] {
      try image.write(to: url, format: .png, parameters: ExportParameters(format: .png))
    }
    let preferenceDomain = "look-transfer-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: preferenceDomain))
    defer { preferences.removePersistentDomain(forName: preferenceDomain) }
    let model = AppModel(preferences: preferences)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([first, second])
    try await settled(model)
    model.setFilmBase(.colorC41)
    try await waitUntil {
      model.hasCachedPreview(for: second) && !model.previewBackgroundWorkIsActive
    }
    model.selection = second
    model.loadSelection()
    try await settled(model)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    let automatic = CorrectionSettings(capturing: model.parameters)

    model.selection = first
    model.loadSelection()
    try await settled(model)
    model.applyLookRecipe(.punchyPrint)
    model.setExposureEV(0.75)
    let copied = CorrectionSettings(capturing: model.parameters)
    if selectedOnly {
      model.selectedFiles = [first, second]
      model.applyCurrentLookToSelectedFiles()
    } else {
      model.applyCurrentSettingsToAllOpenFiles()
    }

    model.setFilmBase(.blackAndWhite)
    model.selection = second
    model.loadSelection()
    try await settled(model)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(CorrectionSettings(capturing: model.parameters) == copied)
    #expect(model.hasEdits(for: second))
    model.undo()
    #expect(CorrectionSettings(capturing: model.parameters) == automatic)
    #expect(!model.hasEdits(for: second))
    model.redo()
    #expect(CorrectionSettings(capturing: model.parameters) == copied)
    #expect(model.hasEdits(for: second))

    model.selection = first
    model.loadSelection()
    try await settled(model)
    model.setFilmBase(.slide)
    model.selection = second
    model.loadSelection()
    try await settled(model)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(CorrectionSettings(capturing: model.parameters) == copied)

    // Undo also restores the automatic state: subsequent roll hints may again
    // reclassify this frame once the user removes the transferred look.
    model.undo()
    model.selection = first
    model.loadSelection()
    try await settled(model)
    model.setFilmBase(.blackAndWhite)
    model.selection = second
    model.loadSelection()
    try await settled(model)
    #expect(FilmBase.resolved(from: model.parameters) == .blackAndWhite)
    #expect(!model.hasEdits(for: second))
  }

  private func settled(_ model: AppModel) async throws {
    try await waitUntil {
      model.previewImage != nil && !model.isLoading && !model.isRendering
    }
  }

  private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for batch look workflow")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
