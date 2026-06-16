import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Film-specific negative processing")
struct FilmNegativeProcessingTests {
  @Test("Default normalization uses zero black level and preserves measured ratios")
  func defaultNormalization() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [10_000, 20_000, 30_000])
    let flatField = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [40_000, 40_000, 40_000])

    let actual = FilmNegativeProcessing.normalizedTransmittance(
      image: image,
      flatField: flatField
    )

    assertEqual(actual, [0.25, 0.5, 0.75])
  }

  @Test("Black-level and flat-field normalization produces relative transmittance")
  func normalizedTransmittance() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [3_000, 5_000, 9_000, 11_000, 21_000, 41_000]
    )
    let flatField = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [11_000, 21_000, 41_000, 11_000, 21_000, 41_000]
    )
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 1_000, green: 1_000, red: 1_000)
    )

    let actual = FilmNegativeProcessing.normalizedTransmittance(
      image: image,
      flatField: flatField,
      parameters: parameters
    )

    assertEqual(actual, [0.2, 0.2, 0.2, 1, 1, 1])
  }

  @Test("Normalization applies distinct black levels in BGR channel order")
  func channelOrdering() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [3_000, 6_000, 10_000])
    let flatField = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [5_000, 10_000, 17_000])
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 1_000, green: 2_000, red: 3_000)
    )

    let actual = FilmNegativeProcessing.normalizedTransmittance(
      image: image,
      flatField: flatField,
      parameters: parameters
    )

    assertEqual(actual, [0.5, 0.5, 0.5])
  }

  @Test("Flat-field normalization removes spatial brightness variation")
  func spatialFlatFieldCorrection() {
    let image = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [2_000, 4_000, 8_000, 4_000, 8_000, 16_000])
    let flatField = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [4_000, 8_000, 16_000, 8_000, 16_000, 32_000])

    let actual = FilmNegativeProcessing.normalizedTransmittance(
      image: image,
      flatField: flatField
    )

    assertEqual(actual, [Double](repeating: 0.5, count: 6))
  }

  @Test("Transmittance clamps clipped and below-black samples")
  func transmittanceClamping() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [500, 20_000, 65_535])
    let flatField = UInt16Image(width: 1, height: 1, channels: 3, pixels: [1_000, 10_000, 30_000])
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 500, green: 500, red: 500),
      epsilon: 0.001
    )

    let actual = FilmNegativeProcessing.normalizedTransmittance(
      image: image,
      flatField: flatField,
      parameters: parameters
    )

    assertEqual(actual, [0.001, 1, 1])
  }

  @Test("Optical density clamps transmittance to safe physical bounds")
  func opticalDensityBounds() {
    let actual = FilmNegativeProcessing.opticalDensity(
      transmittance: [0, 0.001, 0.1, 1, 2],
      epsilon: 0.001
    )

    assertEqual(actual, [3, 3, 1, 0, 0])
  }

  @Test("Density is invariant to matched capture exposure changes")
  func densityExposureInvariance() {
    let lowExposureImage = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [2_000, 4_000, 6_000])
    let lowExposureFlat = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [6_000, 16_000, 26_000])
    let highExposureImage = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [3_000, 7_000, 11_000])
    let highExposureFlat = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [11_000, 31_000, 51_000])
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 1_000, green: 1_000, red: 1_000)
    )

    let lowDensity = FilmNegativeProcessing.opticalDensity(
      transmittance: FilmNegativeProcessing.normalizedTransmittance(
        image: lowExposureImage, flatField: lowExposureFlat, parameters: parameters)
    )
    let highDensity = FilmNegativeProcessing.opticalDensity(
      transmittance: FilmNegativeProcessing.normalizedTransmittance(
        image: highExposureImage, flatField: highExposureFlat, parameters: parameters)
    )

    assertEqual(lowDensity, highDensity)
    #expect(abs(lowDensity[0] - -log10(0.2)) < 1e-12)
    #expect(abs(lowDensity[1] - -log10(0.2)) < 1e-12)
  }

  @Test("Base density subtraction leaves rebate at zero and clamps negative density")
  func baseDensitySubtraction() {
    let actual = FilmNegativeProcessing.subtractBaseDensity(
      density: [0.8, 0.6, 0.4, 0.2, 0.3, 0.5],
      baseDensity: BGRChannelValues(blue: 0.2, green: 0.3, red: 0.5)
    )

    assertEqual(actual, [0.6, 0.3, 0, 0, 0, 0])
  }

  @Test("Base subtraction equals the density of the base-to-image transmittance ratio")
  func baseSubtractionDensityIdentity() {
    let imageTransmittance = [0.1, 0.2, 0.4]
    let baseTransmittance = [0.8, 0.7, 0.6]
    let imageDensity = FilmNegativeProcessing.opticalDensity(transmittance: imageTransmittance)
    let baseDensity = BGRChannelValues(
      blue: -log10(baseTransmittance[0]),
      green: -log10(baseTransmittance[1]),
      red: -log10(baseTransmittance[2])
    )

    let actual = FilmNegativeProcessing.subtractBaseDensity(
      density: imageDensity,
      baseDensity: baseDensity
    )
    let expected = zip(baseTransmittance, imageTransmittance).map { base, image in
      log10(base / image)
    }

    assertEqual(actual, expected)
  }

  @Test("Capture normalization parameters round trip through JSON")
  func parametersCodableRoundTrip() throws {
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 512, green: 768, red: 1_024),
      epsilon: 0.0001
    )

    let encoded = try JSONEncoder().encode(parameters)
    let decoded = try JSONDecoder().decode(CaptureNormalizationParameters.self, from: encoded)

    #expect(decoded == parameters)
  }

  @Test("Combined normalized density pipeline composes all first-slice stages")
  func combinedDensityPipeline() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [3_000, 5_000, 9_000])
    let flatField = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [11_000, 21_000, 41_000])
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 1_000, green: 1_000, red: 1_000)
    )
    let density = -log10(0.2)

    let actual = FilmNegativeProcessing.normalizedImageDensity(
      image: image,
      flatField: flatField,
      baseDensity: BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3),
      parameters: parameters
    )

    assertEqual(actual, [density - 0.1, density - 0.2, density - 0.3])
  }

  @Test("Manual rebate measurement returns BGR base density from selected rectangle")
  func manualRebateMeasurementBGRDensity() throws {
    let image = UInt16Image(
      width: 3, height: 2, channels: 3,
      pixels: [
        20_000, 30_000, 40_000, 30_000, 40_000, 50_000, 1_000, 1_000, 1_000,
        20_000, 30_000, 40_000, 30_000, 40_000, 50_000, 1_000, 1_000, 1_000,
      ])
    let flatField = UInt16Image(
      width: 3, height: 2, channels: 3,
      pixels: [UInt16](repeating: 60_000, count: 18))

    let measured = try FilmNegativeProcessing.measureBaseDensity(
      image: image,
      flatField: flatField,
      region: ImageRegion(x: 0, y: 0, width: 2, height: 2)
    )

    #expect(abs(measured.baseDensity.blue - -log10(25_000.0 / 60_000.0)) < 1e-12)
    #expect(abs(measured.baseDensity.green - -log10(35_000.0 / 60_000.0)) < 1e-12)
    #expect(abs(measured.baseDensity.red - -log10(45_000.0 / 60_000.0)) < 1e-12)
    #expect(measured.sampleCount == 4)
  }

  @Test("Manual rebate measurement resists dust and clipped outliers")
  func manualRebateMeasurementOutlierResistance() throws {
    let image = UInt16Image(
      width: 5, height: 1, channels: 3,
      pixels: [
        1, 1, 1,
        40_000, 40_000, 40_000,
        40_000, 40_000, 40_000,
        40_000, 40_000, 40_000,
        65_535, 65_535, 65_535,
      ])
    let flatField = UInt16Image(
      width: 5, height: 1, channels: 3,
      pixels: [UInt16](repeating: 50_000, count: 15))

    let measured = try FilmNegativeProcessing.measureBaseDensity(
      image: image,
      flatField: flatField,
      region: ImageRegion(x: 0, y: 0, width: 5, height: 1),
      trimFraction: 0.2
    )

    let expectedDensity = -log10(40_000.0 / 50_000.0)
    assertEqual(
      [measured.baseDensity.blue, measured.baseDensity.green, measured.baseDensity.red],
      [expectedDensity, expectedDensity, expectedDensity]
    )
    assertEqual(
      [
        measured.trimmedMeanTransmittance.blue,
        measured.trimmedMeanTransmittance.green,
        measured.trimmedMeanTransmittance.red,
      ],
      [0.8, 0.8, 0.8]
    )
    #expect(measured.confidence > 0.75)
  }

  @Test("Manual rebate measurement reports invalid and empty regions")
  func manualRebateMeasurementRegionValidation() throws {
    let image = UInt16Image(width: 2, height: 2, channels: 3, pixels: [UInt16](repeating: 100, count: 12))
    let flatField = UInt16Image(width: 2, height: 2, channels: 3, pixels: [UInt16](repeating: 1_000, count: 12))

    #expect(throws: FilmBaseMeasurementError.invalidRegion) {
      try FilmNegativeProcessing.measureBaseDensity(
        image: image,
        flatField: flatField,
        region: ImageRegion(x: 1, y: 1, width: 2, height: 1)
      )
    }
    #expect(throws: FilmBaseMeasurementError.emptyRegion) {
      try FilmNegativeProcessing.measureBaseDensity(
        image: image,
        flatField: flatField,
        region: ImageRegion(x: 0, y: 0, width: 0, height: 1)
      )
    }
  }

  @Test("Roll base remains stable across five measured frames")
  func rollProfileMedianBaseFromFiveFrames() throws {
    let measurements = [0.30, 0.31, 0.29, 0.305, 0.9].map { density in
      FilmBaseMeasurement(
        baseDensity: BGRChannelValues(blue: density, green: density + 0.1, red: density + 0.2),
        medianTransmittance: BGRChannelValues(
          blue: pow(10, -density), green: pow(10, -(density + 0.1)), red: pow(10, -(density + 0.2))),
        trimmedMeanTransmittance: BGRChannelValues(
          blue: pow(10, -density), green: pow(10, -(density + 0.1)), red: pow(10, -(density + 0.2))),
        sampleCount: 64,
        rejectedFraction: 0,
        confidence: 0.95
      )
    }

    let profile = RollProfile(
      filmStockID: "kodak-gold-200",
      captureProfileID: "copy-stand-a",
      measurements: measurements,
      exposureBias: 0.25,
      whiteBalanceCorrection: BGRChannelValues(blue: 1.01, green: 1, red: 0.99)
    )

    #expect(profile.measuredBaseDensity == BGRChannelValues(blue: 0.305, green: 0.405, red: 0.505))
    #expect(profile.measurementCount == 5)
  }

  @Test("Roll profile round trips through JSON")
  func rollProfileCodableRoundTrip() throws {
    let profile = RollProfile(
      filmStockID: "portra-400",
      captureProfileID: "lightbox-v1",
      measuredBaseDensity: BGRChannelValues(blue: 0.3, green: 0.4, red: 0.5),
      exposureBias: -0.1,
      whiteBalanceCorrection: BGRChannelValues(blue: 1.05, green: 1, red: 0.95)
    )

    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(RollProfile.self, from: encoded)

    #expect(decoded == profile)
  }

  @Test("Base density precedence favors roll, then frame, then defaults, then manual picker")
  func baseDensityPrecedence() {
    let manual = BGRChannelValues(blue: 0.1, green: 0.1, red: 0.1)
    let defaults = BGRChannelValues(blue: 0.2, green: 0.2, red: 0.2)
    let frame = BGRChannelValues(blue: 0.3, green: 0.3, red: 0.3)
    let roll = RollProfile(
      filmStockID: "stock",
      captureProfileID: "capture",
      measuredBaseDensity: BGRChannelValues(blue: 0.4, green: 0.4, red: 0.4)
    )

    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        rollProfile: roll,
        frameMeasurement: frame,
        defaultBaseDensity: defaults,
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: roll.measuredBaseDensity!, source: .measuredRoll)
    )
    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        frameMeasurement: frame,
        defaultBaseDensity: defaults,
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: frame, source: .measuredFrame)
    )
    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        defaultBaseDensity: defaults,
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: defaults, source: .stockCaptureDefault)
    )
    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: manual, source: .manualPicker)
    )
  }

  @Test("Classifier identifies orange-mask colour negative and selects RawTherapee preset")
  func classifierIdentifiesColourNegative() {
    let image = repeatedImage(
      width: 8,
      height: 8,
      bgr: [
        (blue: 11_000, green: 26_000, red: 42_000),
        (blue: 12_000, green: 27_000, red: 44_000),
        (blue: 10_000, green: 25_000, red: 41_000),
      ]
    )

    let classification = FilmNegativeProcessing.classifyFilmScan(image: image)

    #expect(classification.filmType == .colourNegative)
    #expect(classification.filmNegativePreset == .colourNegative)
    #expect(classification.confidence >= 0.45)
  }

  @Test("Classifier identifies low-chroma black and white negative")
  func classifierIdentifiesBlackAndWhiteNegative() {
    let image = repeatedImage(
      width: 8,
      height: 8,
      bgr: [
        (blue: 19_500, green: 20_000, red: 20_400),
        (blue: 30_000, green: 30_200, red: 30_100),
        (blue: 9_800, green: 10_000, red: 10_200),
      ]
    )

    let classification = FilmNegativeProcessing.classifyFilmScan(image: image)

    #expect(classification.filmType == .blackAndWhiteNegative)
    #expect(classification.filmNegativePreset == .blackAndWhite)
    #expect(classification.confidence >= 0.75)
  }

  @Test("Classifier leaves positive slide without film negative inversion")
  func classifierIdentifiesSlide() {
    let image = repeatedImage(
      width: 8,
      height: 8,
      bgr: [
        (blue: 28_000, green: 23_000, red: 18_000),
        (blue: 8_000, green: 27_000, red: 12_000),
        (blue: 34_000, green: 18_000, red: 31_000),
      ]
    )

    let classification = FilmNegativeProcessing.classifyFilmScan(image: image)

    #expect(classification.filmType == .slide)
    #expect(classification.filmNegativePreset == .off)
    #expect(classification.confidence >= 0.55)
  }

  private func assertEqual(_ actual: [Double], _ expected: [Double], tolerance: Double = 1e-12) {
    #expect(actual.count == expected.count)
    for index in actual.indices {
      #expect(abs(actual[index] - expected[index]) <= tolerance)
    }
  }

  private func repeatedImage(
    width: Int,
    height: Int,
    bgr samples: [(blue: UInt16, green: UInt16, red: UInt16)]
  ) -> UInt16Image {
    var pixels: [UInt16] = []
    pixels.reserveCapacity(width * height * 3)
    for index in 0..<(width * height) {
      let sample = samples[index % samples.count]
      pixels.append(sample.blue)
      pixels.append(sample.green)
      pixels.append(sample.red)
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }
}
