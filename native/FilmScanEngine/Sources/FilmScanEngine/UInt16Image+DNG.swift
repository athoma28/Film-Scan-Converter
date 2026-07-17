import CoreGraphics
import Dispatch
import Foundation

private final class DNGMutableBuffer<Element>: @unchecked Sendable {
  let baseAddress: UnsafeMutablePointer<Element>

  init(_ baseAddress: UnsafeMutablePointer<Element>) {
    self.baseAddress = baseAddress
  }
}

extension UInt16Image {
  func writeDNG(to url: URL) throws {
    _ = try writeDNGMeasured(to: url)
  }

  func writeDNGMeasured(to url: URL) throws -> ExportWriteMetrics {
    guard channels == 1 || channels == 3 else {
      throw ExportError.creationFailed
    }

    let writer = DNGWriter(width: width, height: height, channels: channels, pixels: pixels)
    return try writer.write(to: url)
  }
}

/// Writes a standards-valid, uncompressed LinearRaw DNG whose pixels are the
/// processed output of Film Scan Converter. The engine's rendered pixels are
/// display-referred sRGB, so the writer removes the sRGB transfer function and
/// records output-referred linear sRGB with the matching D65 color matrix.
private final class DNGWriter {
  private enum TIFFType: UInt16 {
    case byte = 1
    case ascii = 2
    case short = 3
    case long = 4
    case rational = 5
    case undefined = 7
    case signedRational = 10
  }

  private struct IFDEntry {
    let tag: UInt16
    let type: TIFFType
    let count: UInt32
    let value: Data
  }

