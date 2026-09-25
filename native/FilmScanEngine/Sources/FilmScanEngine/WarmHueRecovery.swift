import Foundation

/// A bounded color-family correction authored from unpaired Lucky C200/Tahoe
/// references. Neutral stone and cyan/blue water lie outside its mask. Redder
/// skin/bark hues taper out, but similarly colored objects cannot be separated.
public enum WarmHueRecovery {
  public static func apply(
    blue: Double, green: Double, red: Double, amount: Double, boundaryTolerance: Double = 0
  )
    -> (blue: Double, green: Double, red: Double)
  {
    guard amount.isFinite, amount > 0 else { return (blue, green, red) }
    let linear = FilmNegativeProcessing.linearRec2020ToSRGB(red: red, green: green, blue: blue)
    // Do not clip out-of-gamut or HDR input to manufacture a hue measurement.
    guard min(linear.red, linear.green, linear.blue) >= -boundaryTolerance,
      max(linear.red, linear.green, linear.blue) <= 1 + boundaryTolerance
    else { return (blue, green, red) }
    let r = FilmNegativeProcessing.linearToSRGB(linear.red)
    let g = FilmNegativeProcessing.linearToSRGB(linear.green)
    let b = FilmNegativeProcessing.linearToSRGB(linear.blue)
    let maximum = max(r, g, b)
    let minimum = min(r, g, b)
    let delta = maximum - minimum
    guard delta > 1e-8, maximum > 1e-8 else { return (blue, green, red) }
    let hue: Double
    if maximum == r {
      hue = 60 * (g - b) / delta
    } else if maximum == g {
      hue = 60 * (2 + (b - r) / delta)
    } else {
      hue = 60 * (4 + (r - g) / delta)
    }
    let saturation = delta / maximum
    let weight =
      min(amount, 1)
      * ScalarMath.smoothstep(18, 34, hue)
      * (1 - ScalarMath.smoothstep(70, 160, hue))
      * ScalarMath.smoothstep(0.28, 0.58, saturation)
      * (1 - ScalarMath.smoothstep(0.7, 1, max(linear.red, linear.green, linear.blue)))
    guard weight > 0 else { return (blue, green, red) }
    let shiftedHue = (hue + 60 * weight) / 60
    let chroma = maximum * saturation * (1 - 0.25 * weight)
    let x = chroma * (1 - abs(shiftedHue.truncatingRemainder(dividingBy: 2) - 1))
    let m = maximum - chroma
    let rgb: (Double, Double, Double)
    if shiftedHue < 1 {
      rgb = (chroma, x, 0)
    } else if shiftedHue < 2 {
      rgb = (x, chroma, 0)
    } else {
      rgb = (0, chroma, x)
    }
    let recovered = FilmNegativeProcessing.linearSRGBToRec2020(
      red: FilmNegativeProcessing.sRGBToLinear(rgb.0 + m),
      green: FilmNegativeProcessing.sRGBToLinear(rgb.1 + m),
      blue: FilmNegativeProcessing.sRGBToLinear(rgb.2 + m))
    let originalLuma = 0.2626983 * red + 0.6780 * green + 0.0593017 * blue
    let recoveredLuma =
      0.2626983 * recovered.red + 0.6780 * recovered.green
      + 0.0593017 * recovered.blue
    let gain = originalLuma / max(recoveredLuma, 1e-9)
    return (recovered.blue * gain, recovered.green * gain, recovered.red * gain)
  }
}
