import CoreGraphics
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Retained half-size canvas snapshots")
struct RetainedCanvasPreviewCacheTests {
  @Test("Half-size bitmap preserves complete-canvas geometry and latest settings")
  func dimensionsAndMetadata() throws {
    let parameters = ProcessingParameters(
      flip: true, rotation: 1, filmType: .slide, temperature: 13, saturation: 114)
    let logical = PixelDimensions(width: 9000, height: 7000)
    let sensor = PixelDimensions(width: 7728, height: 5152)
    let source = try bitmap(width: 9, height: 7)
    let preview = try #require(
      RetainedCanvasPreview.make(
        cgImage: source, parameters: parameters, logicalDimensions: logical,
        sourcePixelDimensions: sensor))
    #expect(preview.cgImage.width == 4 && preview.cgImage.height == 3)
    #expect(preview.logicalDimensions == logical)
    #expect(preview.sourcePixelDimensions == sensor)
    #expect(preview.parameters == parameters)
    #expect(preview.byteCount == preview.cgImage.bytesPerRow * 3)

    let narrow = try snapshot(width: 1, height: 5)
    #expect(narrow.cgImage.width == 1 && narrow.cgImage.height == 2)
    #expect(narrow.sourcePixelDimensions == nil)
    let single = try snapshot(width: 1, height: 1)
    #expect(single.cgImage.width == 1 && single.cgImage.height == 1)
  }

  @Test("Downsampling keeps sRGB channel order and canvas orientation")
  func orientationAndColor() throws {
    let width = 32
    let height = 24
    let quadrants: [[UInt8]] = [
      [231, 37, 19, 255], [29, 207, 63, 255],
      [47, 71, 229, 255], [183, 143, 97, 255],
    ]
    let pixels = (0..<height).flatMap { y in
      (0..<width).flatMap { x in quadrants[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)] }
    }
    let source = try bitmap(width: width, height: height, pixels: pixels)
    let preview = try #require(
      RetainedCanvasPreview.make(
        cgImage: source, parameters: .init(),
        logicalDimensions: .init(width: width, height: height), sourcePixelDimensions: nil))
    let image = preview.cgImage
    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    #expect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    let output = try rgbaPixels(image)
    for (index, point) in [(2, 2), (13, 2), (2, 9), (13, 9)].enumerated() {
      let offset = (point.1 * image.width + point.0) * 4
      for channel in 0..<4 {
        #expect(abs(Int(output[offset + channel]) - Int(quadrants[index][channel])) <= 1)
      }
    }
  }

  @Test("Snapshots release the original bitmap's source provider")
  func sourceStorageIsIndependent() throws {
    weak var originalStorage: BitmapStorage?
    let preview = try autoreleasepool {
      let storage = BitmapStorage(count: 16 * 12 * 4)
      originalStorage = storage
      let sourceProvider = CGDataProvider(
        dataInfo: Unmanaged.passRetained(storage).toOpaque(), data: storage.bytes,
        size: storage.count,
        releaseData: { info, _, _ in
          if let info { Unmanaged<BitmapStorage>.fromOpaque(info).release() }
        })
      let provider = try #require(sourceProvider)
      let source = try bitmap(width: 16, height: 12, provider: provider)
      return try #require(
        RetainedCanvasPreview.make(
          cgImage: source, parameters: .init(),
          logicalDimensions: .init(width: 16, height: 12), sourcePixelDimensions: nil))
    }
    #expect(originalStorage == nil)
    #expect(try rgbaPixels(preview.cgImage).allSatisfy { $0 == 255 })
  }

  @Test("Count and bitmap-byte limits evict the least recently used canvas")
  func boundedLRU() throws {
    let preview = try snapshot(width: 24, height: 16)
    var cache = RetainedCanvasPreviewCache()
    let two = RetainedCanvasPreviewCache.Limits(count: 2, bytes: .max)
    cache.insert(preview, forKey: "a", limits: two)
    cache.insert(preview, forKey: "b", limits: two)
    cache.touch("a")
    cache.touch("missing")
    cache.insert(preview, forKey: "c", limits: two)
    #expect(cache.count == 2 && cache.physicalByteCount == 2 * preview.byteCount)
    #expect(cache["a"] != nil && cache["b"] == nil && cache["c"] != nil)

    let byteLimit = RetainedCanvasPreviewCache.Limits(count: 20, bytes: 2 * preview.byteCount)
    cache.insert(preview, forKey: "d", limits: byteLimit)
    #expect(cache["a"] == nil && cache["c"] != nil && cache["d"] != nil)
    cache.trim(to: .init(count: 20, bytes: preview.byteCount))
    #expect(cache.count == 1 && cache["d"] != nil)
    #expect(cache.physicalByteCount == preview.byteCount)
    cache.remove(forKey: "d")
    cache.remove(forKey: "missing")
    #expect(cache.count == 0 && cache.physicalByteCount == 0)
  }

  @Test("Replacement, oversized admission and clearing retain accurate accounting")
  func replacementAndRemoval() throws {
    let small = try snapshot(width: 24, height: 16)
    let large = try snapshot(width: 48, height: 32)
    let limits = RetainedCanvasPreviewCache.Limits(count: 4, bytes: 2 * large.byteCount)
    var cache = RetainedCanvasPreviewCache()
    cache.insert(small, forKey: "a", limits: limits)
    cache.insert(small, forKey: "b", limits: limits)
    cache.insert(large, forKey: "a", limits: limits)
    #expect(cache.count == 2 && cache.physicalByteCount == small.byteCount + large.byteCount)
    #expect(cache["a"]?.cgImage.width == large.cgImage.width)

    // A newly oversized edit invalidates only its old snapshot, without evicting
    // another usable canvas in a failed attempt to admit it.
    let admittedOversized = cache.insert(
      large, forKey: "a", limits: .init(count: 4, bytes: small.byteCount))
    #expect(!admittedOversized)
    #expect(cache.count == 1 && cache["b"] != nil && cache["a"] == nil)
    #expect(cache.physicalByteCount == small.byteCount)
    let admittedWhenDisabled = cache.insert(
      small, forKey: "c", limits: .init(count: 0, bytes: .max))
    #expect(!admittedWhenDisabled)
    cache.removeAll()
    #expect(cache.count == 0 && cache.physicalByteCount == 0)
    cache.insert(small, forKey: "new", limits: limits)
    #expect(cache.count == 1 && cache.physicalByteCount == small.byteCount)
    cache.trim(to: .init(count: 0, bytes: 0))
    #expect(cache.count == 0 && cache.physicalByteCount == 0)
  }

  private func snapshot(width: Int, height: Int) throws -> RetainedCanvasPreview {
    try #require(
      RetainedCanvasPreview.make(
        cgImage: bitmap(width: width, height: height), parameters: .init(),
        logicalDimensions: .init(width: width, height: height), sourcePixelDimensions: nil))
  }

  private func bitmap(width: Int, height: Int, pixels: [UInt8]? = nil) throws -> CGImage {
    let values = pixels ?? Array(repeating: UInt8(255), count: width * height * 4)
    let provider = try #require(CGDataProvider(data: Data(values) as CFData))
    return try bitmap(width: width, height: height, provider: provider)
  }

  private func bitmap(width: Int, height: Int, provider: CGDataProvider) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(
      CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: .byteOrder32Big.union(
          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
  }

  private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(data))
    return (0..<image.height).flatMap { row in
      Array(UnsafeBufferPointer(start: bytes + row * image.bytesPerRow, count: image.width * 4))
    }
  }

  private final class BitmapStorage {
    let bytes: UnsafeMutableRawPointer
    let count: Int

    init(count: Int) {
      self.count = count
      bytes = .allocate(byteCount: count, alignment: 16)
      bytes.initializeMemory(as: UInt8.self, repeating: 255, count: count)
    }

    deinit { bytes.deallocate() }
  }
}
