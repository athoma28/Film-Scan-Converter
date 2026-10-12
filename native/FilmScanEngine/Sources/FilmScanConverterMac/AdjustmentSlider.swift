import SwiftUI

typealias EditingGestureAction = @MainActor @Sendable (String, Bool) -> Void
typealias AdjustmentEditingSource = @MainActor @Sendable () -> String?

private struct EditingGestureActionKey: EnvironmentKey {
  static let defaultValue: EditingGestureAction = { _, _ in }
}

private struct AdjustmentEditingSourceKey: EnvironmentKey {
  static let defaultValue: AdjustmentEditingSource = { nil }
}

extension EnvironmentValues {
  var editingGestureAction: EditingGestureAction {
    get { self[EditingGestureActionKey.self] }
    set { self[EditingGestureActionKey.self] = newValue }
  }

  /// Read at commit time so a late focus-loss cannot apply a previous scan's draft.
  var adjustmentEditingSource: AdjustmentEditingSource {
    get { self[AdjustmentEditingSourceKey.self] }
    set { self[AdjustmentEditingSourceKey.self] = newValue }
  }
}

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
  @Environment(\.editingGestureAction) private var editingGestureAction
  @Environment(\.locale) private var locale

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
        AdjustmentValueField(
          title: title, value: $value, range: range,
          valueFormat: valueFormat, unitSuffix: unitSuffix, step: step
        )
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
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
          guard isFocused, !press.modifiers.contains(.command),
            !press.modifiers.contains(.control), !press.modifiers.contains(.option)
          else { return .ignored }
          let direction = press.key == .leftArrow || press.key == .downArrow ? -1.0 : 1.0
          applyValue(
            keyboardValue(
              from: value, direction: direction, coarse: press.modifiers.contains(.shift))
          )
          return .handled
        }
        .help("Double-click to reset. Arrow keys adjust precisely; Shift-arrow adjusts faster.")
    }
  }

  private func applyValue(_ nextValue: Double) {
    guard nextValue != value else { return }
    editingGestureAction(title, true)
    value = nextValue
    editingGestureAction(title, false)
  }

  private func keyboardValue(from value: Double, direction: Double, coarse: Bool) -> Double {
    AdjustmentNumericValue.adjusted(
      value, direction: direction, range: range, step: step,
      valueFormat: valueFormat, coarse: coarse
    )
  }

  @ViewBuilder
  private var slider: some View {
    if step > 0 && responseExponent == 1 {
      Slider(
        value: $value,
        in: range,
        step: step,
        onEditingChanged: { editingGestureAction(title, $0) }
      )
    } else {
      Slider(
        value: responseBinding,
        in: range,
        onEditingChanged: { editingGestureAction(title, $0) }
      )
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
    let base = String(format: valueFormat, locale: locale, value)
    guard !unitSuffix.isEmpty else { return base }
    return "\(base) \(unitSuffix)"
  }
}

