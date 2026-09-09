import CoreGraphics
import CoreText
import FilmScanEngine
import Foundation

/// Immutable settings captured when a contact sheet starts, including stack anchors.
struct ContactSheetItem: Sendable {
  let sources: [URL]
  let parameters: ProcessingParameters?
  let stackMode: ScanStackMode

  var filename: String { sources.first?.lastPathComponent ?? "Scan" }
}

enum ContactSheetExport {
  static let previewMaxDimension = 1_000
  static let imagesPerPage = 12
  static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

  enum ExportError: Error, LocalizedError {
    case noImages
    case cannotCreatePDF
    case invalidPDF
    case imageFailed(String, String)

    var errorDescription: String? {
      switch self {
      case .noImages: "Select at least one scan for the contact sheet."
      case .cannotCreatePDF: "The contact sheet PDF could not be created."
      case .invalidPDF: "The contact sheet PDF could not be finalized."
      case .imageFailed(let filename, let reason): "\(filename): \(reason)"
      }
    }
  }

  /// Streams corrected, bounded images into a staged PDF. No final file appears
  /// until every tile succeeds; cancellation and failures remove the staged file.
  static func write(
    items: [ContactSheetItem],
    destinationDirectory: URL,
    weakPrior: FilmType?,
    flatField: UInt16Image?,
    decode: @Sendable (URL) async throws -> UInt16Image,
    progress: @Sendable (Int, String?) async -> Void
  ) async throws -> URL {
    guard !items.isEmpty, items.allSatisfy({ !$0.sources.isEmpty }) else {
      throw ExportError.noImages
    }
    try Task.checkCancellation()
    let staged = destinationDirectory.appendingPathComponent(
      ".fsc-contact-sheet-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: staged) }
    var bounds = pageBounds
    guard let consumer = CGDataConsumer(url: staged as CFURL),
      let context = CGContext(
        consumer: consumer, mediaBox: &bounds,
        [
          kCGPDFContextTitle as String: "Contact Sheet",
          kCGPDFContextCreator as String: "Film Scan Converter",
        ] as CFDictionary)
    else { throw ExportError.cannotCreatePDF }
    var closed = false
    defer { if !closed { context.closePDF() } }
    let pageCount = (items.count + imagesPerPage - 1) / imagesPerPage

    for (index, item) in items.enumerated() {
      try Task.checkCancellation()
      await progress(index, item.filename)
      let rendered: UInt16Image
      do {
        rendered = try await render(
          item: item, weakPrior: weakPrior, flatField: flatField, decode: decode)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ExportError.imageFailed(item.filename, error.localizedDescription)
      }
      try Task.checkCancellation()
      try autoreleasepool {
        if index % imagesPerPage == 0 {
          context.beginPDFPage(nil)
          drawPage(
            context, imageCount: items.count,
            page: index / imagesPerPage + 1, pageCount: pageCount)
        }
        guard let image = rendered.makePreviewCGImage() else {
          throw ExportError.imageFailed(item.filename, "The corrected preview is unavailable.")
        }
        drawTile(context, image: image, item: item, index: index)
        if index % imagesPerPage == imagesPerPage - 1 || index == items.count - 1 {
          context.endPDFPage()
        }
      }
      await progress(index + 1, nil)
    }
    context.closePDF()
    closed = true
    try Task.checkCancellation()
    guard let document = CGPDFDocument(staged as CFURL), document.numberOfPages == pageCount else {
      throw ExportError.invalidPDF
    }
    return try commit(staged, to: destinationDirectory)
  }

  static func render(
    item: ContactSheetItem, weakPrior: FilmType?, flatField: UInt16Image?,
    decode: @Sendable (URL) async throws -> UInt16Image
  ) async throws -> UInt16Image {
    var images: [UInt16Image] = []
    for url in item.sources {
      try Task.checkCancellation()
      images.append(try await decode(url).resizedToFit(maxDimension: previewMaxDimension))
    }
    try Task.checkCancellation()
    guard let first = images.first else { throw ExportError.noImages }
    let source =
      images.count == 1
      ? first : try MultiScanStacker.combine(images: images, mode: item.stackMode).image
    images.removeAll()
    let parameters =
      item.parameters
      ?? AppModel.automaticallyClassifiedParameters(
        base: ProcessingParameters(),
        image: source.resizedToFit(maxDimension: AppModel.analysisPreviewMaxDimension),
        weakPrior: weakPrior)
    let calibrated = AppModel.parametersForExport(parameters, decodedImage: source)
    var field: UInt16Image?
    if let flatField, flatField.channels == source.channels {
      let sourceAspect = Double(source.width) / Double(source.height)
      let fieldAspect = Double(flatField.width) / Double(flatField.height)
      if abs(sourceAspect - fieldAspect) / sourceAspect <= 0.01 {
        field = flatField.resized(width: source.width, height: source.height)
      }
    }
    try Task.checkCancellation()
    let output = FilmProcessing.correctedPreview(
      image: source, parameters: calibrated, flatField: field)
    try Task.checkCancellation()
    return output.resizedToFit(maxDimension: previewMaxDimension)
  }

  /// FileManager moves fail when the destination exists. Recheck case-insensitive
  /// names after a collision, including a file created while this PDF rendered.
  private static func commit(_ staged: URL, to directory: URL) throws -> URL {
    while true {
      try Task.checkCancellation()
      let existing = Set(
        try FileManager.default.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() })
      var suffix = 1
      var name = "Contact Sheet.pdf"
      while existing.contains(name.lowercased()) {
        suffix += 1
        name = "Contact Sheet-\(suffix).pdf"
      }
      let destination = directory.appendingPathComponent(name)
      do {
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
      } catch {
        guard (error as NSError).domain == NSCocoaErrorDomain,
          (error as NSError).code == NSFileWriteFileExistsError
        else { throw error }
      }
    }
  }

