import AppKit
import Observation
import SwiftUI
import Testing

@testable import FilmScanConverterMac

@Suite("Adjustment numeric entry")
struct AdjustmentValueEditingTests {
  private let english = Locale(identifier: "en_US")

  @Test("Exact entry respects the locale decimal separator")
  func localeParsing() {
    #expect(AdjustmentNumericValue.parse("  +1.25  ", locale: english) == 1.25)
    #expect(AdjustmentNumericValue.parse("−0.25", locale: english) == -0.25)
    #expect(AdjustmentNumericValue.parse("1,25", locale: Locale(identifier: "de_DE")) == 1.25)
    #expect(AdjustmentNumericValue.parse("1.25", locale: Locale(identifier: "de_DE")) == nil)
    #expect(AdjustmentNumericValue.parse("1,000", locale: english) == nil)
  }

  @Test("Incomplete, nonfinite, and partially numeric input cannot commit")
  func rejectsInvalidInput() {
    for input in ["", " ", "-", "+", ".", "1.2abc", "1.2.3", "NaN", "inf", "∞", "1e999"] {
      #expect(AdjustmentNumericValue.parse(input, locale: english) == nil, "Input: \(input)")
    }
  }

  @Test("Commit clamps out-of-range values and respects stepped controls")
  func constrainedCommit() {
    var draft = AdjustmentValueDraft(value: 25, text: "25", source: "scan-a")
    draft.text = "101.4"
    #expect(draft.committedValue(range: 0...100, step: 1, locale: english) == 100)
    draft.text = "-2"
    #expect(draft.committedValue(range: 0...100, step: 1, locale: english) == 0)
    draft.text = "24.6"
    #expect(draft.committedValue(range: 0...100, step: 1, locale: english) == 25)
    draft.text = "24.4"
    #expect(draft.committedValue(range: 0...100, step: 1, locale: english) == 24)
    #expect(AdjustmentNumericValue.constrained(0.46, range: 0.1...0.9, step: 0.2) == 0.5)
  }

  @Test("Focusing and leaving a value preserves hidden precision")
  func untouchedDraftPreservesPrecision() {
    let draft = AdjustmentValueDraft(value: 0.123456, text: "0.123", source: "scan-a")
    #expect(draft.committedValue(range: -1...1, step: 0, locale: english) == 0.123456)
  }

  @Test("Drafts reject another scan even when its parameter value matches")
  func rejectsStaleSourceOrValue() {
    let draft = AdjustmentValueDraft(value: 0.25, text: "0.250", source: "scan-a")
    #expect(draft.matches(value: 0.25, source: "scan-a"))
    #expect(!draft.matches(value: 0.25, source: "scan-b"))
    #expect(!draft.matches(value: 0.3, source: "scan-a"))
    #expect(!draft.matches(value: 0.25, source: nil))
  }

  @Test("Invalid edits never resolve to a model value")
  func invalidDraftDoesNotCommit() {
    var draft = AdjustmentValueDraft(value: 0.25, text: "0.250", source: "scan-a")
    draft.text = "-"
    #expect(draft.committedValue(range: -1...1, step: 0, locale: english) == nil)
    #expect(draft.originalValue == 0.25)
    draft.text = "0.375"
    #expect(draft.committedValue(range: -1...1, step: 0, locale: english) == 0.375)
  }

  @Test("Arrow nudges use displayed precision, Shift and legal step boundaries")
  func keyboardIncrements() {
    #expect(
      AdjustmentNumericValue.adjusted(
        0, direction: 1, range: -4...4, step: 0, valueFormat: "%.2f", coarse: false
      ) == 0.01)
    #expect(
      AdjustmentNumericValue.adjusted(
        0, direction: -1, range: -4...4, step: 0, valueFormat: "%.2f", coarse: true
      ) == -0.1)
    #expect(
      AdjustmentNumericValue.adjusted(
        4, direction: 1, range: -4...4, step: 0, valueFormat: "%.2f", coarse: false
      ) == 4)
    #expect(
      AdjustmentNumericValue.adjusted(
        25, direction: 1, range: 0...100, step: 1, valueFormat: "%.3f", coarse: false
      ) == 26)
  }
}

