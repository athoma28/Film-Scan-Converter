import AppKit
import CryptoKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Representative RAW roll workflow", .serialized)
@MainActor
struct RepresentativeRollWorkflowTests {
  @Test(
    "Apply an anchor look, edit an exception, compare, export selected, and re-export",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_REPRESENTATIVE_ROLL_TESTS"] == "1",
      "set RUN_REPRESENTATIVE_ROLL_TESTS=1 with the local Fuji 400 corpus"))
  func selectedLookComparisonAndExport() async throws {
    let relativePaths = [
      "fuji400-fresh/DSCF2833.RAF", "fuji400-fresh/DSCF2851.RAF", "fuji400-fresh/DSCF2856.RAF",
    ]
    let files = relativePaths.map(SampleRawCorpus.url(relativePath:))
    for file in files {
      try #require(
        FileManager.default.fileExists(atPath: file.path), "Missing \(file.lastPathComponent)")
    }
    let sourceHashes = try files.map(fileHash)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-real-roll-\(UUID().uuidString)", isDirectory: true)
    let destination = directory.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var exception = ProcessingParameters()
    exception.rotation = 1
    exception.flip = true
    exception.manualCrop = .init(x: 0.08, y: 0.12, width: 0.82, height: 0.76)
    exception.densityBaseDensity = .init(blue: 0.2, green: 0.3, red: 0.4)
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(settingsByPath: [files[2].standardizedFileURL.path: exception], editedPaths: []))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles(files)
    try await waitUntil("anchor preview") {
      model.previewImage != nil && !model.isRendering && !model.isLoading
    }
    model.setFilmType(.colourNegative)
    model.setExposureEV(0.5)
    model.setSemanticTemperature(12)
    model.selectedFiles = [files[2], files[0]]
    model.applyCurrentLookToSelectedFiles()
    #expect(model.hasEdits(for: files[0]))
    #expect(model.hasEdits(for: files[2]))
    #expect(!model.hasEdits(for: files[1]))

    #expect(model.selectAdjacentScan(offset: 1))
    try await waitUntil("unselected frame preview") { !model.isLoading && !model.isRendering }
    #expect(model.selection == files[1])
    #expect(model.parameters.photoAdjustments.exposureEV == 0)
    #expect(model.selectAdjacentScan(offset: 1))
    try await waitUntil("exception full-resolution preview") {
      model.previewSourceKind == .rawFull && !model.isRendering && !model.isLoading
    }
    #expect(model.parameters.photoAdjustments.exposureEV == 0.5)
    #expect(model.parameters.rotation == exception.rotation)
    #expect(model.parameters.flip == exception.flip)
    #expect(model.parameters.manualCrop == exception.manualCrop)
    #expect(model.parameters.densityBaseDensity == exception.densityBaseDensity)
    model.setExposureEV(-0.25)
    model.undo()
    #expect(model.parameters.photoAdjustments.exposureEV == 0.5)
    model.redo()
    #expect(model.parameters.photoAdjustments.exposureEV == -0.25)
    try await waitUntil("exception correction") { !model.isRendering }

    let correctedSize = try #require(model.previewImage?.size)
    let correctedHash = try previewHash(model)
    model.showOriginal = true
    try await waitUntil("original comparison") { !model.isRendering }
    #expect(model.previewImage?.size == correctedSize)
    #expect(try previewHash(model) != correctedHash)
    model.showOriginal = false
    try await waitUntil("restored correction") { !model.isRendering }
    #expect(try previewHash(model) == correctedHash)
    #expect(model.previewStatistics.sampleCount > 0)

    let dimensions = ImageGeometry.outputDimensions(
      source: try #require(model.sourcePixelDimensions), parameters: model.parameters)
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.tiff)
    model.setTiffCompression(.lzw)
    model.selectedFiles = [files[2], files[0]]
    model.exportSelected()
    #expect(model.isExporting)
    #expect(model.isActiveExport(for: files[0]))
    #expect(model.isPendingExport(for: files[2]))
    try await waitUntil("selected batch export") { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.exportProgressCurrent == 2)
    #expect(model.fullResolutionExportDecodeCount == 2)
    #expect(model.retainedExportDecodePath == files[2].standardizedFileURL.path)

    let firstOutput = destination.appendingPathComponent("DSCF2833.tiff")
    let exceptionOutput = destination.appendingPathComponent("DSCF2856.tiff")
    #expect(FileManager.default.fileExists(atPath: firstOutput.path))
    _ = try reopenedHash(
      firstOutput, dimensions: RawImageDecoder.fullResolutionDimensions(files[0]))
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("DSCF2851.tiff").path))
    let exportedHash = try reopenedHash(exceptionOutput, dimensions: dimensions)
    let firstFileHash = try fileHash(exceptionOutput)

    model.selectedFiles = [files[2]]
    model.setExposureEV(0.25)
    model.exportSelected()
    try await waitUntil("settings-only re-export") { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(model.fullResolutionExportDecodeCount == 2)
    #expect(model.fullResolutionExportDecodeCacheHits == 1)
    let reexport = destination.appendingPathComponent("DSCF2856-2.tiff")
    #expect(try reopenedHash(reexport, dimensions: dimensions) != exportedHash)
    #expect(try fileHash(exceptionOutput) == firstFileHash)

    #expect(model.selectAdjacentScan(offset: -1))
    #expect(model.retainedExportDecodePath == nil)
    try await waitUntil("return to unselected frame") { !model.isLoading && !model.isRendering }
    #expect(model.parameters.photoAdjustments.exposureEV == 0)
    let relaunched = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    relaunched.importFiles([files[2]])
    try await waitUntil("restored persisted exception") {
      !relaunched.isLoading && !relaunched.isRendering
    }
    #expect(relaunched.parameters.photoAdjustments.exposureEV == 0.25)
    #expect(relaunched.parameters.manualCrop == exception.manualCrop)
    #expect(!relaunched.canUndo)
    relaunched.selection = nil
    relaunched.loadSelection()

    #expect(try files.map(fileHash) == sourceHashes)
    let outputs = try FileManager.default.contentsOfDirectory(
      at: destination, includingPropertiesForKeys: nil)
    #expect(outputs.count == 3)
    for output in outputs { try FileManager.default.removeItem(at: output) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    print(
      "Representative roll passed: \(relativePaths.joined(separator: ", ")); 3 TIFFs reopened/removed; 2 authoritative decodes; 1 retained-decode hit; source hashes unchanged."
    )
  }

  private func waitUntil(_ stage: String, condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(180)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out: \(stage)")
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private func fileHash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func previewHash(_ model: AppModel) throws -> String {
    let image = try #require(model.previewImage)
    let cgImage = try #require(PreviewBitmap.cgImage(from: image))
    let data = try #require(cgImage.dataProvider?.data)
    return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
  }

  private func reopenedHash(_ url: URL, dimensions: PixelDimensions) throws -> String {
    let image = try StandardImageDecoder.decode(url)
    #expect(image.width == dimensions.width)
    #expect(image.height == dimensions.height)
    #expect(image.channels == 3)
    return image.pixels.withUnsafeBytes { buffer in
      SHA256.hash(data: Data(buffer)).map { String(format: "%02x", $0) }.joined()
    }
  }
}
