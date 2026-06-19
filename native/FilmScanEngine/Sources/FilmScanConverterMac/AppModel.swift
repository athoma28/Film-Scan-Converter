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
  @Published private(set) var isShowingEmbeddedRawPreview = false
  @Published private(set) var exportParameters = ExportParameters()
  @Published private(set) var isExporting = false
  @Published private(set) var exportProgressCurrent = 0
  @Published private(set) var exportProgressTotal = 0
  @Published private(set) var exportErrors: [String] = []
  @Published private(set) var rebateCandidates: [AutomaticRebateCandidate] = []
  @Published private(set) var selectedRebateMeasurement: FilmBaseMeasurement?
  @Published private(set) var selectedRebateRegion: ImageRegion?
  @Published private(set) var isRebateDetectionRunning = false
  @Published private(set) var rollProfile: RollProfile?
  @Published private(set) var rebateStatus: String = ""

  let profileStore: ProfileStore

  init(profileStore: ProfileStore? = nil) {
    if let profileStore {
      self.profileStore = profileStore
      return
    }
    if let store = ProfileStore(appGroupIdentifier: "FilmScanConverter") {
      self.profileStore = store
    } else {
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("FilmScanConverter")
      self.profileStore = ProfileStore(baseDirectory: fallback)
    }
  }

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
  private var rawSwapTask: Task<Void, Never>?
  private var predecodeTask: Task<Void, Never>?
  private var rebateTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var pendingRender: PreviewRenderRequest?
  private var renderLoopGeneration = 0
  private var lastSubmitTime: Date = .distantPast
  private var lastRenderEnd: ContinuousClock.Instant = .now
  private static let renderCoalesceInterval: Duration = .milliseconds(17)
  nonisolated private static let previewMaxDimension = 640
  private static let previewCacheLimit = 2
  private static let predecodeLookaheadLimit = 1

  var previewCacheSessionCount: Int {
    previewCache.count
  }

  func hasCachedPreview(for url: URL) -> Bool {
    previewCache[settingsKey(url)] != nil
  }

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
  private var rebateGeneration = 0

  func loadSelection() {
    loadTask?.cancel()
    rawSwapTask?.cancel()
    cancelRenderLoop()
    loadGeneration += 1
    let gen = loadGeneration
    resetRebateState(cancelTask: true)

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      previewSource = nil
      previewRenderer = nil
      isShowingEmbeddedRawPreview = false
      cancelPredecode()
      status = "Drop film scans into the window to begin."
      return
    }

    cancelPredecode()
    ImportLog.loadSelectionStarted(path: selection.lastPathComponent)

    previewImage = nil
    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    isShowingEmbeddedRawPreview = false
    let key = settingsKey(selection)
    let hasStoredSettings = settingsByPath[key] != nil
    parameters = settingsByPath[key] ?? ProcessingParameters()
    showOriginal = false

    if let cached = previewCache[key] {
      ImportLog.loadSelectionCacheHit(path: selection.lastPathComponent)
      applyCachedSession(cached, selection: selection)
      touchPreviewCache(key)
      scheduleLookaheadPredecode(after: selection)
      return
    }

    ImportLog.loadSelectionDecodeStarted(path: selection.lastPathComponent)

    let isRaw = FileDropPolicy.rawExtensions.contains(selection.pathExtension.lowercased())

    if isRaw, let thumbnail = try? RawImageDecoder.extractThumbnail(selection) {
      let proxy = thumbnail.image.resizedToFit(maxDimension: Self.previewMaxDimension)
      previewSource = proxy
      previewRenderer = StillPreviewRenderer(image: proxy)
      isShowingEmbeddedRawPreview = true
      status = "Loading \(selection.lastPathComponent)..."
      if hasStoredSettings {
        populateFilmNegativeMedians()
      }
      cacheCurrentSession(for: selection)
      scheduleRender(immediate: true)
      scheduleLookaheadPredecode(after: selection)

      rawSwapTask = Task { [weak self] in
        guard let self else { return }
        do {
          let decoded = try await Task.detached(priority: .userInitiated) {
            return try RawImageDecoder.decode(selection, profile: .rawTherapeeCameraScan).image
          }.value
          try Task.checkCancellation()
          guard gen == self.loadGeneration else { return }
          guard self.selection == selection else { return }
          ImportLog.loadSelectionDecodeComplete(
            path: selection.lastPathComponent,
            width: decoded.width,
            height: decoded.height,
            channels: decoded.channels
          )
          decodedImage = decoded
          isShowingEmbeddedRawPreview = false
          let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
          previewSource = proxy
          previewRenderer = StillPreviewRenderer(image: proxy)
          if hasStoredSettings {
            populateFilmNegativeMedians()
          } else {
            applyAutomaticFilmClassification(from: proxy)
          }
          cacheCurrentSession(for: selection)
          scheduleRender(immediate: true)
        } catch is CancellationError {
          return
        } catch {
          guard gen == self.loadGeneration else { return }
          guard self.selection == selection else { return }
          ImportLog.loadSelectionDecodeFailed(
            path: selection.lastPathComponent,
            error: error.localizedDescription
          )
          status = "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)"
        }
      }
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
          return try RawImageDecoder.decode(selection, profile: .rawTherapeeCameraScan).image
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
        let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
        previewSource = proxy
        previewRenderer = StillPreviewRenderer(image: proxy)
        isShowingEmbeddedRawPreview = false
        if hasStoredSettings {
          populateFilmNegativeMedians()
        } else {
          applyAutomaticFilmClassification(from: proxy)
        }
        cacheCurrentSession(for: selection)
        scheduleRender(immediate: true)
        scheduleLookaheadPredecode(after: selection)
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

  func setExportDestinationDirectory(_ url: URL?) {
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

  func detectRebate() {
    guard let source = previewSource, source.channels == 3 else {
      rebateStatus = "Load an image with 3 channels first."
      return
    }
    rebateTask?.cancel()
    rebateGeneration += 1
    let generation = rebateGeneration
    let selectedURL = selection
    isRebateDetectionRunning = true
    rebateStatus = "Searching for rebate edge candidates..."
    rebateCandidates = []
    selectedRebateMeasurement = nil
    selectedRebateRegion = nil

    rebateTask = Task { [weak self] in
      guard let self else { return }
      let result: [AutomaticRebateCandidate]
      if Task.isCancelled { return }
      result = await Task.detached(priority: .userInitiated) {
        let flatField = AppModel.unityFlatField(for: source)
        return FilmNegativeProcessing.automaticRebateCandidates(
          image: source,
          flatField: flatField
        )
      }.value
      guard !Task.isCancelled else { return }
      guard generation == rebateGeneration, selection == selectedURL else { return }
      rebateCandidates = result
      isRebateDetectionRunning = false
      if result.isEmpty {
        rebateStatus = "No rebate candidates detected."
      } else {
        rebateStatus =
          "Found \(result.count) rebate candidate\(result.count == 1 ? "" : "s")."
      }
    }
  }

  func measureRebateRegion(_ region: ImageRegion) {
    guard let source = previewSource, source.channels == 3 else {
      rebateStatus = "Load an image with 3 channels first."
      return
    }
    rebateTask?.cancel()
    rebateGeneration += 1
    let generation = rebateGeneration
    let selectedURL = selection
    rebateStatus = "Measuring base density..."
    rebateTask = Task { [weak self] in
      guard let self else { return }
      let result: Result<FilmBaseMeasurement, Error>
      result = await Task.detached(priority: .userInitiated) {
        let flatField = AppModel.unityFlatField(for: source)
        return Result {
          try FilmNegativeProcessing.measureBaseDensity(
            image: source,
            flatField: flatField,
            region: region
          )
        }
      }.value
      guard !Task.isCancelled else { return }
      guard generation == rebateGeneration, selection == selectedURL else { return }
      switch result {
      case .success(let measurement):
        selectedRebateMeasurement = measurement
        selectedRebateRegion = region
        rebateStatus = String(
          format:
            "Base density: B %.3f  G %.3f  R %.3f (confidence %.0f%%)",
          measurement.baseDensity.blue,
          measurement.baseDensity.green,
          measurement.baseDensity.red,
          measurement.confidence * 100
        )
      case .failure(let error):
        rebateStatus = "Measurement failed: \(error.localizedDescription)"
      }
    }
  }

  func selectRebateCandidate(_ candidate: AutomaticRebateCandidate) {
    rebateTask?.cancel()
    rebateTask = nil
    rebateGeneration += 1
    selectedRebateMeasurement = candidate.measurement
    selectedRebateRegion = candidate.region
    rebateStatus = String(
      format:
        "Base density: B %.3f  G %.3f  R %.3f (confidence %.0f%%)",
      candidate.measurement.baseDensity.blue,
      candidate.measurement.baseDensity.green,
      candidate.measurement.baseDensity.red,
      candidate.measurement.confidence * 100
    )
  }

  func createRollProfile(from candidate: AutomaticRebateCandidate) {
    let measurement = candidate.measurement
    selectedRebateMeasurement = measurement
    selectedRebateRegion = candidate.region

    let stockID = FilmStockProfileID(rawValue: "generic_colour_negative")
    let captureID = CaptureProfileID(rawValue: "default")
    let rollID = "roll-\(Date().timeIntervalSince1970)"

    let profile = RollProfile(
      rollID: rollID,
      filmStockID: stockID,
      captureProfileID: captureID,
      measurements: [measurement]
    )
    do {
      try profileStore.saveRollProfile(profile)
      rollProfile = profile
      rebateStatus = "Roll profile saved as \(rollID)."
    } catch {
      rebateStatus = "Unable to save roll profile: \(error.localizedDescription)"
    }
  }

  func clearRebateMeasurement() {
    resetRebateState(cancelTask: true)
  }

  private func resetRebateState(cancelTask: Bool) {
    if cancelTask {
      rebateTask?.cancel()
      rebateTask = nil
      rebateGeneration += 1
    }
    rebateCandidates = []
    selectedRebateMeasurement = nil
    selectedRebateRegion = nil
    rollProfile = nil
    isRebateDetectionRunning = false
    rebateStatus = ""
  }

  nonisolated private static func unityFlatField(for image: UInt16Image) -> UInt16Image {
    let count = image.width * image.height * image.channels
    let pixels = [UInt16](repeating: 65535, count: count)
    return UInt16Image(
      width: image.width, height: image.height, channels: image.channels,
      pixels: pixels)
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
    let destinations: [URL]
    do {
      destinations = try reserveDestinationURLs(
        for: urls,
        destinationDirectory: destDir,
        format: exportParams.format
      )
    } catch {
      status = "Unable to inspect export destination: \(error.localizedDescription)"
      return
    }

    isExporting = true
    exportProgressCurrent = 0
    exportProgressTotal = urls.count
    exportErrors = []
    status = "Exporting..."

    Task { [weak self] in
      guard let self else { return }

      let manager = ExportManager()
      var results: [ExportManager.ExportResult] = []
      results.reserveCapacity(urls.count)

      for (index, pair) in zip(urls, destinations).enumerated() {
        let (url, destinationURL) = pair
        if Task.isCancelled {
          results.append(
            ExportManager.ExportResult(
              sourceURL: url,
              destinationURL: destinationURL,
              error: ExportManager.ExportManagerError.cancelled
            ))
          continue
        }

        do {
          let request = try await self.makeExportRequest(
            for: url,
            exportParams: exportParams,
            destinationURL: destinationURL
          )
          let fileResults = await manager.export(requests: [request])
          results.append(contentsOf: fileResults)
        } catch {
          results.append(
            ExportManager.ExportResult(
              sourceURL: url,
              destinationURL: destinationURL,
              error: error
            ))
        }

        await MainActor.run {
          self.exportProgressCurrent = index + 1
          self.exportProgressTotal = urls.count
        }
      }

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

  private func applyAutomaticFilmClassification(from image: UInt16Image) {
    parameters = Self.automaticallyClassifiedParameters(base: parameters, image: image)
    saveParameters()
  }

  private func makeExportRequest(
    for url: URL,
    exportParams: ExportParameters,
    destinationURL: URL
  ) async throws -> ExportManager.ExportRequest {
    let key = settingsKey(url)
    let decoded = try await decodedImageForExport(url)
    let fileParams: ProcessingParameters
    if let stored = settingsByPath[key] {
      fileParams = stored
    } else {
      let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
      let automatic = Self.automaticallyClassifiedParameters(
        base: ProcessingParameters(),
        image: proxy
      )
      settingsByPath[key] = automatic
      fileParams = automatic
    }

    let processed = await Task.detached(priority: .userInitiated) {
      var output: UInt16Image
      if fileParams.filmType == .cropOnly || fileParams == ProcessingParameters() {
        output = decoded.rotated(
          quarterTurns: fileParams.rotation,
          flipHorizontally: fileParams.flip
        )
      } else {
        output = FilmProcessing.correctedPreview(
          image: decoded,
          parameters: fileParams
        )
      }

      if exportParams.framePercent > 0 || exportParams.aspectRatio != nil {
        output = output.addingFrame(
          percent: exportParams.framePercent,
          aspectRatio: exportParams.aspectRatio
        )
      }
      return output
    }.value

    return ExportManager.ExportRequest(
      sourceURL: url,
      destinationURL: destinationURL,
      image: processed,
      parameters: exportParams
    )
  }

  private func decodedImageForExport(_ url: URL) async throws -> UInt16Image {
    let key = settingsKey(url)
    if selection == url, let decodedImage {
      return decodedImage
    }
    if let cached = previewCache[key] {
      return cached.decodedImage
    }
    return try await Task.detached(priority: .userInitiated) {
      return try Self.decodeImage(url)
    }.value
  }

  private func reserveDestinationURLs(
    for urls: [URL],
    destinationDirectory: URL,
    format: ExportFormat
  ) throws -> [URL] {
    let existingNames = try FileManager.default.contentsOfDirectory(
      at: destinationDirectory,
      includingPropertiesForKeys: nil
    ).map { $0.lastPathComponent.lowercased() }
    var reservedNames = Set(existingNames)

    return urls.map { sourceURL in
      let stem = sourceURL.deletingPathExtension().lastPathComponent
      let ext = format.fileExtension
      var suffix = 1
      var filename = "\(stem).\(ext)"
      while reservedNames.contains(filename.lowercased()) {
        suffix += 1
        filename = "\(stem)-\(suffix).\(ext)"
      }
      reservedNames.insert(filename.lowercased())
      return destinationDirectory.appendingPathComponent(filename)
    }
  }

  private static func automaticallyClassifiedParameters(
    base: ProcessingParameters,
    image: UInt16Image
  ) -> ProcessingParameters {
    let classification = FilmNegativeProcessing.classifyFilmScan(image: image)
    var next = base
    next.filmType = classification.filmType
    switch classification.filmNegativePreset {
    case .off:
      next.filmNegativeParams = FilmNegativeParams(enabled: false)
    case .colourNegative:
      next.filmNegativeParams = FilmNegativeParams.colourNegative
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .blackAndWhite:
      next.filmNegativeParams = FilmNegativeParams.blackAndWhite
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    }
    return next
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
    populateFilmNegativeMedians()
    status = "Loaded \(selection.lastPathComponent) from preview cache."
    scheduleRender(immediate: true)
  }

  private func scheduleLookaheadPredecode(after selection: URL) {
    guard Self.predecodeLookaheadLimit > 0, !isExporting else {
      return
    }
    guard let currentIndex = files.firstIndex(of: selection) else {
      return
    }

    let candidates = files.dropFirst(currentIndex + 1).prefix(Self.predecodeLookaheadLimit)
    guard let target = candidates.first else {
      return
    }
    let targetKey = settingsKey(target)
    guard previewCache[targetKey] == nil else {
      return
    }

    predecodeTask?.cancel()
    ImportLog.loadSelectionDecodeStarted(path: "predecode \(target.lastPathComponent)")
    predecodeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let session = try await Task.detached(priority: .utility) { () -> CachedPreviewSession? in
          let decoded = try Self.decodeImage(target)
          let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
          guard let renderer = StillPreviewRenderer(image: proxy) else {
            return nil
          }
          return CachedPreviewSession(
            decodedImage: decoded,
            previewSource: proxy,
            previewRenderer: renderer
          )
        }.value
        try Task.checkCancellation()
        guard let session else {
          return
        }

        guard !Task.isCancelled else { return }
        guard self.selection == selection, self.previewCache[targetKey] == nil else {
          return
        }

        if self.settingsByPath[targetKey] == nil {
          self.settingsByPath[targetKey] = Self.automaticallyClassifiedParameters(
            base: ProcessingParameters(),
            image: session.previewSource
          )
        }
        self.cacheSession(session, for: target)
      } catch is CancellationError {
        return
      } catch {
        ImportLog.loadSelectionDecodeFailed(
          path: "predecode \(target.lastPathComponent)",
          error: error.localizedDescription
        )
      }
    }
  }

  private func cancelPredecode() {
    predecodeTask?.cancel()
    predecodeTask = nil
  }

  private func cacheCurrentSession(for selection: URL) {
    guard let decodedImage, let previewSource, let previewRenderer else {
      return
    }
    cacheSession(
      CachedPreviewSession(
        decodedImage: decodedImage,
        previewSource: previewSource,
        previewRenderer: previewRenderer
      ),
      for: selection
    )
  }

  private func cacheSession(_ session: CachedPreviewSession, for url: URL) {
    let key = settingsKey(url)
    previewCache[key] = session
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

      let result: RenderedPreview? = await Task.detached(priority: .userInitiated) { () -> RenderedPreview? in
        if let renderer = request.renderer,
          let rendered = renderer.render(
            parameters: request.parameters,
            showOriginal: request.showOriginal
          )
        {
          return RenderedPreview(cgImage: rendered, rendererName: "GPU")
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
        guard let preview = rendered.makePreviewCGImage() else {
          return nil
        }
        return RenderedPreview(cgImage: preview, rendererName: "CPU")
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
        let result
      else {
        continue
      }
      let preview = result.cgImage

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
        "\(request.selection.lastPathComponent) • \(preview.width)×\(preview.height) \(result.rendererName) preview"

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

  nonisolated private static func decodeImage(_ url: URL) throws -> UInt16Image {
    if StandardImageDecoder.supportedExtensions.contains(url.pathExtension.lowercased()) {
      return try StandardImageDecoder.decode(url)
    }
    return try RawImageDecoder.decode(url, profile: .rawTherapeeCameraScan).image
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

private struct CachedPreviewSession: Sendable {
  let decodedImage: UInt16Image
  let previewSource: UInt16Image
  let previewRenderer: StillPreviewRenderer
}

private struct RenderedPreview: Sendable {
  let cgImage: CGImage
  let rendererName: String
}