  private static let sRGBToLinear16: [UInt16] = {
    (0...Int(UInt16.max)).map { encoded in
      let value = Double(encoded) / Double(UInt16.max)
      let linear = value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4)
      return UInt16((linear * Double(UInt16.max)).rounded())
    }
  }()

  private let width: Int
  private let height: Int
  private let channels: Int
  private let pixels: [UInt16]

  init(width: Int, height: Int, channels: Int, pixels: [UInt16]) {
    self.width = width
    self.height = height
    self.channels = channels
    self.pixels = pixels
  }

  func write(to url: URL) throws -> ExportWriteMetrics {
    let packingStart = ContinuousClock.now
    let imageStrip = buildLinearImageData()
    let header = buildHeader(stripByteCount: imageStrip.count)
    let packingSeconds = dngSeconds(packingStart.duration(to: .now))

    let writerStart = ContinuousClock.now
    let stagingURL = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }

    do {
      try header.write(to: stagingURL, options: .atomic)
      let handle = try FileHandle(forWritingTo: stagingURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: imageStrip)
      try handle.synchronize()

      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: stagingURL)
      } else {
        try FileManager.default.moveItem(at: stagingURL, to: url)
      }
    } catch {
      throw UInt16Image.ExportError.commitFailed(url, .dng, error)
    }

    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return ExportWriteMetrics(
      pixelPackingSeconds: packingSeconds,
      encodingFinalizationSeconds: dngSeconds(writerStart.duration(to: .now)),
      packedPixelBytes: imageStrip.count,
      outputBytes: values.fileSize ?? 0
    )
  }

  private func buildLinearImageData() -> Data {
    let outputChannels = channels == 1 ? 1 : 3
    let pixelCount = width * height
    var strip = Data(count: pixelCount * outputChannels * MemoryLayout<UInt16>.size)
    let sourcePixels = pixels
    let sourceChannels = channels
    let transfer = Self.sRGBToLinear16

    strip.withUnsafeMutableBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) else {
        return
      }
      let output = DNGMutableBuffer(baseAddress)
      let workerCount = pixelCount >= 1_000_000
        ? max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        : 1
      let pixelsPerWorker = (pixelCount + workerCount - 1) / workerCount

      DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
        let start = worker * pixelsPerWorker
        let end = min(start + pixelsPerWorker, pixelCount)
        guard start < end else { return }

        if sourceChannels == 3 {
          for pixelIndex in start..<end {
            let component = pixelIndex * 3
            output.baseAddress[component] = transfer[Int(sourcePixels[component + 2])].littleEndian
            output.baseAddress[component + 1] = transfer[Int(sourcePixels[component + 1])].littleEndian
            output.baseAddress[component + 2] = transfer[Int(sourcePixels[component])].littleEndian
          }
        } else {
          for pixelIndex in start..<end {
            output.baseAddress[pixelIndex] = transfer[Int(sourcePixels[pixelIndex])].littleEndian
          }
        }
      }
    }
    return strip
  }

  private func buildHeader(stripByteCount: Int) -> Data {
    var entries = makeEntries(stripOffset: 0, stripByteCount: stripByteCount)
    let ifdStart = 8
    let fixedIFDBytes = 2 + entries.count * 12 + 4
    let externalBytes = entries.reduce(into: 0) { total, entry in
      if entry.value.count > 4 {
        total += aligned(entry.value.count)
      }
    }
    let stripOffset = ifdStart + fixedIFDBytes + externalBytes
    entries = makeEntries(stripOffset: stripOffset, stripByteCount: stripByteCount)

    var header = Data()
    header.append(contentsOf: [0x49, 0x49])
    header.append(u16(42))
    header.append(u32(UInt32(ifdStart)))
    header.append(encodeIFD(entries, ifdStart: ifdStart))
    precondition(header.count == stripOffset, "DNG strip offset must match encoded header size")
    return header
  }

  private func encodeIFD(_ sourceEntries: [IFDEntry], ifdStart: Int) -> Data {
    let entries = sourceEntries.sorted { $0.tag < $1.tag }
    var directory = Data()
    var external = Data()
    let externalStart = ifdStart + 2 + entries.count * 12 + 4

    directory.append(u16(UInt16(entries.count)))
    for entry in entries {
      directory.append(u16(entry.tag))
      directory.append(u16(entry.type.rawValue))
      directory.append(u32(entry.count))
      if entry.value.count <= 4 {
        directory.append(entry.value)
        directory.append(Data(repeating: 0, count: 4 - entry.value.count))
      } else {
        directory.append(u32(UInt32(externalStart + external.count)))
        external.append(entry.value)
        if external.count % 2 != 0 {
          external.append(0)
        }
      }
    }
    directory.append(u32(0))
    directory.append(external)
    return directory
  }

  private func makeEntries(stripOffset: Int, stripByteCount: Int) -> [IFDEntry] {
    let sampleValues = [UInt16](repeating: 16, count: channels)
    let sampleFormats = [UInt16](repeating: 1, count: channels)
    var entries = [
      longs(254, [0]),
      longs(256, [UInt32(width)]),
      longs(257, [UInt32(height)]),
      shorts(258, sampleValues),
      shorts(259, [1]),
      shorts(262, [34892]),
      longs(273, [UInt32(stripOffset)]),
      shorts(274, [1]),
      shorts(277, [UInt16(channels)]),
      longs(278, [UInt32(height)]),
      longs(279, [UInt32(stripByteCount)]),
      rationals(282, [(72, 1)]),
      rationals(283, [(72, 1)]),
      shorts(284, [1]),
      ascii(305, "Film Scan Converter"),
      shorts(296, [2]),
      shorts(339, sampleFormats),
      bytes(50706, [1, 2, 0, 0]),
      bytes(50707, [1, 2, 0, 0]),
      ascii(50708, "Film Scan Converter Processed RGB"),
      shorts(50714, [UInt16](repeating: 0, count: channels)),
      longs(50717, [UInt32](repeating: UInt32(UInt16.max), count: channels)),
      longs(50719, [0, 0]),
      longs(50720, [UInt32(width), UInt32(height)]),
      rationals(50728, Array(repeating: (1, 1), count: channels)),
      signedRationals(50730, [(0, 1)]),
      shorts(50778, [21]),
      longs(50829, [0, 0, UInt32(height), UInt32(width)]),
      shorts(50879, [1]),
      longs(51110, [1]),
    ]

    if channels == 3 {
      // CIE XYZ (D65) to linear sRGB, stored in row-scan order as required
      // for ColorMatrix1's reference-XYZ-to-native-space transform.
      entries.append(signedRationals(50721, [
        (3_240_454, 1_000_000), (-1_537_139, 1_000_000), (-498_531, 1_000_000),
        (-969_266, 1_000_000), (1_876_011, 1_000_000), (41_556, 1_000_000),
        (55_643, 1_000_000), (-204_026, 1_000_000), (1_057_225, 1_000_000),
      ]))
    }
    return entries
  }

  private func bytes(_ tag: UInt16, _ values: [UInt8]) -> IFDEntry {
    IFDEntry(tag: tag, type: .byte, count: UInt32(values.count), value: Data(values))
  }

  private func ascii(_ tag: UInt16, _ value: String) -> IFDEntry {
    var data = Data(value.utf8)
    data.append(0)
    return IFDEntry(tag: tag, type: .ascii, count: UInt32(data.count), value: data)
  }

  private func shorts(_ tag: UInt16, _ values: [UInt16]) -> IFDEntry {
    var data = Data()
    for value in values { data.append(u16(value)) }
    return IFDEntry(tag: tag, type: .short, count: UInt32(values.count), value: data)
  }

  private func longs(_ tag: UInt16, _ values: [UInt32]) -> IFDEntry {
    var data = Data()
    for value in values { data.append(u32(value)) }
    return IFDEntry(tag: tag, type: .long, count: UInt32(values.count), value: data)
  }

  private func rationals(_ tag: UInt16, _ values: [(UInt32, UInt32)]) -> IFDEntry {
    var data = Data()
    for (numerator, denominator) in values {
      data.append(u32(numerator))
      data.append(u32(denominator))
    }
    return IFDEntry(tag: tag, type: .rational, count: UInt32(values.count), value: data)
  }

  private func signedRationals(_ tag: UInt16, _ values: [(Int32, Int32)]) -> IFDEntry {
    var data = Data()
    for (numerator, denominator) in values {
      data.append(i32(numerator))
      data.append(i32(denominator))
    }
    return IFDEntry(
      tag: tag,
      type: .signedRational,
      count: UInt32(values.count),
      value: data
    )
  }

  private func u16(_ value: UInt16) -> Data {
    Data(withUnsafeBytes(of: value.littleEndian) { Data($0) })
  }

  private func u32(_ value: UInt32) -> Data {
    Data(withUnsafeBytes(of: value.littleEndian) { Data($0) })
  }

  private func i32(_ value: Int32) -> Data {
    Data(withUnsafeBytes(of: value.littleEndian) { Data($0) })
  }

  private func aligned(_ byteCount: Int) -> Int {
    byteCount + byteCount % 2
  }
}

private func dngSeconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
