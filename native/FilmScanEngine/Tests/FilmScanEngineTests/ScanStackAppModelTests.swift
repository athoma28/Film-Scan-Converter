import AppKit
import FilmScanEngine
import Foundation
import SwiftUI
import Testing

@testable import FilmScanConverterMac

@Suite("Repeated scan app workflow", .serialized)
@MainActor
struct ScanStackAppModelTests {
  private enum WaitError: Error {
    case timedOut
  }

  @Test("Selecting a detected stack keeps the app chrome inside the window")
  func detectedStackLayoutStaysBounded() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-stack-layout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.png")
    let second = directory.appendingPathComponent("second.png")
    try syntheticCapture(noiseOffset: 0).write(
      to: first, format: .png, parameters: ExportParameters(format: .png))
    try syntheticCapture(noiseOffset: 37).write(
      to: second, format: .png, parameters: ExportParameters(format: .png))
    let model = AppModel()
    model.importFiles([first, second])
    try await waitUntil { model.detectedScanStacks.count == 1 && model.previewImage != nil }

    let host = NSHostingView(
      rootView: ContentView(model: model, camera: CameraController())
        .frame(width: 980, height: 640))
    host.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
    host.layoutSubtreeIfNeeded()
    let splitView = try #require(descendantViews(in: host).first { $0 is NSSplitView })
    #expect(splitView.frame.size == host.bounds.size)
  }

  @Test("Import proposes, previews, and exports one aligned stack")
  func detectedStackPreviewAndExport() async throws {
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-scan-stack-\(UUID().uuidString)", isDirectory: true)
    let sourceDirectory = workDirectory.appendingPathComponent("source", isDirectory: true)
    let destination = workDirectory.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let firstURL = sourceDirectory.appendingPathComponent("frame-01.png")
    let secondURL = sourceDirectory.appendingPathComponent("frame-02.png")
    try syntheticCapture(noiseOffset: 0).write(
      to: firstURL,
      format: .png,
      parameters: ExportParameters(format: .png))
    try syntheticCapture(noiseOffset: 37).write(
      to: secondURL,
      format: .png,
      parameters: ExportParameters(format: .png))

    let model = AppModel()
    model.importFiles([firstURL, secondURL])
    try await waitUntil { model.detectedScanStacks.count == 1 }

    let stack = try #require(model.detectedScanStacks.first)
    #expect(stack.members == [firstURL, secondURL])
    #expect(stack.recommendedMode == .noiseReduction)
    #expect(model.thumbnail(for: firstURL) != nil)
    #expect(model.thumbnail(for: secondURL) != nil)

    // Enabling from any member must switch editing ownership to the anchor so
    // the visible grade and the exported grade cannot silently diverge.
    model.selectedFiles = [secondURL]
    #expect(model.sidebarSelectionDidChange())
    model.loadSelection()
    #expect(model.selection == secondURL)
    try await waitUntil { !model.isLoading && model.previewSourceKind != nil }

    model.setScanStackEnabled(true, for: stack)
    try await waitUntil {
      model.previewSourceKind == .alignedStack && !model.isBuildingScanStack
    }
    #expect(model.selection == firstURL)
    #expect(model.selectedFiles == [firstURL])
    #expect(model.scanStackStatus.contains("noise reduction"))

    model.setFilmType(.cropOnly)
    let decodedInputs = try [firstURL, secondURL].map(StandardImageDecoder.decode)
    let expectedStack = try MultiScanStacker.combine(
      images: decodedInputs,
      mode: .noiseReduction
    ).image
    let expectedOutput = FilmProcessing.correctedPreview(
      image: expectedStack,
      parameters: AppModel.parametersForExport(
        model.parameters,
        decodedImage: expectedStack),
      flatField: nil)

    model.setExportDestinationDirectory(destination)
    model.setExportFormat(.png)
    model.exportAll()
    try await waitUntil(timeout: .seconds(15)) {
      !model.isExporting && model.exportProgressCurrent == 1
    }

    #expect(model.exportProgressTotal == 1)
    #expect(model.exportErrors.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("frame-01.png").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("frame-02.png").path))
    let exported = try StandardImageDecoder.decode(
      destination.appendingPathComponent("frame-01.png"))
    #expect(exported == expectedOutput)
  }

  @Test("Distinct imported frames stay independent instead of forming one stack")
  func distinctImportsDoNotFormAScanStack() async throws {
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-distinct-stack-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let firstURL = workDirectory.appendingPathComponent("frame-a.png")
    let secondURL = workDirectory.appendingPathComponent("frame-b.png")
    let thirdURL = workDirectory.appendingPathComponent("frame-c.png")
    try syntheticCapture(noiseOffset: 0, seed: 7).write(
      to: firstURL,
      format: .png,
      parameters: ExportParameters(format: .png))
    try syntheticCapture(noiseOffset: 11, seed: 91).write(
      to: secondURL,
      format: .png,
      parameters: ExportParameters(format: .png))
    try syntheticCapture(noiseOffset: 23, seed: 204).write(
      to: thirdURL,
      format: .png,
      parameters: ExportParameters(format: .png))

    let model = AppModel()
    model.importFiles([firstURL, secondURL, thirdURL])
    try await waitUntil { !model.isAnalyzingScanStacks && model.files.count == 3 }

    #expect(model.detectedScanStacks.isEmpty)
    #expect(model.detectedScanStack(containing: firstURL) == nil)
    #expect(model.detectedScanStack(containing: secondURL) == nil)
    #expect(model.detectedScanStack(containing: thirdURL) == nil)
  }

  private func syntheticCapture(noiseOffset: Int, seed: Int = 7) -> UInt16Image {
    let width = 96
    let height = 72
    var pixels: [UInt16] = []
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        var hash = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ seed &* 83_492_791))
        hash ^= hash >> 13
        hash &*= 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        let random = Double(hash & 0xffff) / 65_535
        let wave = 0.5 + 0.5 * sin(Double(x + seed) * 0.19) * cos(Double(y - seed) * 0.13)
        let base = 0.04 + 0.68 * (0.72 * wave + 0.28 * random)
        for scale in [0.86, 1.0, 0.93] {
          let encoded = encodeSRGB(min(0.88, base * scale))
          let signedNoise = (x &* 17 + y &* 29 + noiseOffset) % 73 - 36
          pixels.append(UInt16(clamping: Int(encoded) + signedNoise))
        }
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private func encodeSRGB(_ linear: Double) -> UInt16 {
    let encoded =
      linear <= 0.003_130_8
      ? linear * 12.92
      : 1.055 * pow(linear, 1 / 2.4) - 0.055
    return UInt16((min(max(encoded, 0), 1) * 65_535).rounded())
  }

  private func descendantViews(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendantViews)
  }

  private func waitUntil(
    timeout: Duration = .seconds(10),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        Issue.record("Timed out waiting for repeated-scan app state")
        throw WaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