@Suite("Native adjustment value field", .serialized)
@MainActor
struct AdjustmentValueFieldInteractionTests {
  @Test("Native field buffers typing, commits Return and focus loss, and cancels Escape")
  func nativeCommitAndCancel() async throws {
    _ = NSApplication.shared
    let state = NumericEntryState()
    let window = NSWindow(
      contentRect: CGRect(x: -10_000, y: -10_000, width: 180, height: 80),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(
      rootView: AnyView(
        AdjustmentValueField(
          title: "Exposure",
          value: Binding(
            get: { state.value },
            set: {
              state.value = $0
              state.commits += 1
            }
          ), range: -4...4, valueFormat: "%.2f", width: 56
        )
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.adjustmentEditingSource) { state.source }
        .environment(\.editingGestureAction) { _, editing in state.gestures.append(editing) }
        .padding(12)
      ))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer {
      hosting.rootView = AnyView(EmptyView())
      window.contentView = nil
      window.close()
    }

    var editor = try await beginEditing(in: hosting, window: window)
    try await observeNativeTurn(
      "before typing", editor: editor, in: hosting, window: window, state: state)
    replaceText("0.50", in: editor)
    try await observeNativeTurn(
      "after typing", editor: editor, in: hosting, window: window, state: state)
    #expect(state.commits == 0)
    #expect(state.value == 0.123456)
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    try await waitUntil("Return commit", in: hosting, window: window) { state.value == 0.5 }
    #expect(state.commits == 1)
    #expect(state.gestures == [true, false])

    editor = try await beginEditing(in: hosting, window: window)
    try await observeNativeTurn(
      "before typing", editor: editor, in: hosting, window: window, state: state)
    replaceText("-0.75", in: editor)
    try await observeNativeTurn(
      "after typing", editor: editor, in: hosting, window: window, state: state)
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    try await waitUntil("Escape cancellation", in: hosting, window: window) {
      !hasEditableTextField(in: hosting)
    }
    #expect(state.value == 0.5)
    #expect(state.commits == 1)

    editor = try await beginEditing(in: hosting, window: window)
    try await observeNativeTurn(
      "before typing", editor: editor, in: hosting, window: window, state: state)
    replaceText("0.75", in: editor)
    try await observeNativeTurn(
      "after typing", editor: editor, in: hosting, window: window, state: state)
    try #require(window.makeFirstResponder(nil), "Native responder resignation was refused")
    try await waitUntil("focus-loss commit", in: hosting, window: window) { state.value == 0.75 }
    #expect(state.commits == 2)
    #expect(state.gestures == [true, false, true, false])

    // A selection change may beat the focus-loss callback even when both scans
    // have the same adjustment. The live source identity must reject that draft.
    editor = try await beginEditing(in: hosting, window: window)
    try await observeNativeTurn(
      "before typing", editor: editor, in: hosting, window: window, state: state)
    replaceText("1.25", in: editor)
    try await observeNativeTurn(
      "after typing", editor: editor, in: hosting, window: window, state: state)
    state.source = "scan-b"
    try #require(window.makeFirstResponder(nil), "Native responder resignation was refused")
    try await waitUntil("source-change cancellation", in: hosting, window: window) {
      !hasEditableTextField(in: hosting)
    }
    #expect(state.value == 0.75)
    #expect(state.commits == 2)
  }

