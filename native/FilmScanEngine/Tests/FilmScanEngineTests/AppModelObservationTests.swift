import FilmScanEngine
import Foundation
import Observation
import Testing

@testable import FilmScanConverterMac

/// Re-arm synchronously at will-change so multiple mutations in one setter are
/// counted individually, as they were by the former Combine subscription.
@MainActor
final class ModelChangeObservation {
  private let read: () -> Void
  private(set) var count = 0

  init(_ read: @escaping () -> Void) {
    self.read = read
    observe()
  }

  private func observe() {
    withObservationTracking(read) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.count += 1
        self.observe()
      }
    }
  }
}

@Suite("Independent editing and preview observations", .serialized)
@MainActor
struct AppModelObservationTests {
  @Test("Rendering does not invalidate parameter controls, availability, or undo menus")
  func previewAndControlsObserveIndependently() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-observation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(profileStore: ProfileStore(baseDirectory: directory))
    let availability = ModelChangeObservation { _ = model.hasPreviewImage }
    model.importFiles([input])
    try await waitUntil {
      model.hasPreviewImage && !model.isLoading && !model.isRendering
        && model.previewStatisticsRevision == model.publishedRenderRevision
    }
    #expect(availability.count == 1)
    let parameters = ModelChangeObservation { _ = model.parameters }
    let preview = ModelChangeObservation { _ = model.previewImage }
    let menus = ModelChangeObservation {
      _ = model.canUndo
      _ = model.canRedo
    }
    model.beginEditingGesture(named: "Exposure")
    model.setExposureEV(0.25)
    #expect(parameters.count == 1)
    #expect(preview.count == 0)
    try await waitUntil { !model.isRendering }
    #expect(preview.count == 1)
    #expect(parameters.count == 1)
    #expect(availability.count == 1)
    #expect(menus.count == 0)
    model.endEditingGesture()
    #expect(menus.count > 0)
    #expect(model.undoActionName == "Exposure")
    // Statistics are intentionally throttled during the gesture; release
    // flushes the final sample without notifying parameter-only observers.
    try await waitUntil { model.previewStatisticsRevision == model.publishedRenderRevision }
    #expect(parameters.count == 1)
    #expect(preview.count == 1)
    model.undo()
    try await waitUntil { !model.isRendering }
    #expect(parameters.count == 2)
    #expect(availability.count == 1)
    #expect(model.parameters.photoAdjustments.exposureEV == 0)
    model.selection = nil
    model.loadSelection()
    #expect(!model.hasPreviewImage)
    #expect(availability.count == 2)
  }

  private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !ready() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}
