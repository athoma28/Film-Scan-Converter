import AppKit
import FilmScanEngine
import Testing

@testable import FilmScanConverterMac

@Suite("Perspective framing workflow", .serialized)
@MainActor
struct PerspectiveFramingAppTests {
  @Test(
    "Known film proportions survive editing, undo, look transfer, relaunch, and TIFF export",
    arguments: [0, 1])
  func perspectiveRatioWorkflow(rotation: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fsc-perspective-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("frame.png")
    let other = directory.appendingPathComponent("other.png")
    var pixels = [UInt16]()
    for index in 0..<(243 * 161) {
      pixels.append(UInt16((index % 243) * 150))
      pixels.append(UInt16((index / 243) * 200))
      pixels.append(20_000)
    }
    let source = UInt16Image(width: 243, height: 161, channels: 3, pixels: pixels)
    for path in [input, other] {
      try source.write(to: path, format: .png, parameters: .init(format: .png))
    }
    let store = PerFileSettingsStore(baseDirectory: directory)
    let model = AppModel(settingsStore: store)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([input, other])
    try await settled(model)
    model.setFilmType(.cropOnly)
    if rotation == 1 { model.rotateClockwise() }
    model.setPerspectiveCrop(
      .init(
        topLeft: .init(x: 0.20, y: 0.08), topRight: .init(x: 0.78, y: 0.18),
        bottomRight: .init(x: 0.90, y: 0.90), bottomLeft: .init(x: 0.08, y: 0.82)))
    model.setManualCrop(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    let before = model.parameters
    model.beginSourceGeometryEditing()
    try await settled(model)
    let sourcePreviewSize = model.previewImage?.size
    model.setPerspectiveOutputAspectRatio(.landscape3x2)
    let changed = model.parameters
    #expect(model.manualCrop == nil)
    #expect(model.perspectiveOutputAspectRatio == .landscape3x2)
    #expect(
      model.perspectiveCrop?.outputAspectRatio == (rotation == 0 ? .landscape3x2 : .portrait2x3))
    #expect(model.previewImage?.size == sourcePreviewSize)
    model.undo()
    #expect(model.parameters == before)
    model.redo()
    #expect(model.parameters == changed)
    model.resetPerspectiveCorners()
    #expect(model.perspectiveOutputAspectRatio == .landscape3x2)
    model.undo()
    #expect(model.parameters == changed)
    // Public looks retain the entire destination quadrilateral, including its ratio.
    model.applyLookRecipe(.warm)
    #expect(model.perspectiveCrop == changed.perspectiveCrop)
    model.undo()
    model.endSourceGeometryEditing()
    try await settled(model)
    let expected = FilmProcessing.correctedPreview(image: source, parameters: model.parameters)
    #expect(abs(Double(expected.width) - 1.5 * Double(expected.height)) <= 1.5)
    let preview = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let cpu = try #require(expected.makePreviewCGImage())
    #expect(preview.width == cpu.width && preview.height == cpu.height)
    #expect(preview.dataProvider?.data as Data? == cpu.dataProvider?.data as Data?)
    model.setExportDestinationDirectory(directory)
    model.setExportFormat(.tiff)
    model.exportSelected()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    #expect(
      try StandardImageDecoder.decode(directory.appendingPathComponent("frame.tiff")) == expected)
    try await model.flushSettings()
    model.selection = other
    model.loadSelection()
    try await settled(model)
    #expect(model.perspectiveCrop == nil)
    let relaunched = AppModel(settingsStore: store)
    defer {
      relaunched.selection = nil
      relaunched.loadSelection()
    }
    relaunched.importFiles([input])
    try await settled(relaunched)
    #expect(relaunched.perspectiveCrop == changed.perspectiveCrop)
    #expect(relaunched.perspectiveOutputAspectRatio == .landscape3x2)
    relaunched.clearPerspectiveCrop()
    #expect(relaunched.perspectiveCrop == nil)
    relaunched.undo()
    #expect(relaunched.perspectiveCrop == changed.perspectiveCrop)
  }

  private func settled(_ model: AppModel) async throws {
    try await waitUntil { model.previewImage != nil && !model.isLoading && !model.isRendering }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
