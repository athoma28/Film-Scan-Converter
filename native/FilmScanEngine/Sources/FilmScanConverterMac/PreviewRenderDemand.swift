import AppKit

/// Logical document coordinates stay stable as backing rasters change size.
/// At inspection zoom a small overview covers the canvas while a native-pixel
/// region covers the viewport, including a short overscan margin for panning.
struct PreviewRenderDemand: Equatable, Sendable {
  let documentSize: CGSize
  let overviewMaximumDimension: Int
  let detailRect: CGRect?

  init(documentSize: CGSize, visibleRect: CGRect, backingScale: CGFloat, magnification: CGFloat) {
    self.documentSize = documentSize
    let bounds = CGRect(origin: .zero, size: documentSize)
    let visible = visibleRect.intersection(bounds)
    let scale = max(0.01, min(8, backingScale * magnification))
    let longest = max(documentSize.width, documentSize.height)
    let needsDetail =
      !visible.isNull && !visible.isEmpty
      && (visible.width < documentSize.width * 0.9 || visible.height < documentSize.height * 0.9)
    overviewMaximumDimension =
      needsDetail ? 1_024 : max(1, min(8_192, Int(ceil(longest * min(scale, 1)))))
    if needsDetail {
      // Align to a 64-pixel grid to avoid new work for every tiny pan event.
      let expanded = visible.insetBy(dx: -64, dy: -64)
      let aligned = CGRect(
        x: floor(expanded.minX / 64) * 64, y: floor(expanded.minY / 64) * 64,
        width: ceil(expanded.maxX / 64) * 64 - floor(expanded.minX / 64) * 64,
        height: ceil(expanded.maxY / 64) * 64 - floor(expanded.minY / 64) * 64)
      detailRect = aligned.intersection(bounds)
    } else {
      detailRect = nil
    }
  }

  var normalizedDetailRect: CGRect? {
    guard let detailRect, documentSize.width > 0, documentSize.height > 0 else { return nil }
    return CGRect(
      x: detailRect.minX / documentSize.width, y: detailRect.minY / documentSize.height,
      width: detailRect.width / documentSize.width, height: detailRect.height / documentSize.height)
  }
}

struct PreviewDetail {
  let image: NSImage
  let rect: CGRect
}
