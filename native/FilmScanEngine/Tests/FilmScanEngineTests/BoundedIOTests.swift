import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Bounded stack and DNG I/O")
struct BoundedIOTests {
  @Test("Stored stacks keep the reference in memory and preserve capture indices")
  func referenceIsNotSpooled() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reference = texturedImage()
    do {
      let stack = try StoredScanStack(temporaryDirectory: directory)
      try stack.append(reference)
      let storage = try #require(contents(directory).first)
      #expect(try contents(storage).isEmpty)
      #expect(throws: ScanStackError.insufficientImages) { try stack.finish(mode: .noiseReduction) }

      try stack.append(reference)
      let files = try contents(storage)
      #expect(files.map(\.lastPathComponent) == ["1.pixels"])
      #expect(try Data(contentsOf: files[0]).count == reference.pixels.count * 2)
      #expect(
        throws: ScanStackError.incompatibleDimensions(
          index: 2, expectedWidth: 96, expectedHeight: 72, actualWidth: 48, actualHeight: 36)
      ) {
        try stack.append(reference.resized(width: 48, height: 36))
      }
      try stack.append(reference)
      #expect(try contents(storage).map(\.lastPathComponent).sorted() == ["1.pixels", "2.pixels"])

      let result = try stack.finish(mode: .noiseReduction, bandComponentLimit: 96 * 3 * 3 * 5)
      let expected = try MultiScanStacker.combine(
        images: [reference, reference, reference], mode: .noiseReduction)
      #expect(result == expected)
    }
    #expect(try contents(directory).isEmpty)
  }

  @Test("A truncated stored capture fails and its temporary directory is cleaned")
  func storedShortReadCleanup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reference = texturedImage()
    do {
      let stack = try StoredScanStack(temporaryDirectory: directory)
      try stack.append(reference)
      try stack.append(reference)
      let storage = try #require(contents(directory).first)
      let capture = try #require(contents(storage).first)
      let handle = try FileHandle(forWritingTo: capture)
      try handle.truncate(atOffset: 2)
      try handle.close()
      #expect(throws: CocoaError.self) { try stack.finish(mode: .hdr) }
    }
    #expect(try contents(directory).isEmpty)
  }

  @Test(
    "Banded DNG preserves every UInt16 input, single-strip tags, and total-byte metrics",
    arguments: [1, 3])
  func exactDNGCodes(channels: Int) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = codeImage(width: 257, height: 257, channels: channels)
    let url = directory.appendingPathComponent("codes.dng")
    var writes: [Int] = []
    let metrics = try source.writeDNGMeasured(to: url, packingBufferByteLimit: 4_097) { byteCount in
      writes.append(byteCount)
    }
    let data = try Data(contentsOf: url)
    let tags = tiffEntries(data)
    let stripOffset = try #require(tags[273])
    #expect(tags[278] == source.height)
    #expect(tags[279] == source.pixels.count * 2)
    #expect(tags[277] == channels)
    #expect(data.suffix(from: stripOffset) == linearByteOracle(source))
    #expect(metrics.packedPixelBytes == source.pixels.count * 2)
    #expect(metrics.outputBytes == data.count)
    #expect(metrics.pixelPackingSeconds >= 0 && metrics.encodingFinalizationSeconds >= 0)
    let bands = Array(writes.dropFirst())
    #expect(bands.count > 1)
    #expect(bands.allSatisfy { $0 <= 4_097 && $0 % (channels * 2) == 0 })
    #expect(bands.last! < bands.first!)
    #expect(bands.reduce(0, +) == metrics.packedPixelBytes)
  }

  @Test(
    "DNG parallel bands and scalar tails preserve RGB/gray codes without changing the source",
    arguments: [1, 3])
  func parallelDNGBandAndScalarTail(channels: Int) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = codeImage(width: 257, height: 513, channels: channels)
    let sourcePixelBytes = source.pixels.withUnsafeBytes { Data($0) }
    let bytesPerPixel = channels * MemoryLayout<UInt16>.stride
    let parallelBandPixels = 100_003
    let url = directory.appendingPathComponent("parallel-codes.dng")
    var writes: [Int] = []
    let metrics = try source.writeDNGMeasured(
      to: url, packingBufferByteLimit: parallelBandPixels * bytesPerPixel
    ) { byteCount in
      writes.append(byteCount)
    }

    let data = try Data(contentsOf: url)
    let tags = tiffEntries(data)
    let stripOffset = try #require(tags[273])
    #expect(data.suffix(from: stripOffset) == linearByteOracle(source))
    #expect(source.pixels.withUnsafeBytes { Data($0) } == sourcePixelBytes)
    #expect(metrics.packedPixelBytes == source.pixels.count * MemoryLayout<UInt16>.stride)
    #expect(metrics.outputBytes == data.count)
    #expect(metrics.pixelPackingSeconds >= 0 && metrics.encodingFinalizationSeconds >= 0)
    let bands = Array(writes.dropFirst())
    #expect(
      bands == [
        parallelBandPixels * bytesPerPixel,
        (source.width * source.height - parallelBandPixels) * bytesPerPixel,
      ])
    #expect(bands.reduce(0, +) == metrics.packedPixelBytes)
  }

  @Test("Default DNG packing reuses a bounded buffer and writes a final partial band")
  func defaultDNGBandLimit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = codeImage(width: 4_096, height: 700, channels: 3)
    let url = directory.appendingPathComponent("bounded.dng")
    var writes: [Int] = []
    let metrics = try source.writeDNGMeasured(to: url) { byteCount in
      writes.append(byteCount)
    }
    let bands = Array(writes.dropFirst())
    #expect(bands.count == 2)
    #expect(bands.allSatisfy { $0 <= 16 * 1_024 * 1_024 })
    #expect(bands.last! < bands.first!)
    #expect(bands.reduce(0, +) == source.pixels.count * 2)
    #expect(metrics.packedPixelBytes == source.pixels.count * 2)
  }

  @Test("Failed DNG writes remove staging bytes and preserve an existing destination")
  func dngWriteFailureCleanup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("existing.dng")
    let original = Data("existing destination".utf8)
    try original.write(to: destination)
    let source = codeImage(width: 17, height: 13, channels: 3)
    var writes = 0
    #expect(throws: UInt16Image.ExportError.self) {
      try source.writeDNGMeasured(to: destination, packingBufferByteLimit: 96) { _ in
        writes += 1
        if writes == 3 { throw CocoaError(.fileWriteOutOfSpace) }
      }
    }
    #expect(writes == 3)
    #expect(try Data(contentsOf: destination) == original)
    #expect(try contents(directory).map(\.lastPathComponent) == [destination.lastPathComponent])
  }

  @Test("Cancellation between DNG bands removes staging bytes without committing")
  func dngCancellationCleanup() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("cancelled.dng")
    let original = Data("keep this file".utf8)
    try original.write(to: destination)
    let source = codeImage(width: 17, height: 13, channels: 3)
    let task = Task.detached {
      var writes = 0
      return try source.writeDNGMeasured(to: destination, packingBufferByteLimit: 96) { _ in
        writes += 1
        if writes == 3 { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: destination) == original)
    #expect(try contents(directory).map(\.lastPathComponent) == [destination.lastPathComponent])
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func contents(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
  }

  private func codeImage(width: Int, height: Int, channels: Int) -> UInt16Image {
    UInt16Image(
      width: width, height: height, channels: channels,
      pixels: (0..<(width * height * channels)).map {
        UInt16(truncatingIfNeeded: $0 &* 40_503 &+ 173)
      })
  }

  private func texturedImage() -> UInt16Image {
    let width = 96
    let height = 72
    let pixels = (0..<(width * height * 3)).map { index in
      let x = Double((index / 3) % width)
      let y = Double(index / (3 * width))
      let value = 0.45 + 0.17 * sin(x * 0.27 + y * 0.11) + 0.13 * cos(y * 0.31 - x * 0.07)
      return UInt16((value * 65_535).rounded())
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private func linearByteOracle(_ image: UInt16Image) -> Data {
    var result = Data()
    result.reserveCapacity(image.pixels.count * 2)
    for index in 0..<(image.width * image.height) {
      for channel in 0..<image.channels {
        let encoded =
          Double(image.pixels[index * image.channels + image.channels - 1 - channel]) / 65_535
        let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        let value = UInt16((linear * 65_535).rounded())
        result.append(UInt8(truncatingIfNeeded: value))
        result.append(UInt8(truncatingIfNeeded: value >> 8))
      }
    }
    return result
  }

  private func tiffEntries(_ data: Data) -> [Int: Int] {
    let bytes = [UInt8](data)
    func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
    let directory = u32(4)
    var result: [Int: Int] = [:]
    for entry in 0..<u16(directory) {
      let offset = directory + 2 + entry * 12
      if u32(offset + 4) == 1 { result[u16(offset)] = u32(offset + 8) }
    }
    return result
  }
}
