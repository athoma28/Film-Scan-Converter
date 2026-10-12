import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Auxiliary image worker publication", .serialized)
@MainActor
struct AuxiliaryImageWorkTests {
  @Test("A held flat-field decoder leaves the main actor available for input")
  func flatFieldDecodeRunsOffMainActor() async throws {
    let model = makeModel()
    let image = makeField(value: 40_000)
    let url = URL(fileURLWithPath: "/flat-field-worker.tiff")
    let probe = FlatFieldWorkerProbe(image: image)
    defer {
      probe.release()
      model.clearFlatField()
    }
    model.flatFieldDecoder = probe.decode

    model.loadFlatField(from: url)
    try await waitUntil { probe.started }
    #expect(!probe.ranOnMainThread)
    #expect(!probe.finished)
    #expect(model.flatFieldImage == nil)

    model.setExposureEV(0.25)
    #expect(model.parameters.photoAdjustments.exposureEV == 0.25)
    #expect(!probe.finished)

    probe.release()
    try await waitUntil { model.flatFieldURL == url }
    #expect(model.flatFieldImage == image)
    #expect(!probe.cancelledAtReturn)
  }

  @Test("A newer flat-field load supersedes a decoder that cannot immediately stop")
  func newestFlatFieldLoadWins() async throws {
    let model = makeModel()
    let oldImage = makeField(value: 20_000)
    let newestImage = makeField(value: 50_000)
    let oldURL = URL(fileURLWithPath: "/flat-field-old.tiff")
    let newestURL = URL(fileURLWithPath: "/flat-field-newest.tiff")
    let probe = FlatFieldWorkerProbe(image: oldImage)
    defer {
      probe.release()
      model.clearFlatField()
    }
    model.flatFieldDecoder = { url in
      if url == oldURL { return try probe.decode(url) }
      return newestImage
    }

    let oldTask = try #require(model.loadFlatField(from: oldURL))
    try await waitUntil { probe.started }
    model.loadFlatField(from: newestURL)
    // On the two-worker scheduler, complete the newest request while the stale
    // synchronous operation is still held. Single-worker machines drain it first.
    if ProcessInfo.processInfo.physicalMemory >= 16 * 1_024 * 1_024 * 1_024 {
      try await waitUntil { model.flatFieldURL == newestURL }
      #expect(!probe.finished)
    }
    probe.release()
    try await waitUntil { probe.finished && model.flatFieldURL == newestURL }
    await oldTask.value

    #expect(probe.cancelledAtReturn)
    #expect(model.flatFieldImage == newestImage)
    #expect(model.flatFieldURL == newestURL)
    #expect(model.rebateStatus == "Flat-field loaded: \(newestURL.lastPathComponent)")
  }

