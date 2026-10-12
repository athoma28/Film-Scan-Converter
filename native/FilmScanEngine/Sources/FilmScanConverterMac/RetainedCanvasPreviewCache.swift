import CoreGraphics
import FilmScanEngine

/// A display-only snapshot that remains useful after its decoded session is evicted.
/// It owns a small bitmap and value metadata, never a renderer or source buffer.
struct RetainedCanvasPreview: Sendable {
  let cgImage: CGImage
  let parameters: ProcessingParameters
  let logicalDimensions: PixelDimensions
  let sourcePixelDimensions: PixelDimensions?

  var byteCount: Int { cgImage.bytesPerRow * cgImage.height }

  /// Call on a worker with a complete corrected canvas, after transient proxy or
  /// viewport rendering has settled. Core Graphics materializes new sRGB storage
  /// here so a retained snapshot cannot keep the original bitmap provider alive.
  static func make(
    cgImage: CGImage,
    parameters: ProcessingParameters,
    logicalDimensions: PixelDimensions,
    sourcePixelDimensions: PixelDimensions?
  ) -> RetainedCanvasPreview? {
    let width = max(1, cgImage.width / 2)
    let height = max(1, cgImage.height / 2)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.setBlendMode(.copy)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let reduced = context.makeImage() else { return nil }
    return RetainedCanvasPreview(
      cgImage: reduced, parameters: parameters, logicalDimensions: logicalDimensions,
      sourcePixelDimensions: sourcePixelDimensions)
  }
}

/// Independent of the decoded-session cache so dropping RAW buffers need not
/// discard the last complete canvas. The owner serializes access to this value.
struct RetainedCanvasPreviewCache {
  struct Limits {
    let count: Int
    let bytes: Int
  }

  private var entries: [String: RetainedCanvasPreview] = [:]
  private var order: [String] = []
  private(set) var physicalByteCount = 0

  var count: Int { entries.count }

  subscript(key: String) -> RetainedCanvasPreview? { entries[key] }

  /// Oversized snapshots cannot fit this cache and must not evict useful entries.
  /// Removing a previous version still prevents an older edit from being reused.
  @discardableResult
  mutating func insert(
    _ preview: RetainedCanvasPreview, forKey key: String, limits: Limits
  ) -> Bool {
    remove(forKey: key)
    guard limits.count > 0, preview.byteCount <= limits.bytes else { return false }
    entries[key] = preview
    physicalByteCount += preview.byteCount
    order.append(key)
    trim(to: limits)
    return entries[key] != nil
  }

  mutating func touch(_ key: String) {
    guard entries[key] != nil else { return }
    order.removeAll { $0 == key }
    order.append(key)
  }

  mutating func remove(forKey key: String) {
    guard let previous = entries.removeValue(forKey: key) else { return }
    physicalByteCount -= previous.byteCount
    order.removeAll { $0 == key }
  }

  mutating func removeAll() {
    entries.removeAll()
    order.removeAll()
    physicalByteCount = 0
  }

  mutating func trim(to limits: Limits) {
    while count > limits.count || physicalByteCount > limits.bytes {
      guard let key = order.first else { break }
      remove(forKey: key)
    }
  }
}
