import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Explicit RAW detail requests", .serialized)
@MainActor
struct RawDetailRequestTests {
  @Test(
    "Load RAW Preview cancels an active inspect pass and directly loads full sensor detail",
    .enabled(
      if: FileManager.default.fileExists(
        atPath: SampleRawCorpus.url(relativePath: "fuji400-fresh/DSCF2833.RAF").path)))
  func explicitRequestSupersedesInspect() async throws {
    let probe = InspectCancellationProbe()
    let model = AppModel(previewMemoryBudget: 1)
    model.rawInspectDecodeHook = { try probe.holdUntilCancelled() }
    defer {
      model.rawInspectDecodeHook = nil
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([SampleRawCorpus.url(relativePath: "fuji400-fresh/DSCF2833.RAF")])
    try await waitUntil { probe.started }
    #expect(model.isUpgradingRawPreview)
    #expect(model.canLoadRawDetailPreview)
    model.loadRawDetailPreview()
    try await waitUntil { model.previewSourceKind == .rawFull && !model.isRendering }
    #expect(probe.cancelled)
    #expect(probe.calls == 1)
    #expect(model.fullResolutionPreviewDecodeCount == 1)
    #expect(!model.canLoadRawDetailPreview)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(45))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for RAW detail")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class InspectCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var didCancel = false
  var calls: Int { lock.withLock { count } }
  var started: Bool { calls > 0 }
  var cancelled: Bool { lock.withLock { didCancel } }

  func holdUntilCancelled() throws {
    lock.withLock { count += 1 }
    let deadline = Date().addingTimeInterval(15)
    do {
      while Date() < deadline {
        try RawDecodeCancellation.current?.checkCancellation()
        Thread.sleep(forTimeInterval: 0.005)
      }
    } catch {
      lock.withLock { didCancel = true }
      throw error
    }
  }
}
