import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Native app model integration")
@MainActor
struct AppModelTests {
  @Test("Actual render queue displays the latest rapid parameter update")
  func actualRenderQueueDisplaysLatestUpdate() async throws {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_png8"
      )
    )

    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil && model.previewImage != nil }
    model.setFilmType(.colourNegative)
    for value in stride(from: -100, through: 100, by: 5) {
      model.setTemperature(value)
    }
    try await waitUntil { !model.isRendering && model.parameters.temperature == 100 }

    #expect(model.previewImage != nil)
    #expect(model.parameters.temperature == 100)
    #expect(model.renderStats.submittedSnapshots > model.renderStats.displayedRenders)
    #expect(model.renderStats.droppedSnapshots > 0)
  }

  private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        Issue.record("Timed out waiting for app model state")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
