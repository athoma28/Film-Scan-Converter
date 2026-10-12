import AppKit
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Correction clipboard caching and failures")
@MainActor
struct CorrectionClipboardTests {
  @Test("Repeated inspector checks read each clipboard revision only once")
  func inspectorChecksReuseClipboard() throws {
    let pasteboard = CountingPasteboard()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    let model = AppModel(settingsClipboard: clipboard)
    let settings = CorrectionSettings(recipe: .warm)
    pasteboard.replace(text: String(decoding: try JSONEncoder().encode(settings), as: UTF8.self))
    for _ in 0..<100 { #expect(model.canPasteCorrectionSettings) }
    #expect(pasteboard.dataReads == 1)
    #expect(pasteboard.textReads == 1)
    model.pasteCorrectionSettings()
    #expect(model.parameters.photoAdjustments == settings.recipe.photoAdjustments)
    #expect(pasteboard.dataReads == 1)

    pasteboard.replace(text: "Unrelated text")
    for _ in 0..<100 { #expect(!model.canPasteCorrectionSettings) }
    #expect(pasteboard.dataReads == 2)
    #expect(pasteboard.textReads == 2)
    pasteboard.replace(text: nil)
    #expect(!model.canPasteCorrectionSettings)
    #expect(pasteboard.dataReads == 3)
  }

  @Test("Full paste closes a held adjustment gesture and records its own persistent undo step")
  func fullPasteKeepsGestureHistorySeparate() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-paste-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    let pasteboard = CountingPasteboard()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    let model = try await loadedModel(clipboard: clipboard, store: store)
    defer { model.closeAllScans() }
    model.rotateClockwise()
    model.setManualCrop(.init(x: 0.1, y: 0.15, width: 0.8, height: 0.7))
    let before = model.parameters
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    model.setExposureEV(0.5)
    let adjusted = model.parameters
    let settings = CorrectionSettings(recipe: .warm)
    pasteboard.replace(data: try JSONEncoder().encode(settings))
    let expected = settings.applying(to: adjusted)
    try #require(expected != adjusted)

    model.pasteCorrectionSettings()
    #expect(model.parameters == expected)
    #expect(model.undoActionName == "Paste Corrections")
    #expect(model.parameters.rotation == before.rotation)
    #expect(model.parameters.manualCrop == before.manualCrop)
    // The slider's eventual release must not wrap the paste in another entry.
    model.endEditingGesture()
    model.undo()
    #expect(model.parameters == adjusted)
    #expect(model.undoActionName == "Exposure")
    model.undo()
    #expect(model.parameters == before)
    #expect(model.redoActionName == "Exposure")
    model.redo()
    #expect(model.parameters == adjusted)
    #expect(model.redoActionName == "Paste Corrections")
    model.redo()
    #expect(model.parameters == expected)
    try await model.flushSettings()
    let key = try #require(model.selection?.standardizedFileURL.path)
    var persisted = expected
    persisted.filmNegativeParams.measuredMedians = nil
    #expect(try store.loadState().settingsByPath[key] == persisted)
  }

  @Test(
    "Empty and invalid clipboard commands preserve the held adjustment gesture",
    arguments: [false, true])
  func rejectedPastePreservesGesture(invalid: Bool) async throws {
    let pasteboard = CountingPasteboard()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    let model = try await loadedModel(clipboard: clipboard)
    defer { model.closeAllScans() }
    if invalid { pasteboard.replace(data: Data("invalid".utf8)) }
    let before = model.parameters
    let previousUndo = model.undoActionName
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    let firstSample = model.parameters
    model.pasteCorrectionSettings()
    #expect(model.parameters == firstSample)
    #expect(
      model.settingsStatus
        == (invalid
          ? "Clipboard correction settings are not valid."
          : "The clipboard does not contain correction settings."))
    model.setExposureEV(0.5)
    model.endEditingGesture()
    let adjusted = model.parameters
    #expect(model.undoActionName == "Exposure")
    model.undo()
    #expect(model.parameters == before)
    #expect(model.undoActionName == previousUndo)
    model.redo()
    #expect(model.parameters == adjusted)
  }

