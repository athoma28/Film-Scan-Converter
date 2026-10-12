import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Parallel photographic conversion")
struct PhotographicConversionTests {
  @Test("Bounded conversion matches serial tiles for every inversion branch and tone version")
  func conversionRetainsExactPixels() {
    let width = 997
    let height = 137
    // Cross both the worker threshold and the scratch-band boundary, including
    // an uneven final band and sensor-black / channel-extreme inputs.
    let pixels = (0..<(width * height * 3)).map { index in
      index % 23 < 3 ? UInt16(0) : UInt16(truncatingIfNeeded: index * 104_729 + 17)
    }
    let image = UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
    var cases = FilmBase.allCases.filter { $0 != .original }.map {
      $0.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
    }
    var calibrated = cases[0]
    calibrated.filmNegativeParams = .colourNegative
    cases.append(calibrated)
    var basic = calibrated
    basic.filmNegativeParams.enabled = false
    cases.append(basic)
    var basicMonochrome = cases[2]
    basicMonochrome.filmNegativeParams.enabled = false
    cases.append(basicMonochrome)

    for version in 2...4 {
      for var parameters in cases {
        parameters.photoAdjustments = .init(
          schemaVersion: version, exposureEV: 0.35, brightness: 0.1, contrast: 0.2,
          highlights: -0.15, shadows: 0.25, temperatureShiftMired: 8, tint: -0.1,
          saturation: 0.2, vibrance: 0.1, whites: 0.15, blacks: -0.1)
        let actual = FilmProcessing.correctedPreview(image: image, parameters: parameters)
        var expected: [UInt16] = []
        expected.reserveCapacity(actual.pixels.count)
        // Every tile stays below the parallel threshold. Keep the complete
        // sensor as the analysis authority, just as the production bands do.
        for firstRow in stride(from: 0, to: height, by: 25) {
          let tileHeight = min(25, height - firstRow)
          let first = firstRow * width * 3
          let end = (firstRow + tileHeight) * width * 3
          let tile = UInt16Image(
            width: width, height: tileHeight, channels: 3, pixels: Array(pixels[first..<end]))
          let corrected = FilmProcessing.correctedPhotographicPreview(
            image: image, parameters: parameters, preparedGeometry: tile)
          expected.append(contentsOf: corrected.pixels)
        }
        #expect(actual.width == width)
        #expect(actual.height == height)
        #expect(
          actual.pixels == expected,
          "Tone \(version), \(parameters.filmType), \(parameters.filmNegativeParams)")
      }
    }
  }
}
