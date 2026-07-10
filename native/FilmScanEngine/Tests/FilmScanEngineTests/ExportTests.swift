import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanEngine

struct ExportTests {
  private let tempDir: URL

  init() {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("FilmScanExportTests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  private func makeTestImage(
    width: Int = 32,
    height: Int = 16,
    channels: Int = 3
  ) -> UInt16Image {
    var pixels = [UInt16]()
    for y in 0..<height {
      for x in 0..<width {
        let r = UInt16((x * 65535) / max(1, width - 1))
        let g = UInt16((y * 65535) / max(1, height - 1))
        let b = UInt16(((x + y) * 65535) / max(1, width + height - 2) / 2)
        pixels.append(b)
        pixels.append(g)
        pixels.append(r)
      }
    }
    return UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
  }

  private func makeGrayImage(width: Int = 32, height: Int = 16) -> UInt16Image {
    var pixels = [UInt16]()
    for _ in 0..<height {
      for x in 0..<width {
        pixels.append(UInt16((x * 65535) / max(1, width - 1)))
      }
    }
    return UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
  }

  @Test func tiffExportRoundTrip() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .tiff)
    let url = tempDir.appendingPathComponent("test.tiff")
    try original.write(to: url, format: .tiff, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let imported = try StandardImageDecoder.decode(url)
    #expect(imported.width == original.width)
    #expect(imported.height == original.height)
    #expect(imported.channels == 3)
    #expect(imported == original)
  }