/// Buffered exact entry shared by regular controls and the compact grading columns.
struct AdjustmentValueField: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var valueFormat: String = "%.3f"
  var unitSuffix: String = ""
  var step: Double = 0
  var width: CGFloat = 76
  var font: Font = .caption

  @FocusState private var isValueFocused: Bool
  @State private var valueDraft: AdjustmentValueDraft?
  @State private var invalidEntry = false
  @Environment(\.editingGestureAction) private var editingGestureAction
  @Environment(\.adjustmentEditingSource) private var editingSource
  @Environment(\.locale) private var locale

  @ViewBuilder
  var body: some View {
    HStack(spacing: 0) {
      numericValue
    }
    .onChange(of: isValueFocused) { _, focused in
      if !focused { commitValueDraft(discardInvalid: true) }
    }
    .onChange(of: value) { _, newValue in
      if let draft = valueDraft, draft.originalValue != newValue { cancelValueDraft() }
    }
    .onChange(of: editingSource()) { cancelValueDraft() }
    .onDisappear { cancelValueDraft() }
  }

  @ViewBuilder
  private var numericValue: some View {
    if valueDraft != nil {
      HStack(spacing: 3) {
        TextField(
          title,
          text: Binding(
            get: { valueDraft?.text ?? "" },
            set: {
              valueDraft?.text = $0
              invalidEntry = false
            }
          )
        )
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .focused($isValueFocused)
        .onAppear { isValueFocused = true }
        .onSubmit { commitValueDraft(discardInvalid: false) }
        .onExitCommand { cancelValueDraft() }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
          guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
            !press.modifiers.contains(.option), let draft = valueDraft,
            let parsed = AdjustmentNumericValue.parse(draft.text, locale: locale)
          else { return .ignored }
          let next = keyboardValue(
            from: parsed, direction: press.key == .upArrow ? 1 : -1,
            coarse: press.modifiers.contains(.shift)
          )
          valueDraft?.text = numericString(next)
          invalidEntry = false
          return .handled
        }
        .accessibilityLabel("\(title) value")
        .accessibilityHint(
          "Press Return to apply or Escape to cancel. Up and Down adjust precisely.")
        if !unitSuffix.isEmpty { Text(unitSuffix).foregroundStyle(.secondary) }
      }
      .font(font)
      .monospacedDigit()
      .padding(.horizontal, 3)
      .frame(width: width, alignment: .trailing)
      .padding(.vertical, 2)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
      .overlay {
        RoundedRectangle(cornerRadius: 3)
          .stroke(invalidEntry ? Color.red : Color.accentColor, lineWidth: 1)
      }
      .help(
        invalidEntry ? "Enter a valid number. Escape cancels." : "Return applies; Escape cancels.")
    } else {
      Button {
        valueDraft = AdjustmentValueDraft(
          value: value, text: numericString(value), source: editingSource()
        )
        invalidEntry = false
      } label: {
        Text(formattedValue)
          .font(font)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: width, alignment: .trailing)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Edit \(title) value")
      .accessibilityValue(formattedValue)
      .help("Click to enter an exact value.")
    }
  }

  private func commitValueDraft(discardInvalid: Bool) {
    guard let draft = valueDraft else { return }
    guard draft.matches(value: value, source: editingSource()) else {
      cancelValueDraft()
      return
    }
    guard let committed = draft.committedValue(range: range, step: step, locale: locale) else {
      if discardInvalid { cancelValueDraft() } else { invalidEntry = true }
      return
    }
    cancelValueDraft()
    applyValue(committed)
  }

  private func cancelValueDraft() {
    valueDraft = nil
    invalidEntry = false
    isValueFocused = false
  }

  private func applyValue(_ nextValue: Double) {
    guard nextValue != value else { return }
    editingGestureAction(title, true)
    value = nextValue
    editingGestureAction(title, false)
  }

  private func keyboardValue(from value: Double, direction: Double, coarse: Bool) -> Double {
    AdjustmentNumericValue.adjusted(
      value, direction: direction, range: range, step: step,
      valueFormat: valueFormat, coarse: coarse
    )
  }

  private func numericString(_ value: Double) -> String {
    String(format: valueFormat, locale: locale, value)
  }

  private var formattedValue: String {
    let base = numericString(value)
    guard !unitSuffix.isEmpty else { return base }
    return "\(base) \(unitSuffix)"
  }
}

struct AdjustmentValueDraft {
  let originalValue: Double
  let initialText: String
  let source: String?
  var text: String

  init(value: Double, text: String, source: String?) {
    originalValue = value
    initialText = text
    self.source = source
    self.text = text
  }

  func matches(value: Double, source: String?) -> Bool {
    originalValue == value && self.source == source
  }

  func committedValue(range: ClosedRange<Double>, step: Double, locale: Locale) -> Double? {
    // Merely focusing a rounded display must not round the stored adjustment.
    if text == initialText { return originalValue }
    guard let parsed = AdjustmentNumericValue.parse(text, locale: locale) else { return nil }
    return AdjustmentNumericValue.constrained(parsed, range: range, step: step)
  }
}

enum AdjustmentNumericValue {
  static func parse(_ text: String, locale: Locale) -> Double? {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "−", with: "-")
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.isLenient = false
    formatter.usesGroupingSeparator = false
    let separator = NSRegularExpression.escapedPattern(for: formatter.decimalSeparator ?? ".")
    // NumberFormatter alone accepts numeric prefixes such as "1.2abc". Require
    // the complete draft; grouping separators are intentionally not accepted.
    let pattern = "^[+-]?(?:\\p{Nd}+(?:\(separator)\\p{Nd}*)?|\(separator)\\p{Nd}+)$"
    let signedInput = input.hasPrefix("+") ? String(input.dropFirst()) : input
    guard input.range(of: pattern, options: .regularExpression) != nil,
      let number = formatter.number(from: signedInput)?.doubleValue, number.isFinite
    else { return nil }
    return number
  }

  static func constrained(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
    let bounded = min(max(value, range.lowerBound), range.upperBound)
    guard step > 0, step.isFinite else { return bounded }
    let stepped = range.lowerBound + ((bounded - range.lowerBound) / step).rounded() * step
    return min(max(stepped, range.lowerBound), range.upperBound)
  }

  static func adjusted(
    _ value: Double, direction: Double, range: ClosedRange<Double>, step: Double,
    valueFormat: String, coarse: Bool
  ) -> Double {
    let precision =
      valueFormat.range(of: "(?<=\\.)[0-9]+(?=f)", options: .regularExpression)
      .flatMap { Int(valueFormat[$0]) } ?? 3
    let increment = step > 0 ? step : pow(10, -Double(min(precision, 9)))
    let result = value + direction * increment * (coarse ? 10 : 1)
    return constrained(result, range: range, step: step)
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
    let span =
      boundedPosition < neutral
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
    let span =
      boundedValue < neutral
      ? neutral - range.lowerBound
      : range.upperBound - neutral
    guard span > 0 else { return neutral }
    let normalized = (boundedValue - neutral) / span
    let direction = normalized < 0 ? -1.0 : 1.0
    return neutral + direction * pow(abs(normalized), 1 / exponent) * span
  }
}
