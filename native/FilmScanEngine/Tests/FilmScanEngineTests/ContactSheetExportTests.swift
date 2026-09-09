import AppKit
import FilmScanEngine
import PDFKit
import Testing

@testable import FilmScanConverterMac

@Suite("Contact sheet export", .serialized)
@MainActor
struct ContactSheetExportTests {
  @Test("Selected sheets preserve import order, snapshot edits, and avoid existing filenames")
  func selectedSheetSnapshotsEdits() async throws {
    let fixture = try Fixture(names: ["03-z.png", "01-a.png", "02-m.png"])
    defer { fixture.remove() }
    let model = try await fixture.model()
    model.setFilmType(.slide)
    model.setExposureEV(-1)
    model.rotateClockwise()
    model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.7, height: 0.6))
    let before = model.parameters
    model.selectedFiles = [fixture.sources[0], fixture.sources[2]]
    model.beginManualCropEditing()
    model.showOriginal = true
    let probe = ContactSheetDecodeProbe()
    model.contactSheetPreviewDecoder = { url in
      probe.record(url)
      return try StandardImageDecoder.decodePreview(url, maxDimension: 1_000)
    }
    let existing = fixture.destination.appendingPathComponent("Contact Sheet.pdf")
    let existingUppercase = fixture.destination.appendingPathComponent("CONTACT SHEET-2.PDF")
    try Data("keep one".utf8).write(to: existing)
    try Data("keep two".utf8).write(to: existingUppercase)

    model.exportContactSheet()
    #expect(model.isExporting && model.isExportingContactSheet)
    // Mutate after the synchronous snapshot, before the worker starts decoding.
    model.setExposureEV(2)
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.exportProgressCurrent == 2)
    #expect(probe.urls == [fixture.sources[0], fixture.sources[2]])
    #expect(model.parameters.photoAdjustments.exposureEV == 2)
    #expect(model.fullResolutionExportDecodeCount == 0)
    let output = try #require(model.lastContactSheetURL)
    #expect(output.lastPathComponent == "Contact Sheet-3.pdf")
    #expect(try Data(contentsOf: existing) == Data("keep one".utf8))
    #expect(try Data(contentsOf: existingUppercase) == Data("keep two".utf8))
    let pdf = try #require(PDFDocument(url: output))
    #expect(pdf.pageCount == 1)
    let text = try #require(pdf.string)
    #expect(text.contains("1. 03-z.png"))
    #expect(text.contains("2. 02-m.png"))
    #expect(!text.contains("01-a.png"))
    let source = try StandardImageDecoder.decode(fixture.sources[0])
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: before).makePreviewCGImage())
    let actualColor = try pdfTileCenter(output, index: 0)
    let expectedColor = try imageCenter(expected)
    #expect(
      zip(actualColor, expectedColor).allSatisfy { abs($0 - $1) <= 4 },
      "PDF tile \(actualColor), expected corrected preview \(expectedColor)")
    #expect(try fixture.outputNames().count == 3)
    model.endManualCropEditing()
  }

  @Test("Cancelling a sheet stops further decodes and prevents overlapping export queues")
  func cancellationCleansUp() async throws {
    let fixture = try Fixture(names: ["one.png", "two.png"])
    defer { fixture.remove() }
    let model = try await fixture.model()
    let probe = ContactSheetDecodeProbe()
    let releaseDecode = DispatchSemaphore(value: 0)
    defer { releaseDecode.signal() }
    model.contactSheetPreviewDecoder = { url in
      probe.record(url)
      guard releaseDecode.wait(timeout: .now() + 10) == .success else {
        throw CocoaError(.fileReadUnknown)
      }
      return try StandardImageDecoder.decodePreview(url, maxDimension: 1_000)
    }
    model.exportContactSheet(allFiles: true)
    try await waitUntil { probe.urls.count == 1 }
    model.addSelectedToExportQueue()
    model.exportAll()
    model.exportContactSheet()
    #expect(model.exportProgressTotal == 2)
    #expect(model.isExportingContactSheet)
    model.cancelExport()
    releaseDecode.signal()
    try await waitUntil { !model.isExporting }
    #expect(probe.urls.count == 1)
    #expect(model.lastContactSheetURL == nil)
    #expect(model.exportErrors.isEmpty)
    #expect(!model.isExportingContactSheet)
    #expect(model.status.contains("cancelled"))
    #expect(try fixture.outputNames().isEmpty)
  }

  @Test("A failed later scan removes the partial PDF and permits retry")
  func failedScanCleansUp() async throws {
    let fixture = try Fixture(names: ["one.png", "two.png"])
    defer { fixture.remove() }
    let model = try await fixture.model()
    model.contactSheetPreviewDecoder = { url in
      if url.lastPathComponent == "two.png" { throw CocoaError(.fileReadCorruptFile) }
      return try StandardImageDecoder.decodePreview(url, maxDimension: 1_000)
    }
    model.exportContactSheet(allFiles: true)
    try await waitUntil { !model.isExporting }
    #expect(model.lastContactSheetURL == nil)
    #expect(model.exportErrors.count == 1)
    #expect(model.exportErrors.first?.contains("two.png") == true)
    #expect(try fixture.outputNames().isEmpty)
    model.contactSheetPreviewDecoder = nil
    model.exportContactSheet(allFiles: true)
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.lastContactSheetURL?.lastPathComponent == "Contact Sheet.pdf")
  }

  @Test("Sheets paginate without blank trailing pages", arguments: [12, 13, 25])
  func pagination(count: Int) async throws {
    let fixture = try Fixture(names: ["source.png"])
    defer { fixture.remove() }
    var parameters = ProcessingParameters()
    parameters.filmType = .cropOnly
    let items = (1...count).map {
      ContactSheetItem(
        sources: [fixture.directory.appendingPathComponent("scan-\($0).png")],
        parameters: parameters, stackMode: .automatic)
    }
    let image = Fixture.source()
    let output = try await ContactSheetExport.write(
      items: items, destinationDirectory: fixture.destination, weakPrior: nil, flatField: nil,
      decode: { _ in image }, progress: { _, _ in })
    let document = try #require(PDFDocument(url: output))
    let pageCount = (count + 11) / 12
    #expect(document.pageCount == pageCount)
    for pageIndex in 0..<pageCount {
      let page = try #require(document.page(at: pageIndex))
      #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 612, height: 792))
      let text = try #require(page.string)
      #expect(text.contains("Page \(pageIndex + 1) of \(pageCount)"))
      for index in (pageIndex * 12 + 1)...min(count, (pageIndex + 1) * 12) {
        #expect(text.contains("\(index). scan-\(index).png"))
      }
    }
    if count == 25, let path = ProcessInfo.processInfo.environment["CONTACT_SHEET_QA_OUTPUT"] {
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(contentsOf: output).write(
        to: directory.appendingPathComponent("pagination.pdf"), options: .atomic)
    }
  }

  @Test("Selecting a stack member writes one merged tile under the anchor name")
  func enabledStackConsolidates() async throws {
    let fixture = try Fixture(names: ["anchor.png", "capture.png"])
    defer { fixture.remove() }
    let model = try await fixture.model()
    try await waitUntil { !model.isAnalyzingScanStacks }
    let stack = try #require(model.detectedScanStacks.first)
    model.setScanStackEnabled(true, for: stack)
    try await waitUntil { !model.isLoading && !model.isBuildingScanStack }
    model.selection = fixture.sources[1]
    model.selectedFiles = [fixture.sources[1]]
    let probe = ContactSheetDecodeProbe()
    model.contactSheetPreviewDecoder = { url in
      probe.record(url)
      return try StandardImageDecoder.decodePreview(url, maxDimension: 1_000)
    }
    model.exportContactSheet()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.exportProgressTotal == 1)
    #expect(probe.urls == fixture.sources)
    let output = try #require(model.lastContactSheetURL)
    let document = try #require(PDFDocument(url: output))
    let text = try #require(document.string)
    #expect(text.contains("1. anchor.png"))
    #expect(text.contains("2 captures - Aligned stack"))
    #expect(!text.contains("capture.png"))
  }

  @Test(
    "Real RAW contact sheets use bounded demosaiced previews",
    .enabled(
      if: contactSheetRAWCorpusAvailable,
      "sample-raw contact-sheet corpus unavailable"))
  func rawContactSheet() async throws {
    let fixture = try Fixture(names: ["placeholder.png"])
    defer { fixture.remove() }
    let model = AppModel()
    model.importFiles(contactSheetRAWs)
    try await waitUntil { !model.isLoading && model.previewImage != nil }
    model.setExportDestinationDirectory(fixture.destination)
    model.exportContactSheet(allFiles: true)
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.fullResolutionExportDecodeCount == 0)
    #expect(model.retainedExportDecodePath == nil)
    let output = try #require(model.lastContactSheetURL)
    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == 1)
    for url in contactSheetRAWs {
      #expect(document.string?.contains(url.lastPathComponent) == true)
    }
    if let path = ProcessInfo.processInfo.environment["CONTACT_SHEET_QA_OUTPUT"] {
      let destination = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contentsOf: output).write(to: destination, options: .atomic)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for contact-sheet work")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func pdfTileCenter(_ url: URL, index: Int) throws -> [Int] {
    let document = try #require(CGPDFDocument(url as CFURL))
    let page = try #require(document.page(at: index / 12 + 1))
    let context = try #require(
      CGContext(
        data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.drawPDFPage(page)
    let image = try #require(context.makeImage())
    let box = ContactSheetExport.imageBounds(at: index)
    // PDF coordinates start at the bottom; bitmap provider rows start at the top.
    return try color(image, x: Int(box.midX), y: image.height - 1 - Int(box.midY))
  }

  private func imageCenter(_ image: CGImage) throws -> [Int] {
    try color(image, x: image.width / 2, y: image.height / 2)
  }

  private func color(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
    let data = try #require(image.dataProvider?.data as Data?)
    let offset = y * image.bytesPerRow + x * 4
    return data[offset..<offset + 3].map(Int.init)
  }

  private struct Fixture {
    let directory: URL
    let destination: URL
    let sources: [URL]

    init(names: [String]) throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fsc-contact-sheet-\(UUID().uuidString)")
      destination = directory.appendingPathComponent("exports")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let sourceDirectory = directory
      sources = names.map { sourceDirectory.appendingPathComponent($0) }
      for source in sources {
        try Self.source().write(to: source, format: .png, parameters: .init(format: .png))
      }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func outputNames() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: destination.path)
    }

    @MainActor
    func model() async throws -> AppModel {
      let model = AppModel()
      model.importFiles(sources)
      let deadline = ContinuousClock.now + .seconds(10)
      while model.isLoading || model.isRendering || model.previewImage == nil {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      model.setExportDestinationDirectory(destination)
      return model
    }

    static func source() -> UInt16Image {
      var pixels: [UInt16] = []
      for y in 0..<144 {
        for x in 0..<216 {
          let wave = sin(Double(x) * 0.09) * cos(Double(y) * 0.07)
          let noise = (x &* 73_856_093 ^ y &* 19_349_663) & 0xfff
          let value = 24_000 + Int(9_000 * wave) + noise
          pixels += [UInt16(value / 2), UInt16(value), UInt16(value + 9_000)]
        }
      }
      return UInt16Image(width: 216, height: 144, channels: 3, pixels: pixels)
    }
  }
}

private let contactSheetRAWs = [
  "fuji400-fresh/DSCF2833.RAF", "cinestill800t/DSCF3247.RAF", "shanghaigp3/DSCF3200.RAF",
].map { SampleRawCorpus.url(relativePath: $0) }

private var contactSheetRAWCorpusAvailable: Bool {
  contactSheetRAWs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
}

private final class ContactSheetDecodeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URL] = []
  var urls: [URL] { lock.withLock { recorded } }
  func record(_ url: URL) { lock.withLock { recorded.append(url) } }
}
