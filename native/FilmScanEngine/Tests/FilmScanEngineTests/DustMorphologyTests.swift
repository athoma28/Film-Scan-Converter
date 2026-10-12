import Testing

@testable import FilmScanEngine

@Suite("Dust morphology composition")
struct DustMorphologyTests {
  @Test("Composed closing equals repeated cropped-window morphology for all small masks")
  func exhaustiveSmallMasksMatchRepeatedOracle() {
    for (width, height) in [(1, 1), (1, 5), (5, 1), (2, 3), (3, 2), (3, 3)] {
      for bits in 0..<(1 << (width * height)) {
        let source = (0..<(width * height)).map { bits & (1 << $0) == 0 ? UInt8(0) : 255 }
        for kernelSize in 1...8 {
          for iterations in 0...5 {
            let expected = repeatedClosing(
              source, width: width, height: height,
              kernelSize: kernelSize, iterations: iterations)
            let actual = DustDetection.closingBinaryMask(
              source, width: width, height: height,
              kernelSize: kernelSize, iterations: iterations)
            if actual != expected {
              Issue.record(
                "Mismatch at \(width)x\(height), bits \(bits), kernel \(kernelSize), iterations \(iterations)"
              )
              return
            }
          }
        }
      }
    }
  }

  @Test("Closing preserves neutral borders for narrow images, borders and interior holes")
  func boundaryMasksMatchRepeatedOracle() {
    for (width, height) in [(1, 17), (17, 1), (2, 13), (13, 2), (7, 11), (11, 7)] {
      let pixels = width * height
      let edge = (0..<pixels).map { index -> UInt8 in
        let x = index % width
        let y = index / width
        return x == 0 || y == 0 || x == width - 1 || y == height - 1 ? 255 : 0
      }
      var corner = [UInt8](repeating: 0, count: pixels)
      corner[0] = 255
      let cases = [
        [UInt8](repeating: 0, count: pixels), [UInt8](repeating: 255, count: pixels),
        edge, edge.map { 255 - $0 }, corner, corner.map { 255 - $0 },
        (0..<pixels).map { ($0 * 37 + $0 / width * 17) % 11 < 3 ? UInt8(255) : 0 },
      ]
      for source in cases {
        for kernelSize in [1, 2, 3, 4, 9, 20, 101] {
          for iterations in [0, 1, 2, 5, 8] {
            let expected = repeatedClosing(
              source, width: width, height: height,
              kernelSize: kernelSize, iterations: iterations)
            let actual = DustDetection.closingBinaryMask(
              source, width: width, height: height,
              kernelSize: kernelSize, iterations: iterations)
            #expect(actual == expected)
          }
        }
      }
    }
  }

  @Test("Huge iteration counts and kernels saturate without integer overflow")
  func oversizedClosingSaturatesSafely() {
    let sources: [[UInt8]] = [[0, 0, 0, 0, 0, 0], [0, 0, 255, 0, 0, 0]]
    for source in sources {
      let expected = [UInt8](repeating: source.contains(255) ? 255 : 0, count: source.count)
      for kernelSize in [2, 3, Int.max] {
        #expect(
          DustDetection.closingBinaryMask(
            source, width: 3, height: 2, kernelSize: kernelSize, iterations: Int.max)
            == expected)
      }
      for iterations in [Int.min, -1, 0] {
        #expect(
          DustDetection.closingBinaryMask(
            source, width: 3, height: 2, kernelSize: 3, iterations: iterations) == source)
      }
    }
  }

  @Test("Complete components retain contour-area filtering after queue storage reuse")
  func connectedMasksKeepContourAreaSemantics() {
    for (width, height, expectedCode) in [(257, 193, UInt16(0)), (257, 1, UInt16(255))] {
      let source = UInt16Image(
        width: width, height: height, channels: 3,
        pixels: [UInt16](repeating: 12_345, count: width * height * 3))
      // A constant scan thresholds to one full component. A filled rectangle
      // is rejected, but a one-pixel-wide line has zero contour area and stays.
      let mask = DustDetection.findMask(in: source)
      #expect(mask.pixels == [UInt16](repeating: expectedCode, count: width * height))
    }
  }

  /// Independent oracle: directly enumerate cropped neighborhoods instead of
  /// using integral sums or composing the radius. Reproduce the original pass
  /// sequence, with exterior pixels neutral for either operation.
  private func repeatedClosing(
    _ source: [UInt8], width: Int, height: Int, kernelSize: Int, iterations: Int
  ) -> [UInt8] {
    var result = source
    for dilating in [true, false] {
      for _ in 0..<iterations {
        let input = result
        let radius = kernelSize / 2
        for y in 0..<height {
          for x in 0..<width {
            var foreground = !dilating
            for ny in max(0, y - radius)..<min(height, y + radius + 1) {
              for nx in max(0, x - radius)..<min(width, x + radius + 1) {
                if dilating {
                  foreground = foreground || input[ny * width + nx] != 0
                } else {
                  foreground = foreground && input[ny * width + nx] != 0
                }
              }
            }
            result[y * width + x] = foreground ? 255 : 0
          }
        }
      }
    }
    return result
  }
}
