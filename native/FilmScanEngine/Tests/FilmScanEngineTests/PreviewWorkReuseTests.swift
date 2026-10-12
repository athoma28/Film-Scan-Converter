import AppKit
import CoreImage
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Preview stage invalidation and thumbnail preparation", .serialized)
@MainActor
struct PreviewWorkReuseTests {
  @Test(
    "Obsolete CPU corrections skip packing after a context or source change",
    arguments: ["geometry", "comparison", "source", "deselection"])
  func invalidationSkipsCPUPacking(change: String) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = try await loadedModel(fixture: fixture, cpuFallback: true)
    let gate = RenderCheckpointGate(holding: .cpuCorrectionComplete)
    model.previewRenderCheckpointHook = gate.checkpoint
    defer { gate.release() }
    let publications = model.renderStats.displayedRenders

    model.setExposureEV(0.25)
    try await waitUntil { gate.isHeld }
    switch change {
    case "geometry": model.rotateClockwise()
    case "comparison": model.showOriginal = true
    case "source": model.loadSelection()
    default:
      model.selection = nil
      model.loadSelection()
    }
    #expect(gate.frames.count == 1)
    gate.release()
    try await waitUntil { !model.isRendering && !model.isLoading }

    #expect(gate.frames.first == [.started, .flatFieldPrepared, .cpuCorrectionComplete])
    #expect(!gate.ranOnMainThread)
    if change == "deselection" {
      #expect(model.previewImage == nil)
      #expect(model.renderStats.displayedRenders == publications)
    } else {
      #expect(model.publishedPreviewParameters == model.parameters)
      #expect(model.renderStats.displayedRenders == publications + 1)
    }
  }

  @Test("Ordinary point edits retain useful intermediate CPU publication")
  func pointEditsKeepCompletedWork() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = try await loadedModel(fixture: fixture, cpuFallback: true)
    let gate = RenderCheckpointGate(holding: .cpuCorrectionComplete)
    model.previewRenderCheckpointHook = gate.checkpoint
    defer { gate.release() }
    let publications = model.renderStats.displayedRenders

    model.setExposureEV(0.25)
    try await waitUntil { gate.isHeld }
    model.setExposureEV(0.75)
    #expect(gate.frames.count == 1)
    gate.release()
    try await waitUntil { !model.isRendering }

    #expect(gate.frames.count == 2)
    #expect(gate.frames.allSatisfy { $0.contains(.cpuPacked) })
    #expect(model.renderStats.displayedRenders == publications + 2)
    #expect(model.publishedPreviewParameters == model.parameters)
  }

  @Test(
    "Invalidated CPU viewports stop before the remaining bitmap packing",
    arguments: [PreviewRenderCheckpoint.cpuViewportComplete, .cpuOverviewPacked])
  func invalidationSkipsViewportPacking(checkpoint: PreviewRenderCheckpoint) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = try await loadedModel(fixture: fixture, cpuFallback: true)
    let size = try #require(model.previewImage?.size)
    model.setPreviewRenderDemand(
      PreviewRenderDemand(
        documentSize: size,
        visibleRect: CGRect(x: 96, y: 64, width: 96, height: 64),
        backingScale: 2, magnification: 1))
    let gate = RenderCheckpointGate(holding: checkpoint)
    model.previewRenderCheckpointHook = gate.checkpoint
    defer {
      gate.release()
      model.endEditingGesture()
    }
    let publications = model.renderStats.displayedRenders

    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    try await waitUntil { gate.isHeld }
    model.showOriginal = true
    #expect(gate.frames.count == 1)
    gate.release()
    try await waitUntil { !model.isRendering }

    let expected: [PreviewRenderCheckpoint] =
      checkpoint == .cpuViewportComplete
      ? [.started, .cpuViewportComplete]
      : [.started, .cpuViewportComplete, .cpuOverviewPacked]
    #expect(gate.frames.first == expected)
    #expect(model.renderStats.displayedRenders == publications + 1)
    model.endEditingGesture()
    try await waitUntil { !model.isRendering }
    #expect(model.previewDetail == nil)
    #expect(model.publishedPreviewParameters == model.parameters)
  }

  @Test("Invalidated GPU overviews skip obsolete visible-detail rendering")
  func invalidationSkipsGPUDetail() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = try await loadedModel(fixture: fixture, cpuFallback: false)
    let size = try #require(model.previewImage?.size)
    let demand = PreviewRenderDemand(
      documentSize: size,
      visibleRect: CGRect(x: 96, y: 64, width: 96, height: 64),
      backingScale: 2, magnification: 1)
    try #require(demand.detailRect != nil)
    model.setPreviewRenderDemand(demand)
    let gate = RenderCheckpointGate(holding: .gpuOverviewComplete)
    model.previewRenderCheckpointHook = gate.checkpoint
    defer {
      gate.release()
      model.endEditingGesture()
    }
    let publications = model.renderStats.displayedRenders

    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    try await waitUntil { gate.isHeld }
    model.showOriginal = true
    #expect(gate.frames.count == 1)
    gate.release()
    try await waitUntil { !model.isRendering }

    #expect(gate.frames.first == [.started, .gpuOverviewComplete])
    #expect(model.renderStats.displayedRenders == publications + 1)
    #expect(model.previewDetail != nil)
    model.endEditingGesture()
    try await waitUntil { !model.isRendering }
    #expect(model.previewDetail == nil)
    #expect(model.publishedPreviewParameters == model.parameters)
  }

  @Test("Thumbnail bitmap preparation stays off the main actor and is memoized")
  func thumbnailWorkerAndReuse() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let model = fixture.model()
    let gate = ThumbnailPreparationGate()
    model.thumbnailPreparationHook = gate.prepare
    defer { gate.release() }

    model.requestThumbnail(for: fixture.input)
    try await waitUntil { gate.isHeld }
    model.requestThumbnail(for: fixture.input)
    model.setExposureEV(0.35)
    #expect(model.parameters.photoAdjustments.exposureEV == 0.35)
    #expect(model.thumbnail(for: fixture.input) == nil)
    #expect(!gate.ranOnMainThread)
    #expect(gate.calls == 1)

    gate.release()
    try await waitUntil { model.thumbnail(for: fixture.input) != nil }
    let first = try #require(model.thumbnail(for: fixture.input))
    let actual = try #require(PreviewBitmap.cgImage(from: first))
    let source = try StandardImageDecoder.decodePreview(
      fixture.input, maxDimension: AppModel.thumbnailMaxDimension)
    let expected = try legacyInversion(try #require(source.makePreviewCGImage()))
    #expect(try bitmapData(actual) == bitmapData(expected))
    model.requestThumbnail(for: fixture.input)
    #expect(model.thumbnail(for: fixture.input) === first)
    #expect(gate.calls == 1)
    #expect(model.previewCacheSessionCount == 0)
  }

  @Test("Shared thumbnail context preserves independent concurrent outputs")
  func concurrentThumbnailInversion() async throws {
    let inputs = try (0..<8).map { index in
      let pixels = (0..<(64 * 48 * 3)).map {
        UInt16(truncatingIfNeeded: $0 * 257 + index * 7_919)
      }
      return try #require(
        UInt16Image(width: 64, height: 48, channels: 3, pixels: pixels).makePreviewCGImage())
    }
    let expected = try inputs.map { try bitmapData(legacyInversion($0)) }
    let actual = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      for (index, input) in inputs.enumerated() {
        group.addTask {
          let rendered = try #require(PreviewBitmap.invertedCGImage(from: input))
          return (index, try #require(rendered.dataProvider?.data as Data?))
        }
      }
      var results = [Data](repeating: Data(), count: inputs.count)
      for try await (index, data) in group { results[index] = data }
      return results
    }
    #expect(actual == expected)
  }

  private func loadedModel(fixture: Fixture, cpuFallback: Bool) async throws -> AppModel {
    let model = fixture.model()
    model.importFiles([fixture.input])
    try await waitUntil { model.previewImage != nil && !model.isRendering && !model.isLoading }
    model.setFilmBase(.slide)
    if cpuFallback { model.setStraightenAngle(3) }
    try await waitUntil { !model.isRendering }
    #expect(model.status.contains(cpuFallback ? "CPU" : "GPU"))
    return model
  }

  private func legacyInversion(_ source: CGImage) throws -> CGImage {
    let image = CIImage(cgImage: source).applyingFilter("CIColorInvert")
    let context = CIContext(options: [.cacheIntermediates: false])
    return try #require(
      context.createCGImage(
        image, from: image.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
  }

  private func bitmapData(_ image: CGImage) throws -> Data {
    try #require(image.dataProvider?.data as Data?)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for preview work")
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private struct Fixture {
    let identifier = "fsc-preview-work-\(UUID().uuidString)"
    let directory: URL
    let input: URL
    let preferences: UserDefaults

    init() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
      input = directory.appendingPathComponent("scan.png")
      preferences = try #require(UserDefaults(suiteName: identifier))
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let pixels = (0..<(384 * 256 * 3)).map { UInt16(truncatingIfNeeded: $0 * 257 + 73) }
      try UInt16Image(width: 384, height: 256, channels: 3, pixels: pixels).write(
        to: input, format: .png, parameters: ExportParameters(format: .png))
    }

    @MainActor func model() -> AppModel {
      AppModel(
        profileStore: ProfileStore(baseDirectory: directory), preferences: preferences,
        previewMemoryBudget: 1)
    }

    func cleanUp() {
      preferences.removePersistentDomain(forName: identifier)
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private final class RenderCheckpointGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private let target: PreviewRenderCheckpoint
  private var recorded: [[PreviewRenderCheckpoint]] = []
  private var held = false
  private var usedGate = false
  private var mainThread = false

  init(holding target: PreviewRenderCheckpoint) { self.target = target }

  var frames: [[PreviewRenderCheckpoint]] { lock.withLock { recorded } }
  var isHeld: Bool { lock.withLock { held } }
  var ranOnMainThread: Bool { lock.withLock { mainThread } }

  func checkpoint(_ checkpoint: PreviewRenderCheckpoint) {
    let shouldWait = lock.withLock {
      if checkpoint == .started { recorded.append([]) }
      recorded[recorded.count - 1].append(checkpoint)
      mainThread = mainThread || Thread.isMainThread
      guard checkpoint == target, !usedGate else { return false }
      usedGate = true
      held = true
      return true
    }
    if shouldWait {
      _ = semaphore.wait(timeout: .now() + 10)
      lock.withLock { held = false }
    }
  }

  func release() { semaphore.signal() }
}

private final class ThumbnailPreparationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var held = false
  private var count = 0
  private var mainThread = false

  var isHeld: Bool { lock.withLock { held } }
  var calls: Int { lock.withLock { count } }
  var ranOnMainThread: Bool { lock.withLock { mainThread } }

  func prepare() {
    lock.withLock {
      count += 1
      mainThread = mainThread || Thread.isMainThread
      held = true
    }
    _ = semaphore.wait(timeout: .now() + 10)
    lock.withLock { held = false }
  }

  func release() { semaphore.signal() }
}
