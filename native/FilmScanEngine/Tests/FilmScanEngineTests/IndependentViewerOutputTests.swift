import AppKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Independent-viewer output contract", .serialized)
@MainActor
struct IndependentViewerOutputTests {
  private enum WaitError: Error {
    case timedOut
  }

  @Test("App-path TIFF/JPEG/PNG reopen as named sRGB; DNG carries processed-RGB tags")
  func appPathExportsReopenWithIndependentViewers() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-independent-viewer-\(UUID().uuidString)", isDirectory: true)
    let destination = directory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("scan.png")
    try makeSource().write(to: input, format: .png, parameters: .init(format: .png))

    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering && !model.isLoading }
    model.setFilmType(.colourNegative)
    model.rotateClockwise()
    try await waitUntil { !model.isRendering }
    model.setManualCrop(.init(x: 0.10, y: 0.10, width: 0.80, height: 0.75))
    try await waitUntil { !model.isRendering && model.previewImage != nil }
    model.setExportFramePercent(5)
    model.setExportDestinationDirectory(destination)

    let canvas = try #require(model.selectedCanvasDimensions)
    let output = try #require(model.selectedOutputDimensions)
    let preview = try #require(model.previewImage?.size)
    #expect(Int(preview.width.rounded()) == canvas.width)
    #expect(Int(preview.height.rounded()) == canvas.height)
    #expect(output.width > canvas.width)
    #expect(output.height > canvas.height)

    for format in [ExportFormat.tiff, .jpeg, .png] {
      model.setExportFormat(format)
      if format == .tiff { model.setTiffCompression(.lzw) }
      model.exportSelected()
      try await waitUntil { !model.isExporting }
      #expect(model.exportErrors.isEmpty)
    }
    model.setExportFormat(.dng)
    model.exportSelected()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)

    let tiff = destination.appendingPathComponent("scan.tiff")
    let jpeg = destination.appendingPathComponent("scan.jpeg")
    let png = destination.appendingPathComponent("scan.png")
    let dng = destination.appendingPathComponent("scan.dng")

    _ = try IndependentViewerInspection.inspectNamedSRGB(
      at: tiff,
      expectedWidth: output.width,
      expectedHeight: output.height,
      expectedDepth: 16
    )
    _ = try IndependentViewerInspection.inspectNamedSRGB(
      at: jpeg,
      expectedWidth: output.width,
      expectedHeight: output.height,
      expectedDepth: 8
    )
    _ = try IndependentViewerInspection.inspectNamedSRGB(
      at: png,
      expectedWidth: output.width,
      expectedHeight: output.height,
      expectedDepth: 16
    )
    try IndependentViewerInspection.inspectProcessedDNG(
      at: dng,
      expectedWidth: output.width,
      expectedHeight: output.height
    )

    let reopenedTIFF = try StandardImageDecoder.decode(tiff)
    let reopenedPNG = try StandardImageDecoder.decode(png)
    #expect(reopenedTIFF == reopenedPNG)
    #expect(reopenedTIFF.width == output.width)
    #expect(reopenedTIFF.height == output.height)
    #expect(reopenedTIFF.channels == 3)

    for url in [tiff, jpeg, png, dng] {
      try FileManager.default.removeItem(at: url)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  private func makeSource() -> UInt16Image {
    var pixels: [UInt16] = []
    for y in 0..<240 {
      for x in 0..<320 {
        pixels.append(UInt16(6_000 + x * 80))
        pixels.append(UInt16(10_000 + y * 90))
        pixels.append(UInt16(14_000 + x * 40 + y * 50))
      }
    }
    return UInt16Image(width: 320, height: 240, channels: 3, pixels: pixels)
  }

  private func waitUntil(condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
