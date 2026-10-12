import FilmScanPreviewRenderer
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Preview session ownership and admission")
struct PreviewSessionCacheTests {
  @Test("Speculation reserves display space without evicting completed sessions")
  func speculativeAdmission() throws {
    let session = try makeSession()
    let reserved = session.reservedByteCount + session.displayByteReservation
    let limits = PreviewSessionCache.Limits(
      count: 2, bytes: reserved * 2, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(session, forKey: "selected", limits: limits, preserving: "selected")
    cache.insert(
      session, forKey: "neighbour", limits: limits, preserving: "selected", speculative: true)
    #expect(cache.count == 2)
    #expect(cache.physicalByteCount == session.byteCount * 2)
    #expect(!cache.canAdmitSession(forKey: "third", limits: limits))
    cache.insert(
      session, forKey: "third", limits: limits, preserving: "selected", speculative: true)
    #expect(cache["selected"] != nil && cache["neighbour"] != nil && cache["third"] == nil)

    var tooSmall = PreviewSessionCache()
    let tight = PreviewSessionCache.Limits(
      count: 2, bytes: reserved - 1, additionalReservedBytes: 0)
    // Predecode admission can only check that some space remains. The completed
    // session must be rejected when its source plus reserved raster cannot fit.
    #expect(tooSmall.canAdmitSession(forKey: "new", limits: tight))
    tooSmall.insert(session, forKey: "new", limits: tight, preserving: nil, speculative: true)
    #expect(tooSmall.count == 0)
    #expect(tooSmall.physicalByteCount == 0)
  }

  @Test("Lazy full and proxy backing update actual bytes without changing admission")
  func lazyBackingAccounting() throws {
    let source = UInt16Image(
      width: 9, height: 7, channels: 3, pixels: .init(repeating: 12_000, count: 189))
    let proxy = source.resizedToFit(maxDimension: 4)
    let renderer = try #require(StillPreviewRenderer(image: source))
    let proxyRenderer = try #require(StillPreviewRenderer(image: proxy, analysisImage: source))
    let session = CachedPreviewSession(
      sourceKind: .rawFull, displaySource: source, analysisSource: source,
      previewRenderer: renderer, continuousEditSource: proxy,
      continuousEditRenderer: proxyRenderer,
      sourcePixelDimensions: .init(width: source.width, height: source.height))
    let sourceBytes = (source.pixels.count + proxy.pixels.count) * MemoryLayout<UInt16>.stride
    let backingReservation =
      renderer.maximumRetainedRGBAByteCount + proxyRenderer.maximumRetainedRGBAByteCount
    let reserved = session.reservedByteCount + session.displayByteReservation
    #expect(session.byteCount == sourceBytes)
    #expect(session.reservedByteCount == sourceBytes + backingReservation)
    let limits = PreviewSessionCache.Limits(count: 3, bytes: reserved, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(session, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache.physicalByteCount == sourceBytes)
    #expect(!cache.canAdmitSession(forKey: "neighbour", limits: limits))

    let parameters = ProcessingParameters(filmType: .cropOnly)
    let bitmap = try #require(renderer.render(parameters: parameters, showOriginal: true))
    #expect(cache.physicalByteCount == sourceBytes + renderer.maximumRetainedRGBAByteCount)
    #expect(session.reservedByteCount == sourceBytes + backingReservation)
    _ = try #require(proxyRenderer.render(parameters: parameters, showOriginal: true))
    #expect(cache.physicalByteCount == sourceBytes + backingReservation)
    #expect(!cache.canAdmitSession(forKey: "neighbour", limits: limits))
    let corrected = CachedRenderedPreview(
      renderer: renderer, parameters: parameters, showOriginal: true,
      result: RenderedPreview(
        cgImage: bitmap, rendererName: "test", detail: nil,
        statistics: RenderedPreviewStatistics { .empty }))
    cache.storeRenderedPreview(corrected, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache.renderedPreview(forKey: "scan")?.renderer === renderer)
    #expect(cache.physicalByteCount == session.byteCount + corrected.byteCount)
    cache.removeAll(except: nil)
    #expect(cache.count == 0 && cache.physicalByteCount == 0)
  }

  @Test("Full and proxy CPU preparation retain geometry and charge changing buffers exactly")
  func retainedCPUPreparationAccounting() throws {
    let source = UInt16Image(
      width: 96, height: 72, channels: 3,
      pixels: .init(repeating: 24_000, count: 96 * 72 * 3))
    let proxy = source.resizedToFit(maxDimension: 24)
    let analysis = source.resizedToFit(maxDimension: 16)
    let fullPreparation = CPUPreviewPreparationCache(image: source)
    let proxyPreparation = CPUPreviewPreparationCache(image: proxy, analysisImage: analysis)
    let session = CachedPreviewSession(
      sourceKind: .rawFull, displaySource: source, analysisSource: analysis,
      previewRenderer: try #require(StillPreviewRenderer(image: source)),
      cpuPreviewPreparation: fullPreparation, continuousEditSource: proxy,
      continuousEditRenderer: try #require(StillPreviewRenderer(image: proxy)),
      continuousEditCPUPreparation: proxyPreparation,
      sourcePixelDimensions: .init(width: source.width, height: source.height))
    let limits = PreviewSessionCache.Limits(count: 2, bytes: .max, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(session, forKey: "scan", limits: limits, preserving: "scan")
    let initialPhysical = cache.physicalByteCount
    let initialReserved = cache.reservedByteCount
    var parameters = ProcessingParameters(
      straightenAngle: 4, filmType: .slide, photoAdjustments: .init())
    #expect(
      fullPreparation.render(parameters: parameters)
        == FilmProcessing.correctedPreview(image: source, parameters: parameters))
    let fullGeometryBytes = fullPreparation.retainedGeometryByteCount
    #expect(fullGeometryBytes > 0)
    #expect(cache.physicalByteCount == initialPhysical + fullGeometryBytes)
    #expect(cache.reservedByteCount == initialReserved + fullGeometryBytes)

    // Retrieving a visited session keeps its prepared geometry useful for the
    // next point edit; source storage remains owned only once by the session.
    let restored = try #require(cache["scan"])
    #expect(restored.cpuPreviewPreparation === fullPreparation)
    #expect(restored.continuousEditCPUPreparation === proxyPreparation)
    parameters.photoAdjustments.exposureEV = 0.25
    #expect(
      restored.cpuPreviewPreparation.render(parameters: parameters)
        == FilmProcessing.correctedPreview(image: source, parameters: parameters))
    #expect(fullPreparation.geometryBuildCount == 1)
    #expect(fullPreparation.retainedGeometryByteCount == fullGeometryBytes)

    _ = try #require(
      proxyPreparation.renderViewport(
        parameters: parameters, region: .init(x: 2, y: 2, width: 8, height: 6),
        overviewMaximumDimension: 8))
    let proxyGeometryBytes = proxyPreparation.retainedGeometryByteCount
    #expect(proxyGeometryBytes > 0)
    #expect(cache.physicalByteCount == initialPhysical + fullGeometryBytes + proxyGeometryBytes)
    #expect(cache.reservedByteCount == initialReserved + fullGeometryBytes + proxyGeometryBytes)

    // Returning to source geometry releases the allocated full warp; its
    // prepared no-op shares the original source and carries no extra bytes.
    parameters.straightenAngle = 0
    _ = fullPreparation.render(parameters: parameters)
    #expect(fullPreparation.retainedGeometryByteCount == 0)
    #expect(cache.physicalByteCount == initialPhysical + proxyGeometryBytes)
    #expect(cache.reservedByteCount == initialReserved + proxyGeometryBytes)
  }

