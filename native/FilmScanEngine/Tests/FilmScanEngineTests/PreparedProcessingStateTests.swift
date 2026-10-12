import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Prepared CPU processing state")
struct PreparedProcessingStateTests {
  private static func toneCases(schemaVersion: Int) -> [PhotoAdjustmentParameters] {
    var cases: [PhotoAdjustmentParameters] = [.init(schemaVersion: schemaVersion)]
    let keys: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.exposureEV, \.brightness, \.contrast, \.highlights, \.shadows,
      \.whites, \.blacks, \.shadowFloor, \.midtoneLevel, \.highlightCeiling,
    ]
    for key in keys {
      for value in [-2.0, -0.5, 0.5, 2] {
        var parameters = PhotoAdjustmentParameters(schemaVersion: schemaVersion)
        parameters[keyPath: key] = value * (key == \.exposureEV ? 4 : 1)
        cases.append(parameters)
      }
    }
    cases.append(
      .init(
        schemaVersion: schemaVersion, exposureEV: -0.75, brightness: 0.2, contrast: 0.4,
        highlights: -0.3, shadows: 0.3, whites: 0.6, blacks: -0.4,
        shadowFloor: -0.3, midtoneLevel: 0.25, highlightCeiling: -0.2))
    cases.append(
      .init(
        schemaVersion: schemaVersion, exposureEV: 3.5, brightness: -0.6, contrast: -0.8,
        highlights: 0.7, shadows: -0.9, whites: -0.4, blacks: 0.7,
        shadowFloor: 0.3, midtoneLevel: -0.5, highlightCeiling: 0.4))
    return cases
  }

  @Test("Prepared tone is bit-identical to scalar arithmetic in every saved version")
  func toneMatchesScalar() {
    let boundaries = [-1.0, -0.0, 0, 1e-15, 0.0031308, 0.18, 0.98, 1, 1.00001, 2, 16]
    let inputs = boundaries + (0...128).map { PhotographicTone.decode(Double($0) / 128) }
    for version in 1...4 {
      for parameters in Self.toneCases(schemaVersion: version) {
        let prepared = PhotographicTone.Prepared(parameters)
        let firstMismatch = inputs.first { input in
          prepared.luminance(input).bitPattern
            != PhotographicTone.luminance(input, parameters: parameters).bitPattern
        }
        #expect(firstMismatch == nil, "Tone mismatch for \(parameters) at \(firstMismatch as Any)")
        for input in boundaries {
          let expected = PhotographicTone.apply(
            red: input, green: input * 0.37, blue: input * 1.2, parameters: parameters)
          let actual = prepared.apply(red: input, green: input * 0.37, blue: input * 1.2)
          #expect(actual.red.bitPattern == expected.red.bitPattern)
          #expect(actual.green.bitPattern == expected.green.bitPattern)
          #expect(actual.blue.bitPattern == expected.blue.bitPattern)
        }
      }
    }
  }

  @Test("Prepared calibrated inversion retains exact gains, knots, and extended tails")
  func inversionMatchesScalar() {
    let colorProfiles: [CalibratedColorNegativeProfile] = [
      .generic, .fuji400Fresh, .fuji200Expired, .cinestill800T, .harmanPhoenixII,
    ]
    let monoProfiles: [CalibratedMonochromeProfile] = [.generic, .shanghaiGP3]
    let medians: [BGRChannelValues?] = [
      nil, .init(blue: 20_441, green: 18_792, red: 27_054.5),
      .init(blue: 0, green: 1, red: 65_535),
    ]
    let inputs =
      stride(from: 0, through: 65_535, by: 257).map { Double($0) / 65_535 }
      + [-0.1, 0.00001, 0.1, 0.9, 1.00001, 1.5, 16]
    var profileCases: [FilmNegativeParams] = colorProfiles.map { profile in
      var parameters = FilmNegativeParams.colourNegative
      parameters.calibratedColorProfile = profile
      return parameters
    }
    profileCases += monoProfiles.map { profile in
      var parameters = FilmNegativeParams.blackAndWhite
      parameters.calibratedMonochromeProfile = profile
      return parameters
    }
    for profile in profileCases {
      for median in medians {
        for exposure in [-3.0, 0, 1.4] {
          var parameters = profile
          parameters.measuredMedians = median
          parameters.monochromeExposureEV = exposure
          let prepared = FilmNegativeProcessing.PreparedPhotographicInversion(params: parameters)
          for channel in 0..<3 {
            let firstMismatch = inputs.first { input in
              prepared.value(input, channel: channel).bitPattern
                != FilmNegativeProcessing.photographicCalibratedValue(
                  input, channel: channel, params: parameters
                ).bitPattern
            }
            #expect(
              firstMismatch == nil,
              "Inversion mismatch for \(parameters), channel \(channel), input \(firstMismatch as Any)"
            )
          }
        }
      }
    }
  }

  private static func colorCases(schemaVersion: Int) -> [PhotoAdjustmentParameters] {
    [
      .init(schemaVersion: schemaVersion),
      .init(schemaVersion: schemaVersion, temperatureShiftMired: 100),
      .init(schemaVersion: schemaVersion, temperatureShiftMired: -150, tint: 1.5),
      .init(schemaVersion: schemaVersion, tint: -1),
      .init(schemaVersion: schemaVersion, saturation: 1, vibrance: 0.5),
      .init(schemaVersion: schemaVersion, saturation: -2, vibrance: -1.5),
      .init(schemaVersion: schemaVersion, warmHueRecovery: 1),
      .init(
        schemaVersion: schemaVersion, temperatureShiftMired: 40, tint: 0.2,
        saturation: 0.5, vibrance: 0.4, warmHueRecovery: 0.65),
    ]
  }

  @Test("Prepared protected color retains exact recovery, protection, and gamut arithmetic")
  func protectedColorMatchesScalar() {
    let levels = [-4.0, -0.001, -0.0, 0, 1e-9, 0.02, 0.18, 0.5, 0.9, 1, 2, 16]
    var samples: [(blue: Double, green: Double, red: Double)] = []
    for blue in levels {
      for green in levels {
        for red in levels { samples.append((blue, green, red)) }
      }
    }
    samples += [(.nan, 0.2, 0.3), (.infinity, -.infinity, 0.4), (0.22, 0.47, 0.45)]
    for version in 1...4 {
      for parameters in Self.colorCases(schemaVersion: version) {
        let prepared = ProtectedColorAdjustment.Prepared(parameters)
        let firstMismatch = samples.firstIndex { sample in
          let expected = ProtectedColorAdjustment.apply(
            blue: sample.blue, green: sample.green, red: sample.red, parameters: parameters)
          let actual = prepared.apply(blue: sample.blue, green: sample.green, red: sample.red)
          return actual.blue.bitPattern != expected.blue.bitPattern
            || actual.green.bitPattern != expected.green.bitPattern
            || actual.red.bitPattern != expected.red.bitPattern
        }
        #expect(
          firstMismatch == nil,
          "Protected color mismatch for \(parameters) at sample \(firstMismatch as Any)")
      }
    }
  }

  @Test("Serial and parallel buffers retain the scalar tone and color sequence")
  func bufferOperationsMatchScalar() {
    for count in [17, 100_003] {
      for version in 1...4 {
        let parameters = PhotoAdjustmentParameters(
          schemaVersion: version, exposureEV: -0.75, brightness: 0.2, contrast: 0.4,
          highlights: -0.3, shadows: 0.3, temperatureShiftMired: 40,
          tint: 0.2, saturation: 0.5, vibrance: 0.4, warmHueRecovery: 0.65,
          whites: 0.6, blacks: -0.4, shadowFloor: -0.3, midtoneLevel: 0.25,
          highlightCeiling: -0.2)
        let pixels = (0..<(count * 3)).map { index in
          Double((index * 104_729 + 17) % 65_536) / 32_768 - 0.2
        }
        var image = RenderReadyLinearImage(width: count, height: 1, pixels: pixels)
        // Schema 1 uses the photographic scalar solely for this preparation guard;
        // the public buffer API retains its separate legacy schema-1 path.
        if parameters.usesPhotographicTone {
          image.applyLinearToneAdjustments(parameters)
        } else {
          image.applyPhotographicTone(PhotographicTone.Prepared(parameters))
        }
        image.applyProtectedColorAdjustments(parameters)
        let firstMismatch = (0..<count).first { index in
          let i = index * 3
          let tone = PhotographicTone.apply(
            red: pixels[i + 2], green: pixels[i + 1], blue: pixels[i], parameters: parameters)
          let expected = ProtectedColorAdjustment.apply(
            blue: tone.blue, green: tone.green, red: tone.red, parameters: parameters)
          return image.pixels[i].bitPattern != expected.blue.bitPattern
            || image.pixels[i + 1].bitPattern != expected.green.bitPattern
            || image.pixels[i + 2].bitPattern != expected.red.bitPattern
        }
        #expect(
          firstMismatch == nil,
          "Buffer mismatch at \(firstMismatch as Any), count \(count), schema \(version)")
      }
    }
  }
}
