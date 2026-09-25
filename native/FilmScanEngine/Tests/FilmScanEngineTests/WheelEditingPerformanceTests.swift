import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Atomic color wheel editing", .serialized)
@MainActor
struct WheelEditingPerformanceTests {
  @Test(
    "Each wheel event submits one complete value and a drag remains one persisted history step",
    arguments: ["Highlights", "Midtones", "Shadows"])
  func wheelEventsPublishOnceAndUndoTogether(wheel: String) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-wheel-edit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let model = AppModel(settingsStore: store)
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
    let baseline = model.parameters
    let action = "\(wheel) Color Wheel"
    let observation = ModelChangeObservation { _ = model.parameters }
    let samples = [
      ColorWheel(hue: 35, strength: 0.1),
      ColorWheel(hue: 95, strength: 0.3),
      ColorWheel(hue: 205, strength: 0.7),
    ]

    model.beginEditingGesture(named: action)
    for value in samples {
      let submissions = model.renderStats.submittedSnapshots
      let changesBefore = observation.count
      set(value, wheel: wheel, model: model)
      #expect(model.renderStats.submittedSnapshots == submissions + 1)
      #expect(observation.count == changesBefore + 1)
      #expect(selectedWheel(wheel, in: model.parameters) == value)
    }
    let finalValue = try #require(samples.last)
    let submissions = model.renderStats.submittedSnapshots
    set(finalValue, wheel: wheel, model: model)
    #expect(model.renderStats.submittedSnapshots == submissions)
    #expect(observation.count == samples.count)
    model.endEditingGesture()
    try await waitUntil { !model.isRendering }
    try await model.flushSettings()
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(model.undoActionName == action)
    #expect(
      try store.loadState().settingsByPath[input.standardizedFileURL.path]
        .map { selectedWheel(wheel, in: $0) } == finalValue)

    model.undo()
    #expect(model.parameters == baseline)
    #expect(!model.canUndo)
    #expect(model.redoActionName == action)
    model.redo()
    #expect(selectedWheel(wheel, in: model.parameters) == finalValue)
    #expect(!model.canRedo)
    try await model.flushSettings()
    let persisted = try #require(
      store.loadState().settingsByPath[input.standardizedFileURL.path])
    #expect(selectedWheel(wheel, in: persisted) == finalValue)
    // FilmNegativeParams deliberately omits source-derived medians from Codable.
    var expectedPersisted = model.parameters
    expectedPersisted.filmNegativeParams.measuredMedians = nil
    #expect(persisted == expectedPersisted)

    // A wheel reset retains its hue and clears only its strength in one event.
    let beforeReset = model.renderStats.submittedSnapshots
    set(ColorWheel(hue: finalValue.hue, strength: 0), wheel: wheel, model: model)
    #expect(model.renderStats.submittedSnapshots == beforeReset + 1)
    #expect(
      selectedWheel(wheel, in: model.parameters) == ColorWheel(hue: finalValue.hue, strength: 0))
    model.undo()
    #expect(selectedWheel(wheel, in: model.parameters) == finalValue)
    try await waitUntil { !model.isRendering }
    try await model.flushSettings()
  }

  private func set(_ value: ColorWheel, wheel: String, model: AppModel) {
    switch wheel {
    case "Highlights": model.setHighlightWheel(hue: value.hue, strength: value.strength)
    case "Midtones": model.setMidtoneWheel(hue: value.hue, strength: value.strength)
    default: model.setShadowWheel(hue: value.hue, strength: value.strength)
    }
  }

  private func selectedWheel(_ wheel: String, in parameters: ProcessingParameters) -> ColorWheel {
    switch wheel {
    case "Highlights": parameters.highlightWheel
    case "Midtones": parameters.midtoneWheel
    default: parameters.shadowWheel
    }
  }

  private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !ready() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}
