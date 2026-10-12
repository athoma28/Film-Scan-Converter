import AppKit
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Discarding incompatible CPU preparation", .serialized)
struct CPUPreparationDiscardTests {
  @Test(
    "Point edits preserve prepared geometry, while incompatible release clears warp and overview")
  func releasePreservesMatchingGeometry() async throws {
    let source = CPUPreparationPerformanceTests.image(width: 96, height: 64)
    let preparation = CPUPreviewPreparationCache(image: source)
    let parameters = warpedParameters()
    _ = try #require(
      preparation.renderViewport(
        parameters: parameters, region: .init(x: 4, y: 4, width: 8, height: 6),
        overviewMaximumDimension: 16))
    let bytes = preparation.retainedGeometryByteCount
    let geometryBuilds = preparation.geometryBuildCount
    let analysisBuilds = preparation.analysisBuildCount
    #expect(bytes > 0 && geometryBuilds == 1 && analysisBuilds == 1)

    var pointEdit = parameters
    pointEdit.photoAdjustments.exposureEV = 0.25
    await Task.detached { [pointEdit] in
      preparation.discardGeometry(ifIncompatibleWith: pointEdit)
    }.value
    #expect(preparation.retainedGeometryByteCount == bytes)
    #expect(
      preparation.render(parameters: pointEdit)
        == FilmProcessing.correctedPreview(image: source, parameters: pointEdit))
    #expect(preparation.geometryBuildCount == geometryBuilds)
    #expect(preparation.analysisBuildCount == analysisBuilds)

    var simple = pointEdit
    simple.perspectiveCrop = nil
    simple.straightenAngle = 0
    await Task.detached { [simple] in
      preparation.discardGeometry(ifIncompatibleWith: simple)
    }.value
    #expect(preparation.retainedGeometryByteCount == 0)
    #expect(preparation.geometryBuildCount == geometryBuilds)
    #expect(preparation.analysisBuildCount == analysisBuilds)
    #expect(
      preparation.render(parameters: parameters)
        == FilmProcessing.correctedPreview(image: source, parameters: parameters))
    #expect(preparation.geometryBuildCount == geometryBuilds + 1)
    #expect(preparation.analysisBuildCount == analysisBuilds + 1)
  }

  @Test("Density reference renders release only incompatible geometry", arguments: [false, true])
  func densityBypass(incompatible: Bool) throws {
    let source = CPUPreparationPerformanceTests.image(width: 96, height: 64)
    let preparation = CPUPreviewPreparationCache(image: source)
    let parameters = warpedParameters()
    _ = try #require(
      preparation.renderViewport(
        parameters: parameters, region: .init(x: 4, y: 4, width: 8, height: 6),
        overviewMaximumDimension: 16))
    let bytes = preparation.retainedGeometryByteCount
    let builds = preparation.geometryBuildCount
    let analysisBuilds = preparation.analysisBuildCount
    var density = parameters
    density.densityPipelineEnabled = true
    density.densityBaseDensity = .init(blue: 0.2, green: 0.3, red: 0.4)
    density.filmNegativeParams.rendering = .powerLaw
    if incompatible { density.straightenAngle = -3 }
    let field = UInt16Image(
      width: source.width, height: source.height, channels: 3,
      pixels: [UInt16](repeating: .max, count: source.pixels.count))
    #expect(
      preparation.render(parameters: density, flatField: field)
        == FilmProcessing.correctedPreview(
          image: source, parameters: density, flatField: field))
    #expect(preparation.retainedGeometryByteCount == (incompatible ? 0 : bytes))
    #expect(preparation.geometryBuildCount == builds)
    #expect(preparation.analysisBuildCount == analysisBuilds)
    #expect(
      preparation.render(parameters: parameters)
        == FilmProcessing.correctedPreview(image: source, parameters: parameters))
    #expect(preparation.geometryBuildCount == builds + (incompatible ? 1 : 0))
    #expect(preparation.analysisBuildCount == analysisBuilds + (incompatible ? 1 : 0))
  }

  @Test("Discarding obsolete geometry restores exact byte-budget session capacity")
  func releaseRestoresAdmission() throws {
    let source = CPUPreparationPerformanceTests.image(width: 96, height: 64)
    let first = CachedPreviewSession(
      sourceKind: .rawFull, displaySource: source, analysisSource: source,
      previewRenderer: try #require(StillPreviewRenderer(image: source)),
      sourcePixelDimensions: .init(width: source.width, height: source.height))
    let secondSource = source.inverted()
    let second = CachedPreviewSession(
      sourceKind: .rawFull, displaySource: secondSource, analysisSource: secondSource,
      previewRenderer: try #require(StillPreviewRenderer(image: secondSource)),
      sourcePixelDimensions: .init(width: source.width, height: source.height))
    let firstReservation = first.reservedByteCount + first.displayByteReservation
    let secondReservation = second.reservedByteCount + second.displayByteReservation
    let limits = PreviewSessionCache.Limits(
      count: 2, bytes: firstReservation + secondReservation, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(first, forKey: "first", limits: limits, preserving: "first")
    let originalCharge = cache.physicalByteCount
    _ = first.cpuPreviewPreparation.render(parameters: warpedParameters())
    let geometryBytes = first.cpuPreviewPreparation.retainedGeometryByteCount
    #expect(geometryBytes > 0)
    #expect(cache.physicalByteCount == originalCharge + geometryBytes)
    #expect(
      !cache.canAdmitSession(
        forKey: "second", estimatedByteCount: secondReservation, limits: limits))

    var simple = warpedParameters()
    simple.perspectiveCrop = nil
    simple.straightenAngle = 0
    first.cpuPreviewPreparation.discardGeometry(ifIncompatibleWith: simple)
    #expect(cache.physicalByteCount == originalCharge)
    #expect(cache["first"]?.cpuPreviewPreparation === first.cpuPreviewPreparation)
    #expect(
      cache.canAdmitSession(
        forKey: "second", estimatedByteCount: secondReservation, limits: limits))
    cache.insert(
      second, forKey: "second", limits: limits, preserving: "first", speculative: true)
    #expect(cache.count == 2)
    #expect(cache.reservedByteCount == limits.bytes)
  }

  private func warpedParameters() -> ProcessingParameters {
    var parameters = FilmBase.colorC41.applyingInvert(
      to: ProcessingParameters(photoAdjustments: .init(schemaVersion: 4)))
    parameters.perspectiveCrop = .init(
      topLeft: .init(x: 0.08, y: 0.10), topRight: .init(x: 0.93, y: 0.08),
      bottomRight: .init(x: 0.91, y: 0.92), bottomLeft: .init(x: 0.10, y: 0.90))
    parameters.straightenAngle = 2
    return parameters
  }
}

