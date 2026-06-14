import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Threshold generation")
struct ThresholdTests {
  @Test("Threshold generation matches Python reference for default settings (dark=25, light=100)")
  func thresholdDefaultSettings() throws {
    let fixture = try FixtureLoader.loadCase("threshold_d25_l100")
    let actual = fixture.input.getThreshold(darkThreshold: 25, lightThreshold: 100)

    #expect(fixture.metadata.stage == "get_threshold")
    #expect(actual == fixture.expected)
    #expect(actual.channels == 1)
    #expect(actual.height == fixture.metadata.outputShape[0])
    #expect(actual.width == fixture.metadata.outputShape[1])
  }

  @Test("Threshold with dark=0 matches Python reference (all pixels pass dark check)")
  func thresholdAllDark() throws {
    let fixture = try FixtureLoader.loadCase("threshold_d0_l100")
    let actual = fixture.input.getThreshold(darkThreshold: 0, lightThreshold: 100)

    #expect(actual == fixture.expected)
  }

  @Test("Threshold with tight light range matches Python reference (dark=25, light=75)")
  func thresholdTightLightRange() throws {
    let fixture = try FixtureLoader.loadCase("threshold_d25_l75")
    let actual = fixture.input.getThreshold(darkThreshold: 25, lightThreshold: 75)

    #expect(actual == fixture.expected)
  }

  @Test("Threshold with dark=light=100 produces all-zero result")
  func thresholdAllZero() throws {
    let fixture = try FixtureLoader.loadCase("threshold_d100_l100")
    let actual = fixture.input.getThreshold(darkThreshold: 100, lightThreshold: 100)

    #expect(actual == fixture.expected)
  }

  @Test("Threshold with inverted range (dark=75, light=25) produces all-zero result")
  func thresholdInvertedRange() throws {
    let fixture = try FixtureLoader.loadCase("threshold_d75_l25")
    let actual = fixture.input.getThreshold(darkThreshold: 75, lightThreshold: 25)

    #expect(actual == fixture.expected)
  }
}
