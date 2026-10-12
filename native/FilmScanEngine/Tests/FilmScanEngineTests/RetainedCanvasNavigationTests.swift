import AppKit
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Retained corrected canvas navigation", .serialized)
@MainActor
struct RetainedCanvasNavigationTests {
  @Test(
    "Evicted RAW sessions immediately restore the latest half-size canvas at its full logical size")
  func revisitingEvictedCanvas() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let decoder = CanvasDecodeGate()
    model.rawPreviewSessionDecoder = decoder.decode
    defer {
      decoder.release()
      model.closeAllScans()
    }
    model.importFiles(fixture.urls)
    try await settled(model)
    model.setExposureEV(0.65)
    model.setManualCrop(.init(x: 0.125, y: 0.125, width: 0.75, height: 0.75))
    try await settled(model)
    let parameters = model.parameters
    let complete = try #require(model.previewImage)
    let completeBitmap = try #require(PreviewBitmap.cgImage(from: complete))
    let expected = try #require(
      RetainedCanvasPreview.make(
        cgImage: completeBitmap, parameters: parameters,
        logicalDimensions: .init(
          width: Int(complete.size.width), height: Int(complete.size.height)),
        sourcePixelDimensions: model.sourcePixelDimensions))
    try await evictFirst(model, fixture: fixture)

    decoder.holdFullDecode(for: fixture.urls[0])
    model.selection = fixture.urls[0]
    model.loadSelection()
    #expect(model.isShowingRetainedCanvas)
    #expect(model.previewImage?.size == complete.size)
    #expect(model.publishedPreviewParameters == parameters)
    let revision = model.publishedRenderRevision
    try await waitUntil { decoder.isHeld && model.previewSourceKind == .rawDraft }
    #expect(model.parameters == parameters)
    #expect(model.publishedRenderRevision == revision)
    #expect(model.isShowingRetainedCanvas)
    #expect(model.previewDetail == nil)
    let restoredImage = try #require(model.previewImage)
    let restored = try #require(PreviewBitmap.cgImage(from: restoredImage))
    #expect(restored.width == completeBitmap.width / 2)
    #expect(restored.height == completeBitmap.height / 2)
    #expect(try pixels(restored) == pixels(expected.cgImage))

    // Zoom and pan operate on the retained logical canvas without correction.
    let corrections = model.previewCorrectionCount
    model.setPreviewRenderDemand(
      .init(
        documentSize: complete.size,
        visibleRect: CGRect(x: 4, y: 3, width: 20, height: 16),
        backingScale: 2, magnification: 2))
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.previewImage?.size == complete.size)

    decoder.release()
    try await settled(model)
    #expect(!model.isShowingRetainedCanvas)
    #expect(model.previewSourceKind == .rawFull)
    #expect(model.previewImage?.size == complete.size)
    #expect(model.publishedPreviewParameters == parameters)
    let refinedImage = try #require(model.previewImage)
    let refined = try #require(PreviewBitmap.cgImage(from: refinedImage))
    #expect(try pixels(refined) == pixels(completeBitmap))
  }

  @Test(
    "Original and new edits replace retained pixels with the current decoding tier",
    arguments: [false, true])
  func changedDisplayContextReleasesSnapshot(original: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let decoder = CanvasDecodeGate()
    model.rawPreviewSessionDecoder = decoder.decode
    defer {
      decoder.release()
      model.closeAllScans()
    }
    model.importFiles(fixture.urls)
    try await settled(model)
    try await evictFirst(model, fixture: fixture)
    decoder.holdFullDecode(for: fixture.urls[0])
    model.selection = fixture.urls[0]
    model.loadSelection()
    #expect(model.isShowingRetainedCanvas)
    try await waitUntil { decoder.isHeld && model.previewSourceKind == .rawDraft }
    let revision = model.publishedRenderRevision
    if original {
      model.showOriginal = true
    } else {
      model.setExposureEV(1.1)
    }
    try await waitUntil { !model.isRendering && model.publishedRenderRevision > revision }
    #expect(!model.isShowingRetainedCanvas)
    #expect(model.previewSourceKind == .rawDraft)
    #expect(model.previewImage?.size == NSSize(width: 12, height: 8))
    #expect(model.showOriginal == original)
    if !original {
      #expect(model.publishedPreviewParameters?.photoAdjustments.exposureEV == 1.1)
    }
    decoder.release()
    try await settled(model)
  }

  @Test("An unfinished latest edit cannot restore an older corrected snapshot")
  func pendingEditRejectsOldSnapshot() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let decoder = CanvasDecodeGate()
    let renderGate = CanvasPublicationGate()
    model.rawPreviewSessionDecoder = decoder.decode
    defer {
      renderGate.release()
      decoder.release()
      model.closeAllScans()
    }
    model.importFiles(fixture.urls)
    try await settled(model)
    try await evictFirst(model, fixture: fixture)
    model.selection = fixture.urls[0]
    model.loadSelection()
    try await settled(model)

    model.previewRenderCompletionHook = { _ in await renderGate.holdOnce() }
    model.setExposureEV(1.25)
    try await waitUntil { renderGate.isHeld }
    model.selection = fixture.urls[1]
    model.loadSelection()
    renderGate.release()
    model.previewRenderCompletionHook = nil
    try await settled(model)
    model.selection = fixture.urls[2]
    model.loadSelection()
    try await settled(model)
    #expect(!model.hasCachedPreview(for: fixture.urls[0]))

    decoder.holdFullDecode(for: fixture.urls[0])
    model.selection = fixture.urls[0]
    model.loadSelection()
    #expect(!model.isShowingRetainedCanvas)
    #expect(model.parameters.photoAdjustments.exposureEV == 1.25)
    try await waitUntil { decoder.isHeld && !model.isRendering }
    #expect(!model.isShowingRetainedCanvas)
    #expect(model.publishedPreviewParameters?.photoAdjustments.exposureEV == 1.25)
    decoder.release()
    try await settled(model)
  }

  @Test("Original comparison is not retained as the corrected departure canvas")
  func originalDepartureIsNotCaptured() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let decoder = CanvasDecodeGate()
    model.rawPreviewSessionDecoder = decoder.decode
    defer {
      decoder.release()
      model.closeAllScans()
    }
    model.importFiles(fixture.urls)
    try await settled(model)
    model.showOriginal = true
    try await settled(model)
    try await evictFirst(model, fixture: fixture)
    decoder.holdFullDecode(for: fixture.urls[0])
    model.selection = fixture.urls[0]
    model.loadSelection()
    #expect(!model.isShowingRetainedCanvas)
    #expect(!model.showOriginal)
    decoder.release()
    try await settled(model)
  }

  @Test(
    "Flat-field changes, memory pressure, and closing scans clear retained canvases",
    arguments: ["flatField", "pressure", "close"])
  func invalidationClearsSnapshots(reason: String) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let decoder = CanvasDecodeGate()
    model.rawPreviewSessionDecoder = decoder.decode
    defer { model.closeAllScans() }
    model.importFiles(fixture.urls)
    try await settled(model)
    try await evictFirst(model, fixture: fixture)
    #expect(model.retainedCanvasPreviewCount > 0)

    switch reason {
    case "flatField": model.clearFlatField()
    case "pressure": model.handlePreviewMemoryPressure(isUnderPressure: true)
    default: model.closeAllScans()
    }
    try await waitUntil { !model.canvasSnapshotWorkIsActive && !model.isRendering }
    #expect(model.retainedCanvasPreviewCount == 0)
    #expect(!model.isShowingRetainedCanvas)
    if reason == "close" {
      #expect(model.previewImage == nil)
      #expect(model.previewCacheSessionCount == 0)
    }
  }

  @Test(
    "Memory pressure retains and accounts for the visible canvas while cancelling its RAW upgrade")
  func pressurePreservesDisplayedSnapshot() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let decoder = CanvasDecodeGate()
    model.rawPreviewSessionDecoder = decoder.decode
    defer {
      decoder.release()
      model.closeAllScans()
    }
    model.importFiles(fixture.urls)
    try await settled(model)
    try await evictFirst(model, fixture: fixture)
    decoder.holdFullDecode(for: fixture.urls[0])
    model.selection = fixture.urls[0]
    model.loadSelection()
    try await waitUntil { decoder.isHeld && model.previewSourceKind == .rawDraft }
    let canvas = try #require(model.previewImage)
    let bitmap = try #require(PreviewBitmap.cgImage(from: canvas))
    let canvasPixels = try pixels(bitmap)
    let canvasBytes = bitmap.bytesPerRow * bitmap.height
    let draft = try #require(model.decodedImage)
    let draftBytes = draft.pixels.count * MemoryLayout<UInt16>.stride
    let revision = model.publishedRenderRevision
    let corrections = model.previewCorrectionCount
    let decodedFulls = model.fullResolutionPreviewDecodeCount
    let completedFulls = decoder.completedFullDecodeCount
    #expect(model.retainedCanvasPreviewCount > 0)

    model.handlePreviewMemoryPressure(isUnderPressure: true)
    #expect(model.retainedCanvasPreviewCount == 0)
    #expect(model.previewCacheSessionCount == 1)
    #expect(model.isShowingRetainedCanvas)
    #expect(model.previewImage === canvas)
    #expect(model.previewCachePhysicalBytes >= draftBytes + canvasBytes)
    #expect(!model.previewBackgroundWorkIsActive)
    model.setPreviewRenderDemand(
      .init(
        documentSize: canvas.size,
        visibleRect: CGRect(x: 8, y: 6, width: 24, height: 16),
        backingScale: 2, magnification: 3))
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.publishedRenderRevision == revision)
    #expect(model.previewImage?.size == canvas.size)

    decoder.release()
    try await waitUntil { decoder.completedFullDecodeCount > completedFulls }
    // The synchronous decoder has drained. Give its cancelled scheduler
    // continuation a turn on the main actor before checking publication.
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.fullResolutionPreviewDecodeCount == decodedFulls)
    #expect(model.previewSourceKind == .rawDraft)
    #expect(model.retainedCanvasPreviewCount == 0)
    #expect(model.isShowingRetainedCanvas)
    #expect(model.publishedRenderRevision == revision)
    #expect(model.previewCachePhysicalBytes >= draftBytes + canvasBytes)
    let afterPressureImage = try #require(model.previewImage)
    let afterPressure = try #require(PreviewBitmap.cgImage(from: afterPressureImage))
    #expect(try pixels(afterPressure) == canvasPixels)

    model.handlePreviewMemoryPressure(isUnderPressure: false)
    try await settled(model)
    #expect(!model.isShowingRetainedCanvas)
    #expect(model.retainedCanvasPreviewCount == 0)
    #expect(model.previewImage?.size == canvas.size)
  }

  private func evictFirst(_ model: AppModel, fixture: Fixture) async throws {
    for url in fixture.urls.dropFirst() {
      model.selection = url
      model.loadSelection()
      try await settled(model)
    }
    #expect(!model.hasCachedPreview(for: fixture.urls[0]))
  }

  private func settled(_ model: AppModel) async throws {
    try await waitUntil {
      model.previewSourceKind == .rawFull && model.previewImage != nil
        && !model.isLoading && !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive
    }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func pixels(_ image: CGImage) throws -> Data {
    try #require(image.dataProvider?.data as Data?)
  }

  private struct Fixture {
    let directory: URL
    let urls: [URL]
    let preferences: UserDefaults
    let suiteName: String
    let store: PerFileSettingsStore

    init() throws {
      let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("retained-canvas-navigation-\(UUID().uuidString)")
      directory = fixtureDirectory
      try FileManager.default.createDirectory(
        at: fixtureDirectory, withIntermediateDirectories: true)
      let inputURLs = (0..<3).map { fixtureDirectory.appendingPathComponent("\($0).RAF") }
      urls = inputURLs
      for url in inputURLs { try Data().write(to: url) }
      suiteName = "fsc-retained-canvas-\(UUID().uuidString)"
      preferences = try #require(UserDefaults(suiteName: suiteName))
      store = PerFileSettingsStore(baseDirectory: directory.appendingPathComponent("settings"))
      let parameters = ProcessingParameters(filmType: .slide, photoAdjustments: .init())
      try store.save(
        .init(
          settingsByPath: Dictionary(uniqueKeysWithValues: urls.map { ($0.path, parameters) }),
          editedPaths: []))
    }

    @MainActor func model() -> AppModel {
      let model = AppModel(settingsStore: store, preferences: preferences)
      model.setPreviewCacheLimit(2)
      return model
    }

    func cleanUp() {
      preferences.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private final class CanvasDecodeGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var heldPath: String?
  private var waiting = false
  private var completedFulls = 0

  var isHeld: Bool {
    condition.lock()
    defer { condition.unlock() }
    return waiting
  }

  var completedFullDecodeCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return completedFulls
  }

  func holdFullDecode(for url: URL) {
    condition.lock()
    heldPath = url.standardizedFileURL.path
    waiting = false
    condition.unlock()
  }

  func release() {
    condition.lock()
    heldPath = nil
    condition.broadcast()
    condition.unlock()
  }

  func decode(_ url: URL, _ kind: PreviewSourceKind) throws -> CachedPreviewSession {
    condition.lock()
    while kind == .rawFull && heldPath == url.standardizedFileURL.path {
      waiting = true
      condition.wait()
    }
    condition.unlock()
    let width: Int
    switch kind {
    case .rawDraft: width = 12
    case .rawFull: width = 96
    default: width = 48
    }
    let height = width * 2 / 3
    let fileIndex = Int(url.deletingPathExtension().lastPathComponent) ?? 0
    let count = width * height * 3
    let base = 8_000 + fileIndex * 5_000
    var pixels = [UInt16]()
    pixels.reserveCapacity(count)
    for index in 0..<count {
      pixels.append(UInt16(base + (index * 173) % 28_000))
    }
    let source = UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
    guard let renderer = StillPreviewRenderer(image: source) else {
      throw CocoaError(.coderInvalidValue)
    }
    if kind == .rawFull {
      condition.lock()
      completedFulls += 1
      condition.unlock()
    }
    return CachedPreviewSession(
      sourceKind: kind, displaySource: source, analysisSource: source,
      previewRenderer: renderer, sourcePixelDimensions: .init(width: 96, height: 64))
  }
}

@MainActor
private final class CanvasPublicationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var hasArrived = false
  var isHeld: Bool { continuation != nil }

  func holdOnce() async {
    guard !hasArrived else { return }
    hasArrived = true
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
