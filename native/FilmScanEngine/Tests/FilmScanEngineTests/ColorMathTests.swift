import Testing

@testable import FilmScanEngine

@Suite("Shared color math")
struct ColorMathTests {
  @Test("Named luminance standards are normalized")
  func normalizedLuminanceStandards() {
    for weights in [
      LuminanceStandards.rec2020,
      LuminanceStandards.rec709,
      LuminanceStandards.bt601,
    ] {
      #expect(abs(weights.blue + weights.green + weights.red - 1) < 1e-12)
    }
  }

  @Test("Sorted percentile interpolates and handles small collections")
  func sortedPercentile() {
    #expect(ScalarMath.percentile(inSorted: [], fraction: 0.5) == 0)
    #expect(ScalarMath.percentile(inSorted: [7], fraction: 0.5) == 7)
    #expect(ScalarMath.percentile(inSorted: [0, 10], fraction: 0.25) == 2.5)
    #expect(ScalarMath.percentile(inSorted: [0, 10, 20], fraction: 0.5) == 10)
  }

  @Test("Smoothstep clamps its domain and eases through the midpoint")
  func smoothstep() {
    #expect(ScalarMath.smoothstep(2, 4, 1) == 0)
    #expect(ScalarMath.smoothstep(2, 4, 3) == 0.5)
    #expect(ScalarMath.smoothstep(2, 4, 5) == 1)
  }

  @Test("Finite clamp sanitizes exceptional and out-of-range values")
  func finiteClamp() {
    #expect(ScalarMath.finiteClamped(.nan, bound: 10) == 0)
    #expect(ScalarMath.finiteClamped(-.infinity, bound: 10) == 0)
    #expect(ScalarMath.finiteClamped(.infinity, bound: 10) == 10)
    #expect(ScalarMath.finiteClamped(-12, bound: 10) == -10)
    #expect(ScalarMath.finiteClamped(12, bound: 10) == 10)
  }

  @Test("HSV conversion specializes consistently for Float and Double")
  func genericHSVConversion() {
    let floatResult: (red: Float, green: Float, blue: Float) = ColorConversion.hsvToRGB(
      hue: 0.5,
      saturation: 0.75,
      value: 0.8
    )
    let doubleResult: (red: Double, green: Double, blue: Double) = ColorConversion.hsvToRGB(
      hue: 0.5,
      saturation: 0.75,
      value: 0.8
    )

    #expect(abs(Double(floatResult.red) - doubleResult.red) < 1e-6)
    #expect(abs(Double(floatResult.green) - doubleResult.green) < 1e-6)
    #expect(abs(Double(floatResult.blue) - doubleResult.blue) < 1e-6)
    #expect(abs(doubleResult.red - 0.2) < 1e-12)
    #expect(abs(doubleResult.green - 0.8) < 1e-12)
    #expect(abs(doubleResult.blue - 0.8) < 1e-12)
  }
}
