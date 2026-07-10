import Foundation

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

private final class DNGWriter {
  let width: Int
  let height: Int
  let channels: Int
  let pixels: [UInt16]
  let outputChannels: Int

  private struct IFDEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let value: IFDValue

    enum IFDValue {
      case short16(UInt16)
      case short32(UInt32)
      case rational(UInt32, UInt32)
      case ascii(String)
      case bytes([UInt8])
      case srational(Int32, Int32)
    }

    var totalDataSize: Int {
      switch value {
      case .short16: return 2
      case .short32: return 4
      case .rational: return 8
      case .ascii(let s): return s.count + 1
      case .bytes(let b): return b.count
      case .srational: return 8
      }
    }
  }

  init(width: Int, height: Int, channels: Int, pixels: [UInt16]) {
    self.width = width
    self.height = height
    self.channels = channels
    self.pixels = pixels
    self.outputChannels = channels == 1 ? 1 : 3
  }

  func write(to url: URL) throws -> ExportWriteMetrics {
    let packingStart = ContinuousClock.now
    let imageStrip = buildImageData()
    let packingSeconds = dngSeconds(packingStart.duration(to: .now))

    let writerStart = ContinuousClock.now
    let ifdEntries = buildIFDEntries(stripByteCount: imageStrip.count)
    let subIFDEntries = buildSubIFDEntries()
    let ifdSize = ifdDataBytes(ifdEntries)
    let subIfdSize = subIFDDataBytes(subIFDEntries)

    let stripOffset: UInt32 = UInt32(8 + Int(ifdSize) + 4)
    let subIfdStart: UInt32 = stripOffset + UInt32(imageStrip.count)
    let valueDataStart: UInt32 = subIfdStart + UInt32(subIfdSize)

    var data = Data(capacity: Int(valueDataStart) + imageStrip.count * 2 + 4096)

    data.append(contentsOf: [0x49, 0x49])
    data.append(u16LE(42))
    data.append(u32LE(8))
    data.append(encodeIFD(ifdEntries, nextIFDOffset: stripOffset))

    data.append(imageStrip)

    data.append(encodeIFD(subIFDEntries, nextIFDOffset: 0))

    appendInlineValues(ifdEntries, to: &data, startOffset: stripOffset)
    appendInlineValues(subIFDEntries, to: &data, startOffset: valueDataStart)

    try data.write(to: url)
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return ExportWriteMetrics(
      pixelPackingSeconds: packingSeconds,
      encodingFinalizationSeconds: dngSeconds(writerStart.duration(to: .now)),
      packedPixelBytes: imageStrip.count,
      outputBytes: values.fileSize ?? 0
    )
  }

  private func ifdDataBytes(_ entries: [IFDEntry]) -> UInt32 {
    UInt32(2 + entries.count * 12 + 4)
  }

  private func subIFDDataBytes(_ entries: [IFDEntry]) -> UInt32 {
    ifdDataBytes(entries)
  }

  private func encodeIFD(_ entries: [IFDEntry], nextIFDOffset: UInt32) -> Data {
    var d = Data()
    d.append(u16LE(UInt16(entries.count)))
    for entry in entries {
      d.append(u16LE(entry.tag))
      d.append(u16LE(entry.type))
      d.append(u32LE(entry.count))

      let rawValue = valueBytes(entry.value)
      if rawValue.count <= 4 {
        var padded = rawValue
        while padded.count < 4 { padded.append(0) }
        d.append(padded)
      } else {
        d.append(u32LE(0))
      }
    }
    d.append(u32LE(nextIFDOffset))
    return d
  }

  private func appendInlineValues(_ entries: [IFDEntry], to data: inout Data, startOffset: UInt32) {
    var offset = startOffset
    for entry in entries {
      let raw = valueBytes(entry.value)
      if raw.count > 4 {
        data.append(raw)
        offset = offset + UInt32(raw.count)
      }
    }
  }

  private func valueBytes(_ value: IFDEntry.IFDValue) -> Data {
    switch value {
    case .short16(let v): return u16LE(v)
    case .short32(let v): return u32LE(v)
    case .rational(let num, let den): return u32LE(num) + u32LE(den)
    case .ascii(let s): return s.data(using: .ascii)! + [0]
    case .bytes(let b): return Data(b)
    case .srational(let num, let den): return i32LE(num) + i32LE(den)
    }
  }

  private func u16LE(_ v: UInt16) -> Data {
    Data(withUnsafeBytes(of: v.littleEndian) { Data($0) })
  }

  private func u32LE(_ v: UInt32) -> Data {
    Data(withUnsafeBytes(of: v.littleEndian) { Data($0) })
  }

  private func i32LE(_ v: Int32) -> Data {
    Data(withUnsafeBytes(of: v.littleEndian) { Data($0) })
  }

  private func buildImageData() -> Data {
    let count = width * height * outputChannels
    var strip = Data(count: count * 2)
    strip.withUnsafeMutableBytes { ptr in
      let buf = ptr.bindMemory(to: UInt16.self)
      if channels == 3 {
        for pixelIndex in 0..<(width * height) {
          let ci = pixelIndex * 3
          buf[pixelIndex * 3] = pixels[ci + 2].littleEndian
          buf[pixelIndex * 3 + 1] = pixels[ci + 1].littleEndian
          buf[pixelIndex * 3 + 2] = pixels[ci].littleEndian
        }
      } else {
        for pixelIndex in 0..<(width * height) {
          buf[pixelIndex] = pixels[pixelIndex].littleEndian
        }
      }
    }
    return strip
  }

  private func buildIFDEntries(stripByteCount: Int) -> [IFDEntry] {
    let bps = 16
    let stripCount = UInt32(stripByteCount)

    return [
      IFDEntry(tag: 256, type: 4, count: 1, value: .short32(UInt32(width))),
      IFDEntry(tag: 257, type: 4, count: 1, value: .short32(UInt32(height))),
      IFDEntry(tag: 258, type: 3, count: UInt32(outputChannels), value: .bytes(
        (0..<outputChannels).map { _ in UInt8(bps & 0xFF) }
      )),
      IFDEntry(tag: 259, type: 3, count: 1, value: .short16(1)),
      IFDEntry(tag: 262, type: 3, count: 1, value: .short16(outputChannels == 1 ? 1 : 2)),
      IFDEntry(tag: 273, type: 4, count: 1, value: .short32(0)),
      IFDEntry(tag: 277, type: 3, count: 1, value: .short16(UInt16(outputChannels))),
      IFDEntry(tag: 278, type: 4, count: 1, value: .short32(UInt32(height))),
      IFDEntry(tag: 279, type: 4, count: 1, value: .short32(stripCount)),
      IFDEntry(tag: 282, type: 5, count: 1, value: .rational(72, 1)),
      IFDEntry(tag: 283, type: 5, count: 1, value: .rational(72, 1)),
      IFDEntry(tag: 284, type: 3, count: 1, value: .short16(1)),
      IFDEntry(tag: 296, type: 3, count: 1, value: .short16(2)),
      IFDEntry(tag: 306, type: 2, count: 20, value: .ascii("2024:01:01 00:00:00")),
      IFDEntry(tag: 330, type: 4, count: 1, value: .short32(0)),
      IFDEntry(tag: 33432, type: 2, count: 26, value: .ascii("Film Scan Converter (Swift)")),
      IFDEntry(tag: 34665, type: 4, count: 1, value: .short32(0)),
    ]
  }

  private func buildSubIFDEntries() -> [IFDEntry] {
    return [
      IFDEntry(tag: 50706, type: 1, count: 4, value: .bytes([1, 6, 0, 0])),
      IFDEntry(tag: 50707, type: 1, count: 4, value: .bytes([1, 6, 0, 0])),
      IFDEntry(tag: 50708, type: 2, count: 23, value: .ascii("Film Scan Converter")),
      IFDEntry(tag: 50740, type: 2, count: 38, value: .ascii("Processed RGB from camera film scan")),
      IFDEntry(tag: 50778, type: 3, count: 1, value: .short16(1)),
      IFDEntry(tag: 37386, type: 5, count: 1, value: .rational(10, 1)),
      IFDEntry(tag: 37387, type: 5, count: 1, value: .rational(10, 1)),
    ]
  }
}

private func dngSeconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