@Suite("GPU transitions release obsolete CPU preparation", .serialized)
@MainActor
struct CPUPreparationGPUTransitionTests {
  @Test("Returning warped full and Fit sources to GPU releases only incompatible preparation")
  func geometryReturnsToGPU() async throws {
    let fixture = try Fixture(flat: false)
    defer { fixture.cleanUp() }
    let decoder = DiscardSessionDecoder(flat: false)
    let model = fixture.model(decoder: decoder)
    defer { model.closeAllScans() }
    model.importFiles([fixture.input])
    try await settled(model)
    let full = try #require(decoder.fullPreparation)
    let continuous = try #require(decoder.continuousPreparation)
    try expectCPU(model, source: decoder.source)
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    try await waitUntil { !model.isRendering && continuous.geometryBuildCount > 0 }
    model.endEditingGesture()
    try await settled(model)
    let fullBuilds = full.geometryBuildCount
    let continuousBuilds = continuous.geometryBuildCount
    #expect(full.retainedGeometryByteCount > 0)
    #expect(continuous.retainedGeometryByteCount > 0)

    // Both setters execute before the next main-actor render starts. The final
    // GPU-eligible snapshot must not build an intermediate CPU warp.
    model.clearPerspectiveCrop()
    model.setStraightenAngle(0)
    try await settled(model)
    #expect(decoder.fullPreparation === full)
    #expect(decoder.continuousPreparation === continuous)
    #expect(full.retainedGeometryByteCount == 0)
    #expect(continuous.retainedGeometryByteCount == 0)
    #expect(full.geometryBuildCount == fullBuilds)
    #expect(continuous.geometryBuildCount == continuousBuilds)
    try expectGPU(model, source: decoder.source)

    model.setPerspectiveCrop(fixture.parameters.perspectiveCrop)
    model.setStraightenAngle(fixture.parameters.straightenAngle)
    try await settled(model)
    #expect(decoder.fullPreparation === full)
    #expect(full.geometryBuildCount == fullBuilds + 1)
    #expect(full.retainedGeometryByteCount > 0)
    try expectCPU(model, source: decoder.source)
  }