  @Test("Growing an unselected CPU preparation reduces admission and permits bounded eviction")
  func retainedCPUGrowthEvictsUnselectedSession() throws {
    let first = try makeSession()
    let second = try makeSession()
    let limits = PreviewSessionCache.Limits(
      count: 3,
      bytes: first.reservedByteCount + first.displayByteReservation
        + second.reservedByteCount + second.displayByteReservation,
      additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(first, forKey: "first", limits: limits, preserving: "first")
    cache.insert(second, forKey: "selected", limits: limits, preserving: "selected")
    #expect(cache.count == 2)
    _ = first.cpuPreviewPreparation.render(
      parameters: .init(rotation: 1, filmType: .slide, photoAdjustments: .init()))
    #expect(first.cpuPreviewPreparation.retainedGeometryByteCount > 0)
    #expect(cache.reservedByteCount > limits.bytes)
    #expect(!cache.canAdmitSession(forKey: "third", limits: limits))
    cache.insert(
      try makeSession(), forKey: "third", limits: limits, preserving: "selected", speculative: true)
    #expect(cache["first"] != nil && cache["selected"] != nil && cache["third"] == nil)

    cache.trim(to: limits, preserving: "selected")
    #expect(cache["first"] == nil && cache["selected"] != nil)
    #expect(cache.count == 1)
    #expect(cache.physicalByteCount == second.byteCount)
    #expect(cache.reservedByteCount <= limits.bytes)
    cache.removeAll(except: nil)
    #expect(cache.count == 0 && cache.physicalByteCount == 0 && cache.reservedByteCount == 0)
  }

  @Test("Late geometry growth belongs to a replaced owner and cannot charge its replacement")
  func replacedCPUPreparationRemainsDetached() throws {
    var previous: CachedPreviewSession? = try makeSession(kind: .rawDraft)
    weak var previousOwner = previous?.cpuPreviewPreparation
    var workerOwner = previous?.cpuPreviewPreparation
    let replacement = try makeSession(kind: .rawFull)
    let limits = PreviewSessionCache.Limits(count: 2, bytes: .max, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    if let previous { cache.insert(previous, forKey: "scan", limits: limits, preserving: "scan") }
    previous = nil
    cache.insert(replacement, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache["scan"]?.cpuPreviewPreparation === replacement.cpuPreviewPreparation)
    #expect(previousOwner != nil)
    let currentBytes = cache.physicalByteCount
    let currentReserved = cache.reservedByteCount

    // An in-flight request may finish after replacement. Its buffers remain
    // attached to that request's owner, never the new source's cache entry.
    _ = workerOwner?.render(
      parameters: .init(rotation: 1, filmType: .slide, photoAdjustments: .init()))
    #expect(workerOwner?.retainedGeometryByteCount ?? 0 > 0)
    #expect(cache.physicalByteCount == currentBytes)
    #expect(cache.reservedByteCount == currentReserved)
    #expect(replacement.cpuPreviewPreparation.geometryBuildCount == 0)
    workerOwner = nil
    #expect(previousOwner == nil)
  }

  @Test("A shared full and proxy CPU preparation charges its geometry once")
  func sharedCPUPreparationStorage() throws {
    let source = UInt16Image(
      width: 9, height: 7, channels: 3, pixels: .init(repeating: 12_000, count: 189))
    let preparation = CPUPreviewPreparationCache(image: source)
    let session = CachedPreviewSession(
      sourceKind: .rawFull, displaySource: source, analysisSource: source,
      previewRenderer: try #require(StillPreviewRenderer(image: source)),
      cpuPreviewPreparation: preparation, continuousEditSource: source,
      continuousEditCPUPreparation: preparation,
      sourcePixelDimensions: .init(width: source.width, height: source.height))
    let initialPhysical = session.byteCount
    let initialReserved = session.reservedByteCount
    _ = preparation.render(
      parameters: .init(rotation: 1, filmType: .slide, photoAdjustments: .init()))
    let geometryBytes = preparation.retainedGeometryByteCount
    #expect(geometryBytes > 0)
    #expect(session.byteCount == initialPhysical + geometryBytes)
    #expect(session.reservedByteCount == initialReserved + geometryBytes)
  }

  @Test("Foreground admission evicts the least recently used unselected session")
  func leastRecentlyUsedAndMemoryPressure() throws {
    let session = try makeSession()
    let limits = PreviewSessionCache.Limits(count: 2, bytes: .max, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(session, forKey: "a", limits: limits, preserving: "a")
    cache.insert(session, forKey: "b", limits: limits, preserving: "b")
    cache.touch("a")
    cache.insert(session, forKey: "c", limits: limits, preserving: "c")
    #expect(cache["a"] != nil && cache["b"] == nil && cache["c"] != nil)

    cache.trim(to: .init(count: 2, bytes: 1, additionalReservedBytes: 0), preserving: "a")
    #expect(cache.count == 1 && cache["a"] != nil)
    #expect(cache.physicalByteCount == session.byteCount)
    cache.removeAll(except: nil)
    #expect(cache.count == 0 && cache.physicalByteCount == 0)
  }

  @Test("Source upgrades invalidate rasters and reject late results from the old renderer")
  func sourceReplacement() throws {
    let draft = try makeSession(kind: .rawDraft)
    let full = try makeSession(kind: .rawFull)
    let limits = PreviewSessionCache.Limits(count: 2, bytes: .max, additionalReservedBytes: 0)
    var cache = PreviewSessionCache()
    cache.insert(draft, forKey: "scan", limits: limits, preserving: "scan")
    let old = try renderedPreview(for: draft)
    cache.storeRenderedPreview(old, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache.physicalByteCount == draft.byteCount + old.byteCount)

    cache.insert(full, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache.renderedPreview(forKey: "scan") == nil)
    #expect(cache.physicalByteCount == full.byteCount)
    cache.storeRenderedPreview(old, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache.renderedPreview(forKey: "scan") == nil)
    cache.insert(draft, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache["scan"]?.sourceKind == .rawFull)

    let current = try renderedPreview(for: full)
    cache.storeRenderedPreview(current, forKey: "scan", limits: limits, preserving: "scan")
    #expect(cache.renderedPreview(forKey: "scan")?.renderer === full.previewRenderer)
    cache.invalidateRenderedPreviews()
    #expect(cache["scan"]?.sourceKind == .rawFull)
    #expect(cache.renderedPreview(forKey: "scan") == nil)
    #expect(cache.physicalByteCount == full.byteCount)
    cache.remove(forKey: "scan")
    cache.storeRenderedPreview(current, forKey: "scan", limits: limits, preserving: nil)
    #expect(cache.count == 0 && cache.physicalByteCount == 0)
  }

  private func makeSession(kind: PreviewSourceKind = .standardThumbnail) throws
    -> CachedPreviewSession
  {
    let source = UInt16Image(
      width: 9, height: 7, channels: 3, pixels: .init(repeating: 12_000, count: 189))
    return CachedPreviewSession(
      sourceKind: kind, displaySource: source, analysisSource: source,
      previewRenderer: try #require(StillPreviewRenderer(image: source)),
      sourcePixelDimensions: .init(width: source.width, height: source.height))
  }

  private func renderedPreview(for session: CachedPreviewSession) throws -> CachedRenderedPreview {
    let bitmap = try #require(session.displaySource.makePreviewCGImage())
    return CachedRenderedPreview(
      renderer: session.previewRenderer, parameters: .init(), showOriginal: false,
      result: RenderedPreview(
        cgImage: bitmap, rendererName: "test", detail: nil,
        statistics: RenderedPreviewStatistics { .empty }))
  }
}
