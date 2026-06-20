import SwiftUI

struct AdjustmentSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let neutral: Double
  var valueFormat: String = "%.3f"
  var unitSuffix: String = ""
  var step: Double = 0

  init(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    neutral: Double,
    valueFormat: String = "%.3f",
    unitSuffix: String = "",
    step: Double = 0
  ) {
    self.title = title
    self._value = value
    self.range = range
    self.neutral = neutral
    self.valueFormat = valueFormat
    self.unitSuffix = unitSuffix
    self.step = step
  }

  @FocusState private var isFocused: Bool

  private var isAtNeutral: Bool {
    abs(value - neutral) < max(step > 0 ? step * 0.5 : 0.0005, 0.000_001)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
          .font(.callout)
        Spacer()
        Text(formattedValue)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 48, alignment: .trailing)
        Button {
          value = neutral
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAtNeutral ? .tertiary : .secondary)
        .disabled(isAtNeutral)
        .help("Reset \(title)")
      }
      slider
        .controlSize(.small)
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
    if step > 0 {
      Slider(value: $value, in: range, step: step)
    } else {
      Slider(value: $value, in: range)
    }
  }

  private var formattedValue: String {
    let base = String(format: valueFormat, value)
    guard !unitSuffix.isEmpty else { return base }
    return "\(base) \(unitSuffix)"
  }
}
