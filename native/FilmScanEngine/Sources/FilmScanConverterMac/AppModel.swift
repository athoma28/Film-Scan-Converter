import AppKit
import FilmScanEngine
import FilmScanPreviewRenderer
import os.signpost

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var files: [URL] = []
  @Published var selection: URL?
  @Published private(set) var previewImage: NSImage?
  @Published private(set) var decodedImage: UInt16Image?
  @Published private(set) var parameters = ProcessingParameters()
  @Published private(set) var isRendering = false
  @Published var showOriginal = false {
    didSet { scheduleRender() }
  }
  @Published private(set) var status = "Drop film scans into the window to begin."
  @Published private(set) var renderStats = RenderStats()

  public struct RenderStats: Sendable {
    public var submittedSnapshots: Int = 0
    public var displayedRenders: Int = 0
    public var droppedSnapshots: Int = 0
    public var lastLatencyMs: Double = 0
    public var peakLatencyMs: Double = 0
    public var totalSubmissionLatencyMs: Double = 0
  }

  private var settingsByPath: [String: ProcessingParameters] = [:]
  private var previewCache: [String: CachedPreviewSession] = [:]
  private var previewCacheOrder: [String] = []
  private var previewSource: UInt16Image?
  private var previewRenderer: StillPreviewRenderer?
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var pendingRender: PreviewRenderRequest?
  private var renderLoopGeneration = 0
  private var lastSubmitTime: Date = .distantPast
  private var lastRenderEnd: ContinuousClock.Instant = .now
  private static let renderCoalesceInterval: Duration = .milliseconds(17)
  private static let previewMaxDimension = 640
  private static let previewCacheLimit = 2

  private static let renderLog = OSLog(
    subsystem: "film.scan.converter", category: "StillPreview")
  private static let signpostLog = OSLog(
    subsystem: "film.scan.converter", category: "Signpost")

  func importFiles(_ urls: [URL]) {
    let supported = FileDropPolicy.supportedFiles(from: urls)
    guard !supported.isEmpty else {
      status = "No supported image or RAW files were dropped."
      return
    }

    let existing = Set(files.map(\.standardizedFileURL.path))
    files.append(contentsOf: supported.filter { !existing.contains($0.standardizedFileURL.path) })
    selection = supported.first
    loadSelection()
  }

  func loadSelection() {
    loadTask?.cancel()
    cancelRenderLoop()

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      previewSource = nil
      previewRenderer = nil
      status = "Drop film scans into the window to begin."
      return
    }

    previewImage = nil
    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    parameters = settingsByPath[settingsKey(selection)] ?? ProcessingParameters()
    showOriginal = false

    let key = settingsKey(selection)
    if let cached = previewCache[key] {
      applyCachedSession(cached, selection: selection)
      touchPreviewCache(key)
      return
    }

    status = "Decoding \(selection.lastPathComponent)..."

    loadTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        let decoded = try await Task.detached(priority: .userInitiated) {
          if StandardImageDecoder.supportedExtensions.contains(selection.pathExtension.lowercased())
          {
            return try StandardImageDecoder.decode(selection)
          }
          return try RawImageDecoder.decode(selection).image
        }.value
        try Task.checkCancellation()
        guard self.selection == selection else {
          return
        }
        decodedImage = decoded
        let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
        previewSource = proxy
        previewRenderer = StillPreviewRenderer(image: proxy)
        cacheCurrentSession(for: selection)
        scheduleRender(immediate: true)
      } catch is CancellationError {
        return
      } catch {
        guard self.selection == selection else {
          return
        }
        status = "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)"
      }
    }
  }

  func setFilmType(_ value: FilmType) {
    updateParameters { $0.filmType = value }
  }

  func setTemperature(_ value: Int) {
    updateParameters { $0.temperature = value }
  }

  func setTint(_ value: Int) {
    updateParameters { $0.tint = value }
  }

  func setGamma(_ value: Int) {
    updateParameters { $0.gamma = value }
  }

  func setShadows(_ value: Int) {
    updateParameters { $0.shadows = value }
  }

  func setHighlights(_ value: Int) {
    updateParameters { $0.highlights = value }
  }

  func setSaturation(_ value: Int) {
    updateParameters { $0.saturation = value }
  }

  func setCurveEnabled(_ value: Bool) {
    updateParameters {
      $0.curveEnabled = value
      if value && $0.curveControlPoints.isEmpty {
        $0.curveControlPoints = [
          CurvePoint(input: 0, output: 0),
          CurvePoint(input: 0.25, output: 0.2),
          CurvePoint(input: 0.5, output: 0.5),
          CurvePoint(input: 0.75, output: 0.8),
          CurvePoint(input: 1, output: 1),
        ]
      }
    }
  }

  func setCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters {
      $0.curveEnabled = true
      $0.curveControlPoints = points
    }
  }

  func setRedCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters {
      $0.redCurveEnabled = true
      $0.redCurveControlPoints = points
    }
  }

  func setGreenCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters {
      $0.greenCurveEnabled = true
      $0.greenCurveControlPoints = points
    }
  }

  func setBlueCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters {
      $0.blueCurveEnabled = true
      $0.blueCurveControlPoints = points
    }
  }

  func setHighlightWheelHue(_ value: Double) {
    updateParameters { $0.highlightWheel.hue = value }
  }

  func setHighlightWheelStrength(_ value: Double) {
    updateParameters { $0.highlightWheel.strength = value }
  }

  func setMidtoneWheelHue(_ value: Double) {
    updateParameters { $0.midtoneWheel.hue = value }
  }

  func setMidtoneWheelStrength(_ value: Double) {
    updateParameters { $0.midtoneWheel.strength = value }
  }

  func setShadowWheelHue(_ value: Double) {
    updateParameters { $0.shadowWheel.hue = value }
  }

  func setShadowWheelStrength(_ value: Double) {
    updateParameters { $0.shadowWheel.strength = value }
  }

  func rotateCounterclockwise() {
    updateParameters { $0.rotation = ($0.rotation + 3) % 4 }
  }

  func rotateClockwise() {
    updateParameters { $0.rotation = ($0.rotation + 1) % 4 }
  }

  func toggleFlip() {
    updateParameters { $0.flip.toggle() }
  }

  func resetCorrections() {
    parameters = ProcessingParameters()
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender(immediate: true)
    }
  }

  func showImportPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = []
    guard panel.runModal() == .OK else {
      return
    }
    importFiles(panel.urls)
  }

  private func updateParameters(_ update: (inout ProcessingParameters) -> Void) {
    update(&parameters)
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender()
    }
  }

  private func saveParameters() {
    guard let selection else {
      return
    }
    settingsByPath[settingsKey(selection)] = parameters
  }

  private func applyCachedSession(_ session: CachedPreviewSession, selection: URL) {
    decodedImage = session.decodedImage
    previewSource = session.previewSource
    previewRenderer = session.previewRenderer
    status = "Loaded \(selection.lastPathComponent) from preview cache."
    scheduleRender(immediate: true)
  }

  private func cacheCurrentSession(for selection: URL) {
    guard let decodedImage, let previewSource, let previewRenderer else {
      return
    }
    let key = settingsKey(selection)
    previewCache[key] = CachedPreviewSession(
      decodedImage: decodedImage,
      previewSource: previewSource,
      previewRenderer: previewRenderer
    )
    touchPreviewCache(key)
    while previewCacheOrder.count > Self.previewCacheLimit {
      let evicted = previewCacheOrder.removeFirst()
      previewCache.removeValue(forKey: evicted)
    }
  }

  private func touchPreviewCache(_ key: String) {
    previewCacheOrder.removeAll { $0 == key }
    previewCacheOrder.append(key)
  }

  private func scheduleRender(immediate _: Bool = false) {
    guard let selection, let previewSource else {
      return
    }

    let previousHadPending = pendingRender != nil
    pendingRender = PreviewRenderRequest(
      selection: selection,
      source: previewSource,
      renderer: previewRenderer,
      parameters: parameters,
      showOriginal: showOriginal,
      submitTime: Date()
    )

    if previousHadPending {
      var stats = renderStats
      stats.droppedSnapshots += 1
      renderStats = stats
    }

    var stats = renderStats
    stats.submittedSnapshots += 1
    renderStats = stats
    lastSubmitTime = Date()

    let signpostID = OSSignpostID(log: Self.signpostLog)
    os_signpost(
      .event, log: Self.signpostLog, name: "Parameter Snapshot Submitted",
      signpostID: signpostID,
      "filmType=%d temp=%d tint=%d gamma=%d shadows=%d highlights=%d sat=%d curve=%d hW=%d/%d mW=%d/%d sW=%d/%d",
      parameters.filmType.rawValue, parameters.temperature, parameters.tint,
      parameters.gamma, parameters.shadows, parameters.highlights,
      parameters.saturation, parameters.curveEnabled ? 1 : 0,
      Int(parameters.highlightWheel.hue), Int(parameters.highlightWheel.strength * 100),
      Int(parameters.midtoneWheel.hue), Int(parameters.midtoneWheel.strength * 100),
      Int(parameters.shadowWheel.hue), Int(parameters.shadowWheel.strength * 100))

    isRendering = true
    status = "Rendering \(selection.lastPathComponent)..."
    guard renderTask == nil else {
      return
    }

    renderLoopGeneration += 1
    let generation = renderLoopGeneration
    renderTask = Task { [weak self] in
      guard let self else { return }
      let now = ContinuousClock.now
      let elapsed = self.lastRenderEnd.duration(to: now)
      if elapsed < Self.renderCoalesceInterval {
        try? await Task.sleep(for: Self.renderCoalesceInterval - elapsed)
      }
      guard generation == self.renderLoopGeneration, !Task.isCancelled else { return }
      await self.processRenderQueue(generation: generation)
    }
  }

  private func processRenderQueue(generation: Int) async {
    while !Task.isCancelled, let request = pendingRender {
      pendingRender = nil
      let signpostID = OSSignpostID(log: Self.signpostLog)
      let renderStart = Date()
      let submitTime = request.submitTime

      let preview: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
        if let renderer = request.renderer,
          let rendered = renderer.render(
            parameters: request.parameters,
            showOriginal: request.showOriginal
          )
        {
          return rendered
        }
        let rendered =
          request.showOriginal
          ? request.source.rotated(
            quarterTurns: request.parameters.rotation,
            flipHorizontally: request.parameters.flip
          )
          : FilmProcessing.correctedPreview(
            image: request.source,
            parameters: request.parameters
          )
        return rendered.makePreviewCGImage()
      }.value

      let renderDuration = Date().timeIntervalSince(renderStart) * 1000

      guard !Task.isCancelled else {
        break
      }
      guard pendingRender == nil else {
        lastRenderEnd = ContinuousClock.now
        let now = ContinuousClock.now
        let elapsed = lastRenderEnd.duration(to: now)
        let interval = Self.renderCoalesceInterval
        if elapsed < interval {
          try? await Task.sleep(for: interval - elapsed)
        }
        guard generation == renderLoopGeneration else { break }
        continue
      }
      guard selection == request.selection,
        parameters == request.parameters,
        showOriginal == request.showOriginal,
        let preview
      else {
        continue
      }

      let totalLatency = Date().timeIntervalSince(submitTime) * 1000
      var stats = renderStats
      stats.displayedRenders += 1
      stats.lastLatencyMs = totalLatency
      stats.peakLatencyMs = max(stats.peakLatencyMs, totalLatency)
      stats.totalSubmissionLatencyMs += totalLatency
      renderStats = stats

      os_signpost(
        .event, log: Self.signpostLog, name: "Frame Displayed",
        signpostID: signpostID,
        "renderMs=%.1f totalMs=%.1f submissions=%d displayed=%d dropped=%d",
        renderDuration, totalLatency,
        stats.submittedSnapshots, stats.displayedRenders, stats.droppedSnapshots)

      previewImage = NSImage(cgImage: preview, size: .zero)
      status =
        "\(request.selection.lastPathComponent) • \(preview.width)×\(preview.height) GPU preview"

      lastRenderEnd = ContinuousClock.now
      guard pendingRender == nil else {
        let now = ContinuousClock.now
        let elapsed = lastRenderEnd.duration(to: now)
        let interval = Self.renderCoalesceInterval
        if elapsed < interval {
          try? await Task.sleep(for: interval - elapsed)
        }
        guard generation == renderLoopGeneration else { break }
        continue
      }
    }

    guard generation == renderLoopGeneration else {
      return
    }
    renderTask = nil
    isRendering = false
  }

  private func cancelRenderLoop() {
    renderLoopGeneration += 1
    renderTask?.cancel()
    renderTask = nil
    pendingRender = nil
    isRendering = false
  }

  private func settingsKey(_ url: URL) -> String {
    url.standardizedFileURL.path
  }
}

private struct PreviewRenderRequest: Sendable {
  let selection: URL
  let source: UInt16Image
  let renderer: StillPreviewRenderer?
  let parameters: ProcessingParameters
  let showOriginal: Bool
  let submitTime: Date
}

private struct CachedPreviewSession {
  let decodedImage: UInt16Image
  let previewSource: UInt16Image
  let previewRenderer: StillPreviewRenderer
}