  @Test("Image and contact-sheet export wait for a held flat-field load without cancelling it")
  func exportsWaitForPendingFlatField() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fsc-pending-flat-field-export-\(UUID().uuidString)")
    let destination = work.appendingPathComponent("exports")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let input = work.appendingPathComponent("scan.tiff")
    try makeField(value: 30_000).write(
      to: input, format: .tiff, parameters: ExportParameters(format: .tiff))
    let model = makeModel()
    let currentImage = makeField(value: 40_000)
    let newestImage = makeField(value: 55_000)
    let currentURL = work.appendingPathComponent("current-field.tiff")
    let newestURL = work.appendingPathComponent("newest-field.tiff")
    let probe = FlatFieldWorkerProbe(image: newestImage)
    defer {
      probe.release()
      model.clearFlatField()
      model.selection = nil
      model.loadSelection()
      try? FileManager.default.removeItem(at: work)
    }
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.tiff)
    model.setFlatField(currentImage, url: currentURL)
    model.flatFieldDecoder = probe.decode
    model.loadFlatField(from: newestURL)
    try await waitUntil { probe.started }

    model.exportSelected()
    #expect(!model.isExporting)
    #expect(!model.isExportingContactSheet)
    #expect(model.status == "Wait for flat-field loading to finish before exporting.")
    #expect(model.exportProgressTotal == 0)

    model.exportContactSheet()
    #expect(!model.isExporting)
    #expect(!model.isExportingContactSheet)
    #expect(model.status == "Wait for flat-field loading to finish before exporting.")
    #expect(model.exportProgressTotal == 0)
    #expect(!probe.finished)
    #expect(model.flatFieldImage == currentImage)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

    probe.release()
    try await waitUntil { model.flatFieldURL == newestURL }
    #expect(!probe.cancelledAtReturn)
    #expect(model.flatFieldImage == newestImage)
    #expect(!model.isExporting)
    #expect(!model.isExportingContactSheet)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test(
    "Clear and direct replacement invalidate an in-flight flat-field result",
    arguments: [true, false])
  func explicitFlatFieldChangeRejectsHeldResult(clear: Bool) async throws {
    let model = makeModel()
    let pendingURL = URL(fileURLWithPath: "/flat-field-pending.tiff")
    let currentURL = URL(fileURLWithPath: "/flat-field-current.tiff")
    let currentImage = makeField(value: 55_000)
    let probe = FlatFieldWorkerProbe(image: makeField(value: 15_000))
    defer {
      probe.release()
      model.clearFlatField()
    }
    model.flatFieldDecoder = probe.decode
    model.setFlatField(currentImage, url: currentURL)
    let pendingTask = try #require(model.loadFlatField(from: pendingURL))
    try await waitUntil { probe.started }

    if clear {
      model.clearFlatField()
    } else {
      model.setFlatField(currentImage, url: currentURL)
    }
    let expectedStatus = model.rebateStatus
    probe.release()
    try await waitUntil { probe.finished }
    await pendingTask.value

    #expect(probe.cancelledAtReturn)
    #expect(model.flatFieldImage == (clear ? nil : currentImage))
    #expect(model.flatFieldURL == (clear ? nil : currentURL))
    #expect(model.rebateStatus == expectedStatus)
  }

  @Test("A stale flat-field failure cannot replace the current field or its status")
  func staleFlatFieldFailureDoesNotPublish() async throws {
    let model = makeModel()
    let currentURL = URL(fileURLWithPath: "/flat-field-after-failure.tiff")
    let currentImage = makeField(value: 45_000)
    let probe = FlatFieldWorkerProbe(image: makeField(value: 15_000), fails: true)
    defer {
      probe.release()
      model.clearFlatField()
    }
    model.flatFieldDecoder = probe.decode
    let pendingTask = try #require(
      model.loadFlatField(from: URL(fileURLWithPath: "/flat-field-failing.tiff")))
    try await waitUntil { probe.started }
    model.setFlatField(currentImage, url: currentURL)
    let expectedStatus = model.rebateStatus
    probe.release()
    try await waitUntil { probe.finished }
    await pendingTask.value

    #expect(probe.cancelledAtReturn)
    #expect(model.flatFieldImage == currentImage)
    #expect(model.flatFieldURL == currentURL)
    #expect(model.rebateStatus == expectedStatus)
  }

  @Test(
    "An unsuccessful current flat-field load releases export and allows retry",
    arguments: [true, false])
  func unsuccessfulFlatFieldLoadCanRecover(cancelled: Bool) async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fsc-flat-field-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let input = work.appendingPathComponent("scan.tiff")
    let image = makeField(value: 30_000)
    try image.write(to: input, format: .tiff, parameters: ExportParameters(format: .tiff))
    let model = makeModel()
    defer {
      model.clearFlatField()
      model.selection = nil
      model.loadSelection()
      try? FileManager.default.removeItem(at: work)
    }
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
    model.setExportFormat(.png)
    let oldURL = work.appendingPathComponent("old-field.tiff")
    model.setFlatField(image, url: oldURL)
    model.flatFieldDecoder = { _ in
      if cancelled { throw CancellationError() }
      throw CocoaError(.fileReadCorruptFile)
    }
    let pendingTask = try #require(
      model.loadFlatField(from: work.appendingPathComponent("failed-field.tiff")))
    await pendingTask.value
    #expect(model.flatFieldImage == image)
    #expect(model.flatFieldURL == oldURL)
    if cancelled {
      #expect(model.rebateStatus == "Flat-field loading cancelled.")
    } else {
      #expect(model.rebateStatus.hasPrefix("Failed to load flat-field:"))
    }

    model.exportSelected()
    #expect(model.isExporting)
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("scan.png").path))

    let replacement = makeField(value: 50_000)
    let replacementURL = work.appendingPathComponent("replacement.tiff")
    model.flatFieldDecoder = { _ in replacement }
    let retry = try #require(model.loadFlatField(from: replacementURL))
    await retry.value
    #expect(model.flatFieldImage == replacement)
    #expect(model.flatFieldURL == replacementURL)
  }

  @Test("Clearing crop removes completed and pending dust overlays")
  func clearCropRejectsDustOverlayPublication() async throws {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fsc-clear-crop-dust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let input = work.appendingPathComponent("scan.tiff")
    let source = UInt16Image(
      width: 96, height: 64, channels: 3,
      pixels: [UInt16](repeating: 30_000, count: 96 * 64 * 3))
    try source.write(to: input, format: .tiff, parameters: ExportParameters(format: .tiff))
    let model = makeModel()
    defer {
      model.clearDustMask()
      model.selection = nil
      model.loadSelection()
      try? FileManager.default.removeItem(at: work)
    }
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
    model.setFilmBase(.colorC41)
    let crop = RotatedRect(centerX: 0.5, centerY: 0.5, width: 0.7, height: 0.6, angle: 4)
    model.setCropRect(crop)
    try await waitUntil { !model.isRendering }
    model.detectDustMask()
    try await waitUntil { !model.isDustDetectionRunning && model.dustMaskImage != nil }
    #expect(model.dustMaskImage?.size == model.previewImage?.size)

    model.clearCrop()
    #expect(model.dustMaskImage == nil)
    #expect(!model.isDustDetectionRunning)
    #expect(model.dustStatus.isEmpty)
    try await waitUntil { !model.isRendering }

    model.setCropRect(crop)
    try await waitUntil { !model.isRendering }
    let detectionTask = try #require(model.detectDustMask())
    #expect(model.isDustDetectionRunning)
    // Both calls execute in this main-actor turn before the worker task can begin.
    model.clearCrop()
    #expect(model.dustMaskImage == nil)
    #expect(!model.isDustDetectionRunning)
    try await waitUntil { !model.isRendering }
    await detectionTask.value
    #expect(model.dustMaskImage == nil)
    #expect(!model.isDustDetectionRunning)
    #expect(model.dustStatus.isEmpty)
  }

  private func makeModel() -> AppModel {
    let identifier = "fsc-auxiliary-worker-tests-\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
    let preferences = UserDefaults(suiteName: identifier)!
    return AppModel(
      profileStore: ProfileStore(baseDirectory: directory), preferences: preferences,
      previewMemoryBudget: 1)
  }

  private func makeField(value: UInt16) -> UInt16Image {
    UInt16Image(
      width: 8, height: 4, channels: 3,
      pixels: [UInt16](repeating: value, count: 8 * 4 * 3))
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for auxiliary image work")
      try await Task.sleep(for: .milliseconds(5))
    }
  }

}