  private func beginEditing(in hosting: NSView, window: NSWindow) async throws -> NSTextView {
    try await waitUntil("value button layout", in: hosting, window: window) {
      hosting.layoutSubtreeIfNeeded()
      return hosting.bounds.width > 0 && hosting.bounds.height > 0
        && !hasEditableTextField(in: hosting)
    }
    // This isolated SwiftUI host exposes no process-local AX children even
    // while its real native controls are present. Dispatch a real click only to
    // the centered numeric control in this test window instead.
    let point = hosting.convert(CGPoint(x: hosting.bounds.midX, y: hosting.bounds.midY), to: nil)
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: kind, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
      window.sendEvent(event)
    }
    try await waitUntil("text editor focus", in: hosting, window: window) {
      window.firstResponder is NSTextView
    }
    let editor = try #require(window.firstResponder as? NSTextView)
    try #require(editor.isFieldEditor && editor.window === window)
    try #require(
      editableTextFields(in: hosting).contains { $0.currentEditor() === editor },
      "The first responder must belong to this host's editable field")
    return editor
  }

  /// Hosted native input events need distinct run-loop opportunities for SwiftUI
  /// observation. Preserve the assertions and three-second commit deadline;
  /// this diagnostic makes no claim about rapid input in the product. A native
  /// owner check does not establish that SwiftUI observed its private FocusState.
  private func observeNativeTurn(
    _ label: String, editor: NSTextView, in hosting: NSView, window: NSWindow,
    state: NumericEntryState
  ) async throws {
    try await Task.sleep(for: .milliseconds(20))
    hosting.layoutSubtreeIfNeeded()
    let owner = try #require(
      editableTextFields(in: hosting).first { $0.currentEditor() === editor },
      "The field editor lost its owning native field before the next input event")
    try #require(
      window.firstResponder === editor && editor.window === window && editor.isFieldEditor)
    print(
      "NATIVE_FIELD_DIAGNOSTIC \(label): appActive=\(NSApplication.shared.isActive) "
        + "activationPolicy=\(NSApplication.shared.activationPolicy().rawValue) "
        + "windowKey=\(window.isKeyWindow) visible=\(window.isVisible) "
        + "editor=\(ObjectIdentifier(editor)) owner=\(ObjectIdentifier(owner)) "
        + "editorText=\(editor.string.debugDescription) fieldText=\(owner.stringValue.debugDescription) "
        + "value=\(state.value) commits=\(state.commits) gestures=\(state.gestures)")
  }

  private func editableTextFields(in view: NSView) -> [NSTextField] {
    let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
    return own + view.subviews.flatMap { editableTextFields(in: $0) }
  }

  private func hasEditableTextField(in view: NSView) -> Bool {
    if let field = view as? NSTextField, field.isEditable { return true }
    return view.subviews.contains { hasEditableTextField(in: $0) }
  }

  private func replaceText(_ text: String, in editor: NSTextView) {
    editor.insertText(
      text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
  }

  private func waitUntil(
    _ description: String, in hosting: NSView, window: NSWindow, ready: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !ready() {
      try #require(
        ContinuousClock.now < deadline,
        "Timed out waiting for \(description). \(nativeState(in: hosting, window: window))"
      )
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func nativeState(in hosting: NSView, window: NSWindow) -> String {
    let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    let state =
      "windowKey=\(window.isKeyWindow) visible=\(window.isVisible) "
      + "firstResponder=\(responder) hostingFrame=\(hosting.frame)"
    return state + "\n" + accessibilityTree(hosting)
  }

  private func accessibilityTree(_ element: any NSAccessibilityProtocol, depth: Int = 0) -> String {
    guard depth < 8 else { return "…" }
    let prefix = String(repeating: "  ", count: depth)
    var description =
      "\(prefix)\(type(of: element)): role=\(String(describing: element.accessibilityRole())) "
      + "label=\(String(describing: element.accessibilityLabel())) "
      + "title=\(String(describing: element.accessibilityTitle()))\n"
    for child in (element.accessibilityChildren() ?? []).prefix(12) {
      if let accessible = child as? any NSAccessibilityProtocol {
        description += accessibilityTree(accessible, depth: depth + 1)
      } else {
        description += "\(prefix)  child without NSAccessibilityProtocol: \(type(of: child))\n"
      }
    }
    return description
  }
}

@MainActor
@Observable
private final class NumericEntryState {
  var value = 0.123456
  var source = "scan-a"
  var commits = 0
  var gestures: [Bool] = []
}
