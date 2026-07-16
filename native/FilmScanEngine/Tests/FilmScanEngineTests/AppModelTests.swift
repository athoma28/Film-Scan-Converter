import AppKit
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
    atPath: appModelRepositoryRoot.appending(path: "sample-raw/DSCF2819.RAF").path
  )
}

@Suite("Native app model integration", .serialized)
@MainActor
struct AppModelTests {
  private enum WaitError: Error {
    case timedOut
  }

  @Test("App performance stages keep stable Instruments labels")
  func appPerformanceStagesKeepStableLabels() {
    #expect(
      AppPerformanceStage.allCases.map(\.rawValue) == [
        "Queue Wait",
        "Settings and Classification",
        "Decode",
        "Flat Field Lookup",
        "Correction",
        "Geometry and Frame",
        "Write and Finalize",
        "Cleanup",
        "Thumbnail Extraction",
        "Standard Preview Decode",
        "Authoritative Replacement",
        "First Corrected Preview",
        "Selection Received",
        "Metadata and Dimensions",
        "1000px Conversion",
        "Classification and Median Calibration",
        "Preview Renderer Setup",
        "GPU Render",
        "Display Publication",
        "RAW Detail Queue Delay",
      ])
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
    #expect(model.previewStatistics.sampleCount > 0)
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

