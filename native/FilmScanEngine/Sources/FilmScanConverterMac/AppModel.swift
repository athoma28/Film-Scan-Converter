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
  @Published private(set) var isLoading = false
  @Published var showOriginal = false {
    didSet {
      resetDustState(cancelTask: true)
      scheduleRender()
    }
  }
  @Published private(set) var status = "Drop film scans into the window to begin."
  @Published private(set) var renderStats = RenderStats()
  @Published private(set) var previewStatistics = RenderReadyImageStatistics.empty
  @Published private(set) var isShowingEmbeddedRawPreview = false
  @Published private(set) var isShowingProvisionalPreview = false
  @Published private(set) var exportParameters = ExportParameters()
  @Published private(set) var isExporting = false
  @Published private(set) var exportProgressCurrent = 0
  @Published private(set) var exportProgressTotal = 0
  @Published private(set) var exportErrors: [String] = []
  @Published private(set) var exportQueueCount = 0
  @Published private(set) var activeExportFilename: String?
  @Published private(set) var rebateCandidates: [AutomaticRebateCandidate] = []
  @Published private(set) var selectedRebateMeasurement: FilmBaseMeasurement?
  @Published private(set) var selectedRebateRegion: ImageRegion?
  @Published private(set) var isRebateDetectionRunning = false
  @Published private(set) var rollProfile: RollProfile?
  @Published private(set) var rebateStatus: String = ""
  @Published private(set) var flatFieldImage: UInt16Image?
  @Published private(set) var flatFieldURL: URL?
  @Published private(set) var cropRect: RotatedRect?
  @Published private(set) var perspectiveCrop: PerspectiveCrop?
  @Published private(set) var manualCrop: NormalizedCropRect?
  @Published private(set) var straightenAngle: Double = 0
  @Published private(set) var sourcePixelDimensions: PixelDimensions?
  @Published private(set) var cropThresholdPreview: UInt16Image?
  @Published private(set) var isCropDetectionRunning = false
  @Published private(set) var cropStatus: String = ""
  @Published private(set) var dustMaskImage: NSImage?
  @Published private(set) var isDustDetectionRunning = false
  @Published private(set) var dustStatus: String = ""
  @Published private(set) var namedCorrectionPresets: [NamedCorrectionPreset] = []
  @Published private(set) var settingsStatus: String = ""
  @Published private(set) var previewCacheLimit: Int
  @Published private(set) var availableCaptureProfiles: [CaptureProfile] = []
  @Published private(set) var availableFilmStockProfiles: [FilmStockProfile] = []
  @Published private(set) var availableRollProfiles: [RollProfile] = []
  @Published var selectedCaptureProfileID = CaptureProfile.default.id
  @Published var selectedFilmStockProfileID = FilmStockProfile.genericColorNegative.id
  @Published var selectedRollProfileID: String?
  @Published private(set) var profileStatus: String = ""

  let profileStore: ProfileStore
  private let settingsStore: PerFileSettingsStore?
  private let presetStore: NamedCorrectionPresetStore?
  private let settingsClipboard: CorrectionSettingsClipboard
  private let preferences: UserDefaults
  private let authoritativeDecoder = AuthoritativeImageDecoder()

  init(
    profileStore: ProfileStore? = nil,
    settingsStore: PerFileSettingsStore? = nil,
    presetStore: NamedCorrectionPresetStore? = nil,
    settingsClipboard: CorrectionSettingsClipboard = CorrectionSettingsClipboard(),
    preferences: UserDefaults = .standard
  ) {
    self.settingsStore = settingsStore
    self.presetStore = presetStore
    self.settingsClipboard = settingsClipboard
    self.preferences = preferences
    previewCacheLimit = max(2, preferences.integer(forKey: "previewCacheLimit"))
    if let profileStore {
      self.profileStore = profileStore
    } else if let store = ProfileStore(appGroupIdentifier: "FilmScanConverter") {
      self.profileStore = store
    } else {
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("FilmScanConverter")
      self.profileStore = ProfileStore(baseDirectory: fallback)
    }
    if let settingsStore {
      do {
        let state = try settingsStore.loadState()
        settingsByPath = state.settingsByPath
        editedKeys = state.editedPaths
      } catch {
        status = "Saved corrections could not be loaded; defaults are being used."
      }
    }
    if let presetStore {
      do {
        namedCorrectionPresets = try presetStore.load()
      } catch {
        settingsStatus = "Saved presets could not be loaded."
      }
    }
    reloadProfiles()
    Task.detached(priority: .medium) {
      StillPreviewRenderer.warmUp()
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
  private var automaticallyClassifiedKeys: Set<String> = []
  private var editedKeys: Set<String> = []
  private var sameRollFilmTypeHint: FilmType?
  private var previewCache: [String: CachedPreviewSession] = [:]
  private var previewCacheOrder: [String] = []
  private var previewSource: UInt16Image?
  private var previewRenderer: StillPreviewRenderer?
  private var loadTask: Task<Void, Never>?
  private var authoritativeDecodeTask: Task<Void, Never>?
  private var predecodeTask: Task<Void, Never>?
  private var rebateTask: Task<Void, Never>?
  private var cropDetectionTask: Task<Void, Never>?
  private var dustDetectionTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var pendingRender: PreviewRenderRequest?
  private var activeExportQueue: [URL] = []
  private var activeExportDestinations: [URL] = []
  private var activeExportCorrelationIDs: [String] = []
  private var activeExportQueueWaitIntervals: [AppPerformanceInterval] = []
  private var activeExportSeen: Set<String> = []
  private var activeExportParameters: ExportParameters?
  private var exportTask: Task<Void, Never>?
  private var exportWasCancelled = false
  private var renderLoopGeneration = 0
  private var lastSubmitTime: Date = .distantPast
  private var lastRenderEnd: ContinuousClock.Instant = .now
  private var pendingFirstPreviewInterval: AppPerformanceInterval?
  // Keep latest-value-wins scheduling bounded while allowing 120 Hz displays
  // to consume the sub-4 ms Metal renderer without an artificial 60 Hz cap.
  private static let renderCoalesceInterval: Duration = .milliseconds(8)
  nonisolated private static let previewMaxDimension = 640

  var previewCacheSessionCount: Int {
    previewCache.count
  }

  var selectedImageDimensions: (width: Int, height: Int, provisional: Bool)? {
    if let decodedImage {
      return (decodedImage.width, decodedImage.height, false)
    }
    if let previewSource {
      return (previewSource.width, previewSource.height, true)
    }
    return nil
  }

  var selectedCanvasDimensions: PixelDimensions? {
    guard let source = sourcePixelDimensions else { return nil }
    return ImageGeometry.outputDimensions(source: source, parameters: parameters)
  }

  var selectedOutputDimensions: PixelDimensions? {
    guard let canvas = selectedCanvasDimensions else { return nil }
    return ImageGeometry.framedDimensions(
      canvas,
      framePercent: exportParameters.framePercent,
      aspectRatio: exportParameters.aspectRatio)
  }

  func hasCachedPreview(for url: URL) -> Bool {
    previewCache[settingsKey(url)] != nil
  }

  func hasEdits(for url: URL) -> Bool {
    editedKeys.contains(settingsKey(url))
  }

  func setPreviewCacheLimit(_ limit: Int) {
    previewCacheLimit = max(2, limit)
    preferences.set(previewCacheLimit, forKey: "previewCacheLimit")
    trimPreviewCache()
    if let selection { scheduleLookaheadPredecode(after: selection) }
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
    if let interval = pendingFirstPreviewInterval {
      AppPerformanceSignposts.end(interval)
      pendingFirstPreviewInterval = nil
    }
    loadTask?.cancel()
    authoritativeDecodeTask?.cancel()
    cancelRenderLoop()
    loadGeneration += 1
    let gen = loadGeneration
    resetRebateState(cancelTask: true)
    resetCropState(cancelTask: true)
    resetDustState(cancelTask: true)

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      previewSource = nil
      previewRenderer = nil
      previewStatistics = .empty
      isShowingEmbeddedRawPreview = false
      isShowingProvisionalPreview = false
      isLoading = false
      sourcePixelDimensions = nil
      cancelPredecode()
      status = "Drop film scans into the window to begin."
      return
    }

    let loadCorrelationID = UUID().uuidString
    pendingFirstPreviewInterval = AppPerformanceSignposts.begin(
      .firstCorrectedPreview,
      correlationID: loadCorrelationID,
      filename: selection.lastPathComponent
    )

    isLoading = true

    sourcePixelDimensions = Self.fullResolutionDimensions(of: selection)

    cancelPredecode()
    ImportLog.loadSelectionStarted(path: selection.lastPathComponent)

    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    isShowingEmbeddedRawPreview = false
    isShowingProvisionalPreview = false
    let key = settingsKey(selection)
    let hasStoredSettings = settingsByPath[key] != nil
    parameters = settingsByPath[key] ?? ProcessingParameters()
    cropRect = parameters.cropRect
    perspectiveCrop = parameters.perspectiveCrop
    manualCrop = parameters.manualCrop
    straightenAngle = parameters.straightenAngle
    showOriginal = false

    if let cached = previewCache[key] {
      ImportLog.loadSelectionCacheHit(path: selection.lastPathComponent)
      isLoading = false
      applyCachedSession(cached, selection: selection)
      touchPreviewCache(key)
      scheduleLookaheadPredecode(after: selection)
      return
    }

    ImportLog.loadSelectionDecodeStarted(path: selection.lastPathComponent)

    let isRaw = FileDropPolicy.rawExtensions.contains(selection.pathExtension.lowercased())

    let thumbnailInterval = isRaw
      ? AppPerformanceSignposts.begin(
        .thumbnailExtraction,
        correlationID: loadCorrelationID,
        filename: selection.lastPathComponent)
      : nil
    let rawThumbnail = isRaw
      ? try? RawImageDecoder.extractThumbnail(selection, maxDimension: Self.previewMaxDimension)
      : nil
    if let thumbnailInterval { AppPerformanceSignposts.end(thumbnailInterval) }

    if let thumbnail = rawThumbnail {
      let proxy = thumbnail.image
      previewSource = proxy
      previewRenderer = StillPreviewRenderer(image: proxy)
      isShowingEmbeddedRawPreview = true
      isShowingProvisionalPreview = true
      isLoading = false
      status = "Loading \(selection.lastPathComponent)..."
      if hasStoredSettings {
        populateFilmNegativeMedians()
      }
      cacheCurrentSession(for: selection)
      scheduleRender(immediate: true)

      let replacementInterval = AppPerformanceSignposts.begin(
        .authoritativeReplacement,
        correlationID: loadCorrelationID,
        filename: selection.lastPathComponent)
      authoritativeDecodeTask = Task { [weak self] in
        defer { AppPerformanceSignposts.end(replacementInterval) }
        guard let self else { return }
        do {
          let decoded = try await self.authoritativeDecoder.decode(selection)
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
          isShowingProvisionalPreview = false
          let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
          previewSource = proxy
          previewRenderer = StillPreviewRenderer(image: proxy)
          isLoading = false
          if self.settingsByPath[key] != nil {
            populateFilmNegativeMedians()
          } else {
            applyAutomaticFilmClassification(from: proxy)
          }
          cacheCurrentSession(for: selection)
          scheduleRender(immediate: true)
          scheduleLookaheadPredecode(after: selection)
        } catch is CancellationError {
          return
        } catch {
          guard gen == self.loadGeneration else { return }
          guard self.selection == selection else { return }
          ImportLog.loadSelectionDecodeFailed(
            path: selection.lastPathComponent,
            error: error.localizedDescription
          )
          isLoading = false
          isShowingEmbeddedRawPreview = false
          isShowingProvisionalPreview = false
          status = "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)"
        }
      }
      return
    }

    let supportsStandardPreview = StandardImageDecoder.supportedExtensions.contains(
      selection.pathExtension.lowercased())
    let standardPreviewInterval = supportsStandardPreview
      ? AppPerformanceSignposts.begin(
        .standardPreviewDecode,
        correlationID: loadCorrelationID,
        filename: selection.lastPathComponent)
      : nil
    let standardProxy = supportsStandardPreview
      ? try? StandardImageDecoder.decodePreview(
        selection, maxDimension: Self.previewMaxDimension)
      : nil
    if let standardPreviewInterval { AppPerformanceSignposts.end(standardPreviewInterval) }

    if let proxy = standardProxy {
      previewSource = proxy
      previewRenderer = StillPreviewRenderer(image: proxy)
      isShowingProvisionalPreview = true
      isLoading = false
      status = "Loading \(selection.lastPathComponent)..."
      if hasStoredSettings {
        populateFilmNegativeMedians()
      }
      scheduleRender(immediate: true)

      let replacementInterval = AppPerformanceSignposts.begin(
        .authoritativeReplacement,
        correlationID: loadCorrelationID,
        filename: selection.lastPathComponent)
      authoritativeDecodeTask = Task { [weak self] in
        defer { AppPerformanceSignposts.end(replacementInterval) }
        guard let self else { return }
        do {
          let decoded = try await self.authoritativeDecoder.decode(selection)
          try Task.checkCancellation()
          guard gen == self.loadGeneration, self.selection == selection else { return }
          ImportLog.loadSelectionDecodeComplete(
            path: selection.lastPathComponent,
            width: decoded.width,
            height: decoded.height,
            channels: decoded.channels
          )
          decodedImage = decoded
          isShowingProvisionalPreview = false
          let authoritativeProxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
          previewSource = authoritativeProxy
          previewRenderer = StillPreviewRenderer(image: authoritativeProxy)
          if self.settingsByPath[key] != nil {
            populateFilmNegativeMedians()
          } else {
            applyAutomaticFilmClassification(from: authoritativeProxy)
          }
          cacheCurrentSession(for: selection)
          scheduleRender(immediate: true)
          scheduleLookaheadPredecode(after: selection)
        } catch is CancellationError {
          return
        } catch {
          guard gen == self.loadGeneration, self.selection == selection else { return }
          ImportLog.loadSelectionDecodeFailed(
            path: selection.lastPathComponent,
            error: error.localizedDescription
          )
          isShowingProvisionalPreview = false
          status = "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)"
        }
      }
      return
    }

    status = "Decoding \(selection.lastPathComponent)..."

    let decodeInterval = AppPerformanceSignposts.begin(
      .decode,
      correlationID: loadCorrelationID,
      filename: selection.lastPathComponent)
    loadTask = Task { [weak self] in
      defer { AppPerformanceSignposts.end(decodeInterval) }
      guard let self else {
        return
      }
      do {
        let decoded = try await self.authoritativeDecoder.decode(selection)
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
        isLoading = false
        isShowingEmbeddedRawPreview = false
        isShowingProvisionalPreview = false
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
        isLoading = false
        status = "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)"
      }
    }
  }

  func setFilmType(_ value: FilmType) {
    if selection?.standardizedFileURL == files.first?.standardizedFileURL,
      value != .cropOnly
    {
      sameRollFilmTypeHint = value
      reclassifyAutomaticBatchGuesses()
    }
    updateParameters { $0.filmType = value }
  }

  func setTemperature(_ value: Int) {
    updateParameters {
      $0.temperature = value
      $0.photoAdjustments.updateColorIntentFromLegacy(
        temperature: value,
        tint: $0.tint,
        saturation: $0.saturation
      )
    }
  }

  func setTint(_ value: Int) {
    updateParameters {
      $0.tint = value
      $0.photoAdjustments.updateColorIntentFromLegacy(
        temperature: $0.temperature,
        tint: value,
        saturation: $0.saturation
      )
    }
  }

  func setSaturation(_ value: Int) {
    updateParameters {
      $0.saturation = value
      $0.photoAdjustments.updateColorIntentFromLegacy(
        temperature: $0.temperature,
        tint: $0.tint,
        saturation: value
      )
    }
  }

  func setVibrance(_ value: Double) {
    updateParameters { $0.photoAdjustments.vibrance = min(max(value, -1), 1) }
  }

  func setExposureEV(_ value: Double) {
    updateParameters { $0.photoAdjustments.exposureEV = value }
  }

  func setBrightness(_ value: Double) {
    updateParameters { $0.photoAdjustments.brightness = value }
  }

  func setContrast(_ value: Double) {
    updateParameters { $0.photoAdjustments.contrast = value }
  }

  func setSemanticHighlights(_ value: Double) {
    updateParameters { $0.photoAdjustments.highlights = value }
  }

  func setSemanticShadows(_ value: Double) {
    updateParameters { $0.photoAdjustments.shadows = value }
  }

  func setCurveEnabled(_ value: Bool) {
    updateParameters {
      $0.curveEnabled = value
      if value && $0.curveControlPoints.isEmpty {
        $0.curveControlPoints = [
          CurvePoint(input: 0, output: 0),
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
    manualCrop = nil
    updateParameters {
      $0.manualCrop = nil
      $0.rotation = ($0.rotation + ($0.flip ? 1 : 3)) % 4
    }
  }

  func rotateClockwise() {
    manualCrop = nil
    updateParameters {
      $0.manualCrop = nil
      $0.rotation = ($0.rotation + ($0.flip ? 3 : 1)) % 4
    }
  }

  func toggleFlip() {
    manualCrop = nil
    updateParameters {
      $0.manualCrop = nil
      $0.flip.toggle()
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

  func applyKodachromeLikeLook() {
    guard let source = previewSource, source.channels == 3 else {
      settingsStatus = "The Kodachrome-like look needs a loaded color scan."
      return
    }
    let look = KodachromeLikeLook.parameters(for: source, preserving: parameters)
    updateParameters { $0 = look }
    settingsStatus = "Applied Kodachrome-like Auto."
  }

  func setDensityPipelineEnabled(_ value: Bool) {
    updateParameters {
      $0.densityPipelineEnabled = value
      if value, let measurement = selectedRebateMeasurement {
        $0.densityBaseDensity = measurement.baseDensity
      } else if value, let rollBase = rollProfile?.measuredBaseDensity {
        $0.densityBaseDensity = rollBase
      }
    }
  }

  func resolveAndApplyDensityPipeline(
    captureProfileID: CaptureProfileID = CaptureProfileID(rawValue: "default"),
    stockProfileID: FilmStockProfileID = FilmStockProfileID(rawValue: "generic_colour_negative")
  ) {
    do {
      let resolved = try profileStore.resolvePipeline(
        captureProfileID: captureProfileID,
        stockProfileID: stockProfileID,
        rollProfile: rollProfile,
        frameMeasurement: selectedRebateMeasurement?.baseDensity
      )
      updateParameters {
        $0.densityPipelineEnabled = true
        if let baseDensity = resolved.resolvedBaseDensity?.baseDensity {
          $0.densityBaseDensity = baseDensity
        }
        $0.densityC41Profile = resolved.stockProfile.c41Profile
        $0.densityDisplayParams = resolved.stockProfile.displayRendering
      }
      let baseMessage = rebateStatus.isEmpty ? "" : rebateStatus + " "
      rebateStatus = baseMessage
        + "Density pipeline active (stock: \(resolved.stockProfile.displayName))."
    } catch {
      rebateStatus = "Pipeline resolution failed: \(error.localizedDescription)"
    }
  }

  func applySelectedPipelineProfiles() {
    if let selectedRollProfileID {
      rollProfile = availableRollProfiles.first { $0.rollID == selectedRollProfileID }
      if let rollProfile {
        selectedCaptureProfileID = rollProfile.captureProfileID
        selectedFilmStockProfileID = rollProfile.filmStockID
      }
    } else {
      rollProfile = nil
    }
    resolveAndApplyDensityPipeline(
      captureProfileID: selectedCaptureProfileID,
      stockProfileID: selectedFilmStockProfileID
    )
    profileStatus = rebateStatus
  }

  func saveCurrentCaptureProfile(named rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      profileStatus = "Enter a profile name."
      return
    }
    do {
      let source = try profileStore.resolveCaptureProfile(id: selectedCaptureProfileID)
      let profile = CaptureProfile(
        id: CaptureProfileID(rawValue: Self.profileID(from: name)),
        cameraModel: source.cameraModel,
        lensModel: source.lensModel,
        backlightDescription: source.backlightDescription,
        estimatedColorTemperature: source.estimatedColorTemperature,
        normalizationParams: source.normalizationParams,
        preferredISO: source.preferredISO,
        notes: source.notes
      )
      try profileStore.saveCaptureProfile(profile)
      selectedCaptureProfileID = profile.id
      reloadProfiles()
      profileStatus = "Saved capture profile “\(name)”."
    } catch {
      profileStatus = "Capture profile could not be saved: \(error.localizedDescription)"
    }
  }

  func saveCurrentFilmStockProfile(named rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      profileStatus = "Enter a profile name."
      return
    }
    do {
      let profile = FilmStockProfile(
        id: FilmStockProfileID(rawValue: Self.profileID(from: name)),
        displayName: name,
        filmType: parameters.filmType,
        c41Profile: parameters.densityC41Profile,
        displayRendering: parameters.densityDisplayParams,
        notes: "Saved from Film Scan Converter"
      )
      try profileStore.saveFilmStockProfile(profile)
      selectedFilmStockProfileID = profile.id
      reloadProfiles()
      profileStatus = "Saved film-stock profile “\(name)”."
    } catch {
      profileStatus = "Film-stock profile could not be saved: \(error.localizedDescription)"
    }
  }

  private func reloadProfiles() {
    let builtInCapture = profileStore.builtInCaptureProfiles()
    let storedCapture = profileStore.listCaptureProfiles().compactMap {
      try? profileStore.loadCaptureProfile(id: $0)
    }
    availableCaptureProfiles = Self.uniqueCaptureProfiles(builtInCapture + storedCapture)

    let builtInStock = profileStore.builtInFilmStockProfiles()
    let storedStock = profileStore.listFilmStockProfiles().compactMap {
      try? profileStore.loadFilmStockProfile(id: $0)
    }
    availableFilmStockProfiles = Self.uniqueFilmStockProfiles(builtInStock + storedStock)
    do {
      availableRollProfiles = try profileStore.loadRollProfiles().sorted {
        $0.rollID.localizedCaseInsensitiveCompare($1.rollID) == .orderedAscending
      }
    } catch {
      availableRollProfiles = []
      profileStatus = "Saved roll profiles could not be loaded."
    }
  }

  nonisolated private static func profileID(from name: String) -> String {
    let normalized = name.lowercased().map { character -> Character in
      character.isLetter || character.isNumber ? character : "_"
    }
    let collapsed = String(normalized).split(separator: "_").joined(separator: "_")
    return collapsed.isEmpty ? "profile" : collapsed
  }

  nonisolated private static func uniqueCaptureProfiles(
    _ profiles: [CaptureProfile]
  ) -> [CaptureProfile] {
    Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, stored in stored })
      .values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  nonisolated private static func uniqueFilmStockProfiles(
    _ profiles: [FilmStockProfile]
  ) -> [FilmStockProfile] {
    Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, stored in stored })
      .values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  func resetCorrections() {
    resetDustState(cancelTask: true)
    parameters = ProcessingParameters()
    straightenAngle = 0
    if let selection { editedKeys.insert(settingsKey(selection)) }
    resetCropState(cancelTask: true)
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender(immediate: true)
    }
  }

  var canPasteCorrectionSettings: Bool {
    (try? settingsClipboard.read()) != nil
  }

  func copyCorrectionSettings() {
    do {
      try settingsClipboard.write(CorrectionSettings(capturing: parameters))
      settingsStatus = "Correction settings copied."
    } catch {
      settingsStatus = "Correction settings could not be copied."
    }
  }

  func pasteCorrectionSettings() {
    do {
      guard let settings = try settingsClipboard.read() else {
        settingsStatus = "The clipboard does not contain correction settings."
        return
      }
      applyCorrectionSettings(settings)
      settingsStatus = "Correction settings pasted."
    } catch {
      settingsStatus = "Clipboard correction settings are not valid."
    }
  }

  func saveCorrectionPreset(named name: String) {
    guard let presetStore else {
      settingsStatus = "Preset storage is unavailable."
      return
    }
    do {
      namedCorrectionPresets = try presetStore.savePreset(
        named: name,
        settings: CorrectionSettings(capturing: parameters)
      )
      settingsStatus = "Preset saved."
    } catch NamedCorrectionPresetStore.StoreError.emptyName {
      settingsStatus = "Enter a preset name."
    } catch {
      settingsStatus = "Preset could not be saved."
    }
  }

  func applyCorrectionPreset(_ preset: NamedCorrectionPreset) {
    applyCorrectionSettings(preset.settings)
    settingsStatus = "Applied preset “\(preset.name)”."
  }

  func deleteCorrectionPreset(_ preset: NamedCorrectionPreset) {
    guard let presetStore else {
      settingsStatus = "Preset storage is unavailable."
      return
    }
    do {
      namedCorrectionPresets = try presetStore.deletePreset(id: preset.id)
      settingsStatus = "Deleted preset “\(preset.name)”."
    } catch {
      settingsStatus = "Preset could not be deleted."
    }
  }

  private func applyCorrectionSettings(_ settings: CorrectionSettings) {
    resetDustState(cancelTask: true)
    if let selection {
      automaticallyClassifiedKeys.remove(settingsKey(selection))
      editedKeys.insert(settingsKey(selection))
    }
    parameters = settings.applying(to: parameters)
    populateFilmNegativeMedians()
    cropRect = parameters.cropRect
    perspectiveCrop = parameters.perspectiveCrop
    manualCrop = parameters.manualCrop
    straightenAngle = parameters.straightenAngle
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender(immediate: true)
    }
  }

  func applyCurrentSettingsToAllOpenFiles() {
    guard !files.isEmpty else { return }
    let settings = CorrectionSettings(capturing: parameters)
    for url in files {
      let key = settingsKey(url)
      let destination = settingsByPath[key] ?? ProcessingParameters()
      var applied = settings.applying(to: destination)
      applied.filmNegativeParams.measuredMedians = nil
      settingsByPath[key] = applied
      editedKeys.insert(key)
    }
    persistSettings()
    settingsStatus = "Applied settings to all \(files.count) open files."
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
    setExportDestinationDirectory(url)
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

  func addSelectedToExportQueue() {
    guard isExporting, let selection,
      let activeExportParameters,
      let destinationDirectory = activeExportParameters.destinationDirectory
    else { return }
    let key = settingsKey(selection)
    guard !activeExportSeen.contains(key) else {
      status = "\(selection.lastPathComponent) is already in this export run."
      return
    }

    let stem = selection.deletingPathExtension().lastPathComponent
    let ext = activeExportParameters.format.fileExtension

    var existingNames: Set<String>
    if let dirContents = try? FileManager.default.contentsOfDirectory(
      at: destinationDirectory, includingPropertiesForKeys: nil
    ).map({ $0.lastPathComponent.lowercased() }) {
      existingNames = Set(dirContents)
    } else {
      existingNames = []
    }
    for dest in activeExportDestinations {
      existingNames.insert(dest.lastPathComponent.lowercased())
    }

    var filename = "\(stem).\(ext)"
    var suffix = 1
    while existingNames.contains(filename.lowercased()) {
      suffix += 1
      filename = "\(stem)-\(suffix).\(ext)"
    }
    let destination = destinationDirectory.appendingPathComponent(filename)

    activeExportSeen.insert(key)
    activeExportQueue.append(selection)
    activeExportDestinations.append(destination)
    let correlationID = UUID().uuidString
    activeExportCorrelationIDs.append(correlationID)
    activeExportQueueWaitIntervals.append(
      AppPerformanceSignposts.begin(
        .queueWait,
        correlationID: correlationID,
        filename: selection.lastPathComponent))
    exportQueueCount = max(0, activeExportQueue.count - exportProgressCurrent - 1)
    exportProgressTotal += 1
    status = "Added \(selection.lastPathComponent) to the export queue."
  }

  func cancelExport() {
    guard isExporting else { return }
    exportWasCancelled = true
    status = "Cancelling export after the active stage finishes..."
    exportTask?.cancel()
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
    let flatField = preparedFlatField(for: source)
    isRebateDetectionRunning = true
    rebateStatus = "Searching for unexposed film edges..."
    rebateCandidates = []
    selectedRebateMeasurement = nil
    selectedRebateRegion = nil

    rebateTask = Task { [weak self] in
      guard let self else { return }
      let result: [AutomaticRebateCandidate]
      if Task.isCancelled { return }
      result = await Task.detached(priority: .userInitiated) {
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
        rebateStatus = "No clear unexposed film edge detected."
      } else {
        rebateStatus =
          "Found \(result.count) possible film edge\(result.count == 1 ? "" : "s")."
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
    let flatField = preparedFlatField(for: source)
    rebateStatus = "Measuring base density..."
    rebateTask = Task { [weak self] in
      guard let self else { return }
      let result: Result<FilmBaseMeasurement, Error>
      result = await Task.detached(priority: .userInitiated) {
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
        updateParameters {
          $0.densityPipelineEnabled = true
          $0.densityBaseDensity = measurement.baseDensity
        }
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

  func measureRebateRegion(
    normalizedX: Double,
    normalizedY: Double,
    normalizedWidth: Double,
    normalizedHeight: Double
  ) {
    guard let source = previewSource else { return }
    let sourceRect = Self.sourceNormalizedRect(
      fromDisplayedRect: CGRect(
        x: normalizedX, y: normalizedY,
        width: normalizedWidth, height: normalizedHeight),
      rotation: parameters.rotation,
      flippedHorizontally: parameters.flip
    )
    let x = min(max(sourceRect.minX, 0), 1)
    let y = min(max(sourceRect.minY, 0), 1)
    let width = min(max(sourceRect.width, 0), 1 - x)
    let height = min(max(sourceRect.height, 0), 1 - y)
    let region = ImageRegion(
      x: min(source.width - 1, Int((x * Double(source.width)).rounded(.down))),
      y: min(source.height - 1, Int((y * Double(source.height)).rounded(.down))),
      width: max(1, Int((width * Double(source.width)).rounded())),
      height: max(1, Int((height * Double(source.height)).rounded()))
    )
    measureRebateRegion(region)
  }

  nonisolated static func sourceNormalizedRect(
    fromDisplayedRect rect: CGRect,
    rotation: Int,
    flippedHorizontally: Bool
  ) -> CGRect {
    let normalizedTurns = ((rotation % 4) + 4) % 4
    let corners = [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.maxX, y: rect.maxY),
    ].map { displayed -> CGPoint in
      let x = flippedHorizontally ? 1 - displayed.x : displayed.x
      let y = displayed.y
      switch normalizedTurns {
      case 1: return CGPoint(x: y, y: 1 - x)
      case 2: return CGPoint(x: 1 - x, y: 1 - y)
      case 3: return CGPoint(x: 1 - y, y: x)
      default: return CGPoint(x: x, y: y)
      }
    }
    let minX = corners.map(\.x).min() ?? 0
    let maxX = corners.map(\.x).max() ?? 0
    let minY = corners.map(\.y).min() ?? 0
    let maxY = corners.map(\.y).max() ?? 0
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
    updateParameters {
      $0.densityPipelineEnabled = true
      $0.densityBaseDensity = candidate.measurement.baseDensity
    }
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
      selectedRollProfileID = profile.rollID
      selectedCaptureProfileID = profile.captureProfileID
      selectedFilmStockProfileID = profile.filmStockID
      reloadProfiles()
      rebateStatus = "Roll profile saved as \(rollID)."
      resolveAndApplyDensityPipeline(
        captureProfileID: captureID,
        stockProfileID: stockID
      )
    } catch {
      rebateStatus = "Unable to save roll profile: \(error.localizedDescription)"
    }
  }

  func clearRebateMeasurement() {
    resetRebateState(cancelTask: true)
    updateParameters {
      $0.densityPipelineEnabled = false
      $0.densityBaseDensity = nil
    }
  }

  func loadFlatField() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = []
    panel.message = "Select a flat-field calibration image."
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    do {
      let decoded = try Self.decodeImage(url)
      setFlatField(decoded, url: url)
    } catch {
      rebateStatus = "Failed to load flat-field: \(error.localizedDescription)"
    }
  }

  func clearFlatField() {
    setFlatField(nil)
  }

  func setFlatField(_ image: UInt16Image?, url: URL? = nil) {
    guard let image else {
      flatFieldImage = nil
      flatFieldURL = nil
      rebateStatus = "Flat-field cleared."
      scheduleRender(immediate: true)
      return
    }
    guard image.channels == 3 else {
      rebateStatus = "Flat field must be a three-channel image."
      return
    }
    if let decodedImage {
      let sourceAspect = Double(decodedImage.width) / Double(decodedImage.height)
      let fieldAspect = Double(image.width) / Double(image.height)
      guard abs(sourceAspect - fieldAspect) / sourceAspect <= 0.01 else {
        rebateStatus = "Flat field aspect ratio must match the selected scan."
        return
      }
    }
    flatFieldImage = image
    flatFieldURL = url
    rebateStatus = "Flat-field loaded\(url.map { ": \($0.lastPathComponent)" } ?? ".")"
    scheduleRender(immediate: true)
  }

  func detectCrop() {
    guard let source = previewSource, source.channels == 3 else {
      cropStatus = "Load an image with 3 channels first."
      return
    }
    cropDetectionTask?.cancel()
    cropDetectionTask = nil
    cropThresholdPreview = nil
    isCropDetectionRunning = true
    cropStatus = "Finding film frame..."

    let proxy = source
    let dark = parameters.darkThreshold
    let light = parameters.lightThreshold
    let maxDim = 2000
    let selectedURL = selection

    cropDetectionTask = Task { [weak self] in
      guard let self else { return }

      let result: (threshold: UInt16Image, rect: RotatedRect, contourPoints: [SIMD2<Double>])? =
        await Task.detached(priority: .userInitiated) {
          let thresh = proxy.getThreshold(darkThreshold: dark, lightThreshold: light)
          return ContourDetection.findOptimalCrop(threshold: thresh, maxDimension: maxDim)
        }.value

      guard !Task.isCancelled else { return }
      guard self.selection == selectedURL else { return }

      isCropDetectionRunning = false
      guard let result else {
        cropStatus = "No crop frame detected."
        return
      }
      setCropRect(result.rect)
      cropThresholdPreview = result.threshold
      cropStatus = String(
        format: "Crop: %.1f°  w:%.3f  h:%.3f  at (%.3f, %.3f)",
        result.rect.angle,
        result.rect.width,
        result.rect.height,
        result.rect.centerX,
        result.rect.centerY
      )
    }
  }

  func detectDustMask() {
    guard let source = previewSource, source.channels == 3 else {
      dustStatus = "Load a three-channel scan first."
      return
    }
    dustDetectionTask?.cancel()
    isDustDetectionRunning = true
    dustStatus = "Detecting dust…"
    let selectedURL = selection
    let displayParameters = parameters
    dustDetectionTask = Task { [weak self] in
      guard let self else { return }
      let mask = await Task.detached(priority: .userInitiated) {
        DustDetection.findMask(in: source)
      }.value
      guard !Task.isCancelled, self.selection == selectedURL else { return }
      let croppedMask = displayParameters.perspectiveCrop.flatMap {
        PerspectiveTransform.crop(
          mask,
          perspectiveCrop: $0,
          borderPercent: displayParameters.borderCrop
        )
      } ?? displayParameters.cropRect.flatMap {
        PerspectiveTransform.crop(
          mask,
          normalizedRect: $0,
          coordinateSpace: displayParameters.cropRectCoordinateSpace,
          borderPercent: displayParameters.borderCrop
        )
      } ?? mask
      let orientedMask = croppedMask.rotated(
        quarterTurns: displayParameters.rotation,
        flipHorizontally: displayParameters.flip
      )
      let straightenedMask = PerspectiveTransform.rotate(
        orientedMask, clockwiseDegrees: -displayParameters.straightenAngle)
      let finalMask = displayParameters.manualCrop.flatMap {
        PerspectiveTransform.crop(straightenedMask, canvasRect: $0)
      } ?? straightenedMask
      let displayMask = UInt16Image(
        width: finalMask.width,
        height: finalMask.height,
        channels: mask.channels,
        pixels: finalMask.pixels.map { $0 == 0 ? 0 : UInt16.max }
      )
      guard let cgImage = displayMask.makePreviewCGImage() else {
        self.isDustDetectionRunning = false
        self.dustStatus = "Dust mask could not be displayed."
        return
      }
      self.dustMaskImage = NSImage(cgImage: cgImage, size: .zero)
      self.isDustDetectionRunning = false
      let detected = mask.pixels.reduce(into: 0) { count, value in
        if value != 0 { count += 1 }
      }
      self.dustStatus = detected == 0
        ? "No dust candidates found."
        : "Showing \(detected) dust-mask pixels."
    }
  }

  func clearDustMask() {
    resetDustState(cancelTask: true)
  }

  func clearCrop() {
    resetCropState(cancelTask: true)
    parameters.cropRect = nil
    parameters.perspectiveCrop = nil
    parameters.manualCrop = nil
    saveParameters()
    scheduleRender(immediate: true)
  }

  func setCropRect(_ rect: RotatedRect?) {
    if let rect {
      applyCrop(rect, render: true)
    } else {
      clearCrop()
    }
  }

  func beginPerspectiveCrop() {
    guard perspectiveCrop == nil else { return }
    setPerspectiveCrop(PerspectiveCrop(
      topLeft: .init(x: 0.06, y: 0.06),
      topRight: .init(x: 0.94, y: 0.06),
      bottomRight: .init(x: 0.94, y: 0.94),
      bottomLeft: .init(x: 0.06, y: 0.94)
    ))
  }

  func setPerspectiveCrop(_ crop: PerspectiveCrop?) {
    guard let crop else {
      clearCrop()
      return
    }
    guard crop.isValid else {
      cropStatus = "Keep the four corners in clockwise order."
      return
    }
    resetDustState(cancelTask: true)
    cropRect = nil
    perspectiveCrop = crop
    manualCrop = nil
    parameters.cropRect = nil
    parameters.perspectiveCrop = crop
    parameters.manualCrop = nil
    cropStatus = "Perspective crop is active. Drag corners to align the grid."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
  }

  func setManualCrop(_ crop: NormalizedCropRect?) {
    guard let crop else {
      clearManualCrop()
      return
    }
    guard crop.isValid else {
      cropStatus = "Drag a crop box inside the image."
      return
    }
    resetDustState(cancelTask: true)
    manualCrop = crop
    parameters.manualCrop = crop
    cropStatus = "Manual canvas crop is active."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
  }

  func cropCurrentCanvas(to crop: NormalizedCropRect) {
    guard let existing = manualCrop else {
      setManualCrop(crop)
      return
    }
    setManualCrop(NormalizedCropRect(
      x: existing.x + crop.x * existing.width,
      y: existing.y + crop.y * existing.height,
      width: crop.width * existing.width,
      height: crop.height * existing.height))
  }

  func clearManualCrop() {
    guard manualCrop != nil || parameters.manualCrop != nil else { return }
    resetDustState(cancelTask: true)
    manualCrop = nil
    parameters.manualCrop = nil
    cropStatus = ""
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
  }

  func setStraightenAngle(_ angle: Double) {
    guard angle.isFinite else { return }
    let clamped = min(max(angle, -45), 45)
    guard abs(parameters.straightenAngle - clamped) > 0.000_001 else { return }
    resetDustState(cancelTask: true)
    manualCrop = nil
    parameters.manualCrop = nil
    parameters.straightenAngle = clamped
    straightenAngle = clamped
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
  }

  func clearStraightening() {
    setStraightenAngle(0)
  }

  func straighten(usingGuideDeviation deviation: Double) {
    guard deviation.isFinite else { return }
    setStraightenAngle(straightenAngle + deviation)
  }

  func setDarkThreshold(_ value: Int) {
    updateParameters { $0.darkThreshold = value }
  }

  func setLightThreshold(_ value: Int) {
    updateParameters { $0.lightThreshold = value }
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

  private func resetCropState(cancelTask: Bool) {
    if cancelTask {
      cropDetectionTask?.cancel()
      cropDetectionTask = nil
    }
    cropRect = nil
    perspectiveCrop = nil
    manualCrop = nil
    cropThresholdPreview = nil
    isCropDetectionRunning = false
    cropStatus = ""
  }

  private func resetDustState(cancelTask: Bool) {
    if cancelTask {
      dustDetectionTask?.cancel()
      dustDetectionTask = nil
    }
    dustMaskImage = nil
    isDustDetectionRunning = false
    dustStatus = ""
  }

  private func applyCrop(_ rect: RotatedRect, render: Bool) {
    resetDustState(cancelTask: true)
    cropRect = rect
    perspectiveCrop = nil
    manualCrop = nil
    parameters.cropRect = rect
    parameters.cropRectCoordinateSpace = .imageAxes
    parameters.perspectiveCrop = nil
    parameters.manualCrop = nil
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    if render {
      scheduleRender(immediate: true)
    }
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

    // Export has priority over speculative lookahead work. The decoder may
    // finish its current synchronous call, but cancellation prevents it from
    // advancing through the rest of the lookahead queue.
    cancelPredecode()

    var params = exportParameters
    params.destinationDirectory = destDir
    let exportParams = params
    activeExportParameters = exportParams
    activeExportQueue = urls
    activeExportSeen = Set(urls.map(settingsKey))
    exportQueueCount = max(0, urls.count - 1)
    do {
      activeExportDestinations = try reserveDestinationURLs(
        for: urls, destinationDirectory: destDir, format: exportParams.format)
    } catch {
      status = "Unable to inspect export destination: \(error.localizedDescription)"
      activeExportQueue = []
      activeExportCorrelationIDs = []
      activeExportQueueWaitIntervals = []
      activeExportSeen = []
      activeExportParameters = nil
      exportQueueCount = 0
      return
    }
    activeExportCorrelationIDs = urls.map { _ in UUID().uuidString }
    activeExportQueueWaitIntervals = zip(urls, activeExportCorrelationIDs).map { url, correlationID in
      AppPerformanceSignposts.begin(
        .queueWait,
        correlationID: correlationID,
        filename: url.lastPathComponent)
    }
    isExporting = true
    exportWasCancelled = false
    activeExportFilename = urls.first?.lastPathComponent
    exportProgressCurrent = 0
    exportProgressTotal = urls.count
    exportErrors = []
    status = "Exporting..."

    exportTask = Task { [weak self] in
      guard let self else { return }

      let manager = ExportManager()
      var results: [ExportManager.ExportResult] = []
      results.reserveCapacity(urls.count)

      var index = 0
      while index < self.activeExportQueue.count {
        if Task.isCancelled {
          for remainingIndex in index..<self.activeExportQueue.count {
            results.append(
              ExportManager.ExportResult(
                sourceURL: self.activeExportQueue[remainingIndex],
                destinationURL: self.activeExportDestinations[remainingIndex],
                error: ExportManager.ExportManagerError.cancelled
              ))
          }
          index = self.activeExportQueue.count
          break
        }

        let firstURL = self.activeExportQueue[index]
        await MainActor.run {
          self.activeExportFilename = firstURL.lastPathComponent
          self.exportQueueCount = max(0, self.activeExportQueue.count - index - 1)
        }
        let nextIsFullResolutionRAW = index + 1 < self.activeExportQueue.count
          && Self.requiresFullResolutionExportDecode(self.activeExportQueue[index + 1])
        let batchSize = Self.requiresFullResolutionExportDecode(firstURL) || nextIsFullResolutionRAW
          ? 1 : 2
        let endIndex = min(index + batchSize, self.activeExportQueue.count)
        var requests: [ExportManager.ExportRequest] = []
        for requestIndex in index..<endIndex {
          let url = self.activeExportQueue[requestIndex]
          let destinationURL = self.activeExportDestinations[requestIndex]
          let correlationID = self.activeExportCorrelationIDs[requestIndex]
          AppPerformanceSignposts.end(self.activeExportQueueWaitIntervals[requestIndex])
          do {
            requests.append(
              try await self.makeExportRequest(
                for: url,
                exportParams: exportParams,
                destinationURL: destinationURL,
                correlationID: correlationID
              ))
          } catch {
            results.append(
              ExportManager.ExportResult(
                sourceURL: url,
                destinationURL: destinationURL,
                error: error
              ))
          }
        }
        if !requests.isEmpty {
          let batchResults = await manager.exportBatch(
            requests: requests,
            maxConcurrent: min(2, requests.count)
          )
          results.append(contentsOf: batchResults)
          let cleanupIntervals = requests.map {
            AppPerformanceSignposts.begin(
              .cleanup,
              correlationID: $0.correlationID,
              filename: $0.sourceURL.lastPathComponent)
          }
          requests.removeAll(keepingCapacity: false)
          cleanupIntervals.forEach(AppPerformanceSignposts.end)
        }

        index = endIndex
        await MainActor.run {
          self.exportProgressCurrent = index
          self.exportProgressTotal = self.activeExportQueue.count
          self.exportQueueCount = max(0, self.activeExportQueue.count - index - 1)
        }
      }

      await MainActor.run {
        let wasCancelled = self.exportWasCancelled || Task.isCancelled
        for interval in self.activeExportQueueWaitIntervals.dropFirst(
          self.exportProgressCurrent)
        {
          AppPerformanceSignposts.end(interval)
        }
        self.isExporting = false
        self.activeExportFilename = nil
        self.activeExportQueue = []
        self.activeExportDestinations = []
        self.activeExportCorrelationIDs = []
        self.activeExportQueueWaitIntervals = []
        self.activeExportSeen = []
        self.activeExportParameters = nil
        self.exportTask = nil
        self.exportQueueCount = 0
        let failures = results.filter { !$0.isSuccess }
        if wasCancelled {
          self.exportErrors = []
          self.status = "Export cancelled after \(self.exportProgressCurrent) of \(self.exportProgressTotal) images."
        } else if failures.isEmpty {
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
    parameters.filmNegativeParams.measuredMedians = medians
  }

  private func applyAutomaticFilmClassification(from image: UInt16Image) {
    parameters = Self.automaticallyClassifiedParameters(
      base: parameters,
      image: image,
      weakPrior: sameRollFilmTypeHint
    )
    if let selection {
      automaticallyClassifiedKeys.insert(settingsKey(selection))
    }
    saveParameters()
  }

  private func makeExportRequest(
    for url: URL,
    exportParams: ExportParameters,
    destinationURL: URL,
    correlationID: String
  ) async throws -> ExportManager.ExportRequest {
    let key = settingsKey(url)
    let decodeInterval = AppPerformanceSignposts.begin(
      .decode, correlationID: correlationID, filename: url.lastPathComponent)
    let decoded: UInt16Image
    do {
      decoded = try await decodedImageForExport(url)
      AppPerformanceSignposts.end(decodeInterval)
    } catch {
      AppPerformanceSignposts.end(decodeInterval)
      throw error
    }
    try Task.checkCancellation()
    let settingsInterval = AppPerformanceSignposts.begin(
      .settingsAndClassification,
      correlationID: correlationID,
      filename: url.lastPathComponent)
    let fileParams: ProcessingParameters
    if let stored = settingsByPath[key] {
      fileParams = stored
    } else {
      let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
      let automatic = Self.automaticallyClassifiedParameters(
        base: ProcessingParameters(),
        image: proxy,
        weakPrior: sameRollFilmTypeHint
      )
      settingsByPath[key] = automatic
      automaticallyClassifiedKeys.insert(key)
      fileParams = automatic
    }
    AppPerformanceSignposts.end(settingsInterval)

    let flatFieldInterval = AppPerformanceSignposts.begin(
      .flatFieldLookup, correlationID: correlationID, filename: url.lastPathComponent)
    let ff = compatibleFlatField(for: decoded)
    AppPerformanceSignposts.end(flatFieldInterval)
    let correctionInterval = AppPerformanceSignposts.begin(
      .correction, correlationID: correlationID, filename: url.lastPathComponent)
    var processed = await Task.detached(priority: .userInitiated) {
      FilmProcessing.correctedPreview(
        image: decoded,
        parameters: fileParams,
        flatField: ff
      )
    }.value
    AppPerformanceSignposts.end(correctionInterval)
    try Task.checkCancellation()

    let geometryInterval = AppPerformanceSignposts.begin(
      .geometryAndFrame, correlationID: correlationID, filename: url.lastPathComponent)
    processed = await Task.detached(priority: .userInitiated) {
      var output = processed
      if exportParams.framePercent > 0 || exportParams.aspectRatio != nil {
        output = output.addingFrame(
          percent: exportParams.framePercent,
          aspectRatio: exportParams.aspectRatio
        )
      }
      return output
    }.value
    AppPerformanceSignposts.end(geometryInterval)
    try Task.checkCancellation()

    return ExportManager.ExportRequest(
      sourceURL: url,
      destinationURL: destinationURL,
      image: processed,
      parameters: exportParams,
      correlationID: correlationID
    )
  }

  private func decodedImageForExport(_ url: URL) async throws -> UInt16Image {
    if Self.requiresFullResolutionExportDecode(url) {
      return try await Task.detached(priority: .userInitiated) {
        try RawImageDecoder.decode(
          url,
          fullResolution: true,
          profile: .rawTherapeeCameraScan
        ).image
      }.value
    }
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

  nonisolated static func requiresFullResolutionExportDecode(_ url: URL) -> Bool {
    FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
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
    image: UInt16Image,
    weakPrior: FilmType? = nil
  ) -> ProcessingParameters {
    let classification = FilmNegativeProcessing.classifyFilmScan(
      image: image,
      weakPrior: weakPrior
    )
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
    resetDustState(cancelTask: true)
    if let selection {
      automaticallyClassifiedKeys.remove(settingsKey(selection))
      editedKeys.insert(settingsKey(selection))
    }
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
    persistSettings()
    EditLog.parametersSaved(path: selection.lastPathComponent, parameters: parameters)
  }

  private func persistSettings() {
    do {
      try settingsStore?.save(.init(settingsByPath: settingsByPath, editedPaths: editedKeys))
    } catch {
      status = "Corrections changed, but could not be saved for the next launch."
    }
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
    guard previewCacheLimit > 1, !isExporting else {
      return
    }
    guard let currentIndex = files.firstIndex(of: selection) else {
      return
    }

    let candidates = Array(files.dropFirst(currentIndex + 1).prefix(previewCacheLimit - 1))
      .filter { previewCache[settingsKey($0)] == nil }
    guard !candidates.isEmpty else {
      return
    }

    predecodeTask?.cancel()
    predecodeTask = Task { [weak self] in
      guard let self else { return }
      for target in candidates {
        let targetKey = self.settingsKey(target)
        do {
          ImportLog.loadSelectionDecodeStarted(path: "predecode \(target.lastPathComponent)")
          let decoded = try await self.authoritativeDecoder.decode(target)
          let proxy = decoded.resizedToFit(maxDimension: Self.previewMaxDimension)
          guard let renderer = StillPreviewRenderer(image: proxy) else { continue }
          let session = CachedPreviewSession(
            decodedImage: decoded, previewSource: proxy, previewRenderer: renderer)
          try Task.checkCancellation()
          guard self.selection == selection, self.previewCache[targetKey] == nil else { continue }
          if self.settingsByPath[targetKey] == nil {
            self.settingsByPath[targetKey] = Self.automaticallyClassifiedParameters(
              base: ProcessingParameters(), image: session.previewSource,
              weakPrior: self.sameRollFilmTypeHint)
            self.automaticallyClassifiedKeys.insert(targetKey)
          }
          self.cacheSession(session, for: target)
        } catch is CancellationError {
          return
        } catch {
          ImportLog.loadSelectionDecodeFailed(
            path: "predecode \(target.lastPathComponent)", error: error.localizedDescription)
        }
      }
    }
  }

  private func cancelPredecode() {
    predecodeTask?.cancel()
    predecodeTask = nil
  }

  private func reclassifyAutomaticBatchGuesses() {
    guard let sameRollFilmTypeHint else { return }
    for url in files.dropFirst() {
      let key = settingsKey(url)
      guard automaticallyClassifiedKeys.contains(key),
        let session = previewCache[key],
        let existing = settingsByPath[key]
      else {
        continue
      }
      settingsByPath[key] = Self.automaticallyClassifiedParameters(
        base: existing,
        image: session.previewSource,
        weakPrior: sameRollFilmTypeHint
      )
    }
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
    trimPreviewCache()
  }

  private func trimPreviewCache() {
    while previewCacheOrder.count > previewCacheLimit {
      let evicted = previewCacheOrder.removeFirst()
      previewCache.removeValue(forKey: evicted)
    }
  }

  private func touchPreviewCache(_ key: String) {
    previewCacheOrder.removeAll { $0 == key }
    previewCacheOrder.append(key)
  }

  private func scheduleRender(immediate: Bool = false) {
    guard let selection, let previewSource else {
      return
    }

    let previousHadPending = pendingRender != nil
    let ff = preparedFlatField(for: previewSource)
    pendingRender = PreviewRenderRequest(
      selection: selection,
      source: previewSource,
      renderer: previewRenderer,
      parameters: parameters,
      showOriginal: showOriginal,
      submitTime: Date(),
      flatField: ff
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
    guard renderTask == nil else {
      return
    }

    renderLoopGeneration += 1
    let generation = renderLoopGeneration
    let skipCoalesce = immediate
    renderTask = Task { [weak self] in
      guard let self else { return }
      if !skipCoalesce {
        let now = ContinuousClock.now
        let elapsed = self.lastRenderEnd.duration(to: now)
        if elapsed < Self.renderCoalesceInterval {
          try? await Task.sleep(for: Self.renderCoalesceInterval - elapsed)
        }
      }
      guard generation == self.renderLoopGeneration, !Task.isCancelled else { return }
      await self.processRenderQueue(generation: generation)
    }
  }

  private func preparedFlatField(for image: UInt16Image) -> UInt16Image {
    guard let flatField = compatibleFlatField(for: image) else {
      return Self.unityFlatField(for: image)
    }
    return flatField.resized(width: image.width, height: image.height)
  }

  nonisolated private static func previewStatistics(
    for image: UInt16Image
  ) -> RenderReadyImageStatistics? {
    let pixelCount = image.width * image.height
    switch image.channels {
    case 1:
      var pixels = [Double](repeating: 0, count: pixelCount * 3)
      for pixelIndex in 0..<pixelCount {
        let value = Double(image.pixels[pixelIndex]) / 65_535
        let destination = pixelIndex * 3
        pixels[destination] = value
        pixels[destination + 1] = value
        pixels[destination + 2] = value
      }
      return RenderReadyLinearImage(
        width: image.width,
        height: image.height,
        pixels: pixels
      ).statistics()
    case 3:
      return RenderReadyLinearImage(
        width: image.width,
        height: image.height,
        pixels: image.pixels.map { Double($0) / 65_535 }
      ).statistics()
    default:
      return nil
    }
  }

  private func compatibleFlatField(for image: UInt16Image) -> UInt16Image? {
    guard let flatFieldImage, flatFieldImage.channels == image.channels else { return nil }
    let imageAspect = Double(image.width) / Double(image.height)
    let fieldAspect = Double(flatFieldImage.width) / Double(flatFieldImage.height)
    guard abs(imageAspect - fieldAspect) / imageAspect <= 0.01 else { return nil }
    return flatFieldImage
  }

  private func processRenderQueue(generation: Int) async {
    while !Task.isCancelled, let request = pendingRender {
      pendingRender = nil
      let signpostID = OSSignpostID(log: Self.signpostLog)
      let renderStart = Date()
      let submitTime = request.submitTime
      let result: RenderedPreview? = await Task.detached(priority: .userInitiated) { () -> RenderedPreview? in
        let useGPU = request.renderer != nil
          && !request.parameters.densityPipelineEnabled
          && request.parameters.cropRect == nil
          && request.parameters.perspectiveCrop == nil
          && abs(request.parameters.straightenAngle) < 0.000_001
        if useGPU,
          let rendered = request.renderer?.render(
            parameters: request.parameters,
            showOriginal: request.showOriginal
          )
        {
          return RenderedPreview(
            cgImage: rendered,
            rendererName: "GPU",
            statistics: StillPreviewRenderer.statistics(for: rendered) ?? .empty
          )
        }
        let rendered =
          request.showOriginal
          ? request.source.rotated(
            quarterTurns: request.parameters.rotation,
            flipHorizontally: request.parameters.flip
          )
          : FilmProcessing.correctedPreview(
            image: request.source,
            parameters: request.parameters,
            flatField: request.flatField
          )
        guard let preview = rendered.makePreviewCGImage() else {
          return nil
        }
        guard let statistics = Self.previewStatistics(for: rendered) else {
          return nil
        }
        return RenderedPreview(
          cgImage: preview,
          rendererName: "CPU",
          statistics: statistics
        )
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
      previewStatistics = result.statistics
      if let interval = pendingFirstPreviewInterval,
        interval.filename == request.selection.lastPathComponent
      {
        AppPerformanceSignposts.end(interval)
        pendingFirstPreviewInterval = nil
      }
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

  nonisolated fileprivate static func decodeImage(_ url: URL) throws -> UInt16Image {
    if StandardImageDecoder.supportedExtensions.contains(url.pathExtension.lowercased()) {
      return try StandardImageDecoder.decode(url)
    }
    return try RawImageDecoder.decode(url, profile: .rawTherapeeCameraScan).image
  }

  nonisolated private static func fullResolutionDimensions(of url: URL) -> PixelDimensions? {
    if StandardImageDecoder.supportedExtensions.contains(url.pathExtension.lowercased()) {
      return try? StandardImageDecoder.fullResolutionDimensions(url)
    }
    if FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) {
      return try? RawImageDecoder.fullResolutionDimensions(url)
    }
    return nil
  }
}

actor AuthoritativeImageDecoder {
  typealias DecodeOperation = @Sendable (URL) throws -> UInt16Image

  private let operation: DecodeOperation

  init(operation: @escaping DecodeOperation = AppModel.decodeImage) {
    self.operation = operation
  }

  func decode(_ url: URL) throws -> UInt16Image {
    try Task.checkCancellation()
    let decoded = try operation(url)
    try Task.checkCancellation()
    return decoded
  }
}

private struct PreviewRenderRequest: Sendable {
  let selection: URL
  let source: UInt16Image
  let renderer: StillPreviewRenderer?
  let parameters: ProcessingParameters
  let showOriginal: Bool
  let submitTime: Date
  let flatField: UInt16Image?
}

private struct CachedPreviewSession: Sendable {
  let decodedImage: UInt16Image
  let previewSource: UInt16Image
  let previewRenderer: StillPreviewRenderer
}

private struct RenderedPreview: Sendable {
  let cgImage: CGImage
  let rendererName: String
  let statistics: RenderReadyImageStatistics
}
