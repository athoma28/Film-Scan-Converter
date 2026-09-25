import AppKit
import CryptoKit
import FilmScanEngine
import FilmScanPreviewRenderer
import Testing

@testable import FilmScanConverterMac

@Suite("Photographic full-resolution tone and export", .serialized)
@MainActor
struct PhotographicExportTests {
  @Test(
    "Version 4 edits agree with full-source previews and reopened app TIFFs",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PHOTOGRAPHIC_EXPORT_TESTS"] == "1",
      "set RUN_PHOTOGRAPHIC_EXPORT_TESTS=1 with the six-frame tone-study corpus"),
    arguments: [
      "fuji400-fresh/DSCF2833.RAF", "fuji400-fresh/DSCF2892.RAF",
      "proimage/DSCF5800.RAF", "proimage/DSCF5809.RAF",
      "harmanphoenixii/DSCF3079.RAF", "harmanphoenixii/DSCF3091.RAF",
    ])
  func fullResolutionTone(relativePath: String) async throws {
    let file = SampleRawCorpus.url(relativePath: relativePath)
    try #require(FileManager.default.fileExists(atPath: file.path), "Missing \(relativePath)")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-photographic-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base: FilmBase = relativePath.hasPrefix("harmanphoenixii/") ? .colorCyanMask : .colorC41
    let initial = LookRecipe.cleanInvert.applying(to: base.applyingInvert(to: .init()))
    let store = PerFileSettingsStore(baseDirectory: directory)
    try store.save(.init(settingsByPath: [file.standardizedFileURL.path: initial], editedPaths: []))
    let suiteName = "fsc-photographic-export-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(settingsStore: store, preferences: preferences)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([file])
    try await waitUntil {
      model.previewSourceKind == .rawFull && !model.isRendering && !model.isLoading
    }
    model.beginEditingGesture(named: "Photographic tone")
    model.setExposureEV(0.25)
    model.setSemanticHighlights(-0.25)
    model.setSemanticShadows(0.25)
    model.setWhites(0.25)
    model.setBlacks(-0.25)
    model.setShadowFloor(0.10)
    model.setMidtoneLevel(-0.10)
    model.setHighlightCeiling(-0.10)
    model.endEditingGesture()
    try await waitUntil { !model.isRendering }
    #expect(model.parameters.photoAdjustments.schemaVersion == 4)
    let parameters = model.parameters
    let previewSource = try #require(model.decodedImage)
    let preview = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let expectedPreview = FilmProcessing.correctedPreview(
      image: previewSource, parameters: parameters)
    let cpuPreview = try #require(expectedPreview.makePreviewCGImage())
    let renderer = try #require(StillPreviewRenderer(image: previewSource))
    let metalPreview = try #require(renderer.render(parameters: parameters, showOriginal: false))
    let appDifference = try difference(cpuPreview, preview)
    let metalDifference = try difference(cpuPreview, metalPreview)
    #expect(appDifference.maximum <= 2)
    #expect(metalDifference.maximum <= 2)
    #expect(preview.width == previewSource.width && preview.height == previewSource.height)

    model.setExportDestinationDirectory(directory)
    model.setExportFormat(.tiff)
    model.setTiffCompression(.lzw)
    model.exportSelected()
    try await waitUntil { !model.isExporting }
    #expect(model.exportErrors.isEmpty)
    let output = directory.appendingPathComponent(
      file.deletingPathExtension().lastPathComponent + ".tiff")
    let exportSource = try RawImageDecoder.decode(
      file, fullResolution: true, profile: .rawTherapeeCameraScan
    ).image
    var exportParameters = parameters
    exportParameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
      image: exportSource.resizedToFit(maxDimension: 256), borderPercent: 20)
    let expectedExport = FilmProcessing.correctedPreview(
      image: exportSource, parameters: exportParameters)
    let reopened = try StandardImageDecoder.decode(output)
    #expect(reopened == expectedExport)
    _ = try IndependentViewerInspection.inspectNamedSRGB(
      at: output, expectedWidth: expectedExport.width, expectedHeight: expectedExport.height,
      expectedDepth: 16)
    // The interactive source is a one-pass decode, export a three-pass decode.
    // Report this difference separately from same-source CPU/Metal parity.
    let sourceTierDifference = try difference(
      cpuPreview, #require(reopened.makePreviewCGImage()))
    let pixelHash = reopened.pixels.withUnsafeBytes { SHA256.hash(data: Data($0)).description }
    let report: [String: Any] = [
      "frame": relativePath, "toneVersion": 4,
      "width": reopened.width, "height": reopened.height,
      "appPreviewMaximumDifference255": appDifference.maximum,
      "metalMaximumDifference255": metalDifference.maximum,
      "previewExportMeanDifference255": sourceTierDifference.mean,
      "previewExportMaximumDifference255": sourceTierDifference.maximum,
      "exportMatchesProductionCPUExactly": reopened == expectedExport,
      "exportPixelsSHA256": pixelHash,
    ]
    if let path = ProcessInfo.processInfo.environment["PHOTOGRAPHIC_EXPORT_OUTPUT"] {
      let destination = URL(fileURLWithPath: path).appendingPathComponent(
        relativePath.replacingOccurrences(of: ".RAF", with: ""))
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("report.json"))
      try JSONEncoder().encode(exportParameters).write(
        to: destination.appendingPathComponent("parameters.json"))
      try JSONEncoder().encode(exportParameters.filmNegativeParams.measuredMedians)
        .write(to: destination.appendingPathComponent("measured-medians.json"))
      for (name, image) in [("preview", expectedPreview), ("export", reopened)] {
        try image.resizedToFit(maxDimension: 900).write(
          to: destination.appendingPathComponent(name + ".png"), format: .png,
          parameters: .init(format: .png))
      }
    }
    print("Photographic export: \(report)")
  }

  private func difference(_ lhs: CGImage, _ rhs: CGImage) throws -> (maximum: Int, mean: Double) {
    try #require(lhs.width == rhs.width && lhs.height == rhs.height)
    func rgba(_ image: CGImage) throws -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
      let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
      try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(
          CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      return bytes
    }
    let a = try rgba(lhs)
    let b = try rgba(rhs)
    var maximum = 0
    var total: Int64 = 0
    for index in a.indices where index % 4 != 3 {
      let delta = abs(Int(a[index]) - Int(b[index]))
      maximum = max(maximum, delta)
      total += Int64(delta)
    }
    return (maximum, Double(total) / Double(lhs.width * lhs.height * 3))
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(180)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for photographic export")
      try await Task.sleep(for: .milliseconds(25))
    }
  }
}
