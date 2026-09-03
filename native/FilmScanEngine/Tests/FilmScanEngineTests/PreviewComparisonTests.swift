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
