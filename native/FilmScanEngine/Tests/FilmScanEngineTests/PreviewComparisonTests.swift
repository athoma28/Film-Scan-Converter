import AppKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Preview comparison geometry", .serialized)
@MainActor
struct PreviewComparisonTests {
  @Test(
    "Original preserves the corrected composition and restores identical corrected pixels",
    arguments: ["canvas crop", "automatic crop", "perspective", "straighten", "combined"])
  func originalPreservesGeometry(geometry: String) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-comparison-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("scan.png")
    let source = makeSource()
    try source.write(to: input, format: .png, parameters: .init(format: .png))

    var parameters = ProcessingParameters()
    parameters.filmType = .colourNegative
    parameters.rotation = 1
    parameters.flip = true
    parameters.photoAdjustments.exposureEV = 0.75
    if geometry == "canvas crop" || geometry == "combined" {
      parameters.manualCrop = .init(x: 0.12, y: 0.18, width: 0.65, height: 0.7)
    }
    if geometry == "automatic crop" {
      parameters.cropRect = .init(centerX: 0.5, centerY: 0.5, width: 0.7, height: 0.6, angle: 4)
    }
    if geometry == "perspective" || geometry == "combined" {
      parameters.perspectiveCrop = .init(
        topLeft: .init(x: 0.12, y: 0.10), topRight: .init(x: 0.90, y: 0.14),
        bottomRight: .init(x: 0.85, y: 0.88), bottomLeft: .init(x: 0.08, y: 0.92))
    }
    if geometry == "straighten" || geometry == "combined" {
      parameters.straightenAngle = 7
    }
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(settingsByPath: [input.standardizedFileURL.path: parameters], editedPaths: []))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    model.importFiles([input])
    try await waitForPreview(model)
    let corrected = try displayedImage(model)

    model.showOriginal = true
    try await waitForPreview(model)
    let original = try displayedImage(model)
    var originalParameters = model.parameters
    originalParameters.filmType = .cropOnly
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: originalParameters)
        .makePreviewCGImage())

    #expect(original.width == corrected.width)
    #expect(original.height == corrected.height)
    #expect(original.width == expected.width)
    #expect(original.height == expected.height)
    #expect(pixelData(original) == pixelData(expected))
    #expect(pixelData(original) != pixelData(corrected))

    model.showOriginal = false
    try await waitForPreview(model)
    #expect(pixelData(try displayedImage(model)) == pixelData(corrected))

    // Editors need access to the uncropped negative without changing the saved
    // composition or letting their temporary canvas state affect comparison.
    let savedParameters = model.parameters
    let savedState = try store.loadState()
    let savedHistory = model.undoActionName
    model.beginSourceGeometryEditing()
    model.showOriginal = true
    try await waitForPreview(model)
    let editorImage = try displayedImage(model)
    #expect(editorImage.width == source.height)
    #expect(editorImage.height == source.width)
    #expect(model.parameters == savedParameters)
    #expect(model.undoActionName == savedHistory)
    if geometry == "combined" { try await expectDustMatchesPreview(model) }
    model.endSourceGeometryEditing()
    #expect(model.dustMaskImage == nil)
    try await waitForPreview(model)
    #expect(pixelData(try displayedImage(model)) == pixelData(expected))

    model.beginManualCropEditing()
    try await waitForPreview(model)
    originalParameters.manualCrop = nil
    let uncropped = FilmProcessing.correctedPreview(image: source, parameters: originalParameters)
    #expect(model.previewImage?.size == CGSize(width: uncropped.width, height: uncropped.height))
    if geometry == "combined" { try await expectDustMatchesPreview(model) }
    model.endManualCropEditing()
    #expect(model.dustMaskImage == nil)
    try await waitForPreview(model)
    #expect(pixelData(try displayedImage(model)) == pixelData(expected))

    // Loading a selection resets temporary editor state even without a view
    // delivering its overlay cleanup callback.
    model.beginSourceGeometryEditing()
    model.loadSelection()
    try await waitForPreview(model)
    #expect(!model.showOriginal)
    #expect(pixelData(try displayedImage(model)) == pixelData(corrected))
    let persisted = try store.loadState()
    #expect(persisted == savedState)
  }

  @Test("Clipping diagnostics stay populated through Original comparison")
  func clippingDiagnosticsSurviveComparison() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-clipping-nav-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("scan.png")
    try makeSource().write(to: input, format: .png, parameters: .init(format: .png))

    var parameters = ProcessingParameters()
    parameters.filmType = .colourNegative
    parameters.rotation = 1
    parameters.manualCrop = .init(x: 0.12, y: 0.18, width: 0.65, height: 0.7)
    parameters.photoAdjustments.exposureEV = 0.75
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(settingsByPath: [input.standardizedFileURL.path: parameters], editedPaths: []))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    model.importFiles([input])
    try await waitForPreview(model)
    #expect(model.previewStatistics.sampleCount > 0)
    let corrected = model.previewStatistics

    model.showOriginal = true
    try await waitForPreview(model)
    #expect(model.previewStatistics.sampleCount > 0)
    #expect(model.previewStatistics != .empty)

    model.showOriginal = false
    try await waitForPreview(model)
    #expect(model.previewStatistics.sampleCount == corrected.sampleCount)
    #expect(model.previewStatistics.highClippingRatios == corrected.highClippingRatios)
    #expect(model.previewStatistics.lowClippingRatios == corrected.lowClippingRatios)
  }

  @Test(
    "Undo and redo keep an open geometry editor on its uncropped canvas",
    arguments: ["crop", "straighten", "reset"])
  func geometryEditingSurvivesHistory(action: String) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-geometry-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("scan.png")
    let source = makeSource()
    try source.write(to: input, format: .png, parameters: .init(format: .png))

    var initial = ProcessingParameters()
    initial.filmType = .cropOnly
    initial.rotation = 1
    initial.flip = true
    initial.straightenAngle = 7
    initial.manualCrop = .init(x: 0.12, y: 0.18, width: 0.65, height: 0.7)
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(settingsByPath: [input.standardizedFileURL.path: initial], editedPaths: []))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    model.importFiles([input])
    try await waitForPreview(model)
    let committedPreview = try displayedImage(model)
    initial = model.parameters

    // Both Manual Crop and Straighten use this temporary canvas. History must
    // change the saved geometry without dismissing the still-visible editor.
    model.beginManualCropEditing()
    try await expectEditingCanvas(model, source: source)
    switch action {
    case "crop": model.setManualCrop(.init(x: 0.2, y: 0.1, width: 0.5, height: 0.6))
    case "straighten": model.setStraightenAngle(12)
    default: model.resetCorrections()
    }
    let changed = model.parameters
    let changedTolerance = action == "reset" ? 2 : 0
    try await expectEditingCanvas(model, source: source, tolerance: changedTolerance)

    model.undo()
    #expect(model.parameters == initial)
    try await expectEditingCanvas(model, source: source)
    model.redo()
    #expect(model.parameters == changed)
    try await expectEditingCanvas(model, source: source, tolerance: changedTolerance)
    model.undo()
    try await expectEditingCanvas(model, source: source)

    // A subsequent drag must remain an overlay-only edit on that same canvas.
    let submitted = model.renderStats.submittedSnapshots
    model.setManualCrop(.init(x: 0.15, y: 0.2, width: 0.7, height: 0.5))
    #expect(model.renderStats.submittedSnapshots == submitted)
    try await expectEditingCanvas(model, source: source)

    model.endManualCropEditing()
    try await waitForPreview(model)
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: model.parameters)
        .makePreviewCGImage())
    #expect(pixelData(try displayedImage(model)) == pixelData(expected))
    let persisted = try store.loadState()
    let saved = try #require(persisted.settingsByPath[input.standardizedFileURL.path])
    #expect(saved.manualCrop == model.manualCrop)
    #expect(saved.straightenAngle == model.straightenAngle)
    #expect(saved.rotation == model.parameters.rotation)
    #expect(saved.flip == model.parameters.flip)

    // Once editing ends, Undo restores the committed composition as usual.
    model.undo()
    try await waitForPreview(model)
    #expect(model.parameters == initial)
    #expect(pixelData(try displayedImage(model)) == pixelData(committedPreview))
  }

  @Test(
    "Perspective and film-base editors retain the original scan through edits and history",
    arguments: ["perspective", "reset", "exposure", "preset"], [false, true])
  func sourceGeometryEditingSurvivesEdits(action: String, wasComparing: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-source-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("scan.png")
    let source = makeSource()
    try source.write(to: input, format: .png, parameters: .init(format: .png))

    var initial = ProcessingParameters()
    initial.filmType = .colourNegative
    initial.rotation = 1
    initial.flip = true
    initial.photoAdjustments.exposureEV = 0.75
    initial.perspectiveCrop = .init(
      topLeft: .init(x: 0.12, y: 0.10), topRight: .init(x: 0.90, y: 0.14),
      bottomRight: .init(x: 0.85, y: 0.88), bottomLeft: .init(x: 0.08, y: 0.92))
    initial.straightenAngle = 7
    initial.manualCrop = .init(x: 0.12, y: 0.18, width: 0.65, height: 0.7)
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(
      .init(settingsByPath: [input.standardizedFileURL.path: initial], editedPaths: []))
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store)
    model.importFiles([input])
    try await waitForPreview(model)
    initial = model.parameters
    model.showOriginal = wasComparing
    try await waitForPreview(model)
    let committedPreview = try displayedImage(model)
    let initialPersistedState = try store.loadState()

    // Follow the view's editor lifecycle. The loupe and rebate sampler need
    // source pixels for the entire session, including after Undo/Redo.
    model.beginSourceGeometryEditing()
    model.showOriginal = true
    try await expectSourceEditorCanvas(model, source: source)
    switch action {
    case "perspective":
      model.setPerspectiveCrop(
        .init(
          topLeft: .init(x: 0.2, y: 0.2), topRight: .init(x: 0.8, y: 0.2),
          bottomRight: .init(x: 0.8, y: 0.8), bottomLeft: .init(x: 0.2, y: 0.8)))
    case "reset": model.resetCorrections()
    case "exposure": model.setExposureEV(1.25)
    default:
      var preset = initial
      preset.photoAdjustments.exposureEV = -0.5
      model.applyCorrectionPreset(
        .init(name: "Editor Test", settings: CorrectionSettings(capturing: preset)))
    }
    let changed = model.parameters
    #expect(changed != initial)
    try await expectSourceEditorCanvas(model, source: source)

    model.undo()
    #expect(model.parameters == initial)
    try await expectSourceEditorCanvas(model, source: source)
    model.redo()
    #expect(model.parameters == changed)
    try await expectSourceEditorCanvas(model, source: source)
    model.undo()
    try await expectSourceEditorCanvas(model, source: source)
    let persisted = try store.loadState()
    #expect(persisted == initialPersistedState)

    // Closing restores the previous comparison and committed composition.
    model.endSourceGeometryEditing()
    model.showOriginal = wasComparing
    try await waitForPreview(model)
    #expect(pixelData(try displayedImage(model)) == pixelData(committedPreview))
    model.redo()
    try await waitForPreview(model)
    #expect(!model.showOriginal)
    try expectPreviewPixels(
      model, expected: FilmProcessing.correctedPreview(image: source, parameters: changed),
      tolerance: action == "reset" ? 2 : 0)
  }

  private func expectSourceEditorCanvas(_ model: AppModel, source: UInt16Image) async throws {
    try await waitForPreview(model)
    #expect(model.showOriginal)
    var original = ProcessingParameters()
    original.filmType = .cropOnly
    original.rotation = model.parameters.rotation
    original.flip = model.parameters.flip
    try expectPreviewPixels(
      model, expected: FilmProcessing.correctedPreview(image: source, parameters: original),
      tolerance: 2)
  }

  private func expectPreviewPixels(
    _ model: AppModel, expected: UInt16Image, tolerance: Int
  ) throws {
    let reference = try #require(expected.makePreviewCGImage())
    let displayed = try displayedImage(model)
    try #require(displayed.width == reference.width)
    try #require(displayed.height == reference.height)
    let actualPixels = try rgbPixels(displayed)
    let expectedPixels = try rgbPixels(reference)
    let maxError = zip(actualPixels, expectedPixels).map { abs(Int($0) - Int($1)) }.max()
    #expect(try #require(maxError) <= tolerance)
  }

  private func expectEditingCanvas(
    _ model: AppModel, source: UInt16Image, tolerance: Int = 0
  ) async throws {
    try await waitForPreview(model)
    var canvasParameters = model.parameters
    canvasParameters.manualCrop = nil
    let expected = try #require(
      FilmProcessing.correctedPreview(image: source, parameters: canvasParameters)
        .makePreviewCGImage())
    let displayed = try displayedImage(model)
    try #require(displayed.width == expected.width)
    try #require(displayed.height == expected.height)
    // Reset can use Metal's RGBA8 image with aligned rows. Ignore padding and
    // the unused alpha byte; all geometry-forced CPU renders remain exact.
    let actualPixels = try rgbPixels(displayed)
    let expectedPixels = try rgbPixels(expected)
    let maxError = zip(actualPixels, expectedPixels).map { abs(Int($0) - Int($1)) }.max()
    #expect(try #require(maxError) <= tolerance)
  }

  private func rgbPixels(_ image: CGImage) throws -> [UInt8] {
    try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    let data = try #require(pixelData(image))
    var pixels = [UInt8]()
    pixels.reserveCapacity(image.width * image.height * 3)
    for y in 0..<image.height {
      for x in 0..<image.width {
        let start = y * image.bytesPerRow + x * 4
        pixels.append(contentsOf: data[start..<start + 3])
      }
    }
    return pixels
  }

  private func makeSource() -> UInt16Image {
    var pixels: [UInt16] = []
    for y in 0..<160 {
      for x in 0..<240 {
        pixels.append(UInt16(8_000 + x * 100))
        pixels.append(UInt16(12_000 + y * 200))
        pixels.append(UInt16(16_000 + x * 50 + y * 80))
      }
    }
    return UInt16Image(width: 240, height: 160, channels: 3, pixels: pixels)
  }

  private func waitForPreview(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while model.isLoading || model.isRendering || model.previewImage == nil {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for comparison preview")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func displayedImage(_ model: AppModel) throws -> CGImage {
    let image = try #require(model.previewImage)
    return try #require(PreviewBitmap.cgImage(from: image))
  }

  private func expectDustMatchesPreview(_ model: AppModel) async throws {
    model.detectDustMask()
    let deadline = ContinuousClock.now + .seconds(10)
    while model.isDustDetectionRunning {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    let mask = try #require(model.dustMaskImage)
    #expect(mask.size == model.previewImage?.size)
  }

  private func pixelData(_ image: CGImage) -> Data? {
    image.dataProvider?.data as Data?
  }
}
