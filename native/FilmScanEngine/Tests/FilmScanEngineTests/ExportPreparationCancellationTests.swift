import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("App export preparation cancellation", .serialized)
@MainActor
struct ExportPreparationCancellationTests {
  @Test("Cancelling a standard-image decode drains it without decoding the next batched image")
  func cancellationDoesNotStartNextStandardDecode() async throws {
    try await verifyCancellation(committedBeforeCancellation: 0)
  }

  @Test("Cancellation reports committed images after a complete batch and a held next decode")
  func cancellationReportsCommittedImages() async throws {
    try await verifyCancellation(committedBeforeCancellation: 2)
  }

  private func verifyCancellation(committedBeforeCancellation: Int) async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fsc-export-preparation-cancel-\(UUID().uuidString)", isDirectory: true)
    let sourcesDirectory = directory.appendingPathComponent("sources", isDirectory: true)
    let destination = directory.appendingPathComponent("output", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourcesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceCount = committedBeforeCancellation == 0 ? 2 : 3
    let sources = (0..<sourceCount).map {
      sourcesDirectory.appendingPathComponent("scan-\($0).png")
    }
    let committedSources = Array(sources.prefix(committedBeforeCancellation))
    let attemptedSources = Array(sources.prefix(committedBeforeCancellation + 1))
    for source in sources { try FileManager.default.copyItem(at: input, to: source) }
    let originalBytes = try sources.map { try Data(contentsOf: $0) }
    let expected = try StandardImageDecoder.decode(input)
    let probe = StandardExportDecodeGate(heldURL: sources[committedBeforeCancellation])
    let model = AppModel(previewMemoryBudget: 1)
    defer {
      probe.release()
      model.cancelExport()
      model.closeAllScans()
    }
    model.importFiles(sources)
    try await waitUntil {
      model.previewImage != nil && !model.isLoading && !model.isRendering
        && !model.isAnalyzingScanStacks && !model.previewBackgroundWorkIsActive
    }
    for source in sources {
      model.selection = source
      model.loadSelection()
      try await waitUntil { !model.isLoading && !model.isRendering }
      model.setFilmType(.cropOnly)
      try await waitUntil { !model.isRendering }
    }
    model.standardImageExportDecoder = probe.decode
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)
    model.exportAll()
    try await waitUntil { probe.isHeld }
    #expect(probe.startedURLs == attemptedSources)
    #expect(!probe.decodedOnMainThread)
    #expect(model.exportProgressCurrent == committedBeforeCancellation)

    model.cancelExport()
    await Task.yield()
    #expect(model.isExporting, "The active synchronous decode must drain before completion")
    #expect(probe.completedURLs == committedSources)
    #expect(probe.startedURLs == attemptedSources)
    probe.release()
    try await waitUntil { !model.isExporting }

    #expect(probe.startedURLs == attemptedSources)
    #expect(probe.completedURLs == attemptedSources)
    #expect(model.exportErrors.isEmpty)
    #expect(model.activeExportFilename == nil)
    #expect(model.exportQueueCount == 0)
    #expect(
      model.status
        == "Export cancelled. Saved \(committedBeforeCancellation) of \(sources.count) images.")
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
        == Set(committedSources.map(\.lastPathComponent)))
    for source in committedSources {
      #expect(
        try StandardImageDecoder.decode(
          destination.appendingPathComponent(source.lastPathComponent)) == expected)
    }
    #expect(model.fullResolutionExportDecodeCount == 0)
    #expect(model.retainedExportDecodePath == nil)

    // Cancellation does not poison another run: all sources must decode and
    // commit normally once the held stage has drained.
    model.exportAll()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(probe.startedURLs == attemptedSources + sources)
    #expect(probe.completedURLs == probe.startedURLs)
    #expect(model.exportProgressCurrent == sources.count)
    let retryOutputs = sources.enumerated().map { index, source in
      destination.appendingPathComponent(
        index < committedBeforeCancellation
          ? source.deletingPathExtension().lastPathComponent + "-2.png"
          : source.lastPathComponent)
    }
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
        == Set(committedSources.map(\.lastPathComponent) + retryOutputs.map(\.lastPathComponent)))
    for output in retryOutputs {
      #expect(try StandardImageDecoder.decode(output) == expected)
    }
    #expect(try sources.map { try Data(contentsOf: $0) } == originalBytes)
    model.closeAllScans()
    try await waitUntil { !model.isRendering && !model.previewBackgroundWorkIsActive }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for export preparation")
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

/// Hold one synchronous stage without timing assumptions. Later retry decodes
/// proceed normally, and every call still uses the production standard decoder.
private final class StandardExportDecodeGate: @unchecked Sendable {
  private let condition = NSCondition()
  private let heldURL: URL
  private var released = false
  private var held = false
  private var used = false
  private var started: [URL] = []
  private var completed: [URL] = []
  private var onMainThread = false

  init(heldURL: URL) { self.heldURL = heldURL }

  var isHeld: Bool { condition.withLock { held } }
  var startedURLs: [URL] { condition.withLock { started } }
  var completedURLs: [URL] { condition.withLock { completed } }
  var decodedOnMainThread: Bool { condition.withLock { onMainThread } }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }

  func decode(_ url: URL) throws -> UInt16Image {
    condition.lock()
    started.append(url)
    onMainThread = onMainThread || Thread.isMainThread
    if url == heldURL && !used {
      used = true
      held = true
      let deadline = Date().addingTimeInterval(15)
      while !released {
        guard condition.wait(until: deadline) else {
          held = false
          condition.unlock()
          throw DecodeError.gateTimedOut
        }
      }
      held = false
    }
    condition.unlock()
    let image = try StandardImageDecoder.decode(url)
    condition.withLock { completed.append(url) }
    return image
  }

  private enum DecodeError: Error { case gateTimedOut }
}
