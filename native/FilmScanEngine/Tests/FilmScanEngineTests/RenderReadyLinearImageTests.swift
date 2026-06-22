import Testing

@testable import FilmScanEngine

@Suite("Render-ready linear image")
struct RenderReadyLinearImageTests {
  @Test("Power-law front-end exposes unclamped linear values while retaining bounded output")
  func powerLawFrontEndExposesUnclampedValues() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [500, 750, 1_000, 32_000, 33_000, 34_000]
    )
    var parameters = FilmNegativeParams.colourNegative
    parameters.measuredMedians = BGRChannelValues(blue: 32_000, green: 33_000, red: 34_000)

    let linear = FilmNegativeProcessing.powerLawRenderReadyLinear(
      image: image,
      params: parameters
    )
    let bounded = FilmNegativeProcessing.applyPowerLawInversion(
      image: image,
      params: parameters
    )

    #expect(linear.width == image.width)
    #expect(linear.height == image.height)
    #expect(linear.pixels.contains { $0 > 1 })
    #expect(bounded.pixels.allSatisfy { $0 <= 65_535 })
  }

  @Test("Bounded power-law wrapper renders the shared linear result")
  func boundedPowerLawWrapperMatchesSharedLinearResult() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [12_000, 18_000, 24_000, 30_000, 36_000, 42_000]
    )
    var parameters = FilmNegativeParams.colourNegative
    parameters.measuredMedians = BGRChannelValues(blue: 21_000, green: 27_000, red: 33_000)

    let linear = FilmNegativeProcessing.powerLawRenderReadyLinear(
      image: image,
      params: parameters
    )
    let rendered = FilmNegativeProcessing.renderPowerLawDisplay(linear)
    let existing = FilmNegativeProcessing.applyPowerLawInversion(
      image: image,
      params: parameters
    )

    #expect(rendered == existing)
  }

  @Test("Density front-end feeds the shared render-ready interface")
  func densityFrontEndFeedsSharedInterface() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [3_000, 5_000, 9_000])
    let flatField = UInt16Image(
      width: 1,
      height: 1,
      channels: 3,
      pixels: [11_000, 21_000, 41_000]
    )
    let parameters = CaptureNormalizationParameters(
      blackLevel: BGRChannelValues(blue: 1_000, green: 1_000, red: 1_000)
    )
    let baseDensity = BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3)

    let renderReady = FilmNegativeProcessing.densityToRenderReadyLinear(
      image: image,
      flatField: flatField,
      baseDensity: baseDensity,
      parameters: parameters
    )
    let legacyArray = FilmNegativeProcessing.densityToSceneLinear(
      image: image,
      flatField: flatField,
      baseDensity: baseDensity,
      parameters: parameters
    )

    #expect(renderReady.width == 1)
    #expect(renderReady.height == 1)
    #expect(renderReady.pixels == legacyArray)
  }

  @Test("Statistics use deterministic bounded sampling")
  func statisticsAreDeterministicAndBounded() {
    let pixels = (0..<100).flatMap { value -> [Double] in
      let sample = Double(value) / 100.0
      return [sample, sample, sample]
    }
    let image = RenderReadyLinearImage(width: 100, height: 1, pixels: pixels)

    let first = image.statistics(maximumSampleCount: 11)
    let second = image.statistics(maximumSampleCount: 11)

    #expect(first == second)
    #expect(first.sampleCount == 11)
    #expect(first.totalPixelCount == 100)
  }

  @Test("Statistics enforce a fixed upper sampling bound")
  func statisticsEnforceHardSampleLimit() {
    let pixelCount = RenderReadyLinearImage.statisticsSampleLimit + 1
    let image = RenderReadyLinearImage(
      width: pixelCount,
      height: 1,
      pixels: [Double](repeating: 0.18, count: pixelCount * 3)
    )

    let statistics = image.statistics(maximumSampleCount: .max)

    #expect(statistics.sampleCount == RenderReadyLinearImage.statisticsSampleLimit)
    #expect(statistics.totalPixelCount == pixelCount)
  }

  @Test("Robust tone references are not controlled by one extreme outlier")
  func robustToneReferencesRejectOutlier() {
    var pixels = (0..<1_000).flatMap { value -> [Double] in
      let sample = 0.05 + 0.9 * Double(value) / 999.0
      return [sample, sample, sample]
    }
    pixels += [1_000_000, 1_000_000, 1_000_000]
    let image = RenderReadyLinearImage(width: 1_001, height: 1, pixels: pixels)

    let statistics = image.statistics(maximumSampleCount: 1_001)

    #expect(statistics.linearLuminance.p99 < 1)
    #expect(statistics.normalizedToneReferences.shadow == 0)
    #expect(statistics.normalizedToneReferences.highlight == 1)
    #expect(statistics.normalizedToneReferences.midtone > 0)
    #expect(statistics.normalizedToneReferences.midtone < 1)
  }

  @Test("Statistics report per-channel low and high clipping ratios")
  func statisticsReportClippingRatios() {
    let image = RenderReadyLinearImage(
      width: 4,
      height: 1,
      pixels: [
        -1, 0.5, 2,
        0, 1, 0.5,
        0.5, 1.5, 0.75,
        2, -0.5, 1,
      ]
    )

    let statistics = image.statistics(maximumSampleCount: 4)

    #expect(statistics.lowClippingRatios == BGRChannelValues(blue: 0.5, green: 0.25, red: 0))
    #expect(statistics.highClippingRatios == BGRChannelValues(blue: 0.25, green: 0.5, red: 0.5))
  }
}
