import CoreGraphics
import FilmScanEngine
import Foundation
import ImageIO
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

  private func requireSRGBImage(at url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    #expect(image.colorSpace?.copyICCData() != nil)
    return image
  }

  private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }

  private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
      | UInt32(data[offset + 1]) << 8
      | UInt32(data[offset + 2]) << 16
      | UInt32(data[offset + 3]) << 24
  }

  private func dngIFDEntries(_ data: Data) -> [UInt16: (type: UInt16, count: UInt32, value: UInt32)]
  {
    let ifdOffset = Int(littleEndianUInt32(data, at: 4))
    let count = Int(littleEndianUInt16(data, at: ifdOffset))
    var result: [UInt16: (type: UInt16, count: UInt32, value: UInt32)] = [:]
    for index in 0..<count {
      let offset = ifdOffset + 2 + index * 12
      result[littleEndianUInt16(data, at: offset)] = (
        littleEndianUInt16(data, at: offset + 2),
        littleEndianUInt32(data, at: offset + 4),
        littleEndianUInt32(data, at: offset + 8)
      )
    }
    return result
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
    _ = try requireSRGBImage(at: url)
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
    let outputFileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect(metrics.outputBytes == outputFileSize)
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

  @Test func exportUsesCompact16BitRGBComponentLayout() throws {
    let image = makeTestImage(width: 7, height: 5)
    let cgImage = try #require(image.makeExportCGImage16())

    #expect(cgImage.bitsPerComponent == 16)
    #expect(cgImage.bitsPerPixel == 48)
    #expect(cgImage.bytesPerRow == 7 * 6)
    #expect(cgImage.alphaInfo == .none)
    #expect(cgImage.bitmapInfo.contains(.byteOrder16Little))
    #expect(cgImage.colorSpace?.name == CGColorSpace.sRGB)
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
    _ = try requireSRGBImage(at: url)
  }

  @Test func jpegExportUsesCompact8BitRGBComponentLayout() throws {
    let image = makeTestImage(width: 7, height: 5)
    let cgImage = try #require(image.makeExportCGImage8())

    #expect(cgImage.bitsPerComponent == 8)
    #expect(cgImage.bitsPerPixel == 24)
    #expect(cgImage.bytesPerRow == 7 * 3)
    #expect(cgImage.alphaInfo == .none)
    #expect(cgImage.colorSpace?.name == CGColorSpace.sRGB)
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
    #expect(imported == original)
    _ = try requireSRGBImage(at: url)
  }

  @Test(arguments: [(1, 1), (1, 257), (257, 1), (513, 257)])
  func pngExportPreservesAll16BitCodesAndBoundaryRows(width: Int, height: Int) throws {
    let pixelCount = width * height
    var pixels = [UInt16]()
    pixels.reserveCapacity(pixelCount * 3)
    for pixelIndex in 0..<pixelCount {
      // An odd stride visits every UInt16 code in the largest case. XOR offsets
      // keep BGR channels distinct while preserving that coverage and low bits.
      let blue = UInt16(truncatingIfNeeded: pixelIndex * 257 + 0x1234)
      pixels.append(blue)
      pixels.append(blue ^ 0x55AA)
      pixels.append(blue ^ 0xAA55)
    }
    let original = UInt16Image(
      width: width, height: height, channels: 3, pixels: pixels)
    let url = tempDir.appendingPathComponent("full16_\(width)x\(height).png")
    defer { try? FileManager.default.removeItem(at: url) }

    try original.write(to: url, format: .png, parameters: ExportParameters(format: .png))

    let reopened = try requireSRGBImage(at: url)
    #expect(reopened.width == width)
    #expect(reopened.height == height)
    #expect(reopened.bitsPerComponent == 16)
    #expect(
      reopened.alphaInfo == .none || reopened.alphaInfo == .noneSkipFirst
        || reopened.alphaInfo == .noneSkipLast)
    let imported = try StandardImageDecoder.decode(url)
    #expect(imported.width == width)
    #expect(imported.height == height)
    #expect(imported.channels == 3)
    #expect(imported == original)
  }

  @Test func failedExportPreservesExistingDestination() async throws {
    let url = tempDir.appendingPathComponent("existing.png")
    let existingData = Data("existing destination".utf8)
    try existingData.write(to: url)

    let request = ExportManager.ExportRequest(
      sourceURL: tempDir.appendingPathComponent("source.gray"),
      destinationURL: url,
      image: makeGrayImage(),
      parameters: ExportParameters(format: .png))
    let results = await ExportManager().export(requests: [request])

    #expect(results.count == 1)
    #expect(results[0].error != nil)
    #expect(try Data(contentsOf: url) == existingData)
  }

  @Test func largeExportPackingPreservesRGBValuesAcrossParallelRanges() throws {
    let width = 1_001
    let height = 1_000
    let pixelCount = width * height
    var pixels = [UInt16](repeating: 0, count: pixelCount * 3)
    for pixelIndex in 0..<pixelCount {
      let component = pixelIndex * 3
      pixels[component] = UInt16(truncatingIfNeeded: pixelIndex * 3)
      pixels[component + 1] = UInt16(truncatingIfNeeded: pixelIndex * 5)
      pixels[component + 2] = UInt16(truncatingIfNeeded: pixelIndex * 7)
    }
    let image = UInt16Image(
      width: width, height: height, channels: 3, pixels: pixels)
    let rgb16 = try #require(image.rgb16Data())
    let rgb8 = try #require(image.rgb8Data())

    rgb16.withUnsafeBytes { rawBytes in
      let components = rawBytes.bindMemory(to: UInt16.self)
      for pixelIndex in [0, pixelCount / 8, pixelCount / 2, pixelCount - 1] {
        let component = pixelIndex * 3
        #expect(components[component] == pixels[component + 2])
        #expect(components[component + 1] == pixels[component + 1])
        #expect(components[component + 2] == pixels[component])
      }
    }
    rgb8.withUnsafeBytes { rawBytes in
      let components = rawBytes.bindMemory(to: UInt8.self)
      for pixelIndex in [0, pixelCount / 8, pixelCount / 2, pixelCount - 1] {
        let component = pixelIndex * 3
        #expect(components[component] == UInt8(truncatingIfNeeded: pixels[component + 2] >> 8))
        #expect(components[component + 1] == UInt8(truncatingIfNeeded: pixels[component + 1] >> 8))
        #expect(components[component + 2] == UInt8(truncatingIfNeeded: pixels[component] >> 8))
      }
    }
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
    #expect(
      data.count >= original.width * original.height * original.channels * 2,
      "DNG data must contain at least the pixel data")

    let byteOrder = [UInt8](data[0..<2])
    #expect(
      byteOrder == [0x49, 0x49] || byteOrder == [0x4D, 0x4D],
      "DNG should have valid TIFF byte order marker")

    let entries = dngIFDEntries(data)
    let stripOffset = try #require(entries[273]?.value)
    let stripByteCount = try #require(entries[279]?.value)
    #expect(Int(stripOffset + stripByteCount) == data.count)
    #expect(entries[258]?.count == 3)
    #expect(entries[50706]?.value == 0x0000_0201)
    #expect(entries[50721]?.count == 9)
    #expect(entries[50879]?.value == 1)
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
    defer { try? FileManager.default.removeItem(at: tempDir) }
    var requests: [ExportManager.ExportRequest] = []
    for i in 0..<10 {
      let image = makeTestImage()
      let params = ExportParameters(format: .tiff)
      let destURL = tempDir.appendingPathComponent("cancel_\(i).tiff")
      requests.append(
        ExportManager.ExportRequest(
          sourceURL: URL(fileURLWithPath: "/fake/source_\(i).raf"),
          destinationURL: destURL,
          image: image,
          parameters: params
        ))
    }

    let manager = ExportManager()
    let progress = ExportProgressProbe()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await manager.export(requests: requests, progress: progress.record)
    }
    let results = await task.value

    #expect(results.map(\.sourceURL) == requests.map(\.sourceURL))
    #expect(results.allSatisfy { ($0.error as? ExportManager.ExportManagerError) == .cancelled })
    #expect(
      progress.events
        == (1...requests.count).map {
          .init(completed: $0, total: requests.count, succeeded: false)
        })
    #expect(try FileManager.default.contentsOfDirectory(atPath: tempDir.path).isEmpty)
  }

  @Test func exportManagerProgressReporting() async throws {
    defer { try? FileManager.default.removeItem(at: tempDir) }
    // PNG deliberately rejects a one-channel image. The callback must report
    // the failed member and still reach the total after the following success.
    let images = [makeTestImage(), makeGrayImage(), makeTestImage()]
    let params = ExportParameters(format: .png)
    let requests = images.enumerated().map { i, image in
      ExportManager.ExportRequest(
        sourceURL: URL(fileURLWithPath: "/fake/\(i).raf"),
        destinationURL: tempDir.appendingPathComponent("progress_\(i).png"),
        image: image,
        parameters: params
      )
    }

    let manager = ExportManager()
    let progress = ExportProgressProbe()
    let results = await manager.export(requests: requests, progress: progress.record)
    #expect(results.map(\.isSuccess) == [true, false, true])
    #expect(
      progress.events == [
        .init(completed: 1, total: 3, succeeded: true),
        .init(completed: 2, total: 3, succeeded: false),
        .init(completed: 3, total: 3, succeeded: true),
      ])
    for (request, result) in zip(requests, results) {
      if result.isSuccess {
        #expect(try StandardImageDecoder.decode(request.destinationURL) == request.image)
      } else {
        #expect(!FileManager.default.fileExists(atPath: request.destinationURL.path))
      }
    }
  }

  @Test("Batch writers overlap within their limit and return input-ordered results")
  func batchWritersOverlapAndPreserveResultOrder() async throws {
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let parameters = ExportParameters(format: .tiff)
    let requests = (0..<4).map { index in
      ExportManager.ExportRequest(
        sourceURL: tempDir.appendingPathComponent("source_\(index).tiff"),
        destinationURL: tempDir.appendingPathComponent("overlap_\(index).tiff"),
        image: makeTestImage(width: 64 - index * 8, height: 32),
        parameters: parameters)
    }
    let probe = ExportWriterProbe(
      delayedFilename: "overlap_0.tiff", peerFilename: "overlap_1.tiff")
    let manager = ExportManager(writer: probe.write)
    let results = await manager.exportBatch(requests: requests, maxConcurrent: 2)

    #expect(probe.maximumActiveCount == 2)
    #expect(probe.completedFilenames.first == "overlap_1.tiff")
    #expect(results.map(\.sourceURL) == requests.map(\.sourceURL))
    #expect(results.allSatisfy { $0.isSuccess })
    for request in requests {
      #expect(try StandardImageDecoder.decode(request.destinationURL) == request.image)
    }
    let outputNames = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(Set(outputNames) == Set(requests.map { $0.destinationURL.lastPathComponent }))
  }

  @Test("Cancelling active batch writers drains their stages without starting pending jobs")
  func cancellingActiveWritersLeavesPendingJobsUnwritten() async throws {
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let parameters = ExportParameters(format: .tiff)
    let requests = (0..<4).map { index in
      ExportManager.ExportRequest(
        sourceURL: tempDir.appendingPathComponent("source_\(index).tiff"),
        destinationURL: tempDir.appendingPathComponent("cancel_active_\(index).tiff"),
        image: makeTestImage(), parameters: parameters)
    }
    let probe = ExportWriterProbe(waitsForRelease: true)
    defer { probe.release() }
    let progress = ExportProgressProbe()
    let manager = ExportManager(writer: probe.write)
    let task = Task {
      await manager.exportBatch(requests: requests, maxConcurrent: 2, progress: progress.record)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while probe.startedCount < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(probe.startedCount == 2)
    task.cancel()
    probe.release()
    let results = await task.value

    #expect(probe.startedCount == 2)
    #expect(probe.maximumActiveCount == 2)
    #expect(
      progress.events == [
        .init(completed: 1, total: 4, succeeded: true),
        .init(completed: 2, total: 4, succeeded: true),
        .init(completed: 3, total: 4, succeeded: false),
        .init(completed: 4, total: 4, succeeded: false),
      ])
    #expect(results.map(\.sourceURL) == requests.map(\.sourceURL))
    #expect(results.filter(\.isSuccess).count == 2)
    #expect(
      results.filter {
        ($0.error as? ExportManager.ExportManagerError) == .cancelled
      }.count == 2)
    for (request, result) in zip(requests, results) {
      if result.isSuccess {
        #expect(try StandardImageDecoder.decode(request.destinationURL) == request.image)
      } else {
        #expect(!FileManager.default.fileExists(atPath: request.destinationURL.path))
      }
    }
    let outputNames = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(Set(outputNames) == Set(probe.completedFilenames))
  }

  @Test("A failed batch member preserves its destination and removes staging files")
  func batchFailurePreservesDestinationAndCleansStages() async throws {
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let existingURL = tempDir.appendingPathComponent("existing.png")
    let existingData = Data("existing destination".utf8)
    try existingData.write(to: existingURL)
    let outputURL = tempDir.appendingPathComponent("success.png")
    let image = makeTestImage()
    let parameters = ExportParameters(format: .png)
    let requests = [
      ExportManager.ExportRequest(
        sourceURL: tempDir.appendingPathComponent("failure.gray"),
        destinationURL: existingURL, image: makeGrayImage(), parameters: parameters),
      ExportManager.ExportRequest(
        sourceURL: tempDir.appendingPathComponent("success.png"),
        destinationURL: outputURL, image: image, parameters: parameters),
    ]
    let results = await ExportManager().exportBatch(requests: requests, maxConcurrent: 2)

    #expect(results.map(\.sourceURL) == requests.map(\.sourceURL))
    #expect(!results[0].isSuccess)
    #expect(results[1].isSuccess)
    #expect(try Data(contentsOf: existingURL) == existingData)
    #expect(try StandardImageDecoder.decode(outputURL) == image)
    let outputNames = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(Set(outputNames) == ["existing.png", "success.png"])
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

private final class ExportProgressProbe: @unchecked Sendable {
  struct Event: Equatable {
    let completed: Int
    let total: Int
    let succeeded: Bool
  }

  private let lock = NSLock()
  private var recorded: [Event] = []

  var events: [Event] { lock.withLock { recorded } }

  func record(_ completed: Int, _ total: Int, _ succeeded: Bool) {
    lock.withLock {
      recorded.append(.init(completed: completed, total: total, succeeded: succeeded))
    }
  }
}

/// The synchronous writer gate verifies overlapping worker execution without
/// relying on export durations. Its timeouts keep a serialized regression finite.
private final class ExportWriterProbe: @unchecked Sendable {
  private let condition = NSCondition()
  private let waitsForRelease: Bool
  private let delayedFilename: String?
  private let peerFilename: String?
  private var released = false
  private var started = 0
  private var active = 0
  private var maximumActive = 0
  private var completed: [String] = []

  init(
    waitsForRelease: Bool = false,
    delayedFilename: String? = nil,
    peerFilename: String? = nil
  ) {
    self.waitsForRelease = waitsForRelease
    self.delayedFilename = delayedFilename
    self.peerFilename = peerFilename
  }

  var startedCount: Int { condition.withLock { started } }
  var maximumActiveCount: Int { condition.withLock { maximumActive } }
  var completedFilenames: [String] { condition.withLock { completed } }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }

  func write(_ request: ExportManager.ExportRequest) throws {
    condition.lock()
    started += 1
    active += 1
    maximumActive = max(maximumActive, active)
    condition.broadcast()
    condition.unlock()
    var succeeded = false
    defer {
      condition.lock()
      active -= 1
      if succeeded { completed.append(request.destinationURL.lastPathComponent) }
      condition.broadcast()
      condition.unlock()
    }
    try waitBeforeWrite(filename: request.destinationURL.lastPathComponent)
    try request.image.write(
      to: request.destinationURL,
      format: request.parameters.format,
      parameters: request.parameters)
    succeeded = true
  }

  private func waitBeforeWrite(filename: String) throws {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(5)
    while waitsForRelease ? !released : started < 2 {
      guard condition.wait(until: deadline) else { throw ProbeError.writerDidNotStart }
    }
    if filename == delayedFilename, let peerFilename {
      while !completed.contains(peerFilename) {
        guard condition.wait(until: deadline) else { throw ProbeError.peerDidNotFinish }
      }
    }
  }

  private enum ProbeError: Error {
    case writerDidNotStart
    case peerDidNotFinish
  }
}
