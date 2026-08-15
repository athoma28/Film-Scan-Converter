import Foundation

/// Named luminance standards used by the different processing pipelines.
/// Keeping the coefficients explicit prevents visually similar formulas from
/// being mistaken for interchangeable color spaces.
enum LuminanceStandards {
  static let rec2020 = Weights(blue: 0.0593017, green: 0.6780, red: 0.2626983)
  static let rec709 = Weights(blue: 0.0722, green: 0.7152, red: 0.2126)
  static let bt601 = Weights(blue: 0.114, green: 0.587, red: 0.299)

  struct Weights: Equatable, Sendable {
    let blue: Double
    let green: Double
    let red: Double
  }
}

enum ScalarMath {
  @inline(__always)
  static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = min(max((value - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
  }

  static func percentile(inSorted values: [Double], fraction: Double) -> Double {
    precondition((0...1).contains(fraction), "Percentile fraction must be between zero and one")
    guard values.count > 1 else { return values.first ?? 0 }

    let position = fraction * Double(values.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    let amount = position - Double(lower)
    return values[lower] + (values[upper] - values[lower]) * amount
  }

  @inline(__always)
  static func finiteClamped(_ value: Double, bound: Double) -> Double {
    if value.isNaN || value == -.infinity { return 0 }
    if value == .infinity { return bound }
    return min(max(value, -bound), bound)
  }
}

enum ColorConversion {
  /// Converts normalized HSV to RGB. The generic implementation specializes
  /// for both Float processing buffers and Double-valued UI color controls.
  @inline(__always)
  static func hsvToRGB<Value: BinaryFloatingPoint>(
    hue: Value,
    saturation: Value,
    value: Value
  ) -> (red: Value, green: Value, blue: Value) {
    guard saturation != 0 else {
      return (value, value, value)
    }

    let hueSector = hue * 6
    let sector = Int(hueSector.rounded(.down))
    let fraction = hueSector - Value(sector)
    let minimum = value * (1 - saturation)
    let falling = value * (1 - saturation * fraction)
    let rising = value * (1 - saturation * (1 - fraction))

    switch sector % 6 {
    case 0: return (value, rising, minimum)
    case 1: return (falling, value, minimum)
    case 2: return (minimum, value, rising)
    case 3: return (minimum, falling, value)
    case 4: return (rising, minimum, value)
    default: return (value, minimum, falling)
    }
  }
}