  @Test("Explicit first-file film identity becomes a weak hint for ambiguous later files")
  func firstFileFilmIdentityHintsLaterAutomaticClassification() async throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-roll-hint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let first = workDir.appendingPathComponent("first.png")
    let second = workDir.appendingPathComponent("second.png")
    let firstImage = UInt16Image(
      width: 8,
      height: 8,
      channels: 3,
      pixels: [UInt16](repeating: 20_000, count: 8 * 8 * 3)
    )
    var ambiguousPixels: [UInt16] = []
    for index in 0..<(8 * 8) {
      ambiguousPixels.append(index.isMultiple(of: 2) ? 20_000 : 18_000)
      ambiguousPixels.append(index.isMultiple(of: 2) ? 23_600 : 21_200)
      ambiguousPixels.append(index.isMultiple(of: 2) ? 27_800 : 25_000)
    }
    try firstImage.write(to: first, format: .png, parameters: ExportParameters(format: .png))
    try UInt16Image(
      width: 8,
      height: 8,
      channels: 3,
      pixels: ambiguousPixels
    ).write(to: second, format: .png, parameters: ExportParameters(format: .png))

    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.decodedImage != nil && model.selection == first }
    model.setFilmType(.colourNegative)
    try await waitUntil { model.hasCachedPreview(for: second) }

    model.selection = second
    model.loadSelection()

    #expect(model.parameters.filmType == .colourNegative)
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
    #expect(model.parameters.densityPipelineEnabled)
    #expect(model.parameters.densityBaseDensity == model.selectedRebateMeasurement?.baseDensity)

    model.selection = second
    model.loadSelection()

    #expect(model.selectedRebateMeasurement == nil)
    #expect(model.selectedRebateRegion == nil)
    #expect(model.rebateCandidates.isEmpty)
    #expect(!model.isRebateDetectionRunning)
  }

  @Test("Flat-field changes validate geometry and submit a fresh preview")
  func flatFieldChangesSubmitPreview() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil && !model.isRendering }
    let decoded = try #require(model.decodedImage)
    let submissions = model.renderStats.submittedSnapshots

    model.setFlatField(decoded)
    try await waitUntil { model.renderStats.submittedSnapshots > submissions }
    #expect(model.flatFieldImage == decoded)

    let incompatible = UInt16Image(
      width: decoded.width, height: max(1, decoded.height / 2), channels: 3,
      pixels: [UInt16](repeating: .max, count: decoded.width * max(1, decoded.height / 2) * 3)
    )
    model.setFlatField(incompatible)
    #expect(model.flatFieldImage == decoded)
    #expect(model.rebateStatus == "Flat field aspect ratio must match the selected scan.")

    let clearSubmissions = model.renderStats.submittedSnapshots
    model.clearFlatField()
    try await waitUntil { model.renderStats.submittedSnapshots > clearSubmissions }
    #expect(model.flatFieldImage == nil)
  }

  @Test("Density processing with flat field exports through the app path")
  func densityFlatFieldExport() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-density-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }

    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil && model.previewImage != nil }
    let decoded = try #require(model.decodedImage)
    model.setFlatField(decoded)
    model.measureRebateRegion(normalizedX: 0, normalizedY: 0, normalizedWidth: 1, normalizedHeight: 1)
    try await waitUntil { model.parameters.densityPipelineEnabled && !model.isRendering }
    model.rotateClockwise()
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)

    model.exportSelected()
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 1 }

    #expect(model.exportErrors.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("input.png").path))
  }

  @Test("RAW exports request full-resolution camera-scan decoding")
  func rawExportDecodePolicy() {
    #expect(AppModel.requiresFullResolutionExportDecode(
      URL(fileURLWithPath: "/tmp/scan.RAF")))
    #expect(!AppModel.requiresFullResolutionExportDecode(
      URL(fileURLWithPath: "/tmp/scan.tiff")))
  }

  @Test(
    "Power-law export recalibrates film-base medians from export pixels",
    arguments: [FilmType.colourNegative, .blackAndWhiteNegative]
  )
  func exportRecalibratesFilmBaseMedians(filmType: FilmType) throws {
    var parameters = ProcessingParameters()
    parameters.filmType = filmType
    parameters.filmNegativeParams = .colourNegative
    parameters.filmNegativeParams.measuredMedians = BGRChannelValues(
      blue: 60_000, green: 8_000, red: 60_000)
    let decoded = UInt16Image(
      width: 4,
      height: 4,
      channels: 3,
      pixels: Array(repeating: [UInt16(12_000), 24_000, 36_000], count: 16).flatMap { $0 }
    )

    let exportParameters = AppModel.parametersForExport(parameters, decodedImage: decoded)
    let medians = try #require(exportParameters.filmNegativeParams.measuredMedians)

    #expect(medians == BGRChannelValues(blue: 12_000, green: 24_000, red: 36_000))
    #expect(parameters.filmNegativeParams.measuredMedians?.blue == 60_000)
  }

  @Test(
    "Export preserves calibration outside the power-law negative path",
    arguments: [FilmType.cropOnly, .slide]
  )
  func exportPreservesCalibrationForOtherFilmTypes(filmType: FilmType) {
    var parameters = ProcessingParameters()
    parameters.filmType = filmType
    parameters.filmNegativeParams = .colourNegative
    parameters.filmNegativeParams.measuredMedians = BGRChannelValues(
      blue: 60_000, green: 8_000, red: 60_000)
    let decoded = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [12_000, 24_000, 36_000])

    let exportParameters = AppModel.parametersForExport(parameters, decodedImage: decoded)

    #expect(exportParameters == parameters)
  }

  @Test("Export preserves density-pipeline film-base calibration")
  func exportPreservesDensityPipelineCalibration() {
    var parameters = ProcessingParameters()
    parameters.filmType = .colourNegative
    parameters.filmNegativeParams = .colourNegative
    parameters.filmNegativeParams.measuredMedians = BGRChannelValues(
      blue: 60_000, green: 8_000, red: 60_000)
    parameters.densityPipelineEnabled = true
    let decoded = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [12_000, 24_000, 36_000])

    let exportParameters = AppModel.parametersForExport(parameters, decodedImage: decoded)

    #expect(exportParameters == parameters)
  }

  @Test("Export preserves disabled and non-color calibration inputs")
  func exportPreservesUnsupportedCalibrationInputs() {
    var disabled = ProcessingParameters()
    disabled.filmType = .colourNegative
    disabled.filmNegativeParams.enabled = false
    let color = UInt16Image(
      width: 1, height: 1, channels: 3, pixels: [12_000, 24_000, 36_000])
    #expect(AppModel.parametersForExport(disabled, decodedImage: color) == disabled)

    var grayscaleParameters = ProcessingParameters()
    grayscaleParameters.filmType = .blackAndWhiteNegative
    grayscaleParameters.filmNegativeParams = .blackAndWhite
    let grayscale = UInt16Image(width: 2, height: 1, channels: 1, pixels: [12_000, 24_000])
    #expect(
      AppModel.parametersForExport(grayscaleParameters, decodedImage: grayscale)
        == grayscaleParameters)
  }

  @Test("App export rejects stale preview calibration end to end")
  func appExportRejectsStalePreviewCalibrationEndToEnd() async throws {
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-export-calibration-\(UUID().uuidString)", isDirectory: true)
    let destination = workDirectory.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let input = workDirectory.appendingPathComponent("negative.tiff")
    var sourcePixels: [UInt16] = []
    for index in 0..<64 {
      sourcePixels.append(UInt16(9_000 + index * 71))
      sourcePixels.append(UInt16(21_000 + index * 43))
      sourcePixels.append(UInt16(37_000 + index * 29))
    }
    let source = UInt16Image(
      width: 8,
      height: 8,
      channels: 3,
      pixels: sourcePixels
    )
    try source.write(to: input, format: .tiff, parameters: ExportParameters(format: .tiff))

    var stale = ProcessingParameters()
    stale.filmType = .colourNegative
    stale.filmNegativeParams = .colourNegative
    stale.filmNegativeParams.measuredMedians = BGRChannelValues(
      blue: 60_000, green: 8_000, red: 60_000)
    let settingsStore = PerFileSettingsStore(baseDirectory: workDirectory)
    try settingsStore.save(.init(
      settingsByPath: [input.standardizedFileURL.path: stale], editedPaths: []))

    let model = AppModel(settingsStore: settingsStore)
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil }
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)
    model.exportSelected()
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 1 }

    let exported = try StandardImageDecoder.decode(
      destination.appendingPathComponent("negative.png"))
    let decodedSource = try StandardImageDecoder.decode(input)
    let expectedParameters = AppModel.parametersForExport(stale, decodedImage: decodedSource)
    let expected = FilmProcessing.correctedPreview(
      image: decodedSource, parameters: expectedParameters)
    let staleOutput = FilmProcessing.correctedPreview(image: decodedSource, parameters: stale)

    #expect(model.exportErrors.isEmpty)
    #expect(exported == expected)
    #expect(exported != staleOutput)
  }

  @Test("Crop-only export applies the interactive perspective crop")
  func cropOnlyExportAppliesCrop() async throws {
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-crop-export-\(UUID().uuidString)", isDirectory: true)
    let destination = workDirectory.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }
    let input = workDirectory.appendingPathComponent("crop-source.png")
    let source = UInt16Image(
      width: 100, height: 80, channels: 3,
      pixels: [UInt16](repeating: 30_000, count: 100 * 80 * 3))
    try source.write(to: input, format: .png, parameters: ExportParameters(format: .png))

    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil }
    model.setFilmType(.cropOnly)
    let crop = PerspectiveCrop(
      topLeft: .init(x: 0.25, y: 0.25),
      topRight: .init(x: 0.75, y: 0.25),
      bottomRight: .init(x: 0.75, y: 0.75),
      bottomLeft: .init(x: 0.25, y: 0.75)
    )
    model.setPerspectiveCrop(crop)
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)

    model.exportSelected()
    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 1 }

    let exported = try StandardImageDecoder.decode(
      destination.appendingPathComponent("crop-source.png"))
    let expected = try #require(PerspectiveTransform.crop(source, perspectiveCrop: crop))
    #expect(exported.width == expected.width)
    #expect(exported.height == expected.height)
  }

  @Test("Crop-only render statistics handle grayscale crops")
  func cropOnlyRenderStatisticsHandleGrayscaleCrops() async throws {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_grayscale_png8"
      )
    )

    model.importFiles([input])
    try await waitUntil {
      model.decodedImage?.channels == 1 && model.previewImage != nil && !model.isRendering
    }
    model.setFilmType(.cropOnly)
    let displayedBeforeCrop = model.renderStats.displayedRenders
    model.setCropRect(
      RotatedRect(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5, angle: 0))

    try await waitUntil {
      model.renderStats.displayedRenders > displayedBeforeCrop && !model.isRendering
    }

    #expect(model.previewImage != nil)
    #expect(model.previewStatistics.sampleCount > 0)
  }

  @Test("Manual crop immediately changes the displayed preview canvas")
  func manualCropUpdatesDisplayedPreview() async throws {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_png8"
      )
    )

    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    let originalSize = try #require(model.previewImage?.size)
    let displayedBeforeCrop = model.renderStats.displayedRenders

    model.setManualCrop(NormalizedCropRect(
      x: 1.0 / 3.0, y: 0.5, width: 1.0 / 3.0, height: 0.5))
    try await waitUntil {
      model.renderStats.displayedRenders > displayedBeforeCrop && !model.isRendering
    }

    let croppedSize = try #require(model.previewImage?.size)
    #expect(croppedSize.width < originalSize.width)
    #expect(croppedSize.height < originalSize.height)

    let displayedBeforeReenteringCrop = model.renderStats.displayedRenders
    model.beginManualCropEditing()
    try await waitUntil {
      model.renderStats.displayedRenders > displayedBeforeReenteringCrop && !model.isRendering
    }
    #expect(model.previewImage?.size == originalSize)

    let displayedBeforeCancelingCrop = model.renderStats.displayedRenders
    model.endManualCropEditing()
    try await waitUntil {
      model.renderStats.displayedRenders > displayedBeforeCancelingCrop && !model.isRendering
    }
    #expect(model.previewImage?.size == croppedSize)
  }

  @Test("Reset corrections clears crop processing and inspector state")
  func resetCorrectionsClearsCropState() {
    let model = AppModel()
    model.setPerspectiveCrop(PerspectiveCrop(
      topLeft: .init(x: 0.1, y: 0.1),
      topRight: .init(x: 0.9, y: 0.1),
      bottomRight: .init(x: 0.9, y: 0.9),
      bottomLeft: .init(x: 0.1, y: 0.9)
    ))
    model.setStraightenAngle(12.5)
    model.setManualCrop(NormalizedCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))

    model.resetCorrections()

    #expect(model.parameters.cropRect == nil)
    #expect(model.parameters.perspectiveCrop == nil)
    #expect(model.parameters.manualCrop == nil)
    #expect(model.cropRect == nil)
    #expect(model.perspectiveCrop == nil)
    #expect(model.manualCrop == nil)
    #expect(model.parameters.straightenAngle == 0)
    #expect(model.straightenAngle == 0)
    #expect(model.cropThresholdPreview == nil)
    #expect(model.cropStatus.isEmpty)
  }

  @Test("Perspective warp and manual crop remain independent")
  func perspectiveWarpAndCropRemainIndependent() {
    let model = AppModel()
    let crop = NormalizedCropRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
    let perspective = PerspectiveCrop(
      topLeft: .init(x: 0.05, y: 0.08),
      topRight: .init(x: 0.95, y: 0.04),
      bottomRight: .init(x: 0.9, y: 0.94),
      bottomLeft: .init(x: 0.08, y: 0.9))

    model.setManualCrop(crop)
    model.setPerspectiveCrop(perspective)

    #expect(model.manualCrop == crop)
    #expect(model.parameters.manualCrop == crop)
    #expect(model.perspectiveCrop == perspective)

    model.clearPerspectiveCrop()

    #expect(model.perspectiveCrop == nil)
    #expect(model.parameters.perspectiveCrop == nil)
    #expect(model.manualCrop == crop)
    #expect(model.parameters.manualCrop == crop)
  }

  @Test("Manual film-base selection maps oriented preview coordinates to source")
  func rebateSelectionMapsOrientedCoordinates() {
    let displayed = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

    let rotated = AppModel.sourceNormalizedRect(
      fromDisplayedRect: displayed, rotation: 1, flippedHorizontally: false)
    #expect(abs(rotated.minX - 0.2) < 0.000_001)
    #expect(abs(rotated.minY - 0.6) < 0.000_001)
    #expect(abs(rotated.width - 0.4) < 0.000_001)
    #expect(abs(rotated.height - 0.3) < 0.000_001)

    let flipped = AppModel.sourceNormalizedRect(
      fromDisplayedRect: displayed, rotation: 0, flippedHorizontally: true)
    #expect(abs(flipped.minX - 0.6) < 0.000_001)
    #expect(abs(flipped.minY - 0.2) < 0.000_001)
    #expect(abs(flipped.width - 0.3) < 0.000_001)
    #expect(abs(flipped.height - 0.4) < 0.000_001)
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
        $0.region.x + $0.region.width <= AppModel.displayPreviewMaxDimension
          && $0.region.y + $0.region.height <= AppModel.displayPreviewMaxDimension
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
    "RAW import keeps the embedded 1000px preview as the interactive source",
    .enabled(if: appModelRawCorpusAvailable, "sample-raw corpus unavailable; AppModel RAW preview test skipped")
  )
  func rawImportUsesFastEmbeddedPreview() async throws {
    let raw = repositoryRoot.appending(path: "sample-raw/DSCF2819.RAF")

    let model = AppModel()
    model.importFiles([raw])

    try await waitUntil(timeout: .seconds(3)) { model.previewImage != nil }
    #expect(model.previewSourceKind == .embeddedRAW)
    #expect(model.decodedImage?.channels == 3)
    #expect(max(model.decodedImage?.width ?? 0, model.decodedImage?.height ?? 0) <= 1_000)
  }

  @Test(
    "Load RAW Preview replaces embedded pixels with a bounded demosaiced preview",
    .enabled(if: appModelRawCorpusAvailable, "sample-raw corpus unavailable; RAW detail preview test skipped")
  )
  func rawDetailPreviewUsesCameraScanDecode() async throws {
    let raw = repositoryRoot.appending(path: "sample-raw/DSCF2819.RAF")
    let model = AppModel()
    model.importFiles([raw])

    try await waitUntil(timeout: .seconds(3)) { model.previewSourceKind == .embeddedRAW }
    #expect(model.canLoadRawDetailPreview)
    model.loadRawDetailPreview()

    try await waitUntil(timeout: .seconds(25)) {
      model.previewSourceKind == .rawDetail && !model.isLoading
    }
    let dimensions = try #require(model.selectedImageDimensions)
    #expect(!dimensions.provisional)
    #expect(max(dimensions.width, dimensions.height) <= AppModel.rawDetailPreviewMaxDimension)
    #expect(max(dimensions.width, dimensions.height) > AppModel.displayPreviewMaxDimension)
    #expect(!model.canLoadRawDetailPreview)
  }

  @Test("Standard image import keeps a bounded thumbnail and full-resolution geometry")
  func standardImportUsesBoundedPreview() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-standard-swap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("large.tiff")
    try UInt16Image(
      width: 1_200,
      height: 800,
      channels: 3,
      pixels: [UInt16](repeating: 24_000, count: 1_200 * 800 * 3)
    ).write(to: input, format: .tiff, parameters: ExportParameters(format: .tiff))

    let model = AppModel()
    model.importFiles([input])

    try await waitUntil { model.previewImage != nil }
    #expect(model.previewSourceKind == .standardThumbnail)
    let provisionalDimensions = try #require(model.selectedImageDimensions)
    #expect(provisionalDimensions.provisional)
    #expect(max(provisionalDimensions.width, provisionalDimensions.height) <= 1_000)
    model.setFilmType(.cropOnly)
    try await waitUntil { model.previewStatistics.sampleCount > 0 }
    #expect(model.decodedImage?.width == 1_000)
    #expect(model.decodedImage?.height == 667)
    #expect(model.parameters.filmType == .cropOnly)
    let fullDimensions = try #require(model.selectedImageDimensions)
    #expect(fullDimensions.provisional)
    #expect(model.selectedOutputDimensions == PixelDimensions(width: 1_200, height: 800))
    model.setManualCrop(NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    #expect(model.selectedCanvasDimensions == PixelDimensions(width: 600, height: 400))
    #expect(model.selectedOutputDimensions == PixelDimensions(width: 600, height: 400))
    model.cropCurrentCanvas(to: NormalizedCropRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5))
    #expect(model.manualCrop == NormalizedCropRect(x: 0.3, y: 0.35, width: 0.4, height: 0.25))
    #expect(model.selectedCanvasDimensions == PixelDimensions(width: 480, height: 200))
    model.setExportFramePercent(5)
    model.setExportAspectRatio(AspectRatio(width: 1, height: 1))
    #expect(model.selectedOutputDimensions == PixelDimensions(width: 500, height: 500))
  }

  @Test("Canceled queued authoritative decode does not start")
  func canceledQueuedAuthoritativeDecodeDoesNotStart() async throws {
    let probe = AuthoritativeDecodeProbe()
    let decoder = AuthoritativeImageDecoder(operation: probe.decode)
    let first = Task {
      try await decoder.decode(URL(fileURLWithPath: "/tmp/first.tiff"))
    }
    try await Task.sleep(for: .milliseconds(10))
    let second = Task {
      try await decoder.decode(URL(fileURLWithPath: "/tmp/second.tiff"))
    }
    second.cancel()

    _ = try await first.value
    await #expect(throws: CancellationError.self) {
      try await second.value
    }
    #expect(probe.invocationCount == 1)
  }

  @Test("Legacy color setters keep semantic protected-color intent synchronized")
  func legacyColorSettersSynchronizeSemanticIntent() {
    let model = AppModel()

    model.setTemperature(50)
    model.setTint(-25)
    model.setSaturation(140)
    model.setVibrance(0.6)

    let expected = PhotoAdjustmentParameters.migratingLegacy(
      gamma: 0,
      shadows: 0,
      highlights: 0,
      temperature: 50,
      tint: -25,
      saturation: 140
    )
    #expect(model.parameters.photoAdjustments.temperatureShiftMired == expected.temperatureShiftMired)
    #expect(model.parameters.photoAdjustments.tint == expected.tint)
    #expect(model.parameters.photoAdjustments.saturation == expected.saturation)
    #expect(model.parameters.photoAdjustments.vibrance == 0.6)
  }

  @Test("Enabling the overall curve starts from an identity curve")
  func enablingCurveStartsFromIdentity() {
    let model = AppModel()

    model.setCurveEnabled(true)

    #expect(model.parameters.curveEnabled)
    #expect(model.parameters.curveControlPoints == [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 1, output: 1),
    ])
  }

  @Test("Per-file corrections persist across app model instances")
  func perFileCorrectionsPersistAcrossLaunches() async throws {
    let fixture = try #require(
      Bundle.module.url(
        forResource: "input",
        withExtension: "png",
        subdirectory: "Fixtures/decode_png8"
      )
    )
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let input = workDir.appendingPathComponent("scan.png")
    try FileManager.default.copyItem(at: fixture, to: input)

    let first = AppModel(settingsStore: PerFileSettingsStore(baseDirectory: workDir))
    first.importFiles([input])
    try await waitUntil { first.decodedImage != nil }
    first.setFilmType(.colourNegative)
    first.setExposureEV(1.25)
    first.setVibrance(0.4)

    let restored = AppModel(settingsStore: PerFileSettingsStore(baseDirectory: workDir))
    restored.importFiles([input])

    #expect(restored.parameters.filmType == .colourNegative)
    #expect(restored.parameters.photoAdjustments.exposureEV == 1.25)
    #expect(restored.parameters.photoAdjustments.vibrance == 0.4)
  }

  @Test("Persisted corrections remain isolated by standardized file path")
  func persistedCorrectionsRemainPerFile() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-settings-isolation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let store = PerFileSettingsStore(baseDirectory: workDir)
    let firstPath = workDir.appendingPathComponent("first.tif").standardizedFileURL.path
    let secondPath = workDir.appendingPathComponent("second.tif").standardizedFileURL.path

    var first = ProcessingParameters()
    first.photoAdjustments.exposureEV = 2
    var second = ProcessingParameters()
    second.photoAdjustments.exposureEV = -1
    try store.save(.init(
      settingsByPath: [firstPath: first, secondPath: second],
      editedPaths: [firstPath, secondPath]
    ))

    let loaded = try store.loadState().settingsByPath
    #expect(loaded[firstPath]?.photoAdjustments.exposureEV == 2)
    #expect(loaded[secondPath]?.photoAdjustments.exposureEV == -1)
  }

  @Test("Corrupt persisted corrections do not prevent app startup")
  func corruptPersistedCorrectionsRecoverSafely() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-settings-corrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let store = PerFileSettingsStore(baseDirectory: workDir)
    try Data("not json".utf8).write(to: store.fileURL)

    let model = AppModel(settingsStore: store)

    #expect(model.parameters == ProcessingParameters())
    #expect(model.status.contains("could not be loaded"))
  }

  @Test("Transferable correction settings preserve frame-specific geometry and film base")
  func correctionSettingsPreserveFrameSpecificState() {
    var source = ProcessingParameters()
    source.filmType = .colourNegative
    source.photoAdjustments.exposureEV = 1.5
    source.photoAdjustments.vibrance = 0.35
    source.rotation = 1
    source.flip = true
    source.cropRect = RotatedRect(
      centerX: 0.4, centerY: 0.5, width: 0.7, height: 0.8, angle: 2
    )
    source.perspectiveCrop = PerspectiveCrop(
      topLeft: .init(x: 0.1, y: 0.1),
      topRight: .init(x: 0.9, y: 0.2),
      bottomRight: .init(x: 0.8, y: 0.9),
      bottomLeft: .init(x: 0.2, y: 0.8)
    )
    source.straightenAngle = 7
    source.manualCrop = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    source.densityPipelineEnabled = true
    source.densityBaseDensity = BGRChannelValues(blue: 0.2, green: 0.3, red: 0.4)

    var destination = ProcessingParameters()
    destination.rotation = 3
    destination.flip = false
    destination.cropRect = RotatedRect(
      centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.6, angle: -1
    )
    destination.cropRectCoordinateSpace = .legacyTransposedAxes
    destination.perspectiveCrop = PerspectiveCrop(
      topLeft: .init(x: 0.2, y: 0.2),
      topRight: .init(x: 0.8, y: 0.2),
      bottomRight: .init(x: 0.8, y: 0.8),
      bottomLeft: .init(x: 0.2, y: 0.8)
    )
    destination.straightenAngle = -4
    destination.manualCrop = NormalizedCropRect(x: 0.2, y: 0.3, width: 0.6, height: 0.5)
    destination.densityPipelineEnabled = true
    destination.densityBaseDensity = BGRChannelValues(blue: 0.8, green: 0.7, red: 0.6)

    let applied = CorrectionSettings(capturing: source).applying(to: destination)

    #expect(applied.filmType == .colourNegative)
    #expect(applied.photoAdjustments.exposureEV == 1.5)
    #expect(applied.photoAdjustments.vibrance == 0.35)
    #expect(applied.rotation == destination.rotation)
    #expect(applied.flip == destination.flip)
    #expect(applied.cropRect == destination.cropRect)
    #expect(applied.cropRectCoordinateSpace == destination.cropRectCoordinateSpace)
    #expect(applied.perspectiveCrop == destination.perspectiveCrop)
    #expect(applied.straightenAngle == destination.straightenAngle)
    #expect(applied.manualCrop == destination.manualCrop)
    #expect(applied.densityPipelineEnabled == destination.densityPipelineEnabled)
    #expect(applied.densityBaseDensity == destination.densityBaseDensity)
  }

  @Test("Named correction presets persist atomically and replace names case-insensitively")
  func namedCorrectionPresetsPersistAndReplace() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-presets-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let store = NamedCorrectionPresetStore(baseDirectory: workDir)
    var first = ProcessingParameters()
    first.photoAdjustments.exposureEV = 1
    var replacement = ProcessingParameters()
    replacement.photoAdjustments.exposureEV = 2

    try store.savePreset(named: "Warm Print", settings: CorrectionSettings(capturing: first))
    try store.savePreset(named: " warm print ", settings: CorrectionSettings(capturing: replacement))

    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].name == "warm print")
    #expect(loaded[0].settings.parameters.photoAdjustments.exposureEV == 2)
  }

  @Test("App model copies and pastes corrections through the system pasteboard contract")
  func appModelCopiesAndPastesCorrections() {
    let pasteboard = NSPasteboard(name: .init("fsc-tests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    let source = AppModel(settingsClipboard: clipboard)
    source.setFilmType(.colourNegative)
    source.setExposureEV(1.75)
    source.setVibrance(0.5)
    source.copyCorrectionSettings()

    let destination = AppModel(settingsClipboard: clipboard)
    #expect(destination.canPasteCorrectionSettings)
    destination.pasteCorrectionSettings()

    #expect(destination.parameters.filmType == .colourNegative)
    #expect(destination.parameters.photoAdjustments.exposureEV == 1.75)
    #expect(destination.parameters.photoAdjustments.vibrance == 0.5)
  }

  @Test("App model saves, applies, and deletes named correction presets")
  func appModelManagesNamedCorrectionPresets() async throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-model-presets-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let store = NamedCorrectionPresetStore(baseDirectory: workDir)
    let model = AppModel(presetStore: store)
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    model.setFilmType(.slide)
    model.setExposureEV(1.25)
    model.saveCorrectionPreset(named: "Projection")
    let preset = try #require(model.namedCorrectionPresets.first)

    model.setExposureEV(-2)
    model.rotateClockwise()
    let submissionsBeforeApply = model.renderStats.submittedSnapshots
    model.applyCorrectionPreset(preset)

    #expect(model.parameters.filmType == .slide)
    #expect(model.parameters.photoAdjustments.exposureEV == 1.25)
    #expect(model.parameters.rotation == 1)
    #expect(model.renderStats.submittedSnapshots == submissionsBeforeApply + 1)

    model.deleteCorrectionPreset(preset)
    #expect(model.namedCorrectionPresets.isEmpty)
    #expect(AppModel(presetStore: store).namedCorrectionPresets.isEmpty)
  }

  @Test("App model applies the built-in Kodachrome-like look immediately")
  func appModelAppliesKodachromeLikeLook() async throws {
    let model = AppModel()
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    model.importFiles([input])
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    model.setFilmType(.slide)
    model.rotateClockwise()
    try await waitUntil { !model.isRendering }
    let submissionsBeforeApply = model.renderStats.submittedSnapshots

    model.applyKodachromeLikeLook()

    #expect(model.parameters.filmType == .colourNegative)
    #expect(model.parameters.filmNegativeParams.enabled)
    #expect(model.parameters.rotation == 1)
    #expect(model.parameters.photoAdjustments.vibrance == 0.25)
    #expect(model.renderStats.submittedSnapshots == submissionsBeforeApply + 1)
    #expect(model.settingsStatus == "Applied Kodachrome-like Auto.")
    #expect(model.appliedPresetName == "Kodachrome-like Auto")

    model.removeAppliedPreset()

    #expect(model.parameters.filmType == .slide)
    #expect(model.parameters.rotation == 1)
    #expect(model.parameters.photoAdjustments.vibrance == 0)
    #expect(model.appliedPresetName == nil)
    #expect(model.settingsStatus.contains("restored the previous adjustments"))
  }

  @Test("Preview cache limit persists, expands lookahead, and trims immediately")
  func previewCacheLimitPersistsAndTrims() async throws {
    let suiteName = "fsc-preview-cache-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let fixture = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-preview-cache-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let files = try (0..<3).map { index in
      let url = workDir.appendingPathComponent("scan-\(index).png")
      try FileManager.default.copyItem(at: fixture, to: url)
      return url
    }

    let model = AppModel(preferences: preferences)
    model.setPreviewCacheLimit(3)
    model.importFiles(files)
    try await waitUntil { model.previewCacheSessionCount == 3 }
    #expect(model.previewCachePhysicalBytes > 0)
    #expect(model.previewCachePhysicalBytes <= AppModel.previewCacheByteLimit)

    model.setPreviewCacheLimit(2)
    #expect(model.previewCacheSessionCount == 2)
    #expect(preferences.integer(forKey: "previewCacheLimit") == 2)
    #expect(AppModel(preferences: preferences).previewCacheLimit == 2)
  }

  @Test("Apply to all open files preserves per-frame geometry and marks every file edited")
  func applySettingsToAllOpenFiles() async throws {
    let fixture = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-apply-all-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let first = workDir.appendingPathComponent("first.png")
    let second = workDir.appendingPathComponent("second.png")
    try FileManager.default.copyItem(at: fixture, to: first)
    try FileManager.default.copyItem(at: fixture, to: second)

    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.decodedImage != nil }
    model.setExposureEV(1.5)
    model.applyCurrentSettingsToAllOpenFiles()

    #expect(model.hasEdits(for: first))
    #expect(model.hasEdits(for: second))
    model.selection = second
    model.loadSelection()
    #expect(model.parameters.photoAdjustments.exposureEV == 1.5)
  }

  @Test("Files added during export snapshot the current format and destination")
  func queuedExportUsesPerItemSnapshot() async throws {
    let png = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let bmp = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "bmp",
        subdirectory: "Fixtures/decode_bmp8"))
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-queued-snapshot-\(UUID().uuidString)", isDirectory: true)
    let sourceDir = workDir.appendingPathComponent("source", isDirectory: true)
    let firstDestination = workDir.appendingPathComponent("first-destination", isDirectory: true)
    let changedDestination = workDir.appendingPathComponent("changed-destination", isDirectory: true)
    for directory in [sourceDir, firstDestination, changedDestination] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: workDir) }
    let first = sourceDir.appendingPathComponent("first.png")
    let second = sourceDir.appendingPathComponent("second.bmp")
    try FileManager.default.copyItem(at: png, to: first)
    try FileManager.default.copyItem(at: bmp, to: second)

    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.decodedImage != nil }
    model.setExportDestinationDirectory(firstDestination)
    model.setExportFormat(.png)
    model.exportSelected()
    model.setExportDestinationDirectory(changedDestination)
    model.setExportFormat(.jpeg)
    model.selection = second
    model.addSelectedToExportQueue()

    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 2 }
    #expect(FileManager.default.fileExists(
      atPath: firstDestination.appendingPathComponent("first.png").path))
    #expect(FileManager.default.fileExists(
      atPath: changedDestination.appendingPathComponent("second.jpeg").path))
  }

  @Test("The same file can be queued repeatedly with independent JPEG quality snapshots")
  func duplicateQueuedExportsUseIndependentSettings() async throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-duplicate-queue-\(UUID().uuidString)", isDirectory: true)
    let destination = workDir.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let input = workDir.appendingPathComponent("scan.png")
    let width = 256
    let height = 192
    var pixels = [UInt16]()
    pixels.reserveCapacity(width * height * 3)
    for component in 0..<(width * height * 3) {
      let value = component &* 7_919 &+ (component / 3) &* 104_729
      pixels.append(UInt16(value & 0xffff))
    }
    try UInt16Image(width: width, height: height, channels: 3, pixels: pixels).write(
      to: input,
      format: .png,
      parameters: ExportParameters(format: .png)
    )

    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil }
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.jpeg)
    model.setJpegQuality(0.95)
    model.exportSelected()
    model.setJpegQuality(0.40)
    model.addSelectedToExportQueue()
    model.setJpegQuality(0.75)
    model.addSelectedToExportQueue()

    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 3 }
    let names = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
    #expect(names == ["scan-2.jpeg", "scan-3.jpeg", "scan.jpeg"])
    let highQualityBytes = try Data(contentsOf: destination.appendingPathComponent("scan.jpeg")).count
    let lowQualityBytes = try Data(contentsOf: destination.appendingPathComponent("scan-2.jpeg")).count
    let mediumQualityBytes = try Data(contentsOf: destination.appendingPathComponent("scan-3.jpeg")).count
    #expect(lowQualityBytes < mediumQualityBytes)
    #expect(mediumQualityBytes < highQualityBytes)
  }

  @Test("Export Selected writes every sidebar-selected file in import order")
  func exportSelectedSupportsMultipleFiles() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-multi-export-\(UUID().uuidString)", isDirectory: true)
    let sourceDirectory = workDir.appendingPathComponent("source", isDirectory: true)
    let destination = workDir.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let first = sourceDirectory.appendingPathComponent("first.png")
    let second = sourceDirectory.appendingPathComponent("second.png")
    try FileManager.default.copyItem(at: input, to: first)
    try FileManager.default.copyItem(at: input, to: second)

    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.decodedImage != nil }
    model.selectedFiles = [first, second]
    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)
    model.exportSelected()

    try await waitUntil { !model.isExporting && model.exportProgressCurrent == 2 }
    #expect(FileManager.default.fileExists(
      atPath: destination.appendingPathComponent("first.png").path))
    #expect(FileManager.default.fileExists(
      atPath: destination.appendingPathComponent("second.png").path))
  }

  @Test("Export cancellation clears active and pending queue state")
  func exportCancellationClearsQueueState() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-export-cancel-\(UUID().uuidString)", isDirectory: true)
    let sourceDir = workDir.appendingPathComponent("source", isDirectory: true)
    let destination = workDir.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let files = (0..<8).map { sourceDir.appendingPathComponent("scan-\($0).png") }
    for file in files { try FileManager.default.copyItem(at: input, to: file) }

    let model = AppModel()
    model.importFiles(files)
    try await waitUntil { model.decodedImage != nil }
    model.setExportDestinationDirectory(destination)
    model.exportAll()

    #expect(model.isExporting)
    #expect(model.exportQueueCount == files.count - 1)
    model.cancelExport()

    try await waitUntil { !model.isExporting }
    #expect(model.activeExportFilename == nil)
    #expect(model.exportQueueCount == 0)
    #expect(model.status.localizedCaseInsensitiveContains("cancel"))
  }

  @Test("Version-one settings migrate existing paths to edited markers")
  func editedPathMigration() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-edited-migration-\(UUID().uuidString)", isDirectory: true)
    let store = PerFileSettingsStore(baseDirectory: workDir)
    defer { try? FileManager.default.removeItem(at: workDir) }
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    let path = workDir.appendingPathComponent("scan.png").standardizedFileURL.path
    let document = PerFileSettingsStore.Document(
      schemaVersion: 1,
      settingsByPath: [path: ProcessingParameters()]
    )
    try JSONEncoder().encode(document).write(to: store.fileURL, options: .atomic)

    let model = AppModel(settingsStore: store)
    #expect(model.hasEdits(for: URL(fileURLWithPath: path)))
  }

  @Test("Rotation direction remains visual after a horizontal flip")
  func rotationDirectionAccountsForFlip() {
    let model = AppModel()
    model.toggleFlip()
    model.rotateClockwise()
    #expect(model.parameters.rotation == 3)
    model.rotateCounterclockwise()
    #expect(model.parameters.rotation == 0)
  }

  @Test("Dust detection produces a display overlay through the app path")
  func dustDetectionProducesOverlay() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png",
        subdirectory: "Fixtures/decode_png8"))
    let model = AppModel()
    model.importFiles([input])
    try await waitUntil { model.decodedImage != nil }
    model.rotateClockwise()
    try await waitUntil { model.previewImage != nil && !model.isRendering }
    model.detectDustMask()
    try await waitUntil { !model.isDustDetectionRunning && !model.dustStatus.isEmpty }
    #expect(model.dustMaskImage != nil)
    #expect(model.dustMaskImage?.size == model.previewImage?.size)
    model.clearDustMask()
    #expect(model.dustMaskImage == nil)
  }

  @Test("App profile management saves, lists, and applies stored profiles")
  func appProfileManagement() {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-app-profiles-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let model = AppModel(profileStore: ProfileStore(baseDirectory: workDir))
    model.setFilmType(.colourNegative)
    model.saveCurrentCaptureProfile(named: "My Copy Rig")
    model.saveCurrentFilmStockProfile(named: "My Test Stock")

    #expect(model.availableCaptureProfiles.contains { $0.id.rawValue == "my_copy_rig" })
    #expect(model.availableFilmStockProfiles.contains { $0.id.rawValue == "my_test_stock" })
    model.applySelectedPipelineProfiles()
    #expect(model.parameters.densityPipelineEnabled)
    #expect(model.profileStatus.contains("Density pipeline active"))
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

private final class AuthoritativeDecodeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var invocations = 0

  var invocationCount: Int {
    lock.withLock { invocations }
  }

  func decode(_ url: URL) throws -> UInt16Image {
    lock.withLock { invocations += 1 }
    Thread.sleep(forTimeInterval: 0.1)
    return UInt16Image(width: 1, height: 1, channels: 3, pixels: [1, 2, 3])
  }
}
