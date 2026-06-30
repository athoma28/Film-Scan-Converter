import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Film-specific negative processing")
struct FilmNegativeProcessingTests {
  @Test("Rec.2020 working-space matrices round trip linear sRGB")
  func rec2020WorkingSpaceRoundTrip() {
    let source = (red: 0.82, green: 0.31, blue: 0.07)
    let working = FilmNegativeProcessing.linearSRGBToRec2020(
      red: source.red, green: source.green, blue: source.blue)
    let restored = FilmNegativeProcessing.linearRec2020ToSRGB(
      red: working.red, green: working.green, blue: working.blue)
    #expect(abs(restored.red - source.red) < 0.000001)
    #expect(abs(restored.green - source.green) < 0.000001)
    #expect(abs(restored.blue - source.blue) < 0.000001)
  }
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
      rollID: "roll-001",
      filmStockID: FilmStockProfileID(rawValue: "kodak-gold-200"),
      captureProfileID: CaptureProfileID(rawValue: "copy-stand-a"),
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
      rollID: "roll-002",
      filmStockID: FilmStockProfileID(rawValue: "portra-400"),
      captureProfileID: CaptureProfileID(rawValue: "lightbox-v1"),
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
    let automatic = BGRChannelValues(blue: 0.25, green: 0.25, red: 0.25)
    let frame = BGRChannelValues(blue: 0.3, green: 0.3, red: 0.3)
    let roll = RollProfile(
      rollID: "roll-003",
      filmStockID: FilmStockProfileID(rawValue: "stock"),
      captureProfileID: CaptureProfileID(rawValue: "capture"),
      measuredBaseDensity: BGRChannelValues(blue: 0.4, green: 0.4, red: 0.4)
    )

    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        rollProfile: roll,
        frameMeasurement: frame,
        automaticBaseDensity: automatic,
        defaultBaseDensity: defaults,
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: roll.measuredBaseDensity!, source: .measuredRoll)
    )
    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        frameMeasurement: frame,
        automaticBaseDensity: automatic,
        defaultBaseDensity: defaults,
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: frame, source: .measuredFrame)
    )
    #expect(
      FilmNegativeProcessing.resolveBaseDensity(
        automaticBaseDensity: automatic,
        defaultBaseDensity: defaults,
        manualBaseDensity: manual
      ) == ResolvedBaseDensity(baseDensity: automatic, source: .automaticEstimate)
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

  @Test("Automatic rebate estimator returns the brightest top border")
  func automaticRebateEstimatorFindsTopBorder() throws {
    let image = borderedImage(width: 10, height: 10, top: 50_000, center: 25_000)
    let flatField = UInt16Image(
      width: 10, height: 10, channels: 3,
      pixels: [UInt16](repeating: 60_000, count: 10 * 10 * 3))

    let candidates = FilmNegativeProcessing.automaticRebateCandidates(
      image: image,
      flatField: flatField,
      edgeFraction: 0.1
    )

    let first = try #require(candidates.first)
    #expect(first.region == ImageRegion(x: 0, y: 0, width: 10, height: 1))
    #expect(first.confidence > 0.9)
    #expect(abs(first.measurement.baseDensity.blue - -log10(50_000.0 / 60_000.0)) < 1e-12)
  }

  @Test("Automatic rebate estimator handles vertical edge rebates")
  func automaticRebateEstimatorFindsLeftBorder() throws {
    let image = borderedImage(width: 10, height: 10, left: 52_000, center: 25_000)
    let flatField = UInt16Image(
      width: 10, height: 10, channels: 3,
      pixels: [UInt16](repeating: 60_000, count: 10 * 10 * 3))

    let candidates = FilmNegativeProcessing.automaticRebateCandidates(
      image: image,
      flatField: flatField,
      edgeFraction: 0.1
    )

    let first = try #require(candidates.first)
    #expect(first.region == ImageRegion(x: 0, y: 0, width: 1, height: 10))
    #expect(first.confidence > 0.9)
  }

  @Test("Automatic rebate estimator rejects borderless frames")
  func automaticRebateEstimatorRejectsBorderlessFrame() {
    let image = UInt16Image(
      width: 10, height: 10, channels: 3,
      pixels: [UInt16](repeating: 35_000, count: 10 * 10 * 3))
    let flatField = UInt16Image(
      width: 10, height: 10, channels: 3,
      pixels: [UInt16](repeating: 60_000, count: 10 * 10 * 3))

    let candidates = FilmNegativeProcessing.automaticRebateCandidates(
      image: image,
      flatField: flatField,
      edgeFraction: 0.1
    )

    #expect(candidates.isEmpty)
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

  @Test("Weak same-roll prior only breaks an ambiguous classification")
  func classifierUsesWeakSameRollPriorForAmbiguousScan() {
    let ambiguous = repeatedImage(
      width: 8,
      height: 8,
      bgr: [
        (blue: 20_000, green: 23_600, red: 27_800),
        (blue: 18_000, green: 21_200, red: 25_000),
      ]
    )

    let withoutPrior = FilmNegativeProcessing.classifyFilmScan(image: ambiguous)
    let withPrior = FilmNegativeProcessing.classifyFilmScan(
      image: ambiguous,
      weakPrior: .colourNegative
    )

    #expect(withoutPrior.filmType == .slide)
    #expect(withoutPrior.confidence < 0.65)
    #expect(withPrior.filmType == .colourNegative)
    #expect(withPrior.filmNegativePreset == .colourNegative)
    #expect(withPrior.confidence == withoutPrior.confidence)
  }

  @Test("Strong slide and black-and-white evidence override a same-roll prior")
  func classifierKeepsStrongEvidenceOverSameRollPrior() {
    let slide = repeatedImage(
      width: 8,
      height: 8,
      bgr: [
        (blue: 34_000, green: 18_000, red: 12_000),
        (blue: 9_000, green: 29_000, red: 15_000),
      ]
    )
    let blackAndWhite = repeatedImage(
      width: 8,
      height: 8,
      bgr: [
        (blue: 19_900, green: 20_000, red: 20_100),
        (blue: 30_100, green: 30_000, red: 29_900),
      ]
    )

    #expect(
      FilmNegativeProcessing.classifyFilmScan(
        image: slide,
        weakPrior: .colourNegative
      ).filmType == .slide
    )
    #expect(
      FilmNegativeProcessing.classifyFilmScan(
        image: blackAndWhite,
        weakPrior: .colourNegative
      ).filmType == .blackAndWhiteNegative
    )
  }

  @Test("Generic C-41 identity profile maps zero density to unity and unit density to 10")
  func genericC41IdentityProfile() {
    let density: [Double] = [0, 0, 0, 0.5, 0.5, 0.5, 1.0, 1.0, 1.0]

    let scene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: density,
      profile: .identity
    )

    assertEqual(scene, [1, 1, 1, pow(10, 0.5), pow(10, 0.5), pow(10, 0.5), 10, 10, 10])
  }

  @Test("Generic C-41 applies per-channel slopes and offsets")
  func genericC41ChannelSlopesAndOffsets() {
    let density: [Double] = [0.2, 0.4, 0.6]
    let profile = GenericC41Profile(
      densitySlope: BGRChannelValues(blue: 2.0, green: 1.5, red: 1.0),
      densityOffset: BGRChannelValues(blue: -0.1, green: 0, red: 0.1)
    )

    let scene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: density,
      profile: profile
    )

    #expect(scene.count == 3)
    #expect(abs(scene[0] - pow(10, 2.0 * 0.2 - 0.1)) < 1e-12)
    #expect(abs(scene[1] - pow(10, 1.5 * 0.4)) < 1e-12)
    #expect(abs(scene[2] - pow(10, 1.0 * 0.6 + 0.1)) < 1e-12)
  }

  @Test("Generic C-41 scene estimate is monotonic in each channel")
  func genericC41Monotonicity() {
    let density: [Double] = [0.1, 0.2, 0.3, 0.9, 1.0, 1.1]
    let profile = GenericC41Profile(
      densitySlope: BGRChannelValues(blue: 2.0, green: 1.0, red: 0.5)
    )

    let scene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: density,
      profile: profile
    )

    #expect(scene[0] < scene[3])
    #expect(scene[1] < scene[4])
    #expect(scene[2] < scene[5])
  }

  @Test("Generic C-41 slope respects BGR channel isolation")
  func genericC41ChannelIsolation() {
    let density: [Double] = [0.3, 0.3, 0.3]
    let blueProfile = GenericC41Profile(
      densitySlope: BGRChannelValues(blue: 3.0, green: 1.0, red: 1.0)
    )
    let greenProfile = GenericC41Profile(
      densitySlope: BGRChannelValues(blue: 1.0, green: 3.0, red: 1.0)
    )

    let blueScene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: density,
      profile: blueProfile
    )
    let greenScene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: density,
      profile: greenProfile
    )

    #expect(blueScene[0] > blueScene[1])
    #expect(blueScene[2] == greenScene[2])
    #expect(greenScene[1] > greenScene[0])
  }

  @Test("Generic C-41 clamps scene estimate for extreme density values")
  func genericC41ExtremeDensityBounds() {
    let zeroDensity: [Double] = [0, 0, 0]
    let highDensity: [Double] = [3, 3, 3]

    let zeroScene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: zeroDensity
    )
    let highScene = FilmNegativeProcessing.genericC41SceneEstimate(
      baseSubtractedDensity: highDensity
    )

    assertEqual(zeroScene, [1, 1, 1])
    #expect(highScene[0] > zeroScene[0])
    #expect(highScene[1] > zeroScene[1])
    #expect(highScene[2] > zeroScene[2])
  }

  @Test("Scene exposure normalization scales by reciprocal of median green")
  func sceneExposureNormalizationMedian() {
    let scene: [Double] = [1, 2, 3, 4, 5, 6]
    let normalized = FilmNegativeProcessing.normalizeSceneExposure(sceneLinear: scene)

    let greenValues = [2.0, 5.0]
    let medianGreen = (greenValues[0] + greenValues[1]) / 2.0
    let scale = 1.0 / medianGreen
    let expected = scene.map { $0 * scale }
    assertEqual(normalized, expected)
  }

  @Test("Scene exposure normalization with zero median green is identity")
  func sceneExposureNormalizationZeroMedian() {
    let scene: [Double] = [1, 0, 3, 4, 0, 6]
    let normalized = FilmNegativeProcessing.normalizeSceneExposure(sceneLinear: scene)

    #expect(normalized == scene)
  }

  @Test("Generic C-41 profile round trips through JSON")
  func genericC41ProfileCodableRoundTrip() throws {
    let profile = GenericC41Profile(
      densitySlope: BGRChannelValues(blue: 1.8, green: 1.2, red: 0.9),
      densityOffset: BGRChannelValues(blue: -0.05, green: 0.1, red: 0.05)
    )

    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(GenericC41Profile.self, from: encoded)

    #expect(decoded == profile)
  }

  @Test("Composed density-to-scene pipeline converts capture to scene-linear values")
  func densityToSceneLinearPipeline() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [3_000, 5_000, 9_000])
    let flatField = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [11_000, 21_000, 41_000])
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 1_000, green: 1_000, red: 1_000)
    )
    let baseDensity = BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3)

    let scene = FilmNegativeProcessing.densityToSceneLinear(
      image: image,
      flatField: flatField,
      baseDensity: baseDensity,
      parameters: parameters
    )

    assertEqual(
      scene,
      [pow(10, 0.1), 1.0, pow(10, -0.1)]
    )
  }

  @Test("Display renderer is identity for bounded scene-linear input by default")
  func displayRendererNeutralIdentity() {
    let scene: [Double] = [0, 0.1, 0.25, 0.5, 0.75, 1.0]

    let display = FilmNegativeProcessing.renderDisplay(sceneLinear: scene)

    assertEqual(display, scene)
  }

  @Test("Display renderer applies exposure and BGR white balance")
  func displayRendererExposureAndWhiteBalance() {
    let scene: [Double] = [0.05, 0.05, 0.05]
    let parameters = DisplayRenderingParameters(
      exposureEV: 1,
      whiteBalance: BGRChannelValues(blue: 0.5, green: 1, red: 2)
    )

    let display = FilmNegativeProcessing.renderDisplay(
      sceneLinear: scene,
      parameters: parameters
    )

    assertEqual(display, [0.05, 0.1, 0.2])
  }

  @Test("Reinhard display tone map is monotonic")
  func displayRendererToneMapMonotonicity() {
    let scene: [Double] = [0, 0, 0, 0.25, 0.5, 1, 1, 2, 4]
    let parameters = DisplayRenderingParameters(toneMap: .reinhard)

    let display = FilmNegativeProcessing.renderDisplay(
      sceneLinear: scene,
      parameters: parameters
    )

    for channel in 0..<3 {
      #expect(display[channel] < display[3 + channel])
      #expect(display[3 + channel] < display[6 + channel])
    }
  }

  @Test("Reinhard display tone map rolls highlights into finite display range")
  func displayRendererHighlightRolloff() {
    let scene: [Double] = [1, 2, 100]
    let parameters = DisplayRenderingParameters(toneMap: .reinhard)

    let display = FilmNegativeProcessing.renderDisplay(
      sceneLinear: scene,
      parameters: parameters
    )

    #expect(display.allSatisfy { $0 >= 0 && $0 < 1 })
    #expect(display[0] == 0.5)
    #expect(display[1] == 2.0 / 3.0)
    #expect(display[2] == 100.0 / 101.0)
  }

  @Test("Display renderer limits combined exposure and white-balance noise gain")
  func displayRendererLimitsNoiseGain() {
    let scene: [Double] = [0.01, 0.01, 0.01]
    let parameters = DisplayRenderingParameters(
      exposureEV: 3,
      whiteBalance: BGRChannelValues(blue: 100, green: 100, red: 100),
      maximumSceneGain: 4
    )

    let display = FilmNegativeProcessing.renderDisplay(
      sceneLinear: scene,
      parameters: parameters
    )

    assertEqual(display, [0.04, 0.04, 0.04])
  }

  @Test("Display renderer sanitizes non-finite and negative scene values")
  func displayRendererProducesFiniteOutput() {
    let scene: [Double] = [.nan, .infinity, -.infinity, -1, 1, 10]
    let parameters = DisplayRenderingParameters(toneMap: .reinhard)

    let display = FilmNegativeProcessing.renderDisplay(
      sceneLinear: scene,
      parameters: parameters
    )

    #expect(display.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    #expect(display[0] == 0)
    #expect(display[1] == 1)
    #expect(display[2] == 0)
    #expect(display[3] == 0)
  }

  @Test("Display rendering parameters round trip through JSON")
  func displayRenderingParametersCodableRoundTrip() throws {
    let parameters = DisplayRenderingParameters(
      exposureEV: -0.75,
      whiteBalance: BGRChannelValues(blue: 1.1, green: 0.95, red: 1.25),
      toneMap: .reinhard,
      maximumSceneGain: 6
    )

    let encoded = try JSONEncoder().encode(parameters)
    let decoded = try JSONDecoder().decode(DisplayRenderingParameters.self, from: encoded)

    #expect(decoded == parameters)
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

  // ─── Slice G: Capture / Stock / Roll Profile Separation ───

  @Test("CaptureProfile round-trips through JSON")
  func captureProfileCodableRoundTrip() throws {
    let profile = CaptureProfile(
      id: CaptureProfileID(rawValue: "test-capture"),
      cameraModel: "Fuji X-T5",
      lensModel: "Tokina 100mm f/2.8",
      backlightDescription: "CS-Lite LED panel",
      estimatedColorTemperature: 5000,
      normalizationParams: CaptureNormalizationParameters(
        blackLevel: BGRChannelValues(blue: 128, green: 128, red: 128)
      ),
      preferredISO: 200,
      notes: "Standard copy stand setup"
    )
    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(CaptureProfile.self, from: encoded)
    #expect(decoded == profile)
  }

  @Test("FilmStockProfile round-trips through JSON")
  func filmStockProfileCodableRoundTrip() throws {
    let profile = FilmStockProfile(
      id: FilmStockProfileID(rawValue: "portra-400"),
      displayName: "Portra 400",
      filmType: .colourNegative,
      c41Profile: GenericC41Profile(
        densitySlope: BGRChannelValues(blue: 1.05, green: 1.0, red: 0.95),
        densityOffset: BGRChannelValues(blue: 0.01, green: 0.0, red: -0.01)
      ),
      displayRendering: DisplayRenderingParameters(
        exposureEV: -0.5,
        toneMap: .reinhard,
        maximumSceneGain: 8
      ),
      notes: "Calibrated from IT8 target / Portra 400 roll #1"
    )
    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(FilmStockProfile.self, from: encoded)
    #expect(decoded == profile)
  }

  @Test("RollProfile codable round-trip uses type-safe profile IDs")
  func rollProfileCodableWithTypeSafeIDs() throws {
    let profile = RollProfile(
      rollID: "roll-p4-001",
      filmStockID: FilmStockProfileID(rawValue: "portra-400"),
      captureProfileID: CaptureProfileID(rawValue: "copy-stand-a"),
      measuredBaseDensity: BGRChannelValues(blue: 0.32, green: 0.42, red: 0.52),
      exposureBias: -0.25,
      whiteBalanceCorrection: BGRChannelValues(blue: 1.02, green: 1, red: 0.98)
    )
    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(RollProfile.self, from: encoded)
    #expect(decoded == profile)
    #expect(decoded.rollID == "roll-p4-001")
    #expect(decoded.schemaVersion == 2)
  }

  @Test("ProfileStore saves and loads CaptureProfile")
  func profileStoreCaptureProfileRoundTrip() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let profile = CaptureProfile(
      id: CaptureProfileID(rawValue: "stored-capture"),
      cameraModel: "Test Camera",
      normalizationParams: CaptureNormalizationParameters(),
      preferredISO: 400
    )
    try store.saveCaptureProfile(profile)
    let loadedValue = try store.loadCaptureProfile(id: profile.id)
    let loaded = try #require(loadedValue)
    #expect(loaded == profile)
  }

  @Test("ProfileStore saves and loads FilmStockProfile")
  func profileStoreFilmStockProfileRoundTrip() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let profile = FilmStockProfile(
      id: FilmStockProfileID(rawValue: "ektar-100"),
      displayName: "Ektar 100",
      filmType: .colourNegative,
      c41Profile: GenericC41Profile()
    )
    try store.saveFilmStockProfile(profile)
    let loadedValue = try store.loadFilmStockProfile(id: profile.id)
    let loaded = try #require(loadedValue)
    #expect(loaded == profile)
  }

  @Test("ProfileStore saves and loads RollProfile")
  func profileStoreRollProfileRoundTrip() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let profile = RollProfile(
      rollID: "stored-roll",
      filmStockID: FilmStockProfileID(rawValue: "portra-400"),
      captureProfileID: CaptureProfileID(rawValue: "default")
    )
    try store.saveRollProfile(profile)
    let loadedValue = try store.loadRollProfile(rollID: "stored-roll")
    let loaded = try #require(loadedValue)
    #expect(loaded == profile)
  }

  @Test("ProfileStore loads multiple roll profiles")
  func profileStoreLoadsMultipleRollProfiles() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    try store.saveRollProfile(
      RollProfile(
        rollID: "r1", filmStockID: FilmStockProfileID(rawValue: "s1"),
        captureProfileID: CaptureProfileID(rawValue: "c1")))
    try store.saveRollProfile(
      RollProfile(
        rollID: "r2", filmStockID: FilmStockProfileID(rawValue: "s2"),
        captureProfileID: CaptureProfileID(rawValue: "c2")))
    let all = try store.loadRollProfiles()
    #expect(all.count == 2)
    #expect(all.map(\.rollID).sorted() == ["r1", "r2"])
  }

  @Test("ProfileStore migrates schema-1 roll profile JSON")
  func profileStoreMigratesLegacyRollProfile() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let rollDirectory = dir.appendingPathComponent("RollProfiles", isDirectory: true)
    try FileManager.default.createDirectory(at: rollDirectory, withIntermediateDirectories: true)
    let legacyJSON = """
      {
        "schemaVersion": 1,
        "filmStockID": "portra-400",
        "captureProfileID": "copy-stand-a",
        "measuredBaseDensity": {"blue": 0.3, "green": 0.4, "red": 0.5},
        "measurementCount": 3,
        "exposureBias": 0,
        "whiteBalanceCorrection": {"blue": 1, "green": 1, "red": 1}
      }
      """
    try Data(legacyJSON.utf8).write(
      to: rollDirectory.appendingPathComponent("legacy-roll.json"))

    let loadedValue = try ProfileStore(baseDirectory: dir).loadRollProfile(
      rollID: "legacy-roll")
    let loaded = try #require(loadedValue)
    #expect(loaded.rollID == "legacy-roll")
    #expect(loaded.schemaVersion == RollProfile.currentSchemaVersion)
    #expect(loaded.filmStockID.rawValue == "portra-400")
    #expect(loaded.captureProfileID.rawValue == "copy-stand-a")
  }

  @Test("ProfileStore reports corrupt roll profile files")
  func profileStoreReportsCorruptRollProfiles() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let rollDirectory = dir.appendingPathComponent("RollProfiles", isDirectory: true)
    try FileManager.default.createDirectory(at: rollDirectory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(
      to: rollDirectory.appendingPathComponent("corrupt.json"))
    let store = ProfileStore(baseDirectory: dir)

    #expect(throws: DecodingError.self) {
      try store.loadRollProfiles()
    }
  }

  @Test("ProfileStore rejects unsupported profile schema versions")
  func profileStoreRejectsFutureSchema() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let profile = CaptureProfile(
      schemaVersion: 2,
      id: CaptureProfileID(rawValue: "future")
    )
    try store.saveCaptureProfile(profile)

    #expect(
      throws: ProfileResolutionError.incompatibleSchemaVersion(2, supported: 1)
    ) {
      try store.loadCaptureProfile(id: profile.id)
    }
  }

  @Test("Profile resolution resolves built-in profiles when none are stored")
  func profileResolutionFallsBackToBuiltIn() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let capture = try store.resolveCaptureProfile(id: CaptureProfile.default.id)
    #expect(capture == CaptureProfile.default)
    let stock = try store.resolveStockProfile(
      id: FilmStockProfile.genericColorNegative.id)
    #expect(stock == FilmStockProfile.genericColorNegative)
  }

  @Test("Profile resolution returns stored profile over built-in")
  func profileResolutionPrefersStoredOverBuiltIn() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let modified = CaptureProfile(
      id: CaptureProfile.default.id,
      cameraModel: "Overridden",
      preferredISO: 800
    )
    try store.saveCaptureProfile(modified)
    let resolved = try store.resolveCaptureProfile(id: CaptureProfile.default.id)
    #expect(resolved.cameraModel == "Overridden")
    #expect(resolved.preferredISO == 800)
  }

  @Test("Profile resolution throws for unknown capture profile ID")
  func profileResolutionThrowsForUnknownCaptureProfile() {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    #expect(throws: ProfileResolutionError.self) {
      try store.resolveCaptureProfile(
        id: CaptureProfileID(rawValue: "nonexistent"))
    }
  }

  @Test("Profile resolution throws for unknown stock profile ID")
  func profileResolutionThrowsForUnknownStockProfile() {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    #expect(throws: ProfileResolutionError.self) {
      try store.resolveStockProfile(
        id: FilmStockProfileID(rawValue: "nonexistent"))
    }
  }

  @Test("ResolvedPipelineProfile composes capture and stock independently")
  func resolvedPipelineProfileComposesProfiles() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let captureID = CaptureProfileID(rawValue: "comp-capture")
    let stockID = FilmStockProfileID(rawValue: "comp-stock")
    try store.saveCaptureProfile(
      CaptureProfile(
        id: captureID,
        normalizationParams: CaptureNormalizationParameters(
          blackLevel: BGRChannelValues(blue: 64, green: 64, red: 64)
        ),
        preferredISO: 200
      ))
    try store.saveFilmStockProfile(
      FilmStockProfile(
        id: stockID,
        displayName: "Composite Test",
        filmType: .colourNegative,
        c41Profile: GenericC41Profile(
          densitySlope: BGRChannelValues(blue: 1.1, green: 1.0, red: 0.9)
        )
      ))

    let resolved = try store.resolvePipeline(
      captureProfileID: captureID,
      stockProfileID: stockID
    )
    #expect(resolved.captureProfile.preferredISO == 200)
    #expect(resolved.stockProfile.c41Profile.densitySlope.blue == 1.1)
    #expect(resolved.resolvedBaseDensity == nil)
  }

  @Test("ResolvedPipelineProfile includes base density from roll profile")
  func resolvedPipelineProfileIncludesBaseDensity() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let captureID = CaptureProfileID(rawValue: "bd-capture")
    let stockID = FilmStockProfileID(rawValue: "bd-stock")
    try store.saveCaptureProfile(CaptureProfile(id: captureID))
    try store.saveFilmStockProfile(
      FilmStockProfile(
        id: stockID, displayName: "BD Test", filmType: .colourNegative))

    let roll = RollProfile(
      rollID: "bd-roll",
      filmStockID: stockID,
      captureProfileID: captureID,
      measuredBaseDensity: BGRChannelValues(blue: 0.3, green: 0.4, red: 0.5)
    )
    let resolved = try store.resolvePipeline(
      captureProfileID: captureID,
      stockProfileID: stockID,
      rollProfile: roll
    )
    #expect(
      resolved.resolvedBaseDensity?.baseDensity
        == BGRChannelValues(blue: 0.3, green: 0.4, red: 0.5))
    #expect(resolved.resolvedBaseDensity?.source == .measuredRoll)
  }

  @Test("CaptureProfile built-in list includes default")
  func builtInCaptureProfilesIncludesDefault() {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let builtIns = store.builtInCaptureProfiles()
    #expect(builtIns.contains(CaptureProfile.default))
  }

  @Test("FilmStockProfile built-in list includes both generics")
  func builtInFilmStockProfilesIncludesBothGenerics() {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let builtIns = store.builtInFilmStockProfiles()
    #expect(builtIns.contains(FilmStockProfile.genericColorNegative))
    #expect(builtIns.contains(FilmStockProfile.genericBW))
  }

  @Test("ProfileStore lists saved capture profile IDs")
  func profileStoreListsCaptureProfileIDs() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    try store.saveCaptureProfile(CaptureProfile(id: CaptureProfileID(rawValue: "cap-a")))
    try store.saveCaptureProfile(CaptureProfile(id: CaptureProfileID(rawValue: "cap-b")))
    let ids = store.listCaptureProfiles()
    #expect(ids.sorted(by: { $0.rawValue < $1.rawValue }) == [
      CaptureProfileID(rawValue: "cap-a"), CaptureProfileID(rawValue: "cap-b"),
    ])
  }

  @Test("ProfileStore lists saved stock profile IDs")
  func profileStoreListsStockProfileIDs() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    try store.saveFilmStockProfile(
      FilmStockProfile(
        id: FilmStockProfileID(rawValue: "stock-x"), displayName: "X",
        filmType: .colourNegative))
    let ids = store.listFilmStockProfiles()
    #expect(ids.contains(FilmStockProfileID(rawValue: "stock-x")))
  }

  @Test("ResolvedPipelineProfile round-trips through JSON")
  func resolvedPipelineProfileCodableRoundTrip() throws {
    let resolved = ResolvedPipelineProfile(
      captureProfile: .default,
      stockProfile: .genericColorNegative,
      resolvedBaseDensity: ResolvedBaseDensity(
        baseDensity: BGRChannelValues(blue: 0.12, green: 0.15, red: 0.18),
        source: .manualPicker
      )
    )
    let encoded = try JSONEncoder().encode(resolved)
    let decoded = try JSONDecoder().decode(
      ResolvedPipelineProfile.self, from: encoded)
    #expect(decoded == resolved)
  }

  @Test("ProfileStore init with app group identifier creates support directory URL")
  func profileStoreAppGroupInit() throws {
    let store = ProfileStore(appGroupIdentifier: "TestAppGroup")
    #expect(store != nil)
    let storeValue = try #require(store)
    #expect(storeValue.baseDirectory.lastPathComponent == "TestAppGroup")
  }

  @Test("Profile resolution passes through frame and automatic base density")
  func profileResolutionPassesThroughFrameAndAutoBase() throws {
    let dir = temporaryProfileDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ProfileStore(baseDirectory: dir)
    let captureID = CaptureProfileID(rawValue: "frame-auto-cap")
    let stockID = FilmStockProfileID(rawValue: "frame-auto-stock")
    try store.saveCaptureProfile(CaptureProfile(id: captureID))
    try store.saveFilmStockProfile(
      FilmStockProfile(
        id: stockID, displayName: "FA", filmType: .colourNegative))

    let frameBD = BGRChannelValues(blue: 0.11, green: 0.22, red: 0.33)
    let autoBD = BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3)

    let withFrame = try store.resolvePipeline(
      captureProfileID: captureID,
      stockProfileID: stockID,
      frameMeasurement: frameBD,
      automaticBaseDensity: autoBD
    )
    #expect(withFrame.resolvedBaseDensity?.source == .measuredFrame)

    let withAuto = try store.resolvePipeline(
      captureProfileID: captureID,
      stockProfileID: stockID,
      automaticBaseDensity: autoBD
    )
    #expect(withAuto.resolvedBaseDensity?.source == .automaticEstimate)
  }

  private func temporaryProfileDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FilmScanEngineTests-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func borderedImage(
    width: Int,
    height: Int,
    top: UInt16? = nil,
    left: UInt16? = nil,
    center: UInt16
  ) -> UInt16Image {
    var pixels: [UInt16] = []
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let value = top.map { y == 0 ? $0 : center }
          ?? left.map { x == 0 ? $0 : center }
          ?? center
        pixels.append(contentsOf: [value, value, value])
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }
}
