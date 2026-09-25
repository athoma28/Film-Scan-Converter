import Foundation
import Testing

@Suite("Compositor diagnostic marker decoding")
struct PreviewRevisionMarkerTests {
  @Test("Offset and scaled markers decode from padded BGRA rows")
  func markerGeometry() {
    for cell in [3, 6, 12] {
      for revision in [0, 1, 255, 256, 32_767, 65_535] {
        let (bytes, width, height, stride) = fixture(revision: revision, cell: cell)
        let decoded = bytes.withUnsafeBufferPointer {
          PreviewRevisionMarker.decode($0, width: width, height: height, bytesPerRow: stride)
        }
        #expect(decoded == revision)
      }
    }
  }

  @Test("Fractional horizontal placement keeps the bit pitch despite blended edges")
  func fractionalPlacement() {
    let (original, width, height, rowBytes) = fixture(revision: 1_337, cell: 6)
    for fraction in [0.25, 0.5, 0.75] {
      var shifted = original
      for y in 0..<height {
        for x in 1..<width {
          for channel in 0..<3 {
            let index = y * rowBytes + x * 4 + channel
            shifted[index] = UInt8(
              (Double(original[index]) * (1 - fraction)
                + Double(original[index - 4]) * fraction).rounded())
          }
        }
      }
      #expect(
        shifted.withUnsafeBufferPointer {
          PreviewRevisionMarker.decode($0, width: width, height: height, bytesPerRow: rowBytes)
        } == 1_337)
    }
  }

  @Test("A damaged bit cannot be reported as a different valid revision")
  func rejectsCorruption() {
    var (bytes, width, height, stride) = fixture(revision: 42, cell: 6)
    // Invert the first revision cell, retaining its original checksum.
    for y in 7..<19 {
      for x in (11 + 3 * 6)..<(11 + 4 * 6) {
        for channel in 0..<3 { bytes[y * stride + x * 4 + channel] ^= 255 }
      }
    }
    #expect(
      bytes.withUnsafeBufferPointer {
        PreviewRevisionMarker.decode($0, width: width, height: height, bytesPerRow: stride)
      } == nil)
  }

  @Test("Missing markers and undersized buffers remain missing observations")
  func missingObservation() {
    let bytes = [UInt8](repeating: 127, count: 400 * 30)
    #expect(
      bytes.withUnsafeBufferPointer {
        PreviewRevisionMarker.decode($0, width: 100, height: 30, bytesPerRow: 400)
      } == nil)
    #expect(
      bytes.withUnsafeBufferPointer {
        PreviewRevisionMarker.decode($0, width: 100, height: 31, bytesPerRow: 400)
      } == nil)
  }

  private func fixture(revision: Int, cell: Int) -> ([UInt8], Int, Int, Int) {
    let width = 28 * cell + 30
    let height = 32
    let rowBytes = width * 4 + 16
    var bytes = [UInt8](repeating: 127, count: rowBytes * height)
    let check = (revision & 255) ^ (revision >> 8) ^ 0xa5
    let packed = revision | (check << 16)
    var colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 255), (0, 255, 255), (255, 255, 0)]
    for bit in 0..<24 {
      let code: UInt8 = packed & (1 << bit) == 0 ? 0 : 255
      colors.append((code, code, code))
    }
    colors.append((255, 0, 0))
    for (index, color) in colors.enumerated() {
      for y in 7..<19 {
        for x in (11 + index * cell)..<(11 + (index + 1) * cell) {
          let offset = y * rowBytes + x * 4
          bytes[offset] = color.2
          bytes[offset + 1] = color.1
          bytes[offset + 2] = color.0
          bytes[offset + 3] = 255
        }
      }
    }
    return (bytes, width, height, rowBytes)
  }
}
