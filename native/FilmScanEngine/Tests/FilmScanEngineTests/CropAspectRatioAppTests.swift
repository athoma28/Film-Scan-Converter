import AppKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Crop aspect ratio app workflow", .serialized)
@MainActor
struct CropAspectRatioAppTests {
  @Test(
    "Constrained crops survive history and relaunch and agree with exported pixels",
    arguments: ["plain", "rotated", "perspective", "straightened"])
  func cropWorkflow(geometry: String) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-crop-ratio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("scan.png")
    let other = directory.appendingPathComponent("other.png")
    let source = makeSource(large: geometry == "plain")
    try source.write(to: input, format: .png, parameters: .init(format: .png))
    try source.write(to: other, format: .png, parameters: .init(format: .png))
    let store = PerFileSettingsStore(baseDirectory: directory)
    let model = AppModel(settingsStore: store)
    model.importFiles([input, other])
    try await waitForPreview(model)
    model.setFilmType(.cropOnly)
    if geometry == "rotated" { model.rotateClockwise() }
    if geometry == "perspective" {
      model.setPerspectiveCrop(
        .init(
          topLeft: .init(x: 0.1, y: 0.12), topRight: .init(x: 0.85, y: 0.08),
          bottomRight: .init(x: 0.9, y: 0.86), bottomLeft: .init(x: 0.08, y: 0.9)))
    }
    if geometry == "straightened" { model.setStraightenAngle(7) }
    if geometry != "plain" {
      model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    }
    let before = model.parameters
    model.beginManualCropEditing()
    try await waitForPreview(model)
    let editingSize = model.previewImage?.size
    let rendersBefore = model.renderStats.submittedSnapshots

    model.setManualCropAspectRatio(.portrait4x5)
    let fitted = model.parameters
    let crop = try #require(model.manualCrop)
    let canvas = try #require(model.selectedUncroppedCanvasDimensions)
    #expect(
      abs(crop.width * Double(canvas.width) / (crop.height * Double(canvas.height)) - 0.8) < 1e-12)
    #expect(model.previewImage?.size == editingSize)
    #expect(model.renderStats.submittedSnapshots == rendersBefore)
    model.undo()
    try await waitForPreview(model)
    #expect(model.parameters == before)
    #expect(model.previewImage?.size == editingSize)
    model.redo()
    try await waitForPreview(model)
    #expect(model.parameters == fitted)

    // The overlay uses this same resize operation, with one history entry per drag.
    model.beginEditingGesture(named: "Crop")
    let ratio = try #require(model.normalizedManualCropAspectRatio)
    for point in [(0.7, 0.7), (0.65, 0.68), (0.6, 0.65)] {
      model.setManualCrop(
        crop.movingHandle(
          .bottomRight, to: point, minWidth: 0.01, minHeight: 0.01, aspectRatio: ratio))
    }
    model.endEditingGesture()
    let resized = model.parameters
    #expect(resized != fitted)
    model.undo()
    #expect(model.parameters == fitted)
    model.redo()
    #expect(model.parameters == resized)

    // Free unlocks the existing rectangle without changing its composition.
    model.setManualCropAspectRatio(.free)
    #expect(model.manualCrop == resized.manualCrop)
    model.undo()
    #expect(model.parameters == resized)
    model.endManualCropEditing()
    try await waitForPreview(model)
    let expected = FilmProcessing.correctedPreview(image: source, parameters: resized)
    let preview = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let previewSource = try #require(model.decodedImage)
    let expectedPreview = try #require(
      FilmProcessing.correctedPreview(image: previewSource, parameters: resized)
        .makePreviewCGImage())
    #expect(preview.width == expectedPreview.width && preview.height == expectedPreview.height)
    #expect(preview.dataProvider?.data as Data? == expectedPreview.dataProvider?.data as Data?)
    #expect(model.selectedCanvasDimensions == .init(width: expected.width, height: expected.height))
    // Cover the outward rounding of normalized edges to whole output pixels.
    #expect(abs(Double(expected.width) - 0.8 * Double(expected.height)) <= 2)

    model.setExportDestinationDirectory(directory)
    model.setExportFormat(.tiff)
    model.exportSelected()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    let output = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "tiff" || $0.pathExtension == "tif" })
    let exported = try StandardImageDecoder.decode(output)
    #expect(exported.width == expected.width && exported.height == expected.height)
    #expect(exported.pixels == expected.pixels)

    model.selection = other
    model.selectedFiles = [other]
    model.loadSelection()
    try await waitForPreview(model)
    #expect(model.parameters.manualCropAspectRatio == .free)
    #expect(try store.loadState().settingsByPath[input.standardizedFileURL.path] == resized)
    let restored = AppModel(settingsStore: store)
    restored.importFiles([input])
    try await waitForPreview(restored)
    // Source medians are recomputed when loading; crop intent must be unchanged.
    #expect(restored.parameters.manualCropAspectRatio == resized.manualCropAspectRatio)
    #expect(restored.manualCrop == resized.manualCrop)
    #expect(restored.parameters.rotation == resized.rotation)
    #expect(restored.parameters.straightenAngle == resized.straightenAngle)
    #expect(restored.perspectiveCrop == resized.perspectiveCrop)
    #expect(
      restored.previewImage?.size
        == CGSize(width: expectedPreview.width, height: expectedPreview.height))
  }

  private func waitForPreview(_ model: AppModel) async throws {
    try await waitUntil { !model.isLoading && !model.isRendering && model.previewImage != nil }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for crop workflow")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeSource(large: Bool) -> UInt16Image {
    let width = large ? 1_215 : 243
    let height = large ? 805 : 161
    var pixels: [UInt16] = []
    for row in 0..<height {
      for column in 0..<width {
        let x = column * 243 / width
        let y = row * 161 / height
        pixels += [
          UInt16(8_000 + x * 100), UInt16(12_000 + y * 200), UInt16(16_000 + x * 50 + y * 80),
        ]
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }
}
