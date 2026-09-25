import AppKit
import CryptoKit
@preconcurrency import Darwin
import FilmScanEngine
import Foundation
import SwiftUI
import Testing

@testable import FilmScanConverterMac

@Suite("Real RAW native-window interaction diagnostics", .serialized)
@MainActor
struct PreviewInteractionPerformanceTests {
  @Test("Trace correlates coalesced request revisions with completed publication")
  func traceCorrelatesPublication() async throws {
    let input = try #require(
      Bundle.module.url(
        forResource: "input", withExtension: "png", subdirectory: "Fixtures/decode_png8"))
    let suiteName = "fsc-trace-correlation-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    defer {
      preferences.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: PerFileSettingsStore(baseDirectory: directory),
      preferences: preferences)
    defer {
      model.selection = nil
      model.loadSelection()
    }
    model.importFiles([input])
    try await waitUntil("fixture", timeout: .seconds(10)) {
      model.previewImage != nil && !model.isLoading && !model.isRendering
    }
    let trace = PreviewInteractionTrace()
    model.previewInteractionTrace = trace
    model.beginEditingGesture(named: "Exposure")
    for index in 1...6 { model.setExposureEV(Double(index) / 10) }
    model.endEditingGesture()
    try await waitUntil("publication", timeout: .seconds(10)) { !model.isRendering }
    let published = try #require(trace.events.last { $0.stage == .modelPublished })
    #expect(published.revision == model.publishedRenderRevision)
    let revision = trace.events.filter { $0.revision == published.revision }
    #expect(
      revision.map(\.stage) == [
        .requestSubmitted, .renderBegan, .workerBegan, .workerFinished,
        .renderReturned, .modelPublished,
      ])
    #expect(revision.map(\.milliseconds) == revision.map(\.milliseconds).sorted())
    #expect(revision.first?.exposureEV == 0.6)
    #expect(try #require(revision.first?.interactionMilliseconds) <= revision[0].milliseconds)
    #expect(model.publishedPreviewParameters == model.parameters)
    #expect(published.rasterWidth == model.previewImage.flatMap(PreviewBitmap.cgImage)?.width)
    #expect(trace.discardedEventCount == 0)
    try await model.flushSettings()
  }

  private struct Memory: Codable {
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let reusableBytes: UInt64
  }

  private struct Input: Codable {
    let index: Int
    let scheduledMilliseconds: Double
    let setterStartMilliseconds: Double
    let setterEndMilliseconds: Double
    let value: Double
  }

  private struct Case: Codable {
    let name: String
    let repetition: Int
    let viewportWidthPoints: Double
    let viewportHeightPoints: Double
    let magnification: Double
    let backingScale: Double
    let gestureStartMilliseconds: Double
    let releaseMilliseconds: Double
    let finalRevision: Int
    let inputs: [Input]
    let events: [PreviewInteractionTrace.Event]
    let memoryAfter: Memory
  }

  private struct Report: Codable {
    let generatedAt: String
    let input: String
    let inputSHA256: String
    let operatingSystem: String
    let hardware: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let screenMaximumFramesPerSecond: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let inputPeriodMilliseconds: Double
    let eventsPerGesture: Int
    let repetitions: Int
    let cases: [Case]
    let discardedTraceEvents: Int
    let compositorCapture: PreviewCompositorCapture.Snapshot
    let memoryBefore: Memory
    let memoryAfterRelease: Memory
    let modelReleased: Bool
    let cleanupIssue: String?
    let physicalScreenPresentationMeasured: Bool
    let note: String
  }

  @Test(
    "Replay exposure and contrast in the production native window at Fit and 100%",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PREVIEW_INTERACTION_BENCHMARK"] == "1",
      "Requires the local Fuji 400 RAW and a logged-in macOS graphics session")
  )
  func measureNativeWindowInteraction() async throws {
    let environment = ProcessInfo.processInfo.environment
    let input = SampleRawCorpus.url(relativePath: "fuji400-fresh/DSCF2833.RAF")
    try #require(FileManager.default.fileExists(atPath: input.path), "Missing required RAW")
    let output = try #require(environment["FSC_PREVIEW_INTERACTION_OUTPUT"])
    let outputURL = URL(fileURLWithPath: output)
    try #require(!FileManager.default.fileExists(atPath: output), "Choose a fresh report path")
    let repetitions = min(5, max(1, Int(environment["FSC_INTERACTION_REPETITIONS"] ?? "3") ?? 3))
    let eventCount = min(240, max(60, Int(environment["FSC_INTERACTION_EVENTS"] ?? "120") ?? 120))
    let periodMilliseconds = 1_000.0 / 120
    let digest = SHA256.hash(data: try Data(contentsOf: input, options: .mappedIfSafe))
      .map { String(format: "%02x", $0) }.joined()
    let memoryBefore = memorySample()
    let trace = PreviewInteractionTrace(maximumEvents: 40_000)
    let suiteName = "fsc-native-interaction-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let settingsDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName)
    defer { try? FileManager.default.removeItem(at: settingsDirectory) }
    var model: AppModel? = AppModel(
      profileStore: ProfileStore(
        baseDirectory: settingsDirectory.appendingPathComponent("profiles")),
      settingsStore: PerFileSettingsStore(baseDirectory: settingsDirectory),
      preferences: preferences)
    weak var releasedModel = model
    model?.previewInteractionTrace = trace
    let application = NSApplication.shared
    let previousActivationPolicy = application.activationPolicy()
    application.setActivationPolicy(.regular)
    defer { application.setActivationPolicy(previousActivationPolicy) }
    var window: NSWindow? = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 1320, height: 860),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window?.isReleasedWhenClosed = false
    window?.title = "FSC interaction diagnostic — programmatic controls"
    window?.contentView = NSHostingView(
      rootView: AnyView(ContentView(model: try #require(model), camera: CameraController())))
    window?.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    defer {
      window?.contentView = nil
      window?.close()
      model?.selection = nil
      model?.loadSelection()
    }
    model?.importFiles([input])
    try await waitUntil("first RAW preview", timeout: .seconds(90)) {
      model?.previewImage != nil && model?.isLoading == false
    }
    model?.loadRawDetailPreview()
    try await waitUntil("full RAW preview", timeout: .seconds(180)) {
      model?.previewSourceKind == .rawFull && model?.isRendering == false
        && model?.isUpgradingRawPreview == false
    }
    model?.setFilmBase(.colorC41)
    model?.applyLookRecipe(.cleanInvert)
    try await waitUntil("Clean Invert", timeout: .seconds(30)) { model?.isRendering == false }
    let dimensions = try #require(model?.previewImage?.size)
    try #require(dimensions.width > 4_000, "The benchmark requires full-sensor pixels")
    try await waitUntil("native viewport", timeout: .seconds(10)) {
      window?.contentView.flatMap { findPreview(in: $0) } != nil
    }
    let maximumFPS = window?.screen?.maximumFramesPerSecond ?? 0
    let capture = PreviewCompositorCapture(origin: trace.origin)
    try await capture.start(windowNumber: try #require(window).windowNumber)
    let results: [Case]
    do {
      results = try await replayCases(
        model: try #require(model), window: try #require(window), dimensions: dimensions,
        trace: trace, repetitions: repetitions, eventCount: eventCount,
        periodMilliseconds: periodMilliseconds)
    } catch {
      _ = try? await capture.stop()
      throw error
    }
    let compositorCapture = try await capture.stop()
    try await model?.flushSettings()
    model?.selection = nil
    model?.loadSelection()
    (window?.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
    // Allow SwiftUI to retire the old hosted graph before detaching its window.
    try? await Task.sleep(for: .milliseconds(50))
    window?.contentView = nil
    window?.close()
    window = nil
    model = nil
    var cleanupIssue: String?
    do {
      try await waitUntil("model release", timeout: .seconds(30)) { releasedModel == nil }
    } catch {
      cleanupIssue = String(describing: error)
    }
    let modelReleased = releasedModel == nil
    #expect(trace.discardedEventCount == 0)
    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      input: "sample-raw/fuji400-fresh/DSCF2833.RAF", inputSHA256: digest,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      hardware: hardwareDescription(), processorCount: ProcessInfo.processInfo.processorCount,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      screenMaximumFramesPerSecond: maximumFPS,
      sourceWidth: Int(dimensions.width), sourceHeight: Int(dimensions.height),
      inputPeriodMilliseconds: periodMilliseconds, eventsPerGesture: eventCount,
      repetitions: repetitions, cases: results, discardedTraceEvents: trace.discardedEventCount,
      compositorCapture: compositorCapture,
      memoryBefore: memoryBefore, memoryAfterRelease: memorySample(),
      modelReleased: modelReleased, cleanupIssue: cleanupIssue,
      physicalScreenPresentationMeasured: false,
      note:
        "Production ContentView, native NSWindow/NSScrollView and real one-pass full RAW source; C-41 / Clean Invert / photographic tone v2. Programmatic model setters are scheduled at 120 Hz and actual arrival times are retained. Native pointer dispatch is not exercised. modelPublished is recorded after NSImage and detail assignment. viewportUpdated records NSHostingView content replacement; hosting callbacks observe native preparation/drawing only, may be absent for layer-backed rendering, and do not acknowledge compositor presentation or physical screen scan-out. Rates derived from those callbacks must not be called displayed FPS. ScreenCaptureKit observes only this diagnostic window and decodes a revision marker centered inside the same NSHostingView content as the preview raster and detail; the marker is not an image-pixel checksum; callback latency includes capture delivery, and compositor-observed revisions are not physical screen scan-out measurements. No display timer is used as a proxy for delivered frames. Final refinement checks full raster dimensions and exact current parameters. Replay cases alternate order; raw observations describe this run, not population tail guarantees. Only timing, numeric marker observations and metadata are saved; no exports or captured images are written."
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: outputURL, options: .atomic)
    print("PREVIEW_INTERACTION_REPORT \(outputURL.path)")
    #expect(modelReleased, "The report is preserved, but model cleanup did not complete")
  }

  // Scope UI/model locals separately so the lifecycle gate never measures
  // references retained by the replay's asynchronous function frame itself.
  private func replayCases(
    model: AppModel, window: NSWindow, dimensions: CGSize,
    trace: PreviewInteractionTrace, repetitions: Int, eventCount: Int,
    periodMilliseconds: Double
  ) async throws -> [Case] {
    var results: [Case] = []
    for repetition in 0..<repetitions {
      let caseNames =
        repetition.isMultiple(of: 2)
        ? ["fit-exposure", "fit-contrast", "100%-contrast", "100%-exposure"]
        : ["100%-exposure", "100%-contrast", "fit-contrast", "fit-exposure"]
      for name in caseNames {
        let activeModel = model
        let scrollView = try #require(window.contentView.flatMap { findPreview(in: $0) })
        let isFit = name.hasPrefix("fit")
        NotificationCenter.default.post(
          name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        let magnification =
          isFit
          ? PreviewViewportZoom.fitMagnification(
            imageSize: dimensions, viewportSize: scrollView.contentSize) : 1
        scrollView.setMagnification(
          magnification, centeredAt: NSPoint(x: dimensions.width / 2, y: dimensions.height / 2))
        if let document = scrollView.documentView {
          let clip = scrollView.contentView
          let center = clip.convert(
            NSPoint(x: dimensions.width / 2, y: dimensions.height / 2), from: document)
          var bounds = clip.bounds
          bounds.origin = NSPoint(
            x: center.x - bounds.width / 2, y: center.y - bounds.height / 2)
          clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
          scrollView.reflectScrolledClipView(clip)
        }
        NotificationCenter.default.post(
          name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        activeModel.setExposureEV(0)
        activeModel.setContrast(0)
        try await waitUntil("reset", timeout: .seconds(30)) { !activeModel.isRendering }
        // Let view layout/diagnostics finish before the independently timed gesture.
        try await Task.sleep(for: .milliseconds(200))
        let startEvent = trace.events.count
        let gestureStart = trace.milliseconds()
        let isExposure = name.hasSuffix("exposure")
        activeModel.beginEditingGesture(named: isExposure ? "Exposure" : "Contrast")
        let replayStart = ContinuousClock.now
        var inputs: [Input] = []
        for index in 0..<eventCount {
          let offsetNanoseconds = Int64((Double(index) * periodMilliseconds * 1e6).rounded())
          let scheduled = replayStart.advanced(by: .nanoseconds(offsetNanoseconds))
          try await Task.sleep(until: scheduled, clock: .continuous)
          // One smooth traverse with a non-neutral endpoint. Values are public
          // parameters, not pointer positions or synthetic NSEvents.
          let fraction = Double(index + 1) / Double(eventCount)
          let value = (isExposure ? 0.75 : 0.5) * sin(fraction * .pi * 1.5)
          let start = trace.milliseconds()
          if isExposure {
            activeModel.setExposureEV(value)
          } else {
            activeModel.setContrast(value)
          }
          inputs.append(
            Input(
              index: index, scheduledMilliseconds: trace.milliseconds(at: scheduled),
              setterStartMilliseconds: start, setterEndMilliseconds: trace.milliseconds(),
              value: value))
        }
        let release = trace.milliseconds()
        activeModel.endEditingGesture()
        try await waitUntil("exact final refinement", timeout: .seconds(30)) {
          !activeModel.isRendering
            && activeModel.publishedPreviewParameters == activeModel.parameters
        }
        let final = try #require(activeModel.previewImage.flatMap(PreviewBitmap.cgImage))
        #expect(final.width == Int(dimensions.width) && final.height == Int(dimensions.height))
        #expect(activeModel.previewDetail == nil)
        try await Task.sleep(for: .milliseconds(200))
        let events = Array(trace.events.dropFirst(startEvent))
        let duringGesture = events.filter {
          $0.stage == .modelPublished && $0.milliseconds < release
        }
        #expect(!duringGesture.isEmpty)
        #expect(duringGesture.contains { isFit ? $0.usesProxy == true : $0.hasDetail == true })
        #expect(events.contains { $0.stage == .viewportUpdated })
        results.append(
          Case(
            name: name, repetition: repetition + 1,
            viewportWidthPoints: scrollView.contentSize.width,
            viewportHeightPoints: scrollView.contentSize.height,
            magnification: scrollView.magnification,
            backingScale: Double(window.backingScaleFactor),
            gestureStartMilliseconds: gestureStart, releaseMilliseconds: release,
            finalRevision: activeModel.publishedRenderRevision,
            inputs: inputs, events: events, memoryAfter: memorySample()))
      }
    }
    return results
  }

  private func findPreview(in view: NSView) -> PreviewScrollView? {
    if let preview = view as? PreviewScrollView { return preview }
    return view.subviews.lazy.compactMap { findPreview(in: $0) }.first
  }

  private func waitUntil(
    _ description: String, timeout: Duration, ready: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !ready() {
      if ContinuousClock.now >= deadline {
        throw NSError(
          domain: "PreviewInteractionDiagnostic", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"])
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func memorySample() -> Memory {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return Memory(
      physicalFootprintBytes: status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0,
      peakPhysicalFootprintBytes: status == KERN_SUCCESS
        ? UInt64(max(0, info.ledger_phys_footprint_peak)) : 0,
      reusableBytes: status == KERN_SUCCESS ? UInt64(info.reusable) : 0)
  }

  private func hardwareDescription() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
