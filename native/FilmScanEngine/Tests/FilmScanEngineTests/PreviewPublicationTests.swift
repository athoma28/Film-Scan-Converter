import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Preview publication during editing", .serialized)
@MainActor
struct PreviewPublicationTests {
  private enum WaitError: Error { case timedOut }

  @Test(
    "Replay exposure edits with a real 640-entry store and an active preview",
    .enabled(if: ProcessInfo.processInfo.environment["RUN_EDIT_REPLAY_BENCHMARK"] == "1"))
  func benchmarkEditingWithPersistence() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-edit-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let store = PerFileSettingsStore(baseDirectory: directory)
    var saved = Dictionary(
      uniqueKeysWithValues: (0..<639).map { index in
        (directory.appendingPathComponent("synthetic-\(index).tif").path, ProcessingParameters())
      })
    saved[input.standardizedFileURL.path] = ProcessingParameters(filmType: .colourNegative)
    try store.save(.init(settingsByPath: saved, editedPaths: []))
    let model = AppModel(settingsStore: store)
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering && !model.isLoading }
    let displayedBefore = model.renderStats.displayedRenders
    model.beginEditingGesture(named: "Exposure")
    var setterMilliseconds: [Double] = []
    for index in 0..<60 {
      let started = ContinuousClock.now
      model.setExposureEV(Double(index) / 100)
      let duration = started.duration(to: .now)
      setterMilliseconds.append(
        Double(duration.components.seconds) * 1_000
          + Double(duration.components.attoseconds) / 1e15)
      try await Task.sleep(for: .milliseconds(8))
    }
    let framesBeforeRelease = model.renderStats.displayedRenders - displayedBefore
    model.endEditingGesture()
    try await waitUntil { !model.isRendering }
    try await model.flushSettings()
    #expect(framesBeforeRelease > 0)
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(
      try store.loadState().settingsByPath[input.standardizedFileURL.path]?
        .photoAdjustments.exposureEV == 0.59)
    let report: [String: Any] = [
      "case": "640-history-small-decoded-preview-exposure-replay",
      "inputEvents": 60,
      "framesPublishedBeforeRelease": framesBeforeRelease,
      "framesPublishedTotal": model.renderStats.displayedRenders - displayedBefore,
      "setterMilliseconds": setterMilliseconds,
      "longestPublicationGapMilliseconds": model.renderStats.longestPublicationGapMs,
      "finalInteractionLatencyMilliseconds": model.renderStats.lastInteractionLatencyMs,
      "rendererStatus": model.status,
      "note":
        "Programmatic setter replay at 8 ms intervals; publication is not screen presentation.",
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("EDIT_REPLAY \(String(decoding: data, as: UTF8.self))")
  }

  @Test(
    "Cropped exposure edits use the renderer supported by their film base",
    arguments: [FilmBase.slide, .colorC41])
  func manuallyCroppedExposureUsesSupportedRenderer(base: FilmBase) async throws {
    let model = try await loadedModel()
    model.setFilmBase(base)
    model.setManualCrop(.init(x: 0.17, y: 0.13, width: 0.63, height: 0.71))
    model.setExposureEV(0.4)
    try await waitUntil { !model.isRendering }
    // Version 2 shares sensor-frame analysis, so both bases support a cropped GPU edit.
    #expect(model.status.contains("GPU"))
    #expect(model.publishedPreviewParameters == model.parameters)
    model.showOriginal = true
    try await waitUntil { !model.isRendering }
    #expect(model.status.contains("CPU"))
  }

  @Test("Completed point edits keep publishing while newer edits are waiting")
  func sustainedEditsPublishIntermediateAndFinalRevisions() async throws {
    let model = try await loadedModel()
    let gate = CompletionGate()
    model.previewRenderCompletionHook = { await gate.hold($0) }
    defer { gate.releaseAll() }
    let displayedBefore = model.renderStats.displayedRenders
    var previousRevision = model.publishedRenderRevision

    model.setSemanticTemperature(10)
    try await waitUntil { gate.arrivals.count == 1 }
    for index in 0..<4 {
      let nextTemperature = (index + 2) * 10
      model.setSemanticTemperature(Double(nextTemperature))
      gate.release(index)
      try await waitUntil { gate.arrivals.count == index + 2 }
      #expect(model.renderStats.displayedRenders == displayedBefore + index + 1)
      #expect(model.publishedRenderRevision > previousRevision)
      #expect(model.publishedPreviewParameters?.temperature == (index + 1) * 10)
      previousRevision = model.publishedRenderRevision
    }

    gate.release(4)
    try await waitUntil { !model.isRendering }
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(model.publishedPreviewParameters?.temperature == 50)
    #expect(model.renderStats.displayedRenders == displayedBefore + 5)
    #expect(model.renderStats.lastInteractionLatencyMs >= model.renderStats.lastLatencyMs)
    #expect(model.renderStats.lastQueueWaitMs >= 0)
    #expect(model.renderStats.longestPublicationGapMs > 0)
  }

  @Test(
    "Geometry, comparison, and source reloads reject a completed old frame",
    arguments: ["geometry", "geometryReturn", "comparison", "source"])
  func changedContextRejectsCompletedFrame(change: String) async throws {
    let model = try await loadedModel()
    let gate = CompletionGate()
    model.previewRenderCompletionHook = { await gate.hold($0) }
    defer { gate.releaseAll() }
    let displayedBefore = model.renderStats.displayedRenders
    let revisionBefore = model.publishedRenderRevision

    model.setSemanticTemperature(30)
    try await waitUntil { gate.arrivals.count == 1 }
    switch change {
    case "geometry": model.rotateClockwise()
    case "geometryReturn":
      model.rotateClockwise()
      model.rotateCounterclockwise()
    case "comparison": model.showOriginal = true
    default: model.loadSelection()
    }
    gate.release(0)
    try await waitUntil { gate.arrivals.count == 2 && gate.exited.contains(0) }
    #expect(model.renderStats.displayedRenders == displayedBefore)
    #expect(model.publishedRenderRevision == revisionBefore)

    gate.release(1)
    try await waitUntil { !model.isRendering }
    #expect(model.renderStats.displayedRenders == displayedBefore + 1)
    #expect(model.publishedPreviewParameters == model.parameters)
  }

  @Test("Deselecting a document prevents its completed frame from reappearing")
  func deselectionRejectsCompletedFrame() async throws {
    let model = try await loadedModel()
    let gate = CompletionGate()
    model.previewRenderCompletionHook = { await gate.hold($0) }
    defer { gate.releaseAll() }
    model.setSemanticTemperature(45)
    try await waitUntil { gate.arrivals.count == 1 }
    let displayedBefore = model.renderStats.displayedRenders
    model.selection = nil
    model.loadSelection()
    gate.release(0)
    try await waitUntil { gate.exited.contains(0) }
    #expect(model.previewImage == nil)
    #expect(model.renderStats.displayedRenders == displayedBefore)
    #expect(!model.isRendering)
  }

  @Test("Rapid selection reloads keep one detached render worker and drain the latest request")
  func selectionChangesDoNotOverlapWorkers() async throws {
    let model = try await loadedModel()
    let gate = CompletionGate()
    model.previewRenderWorkerHook = { await gate.hold(ProcessingParameters()) }
    defer {
      model.previewRenderWorkerHook = nil
      gate.releaseAll()
    }
    let published = model.renderStats.displayedRenders
    model.setExposureEV(0.25)
    try await waitUntil { gate.arrivals.count == 1 }
    for index in 1...8 {
      model.loadSelection()
      model.setExposureEV(Double(index) / 10)
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(gate.arrivals.count == 1)
    #expect(model.renderStats.displayedRenders == published)
    gate.release(0)
    try await waitUntil { gate.arrivals.count == 2 }
    #expect(model.renderStats.displayedRenders == published)
    gate.release(1)
    try await waitUntil { !model.isRendering }
    #expect(gate.arrivals.count == 2)
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(model.parameters.photoAdjustments.exposureEV == 0.8)
  }

  @Test(
    "Gesture release refreshes delayed diagnostics without repeating a complete correction",
    arguments: [false, true])
  func gestureReleaseDoesNotRepeatCorrection(holdFinalRender: Bool) async throws {
    let model = try await loadedModel()
    try await waitUntil { model.previewStatisticsRevision == model.publishedRenderRevision }
    // Let the next sample pass the gesture's 100 ms diagnostic throttle.
    try await Task.sleep(for: .milliseconds(110))
    let statisticsGate = CompletionGate()
    let renderGate = CompletionGate()
    model.previewStatisticsCompletionHook = { await statisticsGate.hold(.init()) }
    defer {
      model.previewStatisticsCompletionHook = nil
      model.previewRenderCompletionHook = nil
      statisticsGate.releaseAll()
      renderGate.releaseAll()
    }

    model.beginEditingGesture(named: "Temperature")
    model.setSemanticTemperature(10)
    try await waitUntil { statisticsGate.arrivals.count == 1 && !model.isRendering }
    #expect(model.previewStatisticsRevision != model.publishedRenderRevision)
    if holdFinalRender {
      model.previewRenderCompletionHook = { await renderGate.hold($0) }
    }
    model.setSemanticTemperature(20)
    try await waitUntil {
      holdFinalRender ? renderGate.arrivals.count == 1 : !model.isRendering
    }
    let submissions = model.renderStats.submittedSnapshots
    let corrections = model.previewCorrectionCount
    model.endEditingGesture()
    #expect(model.renderStats.submittedSnapshots == submissions)

    model.previewRenderCompletionHook = nil
    model.previewStatisticsCompletionHook = nil
    renderGate.releaseAll()
    statisticsGate.releaseAll()
    try await waitUntil {
      !model.isRendering && model.previewStatisticsRevision == model.publishedRenderRevision
    }
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(model.publishedPreviewParameters?.temperature == 20)
  }

  private func loadedModel() async throws -> AppModel {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering && !model.isLoading }
    model.setFilmType(.colourNegative)
    try await waitUntil { !model.isRendering }
    return model
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

@MainActor
private final class CompletionGate {
  var arrivals: [ProcessingParameters] = []
  var exited: Set<Int> = []
  private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

  func hold(_ parameters: ProcessingParameters) async {
    let index = arrivals.count
    arrivals.append(parameters)
    await withCheckedContinuation { continuations[index] = $0 }
    exited.insert(index)
  }

  func release(_ index: Int) {
    continuations.removeValue(forKey: index)?.resume()
  }

  func releaseAll() {
    let pending = continuations.values
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}
