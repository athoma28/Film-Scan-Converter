import AppKit
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Session-owned CPU preview preparation", .serialized)
@MainActor
struct CPUPreparationRetentionTests {
  @Test("Cached A to B to A preserves full and continuous CPU owners and exact point-edit pixels")
  func cachedRevisitPreservesPreparation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let decoder = PreparationSessionDecoder()
    let model = fixture.model(decoder: decoder)
    defer { model.closeAllScans() }
    try await warmBoth(model, fixture: fixture)
    let full = try #require(decoder.fullPreparation(for: fixture.urls[0]))
    let continuous = try #require(decoder.continuousPreparation(for: fixture.urls[0]))
    let fullBuilds = full.geometryBuildCount
    #expect(fullBuilds > 0 && full.retainedGeometryByteCount > 0)
    try expectProductionCPU(model)

    // Fit gestures exercise the distinct bounded edit source. Release returns
    // to the authoritative full source before any navigation or bitmap guard.
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    try await waitUntil { !model.isRendering && continuous.geometryBuildCount > 0 }
    model.endEditingGesture()
    try await settled(model)
    let continuousBuilds = continuous.geometryBuildCount
    #expect(full.geometryBuildCount == fullBuilds)
    try expectProductionCPU(model)
    let calls = decoder.callCount
    let corrections = model.previewCorrectionCount
    let hits = model.previewRenderCacheHits
    let fullDecodes = model.fullResolutionPreviewDecodeCount

    model.selection = fixture.urls[1]
    model.loadSelection()
    try await settled(model)
    model.selection = fixture.urls[0]
    model.loadSelection()
    try await settled(model)
    #expect(decoder.fullPreparation(for: fixture.urls[0]) === full)
    #expect(decoder.continuousPreparation(for: fixture.urls[0]) === continuous)
    #expect(decoder.callCount == calls)
    #expect(model.fullResolutionPreviewDecodeCount == fullDecodes)
    #expect(model.previewCorrectionCount == corrections)
    #expect(model.previewRenderCacheHits == hits + 2)

