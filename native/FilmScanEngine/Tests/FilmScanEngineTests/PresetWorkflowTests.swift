import AppKit
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Preset workflow regressions", .serialized)
@MainActor
struct PresetWorkflowTests {
  @Test("Version one presets migrate public adjustments and keep destination framing and base")
  func legacyPresetsMigrate() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = NamedCorrectionPresetStore(baseDirectory: directory)
    var source = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
    source = LookRecipe.punchyPrint.applying(to: source)
    source.photoAdjustments.exposureEV = 0.75
    source.rotation = 3
    let id = UUID()
    let legacy = LegacyDocument(presets: [
      LegacyPreset(id: id, name: "Evening", settings: LegacySettings(parameters: source))
    ])
    let data = try JSONEncoder().encode(legacy)
    try data.write(to: store.fileURL)

    let loaded = try #require(store.load().first)
    #expect(loaded.id == id)
    #expect(loaded.name == "Evening")
    #expect(loaded.settings.schemaVersion == 2)
    var destination = FilmBase.slide.applyingInvert(to: ProcessingParameters())
    destination.rotation = 1
    destination.manualCrop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let applied = loaded.settings.applying(to: destination)
    #expect(applied.photoAdjustments == source.photoAdjustments)
    #expect(applied.curveControlPoints == source.curveControlPoints)
    #expect(applied.filmNegativeParams == destination.filmNegativeParams)
    #expect(applied.filmType == .slide)
    #expect(applied.rotation == 1)
    #expect(applied.manualCrop == destination.manualCrop)
    // Reading must not rewrite a user's file; a subsequent save upgrades it.
    #expect(try Data(contentsOf: store.fileURL) == data)
    try store.savePreset(named: "Another", settings: loaded.settings)
    let saved = try JSONDecoder().decode(
      NamedCorrectionPresetStore.Document.self, from: Data(contentsOf: store.fileURL))
    #expect(saved.schemaVersion == 2)
    #expect(saved.presets.count == 2)
    #expect(saved.presets.first { $0.id == id }?.settings == loaded.settings)
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("CorrectionPresets-v1-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == data)
    try store.savePreset(named: "Third", settings: loaded.settings)
    #expect(
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("CorrectionPresets-v1-") }.count == 1)

    let clipboardData = try JSONEncoder().encode(LegacySettings(parameters: source))
    let decoded = try JSONDecoder().decode(CorrectionSettings.self, from: clipboardData)
    #expect(decoded == loaded.settings)
  }

  @Test("Deleting from a legacy library preserves the complete original document")
  func legacyDeletionKeepsRecoveryCopy() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = NamedCorrectionPresetStore(baseDirectory: directory)
    let id = UUID()
    let data = try JSONEncoder().encode(
      LegacyDocument(presets: [
        LegacyPreset(
          id: id, name: "Old", settings: LegacySettings(parameters: ProcessingParameters()))
      ]))
    try data.write(to: store.fileURL)
    #expect(try store.deletePreset(id: id).isEmpty)
    let backup = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix("CorrectionPresets-v1-") })
    #expect(try Data(contentsOf: backup) == data)
    #expect(try store.load().isEmpty)
  }

  @Test("Unknown preset documents cannot be overwritten by save or delete")
  func unknownDocumentIsPreserved() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = NamedCorrectionPresetStore(baseDirectory: directory)
    let data = Data(#"{"schemaVersion":99,"presets":[]}"#.utf8)
    try data.write(to: store.fileURL)
    #expect(throws: NamedCorrectionPresetStore.StoreError.unsupportedSchemaVersion(99)) {
      try store.load()
    }
    #expect(throws: NamedCorrectionPresetStore.StoreError.unsupportedSchemaVersion(99)) {
      try store.savePreset(
        named: "New", settings: CorrectionSettings(capturing: ProcessingParameters()))
    }
    #expect(throws: NamedCorrectionPresetStore.StoreError.unsupportedSchemaVersion(99)) {
      try store.deletePreset(id: UUID())
    }
    #expect(try Data(contentsOf: store.fileURL) == data)
  }

  @Test("Saving reports failure and duplicate names use the store's replacement rule")
  func saveFailureAndReplacement() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NamedCorrectionPresetStore(baseDirectory: directory)
    let model = AppModel(presetStore: store)
    #expect(!AppModel().saveCorrectionPreset(named: "Missing store"))
    #expect(!model.saveCorrectionPreset(named: " \n "))
    #expect(model.saveCorrectionPreset(named: "Café"))
    let id = try #require(model.namedCorrectionPresets.first?.id)
    #expect(NamedCorrectionPresetStore.namesMatch("Café", "  CAFE  "))
    model.setExposureEV(0.5)
    #expect(model.saveCorrectionPreset(named: "  CAFE  "))
    #expect(model.namedCorrectionPresets.count == 1)
    #expect(model.namedCorrectionPresets.first?.id == id)
    #expect(model.namedCorrectionPresets.first?.settings.recipe.photoAdjustments.exposureEV == 0.5)
    // A corrupt store is a recoverable save failure, not a successful empty replacement.
    try Data("invalid JSON".utf8).write(to: store.fileURL)
    #expect(!model.saveCorrectionPreset(named: "Keep this name"))
    #expect(model.namedCorrectionPresets.count == 1)
  }

  @Test("Develop reset preserves film base, calibration and geometry and supports undo")
  func resetDevelopPreservesGeometry() async throws {
    let model = try await loadedModel()
    model.setFilmBase(.colorCyanMask)
    model.rotateClockwise()
    model.setPerspectiveCrop(
      .init(
        topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1),
        bottomRight: .init(x: 0.9, y: 0.9), bottomLeft: .init(x: 0.1, y: 0.9)))
    model.setStraightenAngle(2.5)
    model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    model.setFilmDyeMixing(\.redFromGreen, to: 0.12)
    model.applyLookRecipe(.punchyPrint)
    let before = model.parameters
    model.resetDevelopAdjustments()
    #expect(model.parameters.photoAdjustments == PhotoAdjustmentParameters())
    #expect(!model.parameters.curveEnabled)
    #expect(model.parameters.filmType == before.filmType)
    #expect(model.parameters.filmBaseChosenByUser)
    #expect(model.parameters.filmNegativeParams == before.filmNegativeParams)
    #expect(model.parameters.filmDyeMixing == before.filmDyeMixing)
    #expect(model.parameters.rotation == before.rotation)
    #expect(model.perspectiveCrop == before.perspectiveCrop)
    #expect(model.manualCrop == before.manualCrop)
    #expect(model.straightenAngle == before.straightenAngle)
    let reset = model.parameters
    model.undo()
    #expect(model.parameters == before)
    model.redo()
    #expect(model.parameters == reset)
    try await settled(model)
  }

  @Test("Preset clicks submit one render and repeated values submit none")
  func presetRenderSubmissions() async throws {
    let model = try await loadedModel()
    model.setFilmBase(.slide)
    try await settled(model)
    let size = try #require(model.previewImage?.size)
    model.setPreviewRenderDemand(
      .init(
        documentSize: size, visibleRect: CGRect(origin: .zero, size: size),
        backingScale: 2, magnification: 1))
    let before = model.parameters
    let initialSubmissions = model.renderStats.submittedSnapshots
    model.applyLookRecipe(.warm)
    #expect(model.renderStats.submittedSnapshots == initialSubmissions + 1)
    let preset = NamedCorrectionPreset(
      name: "Saved Cool", settings: CorrectionSettings(recipe: .cool))
    model.applyCorrectionPreset(preset)
    #expect(model.renderStats.submittedSnapshots == initialSubmissions + 2)
    let undoName = model.undoActionName
    model.applyCorrectionPreset(preset)
    model.setExposureEV(model.parameters.photoAdjustments.exposureEV)
    #expect(model.renderStats.submittedSnapshots == initialSubmissions + 2)
    #expect(model.undoActionName == undoName)
    model.undo()
    #expect(LookRecipe.warm.matches(model.parameters))
    model.undo()
    #expect(model.parameters == before)
    try await settled(model)
    model.showOriginal = true
    try await settled(model)
    let comparisonSubmissions = model.renderStats.submittedSnapshots
    model.setExposureEV(model.parameters.photoAdjustments.exposureEV)
    #expect(!model.showOriginal)
    #expect(model.renderStats.submittedSnapshots == comparisonSubmissions + 1)
    try await settled(model)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "preset-flow-\(UUID().uuidString)")
  }

  private func loadedModel() async throws -> AppModel {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    model.importFiles([input])
    try await settled(model)
    return model
  }

  private func settled(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.previewImage == nil || model.isLoading || model.isRendering {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private struct LegacySettings: Encodable {
  let schemaVersion = 1
  let parameters: ProcessingParameters
}

private struct LegacyPreset: Encodable {
  let id: UUID
  let name: String
  let settings: LegacySettings
}

private struct LegacyDocument: Encodable {
  let schemaVersion = 1
  let presets: [LegacyPreset]
}
