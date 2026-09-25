import FilmScanEngine
import FilmScanPreviewRenderer
import Testing

@testable import FilmScanConverterMac

@Suite("Preview session ownership and admission")
struct PreviewSessionCacheTests {
  @Test("Speculation reserves display space without evicting completed sessions")
  func speculativeAdmission() throws {
    let session = try makeSession()
    let reserved = session.byteCount + session.displayByteReservation
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
