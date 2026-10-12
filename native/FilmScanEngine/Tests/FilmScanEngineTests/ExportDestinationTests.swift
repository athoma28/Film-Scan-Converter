import AppKit
import FilmScanEngine
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import FilmScanConverterMac

@Suite("Original-folder export destinations", .serialized)
@MainActor
struct ExportDestinationTests {
  @Test(
    "A file created after enqueue is preserved and the next export chooses a new name",
    arguments: ExportFormat.allCases)
  func lateDestinationCollision(format: ExportFormat) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = try fixture.scan(named: "scan.png", in: fixture.firstDirectory)
    let sourceBytes = try Data(contentsOf: source)
    let model = try await loadedModel([source])
    defer { close(model) }
    model.setExportFormat(format)
    model.exportSelected()
    // Enqueue freezes the destination synchronously. Its main-actor task cannot
    // start the writer until this turn yields, making the collision repeatable.
    let stem = format == .png ? "scan-2" : "scan"
    let occupied = fixture.firstDirectory.appendingPathComponent(
      stem + "." + format.fileExtension)
    let occupiedBytes = Data("created after export enqueue".utf8)
    try occupiedBytes.write(to: occupied)
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.count == 1)
    #expect(try Data(contentsOf: occupied) == occupiedBytes)
    #expect(try Data(contentsOf: source) == sourceBytes)
    #expect(
      try !FileManager.default.contentsOfDirectory(atPath: fixture.firstDirectory.path)
        .contains { $0.hasSuffix(".tmp") })

    model.exportSelected()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    let retryStem = format == .png ? "scan-3" : "scan-2"
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.firstDirectory
          .appendingPathComponent(retryStem + "." + format.fileExtension).path))
    #expect(try Data(contentsOf: occupied) == occupiedBytes)
  }

  @Test("Mixed-folder exports reserve names per folder and preserve source files")
  func originalFoldersPreserveSources() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.scan(named: "scan.png", in: fixture.firstDirectory)
    let second = try fixture.scan(named: "scan.png", in: fixture.secondDirectory, seed: 91)
    let originalFirst = try Data(contentsOf: first)
    let originalSecond = try Data(contentsOf: second)
    let existing = fixture.firstDirectory.appendingPathComponent("SCAN-2.PNG")
    let existingBytes = Data("existing output".utf8)
    try existingBytes.write(to: existing)
    let model = try await loadedModel([first, second])
    defer { close(model) }
    #expect(model.exportParameters.destinationDirectory == nil)
    model.setExportFormat(.png)

    model.exportAll()
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 2 }

    #expect(model.exportErrors.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.firstDirectory.appendingPathComponent("scan-3.png").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.secondDirectory.appendingPathComponent("scan-2.png").path))
    #expect(try Data(contentsOf: first) == originalFirst)
    #expect(try Data(contentsOf: second) == originalSecond)
    #expect(try Data(contentsOf: existing) == existingBytes)
    #expect(model.status.contains("across 2 folders"))
  }

  @Test("Queued exports freeze original or chosen folders and reserve repeated jobs")
  func queuedDestinationsStayFrozen() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.scan(named: "first.png", in: fixture.firstDirectory)
    let second = try fixture.scan(named: "second.png", in: fixture.secondDirectory, seed: 91)
    let originalFirst = try Data(contentsOf: first)
    let originalSecond = try Data(contentsOf: second)
    let model = try await loadedModel([first, second])
    defer { close(model) }
    model.setExportFormat(.png)
    model.exportSelected()
    #expect(model.isExporting)

    model.setExportDestinationDirectory(fixture.commonDirectory)
    model.selectedFiles = [second]
    #expect(model.sidebarSelectionDidChange())
    model.addSelectedToExportQueue()
    model.setExportDestinationDirectory(nil)
    model.setExportFormat(.jpeg)
    model.addSelectedToExportQueue()
    model.addSelectedToExportQueue()
    // Changes after enqueue must not reroute any of the four jobs.
    model.setExportDestinationDirectory(fixture.commonDirectory)
    model.setExportFormat(.tiff)
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 4 }

    #expect(model.exportErrors.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.firstDirectory.appendingPathComponent("first-2.png").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.commonDirectory.appendingPathComponent("second.png").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.secondDirectory.appendingPathComponent("second.jpeg").path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.secondDirectory.appendingPathComponent("second-2.jpeg").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.commonDirectory.path)
        == ["second.png"])
    #expect(try Data(contentsOf: first) == originalFirst)
    #expect(try Data(contentsOf: second) == originalSecond)
    try expectImage(
      at: fixture.firstDirectory.appendingPathComponent("first-2.png"), type: .png)
    try expectImage(at: fixture.commonDirectory.appendingPathComponent("second.png"), type: .png)
    try expectImage(
      at: fixture.secondDirectory.appendingPathComponent("second.jpeg"), type: .jpeg)
    try expectImage(
      at: fixture.secondDirectory.appendingPathComponent("second-2.jpeg"), type: .jpeg)
  }

  @Test("Appended jobs reserve names across symlink aliases of the same physical folder")
  func queuedDirectoryAliasesShareReservations() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = try fixture.scan(named: "scan.png", in: fixture.firstDirectory)
    let alias = fixture.directory.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: alias, withDestinationURL: fixture.firstDirectory)
    let originalBytes = try Data(contentsOf: source)
    let original = try StandardImageDecoder.decode(source)
    let model = try await loadedModel([source])
    defer { close(model) }
    model.setFilmType(.cropOnly)
    model.setExportFormat(.png)
    model.exportSelected()
    #expect(model.isExporting)
    // The first writer cannot begin until this main-actor turn yields, so the
    // second reservation has to notice the queued path, not an existing output.
    model.setExportDestinationDirectory(alias)
    model.addSelectedToExportQueue()
    #expect(model.exportProgressTotal == 2, Comment(rawValue: model.status))
    try await waitUntil { !model.isExporting }

    #expect(model.exportProgressCurrent == 2, Comment(rawValue: model.status))
    #expect(model.exportErrors.isEmpty, Comment(rawValue: model.status))
    #expect(try Data(contentsOf: source) == originalBytes)
    for filename in ["scan-2.png", "scan-3.png"] {
      let output = fixture.firstDirectory.appendingPathComponent(filename)
      #expect(try StandardImageDecoder.decode(output) == original)
    }
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: fixture.firstDirectory.path))
        == ["scan.png", "scan-2.png", "scan-3.png"])
  }

  @Test("Default contact sheets use the active scan folder and snapshot that destination")
  func contactSheetUsesActiveFolder() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try fixture.scan(named: "first.png", in: fixture.firstDirectory)
    let second = try fixture.scan(named: "second.png", in: fixture.secondDirectory, seed: 91)
    let model = try await loadedModel([first, second])
    defer { close(model) }
    model.selectedFiles = [second]
    #expect(model.sidebarSelectionDidChange())
    model.loadSelection()
    try await waitUntil { !model.isLoading && !model.isRendering }
    let existing = fixture.secondDirectory.appendingPathComponent("Contact Sheet.pdf")
    let existingBytes = Data("existing contact sheet".utf8)
    try existingBytes.write(to: existing)

    model.exportContactSheet(allFiles: true)
    #expect(model.isExportingContactSheet)
    model.setExportDestinationDirectory(fixture.commonDirectory)
    try await waitUntil { !model.isExporting }

    #expect(model.exportErrors.isEmpty)
    let output = try #require(model.lastContactSheetURL)
    #expect(output.deletingLastPathComponent() == fixture.secondDirectory)
    #expect(output.lastPathComponent == "Contact Sheet-2.pdf")
    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == 1)
    #expect(try Data(contentsOf: existing) == existingBytes)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.commonDirectory.path).isEmpty)
  }

  @Test("A stack spanning source folders exports and saves its sheet beside the anchor")
  func stackUsesAnchorFolder() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let anchor = try fixture.scan(named: "anchor.png", in: fixture.firstDirectory)
    let capture = try fixture.scan(named: "capture.png", in: fixture.secondDirectory)
    let anchorBytes = try Data(contentsOf: anchor)
    let captureBytes = try Data(contentsOf: capture)
    let model = try await loadedModel([anchor, capture])
    defer { close(model) }
    let stack = try #require(model.detectedScanStacks.first)
    model.setScanStackEnabled(true, for: stack)
    try await waitUntil {
      model.previewSourceKind == .alignedStack && !model.isLoading
        && !model.isBuildingScanStack && !model.isUpgradingScanStack
    }
    model.setFilmType(.cropOnly)
    model.setExportFormat(.png)
    model.selection = capture
    model.selectedFiles = [capture]

    model.exportSelected()
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 1 }
    #expect(model.exportErrors.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.firstDirectory.appendingPathComponent("anchor-2.png").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.secondDirectory.path)
        == ["capture.png"])
    model.exportContactSheet()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.lastContactSheetURL?.deletingLastPathComponent() == fixture.firstDirectory)
    #expect(try Data(contentsOf: anchor) == anchorBytes)
    #expect(try Data(contentsOf: capture) == captureBytes)
  }

  private func loadedModel(_ sources: [URL]) async throws -> AppModel {
    let model = AppModel(previewMemoryBudget: 1)
    model.importFiles(sources)
    try await waitUntil {
      model.hasPreviewImage && !model.isLoading && !model.isRendering
        && !model.isAnalyzingScanStacks
    }
    return model
  }

  private func close(_ model: AppModel) {
    model.selection = nil
    model.loadSelection()
  }

  private func expectImage(at url: URL, type: UTType) throws {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(CGImageSourceGetType(source) as String? == type.identifier)
    let decoded = try StandardImageDecoder.decode(url)
    #expect(decoded.width == 216)
    #expect(decoded.height == 144)
    #expect(decoded.channels == 3)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for export-destination work")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private struct Fixture {
    let directory: URL
    let firstDirectory: URL
    let secondDirectory: URL
    let commonDirectory: URL

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fsc-export-destinations-\(UUID().uuidString)", isDirectory: true)
      firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
      secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
      commonDirectory = directory.appendingPathComponent("common", isDirectory: true)
      for destination in [firstDirectory, secondDirectory, commonDirectory] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func scan(named name: String, in destination: URL, seed: Int = 0) throws -> URL {
      var pixels: [UInt16] = []
      for y in 0..<144 {
        for x in 0..<216 {
          let wave = sin(Double(x + seed) * 0.09) * cos(Double(y - seed) * 0.07)
          let noise = (x &* 73_856_093 ^ y &* 19_349_663 ^ seed &* 83_492_791) & 0xfff
          let value = 24_000 + Int(9_000 * wave) + noise
          pixels += [UInt16(value / 2), UInt16(value), UInt16(value + 9_000)]
        }
      }
      let source = destination.appendingPathComponent(name)
      try UInt16Image(width: 216, height: 144, channels: 3, pixels: pixels).write(
        to: source, format: .png, parameters: .init(format: .png))
      return source
    }
  }
}
