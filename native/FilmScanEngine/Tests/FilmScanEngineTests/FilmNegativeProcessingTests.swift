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
    let automatic = BGRChannelValues(blue: 0.25, green: 0.25, red: 0.25)
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
