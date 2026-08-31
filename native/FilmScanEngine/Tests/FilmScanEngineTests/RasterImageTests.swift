import AppKit
import CoreGraphics
import FilmScanEngine
import SwiftUI
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

  @Test("Simple invert complements an 8-bit preview bitmap")
  func invertedNSImageComplementsChannels() throws {
    var pixels = [UInt16](repeating: 0, count: 4 * 2 * 3)
    for y in 0..<2 {
      for x in 2..<4 {
        let base = (y * 4 + x) * 3
        pixels[base] = .max
        pixels[base + 1] = .max
        pixels[base + 2] = .max
      }
    }
    let source = UInt16Image(width: 4, height: 2, channels: 3, pixels: pixels)
    let cgImage = try #require(source.makePreviewCGImage())
    let inverted = try #require(PreviewBitmap.invertedNSImage(from: cgImage))
    let representation = try #require(inverted.representations.first as? NSBitmapImageRep)
    let left = try #require(representation.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
    let right = try #require(representation.colorAt(x: 3, y: 0)?.usingColorSpace(.deviceRGB))
    #expect(left.redComponent + left.greenComponent + left.blueComponent > 2.3)
    #expect(right.redComponent + right.greenComponent + right.blueComponent < 0.6)
  }

  @Test("Sidebar row draws the inverted thumbnail brighter than the source")
  @MainActor
  func sidebarRowDrawsInvertedThumbnail() throws {
    let black = UInt16Image(
      width: 32,
      height: 24,
      channels: 3,
      pixels: [UInt16](repeating: 0, count: 32 * 24 * 3)
    )
    let cgImage = try #require(black.makePreviewCGImage())
    let thumbnail = try #require(PreviewBitmap.invertedNSImage(from: cgImage))
    let row = ScanSidebarRow(
      url: URL(fileURLWithPath: "/tmp/scan.raf"),
      thumbnail: thumbnail,
      isThumbnailLoading: false,
      isCurrentLoadingOrRendering: false,
      isActiveExport: false,
      isPendingExport: false,
      hasCachedPreview: false,
      hasEdits: false
    )
    let host = NSHostingView(rootView: row.frame(width: 260, height: 80))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 260, height: 80)
    host.layoutSubtreeIfNeeded()
    let bounds = host.bounds
    let representation = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
    host.cacheDisplay(in: bounds, to: representation)
    let sample = try #require(
      representation.colorAt(x: 24, y: Int(bounds.height / 2))?.usingColorSpace(.deviceRGB)
    )
    #expect(sample.redComponent + sample.greenComponent + sample.blueComponent > 1.5)
  }
}