  @Test("Malformed native payload errors are cached and invalidate when replaced")
  func failedReadsInvalidate() throws {
    let pasteboard = CountingPasteboard()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    pasteboard.replace(data: Data("invalid".utf8))
    for _ in 0..<100 {
      #expect(throws: (any Error).self) { try clipboard.read() }
    }
    #expect(pasteboard.dataReads == 1)
    let settings = CorrectionSettings(recipe: .cool)
    pasteboard.replace(data: try JSONEncoder().encode(settings))
    #expect(try clipboard.read() == settings)
    #expect(pasteboard.dataReads == 2)
  }

  @Test("Providers without revisions stay fresh and writes clear a cached result")
  func providersWithoutRevisionsAndWrites() throws {
    let pasteboard = CountingPasteboard()
    pasteboard.revision = nil
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    #expect(try clipboard.read() == nil)
    try clipboard.write(CorrectionSettings(recipe: .warm))
    #expect(try clipboard.read()?.recipe == .warm)
    pasteboard.replace(text: "plain text")
    #expect(try clipboard.read() == nil)

    pasteboard.revision = 10
    #expect(try clipboard.read() == nil)
    try clipboard.write(CorrectionSettings(recipe: .cool))
    #expect(try clipboard.read()?.recipe == .cool)
  }

  @Test("A revision change during a read cannot cache stale clipboard content")
  func revisionChangesDuringRead() throws {
    let pasteboard = CountingPasteboard()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    let warm = try JSONEncoder().encode(CorrectionSettings(recipe: .warm))
    let cool = try JSONEncoder().encode(CorrectionSettings(recipe: .cool))
    pasteboard.replace(data: warm)
    pasteboard.afterDataRead = { pasteboard.replace(data: cool) }
    #expect(try clipboard.read()?.recipe == .warm)
    #expect(try clipboard.read()?.recipe == .cool)
    #expect(pasteboard.dataReads == 2)
  }

  @Test("Copy reports failure if neither representation can be written")
  func failedWritesAreReported() throws {
    let pasteboard = CountingPasteboard()
    pasteboard.acceptsData = false
    pasteboard.acceptsText = false
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    let model = AppModel(settingsClipboard: clipboard)
    model.copyCorrectionSettings()
    #expect(model.settingsStatus == "Correction settings could not be copied.")
    #expect(!model.canPasteCorrectionSettings)
    #expect(throws: CorrectionSettingsClipboard.ClipboardError.writeFailed) {
      try clipboard.write(CorrectionSettings(recipe: .warm))
    }
    pasteboard.acceptsText = true
    try clipboard.write(CorrectionSettings(recipe: .warm))
    #expect(try clipboard.read()?.recipe == .warm)
    pasteboard.acceptsText = false
    pasteboard.acceptsData = true
    try clipboard.write(CorrectionSettings(recipe: .cool))
    #expect(try clipboard.read()?.recipe == .cool)
  }

  private func loadedModel(
    clipboard: CorrectionSettingsClipboard, store: PerFileSettingsStore? = nil
  ) async throws -> AppModel {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let model = AppModel(settingsStore: store, settingsClipboard: clipboard)
    model.importFiles([input])
    let deadline = ContinuousClock.now + .seconds(15)
    while model.isLoading || model.isRendering || model.previewImage == nil {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for clipboard workflow")
      try await Task.sleep(for: .milliseconds(2))
    }
    return model
  }
}

private final class CountingPasteboard: CorrectionSettingsPasteboard {
  var revision: Int? = 0
  var correctionSettingsChangeCount: Int? { revision }
  var acceptsData = true
  var acceptsText = true
  var dataReads = 0
  var textReads = 0
  var afterDataRead: (() -> Void)?
  private var payload: Data?
  private var text: String?

  func replace(data: Data? = nil, text: String? = nil) {
    payload = data
    self.text = text
    if let revision { self.revision = revision + 1 }
  }

  func clearContents() -> Int {
    replace()
    return revision ?? 0
  }

  func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
    guard acceptsData else { return false }
    replace(data: data, text: text)
    return true
  }

  func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
    guard acceptsText else { return false }
    replace(data: payload, text: string)
    return true
  }

  func data(forType type: NSPasteboard.PasteboardType) -> Data? {
    dataReads += 1
    let result = payload
    let callback = afterDataRead
    afterDataRead = nil
    callback?()
    return result
  }

  func string(forType type: NSPasteboard.PasteboardType) -> String? {
    textReads += 1
    return text
  }
}