    model.setExposureEV(0.5)
    try await settled(model)
    #expect(full.geometryBuildCount == fullBuilds)
    #expect(model.previewCorrectionCount == corrections + 1)
    try expectProductionCPU(model)
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.75)
    try await waitUntil {
      !model.isRendering && model.publishedPreviewParameters?.photoAdjustments.exposureEV == 0.75
    }
    #expect(continuous.geometryBuildCount == continuousBuilds)
    model.endEditingGesture()
    try await settled(model)
    #expect(full.geometryBuildCount == fullBuilds)
    try expectProductionCPU(model)
    model.closeAllScans()
    try await drained(model)
  }

  @Test("Changing geometry rebuilds the retained owner and preserves fresh production CPU pixels")
  func geometryInvalidatesWithinTheSameOwner() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let decoder = PreparationSessionDecoder()
    let model = fixture.model(decoder: decoder)
    defer { model.closeAllScans() }
    try await warmBoth(model, fixture: fixture)
    let preparation = try #require(decoder.fullPreparation(for: fixture.urls[0]))
    let builds = preparation.geometryBuildCount
    let before = try previewPixels(model)

    model.setStraightenAngle(-3)
    try await settled(model)
    #expect(decoder.fullPreparation(for: fixture.urls[0]) === preparation)
    #expect(preparation.geometryBuildCount == builds + 1)
    #expect(try previewPixels(model) != before)
    try expectProductionCPU(model)
    model.setExposureEV(0.25)
    try await settled(model)
    #expect(preparation.geometryBuildCount == builds + 1)
    try expectProductionCPU(model)
    model.closeAllScans()
    try await drained(model)
  }

  @Test("Pressure releases unselected preparation and Close All releases selected owners and model")
  func pressureAndCloseReleaseOwners() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let decoder = PreparationSessionDecoder()
    var model: AppModel? = fixture.model(decoder: decoder)
    defer { model?.closeAllScans() }
    weak var releasedModel = model
    try await warmBoth(try #require(model), fixture: fixture)
    weak var firstFull = decoder.fullPreparation(for: fixture.urls[0])
    weak var firstContinuous = decoder.continuousPreparation(for: fixture.urls[0])
    weak var secondFull = decoder.fullPreparation(for: fixture.urls[1])
    weak var secondContinuous = decoder.continuousPreparation(for: fixture.urls[1])
    try #require(firstFull != nil && firstContinuous != nil)
    try #require(secondFull != nil && secondContinuous != nil)
    model?.selection = fixture.urls[1]
    model?.loadSelection()
    try await settled(try #require(model))
    model?.handlePreviewMemoryPressure(isUnderPressure: true)
    try await waitUntil { firstFull == nil && firstContinuous == nil }
    #expect(model?.previewCacheSessionCount == 1)
    #expect(secondFull != nil && secondContinuous != nil)
    try expectProductionCPU(try #require(model))

    model?.closeAllScans()
    try await drained(try #require(model))
    try await waitUntil { secondFull == nil && secondContinuous == nil }
    #expect(model?.previewCacheSessionCount == 0)
    #expect(model?.previewCachePhysicalBytes == 0)
    model = nil
    try await waitUntil { releasedModel == nil }
  }

  @Test("An invalidated worker's new geometry is trimmed before the next worker can finish")
  func staleGeometryGrowthIsTrimmed() async throws {
    let fixture = try Fixture(simpleFirst: true)
    defer { fixture.cleanUp() }
    let decoder = PreparationSessionDecoder()
    let sample = try decoder.makeSession(for: fixture.urls[0])
    let source = sample.displaySource
    let baseReservation = sample.reservedByteCount + sample.displayByteReservation
    let secondGeometry =
      FilmProcessing.prepareGeometry(
        image: source, parameters: fixture.parameters[1]
      ).pixels.count * MemoryLayout<UInt16>.stride
    // Both decoded/rendered owners and B's warp fit. Allow two half canvases
    // and the selected proxy, while leaving less room than A's new full warp.
    let canvasAllowance = source.width * source.height * 2
    let proxyAllowance =
      (sample.continuousEditSource?.pixels.count ?? 0)
      * MemoryLayout<UInt16>.stride
    let budget = baseReservation * 2 + secondGeometry + canvasAllowance + proxyAllowance
    let model = fixture.model(decoder: decoder, budget: budget)
    let firstGate = PreparationCheckpointGate(holding: .cpuCorrectionComplete)
    let secondGate = PreparationCheckpointGate(holding: .started)
    defer {
      firstGate.release()
      secondGate.release()
      model.closeAllScans()
    }
    try await warmBoth(model, fixture: fixture)
    try #require(model.previewCacheSessionCount == 2)
    let firstPreparation = try #require(decoder.fullPreparation(for: fixture.urls[0]))
    try #require(firstPreparation.retainedGeometryByteCount == 0)
    let publications = model.renderStats.displayedRenders
    let decoded = decoder.callCount
    model.previewRenderCheckpointHook = firstGate.checkpoint
    model.setStraightenAngle(3)
    try await waitUntil { firstGate.isHeld }
    try #require(firstPreparation.retainedGeometryByteCount > canvasAllowance + proxyAllowance)

    // Each worker captures its checkpoint closure before starting. B waits at
    // .started, leaving a deterministic observation window after stale A drains.
    model.previewRenderCheckpointHook = secondGate.checkpoint
    model.selection = fixture.urls[1]
    model.loadSelection()
    model.setExposureEV(0.25)
    firstGate.release()
    try await waitUntil { secondGate.isHeld }
    #expect(decoder.callCount == decoded)
    #expect(!model.hasCachedPreview(for: fixture.urls[0]))
    #expect(model.hasCachedPreview(for: fixture.urls[1]))
    #expect(model.previewCacheSessionCount == 1)
    #expect(model.previewCachePhysicalBytes <= budget)
    #expect(model.renderStats.displayedRenders == publications)
    secondGate.release()
    try await settled(model)
    try expectProductionCPU(model)
    model.closeAllScans()
    try await drained(model)
  }

  private func warmBoth(_ model: AppModel, fixture: Fixture) async throws {
    model.importFiles(fixture.urls)
    try await settled(model)
    for index in [1, 0] {
      model.selection = fixture.urls[index]
      model.loadSelection()
      try await settled(model)
    }
    try #require(model.previewCacheSessionCount == 2)
  }

  private func settled(_ model: AppModel) async throws {
    try await waitUntil {
      model.previewSourceKind == .rawFull && model.previewImage != nil
        && !model.isLoading && !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive
        && model.previewStatisticsRevision == model.publishedRenderRevision
    }
    try #require(model.publishedPreviewParameters == model.parameters)
  }

  private func drained(_ model: AppModel) async throws {
    try await waitUntil {
      !model.isLoading && !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive
    }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for CPU preparation work")
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func previewPixels(_ model: AppModel) throws -> Data {
    let image = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    return try #require(image.dataProvider?.data as Data?)
  }

  private func expectProductionCPU(_ model: AppModel) throws {
    let source = try #require(model.decodedImage)
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: model.parameters)
        .makePreviewCGImage())
    let actual = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let expectedPixels = try #require(expected.dataProvider?.data as Data?)
    #expect(actual.width == expected.width && actual.height == expected.height)
    #expect(try previewPixels(model) == expectedPixels)
    #expect(model.previewImage?.size == NSSize(width: expected.width, height: expected.height))
  }

  private struct Fixture {
    let directory: URL
    let urls: [URL]
    let parameters: [ProcessingParameters]
    let suiteName: String
    let preferences: UserDefaults
    let store: PerFileSettingsStore

    init(simpleFirst: Bool = false) throws {
      let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "fsc-cpu-preparation-retention-\(UUID().uuidString)")
      directory = fixtureDirectory
      try FileManager.default.createDirectory(
        at: fixtureDirectory, withIntermediateDirectories: true)
      urls = (0..<2).map { fixtureDirectory.appendingPathComponent("\($0).RAF") }
      for url in urls { try Data().write(to: url) }
      suiteName = "fsc-cpu-preparation-retention-\(UUID().uuidString)"
      preferences = try #require(UserDefaults(suiteName: suiteName))
      store = PerFileSettingsStore(baseDirectory: directory.appendingPathComponent("settings"))
      parameters = (0..<2).map { index in
        var p = FilmBase.colorC41.applyingInvert(
          to: ProcessingParameters(photoAdjustments: .init(schemaVersion: 4)))
        p.filmBaseChosenByUser = true
        if !simpleFirst || index == 1 {
          p.straightenAngle = 2
          if !simpleFirst {
            p.perspectiveCrop = .init(
              topLeft: .init(x: 0.08, y: 0.10), topRight: .init(x: 0.93, y: 0.08),
              bottomRight: .init(x: 0.91, y: 0.92), bottomLeft: .init(x: 0.10, y: 0.90))
          }
        }
        return p
      }
      try store.save(
        .init(
          settingsByPath: Dictionary(
            uniqueKeysWithValues: zip(urls, parameters).map {
              ($0.0.standardizedFileURL.path, $0.1)
            }), editedPaths: Set(urls.map { $0.standardizedFileURL.path })))
    }

    @MainActor func model(decoder: PreparationSessionDecoder, budget: Int? = nil) -> AppModel {
      let model = AppModel(
        profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
        settingsStore: store, preferences: preferences, previewMemoryBudget: budget)
      model.rawPreviewSessionDecoder = decoder.decode
      model.setPreviewCacheLimit(2)
      return model
    }

    func cleanUp() {
      preferences.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private final class PreparationSessionDecoder: @unchecked Sendable {
  private struct Owners {
    weak var full: CPUPreviewPreparationCache?
    weak var continuous: CPUPreviewPreparationCache?
  }

  private let lock = NSLock()
  private var owners: [String: Owners] = [:]
  private var calls = 0

  var callCount: Int { lock.withLock { calls } }

  func fullPreparation(for url: URL) -> CPUPreviewPreparationCache? {
    lock.withLock { owners[url.standardizedFileURL.path]?.full }
  }

  func continuousPreparation(for url: URL) -> CPUPreviewPreparationCache? {
    lock.withLock { owners[url.standardizedFileURL.path]?.continuous }
  }

  func decode(_ url: URL, _: PreviewSourceKind) throws -> CachedPreviewSession {
    // A full synthetic tier avoids any real RAW decode or tier race. Recording
    // only weak owners lets release assertions observe AppModel ownership.
    let session = try makeSession(for: url)
    lock.withLock {
      calls += 1
      owners[url.standardizedFileURL.path] = Owners(
        full: session.cpuPreviewPreparation, continuous: session.continuousEditCPUPreparation)
    }
    return session
  }

  func makeSession(for url: URL) throws -> CachedPreviewSession {
    let width = 128
    let height = 96
    let offset = (Int(url.deletingPathExtension().lastPathComponent) ?? 0) * 5_000
    let source = UInt16Image(
      width: width, height: height, channels: 3,
      pixels: (0..<(width * height * 3)).map {
        UInt16(4_000 + offset + ($0 * 173) % 44_000)
      })
    let proxy = source.resizedToFit(maxDimension: width / 2)
    return CachedPreviewSession(
      sourceKind: .rawFull, displaySource: source, analysisSource: source,
      previewRenderer: try #require(StillPreviewRenderer(image: source)),
      continuousEditSource: proxy,
      continuousEditRenderer: try #require(
        StillPreviewRenderer(image: proxy, analysisImage: source)),
      sourcePixelDimensions: .init(width: width, height: height))
  }
}

private final class PreparationCheckpointGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private let target: PreviewRenderCheckpoint
  private var held = false
  private var used = false

  init(holding target: PreviewRenderCheckpoint) { self.target = target }
  var isHeld: Bool { lock.withLock { held } }

  func checkpoint(_ checkpoint: PreviewRenderCheckpoint) {
    let shouldWait = lock.withLock {
      guard checkpoint == target, !used else { return false }
      held = true
      used = true
      return true
    }
    if shouldWait {
      _ = semaphore.wait(timeout: .now() + 10)
      lock.withLock { held = false }
    }
  }

  func release() { semaphore.signal() }
}
