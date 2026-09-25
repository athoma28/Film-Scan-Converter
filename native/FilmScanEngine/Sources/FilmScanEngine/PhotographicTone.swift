import Foundation

/// Versioned photographic tone contract. Rec.2020 linear values remain floating
/// until the final display writer. Keep the matching Metal functions in parity.
public enum PhotographicTone {
  public static func encode(_ x: Double) -> Double {
    x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
  }

  public static func decode(_ x: Double) -> Double {
    x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
  }

  /// Identity below the knee, C1, strictly increasing and asymptotic above it.
  /// Unlike clamping, distinguishable over-range values remain distinguishable.
  public static func shoulder(_ x: Double) -> Double {
    let knee = 0.98
    guard x > knee else { return x }
    let d = x - knee
    return knee + (1 - knee) * d / (d + 1 - knee)
  }

  /// Smooth compact bend. With |amount| <= 4, derivative is >= 0.23;
  /// both endpoints and their unit slopes are preserved, including at joins.
  public static func bend(_ x: Double, _ amount: Double) -> Double {
    let w = x * (1 - x)
    return x + amount * w * w
  }

  /// Version-3 trial: redistribute response toward the selected range's tail.
  /// In logit coordinates the derivative is 1 / (t * (1 - t)) plus or minus
  /// 2 * ln(2) * amount. Its lower bound is 4 - 2 * ln(2) > 0 at public limits.
  /// Both endpoints stay fixed; the join with the unaffected range has slope 1.
  private static func focusedBend(_ t: Double, _ amount: Double, highlights: Bool) -> Double {
    let gain = exp2(2 * amount * (highlights ? t : 1 - t))
    return t * gain / (1 - t + t * gain)
  }

  /// Stronger upper-half version for Whites. The logit derivative stays
  /// positive at public limits: 1 / (t * (1 - t)) - 3 * ln(2) > 0.
  private static func tailBend(_ t: Double, _ amount: Double, highlights: Bool) -> Double {
    let gain = exp2(3 * amount * (highlights ? t : 1 - t))
    return t * gain / (1 - t + t * gain)
  }

  /// Version 4 separates the basic range controls from grading levels. Range
  /// controls keep the black and white endpoints fixed; the last three controls
  /// deliberately move those levels or the center of the tone scale.
  private static func versionFourRanges(_ value: Double, parameters p: PhotoAdjustmentParameters)
    -> Double
  {
    var x = value
    if p.shadows != 0, x < 0.72 {
      x = 0.72 * bend(x / 0.72, 4 * min(max(p.shadows, -1), 1))
    }
    if p.highlights != 0, x > 0.28, x < 1 {
      x = 0.28 + 0.72 * bend((x - 0.28) / 0.72, 4 * min(max(p.highlights, -1), 1))
    }
    if p.blacks != 0, x < 0.28 {
      x = 0.28 * focusedBend(x / 0.28, min(max(p.blacks, -1), 1), highlights: false)
    }
    if p.whites != 0, x > 0.5, x < 1 {
      x =
        0.5 + 0.5
        * tailBend(
          (x - 0.5) / 0.5, min(max(p.whites, -1), 1), highlights: true)
    }
    return x
  }

  private static func versionFourLevels(_ value: Double, parameters p: PhotoAdjustmentParameters)
    -> Double
  {
    var x = value
    // A compact center bend changes the middle gray neighborhood without
    // dragging the deep shadows or specular highlights along with it.
    if p.midtoneLevel != 0, x > 0.18, x < 0.82 {
      x =
        0.18 + 0.64
        * bend(
          (x - 0.18) / 0.64, 4 * min(max(p.midtoneLevel, -1), 1))
    }
    let shadowFloor = min(max(p.shadowFloor, -1), 1)
    let highlightCeiling = min(max(p.highlightCeiling, -1), 1)
    let black = shadowFloor >= 0 ? 0.12 * shadowFloor : 0.08 * shadowFloor
    let white =
      highlightCeiling >= 0
      ? 1 + 0.10 * highlightCeiling : 1 + 0.16 * highlightCeiling
    return black + (white - black) * x
  }

