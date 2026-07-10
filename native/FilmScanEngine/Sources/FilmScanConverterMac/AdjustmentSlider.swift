import SwiftUI

struct AdjustmentSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let neutral: Double
  var valueFormat: String = "%.3f"
  var unitSuffix: String = ""
  var step: Double = 0
  var responseExponent: Double = 1

  init(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    neutral: Double,
    valueFormat: String = "%.3f",
    unitSuffix: String = "",
    step: Double = 0,
    responseExponent: Double = 1
  ) {
    self.title = title
    self._value = value
    self.range = range
    self.neutral = neutral
    self.valueFormat = valueFormat
    self.unitSuffix = unitSuffix
    self.step = step
    self.responseExponent = max(responseExponent, 1)
  }

  @FocusState private var isFocused: Bool

  private var isAtNeutral: Bool {
    abs(value - neutral) < max(step > 0 ? step * 0.5 : 0.0005, 0.000_001)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(title)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer()
        Text(formattedValue)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 64, alignment: .trailing)
        Button {
          value = neutral
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 10, weight: .medium))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAtNeutral ? .tertiary : .secondary)
        .disabled(isAtNeutral)
        .help("Reset \(title)")
      }
      slider
        .controlSize(.small)
        .frame(height: 16)
        .focused($isFocused)
        .onTapGesture(count: 2) {
          value = neutral
        }
        .accessibilityValue(formattedValue)
        .accessibilityLabel(title)
        .help("Double-click to reset.")
    }
  }

  @ViewBuilder
  private var slider: some View {
    if step > 0 && responseExponent == 1 {
      Slider(value: $value, in: range, step: step)
    } else {
      Slider(value: responseBinding, in: range)
    }
  }

  private var responseBinding: Binding<Double> {
    Binding(
      get: {
        AdjustmentSliderResponse.position(
          for: value,
          range: range,
          neutral: neutral,
          exponent: responseExponent
        )
      },
      set: {
        value = AdjustmentSliderResponse.value(
          for: $0,
          range: range,
          neutral: neutral,
          exponent: responseExponent
        )
      }
    )
  }

  private var formattedValue: String {
    let base = String(format: valueFormat, value)
    guard !unitSuffix.isEmpty else { return base }
    return "\(base) \(unitSuffix)"
  }
}

enum AdjustmentSliderResponse {
  static func value(
    for position: Double,
    range: ClosedRange<Double>,
    neutral: Double,
    exponent: Double
  ) -> Double {
    let boundedPosition = min(max(position, range.lowerBound), range.upperBound)
    guard exponent > 1 else { return boundedPosition }
    let span = boundedPosition < neutral
      ? neutral - range.lowerBound
      : range.upperBound - neutral
    guard span > 0 else { return neutral }
    let normalized = (boundedPosition - neutral) / span
    let direction = normalized < 0 ? -1.0 : 1.0
    return neutral + direction * pow(abs(normalized), exponent) * span
  }

  static func position(
    for value: Double,
    range: ClosedRange<Double>,
    neutral: Double,
    exponent: Double
  ) -> Double {
    let boundedValue = min(max(value, range.lowerBound), range.upperBound)
    guard exponent > 1 else { return boundedValue }
    let span = boundedValue < neutral
      ? neutral - range.lowerBound
      : range.upperBound - neutral
    guard span > 0 else { return neutral }
    let normalized = (boundedValue - neutral) / span
    let direction = normalized < 0 ? -1.0 : 1.0
    return neutral + direction * pow(abs(normalized), 1 / exponent) * span
  }
}
