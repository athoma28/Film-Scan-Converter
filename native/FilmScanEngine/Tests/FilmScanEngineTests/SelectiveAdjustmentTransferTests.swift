import AppKit
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Selective adjustment transfer", .serialized)
@MainActor
struct SelectiveAdjustmentTransferTests {
  @Test("Exposure transfers alone, preserving every other destination parameter")
  func exposureIsIsolated() throws {
    let source = sourceParameters()
    let destination = destinationParameters()
    var expected = destination
    expected.photoAdjustments.exposureEV = source.photoAdjustments.exposureEV
    #expect(
      try CorrectionSettings(capturing: source).applying(to: destination, groups: [.exposure])
        == expected)
  }

  @Test("Tone excludes exposure, color, curves, grading, and the destination tone version")
  func toneIsIsolated() throws {
    let source = sourceParameters()
    var destination = destinationParameters()
    destination.photoAdjustments.schemaVersion = 2
    let result = try CorrectionSettings(capturing: source).applying(
      to: destination, groups: [.tone])
    #expect(result.photoAdjustments.schemaVersion == 2)
    #expect(result.photoAdjustments.exposureEV == destination.photoAdjustments.exposureEV)
    #expect(result.photoAdjustments.highlights == source.photoAdjustments.highlights)
    #expect(result.photoAdjustments.shadows == source.photoAdjustments.shadows)
    #expect(result.photoAdjustments.whites == source.photoAdjustments.whites)
    #expect(result.photoAdjustments.blacks == source.photoAdjustments.blacks)
    #expect(result.photoAdjustments.brightness == source.photoAdjustments.brightness)
    #expect(result.photoAdjustments.contrast == source.photoAdjustments.contrast)
    #expect(
      result.photoAdjustments.temperatureShiftMired
        == destination.photoAdjustments.temperatureShiftMired)
    #expect(result.photoAdjustments.saturation == destination.photoAdjustments.saturation)
    #expect(result.photoAdjustments.shadowFloor == destination.photoAdjustments.shadowFloor)
    #expect(result.photoAdjustments.midtoneLevel == destination.photoAdjustments.midtoneLevel)
    #expect(
      result.photoAdjustments.highlightCeiling == destination.photoAdjustments.highlightCeiling)
    #expect(result.shadowWheel == destination.shadowWheel)
    #expect(result.curveControlPoints == destination.curveControlPoints)
    #expect(result.filmNegativeParams == destination.filmNegativeParams)
    #expect(result.manualCrop == destination.manualCrop)
    #expect(result.dustRepairs == destination.dustRepairs)
  }

  @Test("Color transfers public color controls and keeps inversion and calibration")
  func colorKeepsFrameState() throws {
    let source = sourceParameters()
    let destination = destinationParameters()
    let result = try CorrectionSettings(capturing: source).applying(
      to: destination, groups: [.colorBalance])
    #expect(
      result.photoAdjustments.temperatureShiftMired == source.photoAdjustments.temperatureShiftMired
    )
    #expect(result.photoAdjustments.tint == source.photoAdjustments.tint)
    #expect(result.photoAdjustments.saturation == source.photoAdjustments.saturation)
    #expect(result.photoAdjustments.vibrance == source.photoAdjustments.vibrance)
    #expect(result.photoAdjustments.warmHueRecovery == source.photoAdjustments.warmHueRecovery)
    #expect(result.temperature == Int(source.photoAdjustments.temperatureShiftMired.rounded()))
    #expect(result.filmNegativeParams.densityCastRemovalStrength == 0.23)
    #expect(result.filmNegativeParams.densityUnmixStrength == 0.71)
    #expect(result.filmNegativeParams.densityNeutralProtection)
    #expect(
      result.filmNegativeParams.densityProfileID == destination.filmNegativeParams.densityProfileID)
    #expect(
      result.filmNegativeParams.measuredMedians == destination.filmNegativeParams.measuredMedians)
    #expect(result.photoAdjustments.exposureEV == destination.photoAdjustments.exposureEV)
    #expect(result.photoAdjustments.contrast == destination.photoAdjustments.contrast)
    #expect(result.photoAdjustments.shadowFloor == destination.photoAdjustments.shadowFloor)
    #expect(result.redCurveControlPoints == destination.redCurveControlPoints)
    #expect(result.densityBaseDensity == destination.densityBaseDensity)
    #expect(result.filmDyeMixing == destination.filmDyeMixing)
    #expect(result.rotation == destination.rotation)
    #expect(result.manualCrop == destination.manualCrop)
  }

  @Test("Curves and grading can transfer independently without changing photographic intent")
  func curvesAndGradingAreSeparate() throws {
    let source = sourceParameters()
    let destination = destinationParameters()
    let settings = CorrectionSettings(capturing: source)
    let curves = try settings.applying(to: destination, groups: [.curves])
    #expect(curves.curveEnabled == source.curveEnabled)
    #expect(curves.curveControlPoints == source.curveControlPoints)
    #expect(curves.redCurveEnabled == source.redCurveEnabled)
    #expect(curves.redCurveControlPoints == source.redCurveControlPoints)
    #expect(curves.greenCurveControlPoints == source.greenCurveControlPoints)
    #expect(curves.blueCurveControlPoints == source.blueCurveControlPoints)
    #expect(curves.photoAdjustments == destination.photoAdjustments)
    #expect(curves.shadowWheel == destination.shadowWheel)
    let grading = try settings.applying(to: destination, groups: [.grading])
    #expect(grading.highlightWheel == source.highlightWheel)
    #expect(grading.midtoneWheel == source.midtoneWheel)
    #expect(grading.shadowWheel == source.shadowWheel)
    #expect(grading.photoAdjustments.shadowFloor == source.photoAdjustments.shadowFloor)
    #expect(grading.photoAdjustments.midtoneLevel == source.photoAdjustments.midtoneLevel)
    #expect(grading.photoAdjustments.highlightCeiling == source.photoAdjustments.highlightCeiling)
    #expect(grading.photoAdjustments.exposureEV == destination.photoAdjustments.exposureEV)
    #expect(grading.photoAdjustments.highlights == destination.photoAdjustments.highlights)
    #expect(grading.photoAdjustments.tint == destination.photoAdjustments.tint)
    #expect(grading.curveControlPoints == destination.curveControlPoints)
    #expect(grading.filmNegativeParams == destination.filmNegativeParams)
  }

  @Test("All keeps full recipe behavior and the schema-two clipboard document")
  func fullTransferAndSerializationRemainCompatible() throws {
    let settings = CorrectionSettings(capturing: sourceParameters())
    let destination = destinationParameters()
    #expect(
      try settings.applying(to: destination, groups: CorrectionAdjustmentGroup.all)
        == settings.applying(to: destination))
    #expect(try settings.applying(to: destination, groups: []) == destination)
    let data = try JSONEncoder().encode(settings)
    let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(document["schemaVersion"] as? Int == 2)
    #expect(Set(document.keys) == ["schemaVersion", "recipe"])
    #expect(try JSONDecoder().decode(CorrectionSettings.self, from: data) == settings)
    #expect(!CorrectionAdjustmentGroup.defaultForSync.contains(.exposure))
    #expect(CorrectionAdjustmentGroup.defaultForSync.count == 4)
  }

  @Test("Partial transfers preserve each photographic tone version", arguments: [2, 3, 4])
  func photographicVersionsStayLocal(version: Int) throws {
    var destination = destinationParameters()
    destination.photoAdjustments.schemaVersion = version
    let settings = CorrectionSettings(capturing: sourceParameters())
    let result = try settings.applying(to: destination, groups: [.tone, .grading])
    #expect(result.photoAdjustments.schemaVersion == version)
    #expect(result.photoAdjustments.highlights == settings.recipe.photoAdjustments.highlights)
    #expect(result.photoAdjustments.shadowFloor == settings.recipe.photoAdjustments.shadowFloor)
    #expect(result.photoAdjustments.exposureEV == destination.photoAdjustments.exposureEV)
  }

  @Test("Matching legacy Tone and Grading do not block a different selected adjustment")
  func unchangedLegacyGroupsPermitExposureTransfer() throws {
    var destination = try decodedLegacyParameters()
    destination.photoAdjustments.schemaVersion = 1
    var source = destination
    source.photoAdjustments.schemaVersion = 4
    source.photoAdjustments.exposureEV = 1.25
    var expected = destination
    expected.photoAdjustments.exposureEV = 1.25

    let result = try CorrectionSettings(capturing: source).applying(
      to: destination, groups: [.exposure, .tone, .grading])
    #expect(result == expected)
    #expect(result.gamma == destination.gamma)
    #expect(result.highlights == destination.highlights)
    #expect(result.shadows == destination.shadows)
  }

  @Test("Color transfers onto positive scans preserve their unused inversion settings")
  func colorTransferPreservesPositiveFrameState() throws {
    var destination = destinationParameters()
    destination.filmType = .slide
    let source = sourceParameters()
    let result = try CorrectionSettings(capturing: source).applying(
      to: destination, groups: [.colorBalance])

    #expect(
      result.photoAdjustments.temperatureShiftMired == source.photoAdjustments.temperatureShiftMired
    )
    #expect(result.photoAdjustments.saturation == source.photoAdjustments.saturation)
    #expect(result.filmNegativeParams == destination.filmNegativeParams)
    #expect(result.filmType == .slide)
    #expect(result.dustRepairs == destination.dustRepairs)
    #expect(result.manualCrop == destination.manualCrop)
  }

  @Test("Legacy Tone and Grading mismatch rejects before changing any batch member")
  func legacyBatchRejectionIsAtomic() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var legacy = destinationParameters()
    legacy.photoAdjustments.schemaVersion = 1
    let (urls, store) = try makeRoll(
      directory: directory, parameters: [sourceParameters(), destinationParameters(), legacy])
    let model = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    try await model.flushSettings()
    let before = try store.loadState()
    model.adjustmentTransferGroups = [.tone]
    model.syncSelectedAdjustmentsToAllOpenFiles()
    try await model.flushSettings()
    #expect(try store.loadState() == before)
    #expect(model.settingsStatus.contains("Update legacy tone controls"))
    #expect(!model.hasEdits(for: urls[1]))
    #expect(!model.canUndo)
    let settings = CorrectionSettings(capturing: legacy)
    #expect(throws: CorrectionSettings.TransferError.self) {
      try settings.applying(to: sourceParameters(), groups: [.grading])
    }
    #expect(
      try settings.applying(to: sourceParameters(), groups: [.exposure]).photoAdjustments
        .schemaVersion == 4)
    #expect(settings.applying(to: sourceParameters()).photoAdjustments.schemaVersion == 1)
  }

  @Test("Selected sync preserves frame exposure, unselected scans, history, and relaunch state")
  func selectedSyncPersistsAndUndoes() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let anchor = sourceParameters()
    let destination = destinationParameters()
    let (urls, store) = try makeRoll(
      directory: directory, parameters: [anchor, destination, destination])
    let model = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    model.selectedFiles = [urls[0], urls[1]]
    model.syncSelectedAdjustmentsToSelectedFiles()
    try await model.flushSettings()
    let stored = try store.loadState()
    let transferred = try #require(stored.settingsByPath[urls[1].path])
    #expect(transferred.photoAdjustments.exposureEV == destination.photoAdjustments.exposureEV)
    #expect(
      transferred.photoAdjustments.temperatureShiftMired
        == anchor.photoAdjustments.temperatureShiftMired)
    #expect(transferred.photoAdjustments.contrast == anchor.photoAdjustments.contrast)
    #expect(transferred.manualCrop == destination.manualCrop)
    #expect(transferred.densityBaseDensity == destination.densityBaseDensity)
    #expect(transferred.dustRepairs == destination.dustRepairs)
    #expect(stored.settingsByPath[urls[2].path] == destination)
    #expect(!model.hasEdits(for: urls[0]))
    #expect(model.hasEdits(for: urls[1]))
    #expect(!model.hasEdits(for: urls[2]))
    model.selection = urls[1]
    model.loadSelection()
    try await settled(model)
    #expect(model.undoActionName == "Sync Selected Adjustments")
    model.undo()
    #expect(model.parameters.photoAdjustments == destination.photoAdjustments)
    #expect(!model.hasEdits(for: urls[1]))
    model.redo()
    #expect(model.parameters.photoAdjustments == transferred.photoAdjustments)
    try await model.flushSettings()
    let restored = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer { close(restored) }
    restored.importFiles([urls[1]])
    try await settled(restored)
    #expect(restored.parameters.photoAdjustments == transferred.photoAdjustments)
    #expect(restored.parameters.manualCrop == destination.manualCrop)
  }

  @Test("Clipboard group paste updates the current canvas and selected targets only")
  func clipboardUsesSameSelectiveTransfer() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = destinationParameters()
    let (urls, store) = try makeRoll(directory: directory, parameters: [initial, initial, initial])
    let clipboard = CorrectionSettingsClipboard(pasteboard: SelectiveTransferPasteboard())
    try clipboard.write(CorrectionSettings(capturing: sourceParameters()))
    let model = AppModel(settingsStore: store, settingsClipboard: clipboard, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    model.selectedFiles = [urls[0], urls[1]]
    model.adjustmentTransferGroups = [.exposure]
    model.pasteSelectedCorrectionSettingsToSelectedFiles()
    #expect(model.parameters.photoAdjustments.exposureEV == 1.25)
    #expect(model.parameters.photoAdjustments.contrast == initial.photoAdjustments.contrast)
    #expect(model.undoActionName == "Paste Selected Adjustments")
    try await model.flushSettings()
    let stored = try store.loadState().settingsByPath
    #expect(stored[urls[1].path]?.photoAdjustments.exposureEV == 1.25)
    #expect(stored[urls[2].path] == initial)
    model.undo()
    #expect(model.parameters.photoAdjustments.exposureEV == initial.photoAdjustments.exposureEV)
    model.redo()
    #expect(model.parameters.photoAdjustments.exposureEV == 1.25)
  }

  @Test(
    "An unseen scan resolves its own film base without overwriting selectively transferred exposure"
  )
  func unseenDestinationPreservesSelectiveIntent() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = sourceParameters()
    let (urls, store) = try makeRoll(
      directory: directory, parameters: [source, ProcessingParameters(photoAdjustments: .init())])
    try store.save(.init(settingsByPath: [urls[0].path: source], editedPaths: []))
    let model = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    model.adjustmentTransferGroups = [.exposure]
    model.syncSelectedAdjustmentsToAllOpenFiles()
    try await model.flushSettings()
    let pending = try #require(store.loadState().settingsByPath[urls[1].path])
    #expect(pending.pendingFilmBaseInitialization == .preservingLook)
    #expect(pending.photoAdjustments.exposureEV == source.photoAdjustments.exposureEV)
    #expect(pending.photoAdjustments.contrast == 0)
    #expect(pending.dustRepairs.isEmpty)
    model.selection = urls[1]
    model.loadSelection()
    try await settled(model)
    #expect(model.parameters.pendingFilmBaseInitialization == nil)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(model.parameters.photoAdjustments.exposureEV == source.photoAdjustments.exposureEV)
    #expect(model.parameters.photoAdjustments.contrast == 0)
    #expect(model.parameters.photoAdjustments.temperatureShiftMired == 0)
    #expect(model.parameters.dustRepairs.isEmpty)
  }

  @Test("Single-frame group paste during the first load preserves automatic base initialization")
  func firstLoadSinglePasteRetainsGroups() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = sourceParameters()
    let (urls, store) = try makeRoll(
      directory: directory, parameters: [ProcessingParameters(photoAdjustments: .init())])
    try store.save(.init(settingsByPath: [:], editedPaths: []))
    let clipboard = CorrectionSettingsClipboard(pasteboard: SelectiveTransferPasteboard())
    try clipboard.write(CorrectionSettings(capturing: source))
    let model = AppModel(settingsStore: store, settingsClipboard: clipboard, previewMemoryBudget: 1)
    defer { close(model) }
    // Import schedules its decode on another task. Paste before yielding the main
    // actor, matching the menu action while the initial preview is still loading.
    model.importFiles(urls)
    #expect(model.isLoading)
    #expect(model.previewImage == nil)
    model.adjustmentTransferGroups = [.exposure, .colorBalance]
    model.pasteSelectedCorrectionSettings()
    #expect(model.parameters.pendingFilmBaseInitialization == .preservingLook)
    #expect(model.parameters.photoAdjustments.exposureEV == source.photoAdjustments.exposureEV)
    try await settled(model)
    #expect(model.parameters.pendingFilmBaseInitialization == nil)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(model.parameters.photoAdjustments.exposureEV == source.photoAdjustments.exposureEV)
    #expect(
      model.parameters.photoAdjustments.temperatureShiftMired
        == source.photoAdjustments.temperatureShiftMired)
    #expect(model.parameters.filmNegativeParams.densityCastRemovalStrength == 0.23)
    #expect(model.parameters.filmNegativeParams.densityUnmixStrength == 0.71)
    #expect(model.parameters.photoAdjustments.contrast == 0)
    #expect(model.parameters.dustRepairs.isEmpty)
    let pasted = model.parameters
    #expect(model.undoActionName == "Paste Selected Adjustments")
    model.undo()
    #expect(model.parameters.pendingFilmBaseInitialization == nil)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(model.parameters.photoAdjustments.exposureEV == 0)
    #expect(model.parameters.photoAdjustments.temperatureShiftMired == 0)
    #expect(!model.hasEdits(for: urls[0]))
    model.redo()
    #expect(model.parameters.pendingFilmBaseInitialization == nil)
    #expect(FilmBase.resolved(from: model.parameters) == .colorC41)
    #expect(model.parameters.photoAdjustments == pasted.photoAdjustments)
    #expect(model.parameters.filmNegativeParams.densityCastRemovalStrength == 0.23)
    #expect(model.parameters.filmNegativeParams.densityUnmixStrength == 0.71)
    #expect(model.parameters.dustRepairs.isEmpty)
    #expect(model.hasEdits(for: urls[0]))
    try await model.flushSettings()
    let stored = try #require(store.loadState().settingsByPath[urls[0].path])
    #expect(stored.pendingFilmBaseInitialization == nil)
    #expect(stored.photoAdjustments == model.parameters.photoAdjustments)
  }

  @Test("Matching exposure does not create a pending look or an edit for an unseen scan")
  func unseenNoOpDoesNotSuppressClassification() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var source = sourceParameters()
    source.photoAdjustments.exposureEV = 0
    let (urls, store) = try makeRoll(
      directory: directory, parameters: [source, ProcessingParameters(photoAdjustments: .init())])
    try store.save(.init(settingsByPath: [urls[0].path: source], editedPaths: []))
    let model = AppModel(settingsStore: store, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    model.adjustmentTransferGroups = [.exposure]
    model.syncSelectedAdjustmentsToAllOpenFiles()
    try await model.flushSettings()
    #expect(try store.loadState().settingsByPath[urls[1].path] == nil)
    #expect(!model.hasEdits(for: urls[1]))
  }

  @Test("Empty or matching groups do not mark scans edited or create history")
  func noOpTransfersStayNoOp() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = sourceParameters()
    let (urls, store) = try makeRoll(directory: directory, parameters: [initial, initial])
    let clipboard = CorrectionSettingsClipboard(pasteboard: SelectiveTransferPasteboard())
    try clipboard.write(CorrectionSettings(capturing: destinationParameters()))
    let model = AppModel(settingsStore: store, settingsClipboard: clipboard, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    let submissions = model.renderStats.submittedSnapshots
    model.adjustmentTransferGroups = [.exposure]
    model.syncSelectedAdjustmentsToAllOpenFiles()
    model.adjustmentTransferGroups = []
    model.syncSelectedAdjustmentsToAllOpenFiles()
    model.pasteSelectedCorrectionSettings()
    model.pasteSelectedCorrectionSettingsToAllOpenFiles()
    #expect(!model.hasEdits(for: urls[0]))
    #expect(!model.hasEdits(for: urls[1]))
    #expect(!model.canUndo)
    #expect(model.parameters.photoAdjustments == initial.photoAdjustments)
    #expect(model.renderStats.submittedSnapshots == submissions)
    try await model.flushSettings()
    #expect(try store.loadState().editedPaths.isEmpty)
  }

  @Test(
    "Selecting All groups stays a no-op while full batch apply keeps its existing edited intent")
  func allGroupsNoOpDiffersFromFullBatchIntent() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = sourceParameters()
    let (urls, store) = try makeRoll(directory: directory, parameters: [initial, initial])
    let clipboard = CorrectionSettingsClipboard(pasteboard: SelectiveTransferPasteboard())
    let model = AppModel(settingsStore: store, settingsClipboard: clipboard, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    model.copyCorrectionSettings()
    model.selectedFiles = Set(urls)
    model.adjustmentTransferGroups = CorrectionAdjustmentGroup.all
    let before = model.parameters
    let submissions = model.renderStats.submittedSnapshots
    model.pasteSelectedCorrectionSettings()
    model.pasteSelectedCorrectionSettingsToAllOpenFiles()
    model.syncSelectedAdjustmentsToSelectedFiles()
    #expect(model.parameters == before)
    #expect(model.renderStats.submittedSnapshots == submissions)
    #expect(!model.hasEdits(for: urls[0]))
    #expect(!model.hasEdits(for: urls[1]))
    #expect(!model.canUndo)

    model.applyCurrentLookToSelectedFiles()
    #expect(model.parameters == before)
    #expect(model.hasEdits(for: urls[0]))
    #expect(model.hasEdits(for: urls[1]))
    #expect(model.undoActionName == "Apply Look to Selected")
    model.undo()
    #expect(!model.hasEdits(for: urls[0]))
    #expect(model.hasEdits(for: urls[1]))
    #expect(model.parameters == before)
    model.redo()
    #expect(model.hasEdits(for: urls[0]))
    #expect(model.parameters == before)
    try await model.flushSettings()
    #expect(try store.loadState().editedPaths == Set(urls.map(\.path)))
  }

  @Test(
    "Matching group transfers, including All, preserve decoded legacy integers and exact rendering")
  func decodedLegacyGroupsAreNoOps() throws {
    let legacy = try decodedLegacyParameters()
    #expect(legacy.photoAdjustments.schemaVersion == 1)
    #expect(legacy.photoAdjustments.temperatureShiftMired != Double(legacy.temperature))
    let settings = CorrectionSettings(capturing: legacy)
    let image = UInt16Image(
      width: 4, height: 1, channels: 3,
      pixels: [8000, 16000, 24000, 18000, 32000, 40000, 42000, 48000, 54000, 52000, 57000, 61000])
    let expected = FilmProcessing.correctedPreview(image: image, parameters: legacy)
    let selections: [Set<CorrectionAdjustmentGroup>] = [
      [.tone], [.colorBalance], [.exposure], [.grading], [.curves],
      CorrectionAdjustmentGroup.defaultForSync, CorrectionAdjustmentGroup.all,
    ]
    for groups in selections {
      let applied = try settings.applying(to: legacy, groups: groups)
      #expect(applied == legacy)
      #expect(FilmProcessing.correctedPreview(image: image, parameters: applied) == expected)
    }
    // The original full paste API retains its historical normalization contract.
    let full = settings.applying(to: legacy)
    #expect(full.gamma == 0)
    #expect(full.temperature == Int(legacy.photoAdjustments.temperatureShiftMired.rounded()))
    #expect(full != legacy)
    #expect(FilmProcessing.correctedPreview(image: image, parameters: full) != expected)
  }

  @Test("Matching color preserves density defaults and nil foliage recovery")
  func matchingColorPreservesRepresentations() throws {
    var destination = FilmBase.colorC41.applyingInvert(
      to: ProcessingParameters(photoAdjustments: .init()))
    destination.filmNegativeParams.densityCastRemovalStrength = nil
    destination.filmNegativeParams.densityUnmixStrength = -1
    destination.filmNegativeParams.densityNeutralProtection = false
    var source = destination
    source.photoAdjustments.warmHueRecovery = 0
    let result = try CorrectionSettings(capturing: source).applying(
      to: destination, groups: [.colorBalance])
    #expect(result == destination)
    #expect(result.photoAdjustments.warmHueRecovery == nil)
  }

  @Test(
    "Legacy All self-transfer stays a no-op while original full apply keeps normalization and history"
  )
  func decodedLegacyAppNoOp() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = try decodedLegacyParameters()
    let (urls, store) = try makeRoll(directory: directory, parameters: [legacy, legacy])
    let clipboard = CorrectionSettingsClipboard(pasteboard: SelectiveTransferPasteboard())
    let model = AppModel(settingsStore: store, settingsClipboard: clipboard, previewMemoryBudget: 1)
    defer { close(model) }
    model.importFiles(urls)
    try await settled(model)
    let before = model.parameters
    let submissions = model.renderStats.submittedSnapshots
    model.copyCorrectionSettings()
    model.pasteSelectedCorrectionSettings()
    model.syncSelectedAdjustmentsToAllOpenFiles()
    model.adjustmentTransferGroups = CorrectionAdjustmentGroup.all
    model.pasteSelectedCorrectionSettings()
    model.syncSelectedAdjustmentsToAllOpenFiles()
    #expect(model.parameters == before)
    #expect(model.parameters.temperature == 30)
    #expect(!model.hasEdits(for: urls[0]))
    #expect(!model.hasEdits(for: urls[1]))
    #expect(!model.canUndo)
    #expect(model.renderStats.submittedSnapshots == submissions)
    try await model.flushSettings()
    #expect(try store.loadState().settingsByPath[urls[1].path] == legacy)
    model.selectedFiles = Set(urls)
    model.applyCurrentLookToSelectedFiles()
    #expect(model.parameters.gamma == 0)
    #expect(
      model.parameters.temperature == Int(legacy.photoAdjustments.temperatureShiftMired.rounded()))
    #expect(model.hasEdits(for: urls[0]))
    #expect(model.hasEdits(for: urls[1]))
    #expect(model.undoActionName == "Apply Look to Selected")
    model.undo()
    #expect(model.parameters == before)
    #expect(!model.hasEdits(for: urls[0]))
  }

  private func decodedLegacyParameters() throws -> ProcessingParameters {
    try JSONDecoder().decode(
      ProcessingParameters.self,
      from: Data(
        #"{"filmType":2,"gamma":38,"shadows":-25,"highlights":42,"temperature":30,"tint":-20,"saturation":125}"#
          .utf8))
  }

  private func sourceParameters() -> ProcessingParameters {
    var source = FilmBase.colorC41.applyingInvert(
      to: ProcessingParameters(photoAdjustments: .init()))
    source.photoAdjustments = PhotoAdjustmentParameters(
      exposureEV: 1.25, brightness: 0.2, contrast: 0.3, highlights: -0.4, shadows: 0.5,
      temperatureShiftMired: 23, tint: -0.2, saturation: 0.15, vibrance: 0.25, warmHueRecovery: 0.4,
      whites: -0.1, blacks: 0.2, shadowFloor: 0.15, midtoneLevel: -0.12, highlightCeiling: -0.2)
    source.curveEnabled = true
    source.curveControlPoints = [
      .init(input: 0, output: 0), .init(input: 0.5, output: 0.6), .init(input: 1, output: 1),
    ]
    source.redCurveEnabled = true
    source.redCurveControlPoints = [
      .init(input: 0, output: 0), .init(input: 0.5, output: 0.55), .init(input: 1, output: 1),
    ]
    source.greenCurveControlPoints = source.curveControlPoints
    source.blueCurveControlPoints = source.redCurveControlPoints
    source.shadowWheel = .init(hue: 0.6, strength: 0.2)
    source.midtoneWheel = .init(hue: 0.1, strength: 0.15)
    source.highlightWheel = .init(hue: 0.2, strength: 0.3)
    source.filmNegativeParams.densityCastRemovalStrength = 0.23
    source.filmNegativeParams.densityUnmixStrength = 0.71
    source.filmNegativeParams.densityNeutralProtection = true
    source.dustRepairs = [.init(points: [.init(0.3, 0.4)], radius: 0.01)]
    source.syncLegacyColorFieldsFromPhotoAdjustments()
    return source
  }

  private func destinationParameters() -> ProcessingParameters {
    var destination = FilmBase.colorCyanMask.applyingInvert(
      to: ProcessingParameters(photoAdjustments: .init()))
    destination.photoAdjustments.exposureEV = -0.75
    destination.photoAdjustments.contrast = -0.2
    destination.photoAdjustments.temperatureShiftMired = -10
    destination.photoAdjustments.shadowFloor = 0.3
    destination.rotation = 1
    destination.manualCrop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
    destination.densityBaseDensity = .init(blue: 0.1, green: 0.2, red: 0.3)
    destination.dustRepairs = [.init(points: [.init(0.6, 0.5)], radius: 0.02)]
    destination.syncLegacyColorFieldsFromPhotoAdjustments()
    return destination
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "selective-adjustments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeRoll(directory: URL, parameters: [ProcessingParameters]) throws
    -> ([URL], PerFileSettingsStore)
  {
    let urls = parameters.indices.map { directory.appendingPathComponent("scan-\($0).png") }
    let image = UInt16Image(
      width: 8, height: 8, channels: 3,
      pixels: (0..<64).flatMap {
        $0.isMultiple(of: 2) ? [UInt16(9000), 18000, 41000] : [5000, 13000, 34000]
      })
    for url in urls { try image.write(to: url, format: .png, parameters: .init(format: .png)) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(
        settingsByPath: Dictionary(uniqueKeysWithValues: zip(urls.map(\.path), parameters)),
        editedPaths: []))
    return (urls, store)
  }

  private func close(_ model: AppModel) {
    model.selection = nil
    model.loadSelection()
  }

  private func settled(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.previewImage == nil || model.isLoading || model.isRendering {
      try #require(ContinuousClock.now < deadline, "Selective transfer preview did not settle")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class SelectiveTransferPasteboard: CorrectionSettingsPasteboard {
  private var data: Data?
  private var text: String?

  func clearContents() -> Int {
    data = nil
    text = nil
    return 0
  }

  func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
    self.data = data
    return true
  }

  func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
    text = string
    return true
  }

  func data(forType dataType: NSPasteboard.PasteboardType) -> Data? { data }
  func string(forType dataType: NSPasteboard.PasteboardType) -> String? { text }
}
