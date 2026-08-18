import AppKit
import CoreGraphics
import SwiftUI

/// Builds and displays a single raster snapshot.
///
/// SwiftUI's `Image(nsImage:)` draws every `NSImage` representation. AppKit can
/// cache extra scale variants while the window lays out, which shows the same
/// scan as a stack of overlapping copies. Pinning one bitmap and rendering it
/// through `Image(decorative:scale:)` keeps preview, thumbnail, and loupe
/// drawing on one image.
enum PreviewBitmap {
  static func nsImage(from cgImage: CGImage) -> NSImage {
    let size = NSSize(width: cgImage.width, height: cgImage.height)
    let image = NSImage(size: size)
    image.cacheMode = .never
    image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
    return image
  }

  static func cgImage(from image: NSImage) -> CGImage? {
    if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
      return bitmap.cgImage
    }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }
}

struct RasterImage: View {
  let image: NSImage
  var interpolation: Image.Interpolation = .medium

  var body: some View {
    if let cgImage = PreviewBitmap.cgImage(from: image) {
      Image(decorative: cgImage, scale: 1)
        .resizable()
        .interpolation(interpolation)
    }
  }
}