  static func imageBounds(at index: Int) -> CGRect {
    let slot = index % imagesPerPage
    let width: CGFloat = (pageBounds.width - 64 - 28) / 3
    let tileHeight: CGFloat = 146.5
    return CGRect(
      x: 32 + CGFloat(slot % 3) * (width + 14),
      y: 696 - CGFloat(slot / 3) * (tileHeight + 18) - (tileHeight - 26),
      width: width, height: tileHeight - 26)
  }

  private static func drawPage(
    _ context: CGContext, imageCount: Int, page: Int, pageCount: Int
  ) {
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(pageBounds)
    drawText("Contact Sheet", in: context, x: 32, y: 744, width: 548, size: 20, bold: true)
    drawText(
      "\(imageCount) scan\(imageCount == 1 ? "" : "s") - Corrected previews",
      in: context, x: 32, y: 724, width: 548, size: 10)
    context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
    context.setLineWidth(0.5)
    context.move(to: CGPoint(x: 32, y: 710))
    context.addLine(to: CGPoint(x: 580, y: 710))
    context.strokePath()
    drawText("Film Scan Converter", in: context, x: 32, y: 28, width: 380, size: 9)
    drawText("Page \(page) of \(pageCount)", in: context, x: 484, y: 28, width: 96, size: 9)
  }

  private static func drawTile(
    _ context: CGContext, image: CGImage, item: ContactSheetItem, index: Int
  ) {
    let box = imageBounds(at: index)
    context.setFillColor(CGColor(gray: 0.96, alpha: 1))
    context.fill(box)
    let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(
        x: box.midX - size.width / 2, y: box.midY - size.height / 2,
        width: size.width, height: size.height))
    drawText(
      "\(index + 1). \(item.filename)", in: context,
      x: box.minX, y: box.minY - 13, width: box.width, size: 9)
    if item.sources.count > 1 {
      drawText(
        "\(item.sources.count) captures - Aligned stack", in: context,
        x: box.minX, y: box.minY - 24, width: box.width, size: 8)
    }
  }

  private static func drawText(
    _ text: String, in context: CGContext, x: CGFloat, y: CGFloat,
    width: CGFloat, size: CGFloat, bold: Bool = false
  ) {
    let attributes: [NSAttributedString.Key: Any] = [
      .init(kCTFontAttributeName as String): CTFontCreateWithName(
        (bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil),
      .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.22, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    let ellipsis = CTLineCreateWithAttributedString(
      NSAttributedString(string: "…", attributes: attributes))
    let fitted = CTLineCreateTruncatedLine(line, Double(width), .middle, ellipsis) ?? line
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(fitted, context)
  }
}