  @Test("GPU Original preserves matching CPU rotation geometry for a flat-density return")
  func originalPreservesMatchingGeometry() async throws {
    let fixture = try Fixture(flat: true)
    defer { fixture.cleanUp() }
    let decoder = DiscardSessionDecoder(flat: true)
    let model = fixture.model(decoder: decoder)
    defer { model.closeAllScans() }
    model.importFiles([fixture.input])
    try await settled(model)
    let preparation = try #require(decoder.fullPreparation)
    let builds = preparation.geometryBuildCount
    let bytes = preparation.retainedGeometryByteCount
    #expect(bytes > 0)
    try expectCPU(model, source: decoder.source)
    let corrected = try pixels(model)

    model.showOriginal = true
    try await settled(model)
    #expect(preparation.geometryBuildCount == builds)
    #expect(preparation.retainedGeometryByteCount == bytes)
    try expectGPU(model, source: decoder.source)
    model.showOriginal = false
    try await settled(model)
    #expect(preparation.geometryBuildCount == builds)
    #expect(preparation.retainedGeometryByteCount == bytes)
    #expect(try pixels(model) == corrected)
    try expectCPU(model, source: decoder.source)
  }

  private func expectGPU(_ model: AppModel, source: UInt16Image) throws {
    #expect(model.status.contains("GPU"))
    let renderer = try #require(StillPreviewRenderer(image: source, analysisImage: source))
    try #require(renderer.supports(parameters: model.parameters, showOriginal: model.showOriginal))
    let expectedGPU = try #require(
      renderer.render(parameters: model.parameters, showOriginal: model.showOriginal))
    let actual = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    #expect(actual.width == expectedGPU.width && actual.height == expectedGPU.height)
    #expect(try rgb(actual) == rgb(expectedGPU))
    var parameters = model.parameters
    if model.showOriginal { parameters.filmType = .cropOnly }
    let expectedCPU = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: parameters).makePreviewCGImage())
    let actualPixels = try rgb(actual)
    let cpuPixels = try rgb(expectedCPU)
    try #require(actualPixels.count == cpuPixels.count)
    // Existing production photographic CPU/Metal contract allows two display
    // codes on synthetic scans; the independent GPU output above is exact.
    #expect(zip(actualPixels, cpuPixels).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    #expect(
      model.previewImage?.size == NSSize(width: expectedCPU.width, height: expectedCPU.height))
  }

  private func expectCPU(_ model: AppModel, source: UInt16Image) throws {
    #expect(model.status.contains("CPU"))
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: model.parameters)
        .makePreviewCGImage())
    let actual = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    #expect(actual.width == expected.width && actual.height == expected.height)
    #expect(try rgb(actual) == rgb(expected))
    #expect(model.previewImage?.size == NSSize(width: expected.width, height: expected.height))
  }

  private func pixels(_ model: AppModel) throws -> [UInt8] {
    try rgb(try #require(model.previewImage.flatMap(PreviewBitmap.cgImage)))
  }

  private func rgb(_ image: CGImage) throws -> [UInt8] {
    try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    try #require(image.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little)
    let data = try #require(image.dataProvider?.data)
    let pointer = try #require(CFDataGetBytePtr(data))
    try #require(CFDataGetLength(data) >= image.bytesPerRow * image.height)
    return (0..<image.height).flatMap { y in
      (0..<image.width).flatMap { x in
        let pixel = pointer + y * image.bytesPerRow + x * 4
        return [pixel[0], pixel[1], pixel[2]]
      }
    }
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

  private func waitUntil(_ ready: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !ready() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for GPU/CPU transition")
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private struct Fixture {
    let directory: URL
    let input: URL
    let parameters: ProcessingParameters
    let suiteName: String
    let preferences: UserDefaults
    let store: PerFileSettingsStore

    init(flat: Bool) throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "fsc-cpu-preparation-discard-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      input = directory.appendingPathComponent("scan.RAF")
      try Data().write(to: input)
      suiteName = "fsc-cpu-preparation-discard-\(UUID().uuidString)"
      preferences = try #require(UserDefaults(suiteName: suiteName))
      store = PerFileSettingsStore(baseDirectory: directory.appendingPathComponent("settings"))
      var saved = FilmBase.colorC41.applyingInvert(
        to: ProcessingParameters(photoAdjustments: .init(schemaVersion: 4)))
      saved.filmBaseChosenByUser = true
      if flat {
        saved.rotation = 1
      } else {
        saved.perspectiveCrop = .init(
          topLeft: .init(x: 0.08, y: 0.10), topRight: .init(x: 0.93, y: 0.08),
          bottomRight: .init(x: 0.91, y: 0.92), bottomLeft: .init(x: 0.10, y: 0.90))
        saved.straightenAngle = 2
      }
      parameters = saved
      try store.save(
        .init(
          settingsByPath: [input.standardizedFileURL.path: saved],
          editedPaths: [input.standardizedFileURL.path]))
    }

    @MainActor
    func model(decoder: DiscardSessionDecoder) -> AppModel {
      let model = AppModel(
        profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
        settingsStore: store, preferences: preferences)
      model.rawPreviewSessionDecoder = decoder.decode
      return model
    }

    func cleanUp() {
      preferences.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private final class DiscardSessionDecoder: @unchecked Sendable {
  private struct Owners {
    weak var full: CPUPreviewPreparationCache?
    weak var continuous: CPUPreviewPreparationCache?
  }

  let source: UInt16Image
  private let lock = NSLock()
  private var owners = Owners()

  init(flat: Bool) {
    source =
      flat
      ? UInt16Image(
        width: 128, height: 96, channels: 3,
        pixels: [UInt16](repeating: 32_768, count: 128 * 96 * 3))
      : CPUPreparationPerformanceTests.image(width: 128, height: 96)
  }

  var fullPreparation: CPUPreviewPreparationCache? { lock.withLock { owners.full } }
  var continuousPreparation: CPUPreviewPreparationCache? { lock.withLock { owners.continuous } }

  func decode(_: URL, _: PreviewSourceKind) throws -> CachedPreviewSession {
    let proxy = source.resizedToFit(maxDimension: 64)
    let session = CachedPreviewSession(
      sourceKind: .rawFull, displaySource: source, analysisSource: source,
      previewRenderer: try #require(StillPreviewRenderer(image: source, analysisImage: source)),
      continuousEditSource: proxy,
      continuousEditRenderer: try #require(
        StillPreviewRenderer(image: proxy, analysisImage: source)),
      sourcePixelDimensions: .init(width: source.width, height: source.height))
    lock.withLock {
      owners = Owners(
        full: session.cpuPreviewPreparation, continuous: session.continuousEditCPUPreparation)
    }
    return session
  }
}