/// Simulates synchronous ImageIO work that finishes after cancellation. Native
/// cancellation remains observable, but the gate deliberately does not stop early.
private final class FlatFieldWorkerProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private let image: UInt16Image
  private let fails: Bool
  private var didStart = false
  private var didFinish = false
  private var didRunOnMainThread = false
  private var didObserveCancellation = false

  init(image: UInt16Image, fails: Bool = false) {
    self.image = image
    self.fails = fails
  }

  var started: Bool { lock.withLock { didStart } }
  var finished: Bool { lock.withLock { didFinish } }
  var ranOnMainThread: Bool { lock.withLock { didRunOnMainThread } }
  var cancelledAtReturn: Bool { lock.withLock { didObserveCancellation } }

  func decode(_ url: URL) throws -> UInt16Image {
    lock.withLock {
      didStart = true
      didRunOnMainThread = Thread.isMainThread
    }
    defer {
      let cancelled = RawDecodeCancellation.current?.isCancelled ?? Task.isCancelled
      lock.withLock {
        didObserveCancellation = cancelled
        didFinish = true
      }
    }
    guard gate.wait(timeout: .now() + 5) == .success else { throw ProbeError.notReleased }
    if fails { throw ProbeError.decodeFailed }
    return image
  }

  func release() { gate.signal() }

  private enum ProbeError: Error {
    case notReleased
    case decodeFailed
  }
}