  @Test func measuredExportReportsProductionWriterStagesAndSize() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .tiff)
    let url = tempDir.appendingPathComponent("measured.tiff")

    let metrics = try original.writeMeasured(
      to: url, format: .tiff, parameters: params)

    #expect(metrics.pixelPackingSeconds >= 0)
    #expect(metrics.encodingFinalizationSeconds >= 0)
    #expect(metrics.packedPixelBytes == original.width * original.height * 6)
    #expect(metrics.outputBytes > 0)
    #expect(metrics.outputBytes == (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize)
  }

  @Test func tiffExportWithLZWCompression() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .tiff, tiffCompression: .lzw)
    let url = tempDir.appendingPathComponent("test_lzw.tiff")
    try original.write(to: url, format: .tiff, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let imported = try StandardImageDecoder.decode(url)
    #expect(imported.width == original.width)
    #expect(imported.height == original.height)
  }

  @Test func tiffExportUsesCompact16BitRGBComponentLayout() throws {
    let image = makeTestImage(width: 7, height: 5)
    let cgImage = try #require(image.makeExportCGImageRGB16())

    #expect(cgImage.bitsPerComponent == 16)
    #expect(cgImage.bitsPerPixel == 48)
    #expect(cgImage.bytesPerRow == 7 * 6)
    #expect(cgImage.alphaInfo == .none)
    #expect(cgImage.bitmapInfo.contains(.byteOrder16Little))
  }

  @Test func jpegExportProducesValidFile() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .jpeg)
    let url = tempDir.appendingPathComponent("test.jpg")
    try original.write(to: url, format: .jpeg, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let imported = try StandardImageDecoder.decode(url)
    #expect(imported.width == original.width)
    #expect(imported.height == original.height)
  }

  @Test func jpegQualityParameterShowsSizeDifference() throws {
    let original = makeTestImage()
    let highURL = tempDir.appendingPathComponent("high.jpg")
    let lowURL = tempDir.appendingPathComponent("low.jpg")

    let highParams = ExportParameters(format: .jpeg, jpegQuality: 0.95)
    let lowParams = ExportParameters(format: .jpeg, jpegQuality: 0.1)
    try original.write(to: highURL, format: .jpeg, parameters: highParams)
    try original.write(to: lowURL, format: .jpeg, parameters: lowParams)

    let highSize = try FileManager.default.attributesOfItem(atPath: highURL.path)[.size] as! Int
    let lowSize = try FileManager.default.attributesOfItem(atPath: lowURL.path)[.size] as! Int
    #expect(lowSize < highSize, "Lower quality JPEG should produce smaller file")
  }

  @Test func pngExportRoundTrip() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .png)
    let url = tempDir.appendingPathComponent("test.png")
    try original.write(to: url, format: .png, parameters: params)
    try original.write(to: url, format: .png, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let imported = try StandardImageDecoder.decode(url)
    #expect(imported.width == original.width)
    #expect(imported.height == original.height)
    #expect(imported.channels == 3)
  }

  @Test func pngExportUsesExplicit16BitRGBAComponentLayout() throws {
    let image = makeTestImage(width: 7, height: 5)
    let cgImage = try #require(image.makeExportCGImage16())

    #expect(cgImage.bitsPerComponent == 16)
    #expect(cgImage.bitsPerPixel == 64)
    #expect(cgImage.bytesPerRow == 7 * 8)
    #expect(cgImage.alphaInfo == .noneSkipLast)
    #expect(cgImage.bitmapInfo.contains(.byteOrder16Little))
  }

  @Test func pngExportReportsDestinationAndRemovesStagingFileOnFailure() throws {
    let blockedParent = tempDir.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: blockedParent)
    let destination = blockedParent.appendingPathComponent("failed.png")

    do {
      try makeTestImage().write(
        to: destination,
        format: .png,
        parameters: ExportParameters(format: .png)
      )
      Issue.record("PNG export unexpectedly succeeded")
    } catch {
      #expect(error.localizedDescription.contains("failed.png"))
      #expect(!error.localizedDescription.contains("ExportError error"))
    }

    let leftovers = try FileManager.default.contentsOfDirectory(
      at: tempDir,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains("failed.png") }
    #expect(leftovers.isEmpty)
  }

  @Test func dngExportProducesReadableFile() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .dng)
    let url = tempDir.appendingPathComponent("test.dng")
    try original.write(to: url, format: .dng, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let data = try Data(contentsOf: url)
    #expect(data.count > 0, "DNG file must not be empty")
    #expect(data.count >= original.width * original.height * original.channels * 2,
      "DNG data must contain at least the pixel data")

    let byteOrder = [UInt8](data[0..<2])
    #expect(byteOrder == [0x49, 0x49] || byteOrder == [0x4D, 0x4D],
      "DNG should have valid TIFF byte order marker")
  }

  @Test func dngExportWithGrayImage() throws {
    let original = makeGrayImage()
    let params = ExportParameters(format: .dng)
    let url = tempDir.appendingPathComponent("gray.dng")
    try original.write(to: url, format: .dng, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let data = try Data(contentsOf: url)
    #expect(data.count > 0)
  }

  @Test func framePaddingApplied() throws {
    let original = makeTestImage(width: 32, height: 32)
    let framed = original.addingFrame(percent: 10)
    let params = ExportParameters(format: .tiff, framePercent: 10)
    let url = tempDir.appendingPathComponent("framed.tiff")
    try framed.write(to: url, format: .tiff, parameters: params)

    let imported = try StandardImageDecoder.decode(url)
    let framePixels = Int(32.0 * 10.0 / 100.0)
    let expectedSize = 32 + framePixels * 2
    #expect(imported.width == expectedSize)
    #expect(imported.height == expectedSize)
  }

  @Test func exportManagerSingleRequest() async throws {
    let original = makeTestImage()
    let exportParams = ExportParameters(format: .tiff)
    let destURL = tempDir.appendingPathComponent("single.tiff")

    let request = ExportManager.ExportRequest(
      sourceURL: URL(fileURLWithPath: "/fake/source.raf"),
      destinationURL: destURL,
      image: original,
      parameters: exportParams
    )

    let manager = ExportManager()
    let results = await manager.export(requests: [request])

    #expect(results.count == 1)
    #expect(results[0].isSuccess, "Export should succeed")
    #expect(FileManager.default.fileExists(atPath: destURL.path))
  }

  @Test func exportManagerCancellation() async throws {
    var requests: [ExportManager.ExportRequest] = []
    for i in 0..<10 {
      let image = makeTestImage()
      let params = ExportParameters(format: .tiff)
      let destURL = tempDir.appendingPathComponent("cancel_\(i).tiff")
      requests.append(ExportManager.ExportRequest(
        sourceURL: URL(fileURLWithPath: "/fake/source_\(i).raf"),
        destinationURL: destURL,
        image: image,
        parameters: params
      ))
    }

    let manager = ExportManager()
    let task = Task {
      await manager.export(requests: requests)
    }
    task.cancel()
    let results = await task.value

    let cancelled = results.filter { ($0.error as? ExportManager.ExportManagerError) == .cancelled }
    #expect(cancelled.count > 0, "Cancellation should produce cancelled results")
  }

  @Test func exportManagerProgressReporting() async throws {
    var images: [UInt16Image] = []
    for _ in 0..<5 {
      images.append(makeTestImage())
    }
    let params = ExportParameters(format: .tiff)
    let requests = images.enumerated().map { i, image in
      ExportManager.ExportRequest(
        sourceURL: URL(fileURLWithPath: "/fake/\(i).raf"),
        destinationURL: tempDir.appendingPathComponent("progress_\(i).tiff"),
        image: image,
        parameters: params
      )
    }

    let manager = ExportManager()
    let results = await manager.export(requests: requests)
    #expect(results.count == 5, "All requests should complete")
    let allSucceeded = results.filter(\.isSuccess).count == results.count
    #expect(allSucceeded, "All exports should succeed")
    for request in requests {
      #expect(FileManager.default.fileExists(atPath: request.destinationURL.path))
    }
  }

  @Test func exportManagerBatchParallelism() async throws {
    var images: [UInt16Image] = []
    for _ in 0..<8 {
      images.append(makeTestImage())
    }
    let params = ExportParameters(format: .tiff)
    let requests = images.enumerated().map { i, image in
      ExportManager.ExportRequest(
        sourceURL: URL(fileURLWithPath: "/fake/\(i).raf"),
        destinationURL: tempDir.appendingPathComponent("batch_\(i).tiff"),
        image: image,
        parameters: params
      )
    }

    let manager = ExportManager()
    let results = await manager.exportBatch(requests: requests, maxConcurrent: 4)

    #expect(results.count == 8)
    let successful = results.filter(\.isSuccess)
    #expect(successful.count == 8, "All images should export successfully")
    for request in requests {
      #expect(FileManager.default.fileExists(atPath: request.destinationURL.path))
    }
  }

  @Test func cancelledBatchReturnsOneResultPerRequestWithoutWriting() async throws {
    let params = ExportParameters(format: .tiff)
    let requests = (0..<8).map { index in
      ExportManager.ExportRequest(
        sourceURL: URL(fileURLWithPath: "/fake/cancelled_\(index).raf"),
        destinationURL: tempDir.appendingPathComponent("cancelled_batch_\(index).tiff"),
        image: makeTestImage(),
        parameters: params
      )
    }

    let manager = ExportManager()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await manager.exportBatch(requests: requests, maxConcurrent: 2)
    }
    let results = await task.value

    #expect(results.count == requests.count)
    #expect(
      results.allSatisfy {
        ($0.error as? ExportManager.ExportManagerError) == .cancelled
      })
    #expect(requests.allSatisfy { !FileManager.default.fileExists(atPath: $0.destinationURL.path) })
  }

  @Test func exportFormatRoundTrip() throws {
    let json = """
      {"format":"tiff","framePercent":5,"jpegQuality":0.85,"tiffCompression":"lzw"}
      """
    let data = json.data(using: .utf8)!
    let params = try JSONDecoder().decode(ExportParameters.self, from: data)
    #expect(params.format == .tiff)
    #expect(params.framePercent == 5)
    #expect(params.jpegQuality == 0.85)
    #expect(params.tiffCompression == .lzw)

    let encoded = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(ExportParameters.self, from: encoded)
    #expect(decoded.format == params.format)
    #expect(decoded.framePercent == params.framePercent)
    #expect(decoded.jpegQuality == params.jpegQuality)
    #expect(decoded.tiffCompression == params.tiffCompression)
  }

  @Test func exportFormatAllCasesRoundTrip() throws {
    for format in ExportFormat.allCases {
      let params = ExportParameters(format: format)
      let encoded = try JSONEncoder().encode(params)
      let decoded = try JSONDecoder().decode(ExportParameters.self, from: encoded)
      #expect(decoded.format == format)
    }
  }

  @Test func exportSingleChannelImage() throws {
    let gray = makeGrayImage()
    let params = ExportParameters(format: .tiff)
    let url = tempDir.appendingPathComponent("gray_export.tiff")
    try gray.write(to: url, format: .tiff, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let imported = try StandardImageDecoder.decode(url)
    #expect(imported.width == gray.width)
    #expect(imported.height == gray.height)
  }

  @Test func exportCreatesIntermediateDirectories() throws {
    let original = makeTestImage()
    let params = ExportParameters(format: .tiff)
    let nestedDir = tempDir.appendingPathComponent("nested/subdir")
    let url = nestedDir.appendingPathComponent("test.tiff")

    #expect(!FileManager.default.fileExists(atPath: nestedDir.path))
    try original.write(to: url, format: .tiff, parameters: params)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func exportFormatDisplayNames() {
    #expect(ExportFormat.tiff.displayName == "TIFF")
    #expect(ExportFormat.jpeg.displayName == "JPEG")
    #expect(ExportFormat.png.displayName == "PNG")
    #expect(ExportFormat.dng.displayName == "DNG")
  }

  @Test func exportFormatFileExtensions() {
    #expect(ExportFormat.tiff.fileExtension == "tiff")
    #expect(ExportFormat.jpeg.fileExtension == "jpeg")
    #expect(ExportFormat.png.fileExtension == "png")
    #expect(ExportFormat.dng.fileExtension == "dng")
  }

  @Test func tiffCompressionDisplayNames() {
    for comp in TiffCompression.allCases {
      switch comp {
      case .none: #expect(comp.displayName == "None")
      case .lzw: #expect(comp.displayName == "LZW")
      }
    }
  }
}
