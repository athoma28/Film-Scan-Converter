import Testing

@testable import FilmScanConverterMac

@Suite("Adjustment slider response")
struct AdjustmentSliderTests {
  @Test("Center-weighted response gives finer control around neutral")
  func centerWeightedResponse() {
    let positive = AdjustmentSliderResponse.value(
      for: 0.5,
      range: -1...1,
      neutral: 0,
      exponent: 1.6
    )
    let negative = AdjustmentSliderResponse.value(
      for: -0.5,
      range: -1...1,
      neutral: 0,
      exponent: 1.6
    )

    #expect(positive > 0)
    #expect(positive < 0.5)
    #expect(abs(positive + negative) < 1e-12)
  }

  @Test("Response mapping round trips asymmetric slider ranges")
  func asymmetricRoundTrip() {
    let range = 0.8...1.8
    let neutral = 1.32
    for value in [0.8, 0.95, 1.32, 1.5, 1.8] {
      let position = AdjustmentSliderResponse.position(
        for: value,
        range: range,
        neutral: neutral,
        exponent: 1.5
      )
      let roundTrip = AdjustmentSliderResponse.value(
        for: position,
        range: range,
        neutral: neutral,
        exponent: 1.5
      )
      #expect(abs(roundTrip - value) < 1e-12)
    }
  }

  @Test("Linear response preserves stepped-control behavior")
  func linearResponse() {
    #expect(
      AdjustmentSliderResponse.value(
        for: 37,
        range: -100...100,
        neutral: 0,
        exponent: 1
      ) == 37
    )
  }
}
