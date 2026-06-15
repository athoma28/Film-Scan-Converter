import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Linear capture diagnostic report")
struct CaptureDiagnosticsTests {
  @Test("Report captures dimensions, channels, and source metadata")
  func basicMetadata() {
    let image = UInt16Image(width: 10, height: 5, channels: 3, pixels: [UInt16](repeating: 32_768, count: 150))

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 14
    )

    #expect(report.sourceKind == .raw)
    #expect(report.bitDepth == 14)
    #expect(report.width == 10)
    #expect(report.height == 5)
    #expect(report.channels == 3)
    #expect(report.perChannel.count == 3)
    #expect(report.warnings.isEmpty)
  }

  @Test("Per-channel diagnostics report correct min and max in BGR order")
  func perChannelMinMax() {
    let image = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [
        100, 50_000, 65_000,
        500, 20_000, 10_000,
      ]
    )

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .tiff,
      bitDepth: 16
    )

    #expect(report.perChannel.count == 3)
    #expect(report.perChannel[0].minimum == 100)
    #expect(report.perChannel[0].maximum == 500)
    #expect(report.perChannel[1].minimum == 20_000)
    #expect(report.perChannel[1].maximum == 50_000)
    #expect(report.perChannel[2].minimum == 10_000)
    #expect(report.perChannel[2].maximum == 65_000)
  }

  @Test("Per-channel clipping fractions are exact ratios for synthetic data")
  func clippingFractions() {
    let image = UInt16Image(
      width: 4, height: 1, channels: 3,
      pixels: [
        0, 32_768, 65_535,
        0, 32_768, 65_534,
        1, 32_768, 65_535,
        65_535, 32_768, 65_535,
      ]
    )

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16
    )

    #expect(report.perChannel[0].lowClippedFraction == 0.75)
    #expect(report.perChannel[0].highClippedFraction == 0.25)
    #expect(report.perChannel[1].lowClippedFraction == 0)
    #expect(report.perChannel[1].highClippedFraction == 0)
    #expect(report.perChannel[2].lowClippedFraction == 0)
    #expect(report.perChannel[2].highClippedFraction == 1.0)
  }

  @Test("Low clipping warning fires when fraction meets threshold")
  func lowClippedWarning() {
    let pixelsPerChannel = 10_000
    let totalPixels = pixelsPerChannel * 3
    var pixels = [UInt16](repeating: 32_768, count: totalPixels)
    for i in 0..<11 {
      pixels[i * 3] = 0
    }

    let image = UInt16Image(width: 10_000, height: 1, channels: 3, pixels: pixels)

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16
    )

    #expect(report.warnings.contains(.lowClipped))
    #expect(!report.warnings.contains(.highClipped))
    #expect(report.perChannel[0].lowClippedFraction == 0.0011)
  }

  @Test("Low clipping fraction barely below threshold does not fire warning")
  func lowClippedBelowThreshold() {
    let pixelsPerChannel = 10_000
    let totalPixels = pixelsPerChannel * 3
    var pixels = [UInt16](repeating: 32_768, count: totalPixels)
    for i in 0..<9 {
      pixels[i * 3] = 0
    }

    let image = UInt16Image(width: 10_000, height: 1, channels: 3, pixels: pixels)

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16
    )

    #expect(!report.warnings.contains(.lowClipped))
    #expect(report.perChannel[0].lowClippedFraction == 0.0009)
  }

  @Test("High clipping detection catches pixels at both ends")
  func highClippedDetection() {
    let image = UInt16Image(
      width: 1, height: 1, channels: 3,
      pixels: [65_534, 65_535, 0]
    )

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .png,
      bitDepth: 16
    )

    #expect(report.perChannel[0].highClippedFraction == 1.0)
    #expect(report.perChannel[1].highClippedFraction == 1.0)
    #expect(report.perChannel[2].highClippedFraction == 0)
    #expect(report.warnings.contains(.highClipped))
  }

  @Test("Source kind lossy detection fires for JPEG")
  func lossySourceWarning() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [100, 200, 300])

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .jpeg,
      bitDepth: 8
    )

    #expect(report.warnings.contains(.lossySource))
  }

  @Test("Source kind raw does not fire lossy warning")
  func rawSourceNoLossyWarning() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [100, 200, 300])

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 14
    )

    #expect(!report.warnings.contains(.lossySource))
  }

  @Test("Bit depth at or below 8 fires eightBitSource warning")
  func eightBitSourceWarning() throws {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [100, 200, 300])

    for depth in [1, 4, 8] {
      let report = CaptureDiagnostics.generate(
        image: image,
        sourceKind: .png,
        bitDepth: depth
      )
      #expect(report.warnings.contains(.eightBitSource), "Bit depth \(depth) should fire warning")
    }
  }

  @Test("Bit depth above 8 does not fire eightBitSource warning")
  func deepBitDepthNoWarning() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [100, 200, 300])

    for depth in [9, 10, 12, 14, 16] {
      let report = CaptureDiagnostics.generate(
        image: image,
        sourceKind: .raw,
        bitDepth: depth
      )
      #expect(!report.warnings.contains(.eightBitSource), "Bit depth \(depth) should not fire warning")
    }
  }

  @Test("Missing flat field flag produces warning")
  func missingFlatFieldWarning() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [100, 200, 300])

    let withFlag = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16,
      missingFlatField: true
    )
    #expect(withFlag.warnings.contains(.missingFlatField))

    let withoutFlag = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16,
      missingFlatField: false
    )
    #expect(!withoutFlag.warnings.contains(.missingFlatField))
  }

  @Test("Marked nonlinear flag produces warning")
  func markedNonlinearWarning() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [100, 200, 300])

    let withFlag = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16,
      markedNonlinear: true
    )
    #expect(withFlag.warnings.contains(.markedNonlinear))

    let withoutFlag = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16,
      markedNonlinear: false
    )
    #expect(!withoutFlag.warnings.contains(.markedNonlinear))
  }

  @Test("Single-channel grayscale image is handled correctly")
  func singleChannelHandling() {
    let image = UInt16Image(width: 2, height: 1, channels: 1, pixels: [0, 65_535])

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16
    )

    #expect(report.channels == 1)
    #expect(report.perChannel.count == 1)
    #expect(report.perChannel[0].minimum == 0)
    #expect(report.perChannel[0].maximum == 65_535)
    #expect(report.perChannel[0].lowClippedFraction == 0.5)
    #expect(report.perChannel[0].highClippedFraction == 0.5)
    #expect(report.warnings.contains(.lowClipped))
    #expect(report.warnings.contains(.highClipped))
  }

  @Test("Channel isolation: clipping in one channel does not affect others")
  func channelIsolation() {
    let image = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [
        0, 32_768, 65_535,
        1, 32_768, 65_534,
      ]
    )

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 16
    )

    #expect(report.perChannel[0].lowClippedFraction == 1.0)
    #expect(report.perChannel[0].highClippedFraction == 0)
    #expect(report.perChannel[1].lowClippedFraction == 0)
    #expect(report.perChannel[1].highClippedFraction == 0)
    #expect(report.perChannel[2].lowClippedFraction == 0)
    #expect(report.perChannel[2].highClippedFraction == 1.0)
  }

  @Test("Clean 16-bit linear image produces no warnings")
  func cleanLinearNoWarnings() {
    var pixels = [UInt16](repeating: 0, count: 9)
    for i in 0..<3 {
      for j in 0..<3 {
        pixels[i * 3 + j] = UInt16(100 + i * 10 + j)
      }
    }

    let image = UInt16Image(width: 3, height: 1, channels: 3, pixels: pixels)

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .raw,
      bitDepth: 14
    )

    #expect(report.warnings.isEmpty)
    #expect(report.perChannel[0].minimum > 0)
    #expect(report.perChannel[0].maximum < 65_535)
  }

  @Test("Report round trips through JSON encoding and decoding")
  func codableRoundTrip() throws {
    let image = UInt16Image(width: 2, height: 1, channels: 3, pixels: [0, 32_768, 65_535, 1, 32_768, 65_534])

    let report = CaptureDiagnostics.generate(
      image: image,
      sourceKind: .jpeg,
      bitDepth: 8,
      missingFlatField: true,
      markedNonlinear: false
    )

    let encoded = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(CaptureDiagnosticReport.self, from: encoded)

    #expect(decoded == report)
    #expect(decoded.sourceKind == .jpeg)
    #expect(decoded.bitDepth == 8)
    #expect(decoded.warnings.contains(.lossySource))
    #expect(decoded.warnings.contains(.eightBitSource))
    #expect(decoded.warnings.contains(.missingFlatField))
    #expect(decoded.warnings.contains(.lowClipped))
    #expect(decoded.warnings.contains(.highClipped))
    #expect(!decoded.warnings.contains(.markedNonlinear))
  }

  @Test("CaptureInputKind round trips through JSON")
  func inputKindCoding() throws {
    for kind in [CaptureInputKind.raw, .tiff, .jpeg, .png, .other] {
      let encoded = try JSONEncoder().encode(kind)
      let decoded = try JSONDecoder().decode(CaptureInputKind.self, from: encoded)
      #expect(decoded == kind)
    }
  }

  @Test("CaptureWarning all cases round trip through JSON")
  func warningCoding() throws {
    for warning in CaptureWarning.allCases {
      let encoded = try JSONEncoder().encode(warning)
      let decoded = try JSONDecoder().decode(CaptureWarning.self, from: encoded)
      #expect(decoded == warning)
    }
  }
}
