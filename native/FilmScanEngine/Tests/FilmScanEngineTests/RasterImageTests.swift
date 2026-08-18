import AppKit
import CoreGraphics
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Preview bitmap rendering")
struct RasterImageTests {
  @Test("Preview bitmaps keep one uncached representation at pixel size")
  func previewBitmapHasOneUncachedRepresentation() throws {
    let source = UInt16Image(
      width: 12,
      height: 8,
      channels: 3,
      pixels: [UInt16](repeating: 32_768, count: 12 * 8 * 3)
    )
    let cgImage = try #require(source.makePreviewCGImage())
    let image = PreviewBitmap.nsImage(from: cgImage)

    #expect(image.representations.count == 1)
    #expect(image.cacheMode == .never)
    #expect(image.size == NSSize(width: 12, height: 8))
    #expect(PreviewBitmap.cgImage(from: image) != nil)
    #expect(image.representations.first is NSBitmapImageRep)
  }

  @Test("Asking for a CGImage does not cache extra representations")
  func cgImageLookupDoesNotCacheExtraRepresentations() throws {
    let source = UInt16Image(
      width: 6,
      height: 4,
      channels: 3,
      pixels: [UInt16](repeating: 40_000, count: 6 * 4 * 3)
    )
    let image = PreviewBitmap.nsImage(from: try #require(source.makePreviewCGImage()))
    #expect(PreviewBitmap.cgImage(from: image) != nil)
    #expect(PreviewBitmap.cgImage(from: image) != nil)
    #expect(image.representations.count == 1)
  }
}
