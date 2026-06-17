import Foundation
import Testing

@testable import FilmScanConverterMac

private let appModelRepositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private var appModelRawCorpusAvailable: Bool {
  FileManager.default.fileExists(
    atPath: appModelRepositoryRoot.appending(path: "sample-raw").path
  )
}

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

  @Test("Export all decodes and writes imported files that were not selected yet")
  func exportAllDecodesUnloadedImports() async throws {
    let model = AppModel()
    let first = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_png8"
      )
    )
    let second = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "bmp",
        subdirectory: "Fixtures/decode_bmp8"
      )
    )
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-export-all-\(UUID().uuidString)", isDirectory: true)
    let sourceDir = workDir.appendingPathComponent("source", isDirectory: true)
    let destination = workDir.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let firstCopy = sourceDir.appendingPathComponent("first.png")
    let secondCopy = sourceDir.appendingPathComponent("second.bmp")
    try FileManager.default.copyItem(at: first, to: firstCopy)
    try FileManager.default.copyItem(at: second, to: secondCopy)

    model.importFiles([firstCopy, secondCopy])
    try await waitUntil { model.decodedImage != nil && model.previewImage != nil }
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)

    model.exportAll()
    try await waitUntil(timeout: .seconds(10)) { !model.isExporting && model.exportProgressCurrent == 2 }

    #expect(model.exportErrors.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.png").path))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("second.png").path))
    #expect(model.exportProgressTotal == 2)
  }

  @Test("Import predecodes the next file into the bounded preview cache")
  func importPredecodesNextFileIntoPreviewCache() async throws {
    let model = AppModel()
    let first = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_png8"
      )
    )
    let second = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "bmp",
        subdirectory: "Fixtures/decode_bmp8"
      )
    )
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-predecode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let firstCopy = workDir.appendingPathComponent("first.png")
    let secondCopy = workDir.appendingPathComponent("second.bmp")
    try FileManager.default.copyItem(at: first, to: firstCopy)
    try FileManager.default.copyItem(at: second, to: secondCopy)

    model.importFiles([firstCopy, secondCopy])
    try await waitUntil { model.decodedImage != nil && model.previewImage != nil }
    try await waitUntil { model.previewCacheSessionCount == 2 }

    model.selection = secondCopy
    model.loadSelection()

    #expect(model.decodedImage != nil)
    #expect(model.previewCacheSessionCount <= 2)
  }

  @Test(
    "RAW import shows embedded thumbnail before full decode swaps in",
    .enabled(if: appModelRawCorpusAvailable, "sample-raw corpus unavailable; AppModel RAW thumbnail-swap test skipped")
  )
  func rawImportShowsThumbnailBeforeFullDecodeSwap() async throws {
    let raw = repositoryRoot.appending(path: "sample-raw/DSCF2422.RAF")

    let model = AppModel()
    model.importFiles([raw])

    try await waitUntil(timeout: .seconds(3)) {
      model.isShowingEmbeddedRawPreview && model.previewImage != nil && model.decodedImage == nil
    }

    try await waitUntil(timeout: .seconds(10)) {
      !model.isShowingEmbeddedRawPreview && model.decodedImage != nil && model.previewImage != nil
    }
    #expect(model.decodedImage?.channels == 3)
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

  private var repositoryRoot: URL {
    appModelRepositoryRoot
  }
}
