import AppKit
import CryptoKit
import FilmScanEngine
import Foundation
import Testing

@testable import FilmScanConverterMac

/// Deliberate marks on one real scan establish persistence and output correctness.
/// They do not identify real dust or judge grain, edges, skin, or donor quality.
@Suite("Real RAW dust repair export correctness", .serialized)
@MainActor
struct RawDustExportTests {
  @Test(
    "Saved manual and mask repairs survive framing and agree with a reopened RAW TIFF",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_RAW_DUST_EXPORT_TESTS"] == "1",
      "set RUN_RAW_DUST_EXPORT_TESTS=1 with Fuji DSCF2833 in the local RAW corpus"))
  func repairedRawExportAgreement() async throws {
    let relativePath = "fuji400-fresh/DSCF2833.RAF"
    let input = SampleRawCorpus.url(relativePath: relativePath)
    try #require(FileManager.default.fileExists(atPath: input.path), "Missing \(relativePath)")
    let sourceHash = try fileHash(input)
    let evidenceDirectory = try freshEvidenceDirectory()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-raw-dust-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "fsc-raw-dust-preferences-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    let profileStore = ProfileStore(baseDirectory: directory.appendingPathComponent("profiles"))
    let model = AppModel(
      profileStore: profileStore, settingsStore: store, preferences: preferences)
    defer { model.closeAllScans() }
    model.importFiles([input])
    try await fullPreview(model, stage: "initial full-source preview")
    model.setFilmBase(.colorC41)
    model.applyLookRecipe(.cleanInvert)
    model.setPerspectiveCrop(
      .init(
        topLeft: .init(x: 0.08, y: 0.10), topRight: .init(x: 0.93, y: 0.08),
        bottomRight: .init(x: 0.91, y: 0.92), bottomLeft: .init(x: 0.10, y: 0.90)))
    model.rotateClockwise()
    model.setStraightenAngle(2)
    model.setManualCrop(.init(x: 0.08, y: 0.10, width: 0.84, height: 0.80))
    try await fullPreview(model, stage: "framed full-source preview")
    let beforeRepairs = model.parameters

    model.beginDustEditing()
    try await waitUntil("unframed repair canvas") {
      model.isDustCanvasReady && !model.isRendering
    }
    let sourceDimensions = try #require(model.sourcePixelDimensions)
    let previewSource = try #require(model.decodedImage)
    #expect(
      model.previewImage?.size == CGSize(width: previewSource.width, height: previewSource.height))
    let manualRepair = DustRepairStroke(
      points: [SIMD2(0.42, 0.46), SIMD2(0.425, 0.463)], radius: 0.0015,
      sourcePoint: SIMD2(0.35, 0.46))
    await model.addDustRepair(
      points: manualRepair.points, radius: manualRepair.radius,
      sourcePoint: manualRepair.sourcePoint)?.value
    try #require(model.parameters.dustRepairs == [manualRepair])

    // One intentionally marked compact component exercises the automatic donor
    // path without making a claim about detection accuracy on this photograph.
    model.paintDustMask(points: [SIMD2(0.62, 0.58)], radius: 0.0009, erasing: false)
    let markedMask = try #require(model.dustSourceMask)
    #expect(markedMask.pixels.contains { $0 != 0 })
    #expect(model.parameters.dustRepairs == [manualRepair])
    await model.repairDustMask()?.value
    let repaired = model.parameters
    try #require(repaired.dustRepairs.count == 2)
    #expect(repaired.dustRepairs[0] == manualRepair)
    #expect(
      repaired.dustRepairs[1].sourcePoint != nil, "Automatic repair must save its chosen donor")
    #expect(model.dustSourceMask?.pixels.allSatisfy { $0 == 0 } == true)
    #expect(model.undoActionName == "Repair Dust Mask")
    model.undo()
    #expect(model.parameters.dustRepairs == [manualRepair])
    model.redo()
    #expect(model.parameters == repaired)
    #expect(repaired.rotation == beforeRepairs.rotation)
    #expect(repaired.straightenAngle == beforeRepairs.straightenAngle)
    #expect(repaired.perspectiveCrop == beforeRepairs.perspectiveCrop)
    #expect(repaired.manualCrop == beforeRepairs.manualCrop)
    #expect(FilmBase.resolved(from: repaired) == .colorC41)
    #expect(
      DustRepair.canApply(
        strokes: repaired.dustRepairs,
        imageWidth: sourceDimensions.width, imageHeight: sourceDimensions.height))
    model.endDustEditing()
    try await fullPreview(model, stage: "repaired framed preview")
    try await model.flushSettings()
    let document = try JSONDecoder().decode(
      PerFileSettingsStore.Document.self, from: Data(contentsOf: store.fileURL))
    #expect(document.schemaVersion == 3)
    let parsed = try #require(try store.loadState().settingsByPath[input.standardizedFileURL.path])
    var expectedSaved = repaired
    expectedSaved.filmNegativeParams.measuredMedians = nil
    #expect(parsed.filmNegativeParams.measuredMedians == nil)
    #expect(parsed == expectedSaved)
    model.closeAllScans()

    let restored = AppModel(
      profileStore: profileStore, settingsStore: store, preferences: preferences)
    defer { restored.closeAllScans() }
    restored.importFiles([input])
    try await fullPreview(restored, stage: "restored repaired full-source preview")
    #expect(!restored.isDustEditing)
    #expect(!restored.canUndo)
    #expect(restored.parameters.dustRepairs == repaired.dustRepairs)
    #expect(restored.parameters.rotation == repaired.rotation)
    #expect(restored.parameters.straightenAngle == repaired.straightenAngle)
    #expect(restored.parameters.perspectiveCrop == repaired.perspectiveCrop)
    #expect(restored.parameters.manualCrop == repaired.manualCrop)
    let restoredParameters = restored.parameters
    let restoredSource = try #require(restored.decodedImage)
    let expectedPreview = FilmProcessing.correctedPreview(
      image: restoredSource, parameters: restoredParameters)
    let cpuPreview = try #require(expectedPreview.makePreviewCGImage())
    let displayed = try #require(restored.previewImage.flatMap(PreviewBitmap.cgImage))
    #expect(displayed.width == cpuPreview.width && displayed.height == cpuPreview.height)
    try expectPreviewRGBPixelsMatch(displayed, cpuPreview)

    // Comparison and repair-visibility controls affect the displayed preview;
    // exporting must still consume the saved corrected parameters and repairs.
    restored.showDustRepairs = false
    restored.showOriginal = true
    try await fullPreview(restored, stage: "Original comparison before export")
    #expect(restored.parameters == restoredParameters)
    restored.setExportDestinationDirectory(directory)
    restored.setExportFormat(.tiff)
    restored.setTiffCompression(.lzw)
    restored.exportSelected()
    try #require(restored.isExporting)
    try await waitUntil("repaired RAW TIFF export") {
      !restored.isExporting && restored.exportProgressCurrent == 1
    }
    #expect(restored.exportErrors.isEmpty)
    let output = directory.appendingPathComponent("DSCF2833.tiff")
    try #require(FileManager.default.fileExists(atPath: output.path))
    let exportSource = try RawImageDecoder.decode(
      input, fullResolution: true, profile: .rawTherapeeCameraScan
    ).image
    #expect(exportSource.width == sourceDimensions.width)
    #expect(exportSource.height == sourceDimensions.height)
    var exportParameters = restoredParameters
    // Independently reproduce the export analysis boundary rather than calling
    // the app's parametersForExport helper as its own reference.
    exportParameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
      image: exportSource.resizedToFit(maxDimension: 256), borderPercent: 20)
    let expectedExport = FilmProcessing.correctedPreview(
      image: exportSource, parameters: exportParameters)
    let reopened = try StandardImageDecoder.decode(output)
    try #require(reopened == expectedExport, "Reopened TIFF must equal the production CPU pixels")
    var withoutRepairs = exportParameters
    withoutRepairs.dustRepairs = []
    #expect(
      reopened != FilmProcessing.correctedPreview(image: exportSource, parameters: withoutRepairs),
      "The deliberate repairs must change pixels that survive the final framing")
    let independent = try IndependentViewerInspection.inspectNamedSRGB(
      at: output, expectedWidth: expectedExport.width, expectedHeight: expectedExport.height,
      expectedDepth: 16)
    try #require(try fileHash(input) == sourceHash, "The RAW source bytes must remain unchanged")
    let outputFiles = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "tiff" }
    #expect(outputFiles.count == 1)
    #expect(
      outputFiles.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        == [output.standardizedFileURL.resolvingSymlinksInPath()])

    if let evidenceDirectory {
      try FileManager.default.createDirectory(
        at: evidenceDirectory, withIntermediateDirectories: true)
      let report = Report(
        frame: relativePath, sourceSHA256: sourceHash,
        exportPixelsSHA256: pixelHash(reopened), width: independent.width,
        height: independent.height, depth: independent.depth,
        repairs: exportParameters.dustRepairs.count)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: evidenceDirectory.appendingPathComponent("report.json"))
      try encoder.encode(exportParameters).write(
        to: evidenceDirectory.appendingPathComponent("parameters.json"))
      for (name, image) in [("preview", expectedPreview), ("export", reopened)] {
        try image.resizedToFit(maxDimension: 900).write(
          to: evidenceDirectory.appendingPathComponent(name + ".png"), format: .png,
          parameters: .init(format: .png))
      }
    }
    print(
      "RAW dust export correctness: \(relativePath); 2 saved repairs; \(reopened.width)x\(reopened.height) TIFF equals production CPU; independent 16-bit sRGB; source hash unchanged. Photographic restoration quality is unassessed."
    )
  }

  private func freshEvidenceDirectory() throws -> URL? {
    guard let path = ProcessInfo.processInfo.environment["RAW_DUST_EXPORT_OUTPUT"] else {
      return nil
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    try #require(
      !FileManager.default.fileExists(atPath: directory.path),
      "RAW_DUST_EXPORT_OUTPUT must name a fresh directory")
    return directory
  }

  private func fullPreview(_ model: AppModel, stage: String) async throws {
    try await waitUntil(stage) {
      model.previewSourceKind == .rawFull && model.previewImage != nil
        && !model.isLoading && !model.isRendering
    }
  }

  private func waitUntil(_ stage: String, condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(180)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out: \(stage)")
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private func fileHash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).description
  }

  private func pixelHash(_ image: UInt16Image) -> String {
    image.pixels.withUnsafeBytes { SHA256.hash(data: Data($0)).description }
  }

  private struct Report: Encodable {
    let schemaVersion = 1
    let frame: String
    let sourceSHA256: String
    let exportPixelsSHA256: String
    let width: Int
    let height: Int
    let depth: Int
    let repairs: Int
    let exportMatchesProductionCPUExactly = true
    let sourceBytesUnchanged = true
    let exportedWhileOriginalComparisonWasVisible = true
    let limits = [
      "Deliberate marks do not establish dust-detection accuracy or photographic healing quality.",
      "One X-T5 scan does not establish all-camera acceptance.",
      "One-pass preview and three-pass export sources are not asserted pixel-identical.",
      "Saved repairs use CPU fallback; this check does not establish Metal parity.",
    ]
  }
}
