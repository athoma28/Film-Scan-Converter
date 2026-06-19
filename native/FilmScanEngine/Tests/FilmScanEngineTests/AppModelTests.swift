import Foundation
import FilmScanEngine
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
  private enum WaitError: Error {
    case timedOut
  }

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
    try await waitUntil { model.hasCachedPreview(for: secondCopy) }

    model.selection = secondCopy
    model.loadSelection()

    #expect(model.decodedImage != nil)
    #expect(model.previewCacheSessionCount <= 2)
    #expect(model.hasCachedPreview(for: secondCopy))
  }

  @Test("Export all assigns unique destinations to duplicate basenames")
  func exportAllAvoidsDuplicateBasenameCollisions() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_png8"
      )
    )
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-export-collision-\(UUID().uuidString)", isDirectory: true)
    let firstDir = workDir.appendingPathComponent("first", isDirectory: true)
    let secondDir = workDir.appendingPathComponent("second", isDirectory: true)
    let destination = workDir.appendingPathComponent("export", isDirectory: true)
    for directory in [firstDir, secondDir, destination] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: workDir) }

    let first = firstDir.appendingPathComponent("scan.png")
    let second = secondDir.appendingPathComponent("scan.png")
    try FileManager.default.copyItem(at: input, to: first)
    try FileManager.default.copyItem(at: input, to: second)

    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.decodedImage != nil }
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)
    model.exportAll()
    try await waitUntil(timeout: .seconds(10)) {
      !model.isExporting && model.exportProgressCurrent == 2
    }

    #expect(model.exportErrors.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("scan.png").path))
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("scan-2.png").path))
  }

  @Test("Rebate measurement resets when selection changes")
  func rebateMeasurementResetsOnSelectionChange() async throws {
    let first = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let second = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "bmp",
        subdirectory: "Fixtures/decode_bmp8"))
    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.decodedImage != nil }
    let image = try #require(model.decodedImage)
    model.measureRebateRegion(
      ImageRegion(x: 0, y: 0, width: image.width, height: image.height))
    try await waitUntil { model.selectedRebateMeasurement != nil }

    model.selection = second
    model.loadSelection()

    #expect(model.selectedRebateMeasurement == nil)
    #expect(model.selectedRebateRegion == nil)
    #expect(model.rebateCandidates.isEmpty)
    #expect(!model.isRebateDetectionRunning)
  }

  @Test("Rebate detection uses the bounded preview proxy")
  func rebateDetectionUsesBoundedPreviewProxy() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-rebate-proxy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("bordered.png")
    let width = 900
    let height = 600
    var pixels = [UInt16](repeating: 20_000, count: width * height * 3)
    for y in 0..<70 {
      for x in 0..<width {
        let base = (y * width + x) * 3
        pixels[base] = 60_000
        pixels[base + 1] = 60_000
        pixels[base + 2] = 60_000
      }
    }
    try UInt16Image(
      width: width, height: height, channels: 3, pixels: pixels
    ).write(to: input, format: .png, parameters: ExportParameters(format: .png))

    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil }
    model.detectRebate()
    try await waitUntil { !model.isRebateDetectionRunning }

    #expect(model.decodedImage?.width == width)
    #expect(!model.rebateCandidates.isEmpty)
    #expect(
      model.rebateCandidates.allSatisfy {
        $0.region.x + $0.region.width <= 640
          && $0.region.y + $0.region.height <= 640
      })
  }

  @Test("Roll profile save reports persistence failures")
  func rollProfileSaveReportsPersistenceFailure() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-profile-failure-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: workDir)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let model = AppModel(profileStore: ProfileStore(baseDirectory: workDir))
    let measurement = FilmBaseMeasurement(
      baseDensity: BGRChannelValues(blue: 0.2, green: 0.3, red: 0.4),
      medianTransmittance: BGRChannelValues(blue: 0.6, green: 0.5, red: 0.4),
      trimmedMeanTransmittance: BGRChannelValues(blue: 0.6, green: 0.5, red: 0.4),
      sampleCount: 10,
      rejectedFraction: 0.2,
      confidence: 0.8
    )
    let candidate = AutomaticRebateCandidate(
      region: ImageRegion(x: 0, y: 0, width: 2, height: 2),
      measurement: measurement,
      confidence: 0.8
    )

    model.createRollProfile(from: candidate)

    #expect(model.rollProfile == nil)
    #expect(model.rebateStatus.hasPrefix("Unable to save roll profile:"))
  }

  @Test("Roll profile save persists the selected candidate measurement")
  func rollProfileSavePersistsCandidateMeasurement() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-profile-success-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProfileStore(baseDirectory: directory)
    let model = AppModel(profileStore: store)
    let measurement = FilmBaseMeasurement(
      baseDensity: BGRChannelValues(blue: 0.21, green: 0.31, red: 0.41),
      medianTransmittance: BGRChannelValues(blue: 0.6, green: 0.5, red: 0.4),
      trimmedMeanTransmittance: BGRChannelValues(blue: 0.6, green: 0.5, red: 0.4),
      sampleCount: 20,
      rejectedFraction: 0.2,
      confidence: 0.9
    )
    let candidate = AutomaticRebateCandidate(
      region: ImageRegion(x: 0, y: 0, width: 4, height: 4),
      measurement: measurement,
      confidence: 0.9
    )

    model.selectRebateCandidate(candidate)
    model.createRollProfile(from: candidate)

    let profile = try #require(model.rollProfile)
    let loadedValue = try store.loadRollProfile(rollID: profile.rollID)
    let loaded = try #require(loadedValue)
    #expect(loaded.measuredBaseDensity == measurement.baseDensity)
    #expect(loaded.measurementCount == 1)
    #expect(model.rebateStatus.hasPrefix("Roll profile saved as "))
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
    timeout: Duration = .seconds(10),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        Issue.record("Timed out waiting for app model state")
        throw WaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private var repositoryRoot: URL {
    appModelRepositoryRoot
  }
}
