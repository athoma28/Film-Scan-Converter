import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Standard image decoding")
struct StandardImageDecoderTests {
  @Test("8-bit PNG decode matches Python cv2 loading and scaling")
  func decode8BitPNG() throws {
    let actual = try StandardImageDecoder.decode(
      FixtureLoader.fixtureURL("decode_png8", file: "input.png")
    )
    let expected = try FixtureLoader.loadExpected("decode_png8")

    #expect(actual == expected)
    #expect(actual.channels == 3)
  }

  @Test("8-bit BMP decode matches Python cv2 loading and scaling")
  func decode8BitBMP() throws {
    let actual = try StandardImageDecoder.decode(
      FixtureLoader.fixtureURL("decode_bmp8", file: "input.bmp")
    )
    let expected = try FixtureLoader.loadExpected("decode_bmp8")

    #expect(actual == expected)
    #expect(actual.channels == 3)
  }

  @Test("8-bit JPEG decode stays within documented Python cv2 tolerance")
  func decode8BitJPEG() throws {
    let actual = try StandardImageDecoder.decode(
      FixtureLoader.fixtureURL("decode_jpeg8", file: "input.jpg")
    )
    let expected = try FixtureLoader.loadExpected("decode_jpeg8")

    #expect(actual.width == expected.width)
    #expect(actual.height == expected.height)
    #expect(actual.channels == expected.channels)
    #expect(maximumDifference(actual.pixels, expected.pixels) <= 2_560)
    #expect(meanDifference(actual.pixels, expected.pixels) <= 512)
  }

  @Test("16-bit TIFF decode matches Python cv2 loading")
  func decode16BitTIFF() throws {
    let actual = try StandardImageDecoder.decode(
      FixtureLoader.fixtureURL("decode_tiff16", file: "input.tiff")
    )
    let expected = try FixtureLoader.loadExpected("decode_tiff16")

    #expect(actual == expected)
    #expect(actual.channels == 3)
  }

  @Test("8-bit grayscale PNG decode matches Python cv2 loading and scaling")
  func decode8BitGrayscalePNG() throws {
    let actual = try StandardImageDecoder.decode(
      FixtureLoader.fixtureURL("decode_grayscale_png8", file: "input.png")
    )
    let expected = try FixtureLoader.loadExpected("decode_grayscale_png8")

    #expect(actual == expected)
    #expect(actual.channels == 1)
  }

  @Test("RAW extensions do not enter the standard image decoder")
  func rejectRAWExtension() {
    #expect(throws: StandardImageDecoderError.self) {
      try StandardImageDecoder.decode(URL(fileURLWithPath: "/tmp/scan.raf"))
    }
  }

  @Test("Engine buffers create preview images without changing dimensions")
  func previewImage() throws {
    let decoded = try StandardImageDecoder.decode(
      FixtureLoader.fixtureURL("decode_png8", file: "input.png")
    )
    let preview = try #require(decoded.makePreviewCGImage())

    #expect(preview.width == decoded.width)
    #expect(preview.height == decoded.height)
  }

  private func maximumDifference(_ lhs: [UInt16], _ rhs: [UInt16]) -> UInt16 {
    zip(lhs, rhs).map { left, right in
      left >= right ? left - right : right - left
    }.max() ?? 0
  }

  private func meanDifference(_ lhs: [UInt16], _ rhs: [UInt16]) -> Double {
    let total = zip(lhs, rhs).reduce(0.0) { result, pair in
      result + Double(pair.0 >= pair.1 ? pair.0 - pair.1 : pair.1 - pair.0)
    }
    return total / Double(lhs.count)
  }
}
