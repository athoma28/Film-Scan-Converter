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
  @Published private(set) var exportParameters = ExportParameters()
  @Published private(set) var isExporting = false
  @Published private(set) var exportProgressCurrent = 0
  @Published private(set) var exportProgressTotal = 0
  @Published private(set) var exportErrors: [String] = []

  public struct RenderStats: Sendable {
    public var submittedSnapshots: Int = 0
    public var displayedRenders: Int = 0
    public var droppedSnapshots: Int = 0
    public var lastLatencyMs: Double = 0
    public var peakLatencyMs: Double = 0
    public var totalSubmissionLatencyMs: Double = 0
  }

  private var settingsByPath: [String: ProcessingParameters] = [:]
  private var decodedImagesByPath: [String: UInt16Image] = [:]
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
      ImportLog.error("No supported files in import batch")
      status = "No supported image or RAW files were dropped."
      return
    }

    let existing = Set(files.map(\.standardizedFileURL.path))
    let newFiles = supported.filter { !existing.contains($0.standardizedFileURL.path) }
    ImportLog.importAdded(path: "appending \(newFiles.count) new files (total will be \(files.count + newFiles.count))")
    files.append(contentsOf: newFiles)
    selection = supported.first
    loadSelection()
  }

  private var loadGeneration = 0

  func loadSelection() {
    loadTask?.cancel()
    cancelRenderLoop()
    loadGeneration += 1
    let gen = loadGeneration

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      previewSource = nil
      previewRenderer = nil
      status = "Drop film scans into the window to begin."
      return
    }

    ImportLog.loadSelectionStarted(path: selection.lastPathComponent)

    previewImage = nil
    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    parameters = settingsByPath[settingsKey(selection)] ?? ProcessingParameters()
    showOriginal = false

    let key = settingsKey(selection)
    if let cached = previewCache[key] {
      ImportLog.loadSelectionCacheHit(path: selection.lastPathComponent)
      applyCachedSession(cached, selection: selection)
      touchPreviewCache(key)
      return
    }

    status = "Decoding \(selection.lastPathComponent)..."
    ImportLog.loadSelectionDecodeStarted(path: selection.lastPathComponent)

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
        guard gen == self.loadGeneration else {
          ImportLog.loadSelectionCancelled(path: selection.lastPathComponent)
          return
        }
        guard self.selection == selection else {
          ImportLog.loadSelectionCancelled(path: selection.lastPathComponent)
          return
        }
        ImportLog.loadSelectionDecodeComplete(
          path: selection.lastPathComponent,
          width: decoded.width,
          height: decoded.height,
          channels: decoded.channels
        )
        decodedImage = decoded
        decodedImagesByPath[settingsKey(selection)] = decoded
        let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
        previewSource = proxy
        previewRenderer = StillPreviewRenderer(image: proxy)
        populateFilmNegativeMedians()
        cacheCurrentSession(for: selection)
        scheduleRender(immediate: true)
      } catch is CancellationError {
        ImportLog.loadSelectionCancelled(path: selection.lastPathComponent)
        return
      } catch {
        guard gen == self.loadGeneration else {
          ImportLog.loadSelectionCancelled(path: selection.lastPathComponent)
          return
        }
        guard self.selection == selection else {
          ImportLog.loadSelectionCancelled(path: selection.lastPathComponent)
          return
        }
        ImportLog.loadSelectionDecodeFailed(
          path: selection.lastPathComponent,
          error: error.localizedDescription
        )
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

  func setFilmNegativeEnabled(_ value: Bool) {
    let medians = value ? computeFilmNegativeMedians() : nil
    updateParameters {
      $0.filmNegativeParams.enabled = value
      if let medians {
        $0.filmNegativeParams.measuredMedians = medians
      }
    }
  }

  func setFilmNegativeRedRatio(_ value: Double) {
    updateParameters { $0.filmNegativeParams.redRatio = value }
  }

  func setFilmNegativeGreenExp(_ value: Double) {
    updateParameters { $0.filmNegativeParams.greenExp = value }
  }

  func setFilmNegativeBlueRatio(_ value: Double) {
    updateParameters { $0.filmNegativeParams.blueRatio = value }
  }

  func setFilmNegativePreset(_ preset: FilmNegativePreset) {
    let medians = preset != .off ? computeFilmNegativeMedians() : nil
    updateParameters {
      switch preset {
      case .off:
        $0.filmNegativeParams.enabled = false
      case .colourNegative:
        $0.filmNegativeParams = FilmNegativeParams.colourNegative
      case .blackAndWhite:
        $0.filmNegativeParams = FilmNegativeParams.blackAndWhite
      }
      if let medians {
        $0.filmNegativeParams.measuredMedians = medians
      }
    }
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

  func showExportFolderPicker() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Select Export Folder"
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    exportParameters.destinationDirectory = url
  }

  func setExportFormat(_ format: ExportFormat) {
    exportParameters.format = format
  }

  func setExportFramePercent(_ percent: Int) {
    exportParameters.framePercent = percent
  }

  func setExportAspectRatio(_ ratio: AspectRatio?) {
    exportParameters.aspectRatio = ratio
  }

  func setExportAspectRatioCustom(width: Int, height: Int) {
    if width > 0 && height > 0 {
      exportParameters.aspectRatio = AspectRatio(width: width, height: height)
    } else {
      exportParameters.aspectRatio = nil
    }
  }

  func setJpegQuality(_ quality: Double) {
    exportParameters.jpegQuality = quality
  }

  func setTiffCompression(_ compression: TiffCompression) {
    exportParameters.tiffCompression = compression
  }

  func exportSelected() {
    guard let selection else {
      status = "No image selected for export."
      return
    }
    exportFiles([selection])
  }

  func exportAll() {
    guard !files.isEmpty else {
      status = "No images to export."
      return
    }
    exportFiles(files)
  }

  private func exportFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    guard let destDir = exportParameters.destinationDirectory else {
      status = "Select an export destination folder first."
      return
    }

    var params = exportParameters
    params.destinationDirectory = destDir
    let exportParams = params

    isExporting = true
    exportProgressCurrent = 0
    exportProgressTotal = urls.count
    exportErrors = []
    status = "Exporting..."

    Task { [weak self] in
      guard let self else { return }

      let requests: [ExportManager.ExportRequest] =
        urls.compactMap { url in
          let key = self.settingsKey(url)
          let fileParams = self.settingsByPath[key] ?? ProcessingParameters()
          guard let decoded = self.decodedImagesByPath[key] ?? self.decodedImage else {
            return nil
          }

          var processed: UInt16Image
          if fileParams.filmType == .cropOnly || fileParams == ProcessingParameters() {
            processed = decoded.rotated(
              quarterTurns: fileParams.rotation,
              flipHorizontally: fileParams.flip
            )
          } else {
            processed = FilmProcessing.correctedPreview(
              image: decoded,
              parameters: fileParams
            )
          }

          if exportParams.framePercent > 0 || exportParams.aspectRatio != nil {
            processed = processed.addingFrame(
              percent: exportParams.framePercent,
              aspectRatio: exportParams.aspectRatio
            )
          }

          let baseName = url.deletingPathExtension().lastPathComponent
          let ext = exportParams.format.fileExtension
          let destURL = destDir.appendingPathComponent("\(baseName).\(ext)")

          return ExportManager.ExportRequest(
            sourceURL: url,
            destinationURL: destURL,
            image: processed,
            parameters: exportParams
          )
        }

      if requests.isEmpty {
        await MainActor.run {
          self.isExporting = false
          self.status = "No images could be prepared for export."
        }
        return
      }

      let manager = ExportManager()
      let results = await manager.exportBatch(
        requests: requests,
        progress: { current, total, success in
          Task { @MainActor in
            self.exportProgressCurrent = current
            self.exportProgressTotal = total
          }
        }
      )

      await MainActor.run {
        self.isExporting = false
        let failures = results.filter { !$0.isSuccess }
        if failures.isEmpty {
          self.status = "Exported \(results.count) image\(results.count == 1 ? "" : "s") to \(destDir.lastPathComponent)."
        } else {
          self.exportErrors = failures.compactMap { result in
            result.error.map { "\(result.sourceURL.lastPathComponent): \($0.localizedDescription)" }
          }
          self.status = "Export complete with \(failures.count) error\(failures.count == 1 ? "" : "s")."
        }
      }
    }
  }

  private func computeFilmNegativeMedians() -> BGRChannelValues? {
    guard let proxy = previewSource, proxy.channels == 3 else { return nil }
    return FilmNegativeProcessing.computeMedians(image: proxy, borderPercent: 20.0)
  }

  private func populateFilmNegativeMedians() {
    guard let medians = computeFilmNegativeMedians() else { return }
    updateParameters {
      $0.filmNegativeParams.measuredMedians = medians
    }
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
    decodedImagesByPath[settingsKey(selection)] = session.decodedImage
    previewSource = session.previewSource
    previewRenderer = session.previewRenderer
    populateFilmNegativeMedians()
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