  public static func luminance(_ input: Double, parameters p: PhotoAdjustmentParameters) -> Double {
    let gain = exp2(min(max(p.exposureEV, -4), 4))
    let positive = max(input, 0)
    // Exposure is a linear gain followed by a gain-dependent shoulder. Increasing
    // exposure redistributes highlights instead of creating a hard white plateau.
    let exposed = positive * gain / (1 + positive * max(gain - 1, 0))
    var x = encode(exposed)
    if x < 1 { x = bend(x, 4 * min(max(p.brightness, -1), 1)) }
    let contrast = min(max(p.contrast, -1), 1)
    if contrast != 0, x > 0, x < 1 {
      let pivot = encode(0.18)
      let power = exp2(contrast * 0.8)
      if x < pivot {
        x = pivot * pow(x / pivot, power)
      } else {
        x = 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), power)
      }
    }
    let hasVersionFourControl =
      p.highlights != 0 || p.shadows != 0 || p.whites != 0
      || p.blacks != 0 || p.shadowFloor != 0 || p.midtoneLevel != 0
      || p.highlightCeiling != 0
    if p.schemaVersion >= 4, hasVersionFourControl {
      x = versionFourRanges(x, parameters: p)
      x = encode(shoulder(decode(x)))
      x = versionFourLevels(x, parameters: p)
    } else {
      if x < 0.65 {
        let shadows = min(max(p.shadows, -1), 1)
        x =
          0.65
          * (p.schemaVersion >= 3 && shadows != 0
            ? focusedBend(x / 0.65, shadows, highlights: false)
            : bend(x / 0.65, 4 * shadows))
      }
      if x > 0.4, x < 1 {
        let highlights = min(max(p.highlights, -1), 1)
        x =
          0.4 + 0.6
          * (p.schemaVersion >= 3 && highlights != 0
            ? focusedBend((x - 0.4) / 0.6, highlights, highlights: true)
            : bend((x - 0.4) / 0.6, 4 * highlights))
      }
      x = encode(shoulder(decode(x)))
      // Version 1-3 endpoints are explicit creative controls; intentional
      // clipping is deferred until after curves and grading.
      let black = min(max(p.blacks, -1), 1) * 0.12
      x = (x + black) / (1 + black)
      x *= exp2(min(max(p.whites, -1), 1) * 0.5)
    }
    return decode(x)
  }

  public static func apply(
    red: Double, green: Double, blue: Double,
    parameters: PhotoAdjustmentParameters
  ) -> (red: Double, green: Double, blue: Double) {
    let y = 0.2626983 * red + 0.678 * green + 0.0593017 * blue
    let target = luminance(y, parameters: parameters)
    if y > 1e-12 {
      let scale = target / y
      return (red * scale, green * scale, blue * scale)
    }
    return (target, target, target)
  }

  /// Compress out-of-gamut chroma around luminance rather than clipping channels
  /// independently. The soft approach leaves margin for texture in saturated colors.
  public static func displayGamut(red: Double, green: Double, blue: Double)
    -> (red: Double, green: Double, blue: Double)
  {
    let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    guard y > 0, y < 1 else { return (y, y, y) }
    let dr = red - y
    let dg = green - y
    let db = blue - y
    func distance(_ d: Double) -> Double { d >= 0 ? d / (1 - y) : -d / y }
    let extent = max(distance(dr), distance(dg), distance(db))
    guard extent > 0.8 else { return (red, green, blue) }
    let d = extent - 0.8
    let scale = (0.8 + 0.2 * d / (d + 0.2)) / extent
    return (y + dr * scale, y + dg * scale, y + db * scale)
  }
}
