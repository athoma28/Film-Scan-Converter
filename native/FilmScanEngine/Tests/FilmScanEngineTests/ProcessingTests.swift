import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Film processing stages")
struct ProcessingTests {
  @Test("Neutral white balance (temp=0, tint=0) returns the same image")
  func whiteBalanceNeutral() throws {
    let (input, expected, shape, metadata) = try FixtureLoader.loadFloat64Case("wb_t0_tint0")

    #expect(metadata.stage == "wb_adjust_coeff")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: 0,
      tint: 0
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Warm white balance (temp=65, tint=-40) matches Python reference")
  func whiteBalanceWarm() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("wb_t65_tintm40")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: 65,
      tint: -40
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Cool white balance (temp=-30, tint=20) matches Python reference")
  func whiteBalanceCool() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("wb_tm30_tint20")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: -30,
      tint: 20
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Extreme white balance (temp=100, tint=-100) matches Python reference")
  func whiteBalanceExtreme() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("wb_t100_tintm100")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: 100,
      tint: -100
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Neutral saturation (sat=100) returns the same image")
  func saturationNeutral() throws {
    let (input, expected, shape, metadata) = try FixtureLoader.loadFloat64Case("sat_100")

    #expect(metadata.stage == "sat_adjust")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 100
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Boosted saturation (sat=150) matches Python reference")
  func saturationBoosted() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_150")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 150
    )

    assertFloat64Equal(actual, expected)
  }

  @Test("Reduced saturation (sat=50) matches Python reference within documented float tolerance")
  func saturationReduced() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_50")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 50
    )

    assertFloat64Equal(actual, expected)
  }

  @Test(
    "Desaturated to grayscale (sat=0) matches Python reference within documented float tolerance")
  func saturationGrayscale() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_0")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 0
    )

    assertFloat64Equal(actual, expected)
  }

  @Test("Max saturation (sat=200) matches Python reference within documented float tolerance")
  func saturationMax() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_200")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 200
    )

    assertFloat64Equal(actual, expected)
  }

  @Test(
    "Exposure matches Python float32 rounding",
    arguments: [
      ("exposure_neutral", 0, 0, 0),
      ("exposure_gamma40", 40, 0, 0),
      ("exposure_shadows60", 0, 60, 0),
      ("exposure_highlightsm45", 0, 0, -45),
      ("exposure_combined", -35, 70, -55),
    ]
  )
  func exposure(caseName: String, gamma: Int, shadows: Int, highlights: Int) throws {
    let (input, expected, _, metadata) = try FixtureLoader.loadFloat64Case(caseName)

    #expect(metadata.stage == "exposure")

    let actual = FilmProcessing.exposure(
      image: input,
      gamma: gamma,
      shadows: shadows,
      highlights: highlights
    )

    #expect(actual == expected)
  }

  private func assertFloat64Equal(_ actual: [Double], _ expected: [Double], tolerance: Double = 0.5)
  {
    #expect(actual.count == expected.count)
    for i in actual.indices {
      let diff = abs(actual[i] - expected[i])
      #expect(diff <= tolerance || actual[i] == expected[i])
    }
  }
}
