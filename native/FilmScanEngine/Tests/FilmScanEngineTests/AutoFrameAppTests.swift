import AppKit
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Auto Frame request ownership", .serialized)
@MainActor
struct AutoFrameAppTests {
  @Test("A current frame result keeps newer point edits and remains undoable and persistent")
  func currentResult() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.setPerspectiveCrop(Self.perspective)
    model.setManualCrop(Self.manualCrop)
    let gate = FrameDetectionGate(rect: Self.frame)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { gate.isHeld }
    model.setExposureEV(0.25)
    let before = model.parameters
    #expect(model.isCropDetectionRunning)
    gate.release()
    await task.value

    #expect(!gate.ranOnMainThread && !gate.timedOut)
    #expect(!model.isCropDetectionRunning)
    #expect(model.cropRect == Self.frame)
    #expect(model.parameters.cropRectCoordinateSpace == .imageAxes)
    #expect(model.manualCrop == nil && model.perspectiveCrop == nil)
    #expect(model.parameters.photoAdjustments.exposureEV == 0.25)
    #expect(model.cropThresholdPreview == gate.threshold)
    #expect(model.undoActionName == "Detect Frame")
    let detected = model.parameters
    model.undo()
    #expect(model.parameters == before)
    #expect(model.manualCrop == Self.manualCrop && model.perspectiveCrop == Self.perspective)
    model.redo()
    #expect(model.parameters == detected)
    try await assertSaved(model, fixture: fixture)
    let restored = try await loadedModel(fixture)
    defer { restored.closeAllScans() }
    #expect(restored.cropRect == Self.frame)
    #expect(restored.manualCrop == nil && restored.perspectiveCrop == nil)
    #expect(restored.parameters.photoAdjustments.exposureEV == 0.25)
    #expect(restored.undoActionName == nil)
  }

  @Test(
    "A frame completing during a slider drag remains a separate undo step",
    arguments: [false, true])
  func completionDuringPointGesture(continueDragging: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.setPerspectiveCrop(Self.perspective)
    model.setManualCrop(Self.manualCrop)
    let initial = model.parameters
    let gate = FrameDetectionGate(rect: Self.frame)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { gate.isHeld }
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.1)
    model.setExposureEV(0.25)
    let beforeFrame = model.parameters
    gate.release()
    await task.value
    let afterFrame = model.parameters
    #expect(afterFrame.cropRect == Self.frame)
    #expect(afterFrame.photoAdjustments.exposureEV == 0.25)
    #expect(model.undoActionName == "Detect Frame")
    if continueDragging {
      model.setExposureEV(0.4)
      model.setExposureEV(0.5)
    }
    model.endEditingGesture()
    let final = model.parameters
    if continueDragging {
      #expect(model.undoActionName == "Exposure")
      model.undo()
      // Both continued pointer samples belong to one rebased drag entry.
      #expect(model.parameters == afterFrame)
    }
    #expect(model.undoActionName == "Detect Frame")
    model.undo()
    #expect(model.parameters == beforeFrame)
    #expect(model.undoActionName == "Exposure")
    model.undo()
    #expect(model.parameters == initial)
    model.redo()
    #expect(model.parameters == beforeFrame)
    model.redo()
    #expect(model.parameters == afterFrame)
    if continueDragging {
      model.redo()
      #expect(model.parameters == final)
    }
    #expect(!gate.timedOut)
    try await assertSaved(model, fixture: fixture)
  }

  @Test("A detector with no frame leaves an active slider drag as one undo entry")
  func noResultKeepsPointGesture() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    let initial = model.parameters
    let gate = FrameDetectionGate(rect: nil)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { gate.isHeld }
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.1)
    model.setExposureEV(0.25)
    gate.release()
    await task.value
    #expect(model.cropStatus == "No crop frame detected.")
    #expect(model.cropRect == nil && model.cropThresholdPreview == nil)
    model.setExposureEV(0.4)
    model.setExposureEV(0.5)
    model.endEditingGesture()
    let final = model.parameters
    #expect(model.undoActionName == "Exposure")
    model.undo()
    #expect(model.parameters == initial)
    model.redo()
    #expect(model.parameters == final)
    #expect(!gate.timedOut)
    try await assertSaved(model, fixture: fixture)
  }

  @Test(
    "Geometry and detector-threshold mutations reject a held frame result",
    arguments: [
      "manual", "perspective", "straighten", "rotate", "flip", "dark", "light", "ratio", "frame",
    ])
  func staleGeometry(mutation: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    let gate = FrameDetectionGate(rect: Self.frame)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { gate.isHeld }
    switch mutation {
    case "manual": model.setManualCrop(Self.manualCrop)
    case "perspective": model.setPerspectiveCrop(Self.perspective)
    case "straighten": model.setStraightenAngle(8)
    case "rotate": model.rotateClockwise()
    case "flip": model.toggleFlip()
    case "dark": model.setDarkThreshold(model.parameters.darkThreshold + 1)
    case "light": model.setLightThreshold(model.parameters.lightThreshold - 1)
    case "ratio": model.setManualCropAspectRatio(.portrait4x5)
    case "frame":
      model.setCropRect(.init(centerX: 0.5, centerY: 0.5, width: 0.8, height: 0.7, angle: 0))
    default: Issue.record("Unknown geometry mutation")
    }
    #expect(!model.isCropDetectionRunning)
    let expected = model.parameters
    let expectedStatus = model.cropStatus
    let expectedThreshold = model.cropThresholdPreview
    let expectedUndo = model.undoActionName
    let expectedRedo = model.redoActionName
    gate.release()
    await task.value

    #expect(!gate.timedOut)
    #expect(model.parameters == expected)
    #expect(model.cropStatus == expectedStatus)
    #expect(model.cropThresholdPreview == expectedThreshold)
    #expect(model.undoActionName == expectedUndo && model.redoActionName == expectedRedo)
    try await assertSaved(model, fixture: fixture)
  }

  @Test("Undo rejects pending detection even when geometry returns to its starting value")
  func editThenUndo() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    let before = model.parameters
    let gate = FrameDetectionGate(rect: Self.frame)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { gate.isHeld }
    model.setManualCrop(Self.manualCrop)
    model.undo()
    #expect(model.parameters == before)
    #expect(model.redoActionName == "Crop")
    let expectedStatus = model.cropStatus
    gate.release()
    await task.value
    #expect(!model.isCropDetectionRunning && !gate.timedOut)
    #expect(model.parameters == before)
    #expect(model.redoActionName == "Crop")
    #expect(model.cropStatus == expectedStatus && model.cropThresholdPreview == nil)
    model.redo()
    #expect(model.manualCrop == Self.manualCrop)
    try await assertSaved(model, fixture: fixture)
  }

  @Test("Undo of a point edit also supersedes pending Auto Frame")
  func historyRestoration() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    model.setExposureEV(0.5)
    let gate = FrameDetectionGate(rect: Self.frame)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { gate.isHeld }
    model.undo()
    let expected = model.parameters
    let expectedStatus = model.cropStatus
    #expect(!model.isCropDetectionRunning)
    gate.release()
    await task.value
    #expect(!gate.timedOut && model.parameters == expected)
    #expect(model.redoActionName == "Exposure")
    #expect(model.cropStatus == expectedStatus && model.cropThresholdPreview == nil)
    try await assertSaved(model, fixture: fixture)
  }

  @Test("An obsolete completion cannot clear the newer request's busy state or publish its result")
  func replacementRequest() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    let first = FrameDetectionGate(rect: Self.frame)
    let secondRect = RotatedRect(centerX: 0.45, centerY: 0.55, width: 0.6, height: 0.5, angle: 2)
    let second = FrameDetectionGate(rect: secondRect)
    defer {
      first.release()
      second.release()
    }
    model.cropDetectionWorker = first.detect
    let firstTask = try #require(model.detectCrop())
    try await waitUntil { first.isHeld }
    model.cropDetectionWorker = second.detect
    let secondTask = try #require(model.detectCrop())
    try await waitUntil { second.isHeld }
    let expected = model.parameters
    first.release()
    await firstTask.value
    #expect(model.isCropDetectionRunning)
    #expect(model.cropStatus == "Finding film frame...")
    #expect(model.parameters == expected && model.cropThresholdPreview == nil)
    second.release()
    await secondTask.value
    #expect(!first.timedOut && !second.timedOut)
    #expect(!model.isCropDetectionRunning)
    #expect(model.cropRect == secondRect && model.cropThresholdPreview == second.threshold)
    #expect(model.undoActionName == "Detect Frame")
    model.undo()
    #expect(model.parameters == expected)
  }

  @Test("A same-file RAW preview upgrade cancels detection without changing saved geometry")
  func sourceUpgrade() async throws {
    let fixture = try Fixture(raw: true)
    defer { fixture.remove() }
    let model = fixture.model()
    let decoder = FrameRawUpgradeGate()
    let detector = FrameDetectionGate(rect: Self.frame)
    defer {
      detector.release()
      decoder.release()
      model.closeAllScans()
    }
    model.rawPreviewSessionDecoder = decoder.decode
    model.importFiles([fixture.input])
    try await waitUntil {
      model.previewSourceKind == .rawDraft && decoder.isHeld && !model.isLoading
    }
    model.setPerspectiveCrop(Self.perspective)
    model.setManualCrop(Self.manualCrop)
    model.cropDetectionWorker = detector.detect
    let task = try #require(model.detectCrop())
    try await waitUntil { detector.isHeld }
    let expected = model.parameters
    let expectedUndo = model.undoActionName
    decoder.release()
    try await waitUntil {
      model.previewSourceKind == .rawFull && !model.previewBackgroundWorkIsActive
    }
    #expect(!model.isCropDetectionRunning)
    #expect(model.cropStatus == "The scan preview changed. Run Auto Frame again.")
    detector.release()
    await task.value
    #expect(!detector.timedOut && !decoder.timedOut)
    #expect(model.parameters == expected)
    #expect(model.perspectiveCrop == Self.perspective && model.manualCrop == Self.manualCrop)
    #expect(model.undoActionName == expectedUndo)
    #expect(model.cropThresholdPreview == nil)
    #expect(model.cropStatus == "The scan preview changed. Run Auto Frame again.")
    try await assertSaved(model, fixture: fixture)
  }

  @Test("Cancellation before task scheduling skips native detection and releases its owner")
  func cancellationBeforeWorker() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = try await loadedModel(fixture)
    defer { model.closeAllScans() }
    let gate = FrameDetectionGate(rect: Self.frame)
    defer { gate.release() }
    model.cropDetectionWorker = gate.detect
    let before = model.parameters
    let task = try #require(model.detectCrop())
    task.cancel()
    await task.value
    #expect(gate.callCount == 0)
    #expect(!model.isCropDetectionRunning)
    #expect(model.parameters == before && model.cropThresholdPreview == nil)
    #expect(model.cropStatus == "Frame detection cancelled.")
  }

  private static let manualCrop = NormalizedCropRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
  private static let perspective = PerspectiveCrop(
    topLeft: .init(x: 0.06, y: 0.08), topRight: .init(x: 0.94, y: 0.06),
    bottomRight: .init(x: 0.9, y: 0.92), bottomLeft: .init(x: 0.08, y: 0.94))
  private static let frame = RotatedRect(
    centerX: 0.5, centerY: 0.5, width: 0.7, height: 0.6, angle: 6)

  private func loadedModel(_ fixture: Fixture) async throws -> AppModel {
    let model = fixture.model()
    model.importFiles([fixture.input])
    try await waitUntil { !model.isLoading && !model.isRendering && model.previewImage != nil }
    return model
  }

  private func assertSaved(_ model: AppModel, fixture: Fixture) async throws {
    try await model.flushSettings()
    var expected = model.parameters
    expected.filmNegativeParams.measuredMedians = nil
    #expect(
      try fixture.store.loadState().settingsByPath[fixture.input.standardizedFileURL.path]
        == expected)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for Auto Frame request")
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private struct Fixture {
    let directory: URL
    let input: URL
    let store: PerFileSettingsStore
    let preferences: UserDefaults
    let suiteName: String

    init(raw: Bool = false) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fsc-auto-frame-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      input = directory.appendingPathComponent(raw ? "scan.RAF" : "scan.png")
      if raw {
        try Data().write(to: input)
      } else {
        try FrameRawUpgradeGate.source(width: 96, height: 72)
          .write(to: input, format: .png, parameters: .init(format: .png))
      }
      store = PerFileSettingsStore(baseDirectory: directory.appendingPathComponent("settings"))
      try store.save(
        .init(
          settingsByPath: [
            input.standardizedFileURL.path: .init(filmType: .cropOnly, photoAdjustments: .init())
          ],
          editedPaths: []))
      suiteName = "fsc-auto-frame-\(UUID().uuidString)"
      preferences = try #require(UserDefaults(suiteName: suiteName))
    }

    @MainActor func model() -> AppModel {
      AppModel(settingsStore: store, preferences: preferences)
    }

    func remove() {
      preferences.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private final class FrameDetectionGate: @unchecked Sendable {
  private let condition = NSCondition()
  private let rect: RotatedRect?
  let threshold = UInt16Image(width: 2, height: 2, channels: 1, pixels: [0, 65535, 65535, 0])
  private var held = false
  private var released = false
  private var calls = 0
  private var mainThread = false
  private var timeout = false
  var isHeld: Bool { condition.withLock { held } }
  var ranOnMainThread: Bool { condition.withLock { mainThread } }
  var timedOut: Bool { condition.withLock { timeout } }
  var callCount: Int { condition.withLock { calls } }

  init(rect: RotatedRect?) { self.rect = rect }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }

  func detect(_ source: UInt16Image, _ dark: Int, _ light: Int, _ maxDimension: Int)
    -> (threshold: UInt16Image, rect: RotatedRect, contourPoints: [SIMD2<Double>])?
  {
    condition.lock()
    calls += 1
    mainThread = mainThread || Thread.isMainThread
    held = true
    let deadline = Date().addingTimeInterval(15)
    while !released {
      if !condition.wait(until: deadline) {
        timeout = true
        break
      }
    }
    held = false
    condition.unlock()
    guard let rect else { return nil }
    return (threshold, rect, [])
  }
}

private final class FrameRawUpgradeGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var held = false
  private var released = false
  private var timeout = false
  var isHeld: Bool { condition.withLock { held } }
  var timedOut: Bool { condition.withLock { timeout } }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }

  func decode(_ url: URL, _ kind: PreviewSourceKind) throws -> CachedPreviewSession {
    if kind == .rawInspect {
      condition.lock()
      held = true
      let deadline = Date().addingTimeInterval(15)
      while !released {
        if !condition.wait(until: deadline) {
          timeout = true
          break
        }
      }
      held = false
      condition.unlock()
    }
    let width = kind == .rawDraft ? 96 : (kind == .rawFull ? 192 : 144)
    let image = Self.source(width: width, height: width * 3 / 4)
    return CachedPreviewSession(
      sourceKind: kind, displaySource: image, analysisSource: image,
      previewRenderer: try #require(StillPreviewRenderer(image: image)),
      sourcePixelDimensions: .init(width: 192, height: 144))
  }

  static func source(width: Int, height: Int) -> UInt16Image {
    UInt16Image(
      width: width, height: height, channels: 3,
      pixels: (0..<(width * height * 3)).map { UInt16(8_000 + ($0 * 73) % 40_000) })
  }
}
