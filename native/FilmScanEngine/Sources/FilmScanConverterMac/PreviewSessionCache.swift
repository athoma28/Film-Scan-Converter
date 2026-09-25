import CoreGraphics
import FilmScanEngine
import FilmScanPreviewRenderer

/// Owns each decoded session and its last complete corrected raster together.
/// Speculation cannot evict visited sessions; foreground work preserves the selection.
struct PreviewSessionCache {
  struct Limits {
    let count: Int
    let bytes: Int
    let additionalReservedBytes: Int
  }

  private struct Entry {
    let session: CachedPreviewSession
    let sourceByteCount: Int
    var rendered: CachedRenderedPreview?

    var physicalByteCount: Int { sourceByteCount + (rendered?.byteCount ?? 0) }
    var reservedByteCount: Int {
      sourceByteCount + max(session.displayByteReservation, rendered?.byteCount ?? 0)
    }
  }

  private var entries: [String: Entry] = [:]
  private var order: [String] = []

  var count: Int { entries.count }
  var physicalByteCount: Int { entries.values.reduce(0) { $0 + $1.physicalByteCount } }
  private var reservedByteCount: Int { entries.values.reduce(0) { $0 + $1.reservedByteCount } }

  subscript(key: String) -> CachedPreviewSession? { entries[key]?.session }

  func renderedPreview(forKey key: String) -> CachedRenderedPreview? { entries[key]?.rendered }

  /// A nil estimate checks for any remaining capacity before a bounded decode.
  /// Actual source and bitmap sizes are checked again when admitting its result.
  func canAdmitSession(
    forKey key: String, estimatedByteCount: Int? = nil, limits: Limits
  ) -> Bool {
    let previous = entries[key]
    guard count + (previous == nil ? 1 : 0) <= limits.count else { return false }
    let retainedBytes =
      reservedByteCount - (previous?.reservedByteCount ?? 0) + limits.additionalReservedBytes
    if let estimatedByteCount { return retainedBytes + estimatedByteCount <= limits.bytes }
    return retainedBytes < limits.bytes
  }

  mutating func insert(
    _ session: CachedPreviewSession, forKey key: String, limits: Limits,
    preserving selectedKey: String?, allowDowngrade: Bool = false, speculative: Bool = false
  ) {
    if !allowDowngrade, let previous = entries[key],
      previous.session.sourceKind.qualityRank > session.sourceKind.qualityRank
    {
      return
    }
    let entry = Entry(session: session, sourceByteCount: session.byteCount)
    if speculative,
      !canAdmitSession(forKey: key, estimatedByteCount: entry.reservedByteCount, limits: limits)
    {
      return
    }
    // Replacing the source also invalidates its old renderer's corrected raster.
    entries[key] = entry
    order.removeAll { $0 == key }
    if speculative {
      order.insert(key, at: 0)
    } else {
      order.append(key)
    }
    trim(to: limits, preserving: selectedKey)
  }

  mutating func storeRenderedPreview(
    _ preview: CachedRenderedPreview, forKey key: String, limits: Limits,
    preserving selectedKey: String?
  ) {
    guard entries[key]?.session.previewRenderer === preview.renderer else { return }
    entries[key]?.rendered = preview
    trim(to: limits, preserving: selectedKey)
  }

  mutating func invalidateRenderedPreviews() {
    for key in entries.keys { entries[key]?.rendered = nil }
  }

  mutating func remove(forKey key: String) {
    entries.removeValue(forKey: key)
    order.removeAll { $0 == key }
  }

  mutating func removeAll(except selectedKey: String?) {
    for key in order where key != selectedKey { remove(forKey: key) }
  }

  mutating func touch(_ key: String) {
    guard entries[key] != nil else { return }
    order.removeAll { $0 == key }
    order.append(key)
  }

  mutating func trim(to limits: Limits, preserving selectedKey: String?) {
    while count > limits.count || reservedByteCount + limits.additionalReservedBytes > limits.bytes
    {
      guard let evicted = order.first(where: { $0 != selectedKey }) else { break }
      remove(forKey: evicted)
    }
  }
}

enum PreviewSourceKind: String, Sendable {
  case embeddedRAW
  case rawDraft
  case standardThumbnail
  case rawDetail
  case rawInspect
  case rawFull
  case alignedStack

  var qualityRank: Int {
    switch self {
    case .embeddedRAW: 0
    case .rawDraft, .standardThumbnail: 1
    case .rawDetail: 2
    case .rawInspect: 3
    case .rawFull: 4
    case .alignedStack: 5
    }
  }
}

struct CachedPreviewSession: Sendable {
  let sourceKind: PreviewSourceKind
  let displaySource: UInt16Image
  let analysisSource: UInt16Image
  let previewRenderer: StillPreviewRenderer
  let continuousEditSource: UInt16Image?
  let continuousEditRenderer: StillPreviewRenderer?
  let sourcePixelDimensions: PixelDimensions?

  init(
    sourceKind: PreviewSourceKind,
    displaySource: UInt16Image,
    analysisSource: UInt16Image,
    previewRenderer: StillPreviewRenderer,
    continuousEditSource: UInt16Image? = nil,
    continuousEditRenderer: StillPreviewRenderer? = nil,
    sourcePixelDimensions: PixelDimensions?
  ) {
    self.sourceKind = sourceKind
    self.displaySource = displaySource
    self.analysisSource = analysisSource
    self.previewRenderer = previewRenderer
    self.continuousEditSource = continuousEditSource
    self.continuousEditRenderer = continuousEditRenderer
    self.sourcePixelDimensions = sourcePixelDimensions
  }

  var displayByteReservation: Int { displaySource.width * displaySource.height * 4 }

  var byteCount: Int {
    let sharesAnalysisStorage = displaySource.pixels.withUnsafeBufferPointer { display in
      analysisSource.pixels.withUnsafeBufferPointer { analysis in
        display.baseAddress == analysis.baseAddress
      }
    }
    let analysisCount = sharesAnalysisStorage ? 0 : analysisSource.pixels.count
    let continuousEditCount = continuousEditSource?.pixels.count ?? 0
    let continuousEditRendererBytes = continuousEditRenderer?.retainedRGBAByteCount ?? 0
    return (displaySource.pixels.count + analysisCount + continuousEditCount)
      * MemoryLayout<UInt16>.stride
      + previewRenderer.retainedRGBAByteCount + continuousEditRendererBytes
  }
}

struct CachedRenderedPreview {
  let renderer: StillPreviewRenderer
  let parameters: ProcessingParameters
  let showOriginal: Bool
  let result: RenderedPreview
  var byteCount: Int { result.cgImage.bytesPerRow * result.cgImage.height }
}

struct RenderedPreview: Sendable {
  let cgImage: CGImage
  let rendererName: String
  let detail: CGImage?
  let statistics: RenderedPreviewStatistics
}
