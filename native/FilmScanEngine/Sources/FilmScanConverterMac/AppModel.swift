import AppKit
import FilmScanEngine
import FilmScanPreviewRenderer
import Observation
import os.signpost

/// Dispatch source cancellation is thread-safe, including during model teardown.
private final class PreviewMemoryPressureSourceHandle: @unchecked Sendable {
  let source: DispatchSourceMemoryPressure

  init(_ source: DispatchSourceMemoryPressure) {
    self.source = source
  }

  func cancel() {
    source.cancel()
  }
}

@MainActor
@Observable
final class AppModel {
  private(set) var files: [URL] = [] {
    didSet { persistOpenRoll() }
  }
  var selection: URL? {
    didSet { persistOpenRoll() }
  }
  var selectedFiles: Set<URL> = [] {
    didSet { persistOpenRoll() }
  }
  private(set) var hasPreviewImage = false
  private(set) var previewImage: NSImage? {
    didSet {
      // Availability drives controls; a new raster must not invalidate them.
      let available = previewImage != nil
      if hasPreviewImage != available { hasPreviewImage = available }
    }
  }
  private(set) var previewDetail: PreviewDetail?
  private(set) var previewStatisticsRevision = 0
  private var previewRenderDemand: PreviewRenderDemand?
  private var viewportRevision = 0
  private var statisticsTask: Task<Void, Never>?
  private var pendingStatistics: PreviewStatisticsRequest?
  private var publishedStatisticsRequest: PreviewStatisticsRequest?
  private var lastStatisticsSubmission: ContinuousClock.Instant?
  private(set) var previewStatisticsComputationCount = 0
  var previewStatisticsCompletionHook: (@MainActor () async -> Void)?

  private(set) var thumbnailImages: [String: NSImage] = [:]
  private(set) var thumbnailLoadingPaths: Set<String> = []
  private(set) var detectedScanStacks: [DetectedScanStack] = []
  private(set) var enabledScanStackIDs: Set<String> = []
  private(set) var scanStackModes: [String: ScanStackMode] = [:]
  private(set) var isAnalyzingScanStacks = false
  private(set) var isBuildingScanStack = false
  private(set) var isUpgradingScanStack = false
  private(set) var scanStackStatus = ""
  private(set) var scanStackStatusID: String?
  private(set) var scanStackEffectiveMode: ScanStackMode?
  private(set) var decodedImage: UInt16Image?
  private(set) var parameters = ProcessingParameters(photoAdjustments: .init())
  private(set) var isRendering = false
  private(set) var isLoading = false
  private(set) var isUpgradingRawPreview = false
  var showOriginal = false {
    didSet {
      if isDustEditing {
        refreshDustMaskDisplay()
      } else {
        resetDustState(cancelTask: true)
      }
      scheduleRender()
    }
  }
  private(set) var status = "Drop film scans into the window to begin."
  private(set) var statusKind: StatusKind = .info
  private(set) var renderStats = RenderStats()
  private(set) var previewStatistics = RenderReadyImageStatistics.empty
  private(set) var previewSourceKind: PreviewSourceKind?
  private(set) var exportParameters = ExportParameters()
  private(set) var isExporting = false
  private(set) var isExportingContactSheet = false
  private(set) var lastContactSheetURL: URL?
  private(set) var exportProgressCurrent = 0
  private(set) var exportProgressTotal = 0
  private(set) var exportErrors: [String] = []
  private(set) var exportQueueCount = 0
  private(set) var activeExportFilename: String?
  private(set) var rebateCandidates: [AutomaticRebateCandidate] = []
  private(set) var selectedRebateMeasurement: FilmBaseMeasurement?
  private(set) var selectedRebateRegion: ImageRegion?
  private(set) var isRebateDetectionRunning = false
  private(set) var rollProfile: RollProfile?
  private(set) var rebateStatus: String = ""
  private(set) var flatFieldImage: UInt16Image? {
    didSet {
      previewSourceGeneration += 1
      previewCache.invalidateRenderedPreviews()
      clearRetainedCanvasPreviews()
    }
  }
  private(set) var flatFieldURL: URL?
  private(set) var cropRect: RotatedRect?
  private(set) var perspectiveCrop: PerspectiveCrop?
  private(set) var manualCrop: NormalizedCropRect?
  private(set) var straightenAngle: Double = 0
  private(set) var sourcePixelDimensions: PixelDimensions?
  private(set) var cropThresholdPreview: UInt16Image?
  private(set) var isCropDetectionRunning = false
  private(set) var cropStatus: String = ""
  private(set) var dustMaskImage: NSImage?
  private(set) var dustSourceMask: UInt16Image?
  private(set) var isDustEditing = false
  var showDustMask = true {
    didSet { refreshDustMaskDisplay() }
  }
  var showDustRepairs = true {
    didSet { scheduleRender(immediate: true) }
  }
  private(set) var isDustDetectionRunning = false
  private(set) var isDustRepairRunning = false
  private(set) var dustStatus: String = ""
  private(set) var namedCorrectionPresets: [NamedCorrectionPreset] = []
  var appliedPresetName: String? {
    if let factory = LookRecipe.factory.first(where: { $0.matches(parameters) }) {
      return factory.title
    }
    return namedCorrectionPresets.first { $0.settings.recipe.matches(parameters) }?.name
  }

  /// Reuse the selected decoded source. The optional look strip prepares and
  /// renders its small images off the main actor without requesting another RAW.
  var presetPreviewRequest: PresetPreviewRequest? {
    guard let selection, let previewSource, hasPreviewImage,
      previewSourceKind != .embeddedRAW, !isLoading, !isExporting,
      !isBuildingScanStack, !isDustEditing,
      !isPreviewingSourceGeometry, !isPreviewingUncroppedCanvas,
      FilmBase.resolved(from: parameters).supportsLooks
    else { return nil }
    var previewParameters = parameters
    if !showDustRepairs { previewParameters.dustRepairs = [] }
    return PresetPreviewRequest(
      key: PresetPreviewKey(
        sourceURL: selection, sourceGeneration: previewSourceGeneration,
        parameters: previewParameters),
      source: previewSource, parameters: previewParameters,
      flatField: compatibleFlatField(for: previewSource))
  }

  private(set) var settingsStatus: String = ""
  private(set) var openRollStatus: String = ""
  private(set) var previewCacheLimit: Int
  private(set) var availableCaptureProfiles: [CaptureProfile] = []
  private(set) var availableFilmStockProfiles: [FilmStockProfile] = []
  private(set) var availableRollProfiles: [RollProfile] = []
  var selectedCaptureProfileID = CaptureProfile.default.id
  var selectedFilmStockProfileID = FilmStockProfile.genericColorNegative.id
  var selectedRollProfileID: String?
  private(set) var profileStatus: String = ""
  private(set) var undoActionName: String?
  private(set) var redoActionName: String?

  let profileStore: ProfileStore
  private var settingsPersistence: PerFileSettingsPersistence?
  private var latestSettingsCompletionRevision: UInt64 = 0
  private var latestSavedSettingsRevision: UInt64 = 0
  private var openRollPersistence: OpenRollPersistence?
  private var lastSubmittedOpenRoll: OpenRollStore.State?
  private var latestOpenRollCompletionRevision: UInt64 = 0
  private var latestSavedOpenRollRevision: UInt64 = 0
  private let presetStore: NamedCorrectionPresetStore?
  private let settingsClipboard: CorrectionSettingsClipboard
  private let preferences: UserDefaults
  private let authoritativeDecoder = AuthoritativeImageDecoder()

  init(
    profileStore: ProfileStore? = nil,
    settingsStore: PerFileSettingsStore? = nil,
    openRollStore: OpenRollStore? = nil,
    presetStore: NamedCorrectionPresetStore? = nil,
    settingsClipboard: CorrectionSettingsClipboard = CorrectionSettingsClipboard(),
    preferences: UserDefaults = .standard,
    previewMemoryBudget: Int? = nil
  ) {
    self.presetStore = presetStore
    self.settingsClipboard = settingsClipboard
    self.preferences = preferences
    previewMemoryByteLimit = max(1, previewMemoryBudget ?? Self.previewCacheByteLimit)
    if preferences.object(forKey: "previewCacheLimit") == nil {
      previewCacheLimit = Self.defaultPreviewCacheLimit
    } else {
      previewCacheLimit = max(2, preferences.integer(forKey: "previewCacheLimit"))
    }
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
      let requiresSettingsRecovery: Bool
      do {
        let state = try settingsStore.loadState()
        settingsByPath = state.settingsByPath
        editedKeys = state.editedPaths
        requiresSettingsRecovery = false
      } catch {
        requiresSettingsRecovery = true
        setStatus(
          "Saved corrections could not be loaded; defaults are being used.",
          kind: .error)
      }
      settingsPersistence = PerFileSettingsPersistence(
        initialState: .init(settingsByPath: settingsByPath, editedPaths: editedKeys),
        save: settingsStore.makeSessionSaveOperation(requiresRecovery: requiresSettingsRecovery),
        onCompletion: { [weak self] revision, result in
          Task { @MainActor [weak self] in
            self?.handleSettingsPersistenceCompletion(revision: revision, result: result)
          }
        })
    }
    if let presetStore {
      do {
        namedCorrectionPresets = try presetStore.load()
      } catch {
        settingsStatus = "Saved presets could not be loaded."
      }
    }
    reloadProfiles()
    let pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    pressure.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let source = self.previewMemoryPressureSource else { return }
        self.handlePreviewMemoryPressure(isUnderPressure: !source.source.data.contains(.normal))
      }
    }
    previewMemoryPressureSource = PreviewMemoryPressureSourceHandle(pressure)
    pressure.resume()
    Task.detached(priority: .medium) {
      StillPreviewRenderer.warmUp()
    }
    if let openRollStore {
      do {
        if let saved = try openRollStore.load() {
          files = saved.paths.map { URL(fileURLWithPath: $0) }
          selection = saved.selection.map { URL(fileURLWithPath: $0) }
          selectedFiles = Set(saved.selectedPaths.map { URL(fileURLWithPath: $0) })
        }
      } catch {
        openRollStatus = "The previous roll could not be restored. Its saved file has been kept."
      }
      lastSubmittedOpenRoll = openRollState
      openRollPersistence = OpenRollPersistence(
        save: { try openRollStore.save($0) },
        onCompletion: { [weak self] revision, result in
          Task { @MainActor [weak self] in
            self?.handleOpenRollPersistenceCompletion(revision: revision, result: result)
          }
        })
      if !files.isEmpty {
        scheduleScanStackAnalysis()
        loadSelection()
      }
    }
  }

  deinit { previewMemoryPressureSource?.cancel() }

  public struct RenderStats: Sendable {
    public var submittedSnapshots: Int = 0
    public var displayedRenders: Int = 0
    public var droppedSnapshots: Int = 0
    public var lastLatencyMs: Double = 0
    public var peakLatencyMs: Double = 0
    public var totalSubmissionLatencyMs: Double = 0
    public var lastPreparationMs: Double = 0
    public var lastQueueWaitMs: Double = 0
    public var lastRenderMs: Double = 0
    public var lastInteractionLatencyMs: Double = 0
    public var longestPublicationGapMs: Double = 0
  }

  private func setStatus(_ message: String, kind: StatusKind = .info) {
    status = message
    statusKind = kind
  }

  private struct EditingSnapshot: Equatable {
    let parameters: ProcessingParameters
    let framePercent: Int
    let aspectRatio: AspectRatio?
    let wasEdited: Bool
    let wasAutomaticallyClassified: Bool
  }

  private struct EditTransaction {
    let key: String
    let actionName: String
    let before: EditingSnapshot
  }

  private var settingsByPath: [String: ProcessingParameters] = [:]
  private var automaticallyClassifiedKeys: Set<String> = []
  private var editedKeys: Set<String> = []
  private var sameRollFilmTypeHint: FilmType?
  private var previewCache = PreviewSessionCache()
  private var retainedCanvasCache = RetainedCanvasPreviewCache()
  private var loadedPreviewKey: String?
  private var displayedRetainedCanvas: RetainedCanvasPreview?
  private var canvasSnapshotGeneration = 0
  private var pendingCanvasSnapshot: CanvasSnapshotRequest?
  private var canvasSnapshotTask: Task<Void, Never>?
  private var canvasSnapshotWorkerBytes = 0
  var isShowingRetainedCanvas: Bool { displayedRetainedCanvas != nil }
  var retainedCanvasPreviewCount: Int { retainedCanvasCache.count }
  var canvasSnapshotWorkIsActive: Bool { canvasSnapshotTask != nil }
  /// Synthetic tier injection for navigation tests; production uses LibRaw.
  var rawPreviewSessionDecoder: (@Sendable (URL, PreviewSourceKind) throws -> CachedPreviewSession)?
  let previewMemoryByteLimit: Int
  @ObservationIgnored private var previewMemoryPressureSource: PreviewMemoryPressureSourceHandle?
  /// Counts cache-drop handler calls from every origin, including OS notifications.
  @ObservationIgnored private(set) var previewMemoryPressureHandlingCount = 0
  private var isUnderPreviewMemoryPressure = false
  private(set) var previewCorrectionCount = 0
  private(set) var previewRenderCacheHits = 0
  private(set) var fullResolutionPreviewDecodeCount = 0
  /// Scheduler submissions, including requests cancelled before native decoding starts.
  private(set) var lookaheadPreviewRequestCount = 0
  var previewBackgroundWorkIsActive: Bool { predecodeTask != nil }
  private var previewSource: UInt16Image? {
    didSet {
      previewSourceGeneration += 1
      cpuPreviewPreparation = previewSource.map { CPUPreviewPreparationCache(image: $0) }
    }
  }
  private var cpuPreviewPreparation: CPUPreviewPreparationCache?
  private var previewSourceGeneration = 0 {
    didSet {
      cancelCropDetection(status: "The scan preview changed. Run Auto Frame again.")
      renderCancellation.cancel()
      previewDetail = nil
    }
  }

  private var previewRenderer: StillPreviewRenderer?
  private var continuousEditCPUPreparation: CPUPreviewPreparationCache?
  private var continuousEditPreviewSource: UInt16Image? {
    didSet {
      continuousEditCPUPreparation = continuousEditPreviewSource.map {
        CPUPreviewPreparationCache(
          image: $0,
          analysisImage: previewSource?.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension)
        )
      }
    }
  }
  private var continuousEditPreviewRenderer: StillPreviewRenderer?
  private var continuousEditPreviewNeedsRefinement = false
  private var isPreviewingUncroppedCanvas = false
  private var isPreviewingSourceGeometry = false
  private var editHistories: [String: EditHistory<EditingSnapshot>] = [:]
  private var editTransaction: EditTransaction?
  private var loadTask: Task<Void, Never>?
  private var predecodeTask: Task<Void, Never>?
  private var previewWorkRevision = 0
  private var thumbnailTasks: [String: Task<Void, Never>] = [:]
  private var thumbnailGeneration = 0
  private var thumbnailCacheOrder: [String] = []
  private var thumbnailCacheBytes = 0
  private var thumbnailByteCounts: [String: Int] = [:]
  private var failedThumbnailPaths: Set<String> = []
  private var scanAnalysisRecords: [String: ScanDetectionRecord] = [:]
  private var scanAnalysisTask: Task<Void, Never>?
  private var scanAnalysisGeneration = 0
  private var scanStackPreviewTask: Task<Void, Never>?
  private var scanStackPreviewGeneration = 0
  private var stackedPreviewMembers: StackPreviewMemberCache?
  private var lastStackedPreviewMode: ScanStackMode?
  private var rebateTask: Task<Void, Never>?
  private var flatFieldLoadTask: Task<Void, Never>?
  private var flatFieldLoadGeneration = 0
  var flatFieldDecoder: (@Sendable (URL) throws -> UInt16Image)?
  typealias CropDetectionResult = (
    threshold: UInt16Image, rect: RotatedRect, contourPoints: [SIMD2<Double>]
  )
  /// Holds native frame detection at a deterministic boundary in integration tests.
  var cropDetectionWorker: (@Sendable (UInt16Image, Int, Int, Int) -> CropDetectionResult?)?
  private var cropDetectionTask: Task<Void, Never>?
  private var cropDetectionGeneration = 0
  private var dustDetectionTask: Task<Void, Never>?
  private var dustDetectionGeneration = 0
  private var dustRepairTask: Task<Void, Never>?
  private var dustRepairGeneration = 0
  private var renderTask: Task<Void, Never>?
  private var pendingRender: PreviewRenderRequest?
  private var renderRevision = 0
  private var renderCancellation = PreviewRenderCancellation()
  private var renderContextGeneration = 0 {
    didSet {
      renderCancellation.cancel()
      renderCancellation = PreviewRenderCancellation()
    }
  }
  private var lastRenderContext: PreviewRenderContext?
  private var pendingInteractionStart: ContinuousClock.Instant?
  private var lastPublicationTime: ContinuousClock.Instant?
  private(set) var publishedRenderRevision = 0
  private(set) var publishedPreviewParameters: ProcessingParameters?
  /// Allows integration tests to hold a completed frame while newer edits arrive.
  var previewRenderCompletionHook: (@MainActor (ProcessingParameters) async -> Void)?
  var previewRenderWorkerHook: (@Sendable () async -> Void)?
  var previewRenderCheckpointHook: (@Sendable (PreviewRenderCheckpoint) -> Void)?
  var thumbnailPreparationHook: (@Sendable () -> Void)?
  var rawInspectDecodeHook: (@Sendable () throws -> Void)?
  /// Attached only by explicit diagnostics; ordinary editing retains no trace.
  var previewInteractionTrace: PreviewInteractionTrace?
  private var activeExportQueue: [URL] = []
  private var activeExportDestinations: [URL] = []
  private var activeExportItemParameters: [ExportParameters] = []
  private var activeExportCorrelationIDs: [String] = []
  private var activeExportQueueWaitIntervals: [AppPerformanceInterval] = []
  private var exportTask: Task<Void, Never>?
  private var exportWasCancelled = false
  private var lastRenderEnd: ContinuousClock.Instant = .now
  private var pendingFirstPreviewInterval: AppPerformanceInterval?
  private let rawDecodeScheduler = RawDecodeScheduler(
    maximumConcurrentDecodes: ProcessInfo.processInfo.physicalMemory >= 16 * 1_024 * 1_024 * 1_024
      ? 2 : 1)
  /// Last three-pass camera-scan decode of the selected file. Settings-only
  /// re-export skips unpack and demosaic. Dropped on selection change.
  private var retainedExportDecode = SelectedFileExportDecodeCache()
  /// Test seam that replaces LibRaw for selected-file export-cache tests.
  var fullResolutionExportDecoder: (@Sendable (URL) throws -> UInt16Image)?
  /// Test seam for standard-image export stage and cancellation regressions.
  var standardImageExportDecoder: (@Sendable (URL) throws -> UInt16Image)?
  var scanStackPreviewDecoder: (@Sendable (URL, ScanStackPreviewTier) throws -> UInt16Image)?
  var contactSheetPreviewDecoder: (@Sendable (URL) throws -> UInt16Image)?
  private(set) var fullResolutionExportDecodeCount = 0
  private(set) var fullResolutionExportDecodeCacheHits = 0

  var retainedExportDecodePath: String? { retainedExportDecode.key }
  // Keep latest-value-wins scheduling bounded while allowing 120 Hz displays
  // to consume the sub-4 ms Metal renderer without an artificial 60 Hz cap.
  private static let renderCoalesceInterval: Duration = .milliseconds(8)
  nonisolated static let displayPreviewMaxDimension = 1_000
  /// Largest camera-scan preview that stays near 0.3s on the development machine
  /// (unpack dominates; X-Trans interpolation requires a 512px tile).
  nonisolated static let rawDraftPreviewMaxDimension = 640
  /// Unseen-neighbour lookahead. On the 40MP development RAF a 3200px bound
  /// bins to ~2580px in about 2.4s: sharper than the 640px draft, cheap enough
  /// to fill while the selected file is already on its inspect or full pass.
  nonisolated static let rawDetailPreviewMaxDimension = 3_200
  /// Selected-file inspect preview. On the 40MP development RAF a 4000px bound
  /// bins to ~3876px and paints in about 4.0s; the next CFA integer step is the
  /// full sensor (~11–14s).
  nonisolated static let rawInspectPreviewMaxDimension = 4_000
  /// Positive bound larger than any current camera mosaic. Keeps the 1-pass
  /// interpolator (`fullResolution` stays false) while skipping mosaic shrink
  /// and the X-Trans 2×2 preview downsample used when `maxDimension` is nil.
  nonisolated static let rawFullPreviewDecodeBound = 100_000
  nonisolated static let analysisPreviewMaxDimension = 256
  nonisolated static let rawLookaheadDetailCount = 3
  nonisolated static let defaultPreviewCacheLimit = 8
  /// A temporary raster used only while a point-control gesture is active on
  /// a retained full-sensor RAW. Its logical document size remains full scale,
  /// and gesture release always queues an exact full-resolution refinement.
  nonisolated static let continuousEditPreviewMaxDimension = 2_048
  /// Includes decoded sources, renderer backing, and corrected display rasters.
  /// Leave most RAM for LibRaw workspaces, CPU geometry, Metal, export, and macOS.
  nonisolated static let previewCacheByteLimit = previewMemoryBudget(
    physicalMemory: ProcessInfo.processInfo.physicalMemory)

  nonisolated static func previewMemoryBudget(physicalMemory: UInt64) -> Int {
    let mebibyte: UInt64 = 1_024 * 1_024
    return Int(max(512 * mebibyte, min(3_072 * mebibyte, physicalMemory / 8)))
  }
  nonisolated static let thumbnailMaxDimension = 192
  nonisolated static let thumbnailCacheCountLimit = 256
  nonisolated static let thumbnailCacheByteLimit = 48 * 1_024 * 1_024
  nonisolated static let maximumScanStackMembers = 8

  var previewCacheSessionCount: Int {
    previewCache.count
  }

  var previewCachePhysicalBytes: Int {
    previewCache.physicalByteCount
      + retainedCanvasCache.physicalByteCount
      + uncachedDisplayedCanvasBytes
      + uncachedCPUPreparationGeometryBytes
  }

  var selectedImageDimensions: (width: Int, height: Int, provisional: Bool)? {
    if let previewSource {
      let stackIsAuthoritative =
        previewSourceKind == .alignedStack && stackPreviewCoversSource(previewSource)
      return (
        previewSource.width, previewSource.height,
        previewSourceKind != .rawFull && !stackIsAuthoritative
      )
    }
    return nil
  }

  var selectedDetectedFrameDimensions: PixelDimensions? {
    guard let source = sourcePixelDimensions, parameters.cropRect != nil else { return nil }
    var frameParameters = parameters
    frameParameters.rotation = 0
    frameParameters.straightenAngle = 0
    frameParameters.manualCrop = nil
    return ImageGeometry.outputDimensions(source: source, parameters: frameParameters)
  }

  var selectedCanvasDimensions: PixelDimensions? {
    guard let source = sourcePixelDimensions else { return nil }
    return ImageGeometry.outputDimensions(source: source, parameters: parameters)
  }

  var selectedUncroppedCanvasDimensions: PixelDimensions? {
    guard let source = sourcePixelDimensions else { return nil }
    var uncropped = parameters
    uncropped.manualCrop = nil
    return ImageGeometry.outputDimensions(source: source, parameters: uncropped)
  }

  var normalizedManualCropAspectRatio: Double? {
    guard let canvas = selectedUncroppedCanvasDimensions else { return nil }
    return parameters.manualCropAspectRatio.normalizedRatio(in: canvas)
  }

  var selectedOutputDimensions: PixelDimensions? {
    guard let canvas = selectedCanvasDimensions else { return nil }
    return ImageGeometry.framedDimensions(
      canvas,
      framePercent: exportParameters.framePercent,
      aspectRatio: exportParameters.aspectRatio)
  }

  var selectedFileCount: Int {
    orderedSelectedFiles.count
  }

  var selectedExportItemCount: Int {
    consolidatedExportURLs(orderedSelectedFiles).count
  }

  var canLoadRawDetailPreview: Bool {
    guard let selection else { return false }
    return FileDropPolicy.rawExtensions.contains(selection.pathExtension.lowercased())
      && previewSourceKind != .rawFull
      && previewSourceKind != .alignedStack
      && !isLoading
      && !isExporting
  }

  var canUndo: Bool { undoActionName != nil }
  var canRedo: Bool { redoActionName != nil }

  var undoMenuTitle: String {
    undoActionName.map { "Undo \($0)" } ?? "Undo"
  }

  var redoMenuTitle: String {
    redoActionName.map { "Redo \($0)" } ?? "Redo"
  }

  private var orderedSelectedFiles: [URL] {
    guard let selection else { return [] }
    guard selectedFiles.contains(selection) else { return [selection] }
    return files.filter { selectedFiles.contains($0) }
  }

  private func enabledScanStack(containing url: URL) -> DetectedScanStack? {
    guard let stack = detectedScanStack(containing: url),
      enabledScanStackIDs.contains(stack.id)
    else { return nil }
    return stack
  }

  private func consolidatedExportURLs(_ urls: [URL]) -> [URL] {
    var result: [URL] = []
    var includedStackIDs: Set<String> = []
    var includedPaths: Set<String> = []
    for url in urls {
      if let stack = enabledScanStack(containing: url) {
        guard includedStackIDs.insert(stack.id).inserted else { continue }
        let path = settingsKey(stack.anchor)
        if includedPaths.insert(path).inserted { result.append(stack.anchor) }
      } else {
        let path = settingsKey(url)
        if includedPaths.insert(path).inserted { result.append(url) }
      }
    }
    return result
  }

  func hasCachedPreview(for url: URL) -> Bool {
    previewCache[settingsKey(url)] != nil
  }

  func cachedPreviewKind(for url: URL) -> PreviewSourceKind? {
    previewCache[settingsKey(url)]?.sourceKind
  }

  /// Prefer forward browsing, then the previous neighbour. Completed full
  /// previews remain in the LRU cache in either direction.
  nonisolated static func previewLookahead(
    files: [URL],
    selected: URL,
    cacheLimit: Int
  ) -> [URL] {
    guard let index = files.firstIndex(of: selected) else { return [] }
    let budget = max(0, cacheLimit - 1)
    var upcoming = Array(files.dropFirst(index + 1).prefix(rawLookaheadDetailCount))
    if upcoming.count < rawLookaheadDetailCount {
      upcoming += files[..<index].reversed().prefix(rawLookaheadDetailCount - upcoming.count)
    }
    return Array(upcoming.prefix(budget))
  }

  func hasEdits(for url: URL) -> Bool {
    editedKeys.contains(settingsKey(url))
  }

  func thumbnail(for url: URL) -> NSImage? {
    thumbnailImages[settingsKey(url)]
  }

  func isThumbnailLoading(for url: URL) -> Bool {
    thumbnailLoadingPaths.contains(settingsKey(url))
  }

  /// Starts one small, independent thumbnail decode for a visible sidebar row.
  /// These images do not retain the much larger interactive preview sessions.
  @discardableResult
  func requestThumbnail(for url: URL) -> Task<Void, Never>? {
    let key = settingsKey(url)
    guard thumbnailImages[key] == nil,
      thumbnailTasks[key] == nil,
      !thumbnailLoadingPaths.contains(key),
      !failedThumbnailPaths.contains(key)
    else {
      if thumbnailImages[key] != nil { touchThumbnailCache(key) }
      return thumbnailTasks[key]
    }

    thumbnailLoadingPaths.insert(key)
    let generation = thumbnailGeneration
    let preparationHook = thumbnailPreparationHook
    let task = Task { [weak self] in
      let worker = Task.detached(priority: .utility) {
        try? Self.makeSidebarScanAnalysis(for: url, preparationHook: preparationHook)
      }
      let analysis = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self, generation == self.thumbnailGeneration else { return }
      self.thumbnailTasks[key] = nil
      self.thumbnailLoadingPaths.remove(key)
      guard !Task.isCancelled else { return }
      guard let analysis else {
        self.failedThumbnailPaths.insert(key)
        return
      }
      self.publishSidebarScanAnalysis(analysis, for: url)
    }
    thumbnailTasks[key] = task
    return task
  }

  var selectedDetectedScanStack: DetectedScanStack? {
    guard let selection else { return nil }
    return detectedScanStack(containing: selection)
  }

  func detectedScanStack(containing url: URL) -> DetectedScanStack? {
    detectedScanStacks.first { $0.contains(url) }
  }

  func isScanStackEnabled(_ stack: DetectedScanStack) -> Bool {
    enabledScanStackIDs.contains(stack.id)
  }

  func scanStackMode(for stack: DetectedScanStack) -> ScanStackMode {
    scanStackModes[stack.id] ?? .automatic
  }

  func setScanStackEnabled(_ enabled: Bool, for stack: DetectedScanStack) {
    guard !isExporting else {
      scanStackStatus = "Wait for the active export to finish before changing stacks."
      scanStackStatusID = stack.id
      return
    }
    if enabled {
      guard !isAnalyzingScanStacks else {
        scanStackStatus = "Wait for repeated-capture analysis to finish."
        scanStackStatusID = stack.id
        return
      }
      guard !isLoading else {
        scanStackStatus = "Wait for the source preview to finish loading."
        scanStackStatusID = stack.id
        return
      }
      guard flatFieldImage == nil else {
        scanStackStatus =
          "Clear the flat field before stacking; sensor-coordinate correction must happen per capture."
        scanStackStatusID = stack.id
        return
      }
      enabledScanStackIDs.insert(stack.id)
      if scanStackModes[stack.id] == nil {
        scanStackModes[stack.id] = .automatic
      }
      scanStackStatusID = stack.id
      if selection != stack.anchor || selectedFiles != [stack.anchor] {
        selection = stack.anchor
        selectedFiles = [stack.anchor]
        loadSelection()
      } else {
        buildScanStackPreview(stack)
      }
    } else {
      enabledScanStackIDs.remove(stack.id)
      scanStackPreviewGeneration += 1
      scanStackPreviewTask?.cancel()
      scanStackPreviewTask = nil
      isBuildingScanStack = false
      isUpgradingScanStack = false
      stackedPreviewMembers = nil
      lastStackedPreviewMode = nil
      scanStackEffectiveMode = nil
      scanStackStatus = "Stack disabled; showing the reference capture."
      scanStackStatusID = stack.id
      if selection.map(stack.contains) == true { loadSelection() }
    }
  }

  func setScanStackMode(_ mode: ScanStackMode, for stack: DetectedScanStack) {
    guard !isExporting else { return }
    let previous = scanStackMode(for: stack)
    scanStackModes[stack.id] = mode
    guard enabledScanStackIDs.contains(stack.id), previous != mode else { return }
    buildScanStackPreview(stack)
  }

  var canSelectPreviousScan: Bool { adjacentScan(offset: -1) != nil }
  var canSelectNextScan: Bool { adjacentScan(offset: 1) != nil }

  /// Moves the primary file to the previous or next import-ordered scan and
  /// collapses the sidebar selection to that one file so review stays fast.
  @discardableResult
  func selectAdjacentScan(offset: Int) -> Bool {
    guard let next = adjacentScan(offset: offset) else { return false }
    selectedFiles = [next]
    guard sidebarSelectionDidChange() else { return false }
    loadSelection()
    return true
  }

  var canMoveSelectedSidebarFileUp: Bool { sidebarSelectionMoveDestination(by: -1) != nil }

  var canMoveSelectedSidebarFileDown: Bool { sidebarSelectionMoveDestination(by: 1) != nil }

  func moveSelectedSidebarFile(by offset: Int) {
    guard let selection,
      let source = files.firstIndex(of: selection),
      let destination = sidebarSelectionMoveDestination(by: offset)
    else {
      return
    }
    // SwiftUI's destination is an insertion offset in the original array.
    moveSidebarFiles(
      fromOffsets: IndexSet(integer: source),
      toOffset: destination > source ? destination + 1 : destination)
  }

  private func sidebarSelectionMoveDestination(by offset: Int) -> Int? {
    guard !isExporting, let selection, let source = files.firstIndex(of: selection),
      offset == -1 || offset == 1
    else {
      return nil
    }
    let destination = source + offset
    guard files.indices.contains(destination) else { return nil }
    return destination
  }

  func isActiveExport(for url: URL) -> Bool {
    guard isExporting, activeExportQueue.indices.contains(exportProgressCurrent) else {
      return false
    }
    let active = activeExportQueue[exportProgressCurrent]
    if active == url { return true }
    return enabledScanStack(containing: url)?.anchor == active
  }

  func isPendingExport(for url: URL) -> Bool {
    guard isExporting else { return false }
    let pending = activeExportQueue.dropFirst(exportProgressCurrent + 1)
    if pending.contains(url) { return true }
    guard let anchor = enabledScanStack(containing: url)?.anchor else { return false }
    return pending.contains(anchor)
  }

  private func adjacentScan(offset: Int) -> URL? {
    let reviewFiles = files.filter { url in
      guard let stack = enabledScanStack(containing: url) else { return true }
      return stack.anchor == url
    }
    guard let selection else { return nil }
    let canonical = enabledScanStack(containing: selection)?.anchor ?? selection
    guard let index = reviewFiles.firstIndex(of: canonical) else { return nil }
    let nextIndex = index + offset
    guard reviewFiles.indices.contains(nextIndex) else { return nil }
    return reviewFiles[nextIndex]
  }

  func setPreviewCacheLimit(_ limit: Int) {
    previewCacheLimit = max(2, limit)
    preferences.set(previewCacheLimit, forKey: "previewCacheLimit")
    trimPreviewCache()
    if let selection { schedulePreviewWork(after: selection) }
  }

  private static let signpostLog = OSLog(
    subsystem: "film.scan.converter", category: "Signpost")

  func importFiles(_ urls: [URL]) {
    guard !isExporting else {
      setStatus("Wait for the active export to finish before importing more scans.", kind: .error)
      return
    }
    let supported = FileDropPolicy.supportedFiles(from: urls).map(\.standardizedFileURL)
    guard !supported.isEmpty else {
      ImportLog.error("No supported files in import batch")
      setStatus("No supported image or RAW files were dropped.", kind: .error)
      return
    }

    let existing = Set(files.map(\.standardizedFileURL.path))
    let newFiles = supported.filter { !existing.contains($0.standardizedFileURL.path) }
    ImportLog.importAdded(
      path: "appending \(newFiles.count) new files (total will be \(files.count + newFiles.count))")
    files.append(contentsOf: newFiles)
    scheduleScanStackAnalysis()
    selection = supported.first
    selectedFiles = selection.map { Set([$0]) } ?? []
    loadSelection()
  }

  /// Ends this browsing session without deleting source files or saved edits.
  func closeAllScans() {
    guard !isExporting else {
      setStatus("Wait for the active export to finish before closing scans.", kind: .error)
      return
    }
    endEditingGesture()
    files = []
    selection = nil
    selectedFiles = []
    loadSelection()
    loadTask = nil
    lastRenderContext = nil
    publishedPreviewParameters = nil
    scanAnalysisGeneration += 1
    scanAnalysisTask?.cancel()
    scanAnalysisTask = nil
    isAnalyzingScanStacks = false
    thumbnailGeneration += 1
    for task in thumbnailTasks.values { task.cancel() }
    thumbnailTasks.removeAll()
    thumbnailLoadingPaths.removeAll()
    thumbnailImages.removeAll()
    thumbnailCacheOrder.removeAll()
    thumbnailByteCounts.removeAll()
    thumbnailCacheBytes = 0
    failedThumbnailPaths.removeAll()
    scanAnalysisRecords.removeAll()
    detectedScanStacks = []
    enabledScanStackIDs = []
    scanStackModes = [:]
    scanStackStatus = ""
    scanStackStatusID = nil
    previewCache.removeAll(except: nil)
    editHistories.removeAll()
    refreshHistoryAvailability()
    sameRollFilmTypeHint = nil
    cancelFlatFieldLoad()
    flatFieldImage = nil
    flatFieldURL = nil
  }

  private var openRollState: OpenRollStore.State {
    .init(
      paths: files.map { settingsKey($0) },
      selection: selection.map { settingsKey($0) },
      selectedPaths: Set(selectedFiles.map { settingsKey($0) }))
  }

  private func persistOpenRoll() {
    guard let openRollPersistence else { return }
    let snapshot = openRollState
    guard snapshot != lastSubmittedOpenRoll else { return }
    lastSubmittedOpenRoll = snapshot
    openRollPersistence.submit(snapshot)
  }

  private func handleOpenRollPersistenceCompletion(revision: UInt64, result: Result<Void, Error>) {
    guard revision >= latestOpenRollCompletionRevision else { return }
    latestOpenRollCompletionRevision = revision
    switch result {
    case .success:
      latestSavedOpenRollRevision = max(latestSavedOpenRollRevision, revision)
      openRollStatus = ""
    case .failure:
      guard revision > latestSavedOpenRollRevision else { return }
      openRollStatus = "The open roll could not be saved for the next launch."
    }
  }

  func moveSidebarFiles(fromOffsets source: IndexSet, toOffset destination: Int) {
    guard !isExporting, !source.isEmpty,
      source.allSatisfy({ files.indices.contains($0) }),
      (0...files.count).contains(destination)
    else { return }
    var reordered = files
    reordered.move(fromOffsets: source, toOffset: destination)
    guard reordered != files else { return }

    let selectedStack = selection.flatMap { enabledScanStack(containing: $0) }
    files = reordered
    cancelPredecode()
    // Reconcile cached proposals before returning: export must never observe
    // the new order with stack membership from the old order.
    scanAnalysisGeneration += 1
    scanAnalysisTask?.cancel()
    scanAnalysisTask = nil
    applyDetectedScanStackProposals(
      Self.detectedScanStackProposals(files: files, records: scanAnalysisRecords))
    if let selectedStack, !enabledScanStackIDs.contains(selectedStack.id) {
      scanStackStatus = "Stack disabled because its capture order changed."
      scanStackStatusID = nil
      loadSelection()
    } else if let selection {
      schedulePreviewWork(after: selection)
    }
    if files.contains(where: { scanAnalysisRecords[settingsKey($0)] == nil }) {
      scheduleScanStackAnalysis()
    } else {
      isAnalyzingScanStacks = false
    }
  }

  /// Keeps the detail view anchored to one primary file while SwiftUI owns a
  /// native multi-selection set for Command- and Shift-click export workflows.
  /// Adding another selected row does not unexpectedly replace the image being
  /// edited; clicking a different row by itself still changes the primary file.
  @discardableResult
  func sidebarSelectionDidChange() -> Bool {
    let previous = selection
    if let selection, selectedFiles.contains(selection) {
      return false
    }
    endEditingGesture()
    let requested = files.first { selectedFiles.contains($0) }
    if let requested, let stack = enabledScanStack(containing: requested) {
      selection = stack.anchor
      selectedFiles = [stack.anchor]
    } else {
      selection = requested
    }
    return selection != previous
  }

  func loadRawDetailPreview() {
    guard let selection,
      FileDropPolicy.rawExtensions.contains(selection.pathExtension.lowercased())
    else {
      setStatus("RAW preview detail is only available for camera RAW files.")
      return
    }
    guard previewSourceKind != .rawFull else {
      setStatus("The full-resolution RAW preview is already loaded.")
      return
    }
    guard canLoadRawDetailPreview else { return }
    // Explicit detail requests supersede an in-flight inspect pass. The shared
    // decode gate keeps its worker occupied until cooperative cancellation ends.
    cancelPredecode()
    schedulePreviewWork(after: selection, skipInspect: true)
  }

  private var loadGeneration = 0
  private var rebateGeneration = 0

  private func prepareForSelectionLoad() -> Int {
    retainDepartingCanvas()
    displayedRetainedCanvas = nil
    loadedPreviewKey = nil
    endEditingGesture()
    isPreviewingUncroppedCanvas = false
    isPreviewingSourceGeometry = false
    isDustEditing = false
    retainedExportDecode.dropIfNotSelected(selection.map(settingsKey))
    refreshHistoryAvailability()
    scanStackPreviewGeneration += 1
    scanStackPreviewTask?.cancel()
    scanStackPreviewTask = nil
    isBuildingScanStack = false
    isUpgradingScanStack = false
    let currentStackID = selection.flatMap { detectedScanStack(containing: $0)?.id }
    if stackedPreviewMembers?.stackID != currentStackID {
      stackedPreviewMembers = nil
    }
    if currentStackID == nil || !(currentStackID.map(enabledScanStackIDs.contains) ?? false) {
      scanStackEffectiveMode = nil
      lastStackedPreviewMode = nil
    }
    if let interval = pendingFirstPreviewInterval {
      AppPerformanceSignposts.end(interval)
      pendingFirstPreviewInterval = nil
    }
    loadTask?.cancel()
    cancelRenderLoop()
    loadGeneration += 1
    let gen = loadGeneration
    resetRebateState(cancelTask: true)
    resetCropState(cancelTask: true)
    resetDustState(cancelTask: true)
    return gen
  }

  private func clearPreviewForEmptySelection() {
    previewImage = nil
    clearActivePreviewSources()
    previewStatistics = .empty
    previewSourceKind = nil
    isLoading = false
    isUpgradingRawPreview = false
    sourcePixelDimensions = nil
    cancelPredecode()
    setStatus("Drop film scans into the window to begin.")
    refreshHistoryAvailability()
  }

  private func clearActivePreviewSources() {
    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    continuousEditPreviewSource = nil
    continuousEditPreviewRenderer = nil
    continuousEditPreviewNeedsRefinement = false
  }

  func loadSelection() {
    let gen = prepareForSelectionLoad()
    guard let selection else {
      clearPreviewForEmptySelection()
      return
    }

    let loadCorrelationID = UUID().uuidString
    let selectionInterval = AppPerformanceSignposts.begin(
      .selectionReceived, correlationID: loadCorrelationID,
      filename: selection.lastPathComponent)
    AppPerformanceSignposts.end(selectionInterval)
    pendingFirstPreviewInterval = AppPerformanceSignposts.begin(
      .firstCorrectedPreview,
      correlationID: loadCorrelationID,
      filename: selection.lastPathComponent
    )

    isLoading = true
    isUpgradingRawPreview = false

    cancelPredecode()
    ImportLog.loadSelectionStarted(path: selection.lastPathComponent)

    clearActivePreviewSources()
    previewSourceKind = nil
    let key = settingsKey(selection)
    parameters = settingsByPath[key] ?? ProcessingParameters(photoAdjustments: .init())
    cropRect = parameters.cropRect
    perspectiveCrop = parameters.perspectiveCrop
    manualCrop = parameters.manualCrop
    straightenAngle = parameters.straightenAngle
    showOriginal = false
    refreshHistoryAvailability()

    restoreRetainedCanvas(for: selection)

    // A merged session is only valid while its stack is enabled. Disabling or
    // reordering captures must reload the source rather than reuse merged pixels.
    if previewCache[key]?.sourceKind == .alignedStack,
      enabledScanStack(containing: selection) == nil
    {
      previewCache.remove(forKey: key)
    }
    if let cached = previewCache[key] {
      ImportLog.loadSelectionCacheHit(path: selection.lastPathComponent)
      isLoading = false
      applyCachedSession(cached, selection: selection)
      previewCache.touch(key)
      schedulePreviewWork(after: selection)
      return
    }

    ImportLog.loadSelectionDecodeStarted(path: selection.lastPathComponent)

    let isRaw = FileDropPolicy.rawExtensions.contains(selection.pathExtension.lowercased())

    let thumbnailInterval =
      isRaw
      ? AppPerformanceSignposts.begin(
        .thumbnailExtraction,
        correlationID: loadCorrelationID,
        filename: selection.lastPathComponent)
      : nil
    let supportsStandardPreview = StandardImageDecoder.supportedExtensions.contains(
      selection.pathExtension.lowercased())
    if isRaw || supportsStandardPreview {
      let sessionDecoder = rawPreviewSessionDecoder
      loadTask = Task { [weak self] in
        guard let self else { return }
        let conversionInterval = AppPerformanceSignposts.begin(
          .previewConversion, correlationID: loadCorrelationID,
          filename: selection.lastPathComponent)
        let session = try? await self.rawDecodeScheduler.run { () -> CachedPreviewSession? in
          if isRaw, let sessionDecoder { return try sessionDecoder(selection, .rawDraft) }
          let display: UInt16Image
          let kind: PreviewSourceKind
          do {
            if isRaw {
              display = try Self.decodeRawPreview(
                selection, maxDimension: Self.rawDraftPreviewMaxDimension)
              kind = .rawDraft
            } else {
              display = try StandardImageDecoder.decodePreview(
                selection, maxDimension: Self.displayPreviewMaxDimension)
              kind = .standardThumbnail
            }
          } catch {
            ImportLog.loadSelectionDecodeFailed(
              path: selection.lastPathComponent,
              error: "Fast preview: \(error.localizedDescription)")
            return nil
          }
          guard let renderer = StillPreviewRenderer(image: display) else {
            ImportLog.error(
              "Fast preview renderer creation failed for \(selection.lastPathComponent)")
            return nil
          }
          return CachedPreviewSession(
            sourceKind: kind,
            displaySource: display,
            analysisSource: display.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension),
            previewRenderer: renderer,
            sourcePixelDimensions: Self.fullResolutionDimensions(of: selection))
        }
        AppPerformanceSignposts.end(conversionInterval)
        if let thumbnailInterval { AppPerformanceSignposts.end(thumbnailInterval) }
        guard !Task.isCancelled, gen == self.loadGeneration, self.selection == selection else {
          return
        }
        guard let session else {
          self.isLoading = false
          self.setStatus(
            "Unable to create a fast preview for \(selection.lastPathComponent).",
            kind: .error)
          return
        }
        let analysisInterval = AppPerformanceSignposts.begin(
          .analysis, correlationID: loadCorrelationID,
          filename: selection.lastPathComponent)
        self.applyPreviewSession(
          session, selection: selection,
          hasStoredSettings: self.settingsByPath[key] != nil)
        AppPerformanceSignposts.end(analysisInterval)
        self.cacheSession(session, for: selection)
        self.scheduleRender(immediate: true)
        self.schedulePreviewWork(after: selection)
      }
      return
    }

    setStatus("Decoding \(selection.lastPathComponent)...")

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
        let proxy = decoded.resizedToFit(maxDimension: Self.displayPreviewMaxDimension)
        previewSource = proxy
        previewRenderer = StillPreviewRenderer(image: proxy)
        isLoading = false
        previewSourceKind = .rawDetail
        if let current = settingsByPath[key] { parameters = current }
        if settingsByPath[key] != nil, parameters.pendingFilmBaseInitialization == nil {
          populateFilmNegativeMedians()
        } else {
          applyAutomaticFilmClassification(from: proxy)
        }
        cacheCurrentSession(for: selection)
        scheduleRender(immediate: true)
        schedulePreviewWork(after: selection)
        scheduleEnabledScanStackPreview(for: selection)
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
        setStatus(
          "Unable to decode \(selection.lastPathComponent): \(error.localizedDescription)",
          kind: .error)
      }
    }
  }

  func setFilmType(_ value: FilmType) {
    let base: FilmBase
    switch value {
    case .colourNegative: base = .colorC41
    case .blackAndWhiteNegative: base = .blackAndWhite
    case .slide: base = .slide
    case .cropOnly: base = .original
    }
    setFilmBase(base)
  }

  func setFilmBase(_ base: FilmBase) {
    if selection?.standardizedFileURL == files.first?.standardizedFileURL,
      base.filmType != .cropOnly
    {
      sameRollFilmTypeHint = base.filmType
      reclassifyAutomaticBatchGuesses()
    }
    let medians =
      base.filmType == .blackAndWhiteNegative || base.filmType == .colourNegative
      ? computeFilmNegativeMedians()
      : nil
    if base.filmType == .blackAndWhiteNegative {
      selectedFilmStockProfileID = FilmStockProfile.genericBW.id
    } else if base.filmType == .colourNegative {
      selectedFilmStockProfileID = FilmStockProfile.genericColorNegative.id
    }
    updateParameters(actionName: "Film Base") {
      $0 = base.applyingInvert(to: $0)
      $0.filmNegativeParams.measuredMedians = medians
      $0.filmBaseChosenByUser = true
      $0.pendingFilmBaseInitialization = nil
    }
  }

  func setSemanticTemperature(_ value: Double) {
    setPhotoAdjustment(
      \.temperatureShiftMired, to: value,
      range: PhotoAdjustmentParameters.temperatureShiftRangeMired,
      actionName: "Temperature")
  }

  func setSemanticTint(_ value: Double) {
    setPhotoAdjustment(
      \.tint, to: value, range: PhotoAdjustmentParameters.tintRange,
      actionName: "Tint")
  }

  func setSemanticSaturation(_ value: Double) {
    setPhotoAdjustment(
      \.saturation, to: value, range: PhotoAdjustmentParameters.saturationRange,
      actionName: "Saturation")
  }

  func setVibrance(_ value: Double) {
    setPhotoAdjustment(
      \.vibrance, to: value, range: PhotoAdjustmentParameters.vibranceRange,
      actionName: "Vibrance")
  }

  func setWarmHueRecovery(_ value: Double) {
    guard value.isFinite else { return }
    updateParameters(actionName: "Foliage Recovery") {
      $0.photoAdjustments.warmHueRecovery = min(max(value, 0), 1)
    }
  }

  func setFilmDyeMixing(
    _ keyPath: WritableKeyPath<FilmDyeMixingParameters, Double>,
    to value: Double
  ) {
    updateParameters(actionName: "Dye Crossover") {
      $0.filmDyeMixing[keyPath: keyPath] = value
      $0.filmDyeMixing = $0.filmDyeMixing.clamped()
    }
  }

  func resetFilmDyeMixing() {
    updateParameters(actionName: "Dye Crossover") { $0.filmDyeMixing = .neutral }
  }

  func setExposureEV(_ value: Double) {
    setPhotoAdjustment(
      \.exposureEV, to: value, range: PhotoAdjustmentParameters.exposureRangeEV,
      actionName: "Exposure")
  }

  func setBrightness(_ value: Double) {
    setPhotoAdjustment(
      \.brightness, to: value, range: PhotoAdjustmentParameters.brightnessRange,
      actionName: "Brightness")
  }

  func setContrast(_ value: Double) {
    setPhotoAdjustment(
      \.contrast, to: value, range: PhotoAdjustmentParameters.contrastRange,
      actionName: "Contrast")
  }

  func setSemanticHighlights(_ value: Double) {
    setPhotoAdjustment(
      \.highlights, to: value, range: PhotoAdjustmentParameters.highlightsRange,
      actionName: "Highlights", promotingTone: true)
  }

  func setSemanticShadows(_ value: Double) {
    setPhotoAdjustment(
      \.shadows, to: value, range: PhotoAdjustmentParameters.shadowsRange,
      actionName: "Shadows", promotingTone: true)
  }

  func setWhites(_ value: Double) {
    setPhotoAdjustment(
      \.whites, to: value, range: PhotoAdjustmentParameters.gradingPointRange,
      actionName: "Whites", promotingTone: true)
  }

  func setBlacks(_ value: Double) {
    setPhotoAdjustment(
      \.blacks, to: value, range: PhotoAdjustmentParameters.gradingPointRange,
      actionName: "Blacks", promotingTone: true)
  }

  func setShadowFloor(_ value: Double) {
    guard parameters.photoAdjustments.usesPhotographicTone else { return }
    setPhotoAdjustment(
      \.shadowFloor, to: value, range: PhotoAdjustmentParameters.gradingPointRange,
      actionName: "Shadow Floor", promotingTone: true)
  }

  func setMidtoneLevel(_ value: Double) {
    guard parameters.photoAdjustments.usesPhotographicTone else { return }
    setPhotoAdjustment(
      \.midtoneLevel, to: value, range: PhotoAdjustmentParameters.gradingPointRange,
      actionName: "Midtone Level", promotingTone: true)
  }

  func setHighlightCeiling(_ value: Double) {
    guard parameters.photoAdjustments.usesPhotographicTone else { return }
    setPhotoAdjustment(
      \.highlightCeiling, to: value, range: PhotoAdjustmentParameters.gradingPointRange,
      actionName: "Highlight Ceiling", promotingTone: true)
  }

  /// All public numeric edits validate before changing history, persistence, or comparison state.
  private func setPhotoAdjustment(
    _ keyPath: WritableKeyPath<PhotoAdjustmentParameters, Double>, to value: Double,
    range: ClosedRange<Double>, actionName: String, promotingTone: Bool = false
  ) {
    guard value.isFinite else { return }
    updateParameters(actionName: actionName) {
      if promotingTone { Self.promoteFocusedToneIfNeeded(&$0.photoAdjustments) }
      $0.photoAdjustments[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
      if keyPath == \.temperatureShiftMired || keyPath == \.tint || keyPath == \.saturation {
        $0.syncLegacyColorFieldsFromPhotoAdjustments()
      }
    }
  }

  private static func promoteFocusedToneIfNeeded(_ photo: inout PhotoAdjustmentParameters) {
    if (2..<PhotoAdjustmentParameters.currentSchemaVersion).contains(photo.schemaVersion) {
      photo.schemaVersion = PhotoAdjustmentParameters.currentSchemaVersion
    }
  }

  func upgradeToneControls() {
    guard !parameters.photoAdjustments.usesPhotographicTone else { return }
    updateParameters(actionName: "Update Tone Controls") {
      $0.photoAdjustments.schemaVersion = PhotoAdjustmentParameters.currentSchemaVersion
      $0.photoAdjustments.highlights *= -1
    }
  }

  func setCurveEnabled(_ value: Bool) {
    updateParameters(actionName: "Tone Curve") {
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
    updateParameters(actionName: "Tone Curve") {
      $0.curveEnabled = true
      $0.curveControlPoints = points
    }
  }

  func setRedCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters(actionName: "Red Curve") {
      $0.redCurveEnabled = true
      $0.redCurveControlPoints = points
    }
  }

  func setGreenCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters(actionName: "Green Curve") {
      $0.greenCurveEnabled = true
      $0.greenCurveControlPoints = points
    }
  }

  func setBlueCurveControlPoints(_ points: [CurvePoint]) {
    updateParameters(actionName: "Blue Curve") {
      $0.blueCurveEnabled = true
      $0.blueCurveControlPoints = points
    }
  }

  // One drag event changes both coordinates. Publish, persist and render them
  // together so the intermediate hue-only value never enters the work queue.
  func setHighlightWheel(hue: Double, strength: Double) {
    updateParameters(actionName: "Highlights Color Wheel") {
      $0.highlightWheel = ColorWheel(hue: hue, strength: strength)
    }
  }

  func setMidtoneWheel(hue: Double, strength: Double) {
    updateParameters(actionName: "Midtones Color Wheel") {
      $0.midtoneWheel = ColorWheel(hue: hue, strength: strength)
    }
  }

  func setShadowWheel(hue: Double, strength: Double) {
    updateParameters(actionName: "Shadows Color Wheel") {
      $0.shadowWheel = ColorWheel(hue: hue, strength: strength)
    }
  }

  func rotateCounterclockwise() {
    manualCrop = nil
    updateParameters(actionName: "Rotate") {
      $0.manualCrop = nil
      $0.rotation = ($0.rotation + ($0.flip ? 1 : 3)) % 4
    }
  }

  func rotateClockwise() {
    manualCrop = nil
    updateParameters(actionName: "Rotate") {
      $0.manualCrop = nil
      $0.rotation = ($0.rotation + ($0.flip ? 3 : 1)) % 4
    }
  }

  func toggleFlip() {
    manualCrop = nil
    updateParameters(actionName: "Flip") {
      $0.manualCrop = nil
      $0.flip.toggle()
    }
  }

  func setFilmNegativeRedRatio(_ value: Double) {
    updateParameters(actionName: "Negative Profile") { $0.filmNegativeParams.redRatio = value }
  }

  func setCalibratedNegativeExposure(_ value: Double) {
    updateParameters(actionName: "Negative Exposure") {
      $0.filmNegativeParams.monochromeExposureEV = value
    }
  }

  func setDensityUnmixStrength(_ value: Double) {
    guard value.isFinite else { return }
    updateParameters(actionName: "Color Separation") {
      $0.filmNegativeParams.densityUnmixStrength = min(max(value, 0), 1)
    }
  }

  func setFilmNegativePreset(_ preset: FilmNegativePreset) {
    let medians = preset != .off ? computeFilmNegativeMedians() : nil
    updateParameters(actionName: "Negative Profile") {
      switch preset {
      case .off:
        $0.filmNegativeParams.enabled = false
      case .colourNegative:
        $0.filmNegativeParams = FilmNegativeParams.colourNegative
      case .fuji400FreshAlternate:
        $0.filmNegativeParams = FilmNegativeParams.fuji400FreshAlternate
      case .fuji200ExpiredAlternate:
        $0.filmNegativeParams = FilmNegativeParams.fuji200ExpiredAlternate
      case .cinestill800TAlternate:
        $0.filmNegativeParams = FilmNegativeParams.cinestill800TAlternate
      case .harmanPhoenixIIAlternate:
        $0.filmNegativeParams = FilmNegativeParams.harmanPhoenixIIAlternate
      case .densityPrintGenericC41:
        $0.filmNegativeParams = FilmNegativeParams.densityPrintGenericC41
      case .densityPrintHarmanPhoenixII:
        $0.filmNegativeParams = FilmNegativeParams.densityPrintHarmanPhoenixII
      case .densityPrintFuji400:
        $0.filmNegativeParams = FilmNegativeParams.densityPrintFuji400
      case .legacyColourNegative:
        $0.filmNegativeParams = FilmNegativeParams.legacyColourNegative
      case .blackAndWhite:
        $0.filmNegativeParams = FilmNegativeParams.blackAndWhite
      case .shanghaiGP3Alternate:
        $0.filmNegativeParams = FilmNegativeParams.shanghaiGP3Alternate
      case .legacyBlackAndWhite:
        $0.filmNegativeParams = FilmNegativeParams.legacyBlackAndWhite
      }
      if let medians {
        $0.filmNegativeParams.measuredMedians = medians
      }
    }
  }

  func applyLookRecipe(_ recipe: LookRecipe) {
    endEditingGesture()
    updateParameters(actionName: recipe.title, immediate: true) { $0 = recipe.applying(to: $0) }
    settingsStatus = "Applied \(recipe.title)."
  }

  func setDensityCastRemovalStrength(_ value: Double) {
    guard value.isFinite else { return }
    updateParameters(actionName: "Cast Cleanup") {
      $0.filmNegativeParams.densityCastRemovalStrength = min(max(value, 0), 1)
      $0.filmNegativeParams.densityNeutralProtection = true
    }
  }

  func setDensityPipelineEnabled(_ value: Bool) {
    updateParameters(actionName: "Density Pipeline") {
      $0.densityPipelineEnabled = value
      if value {
        $0.filmNegativeParams.rendering = .powerLaw
      }
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
      let currentMedians =
        computeFilmNegativeMedians()
        ?? parameters.filmNegativeParams.measuredMedians
      let usesPhysicalDensity = resolved.stockProfile.filmNegativeParams.rendering == .densityPrint
      let usesDensityPipeline = resolved.stockProfile.filmNegativeParams.rendering == .powerLaw
      updateParameters(actionName: "Processing Profile") {
        $0.filmType = resolved.stockProfile.filmType
        $0.densityPipelineEnabled = usesDensityPipeline
        if let baseDensity = resolved.resolvedBaseDensity?.baseDensity {
          $0.densityBaseDensity = baseDensity
        }
        $0.densityCorrection = resolved.captureProfile.densityCorrection
        $0.densityC41Profile = resolved.stockProfile.c41Profile
        $0.densityDisplayParams = resolved.stockProfile.displayRendering
        $0.filmNegativeParams = resolved.stockProfile.filmNegativeParams
        $0.filmNegativeParams.measuredMedians = currentMedians
        $0.filmDyeMixing = resolved.stockProfile.dyeMixing
      }
      let baseMessage = rebateStatus.isEmpty ? "" : rebateStatus + " "
      if usesPhysicalDensity {
        rebateStatus =
          baseMessage
          + "Physical density profile active (stock: \(resolved.stockProfile.displayName))."
      } else if usesDensityPipeline {
        rebateStatus =
          baseMessage
          + "Density pipeline active (stock: \(resolved.stockProfile.displayName))."
      } else {
        rebateStatus =
          baseMessage
          + "Calibrated negative profile active (stock: \(resolved.stockProfile.displayName))."
      }
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
        densityCorrection: source.densityCorrection,
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
        filmNegativeParams: parameters.filmNegativeParams,
        dyeMixing: parameters.filmDyeMixing,
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
    profileStatus = ""
    var loadFailureCount = 0

    let builtInCapture = profileStore.builtInCaptureProfiles()
    var storedCapture: [CaptureProfile] = []
    for id in profileStore.listCaptureProfiles() {
      do {
        if let profile = try profileStore.loadCaptureProfile(id: id) {
          storedCapture.append(profile)
        } else {
          loadFailureCount += 1
          ProfileLog.loadFailed(
            kind: "Capture", id: id.rawValue, error: "The profile file disappeared.")
        }
      } catch {
        loadFailureCount += 1
        ProfileLog.loadFailed(
          kind: "Capture", id: id.rawValue, error: error.localizedDescription)
      }
    }
    availableCaptureProfiles = Self.uniqueCaptureProfiles(builtInCapture + storedCapture)

    let builtInStock = profileStore.builtInFilmStockProfiles()
    var storedStock: [FilmStockProfile] = []
    for id in profileStore.listFilmStockProfiles() {
      do {
        if let profile = try profileStore.loadFilmStockProfile(id: id) {
          storedStock.append(profile)
        } else {
          loadFailureCount += 1
          ProfileLog.loadFailed(
            kind: "Film-stock", id: id.rawValue, error: "The profile file disappeared.")
        }
      } catch {
        loadFailureCount += 1
        ProfileLog.loadFailed(
          kind: "Film-stock", id: id.rawValue, error: error.localizedDescription)
      }
    }
    availableFilmStockProfiles = Self.uniqueFilmStockProfiles(builtInStock + storedStock)
    do {
      availableRollProfiles = try profileStore.loadRollProfiles().sorted {
        $0.rollID.localizedCaseInsensitiveCompare($1.rollID) == .orderedAscending
      }
    } catch {
      availableRollProfiles = []
      loadFailureCount += 1
      ProfileLog.loadFailed(
        kind: "Roll", id: "roll-profiles", error: error.localizedDescription)
    }

    if loadFailureCount > 0 {
      profileStatus =
        "\(loadFailureCount) saved profile\(loadFailureCount == 1 ? "" : "s") could not be loaded. See the app log for details."
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
      .values.sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  func resetCorrections() {
    let historyBefore = currentEditingSnapshot()
    resetDustState(cancelTask: true)
    parameters = ProcessingParameters(photoAdjustments: .init())
    straightenAngle = 0
    if let selection { editedKeys.insert(settingsKey(selection)) }
    resetCropState(cancelTask: true)
    saveParameters()
    renderAfterEditing()
    recordCurrentEdit(actionName: "Reset Corrections", before: historyBefore)
  }

  func resetDevelopAdjustments() {
    endEditingGesture()
    applyCorrectionSettings(
      CorrectionSettings(capturing: ProcessingParameters(photoAdjustments: .init())),
      actionName: "Reset Adjustments")
    settingsStatus = "Reset tone and color adjustments."
  }

  var canPasteCorrectionSettings: Bool {
    (try? settingsClipboard.read()) != nil
  }

  var adjustmentTransferGroups = CorrectionAdjustmentGroup.defaultForSync

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
      endEditingGesture()
      applyCorrectionSettings(settings, actionName: "Paste Corrections")
      settingsStatus = "Correction settings pasted."
    } catch {
      settingsStatus = "Clipboard correction settings are not valid."
    }
  }

  func pasteSelectedCorrectionSettings() {
    guard !adjustmentTransferGroups.isEmpty else {
      settingsStatus = "Choose adjustments to paste."
      return
    }
    do {
      guard let settings = try settingsClipboard.read() else {
        settingsStatus = "The clipboard does not contain correction settings."
        return
      }
      if let selection {
        let changed = try applyCorrectionSettings(
          settings, to: [selection], groups: adjustmentTransferGroups,
          actionName: "Paste Selected Adjustments")
        settingsStatus =
          changed == 0
          ? "Selected adjustments already match." : "Pasted selected adjustments."
        return
      }
      let next = try settings.applying(to: parameters, groups: adjustmentTransferGroups)
      guard next != parameters else {
        settingsStatus = "Selected adjustments already match."
        return
      }
      endEditingGesture()
      updateParameters(actionName: "Paste Selected Adjustments", immediate: true) { $0 = next }
      settingsStatus = "Pasted selected adjustments."
    } catch {
      settingsStatus =
        (error as? CorrectionSettings.TransferError)?.localizedDescription
        ?? "Clipboard correction settings are not valid."
    }
  }

  func pasteSelectedCorrectionSettingsToSelectedFiles() {
    pasteSelectedCorrectionSettings(to: orderedSelectedFiles)
  }

  func pasteSelectedCorrectionSettingsToAllOpenFiles() {
    pasteSelectedCorrectionSettings(to: files)
  }

  private func pasteSelectedCorrectionSettings(to targets: [URL]) {
    guard !adjustmentTransferGroups.isEmpty else {
      settingsStatus = "Choose adjustments to paste."
      return
    }
    guard !targets.isEmpty else { return }
    do {
      guard let settings = try settingsClipboard.read() else {
        settingsStatus = "The clipboard does not contain correction settings."
        return
      }
      let changed = try applyCorrectionSettings(
        settings, to: targets, groups: adjustmentTransferGroups,
        actionName: "Paste Selected Adjustments")
      settingsStatus =
        changed == 0
        ? "Selected adjustments already match."
        : "Pasted selected adjustments to \(changed) scan\(changed == 1 ? "" : "s")."
    } catch {
      settingsStatus =
        (error as? CorrectionSettings.TransferError)?.localizedDescription
        ?? "Clipboard correction settings are not valid."
    }
  }

  func syncSelectedAdjustmentsToSelectedFiles() {
    let targets = orderedSelectedFiles
    guard targets.count > 1 else {
      settingsStatus = "Select two or more scans to sync adjustments."
      return
    }
    syncSelectedAdjustments(to: targets)
  }

  func syncSelectedAdjustmentsToAllOpenFiles() {
    syncSelectedAdjustments(to: files)
  }

  private func syncSelectedAdjustments(to targets: [URL]) {
    guard selection != nil, !targets.isEmpty else { return }
    guard !adjustmentTransferGroups.isEmpty else {
      settingsStatus = "Choose adjustments to sync."
      return
    }
    do {
      let changed = try applyCorrectionSettings(
        CorrectionSettings(capturing: parameters), to: targets, groups: adjustmentTransferGroups,
        actionName: "Sync Selected Adjustments")
      settingsStatus =
        changed == 0
        ? "Selected adjustments already match."
        : "Synced selected adjustments to \(changed) scan\(changed == 1 ? "" : "s")."
    } catch {
      settingsStatus = error.localizedDescription
    }
  }

  @discardableResult
  func saveCorrectionPreset(named name: String) -> Bool {
    guard let presetStore else {
      settingsStatus = "Preset storage is unavailable."
      return false
    }
    do {
      namedCorrectionPresets = try presetStore.savePreset(
        named: name,
        settings: CorrectionSettings(capturing: parameters)
      )
      settingsStatus = "Preset saved."
      return true
    } catch NamedCorrectionPresetStore.StoreError.emptyName {
      settingsStatus = "Enter a preset name."
    } catch {
      settingsStatus = "Preset could not be saved."
    }
    return false
  }

  func applyCorrectionPreset(_ preset: NamedCorrectionPreset) {
    endEditingGesture()
    applyCorrectionSettings(preset.settings, actionName: "Apply \(preset.name)")
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

  private func applyCorrectionSettings(
    _ settings: CorrectionSettings,
    actionName: String
  ) {
    updateParameters(actionName: actionName, immediate: true) {
      $0 = settings.applying(to: $0)
    }
  }

  func applyCurrentSettingsToAllOpenFiles() {
    guard selection != nil, !files.isEmpty else { return }
    applyCurrentLook(
      to: files,
      actionName: "Apply Settings to All"
    )
    settingsStatus = "Applied settings to all \(files.count) open files."
  }

  func applyCurrentLookToSelectedFiles() {
    let targets = orderedSelectedFiles
    guard targets.count > 1 else {
      settingsStatus = "Select two or more files to apply the current look."
      return
    }
    applyCurrentLook(
      to: targets,
      actionName: "Apply Look to Selected"
    )
    settingsStatus = "Applied the current look to \(targets.count) selected files."
  }

  private func applyCurrentLook(
    to targets: [URL],
    actionName: String
  ) {
    let settings = CorrectionSettings(capturing: parameters)
    // Complete transfers cannot encounter a partial legacy-tone mismatch.
    _ = try? applyCorrectionSettings(
      settings, to: targets, groups: CorrectionAdjustmentGroup.all, actionName: actionName,
      marksMatchingTargetsEdited: true)
  }

  @discardableResult
  private func applyCorrectionSettings(
    _ settings: CorrectionSettings,
    to targets: [URL],
    groups: Set<CorrectionAdjustmentGroup>,
    actionName: String,
    marksMatchingTargetsEdited: Bool = false
  ) throws -> Int {
    guard !groups.isEmpty else { return 0 }
    // Validate the entire batch first so an incompatible legacy scan does not
    // leave the preceding scans changed and the remaining scans untouched.
    var changes: [(url: URL, parameters: ProcessingParameters)] = []
    for url in targets {
      let key = settingsKey(url)
      let destination = editingSnapshot(for: key).parameters
      var transferDestination = destination
      if settingsByPath[key] == nil || destination.pendingFilmBaseInitialization != nil {
        transferDestination.pendingFilmBaseInitialization = .preservingLook
      }
      let applied: ProcessingParameters
      if marksMatchingTargetsEdited {
        applied = settings.applying(to: transferDestination)
      } else {
        applied = try settings.applying(to: transferDestination, groups: groups)
      }
      var comparable = applied
      comparable.pendingFilmBaseInitialization = destination.pendingFilmBaseInitialization
      guard marksMatchingTargetsEdited || comparable != destination else { continue }
      changes.append((url, applied))
    }
    guard !changes.isEmpty else { return 0 }
    endEditingGesture()
    for change in changes {
      let key = settingsKey(change.url)
      if selection == change.url,
        change.parameters != parameters || !marksMatchingTargetsEdited
      {
        updateParameters(actionName: actionName, immediate: true) { $0 = change.parameters }
        continue
      }
      // The original full batch action deliberately marks every target edited,
      // including a matching anchor, and records that intent in its history.
      // Selective transfers (even All groups) leave matching scans untouched.
      let historyBefore = editingSnapshot(for: key)
      let applied = change.parameters
      settingsByPath[key] = applied
      automaticallyClassifiedKeys.remove(key)
      editedKeys.insert(key)
      persistSettings(for: key)
      recordEdit(
        for: key,
        actionName: actionName,
        before: historyBefore,
        after: editingSnapshot(for: key)
      )
    }
    settingsPersistence?.requestFlush()
    refreshHistoryAvailability()
    return changes.count
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
    panel.directoryURL =
      exportParameters.destinationDirectory ?? selection?.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    setExportDestinationDirectory(url)
  }

  func setExportDestinationDirectory(_ url: URL?) {
    exportParameters.destinationDirectory = url?.standardizedFileURL
  }

  func setExportFormat(_ format: ExportFormat) {
    exportParameters.format = format
  }

  func setExportFramePercent(_ percent: Int) {
    let historyBefore = currentEditingSnapshot()
    exportParameters.framePercent = percent
    recordCurrentEdit(actionName: "Border", before: historyBefore)
  }

  func setExportAspectRatio(_ ratio: AspectRatio?) {
    let historyBefore = currentEditingSnapshot()
    exportParameters.aspectRatio = ratio
    recordCurrentEdit(actionName: "Aspect Ratio", before: historyBefore)
  }

  func setJpegQuality(_ quality: Double) {
    exportParameters.jpegQuality = quality
  }

  func setTiffCompression(_ compression: TiffCompression) {
    exportParameters.tiffCompression = compression
  }

  func exportSelected() {
    let urls = consolidatedExportURLs(orderedSelectedFiles)
    guard !urls.isEmpty else {
      setStatus("No image selected for export.", kind: .error)
      return
    }
    exportFiles(urls)
  }

  func exportAll() {
    guard !files.isEmpty else {
      setStatus("No images to export.", kind: .error)
      return
    }
    exportFiles(consolidatedExportURLs(files))
  }

  func exportContactSheet(allFiles: Bool = false) {
    guard flatFieldLoadTask == nil else {
      setStatus("Wait for flat-field loading to finish before exporting.")
      return
    }
    guard !isExporting else { return }
    guard !isLoading, !isBuildingScanStack else {
      setStatus("Wait for the current preview to finish before exporting.", kind: .error)
      return
    }
    let urls = consolidatedExportURLs(allFiles ? files : orderedSelectedFiles)
    guard !urls.isEmpty else {
      setStatus("Select at least one scan for the contact sheet.", kind: .error)
      return
    }
    let activeSource = selection.map { enabledScanStack(containing: $0)?.anchor ?? $0 } ?? urls[0]
    let directory =
      exportParameters.destinationDirectory ?? activeSource.deletingLastPathComponent()
    let items = urls.map { url in
      let stack = enabledScanStack(containing: url)
      return ContactSheetItem(
        sources: stack?.members ?? [url], parameters: settingsByPath[settingsKey(url)],
        stackMode: stack.map(scanStackMode) ?? .automatic)
    }
    let prior = sameRollFilmTypeHint
    let field = flatFieldImage
    let gate = rawDecodeScheduler
    let decoder = contactSheetPreviewDecoder
    cancelPredecode()
    cancelScanStackUpgradePreservingPreview()
    isExporting = true
    isExportingContactSheet = true
    exportWasCancelled = false
    exportErrors = []
    lastContactSheetURL = nil
    activeExportQueue = urls
    activeExportFilename = urls.first?.lastPathComponent
    exportProgressCurrent = 0
    exportProgressTotal = urls.count
    exportQueueCount = max(0, urls.count - 1)
    setStatus("Creating contact sheet...")

    exportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isExporting = false
        self.isExportingContactSheet = false
        self.activeExportQueue = []
        self.activeExportFilename = nil
        self.exportQueueCount = 0
        self.exportTask = nil
      }
      do {
        let output = try await ContactSheetExport.write(
          items: items, destinationDirectory: directory, weakPrior: prior, flatField: field,
          decode: { url in
            try await gate.run {
              try Task.checkCancellation()
              let image: UInt16Image
              if let decoder {
                image = try decoder(url)
              } else if StandardImageDecoder.supportedExtensions.contains(
                url.pathExtension.lowercased())
              {
                image = try StandardImageDecoder.decodePreview(
                  url, maxDimension: ContactSheetExport.previewMaxDimension)
              } else {
                image = try Self.decodeRawPreview(
                  url, maxDimension: ContactSheetExport.previewMaxDimension)
              }
              try Task.checkCancellation()
              return image
            }
          },
          progress: { [weak self] completed, filename in
            await self?.updateContactSheetProgress(completed: completed, filename: filename)
          })
        self.lastContactSheetURL = output
        self.setStatus(
          "Saved \(items.count)-scan contact sheet to \(directory.lastPathComponent)/\(output.lastPathComponent)."
        )
      } catch is CancellationError {
        self.exportErrors = []
        self.setStatus("Contact sheet cancelled; no PDF was saved.")
      } catch {
        self.exportErrors = [error.localizedDescription]
        self.setStatus(
          "Contact sheet could not be saved: \(error.localizedDescription)", kind: .error)
      }
    }
  }

  private func updateContactSheetProgress(completed: Int, filename: String?) {
    exportProgressCurrent = completed
    activeExportFilename = filename
    exportQueueCount = max(0, exportProgressTotal - completed - (filename == nil ? 0 : 1))
  }

  func addSelectedToExportQueue() {
    let urls = consolidatedExportURLs(orderedSelectedFiles)
    guard isExporting, !isExportingContactSheet, !urls.isEmpty else {
      return
    }

    let itemParameters = exportParameters
    let destinations: [URL]
    do {
      destinations = try reserveDestinationURLs(
        for: urls,
        destinationDirectory: itemParameters.destinationDirectory,
        format: itemParameters.format,
        alreadyReserved: activeExportDestinations
      )
    } catch {
      setStatus(
        "Unable to inspect export destination: \(error.localizedDescription)",
        kind: .error)
      return
    }
    for (url, destination) in zip(urls, destinations) {
      activeExportQueue.append(url)
      activeExportDestinations.append(destination)
      var resolvedParameters = itemParameters
      resolvedParameters.destinationDirectory = destination.deletingLastPathComponent()
      activeExportItemParameters.append(resolvedParameters)
      let correlationID = UUID().uuidString
      activeExportCorrelationIDs.append(correlationID)
      activeExportQueueWaitIntervals.append(
        AppPerformanceSignposts.begin(
          .queueWait,
          correlationID: correlationID,
          filename: url.lastPathComponent))
    }
    exportQueueCount = max(0, activeExportQueue.count - exportProgressCurrent - 1)
    exportProgressTotal += urls.count
    setStatus(
      urls.count == 1
        ? "Added \(urls[0].lastPathComponent) to the export queue."
        : "Added \(urls.count) exports to the queue.")
  }

  func cancelExport() {
    guard isExporting else { return }
    exportWasCancelled = true
    setStatus("Cancelling export after the active stage finishes...")
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
    let sourceGeneration = previewSourceGeneration
    let compatibleField = compatibleFlatField(for: source)
    isRebateDetectionRunning = true
    rebateStatus = "Searching for unexposed film edges..."
    rebateCandidates = []
    selectedRebateMeasurement = nil
    selectedRebateRegion = nil

    rebateTask = Task { [weak self] in
      guard let self else { return }
      let result: [AutomaticRebateCandidate]
      if Task.isCancelled { return }
      let worker = Task.detached(priority: .userInitiated) { () -> [AutomaticRebateCandidate] in
        guard !Task.isCancelled else { return [] }
        let flatField = Self.preparedFlatField(for: source, compatibleField: compatibleField)
        guard !Task.isCancelled else { return [] }
        return FilmNegativeProcessing.automaticRebateCandidates(
          image: source,
          flatField: flatField
        )
      }
      result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled else { return }
      guard generation == rebateGeneration, selection == selectedURL else { return }
      guard sourceGeneration == previewSourceGeneration else {
        isRebateDetectionRunning = false
        rebateTask = nil
        return
      }
      rebateTask = nil
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
    let sourceGeneration = previewSourceGeneration
    let compatibleField = compatibleFlatField(for: source)
    rebateStatus = "Measuring base density..."
    rebateTask = Task { [weak self] in
      guard let self else { return }
      let result: Result<FilmBaseMeasurement, Error>
      let worker = Task.detached(priority: .userInitiated) {
        return Result {
          try Task.checkCancellation()
          let flatField = Self.preparedFlatField(for: source, compatibleField: compatibleField)
          try Task.checkCancellation()
          return try FilmNegativeProcessing.measureBaseDensity(
            image: source,
            flatField: flatField,
            region: region
          )
        }
      }
      result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled else { return }
      guard generation == rebateGeneration, selection == selectedURL else { return }
      guard sourceGeneration == previewSourceGeneration else {
        rebateTask = nil
        return
      }
      rebateTask = nil
      switch result {
      case .success(let measurement):
        selectedRebateMeasurement = measurement
        selectedRebateRegion = region
        updateParameters(actionName: "Film Base Measurement") {
          $0.densityPipelineEnabled = true
          $0.filmNegativeParams.rendering = .powerLaw
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
    updateParameters(actionName: "Film Base Measurement") {
      $0.densityPipelineEnabled = true
      $0.filmNegativeParams.rendering = .powerLaw
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
    updateParameters(actionName: "Clear Film Base") {
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
    loadFlatField(from: url)
  }

  @discardableResult
  func loadFlatField(from url: URL) -> Task<Void, Never>? {
    guard !isExporting else {
      rebateStatus = "Wait for the active export to finish before changing the flat field."
      return nil
    }
    cancelFlatFieldLoad()
    let generation = flatFieldLoadGeneration
    let scheduler = rawDecodeScheduler
    let decoder = flatFieldDecoder
    rebateStatus = "Loading flat-field: \(url.lastPathComponent)..."
    let task = Task { [weak self] in
      defer {
        if let self, generation == self.flatFieldLoadGeneration {
          self.flatFieldLoadTask = nil
        }
      }
      do {
        let image = try await scheduler.run {
          try decoder?(url) ?? Self.decodeImage(url)
        }
        guard let self, !Task.isCancelled, generation == self.flatFieldLoadGeneration else {
          return
        }
        self.setFlatField(image, url: url)
      } catch is CancellationError {
        guard let self, generation == self.flatFieldLoadGeneration else { return }
        self.rebateStatus = "Flat-field loading cancelled."
      } catch {
        guard let self, generation == self.flatFieldLoadGeneration else { return }
        self.rebateStatus = "Failed to load flat-field: \(error.localizedDescription)"
      }
    }
    flatFieldLoadTask = task
    return task
  }

  private func cancelFlatFieldLoad() {
    flatFieldLoadGeneration += 1
    flatFieldLoadTask?.cancel()
    flatFieldLoadTask = nil
  }

  func clearFlatField() {
    setFlatField(nil)
  }

  func setFlatField(_ image: UInt16Image?, url: URL? = nil) {
    guard !isExporting else {
      rebateStatus = "Wait for the active export to finish before changing the flat field."
      return
    }
    cancelFlatFieldLoad()
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
    if !enabledScanStackIDs.isEmpty {
      enabledScanStackIDs.removeAll()
      scanStackPreviewGeneration += 1
      scanStackPreviewTask?.cancel()
      scanStackPreviewTask = nil
      isBuildingScanStack = false
      isUpgradingScanStack = false
      stackedPreviewMembers = nil
      lastStackedPreviewMode = nil
      scanStackEffectiveMode = nil
      scanStackStatus =
        "Stack disabled because flat-field correction must be applied before alignment."
      scanStackStatusID = nil
      loadSelection()
    } else {
      scheduleRender(immediate: true)
    }
  }

  @discardableResult
  func detectCrop() -> Task<Void, Never>? {
    guard let source = previewSource, source.channels == 3 else {
      cropStatus = "Load an image with 3 channels first."
      return nil
    }
    cancelCropDetection()
    let generation = cropDetectionGeneration
    cropThresholdPreview = nil
    isCropDetectionRunning = true
    cropStatus = "Finding film frame..."

    let dark = parameters.darkThreshold
    let light = parameters.lightThreshold
    let maxDim = 2000
    let selectedURL = selection
    let sourceGeneration = previewSourceGeneration
    let detectionWorker = cropDetectionWorker

    cropDetectionTask = Task { [weak self] in
      guard let self else { return }
      guard !Task.isCancelled else {
        self.finishCancelledCropDetection(generation: generation)
        return
      }
      let worker = Task.detached(priority: .userInitiated) { () -> CropDetectionResult? in
        guard !Task.isCancelled else { return nil }
        let result: CropDetectionResult?
        if let detectionWorker {
          result = detectionWorker(source, dark, light, maxDim)
        } else {
          let threshold = source.getThreshold(darkThreshold: dark, lightThreshold: light)
          guard !Task.isCancelled else { return nil }
          result = ContourDetection.findOptimalCrop(threshold: threshold, maxDimension: maxDim)
        }
        guard !Task.isCancelled else { return nil }
        return result
      }
      // Synchronous threshold/contour work drains before this task completes.
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard generation == self.cropDetectionGeneration else { return }
      guard !Task.isCancelled else {
        self.finishCancelledCropDetection(generation: generation)
        return
      }
      guard self.selection == selectedURL,
        self.previewSourceGeneration == sourceGeneration
      else {
        self.finishCancelledCropDetection(generation: generation)
        return
      }

      self.cropDetectionTask = nil
      self.isCropDetectionRunning = false
      guard let result else {
        self.cropStatus = "No crop frame detected."
        return
      }
      self.performDiscreteEditingCompletion {
        self.setCropRect(result.rect)
      }
      self.cropThresholdPreview = result.threshold
      self.cropStatus = String(
        format: "Crop: %.1f°  w:%.3f  h:%.3f  at (%.3f, %.3f)",
        result.rect.angle,
        result.rect.width,
        result.rect.height,
        result.rect.centerX,
        result.rect.centerY
      )
    }
    return cropDetectionTask
  }

  @discardableResult
  func detectDustMask() -> Task<Void, Never>? {
    guard let source = previewSource, source.channels == 3 else {
      dustStatus = "Load a three-channel scan first."
      return nil
    }
    cancelDustMaskRepair()
    cancelDustDetection()
    let generation = dustDetectionGeneration
    isDustDetectionRunning = true
    dustStatus = "Detecting dust…"
    let selectedURL = selection
    let sourceGeneration = previewSourceGeneration
    let displayParameters = previewDisplayParameters
    // Identification is bounded; saved repair coordinates remain sensor-relative.
    let detectionSource = source.resizedToFit(maxDimension: 2_048)
    dustDetectionTask = Task { [weak self] in
      guard let self else { return }
      guard !Task.isCancelled else {
        self.finishCancelledDustDetection(generation: generation)
        return
      }
      let worker = Task.detached(priority: .userInitiated) {
        let mask = DustDetection.findMask(in: detectionSource)
        let preview = Self.makeDustMaskPreview(mask: mask, parameters: displayParameters)
        return (mask: mask, image: preview.image, detected: preview.detected)
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard generation == self.dustDetectionGeneration else { return }
      guard !Task.isCancelled else {
        self.finishCancelledDustDetection(generation: generation)
        return
      }
      guard self.selection == selectedURL else { return }
      guard sourceGeneration == self.previewSourceGeneration else {
        self.isDustDetectionRunning = false
        self.dustDetectionTask = nil
        self.dustStatus = "Scan changed; run dust detection again."
        return
      }
      self.isDustDetectionRunning = false
      self.dustDetectionTask = nil
      guard let cgImage = result.image else {
        self.dustStatus = "Dust mask could not be displayed."
        return
      }
      self.dustSourceMask = result.mask
      self.dustMaskImage = self.showDustMask ? PreviewBitmap.nsImage(from: cgImage) : nil
      self.dustStatus =
        result.detected == 0
        ? "No dust candidates found."
        : "Showing \(result.detected) dust-mask pixels."
    }
    return dustDetectionTask
  }

  nonisolated private static func makeDustMaskPreview(
    mask: UInt16Image, parameters: ProcessingParameters
  ) -> (image: CGImage?, detected: Int) {
    guard !Task.isCancelled else { return (nil, 0) }
    let croppedMask =
      parameters.perspectiveCrop.flatMap {
        PerspectiveTransform.crop(
          mask,
          perspectiveCrop: $0,
          borderPercent: parameters.borderCrop
        )
      } ?? parameters.cropRect.flatMap {
        PerspectiveTransform.crop(
          mask,
          normalizedRect: $0,
          coordinateSpace: parameters.cropRectCoordinateSpace,
          borderPercent: parameters.borderCrop
        )
      } ?? mask
    let orientedMask = croppedMask.rotated(
      quarterTurns: parameters.rotation,
      flipHorizontally: parameters.flip
    )
    let straightenedMask = PerspectiveTransform.rotate(
      orientedMask, clockwiseDegrees: -parameters.straightenAngle)
    let finalMask =
      parameters.manualCrop.flatMap {
        PerspectiveTransform.crop(straightenedMask, canvasRect: $0)
      } ?? straightenedMask
    let displayMask = UInt16Image(
      width: finalMask.width,
      height: finalMask.height,
      channels: mask.channels,
      pixels: finalMask.pixels.map { $0 == 0 ? 0 : UInt16.max }
    )
    guard !Task.isCancelled else { return (nil, 0) }
    let cgImage = displayMask.makePreviewCGImage()
    let detected = mask.pixels.reduce(into: 0) { count, value in
      if value != 0 { count += 1 }
    }
    return (cgImage, detected)
  }

  func clearDustMask() {
    resetDustState(cancelTask: true)
  }

  var dustBrushSourceWidth: Int {
    sourcePixelDimensions?.width ?? previewSource?.width ?? 1
  }

  /// The overlay must wait for the unframed source raster when opening from a
  /// cropped or oriented view. Subsequent color/repair renders keep it usable.
  var isDustCanvasReady: Bool {
    guard isDustEditing, !isDustRepairRunning, let source = previewSource,
      let published = publishedPreviewParameters,
      previewImage?.size == NSSize(width: source.width, height: source.height)
    else { return false }
    return published.cropRect == nil && published.perspectiveCrop == nil
      && published.manualCrop == nil && published.rotation == 0 && !published.flip
      && published.borderCrop == 0 && abs(published.straightenAngle) < 0.000_001
  }

  func beginDustEditing() {
    guard previewSource != nil, !isDustEditing else { return }
    endEditingGesture()
    isDustEditing = true
    showDustRepairs = true
    showOriginal = false
    resetDustState(cancelTask: true)
    scheduleRender(immediate: true)
  }

  func endDustEditing() {
    guard isDustEditing else { return }
    endEditingGesture()
    isDustEditing = false
    showDustRepairs = true
    resetDustState(cancelTask: true)
    scheduleRender(immediate: true)
  }

  func paintDustMask(points: [SIMD2<Double>], radius: Double, erasing: Bool) {
    guard isDustEditing, let source = previewSource else { return }
    cancelDustMaskRepair()
    cancelDustDetection()
    let bound = source.resizedToFit(maxDimension: 2_048)
    let mask =
      dustSourceMask
      ?? UInt16Image(
        width: bound.width, height: bound.height, channels: 1,
        pixels: [UInt16](repeating: 0, count: bound.width * bound.height))
    dustSourceMask = DustMaskEditing.painting(
      mask, points: points, radius: radius, erasing: erasing)
    refreshDustMaskDisplay()
    dustStatus = "Mask edited. Repair Mask applies only the marked areas."
  }

  private func refreshDustMaskDisplay() {
    guard showDustMask, let mask = dustSourceMask else {
      dustMaskImage = nil
      return
    }
    let result = Self.makeDustMaskPreview(mask: mask, parameters: previewDisplayParameters)
    dustMaskImage = result.image.map { PreviewBitmap.nsImage(from: $0) }
  }

  @discardableResult
  func addDustRepair(
    points: [SIMD2<Double>], radius: Double, sourcePoint: SIMD2<Double>? = nil
  ) -> Task<Void, Never>? {
    guard isDustEditing, !points.isEmpty, points.count <= DustRepair.maximumPointsPerStroke,
      radius.isFinite, radius > 0, radius <= DustRepair.maximumNormalizedRadius,
      points.allSatisfy({
        $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
      })
    else { return nil }
    guard parameters.dustRepairs.count < DustRepair.maximumStrokeCount else {
      dustStatus = "The repair limit has been reached. Clear unwanted repairs before adding more."
      return nil
    }
    if let sourcePoint {
      guard sourcePoint.x.isFinite, sourcePoint.y.isFinite,
        (0...1).contains(sourcePoint.x), (0...1).contains(sourcePoint.y)
      else { return nil }
      guard let source = previewSource else { return nil }
      let dimensions = [
        PixelDimensions(width: source.width, height: source.height),
        sourcePixelDimensions ?? PixelDimensions(width: source.width, height: source.height),
      ]
      let offset = sourcePoint - points[0]
      guard
        dimensions.allSatisfy({ size in
          let r = max(0.75, radius * Double(size.width))
          let marginX = (r + 0.5) / Double(size.width)
          let marginY = (r + 0.5) / Double(size.height)
          return hypot(offset.x * Double(size.width), offset.y * Double(size.height)) >= r * 2
            && points.allSatisfy { point in
              let donor = point + offset
              return donor.x >= marginX && donor.x <= 1 - marginX
                && donor.y >= marginY && donor.y <= 1 - marginY
            }
        })
      else {
        dustStatus = "Choose a texture source farther from the repair and away from the scan edge."
        return nil
      }
    }
    let stroke = DustRepairStroke(points: points, radius: radius, sourcePoint: sourcePoint)
    guard let source = previewSource,
      DustRepair.canApply(
        strokes: parameters.dustRepairs + [stroke],
        imageWidth: sourcePixelDimensions?.width ?? source.width,
        imageHeight: sourcePixelDimensions?.height ?? source.height)
    else {
      dustStatus =
        "This stroke exceeds the repair budget. Use a smaller brush or clear unwanted repairs."
      return nil
    }
    cancelDustMaskRepair()
    cancelDustDetection()
    let generation = dustRepairGeneration
    let selectedURL = selection
    let sourceGeneration = previewSourceGeneration
    let savedParameters = parameters
    let existingMask = dustSourceMask
    let targetIndex = savedParameters.dustRepairs.count
    let allStrokes = savedParameters.dustRepairs + [stroke]
    isDustRepairRunning = true
    dustStatus = "Checking texture sources…"
    dustRepairTask = Task { [weak self] in
      guard !Task.isCancelled else {
        guard let self, generation == self.dustRepairGeneration else { return }
        self.isDustRepairRunning = false
        self.dustRepairTask = nil
        self.dustStatus = "Repair cancelled. Candidates remain marked."
        return
      }
      let worker = Task.detached(priority: .userInitiated) {
        () -> (stroke: DustRepairStroke?, mask: UInt16Image?) in
        let plannedStroke: DustRepairStroke?
        if stroke.points.count == 1 {
          plannedStroke =
            DustRepair.plannedSinglePointRepairs(
              in: source, strokes: allStrokes, excludingMask: existingMask,
              planningStrokeIndices: [targetIndex]
            ).first?.stroke
        } else {
          // The saved format keeps the existing per-dab automatic policy for
          // paths. Require every dab to render before consuming the whole path.
          guard
            DustRepair.applicableStrokeIndices(
              in: source, strokes: allStrokes, checkingStrokeIndices: [targetIndex]
            ) == [targetIndex]
          else { return (nil, nil) }
          plannedStroke = stroke
        }
        guard let plannedStroke else { return (nil, nil) }
        let remainingMask = existingMask.map {
          DustMaskEditing.consumingRepairFootprints(
            $0, repairs: [plannedStroke], sourceWidth: source.width, sourceHeight: source.height)
        }
        return (plannedStroke, remainingMask)
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self, generation == self.dustRepairGeneration else { return }
      self.isDustRepairRunning = false
      self.dustRepairTask = nil
      guard !Task.isCancelled else {
        self.dustStatus = "Repair cancelled. Candidates remain marked."
        return
      }
      guard self.isDustEditing, self.selection == selectedURL else { return }
      guard self.previewSourceGeneration == sourceGeneration else {
        self.dustStatus = "The scan preview changed. Paint the healing stroke again."
        return
      }
      guard self.parameters == savedParameters, self.dustSourceMask == existingMask else { return }
      guard let plannedStroke = result.stroke else {
        self.dustStatus =
          "No usable texture source found. Candidates remain marked; paint farther from the scan edge or choose another source."
        return
      }
      self.performDiscreteEditingCompletion {
        self.showDustRepairs = true
        self.updateParameters(actionName: "Healing Brush", immediate: true) {
          $0.dustRepairs.append(plannedStroke)
        }
      }
      if let remainingMask = result.mask {
        self.dustSourceMask = remainingMask
        self.refreshDustMaskDisplay()
      }
      self.dustStatus = "Healing stroke saved. Option-click chooses a texture source."
    }
    return dustRepairTask
  }

  @discardableResult
  func repairDustMask() -> Task<Void, Never>? {
    guard isDustEditing, !isDustDetectionRunning, !isDustRepairRunning,
      let mask = dustSourceMask, let source = previewSource
    else { return nil }
    let remaining = DustRepair.maximumStrokeCount - parameters.dustRepairs.count
    guard remaining > 0 else {
      dustStatus = "The repair limit has been reached. Clear unwanted repairs before adding more."
      return nil
    }
    let generation = dustRepairGeneration
    let selectedURL = selection
    let sourceGeneration = previewSourceGeneration
    let savedParameters = parameters
    let existingCount = savedParameters.dustRepairs.count
    let dimensions = sourcePixelDimensions ?? .init(width: source.width, height: source.height)
    isDustRepairRunning = true
    dustStatus = "Checking texture sources…"
    dustRepairTask = Task { [weak self] in
      guard !Task.isCancelled else {
        guard let self, generation == self.dustRepairGeneration else { return }
        self.isDustRepairRunning = false
        self.dustRepairTask = nil
        self.dustStatus = "Repair cancelled. Candidates remain marked."
        return
      }
      let worker = Task.detached(priority: .userInitiated) {
        () -> (repairs: [DustRepairStroke], mask: UInt16Image?, status: String) in
        let candidates = DustRepair.automaticRepairCandidates(
          from: mask, maximumCount: min(250, remaining))
        guard !candidates.isEmpty else {
          return ([], nil, "No small isolated spots to repair. Use Healing Brush for larger areas.")
        }
        let allRepairs = savedParameters.dustRepairs + candidates.map(\.stroke)
        guard
          DustRepair.canApply(
            strokes: allRepairs, imageWidth: dimensions.width, imageHeight: dimensions.height)
        else {
          return (
            [], nil,
            "These spots exceed the repair budget. Erase unwanted candidates or clear old repairs."
          )
        }
        let plans = DustRepair.plannedSinglePointRepairs(
          in: source, strokes: allRepairs, excludingMask: mask)
        let accepted = plans.filter { $0.strokeIndex >= existingCount }.map { plan in
          MaskRepairCandidate(
            stroke: plan.stroke, maskSeed: candidates[plan.strokeIndex - existingCount].maskSeed)
        }
        guard !accepted.isEmpty else {
          return (
            [], nil,
            "No usable texture sources found. Candidates remain marked; use Healing Brush to choose a source."
          )
        }
        return (
          accepted.map(\.stroke),
          DustMaskEditing.consumingComponents(mask, candidates: accepted),
          "Saved \(accepted.count) masked spot repairs. Unprocessed candidates remain marked; check the result at 100%."
        )
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self, generation == self.dustRepairGeneration else { return }
      self.isDustRepairRunning = false
      self.dustRepairTask = nil
      guard !Task.isCancelled else {
        self.dustStatus = "Repair cancelled. Candidates remain marked."
        return
      }
      guard self.isDustEditing, self.selection == selectedURL else { return }
      guard self.previewSourceGeneration == sourceGeneration else {
        self.dustStatus = "The scan preview changed. Run Auto Repair Mask again."
        return
      }
      guard self.parameters == savedParameters else { return }
      guard !result.repairs.isEmpty, let remainingMask = result.mask else {
        self.dustStatus = result.status
        return
      }
      self.performDiscreteEditingCompletion {
        self.showDustRepairs = true
        self.updateParameters(actionName: "Repair Dust Mask", immediate: true) {
          $0.dustRepairs.append(contentsOf: result.repairs)
        }
      }
      self.dustSourceMask = remainingMask
      self.refreshDustMaskDisplay()
      self.dustStatus = result.status
    }
    return dustRepairTask
  }

  func clearDustRepairs() {
    guard !parameters.dustRepairs.isEmpty else { return }
    updateParameters(actionName: "Clear Dust Repairs", immediate: true) { $0.dustRepairs = [] }
  }

  func dustStrokeLimitReached() {
    dustStatus = "The stroke is too long. Paint shorter strokes; this stroke was not saved."
  }

  func clearCrop() {
    let historyBefore = currentEditingSnapshot()
    resetCropState(cancelTask: true)
    resetDustState(cancelTask: true)
    parameters.cropRect = nil
    parameters.perspectiveCrop = nil
    parameters.manualCrop = nil
    saveParameters()
    scheduleRender(immediate: true)
    recordCurrentEdit(actionName: "Clear Crop", before: historyBefore)
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
    resetPerspectiveCorners()
  }

  func resetPerspectiveCorners() {
    setPerspectiveCrop(
      PerspectiveCrop(
        topLeft: .init(x: 0.06, y: 0.06),
        topRight: .init(x: 0.94, y: 0.06),
        bottomRight: .init(x: 0.94, y: 0.94),
        bottomLeft: .init(x: 0.06, y: 0.94),
        outputAspectRatio: perspectiveCrop?.outputAspectRatio
      ))
  }

  var perspectiveOutputAspectRatio: CropAspectRatio {
    let ratio = perspectiveCrop?.outputAspectRatio ?? .free
    return parameters.rotation % 2 == 0 ? ratio : ratio.transposed
  }

  func setPerspectiveOutputAspectRatio(_ ratio: CropAspectRatio) {
    guard var crop = perspectiveCrop else { return }
    let sourceRatio = parameters.rotation % 2 == 0 ? ratio : ratio.transposed
    crop.outputAspectRatio = sourceRatio == .free ? nil : sourceRatio
    setPerspectiveCrop(crop)
  }

  func setPerspectiveCrop(_ crop: PerspectiveCrop?) {
    guard let crop else {
      clearPerspectiveCrop()
      return
    }
    guard crop.isValid else {
      cropStatus = "Keep the four corners in clockwise order."
      return
    }
    if crop == perspectiveCrop { return }
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
    resetDustState(cancelTask: true)
    cropRect = nil
    perspectiveCrop = crop
    manualCrop = nil
    parameters.cropRect = nil
    parameters.perspectiveCrop = crop
    parameters.manualCrop = nil
    cropStatus = "Perspective warp is active. Drag corners to align the grid."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    if !isPreviewingSourceGeometry {
      scheduleRender(immediate: true)
    }
    recordCurrentEdit(actionName: "Perspective", before: historyBefore)
  }

  func clearPerspectiveCrop() {
    guard perspectiveCrop != nil || parameters.perspectiveCrop != nil else { return }
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
    resetDustState(cancelTask: true)
    perspectiveCrop = nil
    parameters.perspectiveCrop = nil
    if manualCrop != nil {
      manualCrop = nil
      parameters.manualCrop = nil
    }
    cropStatus = ""
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    if !isPreviewingSourceGeometry {
      scheduleRender(immediate: true)
    }
    recordCurrentEdit(actionName: "Clear Perspective", before: historyBefore)
  }

  func setManualCropAspectRatio(_ ratio: CropAspectRatio) {
    guard parameters.manualCropAspectRatio != ratio,
      let canvas = selectedUncroppedCanvasDimensions
    else { return }
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
    parameters.manualCropAspectRatio = ratio
    if let normalizedRatio = ratio.normalizedRatio(in: canvas) {
      let crop = (manualCrop ?? .fullFrame).fitted(toAspectRatio: normalizedRatio)
      manualCrop = crop
      parameters.manualCrop = crop
      cropStatus = "Manual canvas crop is active."
      resetDustState(cancelTask: true)
    }
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    if !isPreviewingUncroppedCanvas { scheduleRender(immediate: true) }
    recordCurrentEdit(actionName: "Crop Aspect Ratio", before: historyBefore)
  }

  func setManualCrop(_ crop: NormalizedCropRect?) {
    guard var crop else {
      clearManualCrop()
      return
    }
    guard crop.isValid else {
      cropStatus = "Drag a crop box inside the image."
      return
    }
    if let ratio = normalizedManualCropAspectRatio { crop = crop.fitted(toAspectRatio: ratio) }
    if crop == manualCrop { return }
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
    resetDustState(cancelTask: true)
    manualCrop = crop
    parameters.manualCrop = crop
    cropStatus = "Manual canvas crop is active."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    if !isPreviewingUncroppedCanvas {
      scheduleRender(immediate: true)
    }
    recordCurrentEdit(actionName: "Crop", before: historyBefore)
  }

  func beginManualCropEditing() {
    guard !isPreviewingUncroppedCanvas else { return }
    isPreviewingUncroppedCanvas = true
    resetDustState(cancelTask: true)
    scheduleRender(immediate: true)
  }

  func endManualCropEditing() {
    guard isPreviewingUncroppedCanvas else { return }
    isPreviewingUncroppedCanvas = false
    settingsPersistence?.requestFlush()
    resetDustState(cancelTask: true)
    scheduleRender(immediate: true)
  }

  /// Perspective handles and film-base sampling use the oriented source scan.
  /// Ordinary Original comparison keeps all committed geometry instead.
  func beginSourceGeometryEditing() {
    guard !isPreviewingSourceGeometry else { return }
    isPreviewingSourceGeometry = true
    resetDustState(cancelTask: true)
    scheduleRender(immediate: true)
  }

  func endSourceGeometryEditing() {
    guard isPreviewingSourceGeometry else { return }
    isPreviewingSourceGeometry = false
    settingsPersistence?.requestFlush()
    resetDustState(cancelTask: true)
    scheduleRender(immediate: true)
  }

  func cropCurrentCanvas(to crop: NormalizedCropRect) {
    guard let existing = manualCrop else {
      setManualCrop(crop)
      return
    }
    setManualCrop(
      NormalizedCropRect(
        x: existing.x + crop.x * existing.width,
        y: existing.y + crop.y * existing.height,
        width: crop.width * existing.width,
        height: crop.height * existing.height))
  }

  func clearManualCrop() {
    guard manualCrop != nil || parameters.manualCrop != nil else { return }
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
    resetDustState(cancelTask: true)
    manualCrop = nil
    parameters.manualCrop = nil
    cropStatus = ""
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    if !isPreviewingUncroppedCanvas {
      scheduleRender(immediate: true)
    }
    recordCurrentEdit(actionName: "Clear Crop", before: historyBefore)
  }

  func setStraightenAngle(_ angle: Double) {
    guard angle.isFinite else { return }
    let clamped = min(max(angle, -45), 45)
    guard abs(parameters.straightenAngle - clamped) > 0.000_001 else { return }
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
    resetDustState(cancelTask: true)
    manualCrop = nil
    parameters.manualCrop = nil
    parameters.straightenAngle = clamped
    straightenAngle = clamped
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
    recordCurrentEdit(actionName: "Straighten", before: historyBefore)
  }

  func clearStraightening() {
    setStraightenAngle(0)
  }

  func straighten(usingGuideDeviation deviation: Double) {
    guard deviation.isFinite else { return }
    setStraightenAngle(straightenAngle + deviation)
  }

  func setDarkThreshold(_ value: Int) {
    updateParameters(actionName: "Dark Threshold") { $0.darkThreshold = value }
  }

  func setLightThreshold(_ value: Int) {
    updateParameters(actionName: "Light Threshold") { $0.lightThreshold = value }
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

  private func cancelCropDetection(status: String = "") {
    cropDetectionGeneration += 1
    cropDetectionTask?.cancel()
    cropDetectionTask = nil
    if isCropDetectionRunning {
      cropThresholdPreview = nil
      cropStatus = status
    }
    isCropDetectionRunning = false
  }

  private func finishCancelledCropDetection(generation: Int) {
    guard generation == cropDetectionGeneration else { return }
    cropDetectionTask = nil
    isCropDetectionRunning = false
    cropStatus = "Frame detection cancelled."
  }

  nonisolated private static func cropDetectionInputsChanged(
    from previous: ProcessingParameters, to next: ProcessingParameters
  ) -> Bool {
    previous.darkThreshold != next.darkThreshold || previous.lightThreshold != next.lightThreshold
      || previous.cropRect != next.cropRect
      || previous.cropRectCoordinateSpace != next.cropRectCoordinateSpace
      || previous.perspectiveCrop != next.perspectiveCrop || previous.manualCrop != next.manualCrop
      || previous.manualCropAspectRatio != next.manualCropAspectRatio
      || previous.straightenAngle != next.straightenAngle
      || previous.rotation != next.rotation || previous.flip != next.flip
  }

  private func resetCropState(cancelTask: Bool) {
    if cancelTask { cancelCropDetection() }
    cropRect = nil
    perspectiveCrop = nil
    manualCrop = nil
    cropThresholdPreview = nil
    isCropDetectionRunning = false
    cropStatus = ""
  }

  private func resetDustState(cancelTask: Bool) {
    if cancelTask {
      cancelDustMaskRepair()
      cancelDustDetection()
    }
    dustMaskImage = nil
    dustSourceMask = nil
    isDustDetectionRunning = false
    dustStatus = ""
  }

  private func cancelDustDetection() {
    dustDetectionGeneration += 1
    dustDetectionTask?.cancel()
    dustDetectionTask = nil
    isDustDetectionRunning = false
  }

  private func finishCancelledDustDetection(generation: Int) {
    guard generation == dustDetectionGeneration else { return }
    dustDetectionTask = nil
    isDustDetectionRunning = false
    dustStatus = "Dust detection cancelled."
  }

  private func cancelDustMaskRepair() {
    dustRepairGeneration += 1
    dustRepairTask?.cancel()
    dustRepairTask = nil
    isDustRepairRunning = false
  }

  private func applyCrop(_ rect: RotatedRect, render: Bool) {
    let historyBefore = currentEditingSnapshot()
    cancelCropDetection()
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
    recordCurrentEdit(actionName: "Detect Frame", before: historyBefore)
  }

  nonisolated private static func unityFlatField(for image: UInt16Image) -> UInt16Image {
    let count = image.width * image.height * image.channels
    let pixels = [UInt16](repeating: 65535, count: count)
    return UInt16Image(
      width: image.width, height: image.height, channels: image.channels,
      pixels: pixels)
  }

  private func exportFiles(_ urls: [URL]) {
    guard flatFieldLoadTask == nil else {
      setStatus("Wait for flat-field loading to finish before exporting.")
      return
    }
    guard !isExporting, !urls.isEmpty else { return }
    guard !isBuildingScanStack else {
      setStatus(
        "Wait for the aligned stack preview to finish before exporting.",
        kind: .error)
      return
    }
    guard !isLoading else {
      setStatus(
        "Wait for the active preview decode to finish before exporting.",
        kind: .error)
      return
    }
    // Export has priority over speculative lookahead work. The decoder may
    // finish its current synchronous call, but cancellation prevents it from
    // advancing through the rest of the lookahead queue.
    cancelPredecode()
    cancelScanStackUpgradePreservingPreview()

    let exportParams = exportParameters
    activeExportQueue = urls
    exportQueueCount = max(0, urls.count - 1)
    do {
      activeExportDestinations = try reserveDestinationURLs(
        for: urls, destinationDirectory: exportParams.destinationDirectory,
        format: exportParams.format)
      activeExportItemParameters = activeExportDestinations.map { destination in
        var resolvedParameters = exportParams
        resolvedParameters.destinationDirectory = destination.deletingLastPathComponent()
        return resolvedParameters
      }
    } catch {
      setStatus(
        "Unable to inspect export destination: \(error.localizedDescription)",
        kind: .error)
      activeExportQueue = []
      activeExportItemParameters = []
      activeExportCorrelationIDs = []
      activeExportQueueWaitIntervals = []
      exportQueueCount = 0
      return
    }
    activeExportCorrelationIDs = urls.map { _ in UUID().uuidString }
    activeExportQueueWaitIntervals = zip(urls, activeExportCorrelationIDs).map {
      url, correlationID in
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
    setStatus("Exporting...")

    exportTask = Task { [weak self] in
      guard let self else { return }
      await self.processExportQueue(initialCapacity: urls.count)
    }
  }

  private func processExportQueue(initialCapacity: Int) async {
    let manager = ExportManager()
    var results: [ExportManager.ExportResult] = []
    results.reserveCapacity(initialCapacity)

    var index = 0
    while index < activeExportQueue.count {
      if Task.isCancelled {
        for remainingIndex in index..<activeExportQueue.count {
          results.append(
            ExportManager.ExportResult(
              sourceURL: activeExportQueue[remainingIndex],
              destinationURL: activeExportDestinations[remainingIndex],
              error: ExportManager.ExportManagerError.cancelled
            ))
        }
        break
      }

      let firstURL = activeExportQueue[index]
      await MainActor.run {
        activeExportFilename = firstURL.lastPathComponent
        exportQueueCount = max(0, activeExportQueue.count - index - 1)
      }
      let endIndex = exportBatchEndIndex(startingAt: index)
      let batchResults = await exportBatch(index..<endIndex, using: manager)
      results.append(contentsOf: batchResults)

      index = endIndex
      await MainActor.run {
        exportProgressCurrent = index
        exportProgressTotal = activeExportQueue.count
        exportQueueCount = max(0, activeExportQueue.count - index - 1)
      }
    }
    await MainActor.run {
      self.finishExportQueue(with: results)
    }
  }

  private func exportBatchEndIndex(startingAt startIndex: Int) -> Int {
    let url = activeExportQueue[startIndex]
    let nextIsFullResolutionRAW =
      startIndex + 1 < activeExportQueue.count
      && Self.requiresFullResolutionExportDecode(activeExportQueue[startIndex + 1])
    let currentIsStack = enabledScanStack(containing: url) != nil
    let nextIsStack =
      startIndex + 1 < activeExportQueue.count
      && enabledScanStack(containing: activeExportQueue[startIndex + 1]) != nil
    let batchSize =
      Self.requiresFullResolutionExportDecode(url) || nextIsFullResolutionRAW
        || currentIsStack || nextIsStack
      ? 1 : 2
    return min(startIndex + batchSize, activeExportQueue.count)
  }

  private func exportBatch(
    _ range: Range<Int>, using manager: ExportManager
  ) async -> [ExportManager.ExportResult] {
    var requests: [ExportManager.ExportRequest] = []
    var results: [ExportManager.ExportResult] = []
    for requestIndex in range {
      let url = activeExportQueue[requestIndex]
      let destinationURL = activeExportDestinations[requestIndex]
      let itemParameters = activeExportItemParameters[requestIndex]
      let correlationID = activeExportCorrelationIDs[requestIndex]
      AppPerformanceSignposts.end(activeExportQueueWaitIntervals[requestIndex])
      do {
        requests.append(
          try await makeExportRequest(
            for: url,
            exportParams: itemParameters,
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
    return results
  }

  private func finishExportQueue(with results: [ExportManager.ExportResult]) {
    let wasCancelled = exportWasCancelled || Task.isCancelled
    for interval in activeExportQueueWaitIntervals.dropFirst(
      exportProgressCurrent)
    {
      AppPerformanceSignposts.end(interval)
    }
    isExporting = false
    activeExportFilename = nil
    activeExportQueue = []
    activeExportDestinations = []
    activeExportItemParameters = []
    activeExportCorrelationIDs = []
    activeExportQueueWaitIntervals = []
    exportTask = nil
    exportQueueCount = 0
    let failures = results.filter { !$0.isSuccess }
    if wasCancelled {
      exportErrors = []
      let savedCount = results.filter(\.isSuccess).count
      setStatus(
        "Export cancelled. Saved \(savedCount) of \(exportProgressTotal) images."
      )
    } else if failures.isEmpty {
      let directories = Set(results.map { $0.destinationURL.deletingLastPathComponent() })
      let destinationDescription: String
      if directories.count == 1, let directory = directories.first {
        destinationDescription = "to \(directory.lastPathComponent)"
      } else {
        destinationDescription = "across \(directories.count) folders"
      }
      setStatus(
        "Exported \(results.count) image\(results.count == 1 ? "" : "s") \(destinationDescription)."
      )
    } else {
      exportErrors = failures.compactMap { result in
        result.error.map { "\(result.sourceURL.lastPathComponent): \($0.localizedDescription)" }
      }
      setStatus(
        "Export complete with \(failures.count) error\(failures.count == 1 ? "" : "s").",
        kind: .error)
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

  private func populateFilmNegativeMedians(from image: UInt16Image) {
    guard image.channels == 3 else { return }
    parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
      image: image, borderPercent: 20.0)
  }

  private func applyAutomaticFilmClassification(from image: UInt16Image) {
    let retainsLook = parameters.pendingFilmBaseInitialization == .preservingLook
    parameters = Self.automaticallyClassifiedParameters(
      base: parameters,
      image: image,
      weakPrior: sameRollFilmTypeHint
    )
    if let selection, !retainsLook {
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
    try Task.checkCancellation()
    let key = settingsKey(url)
    let decodeInterval = AppPerformanceSignposts.begin(
      .decode, correlationID: correlationID, filename: url.lastPathComponent)
    let decoded: UInt16Image
    do {
      if let stack = enabledScanStack(containing: url) {
        decoded = try await decodedScanStackForExport(
          stack,
          mode: scanStackMode(for: stack))
      } else {
        decoded = try await decodedImageForExport(url)
      }
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
    var fileParams: ProcessingParameters
    if let stored = settingsByPath[key], stored.pendingFilmBaseInitialization == nil {
      fileParams = stored
    } else {
      let proxy = decoded.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension)
      let automatic = Self.automaticallyClassifiedParameters(
        base: settingsByPath[key] ?? ProcessingParameters(photoAdjustments: .init()),
        image: proxy,
        weakPrior: sameRollFilmTypeHint
      )
      settingsByPath[key] = automatic
      if !editedKeys.contains(key) { automaticallyClassifiedKeys.insert(key) }
      persistSettings(for: key)
      fileParams = automatic
    }
    fileParams = Self.parametersForExport(fileParams, decodedImage: decoded)
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
      let key = settingsKey(url)
      if let cached = retainedExportDecode.image(forKey: key) {
        fullResolutionExportDecodeCacheHits += 1
        return cached
      }
      let decoder = fullResolutionExportDecoder
      let gate = rawDecodeScheduler
      let image = try await gate.run(priority: .export) {
        if let decoder {
          return try decoder(url)
        }
        return try RawImageDecoder.decode(
          url,
          fullResolution: true,
          profile: .rawTherapeeCameraScan
        ).image
      }
      fullResolutionExportDecodeCount += 1
      retainedExportDecode.retain(
        key: key,
        image: image,
        selectedKey: selection.map(settingsKey)
      )
      return image
    }
    let decoder = standardImageExportDecoder
    return try await Task.detached(priority: .userInitiated) {
      try decoder?(url) ?? Self.decodeImage(url)
    }.value
  }

  private func decodedScanStackForExport(
    _ stack: DetectedScanStack,
    mode: ScanStackMode
  ) async throws -> UInt16Image {
    scanStackStatusID = stack.id
    let result = try await combinedFullResolutionStack(stack: stack, mode: mode, forExport: true)
    scanStackStatus =
      "Built full-resolution \(Self.scanStackModeLabel(result.effectiveMode)) stack from \(stack.members.count) captures."
    return result.image
  }

  nonisolated static func requiresFullResolutionExportDecode(_ url: URL) -> Bool {
    FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
  }

  /// Preview calibration may come from a bounded RAW draft or another proxy.
  /// Re-measure the film base in the pixels that export will actually process
  /// so a lower-resolution preview cannot contaminate the full-resolution
  /// correction.
  nonisolated static func parametersForExport(
    _ parameters: ProcessingParameters,
    decodedImage: UInt16Image
  ) -> ProcessingParameters {
    let usesAdaptiveNegativeReference =
      !parameters.densityPipelineEnabled
      && (parameters.filmType == .colourNegative
        || parameters.filmType == .blackAndWhiteNegative)
      && parameters.filmNegativeParams.enabled
    guard usesAdaptiveNegativeReference, decodedImage.channels == 3 else {
      return parameters
    }
    var exportParameters = parameters
    let analysisImage = decodedImage.resizedToFit(maxDimension: analysisPreviewMaxDimension)
    exportParameters.filmNegativeParams.measuredMedians =
      FilmNegativeProcessing.computeMedians(image: analysisImage, borderPercent: 20.0)
    return exportParameters
  }

  private func reserveDestinationURLs(
    for urls: [URL],
    destinationDirectory: URL?,
    format: ExportFormat,
    alreadyReserved: [URL] = []
  ) throws -> [URL] {
    var reservedNamesByDirectory: [URL: Set<String>] = [:]
    return try urls.map { sourceURL in
      let directory = (destinationDirectory ?? sourceURL.deletingLastPathComponent())
        .standardizedFileURL
      let directoryKey = directory.resolvingSymlinksInPath()
      if reservedNamesByDirectory[directoryKey] == nil {
        // Foundation's URL enumerator can reject a directory symlink itself.
        // Inspect the same physical folder used to share name reservations.
        let existingNames = try FileManager.default.contentsOfDirectory(
          at: directoryKey,
          includingPropertiesForKeys: nil
        ).map { $0.lastPathComponent.lowercased() }
        var reservedNames = Set(existingNames)
        reservedNames.formUnion(
          alreadyReserved
            .filter {
              $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                == directoryKey
            }
            .map { $0.lastPathComponent.lowercased() })
        reservedNamesByDirectory[directoryKey] = reservedNames
      }
      let stem = sourceURL.deletingPathExtension().lastPathComponent
      let ext = format.fileExtension
      var suffix = 1
      var filename = "\(stem).\(ext)"
      while reservedNamesByDirectory[directoryKey, default: []].contains(filename.lowercased()) {
        suffix += 1
        filename = "\(stem)-\(suffix).\(ext)"
      }
      reservedNamesByDirectory[directoryKey, default: []].insert(filename.lowercased())
      return directory.appendingPathComponent(filename)
    }
  }

  nonisolated static func automaticallyClassifiedParameters(
    base: ProcessingParameters,
    image: UInt16Image,
    weakPrior: FilmType? = nil
  ) -> ProcessingParameters {
    FilmBase.automaticallyClassifiedParameters(base: base, image: image, weakPrior: weakPrior)
  }

  func editingGestureChanged(_ actionName: String, isEditing: Bool) {
    if isEditing {
      beginEditingGesture(named: actionName)
    } else {
      endEditingGesture()
    }
  }

  func beginEditingGesture(named actionName: String) {
    guard let selection else { return }
    let key = settingsKey(selection)
    if let transaction = editTransaction {
      guard transaction.key != key || transaction.actionName != actionName else { return }
      endEditingGesture()
    }
    editTransaction = EditTransaction(
      key: key,
      actionName: actionName,
      before: editingSnapshot(for: key)
    )
    previewInteractionTrace?.record(.gestureBegan)
  }

  func endEditingGesture() {
    finishEditingGesture(refiningPreview: true)
  }

  private func finishEditingGesture(refiningPreview: Bool) {
    // This also flushes keyboard/text edits when selection or editor changes.
    settingsPersistence?.requestFlush()
    guard let transaction = editTransaction else { return }
    previewInteractionTrace?.record(.gestureEnded)
    editTransaction = nil
    recordEdit(
      for: transaction.key,
      actionName: transaction.actionName,
      before: transaction.before,
      after: editingSnapshot(for: transaction.key)
    )
    refreshHistoryAvailability()
    guard refiningPreview else { return }
    if continuousEditPreviewNeedsRefinement {
      continuousEditPreviewNeedsRefinement = false
      scheduleRender(immediate: true)
    } else if !isRendering, previewStatisticsRevision != publishedRenderRevision,
      let publishedStatisticsRequest
    {
      // A complete raster already has the final pixels. Refresh throttled
      // diagnostics directly; an in-flight render will submit its own sample.
      enqueuePreviewStatistics(publishedStatisticsRequest)
    }
    if let selection, !isLoading { schedulePreviewWork(after: selection) }
  }

  /// Keep a completed worker's discrete edit separate from an ongoing drag.
  /// Rebase the drag afterward so its remaining samples still coalesce, while
  /// the completion's own render replaces the intermediate refinement work.
  private func performDiscreteEditingCompletion(_ completion: () -> Void) {
    let continuingGesture = editTransaction
    if continuingGesture != nil { finishEditingGesture(refiningPreview: false) }
    completion()
    if let continuingGesture, selection.map(settingsKey) == continuingGesture.key {
      beginEditingGesture(named: continuingGesture.actionName)
    }
  }

  func undo() {
    endEditingGesture()
    guard let selection else { return }
    let key = settingsKey(selection)
    guard var history = editHistories[key], let entry = history.undo() else { return }
    editHistories[key] = history
    applyEditingSnapshot(
      entry.before,
      for: key,
      restoresOutputFraming: Self.isOutputFramingAction(entry.actionName)
    )
    settingsStatus = "Undid \(entry.actionName)."
    refreshHistoryAvailability()
  }

  func redo() {
    endEditingGesture()
    guard let selection else { return }
    let key = settingsKey(selection)
    guard var history = editHistories[key], let entry = history.redo() else { return }
    editHistories[key] = history
    applyEditingSnapshot(
      entry.after,
      for: key,
      restoresOutputFraming: Self.isOutputFramingAction(entry.actionName)
    )
    settingsStatus = "Redid \(entry.actionName)."
    refreshHistoryAvailability()
  }

  private func currentEditingSnapshot() -> EditingSnapshot? {
    guard let selection else { return nil }
    return editingSnapshot(for: settingsKey(selection))
  }

  private func editingSnapshot(for key: String) -> EditingSnapshot {
    let snapshotParameters: ProcessingParameters
    if selection.map(settingsKey) == key {
      var selectedParameters = parameters
      if settingsByPath[key] == nil, isLoading {
        // Before the first decode, Original is only a canvas placeholder. Undo
        // must restore automatic classification once source pixels are available.
        selectedParameters.pendingFilmBaseInitialization = .automatic
      }
      snapshotParameters = selectedParameters
    } else {
      snapshotParameters =
        settingsByPath[key]
        ?? ProcessingParameters(
          pendingFilmBaseInitialization: .automatic, photoAdjustments: .init())
    }
    return EditingSnapshot(
      parameters: snapshotParameters,
      framePercent: exportParameters.framePercent,
      aspectRatio: exportParameters.aspectRatio,
      wasEdited: editedKeys.contains(key),
      wasAutomaticallyClassified: automaticallyClassifiedKeys.contains(key)
    )
  }

  private func recordCurrentEdit(
    actionName: String,
    before: EditingSnapshot?
  ) {
    guard let selection, let before else { return }
    let key = settingsKey(selection)
    guard editTransaction?.key != key else { return }
    recordEdit(
      for: key,
      actionName: actionName,
      before: before,
      after: editingSnapshot(for: key)
    )
    refreshHistoryAvailability()
  }

  private func recordEdit(
    for key: String,
    actionName: String,
    before: EditingSnapshot,
    after: EditingSnapshot
  ) {
    var history = editHistories[key] ?? EditHistory(limit: 100)
    history.record(actionName: actionName, before: before, after: after)
    editHistories[key] = history
  }

  private func applyEditingSnapshot(
    _ snapshot: EditingSnapshot,
    for key: String,
    restoresOutputFraming: Bool
  ) {
    guard selection.map(settingsKey) == key else { return }
    cancelCropDetection()
    resetDustState(cancelTask: true)
    // History restores edits, not editor lifetime. Crop and Straighten keep
    // their overlays open, so their canvas must stay uncropped until Done.
    parameters = snapshot.parameters
    cropRect = snapshot.parameters.cropRect
    perspectiveCrop = snapshot.parameters.perspectiveCrop
    manualCrop = snapshot.parameters.manualCrop
    straightenAngle = snapshot.parameters.straightenAngle
    if restoresOutputFraming {
      exportParameters.framePercent = snapshot.framePercent
      exportParameters.aspectRatio = snapshot.aspectRatio
    }

    if snapshot.wasEdited {
      editedKeys.insert(key)
    } else {
      editedKeys.remove(key)
    }
    if snapshot.wasAutomaticallyClassified {
      automaticallyClassifiedKeys.insert(key)
    } else {
      automaticallyClassifiedKeys.remove(key)
    }

    if parameters.pendingFilmBaseInitialization != nil, let source = previewSource {
      applyAutomaticFilmClassification(
        from: source.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension))
    } else {
      saveParameters()
    }
    renderAfterEditing()
  }

  private func refreshHistoryAvailability() {
    guard let selection else {
      undoActionName = nil
      redoActionName = nil
      return
    }
    let history = editHistories[settingsKey(selection)]
    undoActionName = history?.undoActionName
    redoActionName = history?.redoActionName
  }

  nonisolated private static func isOutputFramingAction(_ actionName: String) -> Bool {
    actionName == "Border" || actionName == "Aspect Ratio"
  }

  private func updateParameters(
    actionName: String,
    immediate: Bool = false,
    _ update: (inout ProcessingParameters) -> Void
  ) {
    let interactionStart = ContinuousClock.now
    previewInteractionTrace?.record(.setterBegan, interactionStart: interactionStart)
    var next = parameters
    update(&next)
    guard next != parameters else {
      if showOriginal && !isPreviewingSourceGeometry { showOriginal = false }
      return
    }
    let historyBefore = currentEditingSnapshot()
    if Self.cropDetectionInputsChanged(from: parameters, to: next) {
      cancelCropDetection()
    }
    resetDustState(cancelTask: true)
    if let selection {
      automaticallyClassifiedKeys.remove(settingsKey(selection))
      editedKeys.insert(settingsKey(selection))
    }
    parameters = next
    saveParameters()
    renderAfterEditing(immediate: immediate, interactionStart: interactionStart)
    recordCurrentEdit(actionName: actionName, before: historyBefore)
  }

  private func renderAfterEditing(
    immediate: Bool = true, interactionStart: ContinuousClock.Instant? = nil
  ) {
    pendingInteractionStart = interactionStart
    // Edits reveal the corrected result during ordinary comparison. Perspective
    // and film-base tools still need original pixels until their overlays close.
    if showOriginal && !isPreviewingSourceGeometry {
      showOriginal = false
    } else {
      scheduleRender(immediate: immediate)
    }
  }

  private func saveParameters() {
    guard let selection else {
      return
    }
    let key = settingsKey(selection)
    settingsByPath[key] = parameters
    persistSettings(for: key)
    EditLog.parametersSaved(path: selection.lastPathComponent, parameters: parameters)
  }

  private func persistSettings(for key: String) {
    guard let parameters = settingsByPath[key] else {
      settingsPersistence?.submit(.remove(path: key))
      return
    }
    settingsPersistence?.submit(
      .set(path: key, parameters: parameters, edited: editedKeys.contains(key)))
  }

  func handleSettingsPersistenceCompletion(revision: UInt64, result: Result<Void, Error>) {
    guard revision >= latestSettingsCompletionRevision else { return }
    latestSettingsCompletionRevision = revision
    let message = "Corrections changed, but could not be saved for the next launch."
    switch result {
    case .success:
      latestSavedSettingsRevision = max(latestSavedSettingsRevision, revision)
      if settingsStatus == message { settingsStatus = "" }
      if status == message { setStatus("Corrections saved.") }
    case .failure:
      // A retry can succeed at the same revision. A late callback from its
      // earlier failed attempt must not restore the error after that success.
      guard revision > latestSavedSettingsRevision else { return }
      settingsStatus = message
      setStatus(message, kind: .error)
    }
  }

  /// Used by orderly termination and relaunch tests. Include any edits received
  /// while a write was in flight before letting the app close.
  func flushSettings() async throws {
    endEditingGesture()
    repeat {
      try await settingsPersistence?.flush()
      try await openRollPersistence?.flush()
    } while settingsPersistence?.hasUnsavedChanges == true
      || openRollPersistence?.hasUnsavedChanges == true
  }

  private func applyCachedSession(_ session: CachedPreviewSession, selection: URL) {
    applyPreviewSession(
      session, selection: selection,
      hasStoredSettings: settingsByPath[settingsKey(selection)] != nil,
      recalibrateFromSource: previewCache.renderedPreview(forKey: settingsKey(selection)) == nil
        || parameters.filmNegativeParams.measuredMedians == nil)
    scheduleRender(immediate: true)
  }

  private func applyPreviewSession(
    _ session: CachedPreviewSession,
    selection: URL,
    hasStoredSettings: Bool,
    recalibrateFromSource: Bool = true
  ) {
    if let current = previewSourceKind,
      session.sourceKind.qualityRank < current.qualityRank
    {
      return
    }
    // Compatibility for feature gates while they migrate to explicit preview
    // requirements. This is never consulted by export.
    decodedImage = session.displaySource
    previewSource = session.displaySource
    cpuPreviewPreparation = session.cpuPreviewPreparation
    previewRenderer = session.previewRenderer
    continuousEditPreviewSource = session.continuousEditSource
    continuousEditCPUPreparation = session.continuousEditCPUPreparation
    continuousEditPreviewRenderer = session.continuousEditRenderer
    continuousEditPreviewNeedsRefinement = false
    previewSourceKind = session.sourceKind
    loadedPreviewKey = settingsKey(selection)
    sourcePixelDimensions = session.sourcePixelDimensions
    isLoading = false
    if session.sourceKind == .rawFull {
      isUpgradingRawPreview = false
    }
    if let current = settingsByPath[settingsKey(selection)] { parameters = current }
    if hasStoredSettings, parameters.pendingFilmBaseInitialization == nil {
      if recalibrateFromSource, displayedRetainedCanvas == nil {
        populateFilmNegativeMedians(from: session.analysisSource)
        // Keep the saved settings in step with the displayed tier. Otherwise a
        // cache hit restores draft medians and unnecessarily changes the image.
        saveParameters()
      }
    } else {
      applyAutomaticFilmClassification(from: session.analysisSource)
    }
    scheduleEnabledScanStackPreview(for: selection)
  }

  private func schedulePreviewWork(after selection: URL, skipInspect: Bool = false) {
    guard !isExporting, !isUnderPreviewMemoryPressure else { return }
    guard files.contains(selection), predecodeTask == nil else { return }

    let selectedKey = settingsKey(selection)
    let isRaw = FileDropPolicy.rawExtensions.contains(selection.pathExtension.lowercased())
    let currentRank =
      previewCache[selectedKey]?.sourceKind.qualityRank
      ?? previewSourceKind?.qualityRank
      ?? 0
    let blockedByStack =
      previewSourceKind == .alignedStack
      || enabledScanStack(containing: selection) != nil
    // A 3200px lookahead hit is already sharp enough to skip the 4000px inspect
    // decode so the selected-file full-res pass can start immediately.
    let needsSelectedInspect =
      isRaw && !blockedByStack && !skipInspect
      && displayedRetainedCanvas == nil
      && currentRank < PreviewSourceKind.rawDetail.qualityRank
    let needsSelectedFullRes =
      isRaw && !blockedByStack && currentRank < PreviewSourceKind.rawFull.qualityRank
    let lookahead = Self.previewLookahead(
      files: files, selected: selection, cacheLimit: previewCacheLimit)
    guard needsSelectedInspect || needsSelectedFullRes || !lookahead.isEmpty else {
      return
    }

    let generation = loadGeneration
    predecodeTask?.cancel()
    previewWorkRevision += 1
    let workRevision = previewWorkRevision
    if needsSelectedInspect || needsSelectedFullRes {
      isUpgradingRawPreview = true
    }

    predecodeTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == self.loadGeneration, workRevision == self.previewWorkRevision {
          self.isUpgradingRawPreview = false
          self.predecodeTask = nil
        }
      }
      if needsSelectedInspect {
        await self.decodeAndCacheRawInspect(selection, generation: generation)
      }
      guard !Task.isCancelled, generation == self.loadGeneration else { return }
      if needsSelectedFullRes {
        async let fullWork: Void = self.decodeAndCacheRawFull(
          selection, generation: generation)
        async let lookaheadWork: Void = self.prefetchLookahead(
          lookahead, generation: generation)
        _ = await (fullWork, lookaheadWork)
      } else {
        await self.prefetchLookahead(lookahead, generation: generation)
      }
      await self.prefetchFullPreviews(lookahead, generation: generation)
    }
  }

  private func prefetchLookahead(_ urls: [URL], generation: Int) async {
    for url in urls {
      guard !Task.isCancelled, generation == loadGeneration else { return }
      await decodeAndCachePreviewTier(
        url, generation: generation, applyIfSelected: true)
    }
  }

  private func prefetchFullPreviews(_ urls: [URL], generation: Int) async {
    // Sharp previews first; then spend idle time on up to two full-sensor
    // neighbours. Admission never displaces a completed, visited full preview.
    for url in urls.prefix(2) {
      guard !Task.isCancelled, generation == loadGeneration else { return }
      guard canPrefetchFullPreview(for: url) else { continue }
      await decodeAndCacheRawFull(url, generation: generation, speculative: true)
    }
  }

  private func canPrefetchFullPreview(for url: URL) -> Bool {
    let key = settingsKey(url)
    guard !isUnderPreviewMemoryPressure, !isExporting,
      enabledScanStack(containing: url) == nil,
      let session = previewCache[key], session.sourceKind != .rawFull,
      let size = session.sourcePixelDimensions
    else { return false }
    // UInt16 RGB + RGBA16 renderer + RGBA8 display, plus the 2048px edit proxy.
    let estimate = size.width * size.height * 18 + 64 * 1_024 * 1_024
    return previewCache.canAdmitSession(
      forKey: key, estimatedByteCount: estimate, limits: previewCacheLimits)
  }

  private func decodeAndCacheRawInspect(
    _ url: URL,
    generation: Int
  ) async {
    guard FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) else { return }
    if let existing = previewCache[settingsKey(url)]?.sourceKind,
      existing.qualityRank >= PreviewSourceKind.rawInspect.qualityRank
    {
      return
    }
    if selection == url, enabledScanStack(containing: url) != nil { return }

    let decodeHook = rawInspectDecodeHook
    let sessionDecoder = rawPreviewSessionDecoder
    do {
      let session = try await rawDecodeScheduler.run {
        try decodeHook?()
        if let sessionDecoder { return try sessionDecoder(url, .rawInspect) }
        return try Self.makeRawPreviewSession(
          for: url,
          maxDimension: Self.rawInspectPreviewMaxDimension,
          kind: .rawInspect)
      }
      guard !Task.isCancelled, generation == loadGeneration else { return }
      cacheSession(session, for: url)
      guard generation == loadGeneration, selection == url,
        enabledScanStack(containing: url) == nil
      else { return }
      applyPreviewSession(
        session,
        selection: url,
        hasStoredSettings: settingsByPath[settingsKey(url)] != nil,
        recalibrateFromSource: !editedKeys.contains(settingsKey(url)))
      scheduleRender(immediate: true)
    } catch is CancellationError {
      return
    } catch {
      ImportLog.loadSelectionDecodeFailed(
        path: "RAW inspect \(url.lastPathComponent)", error: error.localizedDescription)
      if generation == loadGeneration, selection == url {
        setStatus(
          "Unable to load inspect RAW preview: \(error.localizedDescription)",
          kind: .error)
      }
    }
  }

  private func decodeAndCacheRawFull(
    _ url: URL,
    generation: Int,
    speculative: Bool = false
  ) async {
    guard FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) else { return }
    if previewCache[settingsKey(url)]?.sourceKind == .rawFull { return }
    if selection == url, enabledScanStack(containing: url) != nil { return }
    let gate = rawDecodeScheduler
    let sessionDecoder = rawPreviewSessionDecoder
    do {
      let session = try await gate.run(priority: speculative ? .lookahead : .selected) {
        if let sessionDecoder { return try sessionDecoder(url, .rawFull) }
        return try Self.makeRawFullPreviewSession(for: url)
      }
      guard !Task.isCancelled, generation == loadGeneration,
        enabledScanStack(containing: url) == nil
      else { return }
      fullResolutionPreviewDecodeCount += 1
      cacheSession(session, for: url, speculative: speculative)
      guard selection == url else { return }
      applyPreviewSession(
        session,
        selection: url,
        hasStoredSettings: settingsByPath[settingsKey(url)] != nil,
        recalibrateFromSource: !editedKeys.contains(settingsKey(url)))
      scheduleRender(immediate: true)
    } catch is CancellationError {
      return
    } catch {
      ImportLog.loadSelectionDecodeFailed(
        path: "RAW full preview \(url.lastPathComponent)", error: error.localizedDescription)
      if generation == loadGeneration, selection == url {
        setStatus(
          "Unable to load full-resolution RAW preview: \(error.localizedDescription)",
          kind: .error)
      }
    }
  }

  private func decodeAndCachePreviewTier(
    _ url: URL,
    generation: Int,
    applyIfSelected: Bool
  ) async {
    let isRaw = FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
    let desiredKind: PreviewSourceKind = isRaw ? .rawDetail : .standardThumbnail
    let key = settingsKey(url)
    if let existing = previewCache[key], existing.sourceKind.qualityRank >= desiredKind.qualityRank
    {
      return
    }
    if selection == url, enabledScanStack(containing: url) != nil { return }

    if selection != url {
      // Speculation cannot evict retained previews. Skip work that cannot fit
      // even before allocating its source; exact byte admission still follows
      // decoding because CFA binning determines the actual preview dimensions.
      guard !isUnderPreviewMemoryPressure, !isExporting,
        previewCache.canAdmitSession(forKey: key, limits: previewCacheLimits)
      else { return }
    }

    let sessionDecoder = rawPreviewSessionDecoder
    do {
      lookaheadPreviewRequestCount += 1
      let session = try await rawDecodeScheduler.run(priority: .lookahead) {
        () -> CachedPreviewSession in
        if isRaw {
          if let sessionDecoder { return try sessionDecoder(url, desiredKind) }
          return try Self.makeRawPreviewSession(
            for: url,
            maxDimension: Self.rawDetailPreviewMaxDimension,
            kind: desiredKind)
        }
        return try Self.makeFastPreviewSession(for: url)
      }
      guard !Task.isCancelled, generation == loadGeneration else { return }
      cacheSession(session, for: url, speculative: selection != url)
      if settingsByPath[key] == nil || settingsByPath[key]?.pendingFilmBaseInitialization != nil {
        settingsByPath[key] = Self.automaticallyClassifiedParameters(
          base: settingsByPath[key] ?? ProcessingParameters(photoAdjustments: .init()),
          image: session.analysisSource,
          weakPrior: sameRollFilmTypeHint)
        if !editedKeys.contains(key) { automaticallyClassifiedKeys.insert(key) }
        persistSettings(for: key)
      }
      guard applyIfSelected, generation == loadGeneration, selection == url,
        enabledScanStack(containing: url) == nil
      else { return }
      applyPreviewSession(
        session,
        selection: url,
        hasStoredSettings: settingsByPath[key] != nil,
        recalibrateFromSource: !editedKeys.contains(key))
      scheduleRender(immediate: true)
    } catch is CancellationError {
      return
    } catch {
      ImportLog.loadSelectionDecodeFailed(
        path: "predecode \(url.lastPathComponent)", error: error.localizedDescription)
    }
  }

  private func cancelPredecode() {
    previewWorkRevision += 1
    isUpgradingRawPreview = false
    predecodeTask?.cancel()
    predecodeTask = nil
  }

  private func cancelScanStackUpgradePreservingPreview() {
    guard isUpgradingScanStack else { return }
    scanStackPreviewGeneration += 1
    scanStackPreviewTask?.cancel()
    scanStackPreviewTask = nil
    isUpgradingScanStack = false
  }

  private func stackPreviewCoversSource(_ image: UInt16Image) -> Bool {
    guard let source = sourcePixelDimensions else { return false }
    return image.width >= source.width && image.height >= source.height
  }

  private func stackPreviewSessionIsCurrent(
    generation: Int,
    selectedURL: URL,
    stack: DetectedScanStack
  ) -> Bool {
    generation == scanStackPreviewGeneration
      && selection == selectedURL
      && enabledScanStackIDs.contains(stack.id)
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
        image: session.analysisSource,
        weakPrior: sameRollFilmTypeHint
      )
      persistSettings(for: key)
    }
  }

  private func cacheCurrentSession(for selection: URL) {
    guard let previewSource, let previewRenderer else {
      return
    }
    let analysisSource =
      previewCache[settingsKey(selection)].flatMap {
        $0.previewRenderer === previewRenderer ? $0.analysisSource : nil
      } ?? previewSource.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension)
    cacheSession(
      CachedPreviewSession(
        sourceKind: previewSourceKind ?? .rawDetail,
        displaySource: previewSource,
        analysisSource: analysisSource,
        previewRenderer: previewRenderer,
        cpuPreviewPreparation: cpuPreviewPreparation,
        continuousEditSource: continuousEditPreviewSource,
        continuousEditRenderer: continuousEditPreviewRenderer,
        continuousEditCPUPreparation: continuousEditCPUPreparation,
        sourcePixelDimensions: sourcePixelDimensions
      ),
      for: selection
    )
  }

  private func cacheSession(
    _ session: CachedPreviewSession,
    for url: URL,
    allowDowngrade: Bool = false,
    speculative: Bool = false
  ) {
    previewCache.insert(
      session, forKey: settingsKey(url), limits: previewCacheLimits,
      preserving: selection.map { settingsKey($0) },
      allowDowngrade: allowDowngrade, speculative: speculative)
    trimPreviewCache()
  }

  private func trimPreviewCache() {
    previewCache.trim(to: previewCacheLimits, preserving: selection.map { settingsKey($0) })
    // If only an oversized selected session remains, evict unselected display
    // snapshots too. The selected canvas itself may still exceed the budget.
    let occupiedBytes =
      previewCache.reservedByteCount
      + previewCacheLimits.additionalReservedBytes - retainedCanvasCache.physicalByteCount
    let availableBytes = max(0, previewMemoryByteLimit - occupiedBytes)
    retainedCanvasCache.trim(
      to: .init(
        count: retainedCanvasLimits.count, bytes: min(retainedCanvasLimits.bytes, availableBytes)))
  }

  private var retainedCanvasLimits: RetainedCanvasPreviewCache.Limits {
    .init(count: 24, bytes: min(256 * 1_024 * 1_024, previewMemoryByteLimit / 8))
  }

  private var uncachedDisplayedCanvasBytes: Int {
    guard let canvas = displayedRetainedCanvas,
      selection.map({ retainedCanvasCache[settingsKey($0)] == nil }) == true
    else { return 0 }
    return canvas.byteCount
  }

  /// Selection has already moved. Use the loaded key for the outgoing canvas,
  /// and retain only completed pixels that match its latest saved correction.
  private func retainDepartingCanvas() {
    guard !isUnderPreviewMemoryPressure, let key = loadedPreviewKey,
      key != selection.map(settingsKey), previewSourceKind == .rawFull,
      !isPreviewingSourceGeometry, !isPreviewingUncroppedCanvas, !isDustEditing,
      let rendered = previewCache.renderedPreview(forKey: key),
      !rendered.showOriginal, rendered.result.detail == nil,
      rendered.parameters == settingsByPath[key],
      retainedCanvasCache[key]?.parameters != rendered.parameters
    else { return }
    let image = rendered.result.cgImage
    guard
      max(1, image.width / 2) * max(1, image.height / 2) * 4
        <= retainedCanvasLimits.bytes
    else { return }
    pendingCanvasSnapshot = CanvasSnapshotRequest(
      key: key, image: image, parameters: rendered.parameters,
      logicalDimensions: .init(width: image.width, height: image.height),
      sourcePixelDimensions: sourcePixelDimensions, generation: canvasSnapshotGeneration)
    guard canvasSnapshotTask == nil else { return }
    canvasSnapshotTask = Task { [weak self] in
      while let request = self?.pendingCanvasSnapshot {
        self?.pendingCanvasSnapshot = nil
        self?.canvasSnapshotWorkerBytes = request.byteCount
        let canvas = await Task.detached(priority: .utility) {
          RetainedCanvasPreview.make(
            cgImage: request.image, parameters: request.parameters,
            logicalDimensions: request.logicalDimensions,
            sourcePixelDimensions: request.sourcePixelDimensions)
        }.value
        guard let self else { return }
        self.canvasSnapshotWorkerBytes = 0
        guard request.generation == self.canvasSnapshotGeneration,
          !self.isUnderPreviewMemoryPressure,
          self.settingsByPath[request.key] == request.parameters,
          let canvas
        else { continue }
        self.retainedCanvasCache.insert(
          canvas, forKey: request.key, limits: self.retainedCanvasLimits)
        self.trimPreviewCache()
        // Fast A→B→A navigation can return before downsampling finishes.
        if let selected = self.selection, self.settingsKey(selected) == request.key,
          self.previewSourceKind != .rawFull,
          self.previewDisplayParameters == request.parameters,
          !self.showOriginal, !self.isPreviewingUncroppedCanvas,
          !self.isPreviewingSourceGeometry, !self.isDustEditing
        {
          self.restoreRetainedCanvas(for: selected)
        }
      }
      self?.canvasSnapshotTask = nil
    }
  }

  private func restoreRetainedCanvas(for url: URL) {
    let key = settingsKey(url)
    guard enabledScanStack(containing: url) == nil,
      let canvas = retainedCanvasCache[key], canvas.parameters == previewDisplayParameters
    else { return }
    retainedCanvasCache.touch(key)
    displayedRetainedCanvas = canvas
    previewImage = PreviewBitmap.nsImage(
      from: canvas.cgImage,
      logicalSize: NSSize(
        width: canvas.logicalDimensions.width, height: canvas.logicalDimensions.height))
    previewDetail = nil
    sourcePixelDimensions = canvas.sourcePixelDimensions
    publishedPreviewParameters = canvas.parameters
    renderRevision += 1
    publishedRenderRevision = renderRevision
    previewStatistics = .empty
    previewStatisticsRevision = renderRevision
    if let interval = pendingFirstPreviewInterval, interval.filename == url.lastPathComponent {
      AppPerformanceSignposts.end(interval)
      pendingFirstPreviewInterval = nil
    }
  }

  private func clearRetainedCanvasPreviews(preservingDisplay: Bool = false) {
    canvasSnapshotGeneration += 1
    pendingCanvasSnapshot = nil
    retainedCanvasCache.removeAll()
    if !preservingDisplay { displayedRetainedCanvas = nil }
  }

  private var previewCacheLimits: PreviewSessionCache.Limits {
    let proxyBytes = (continuousEditPreviewSource?.pixels.count ?? 0) * MemoryLayout<UInt16>.stride
    let canvasBytes = retainedCanvasCache.physicalByteCount + uncachedDisplayedCanvasBytes
    let workerBytes = canvasSnapshotWorkerBytes + (pendingCanvasSnapshot?.byteCount ?? 0)
    return .init(
      count: previewCacheLimit, bytes: previewMemoryByteLimit,
      additionalReservedBytes: proxyBytes + canvasBytes + workerBytes
        + uncachedCPUPreparationGeometryBytes)
  }

  /// Cached sessions already charge these owners. During replacement or eviction
  /// an active source may still own preparation outside the cache.
  private var uncachedCPUPreparationGeometryBytes: Int {
    let session = loadedPreviewKey.flatMap { previewCache[$0] }
    let cachedOwners = [session?.cpuPreviewPreparation, session?.continuousEditCPUPreparation]
      .compactMap { $0 }
    var countedOwners = Set<ObjectIdentifier>()
    return [cpuPreviewPreparation, continuousEditCPUPreparation].compactMap { $0 }.reduce(into: 0) {
      bytes, owner in
      guard !cachedOwners.contains(where: { $0 === owner }),
        countedOwners.insert(ObjectIdentifier(owner)).inserted
      else { return }
      bytes += owner.retainedGeometryByteCount
    }
  }

  func handlePreviewMemoryPressure(isUnderPressure: Bool) {
    isUnderPreviewMemoryPressure = isUnderPressure
    if isUnderPressure {
      previewMemoryPressureHandlingCount += 1
      clearRetainedCanvasPreviews(preservingDisplay: true)
      cancelPredecode()
      let selectedKey = selection.map { settingsKey($0) }
      previewCache.removeAll(except: selectedKey)
      retainedExportDecode = SelectedFileExportDecodeCache()
    } else if let selection {
      schedulePreviewWork(after: selection)
    }
  }

  private func trimThumbnailCache() {
    while thumbnailCacheOrder.count > Self.thumbnailCacheCountLimit
      || thumbnailCacheBytes > Self.thumbnailCacheByteLimit
    {
      let evicted = thumbnailCacheOrder.removeFirst()
      thumbnailImages.removeValue(forKey: evicted)
      thumbnailCacheBytes -= thumbnailByteCounts.removeValue(forKey: evicted) ?? 0
    }
  }

  private func touchThumbnailCache(_ key: String) {
    thumbnailCacheOrder.removeAll { $0 == key }
    thumbnailCacheOrder.append(key)
  }

  private func publishSidebarScanAnalysis(_ analysis: SidebarScanAnalysis, for url: URL) {
    let key = settingsKey(url)
    scanAnalysisRecords[key] = analysis.detectionRecord
    failedThumbnailPaths.remove(key)

    if thumbnailImages[key] == nil, let thumbnail = analysis.thumbnail {
      let byteCount = thumbnail.bytesPerRow * thumbnail.height
      thumbnailImages[key] = PreviewBitmap.nsImage(from: thumbnail)
      thumbnailByteCounts[key] = byteCount
      thumbnailCacheBytes += byteCount
    }
    if thumbnailImages[key] != nil {
      touchThumbnailCache(key)
      trimThumbnailCache()
    }
  }

  private func scheduleScanStackAnalysis() {
    scanAnalysisGeneration += 1
    let generation = scanAnalysisGeneration
    scanAnalysisTask?.cancel()
    let targets = files
    let needsAnalysis = targets.contains { scanAnalysisRecords[settingsKey($0)] == nil }
    if needsAnalysis, !enabledScanStackIDs.isEmpty {
      enabledScanStackIDs.removeAll()
      scanStackPreviewGeneration += 1
      scanStackPreviewTask?.cancel()
      scanStackPreviewTask = nil
      isBuildingScanStack = false
      isUpgradingScanStack = false
      stackedPreviewMembers = nil
      lastStackedPreviewMode = nil
      scanStackEffectiveMode = nil
      scanStackStatus = "Stack disabled while newly imported captures are analyzed."
      scanStackStatusID = nil
    }
    isAnalyzingScanStacks = targets.count > 1 && needsAnalysis

    scanAnalysisTask = Task { [weak self] in
      guard let self else { return }
      for url in targets {
        guard !Task.isCancelled, generation == self.scanAnalysisGeneration else { return }
        let key = self.settingsKey(url)
        if self.scanAnalysisRecords[key] != nil { continue }
        // Thumbnail rendering and repeated-scan analysis share one per-path
        // decode. A superseded analysis generation may stop waiting, while the
        // small decode can finish once and be reused by its replacement.
        self.requestThumbnail(for: url)
        if let thumbnailTask = self.thumbnailTasks[key] {
          await thumbnailTask.value
        }
      }
      guard generation == self.scanAnalysisGeneration else { return }
      let records = self.scanAnalysisRecords
      let proposalWorker = Task.detached(priority: .utility) {
        Self.detectedScanStackProposals(
          files: targets,
          records: records)
      }
      let proposals = await withTaskCancellationHandler {
        await proposalWorker.value
      } onCancel: {
        proposalWorker.cancel()
      }
      guard !Task.isCancelled, generation == self.scanAnalysisGeneration else { return }
      self.applyDetectedScanStackProposals(proposals)
      self.isAnalyzingScanStacks = false
      self.scanAnalysisTask = nil
    }
  }

  nonisolated private static func detectedScanStackProposals(
    files: [URL],
    records: [String: ScanDetectionRecord]
  ) -> [DetectedScanStack] {
    var proposals: [DetectedScanStack] = []
    var currentURLs: [URL] = []
    var currentMatches: [SameNegativeMatch] = []

    func record(for url: URL) -> ScanDetectionRecord? {
      records[url.standardizedFileURL.path]
    }

    func finishCurrentGroup() {
      guard currentURLs.count >= 2 else {
        currentURLs = []
        currentMatches = []
        return
      }
      let exposureValues = currentURLs.compactMap {
        record(for: $0)?.exposureEV
      }
      let exposureSpread = (exposureValues.max() ?? 0) - (exposureValues.min() ?? 0)
      proposals.append(
        DetectedScanStack(
          members: currentURLs,
          confidence: currentMatches.map(\.confidence).min() ?? 0,
          exposureSpreadEV: exposureSpread,
          recommendedMode: exposureSpread >= 0.5 ? .hdr : .noiseReduction
        ))
      currentURLs = []
      currentMatches = []
    }

    for url in files {
      guard !Task.isCancelled else { return [] }
      guard let analysis = record(for: url) else {
        finishCurrentGroup()
        continue
      }
      guard let anchorURL = currentURLs.first,
        let anchor = record(for: anchorURL)
      else {
        currentURLs = [url]
        continue
      }
      let dimensionsMatch = anchor.fullResolutionDimensions == analysis.fullResolutionDimensions
      let match = SameNegativeDetector.match(
        anchor.fingerprint,
        analysis.fingerprint,
        minimumConfidence: 0.92)
      if dimensionsMatch, match.isMatch {
        if currentURLs.count >= maximumScanStackMembers {
          finishCurrentGroup()
          currentURLs = [url]
        } else {
          currentURLs.append(url)
          currentMatches.append(match)
        }
      } else {
        finishCurrentGroup()
        currentURLs = [url]
      }
    }
    finishCurrentGroup()
    return proposals
  }

  private func applyDetectedScanStackProposals(_ proposals: [DetectedScanStack]) {
    detectedScanStacks = proposals

    let validIDs = Set(proposals.map(\.id))
    enabledScanStackIDs.formIntersection(validIDs)
    scanStackModes = scanStackModes.filter { validIDs.contains($0.key) }
  }

  private func scheduleEnabledScanStackPreview(for url: URL) {
    guard let stack = detectedScanStack(containing: url),
      enabledScanStackIDs.contains(stack.id)
    else { return }
    if previewSourceKind == .alignedStack,
      let previewSource,
      stackPreviewCoversSource(previewSource),
      scanStackEffectiveMode != nil,
      !isBuildingScanStack,
      !isUpgradingScanStack
    {
      return
    }
    buildScanStackPreview(stack)
  }

  private func buildScanStackPreview(_ stack: DetectedScanStack) {
    guard let selectedURL = selection, stack.contains(selectedURL),
      enabledScanStackIDs.contains(stack.id)
    else { return }
    scanStackPreviewGeneration += 1
    let generation = scanStackPreviewGeneration
    scanStackPreviewTask?.cancel()
    cancelPredecode()
    let mode = scanStackMode(for: stack)
    isBuildingScanStack = previewSourceKind != .alignedStack
    isUpgradingScanStack = previewSourceKind == .alignedStack
    publishScanStackStatus("Aligning \(stack.members.count) captures...")
    scanStackStatusID = stack.id

    scanStackPreviewTask = Task { [weak self] in
      guard let self else { return }
      var appliedImage: UInt16Image?
      var appliedTier: ScanStackPreviewTier?
      do {
        if let cached = self.stackedPreviewMembers, cached.stackID == stack.id,
          !cached.images.isEmpty
        {
          try Task.checkCancellation()
          guard
            self.stackPreviewSessionIsCurrent(
              generation: generation, selectedURL: selectedURL, stack: stack)
          else { return }
          self.publishScanStackStatus(
            "Updating \(Self.scanStackModeLabel(mode)) from the current stack...")
          do {
            let images = cached.images
            let result = try await Task.detached(priority: .userInitiated) {
              try MultiScanStacker.combine(images: images, mode: mode)
            }.value
            try Task.checkCancellation()
            guard
              self.stackPreviewSessionIsCurrent(
                generation: generation, selectedURL: selectedURL, stack: stack)
            else { return }
            try self.applyAlignedStackPreview(
              result, stack: stack, calibrateFromSource: false)
            appliedImage = result.image
            appliedTier = cached.tier
            self.lastStackedPreviewMode = mode
            self.isBuildingScanStack = false
            self.isUpgradingScanStack = !self.stackPreviewCoversSource(result.image)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // Rebuild from the source files if the cached members cannot be recombined.
          }
        }

        for tier in ScanStackPreviewTier.allCases {
          try Task.checkCancellation()
          guard
            self.stackPreviewSessionIsCurrent(
              generation: generation, selectedURL: selectedURL, stack: stack)
          else { return }
          if let appliedImage, self.stackPreviewCoversSource(appliedImage) {
            break
          }
          if let appliedTier, tier.rawValue <= appliedTier.rawValue {
            continue
          }
          if self.lastStackedPreviewMode == mode,
            self.alignedStackAlreadySatisfies(tier, stack: stack)
          {
            continue
          }
          if self.stackTierWouldRegressVisiblePreview(tier, stack: stack) {
            continue
          }

          if appliedImage != nil || self.previewSourceKind == .alignedStack {
            self.isBuildingScanStack = false
            self.isUpgradingScanStack = true
            self.publishScanStackStatus("Loading \(tier.statusLabel) stack...")
          } else {
            self.publishScanStackStatus(
              "Aligning \(stack.members.count) captures at \(tier.statusLabel) resolution...")
          }

          let prepared: PreparedStackCombine
          do {
            prepared = try await self.combinedStackResult(
              stack: stack, mode: mode, tier: tier)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            if tier == .full { throw error }
            continue
          }
          try Task.checkCancellation()
          guard
            self.stackPreviewSessionIsCurrent(
              generation: generation, selectedURL: selectedURL, stack: stack)
          else { return }

          if self.stackImageWouldRegressVisiblePreview(prepared.result.image) {
            continue
          }

          try self.applyAlignedStackPreview(
            prepared.result,
            stack: stack,
            calibrateFromSource: appliedImage == nil)
          appliedImage = prepared.result.image
          appliedTier = tier
          self.lastStackedPreviewMode = mode
          if !prepared.members.isEmpty {
            self.stackedPreviewMembers = StackPreviewMemberCache(
              stackID: stack.id, tier: tier, images: prepared.members)
          }
        }
        guard
          self.stackPreviewSessionIsCurrent(
            generation: generation, selectedURL: selectedURL, stack: stack)
        else { return }
        if appliedImage == nil {
          self.publishScanStackStatus(
            "Stack could not be built from the current captures.",
            kind: .error)
          self.isBuildingScanStack = false
          self.isUpgradingScanStack = false
          self.scanStackPreviewTask = nil
          return
        }
        self.isBuildingScanStack = false
        self.isUpgradingScanStack = false
        self.scanStackPreviewTask = nil
      } catch is CancellationError {
        return
      } catch {
        guard generation == self.scanStackPreviewGeneration else { return }
        self.isBuildingScanStack = false
        self.isUpgradingScanStack = false
        self.scanStackPreviewTask = nil
        if appliedImage != nil {
          self.publishScanStackStatus(
            "Showing the bounded stack; full-resolution upgrade failed: \(error.localizedDescription)",
            kind: .error)
        } else {
          self.publishScanStackStatus(
            "Stack could not be built: \(error.localizedDescription)",
            kind: .error)
        }
      }
    }
  }

  private func combinedStackResult(
    stack: DetectedScanStack,
    mode: ScanStackMode,
    tier: ScanStackPreviewTier
  ) async throws -> PreparedStackCombine {
    if let cached = stackedPreviewMembers, cached.stackID == stack.id, cached.tier == tier,
      !cached.images.isEmpty
    {
      publishScanStackStatus("Combining \(cached.images.count) captures...")
      let images = cached.images
      let result = try await Task.detached(priority: .userInitiated) {
        try MultiScanStacker.combine(images: images, mode: mode)
      }.value
      return PreparedStackCombine(result: result, members: images)
    }

    if tier == .full {
      let result = try await combinedFullResolutionStack(
        stack: stack, mode: mode, forExport: false)
      return PreparedStackCombine(result: result, members: [])
    }

    var images: [UInt16Image] = []
    images.reserveCapacity(stack.members.count)
    for (index, url) in stack.members.enumerated() {
      try Task.checkCancellation()
      publishScanStackStatus(
        "Decoding stack capture \(index + 1) of \(stack.members.count) (\(tier.statusLabel)): \(url.lastPathComponent)"
      )
      images.append(try await decodeStackPreviewMember(url, tier: tier))
    }
    try Task.checkCancellation()
    publishScanStackStatus("Aligning and combining \(stack.members.count) captures...")
    let captured = images
    let result = try await Task.detached(priority: .userInitiated) {
      try MultiScanStacker.combine(images: captured, mode: mode)
    }.value
    return PreparedStackCombine(result: result, members: images)
  }

  private func combinedFullResolutionStack(
    stack: DetectedScanStack,
    mode: ScanStackMode,
    forExport: Bool
  ) async throws -> MultiScanStackResult {
    try await MultiScanStacker.combine(imageCount: stack.members.count, mode: mode) { index in
      try await self.loadFullResolutionStackMember(
        stack.members[index], index: index, count: stack.members.count, forExport: forExport)
    }
  }

  private func loadFullResolutionStackMember(
    _ url: URL, index: Int, count: Int, forExport: Bool
  ) async throws -> UInt16Image {
    try Task.checkCancellation()
    publishScanStackStatus(
      "Decoding stack capture \(index + 1) of \(count): \(url.lastPathComponent)")
    let image: UInt16Image
    if forExport {
      image = try await decodedImageForExport(url)
    } else {
      image = try await decodeStackPreviewMember(url, tier: .full)
    }
    try Task.checkCancellation()
    publishScanStackStatus("Aligning and combining \(count) captures...")
    return image
  }

  private func decodeStackPreviewMember(
    _ url: URL,
    tier: ScanStackPreviewTier
  ) async throws -> UInt16Image {
    let decoder = scanStackPreviewDecoder
    return try await rawDecodeScheduler.run {
      try decoder?(url, tier) ?? Self.makeStackPreviewSource(for: url, tier: tier)
    }
  }

  private func applyAlignedStackPreview(
    _ result: MultiScanStackResult,
    stack: DetectedScanStack,
    calibrateFromSource: Bool
  ) throws {
    guard let renderer = StillPreviewRenderer(image: result.image) else {
      throw CocoaError(.coderInvalidValue)
    }
    decodedImage = result.image
    previewSource = result.image
    previewRenderer = renderer
    previewSourceKind = .alignedStack
    scanStackEffectiveMode = result.effectiveMode
    if calibrateFromSource {
      populateFilmNegativeMedians(
        from: result.image.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension))
    }
    let modeLabel = Self.scanStackModeLabel(result.effectiveMode)
    if stackPreviewCoversSource(result.image) {
      publishScanStackStatus(
        "Aligned \(stack.members.count) captures for \(modeLabel) at full resolution.")
    } else {
      publishScanStackStatus(
        "Aligned \(stack.members.count) captures for \(modeLabel).")
    }
    if let selection {
      cacheCurrentSession(for: selection)
    }
    scheduleRender(immediate: true)
  }

  private func publishScanStackStatus(_ message: String, kind: StatusKind = .info) {
    scanStackStatus = message
    setStatus(message, kind: kind)
  }

  private func stackPreviewBound(
    for tier: ScanStackPreviewTier, stack: DetectedScanStack
  ) -> Int? {
    let isRaw = FileDropPolicy.rawExtensions.contains(stack.anchor.pathExtension.lowercased())
    switch tier {
    case .draft:
      return isRaw ? Self.rawDraftPreviewMaxDimension : Self.displayPreviewMaxDimension
    case .inspect:
      return Self.rawInspectPreviewMaxDimension
    case .full:
      return nil
    }
  }

  /// A 640px RAW draft is much smaller than an inspect or full preview already
  /// on the canvas. Applying it makes the viewport look pixelated and hides the
  /// fact that a sharper stack is still loading.
  private func stackTierWouldRegressVisiblePreview(
    _ tier: ScanStackPreviewTier, stack: DetectedScanStack
  ) -> Bool {
    guard let current = previewSource else { return false }
    guard let bound = stackPreviewBound(for: tier, stack: stack) else { return false }
    return bound * 2 < max(current.width, current.height)
  }

  private func stackImageWouldRegressVisiblePreview(_ image: UInt16Image) -> Bool {
    guard let current = previewSource else { return false }
    if previewSourceKind == .alignedStack,
      stackPreviewCoversSource(current),
      !stackPreviewCoversSource(image)
    {
      return true
    }
    return max(image.width, image.height) * 2 < max(current.width, current.height)
  }

  private func alignedStackAlreadySatisfies(
    _ tier: ScanStackPreviewTier, stack: DetectedScanStack
  ) -> Bool {
    guard previewSourceKind == .alignedStack, let current = previewSource else { return false }
    if stackPreviewCoversSource(current) { return true }
    guard let bound = stackPreviewBound(for: tier, stack: stack) else { return false }
    return max(current.width, current.height) >= (bound * 9) / 10
  }

  nonisolated private static func scanStackModeLabel(_ mode: ScanStackMode) -> String {
    switch mode {
    case .automatic: "automatic stacking"
    case .noiseReduction: "noise reduction"
    case .hdr: "HDR"
    }
  }

  private var previewDisplayParameters: ProcessingParameters {
    var displayParameters = parameters
    if isDustEditing {
      displayParameters.cropRect = nil
      displayParameters.perspectiveCrop = nil
      displayParameters.straightenAngle = 0
      displayParameters.manualCrop = nil
      displayParameters.borderCrop = 0
      displayParameters.rotation = 0
      displayParameters.flip = false
    } else if isPreviewingSourceGeometry {
      displayParameters.cropRect = nil
      displayParameters.perspectiveCrop = nil
      displayParameters.straightenAngle = 0
      displayParameters.manualCrop = nil
    } else if isPreviewingUncroppedCanvas {
      displayParameters.manualCrop = nil
    }
    if !showDustRepairs || showOriginal { displayParameters.dustRepairs = [] }
    return displayParameters
  }

  func setPreviewRenderDemand(_ demand: PreviewRenderDemand) {
    guard demand != previewRenderDemand else { return }
    previewRenderDemand = demand
    // Native scrolling composites the retained complete raster. Only an active
    // edit uses viewport-specific correction, followed by a full raster on release.
    if editTransaction != nil {
      viewportRevision += 1
      scheduleRender(immediate: true)
    }
  }

  private func submitPreviewStatistics(
    _ statistics: RenderedPreviewStatistics,
    request: PreviewRenderRequest
  ) {
    let sample = PreviewStatisticsRequest(
      revision: request.revision, sourceGeneration: request.sourceGeneration, sample: statistics)
    publishedStatisticsRequest = sample
    if let resolved = statistics.resolvedValue {
      // A retained raster carries its diagnostics across selection changes.
      // Publish them together instead of sampling identical pixels again.
      pendingStatistics = nil
      previewStatistics = resolved
      previewStatisticsRevision = request.revision
      return
    }
    let now = ContinuousClock.now
    // Always refresh the final edit; continuous gestures need diagnostics at
    // most ten times per second. One active and one latest pending sample.
    if editTransaction != nil, let lastStatisticsSubmission,
      lastStatisticsSubmission.duration(to: now) < .milliseconds(100)
    {
      return
    }
    enqueuePreviewStatistics(sample)
  }

  private func enqueuePreviewStatistics(_ sample: PreviewStatisticsRequest) {
    lastStatisticsSubmission = .now
    pendingStatistics = sample
    guard statisticsTask == nil else { return }
    statisticsTask = Task { [weak self] in
      while let sample = self?.pendingStatistics {
        self?.pendingStatistics = nil
        let result = await Task.detached(priority: .utility) { sample.sample.resolve() }.value
        guard let self else { return }
        if result.didCompute { self.previewStatisticsComputationCount += 1 }
        await self.previewStatisticsCompletionHook?()
        if self.previewSourceGeneration == sample.sourceGeneration,
          self.publishedRenderRevision == sample.revision
        {
          self.previewStatistics = result.statistics
          self.previewStatisticsRevision = sample.revision
        }
      }
      self?.statisticsTask = nil
    }
  }

  private func scheduleRender(immediate: Bool = false) {
    let interactionStart = pendingInteractionStart ?? ContinuousClock.now
    pendingInteractionStart = nil
    if let canvas = displayedRetainedCanvas {
      let matches =
        canvas.parameters == previewDisplayParameters && !showOriginal
        && !isPreviewingSourceGeometry && !isPreviewingUncroppedCanvas && !isDustEditing
        && selection.flatMap { enabledScanStack(containing: $0) } == nil
      if matches, previewSourceKind != .rawFull { return }
      if !matches { displayedRetainedCanvas = nil }
    }
    guard let selection, let previewSource, let cpuPreviewPreparation else {
      return
    }

    let displayParameters = previewDisplayParameters
    let useContinuousEditPreview: Bool
    let renderSource: UInt16Image
    let renderRenderer: StillPreviewRenderer?
    let renderCPUPreparation: CPUPreviewPreparationCache
    if editTransaction != nil,
      previewRenderDemand?.detailRect == nil,
      previewSourceKind == .rawFull,
      let continuousEditPreviewSource,
      let continuousEditCPUPreparation
    {
      useContinuousEditPreview = true
      renderSource = continuousEditPreviewSource
      renderRenderer = continuousEditPreviewRenderer
      renderCPUPreparation = continuousEditCPUPreparation
    } else {
      useContinuousEditPreview = false
      renderSource = previewSource
      renderRenderer = previewRenderer
      renderCPUPreparation = cpuPreviewPreparation
    }
    if useContinuousEditPreview || (editTransaction != nil && previewRenderDemand != nil) {
      continuousEditPreviewNeedsRefinement = true
    }
    let logicalDimensions = ImageGeometry.outputDimensions(
      source: PixelDimensions(width: previewSource.width, height: previewSource.height),
      parameters: displayParameters)

    let context = PreviewRenderContext(
      selection: selection, sourceGeneration: previewSourceGeneration,
      parameters: displayParameters, showOriginal: showOriginal)
    if context != lastRenderContext {
      renderContextGeneration += 1
      lastRenderContext = context
    }
    let demand =
      editTransaction == nil
      ? nil
      : previewRenderDemand.flatMap {
        $0.documentSize
          == CGSize(width: logicalDimensions.width, height: logicalDimensions.height)
          ? $0 : nil
      }
    // The visible detail still uses the full source. Its temporary background
    // overview can reuse the same bounded source as Fit instead of correcting
    // every sensor pixel just to reduce the result to 1024px.
    let overviewRenderer =
      previewSourceKind == .rawFull && demand?.detailRect != nil
      ? continuousEditPreviewRenderer : nil
    if renderTask == nil { lastPublicationTime = interactionStart }
    renderRevision += 1
    let previousHadPending = pendingRender != nil
    pendingRender = PreviewRenderRequest(
      revision: renderRevision,
      contextGeneration: renderContextGeneration,
      cancellation: renderCancellation,
      sourceGeneration: previewSourceGeneration,
      selection: selection,
      source: renderSource,
      renderer: renderRenderer,
      overviewRenderer: overviewRenderer,
      parameters: displayParameters,
      showOriginal: showOriginal,
      logicalDimensions: logicalDimensions,
      usesContinuousEditPreview: useContinuousEditPreview,
      interactionStart: interactionStart,
      submitTime: ContinuousClock.now,
      // Capture the existing buffer only. Preparing a full-size unity field
      // here allocated an image on the main actor for every slider event,
      // even when the GPU renderer never consumed it.
      cpuPreparation: renderCPUPreparation,
      otherCPUPreparation: renderCPUPreparation === cpuPreviewPreparation
        ? continuousEditCPUPreparation : cpuPreviewPreparation,
      viewportRevision: viewportRevision,
      demand: demand,
      cachedResult: editTransaction == nil
        ? previewCache.renderedPreview(forKey: settingsKey(selection)).flatMap {
          $0.renderer === renderRenderer && $0.parameters == displayParameters
            && $0.showOriginal == showOriginal ? $0.result : nil
        } : nil,
      flatField: compatibleFlatField(for: renderSource)
    )
    previewInteractionTrace?.record(
      .requestSubmitted, revision: renderRevision, interactionStart: interactionStart,
      exposureEV: displayParameters.photoAdjustments.exposureEV,
      contrast: displayParameters.photoAdjustments.contrast,
      sourceWidth: renderSource.width, sourceHeight: renderSource.height,
      usesProxy: useContinuousEditPreview,
      usesProxyOverview: overviewRenderer != nil,
      hasDetail: demand?.detailRect != nil)

    if previousHadPending {
      var stats = renderStats
      stats.droppedSnapshots += 1
      renderStats = stats
    }

    var stats = renderStats
    stats.submittedSnapshots += 1
    renderStats = stats

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
      await self.processRenderQueue()
    }
  }

  nonisolated private static func preparedFlatField(
    for image: UInt16Image, compatibleField: UInt16Image?
  ) -> UInt16Image {
    guard let flatField = compatibleField else {
      return Self.unityFlatField(for: image)
    }
    return flatField.resized(width: image.width, height: image.height)
  }

  nonisolated static func previewStatistics(
    for image: UInt16Image
  ) -> RenderReadyImageStatistics? {
    image.previewStatistics()
  }

  private func compatibleFlatField(for image: UInt16Image) -> UInt16Image? {
    guard let flatFieldImage, flatFieldImage.channels == image.channels else { return nil }
    let imageAspect = Double(image.width) / Double(image.height)
    let fieldAspect = Double(flatFieldImage.width) / Double(flatFieldImage.height)
    guard abs(imageAspect - fieldAspect) / imageAspect <= 0.01 else { return nil }
    return flatFieldImage
  }

  private func processRenderQueue() async {
    while !Task.isCancelled, let request = pendingRender {
      pendingRender = nil
      let signpostID = OSSignpostID(log: Self.signpostLog)
      let renderStart = ContinuousClock.now
      previewInteractionTrace?.record(.renderBegan, revision: request.revision)
      let submitTime = request.submitTime
      if request.cachedResult != nil {
        previewRenderCacheHits += 1
      } else {
        previewCorrectionCount += 1
      }
      let result: RenderedPreview?
      if let cached = request.cachedResult {
        result = cached
      } else {
        let traceWorker = previewInteractionTrace != nil
        let workerHook = previewRenderWorkerHook
        let checkpointHook = previewRenderCheckpointHook
        let worker = await Task.detached(priority: .userInitiated) {
          await workerHook?()
          let began = traceWorker ? ContinuousClock.now : nil
          let rendered = Self.renderPreview(request, checkpointHook: checkpointHook)
          return PreviewRenderWorkerResult(
            rendered: rendered, began: began,
            finished: traceWorker ? ContinuousClock.now : nil)
        }.value
        result = worker.rendered
        if let began = worker.began, let finished = worker.finished {
          // Worker instants are captured off the main actor and reported only
          // after resumption. Their times separate compute from UI contention.
          previewInteractionTrace?.record(.workerBegan, revision: request.revision, at: began)
          previewInteractionTrace?.record(.workerFinished, revision: request.revision, at: finished)
        }
      }

      let renderDuration = Self.milliseconds(renderStart.duration(to: .now))
      previewInteractionTrace?.record(.renderReturned, revision: request.revision)
      // A discarded worker can still grow a retained session's CPU geometry.
      // Account for that memory before any cancellation guard or suspended hook.
      trimPreviewCache()
      await previewRenderCompletionHook?(request.parameters)

      guard !Task.isCancelled else {
        break
      }
      // A completed point edit is useful even when a newer one is queued.
      // Document, source, comparison, and geometry changes invalidate the entire
      // context, including a change away and back while this frame was running.
      guard selection == request.selection,
        previewSourceGeneration == request.sourceGeneration,
        request.demand == nil || viewportRevision == request.viewportRevision,
        renderContextGeneration == request.contextGeneration,
        request.revision > publishedRenderRevision,
        pendingRender != nil || previewDisplayParameters == request.parameters,
        showOriginal == request.showOriginal,
        let result
      else {
        var stats = renderStats
        stats.droppedSnapshots += 1
        renderStats = stats
        continue
      }
      let preview = result.cgImage
      if !request.usesContinuousEditPreview, request.demand == nil,
        let renderer = request.renderer
      {
        previewCache.storeRenderedPreview(
          CachedRenderedPreview(
            renderer: renderer, parameters: request.parameters,
            showOriginal: request.showOriginal, result: result),
          forKey: settingsKey(request.selection), limits: previewCacheLimits,
          preserving: selection.map { settingsKey($0) })
      } else {
        // A selected-source CPU viewport can retain geometry plus an overview.
        // Account for it before admitting more speculative sessions.
        trimPreviewCache()
      }

      let publicationTime = ContinuousClock.now
      let totalLatency = Self.milliseconds(submitTime.duration(to: publicationTime))
      var stats = renderStats
      stats.displayedRenders += 1
      stats.lastLatencyMs = totalLatency
      stats.peakLatencyMs = max(stats.peakLatencyMs, totalLatency)
      stats.totalSubmissionLatencyMs += totalLatency
      stats.lastPreparationMs = Self.milliseconds(request.interactionStart.duration(to: submitTime))
      stats.lastQueueWaitMs = Self.milliseconds(submitTime.duration(to: renderStart))
      stats.lastRenderMs = renderDuration
      stats.lastInteractionLatencyMs = Self.milliseconds(
        request.interactionStart.duration(to: publicationTime))
      if let lastPublicationTime {
        stats.longestPublicationGapMs = max(
          stats.longestPublicationGapMs,
          Self.milliseconds(lastPublicationTime.duration(to: publicationTime)))
      }
      renderStats = stats
      lastPublicationTime = publicationTime
      publishedRenderRevision = request.revision
      publishedPreviewParameters = request.parameters

      os_signpost(
        .event, log: Self.signpostLog, name: "Frame Published",
        signpostID: signpostID,
        "renderMs=%.1f totalMs=%.1f submissions=%d displayed=%d dropped=%d editProxy=%d",
        renderDuration, totalLatency,
        stats.submittedSnapshots, stats.displayedRenders, stats.droppedSnapshots,
        request.usesContinuousEditPreview ? 1 : 0)

      previewImage = PreviewBitmap.nsImage(
        from: preview,
        logicalSize: NSSize(
          width: request.logicalDimensions.width,
          height: request.logicalDimensions.height))
      displayedRetainedCanvas = nil
      if let detail = result.detail, let rect = request.demand?.detailRect {
        previewDetail = PreviewDetail(image: PreviewBitmap.nsImage(from: detail), rect: rect)
      } else {
        previewDetail = nil
      }
      previewInteractionTrace?.record(
        .modelPublished, revision: request.revision,
        rasterWidth: preview.width, rasterHeight: preview.height,
        usesProxy: request.usesContinuousEditPreview, hasDetail: result.detail != nil,
        renderer: result.rendererName)
      submitPreviewStatistics(result.statistics, request: request)
      if let interval = pendingFirstPreviewInterval,
        interval.filename == request.selection.lastPathComponent
      {
        AppPerformanceSignposts.end(interval)
        pendingFirstPreviewInterval = nil
      }
      // A background redraw must not erase the outcome of a failed operation,
      // or hide in-flight stack alignment progress behind a generic renderer line.
      if statusKind != .error, !status.localizedCaseInsensitiveContains("cancel"),
        !isBuildingScanStack, !isUpgradingScanStack
      {
        let filename = request.selection.lastPathComponent
        let renderer = result.rendererName
        switch previewSourceKind {
        case .embeddedRAW:
          setStatus("\(filename) • \(renderer) · camera JPEG, not RAW color")
        case .alignedStack:
          let qualifier =
            (previewSource.map(stackPreviewCoversSource) == true)
            ? "aligned stack"
            : "aligned stack preview"
          setStatus("\(filename) • \(renderer) · \(qualifier)")
        default:
          setStatus("\(filename) • \(renderer)")
        }
      }

      lastRenderEnd = ContinuousClock.now
    }

    renderTask = nil
    isRendering = false
  }

  nonisolated private static func renderPreview(
    _ request: PreviewRenderRequest,
    checkpointHook: (@Sendable (PreviewRenderCheckpoint) -> Void)?
  ) -> RenderedPreview? {
    func remainsCurrent(at checkpoint: PreviewRenderCheckpoint) -> Bool {
      checkpointHook?(checkpoint)
      return !request.cancellation.isCancelled
    }
    guard remainsCurrent(at: .started) else { return nil }
    if let rendered = renderGPUPreview(request, remainsCurrent: remainsCurrent) {
      return rendered
    }
    guard !request.cancellation.isCancelled else { return nil }
    var renderParameters = request.parameters
    if request.showOriginal {
      renderParameters.filmType = .cropOnly
    }
    if let rendered = renderCPUViewport(
      request, parameters: renderParameters, remainsCurrent: remainsCurrent)
    {
      return rendered
    }
    guard !request.cancellation.isCancelled else { return nil }
    return renderCPUPreview(
      request, parameters: renderParameters, remainsCurrent: remainsCurrent)
  }

  nonisolated private static func renderGPUPreview(
    _ request: PreviewRenderRequest,
    remainsCurrent: (PreviewRenderCheckpoint) -> Bool
  ) -> RenderedPreview? {
    let renderer = request.overviewRenderer ?? request.renderer
    guard
      renderer?.supports(
        parameters: request.parameters, showOriginal: request.showOriginal) == true
    else { return nil }
    request.cpuPreparation.discardGeometry(ifIncompatibleWith: request.parameters)
    if let other = request.otherCPUPreparation, other !== request.cpuPreparation {
      other.discardGeometry(ifIncompatibleWith: request.parameters)
    }
    guard
      let overview = renderer?.render(
        parameters: request.parameters,
        showOriginal: request.showOriginal,
        maximumDimension: request.demand?.overviewMaximumDimension)
    else { return nil }
    guard remainsCurrent(.gpuOverviewComplete) else { return nil }
    let detail = request.demand?.normalizedDetailRect.flatMap { region in
      request.renderer?.render(
        parameters: request.parameters, showOriginal: request.showOriginal,
        normalizedRegion: region)
    }
    guard remainsCurrent(.gpuDetailComplete),
      request.demand?.detailRect == nil || detail != nil
    else { return nil }
    return RenderedPreview(
      cgImage: overview,
      rendererName: request.usesContinuousEditPreview ? "GPU edit preview" : "GPU",
      detail: detail,
      statistics: RenderedPreviewStatistics {
        StillPreviewRenderer.statistics(for: overview) ?? .empty
      })
  }

  nonisolated private static func renderCPUViewport(
    _ request: PreviewRenderRequest,
    parameters: ProcessingParameters,
    remainsCurrent: (PreviewRenderCheckpoint) -> Bool
  ) -> RenderedPreview? {
    guard let demand = request.demand, let rect = demand.detailRect,
      let viewport = request.cpuPreparation.renderViewport(
        parameters: parameters,
        region: ImageRegion(
          x: Int(rect.minX), y: Int(rect.minY),
          width: Int(rect.width), height: Int(rect.height)),
        overviewMaximumDimension: demand.overviewMaximumDimension)
    else { return nil }
    guard remainsCurrent(.cpuViewportComplete) else { return nil }
    let overview = viewport.overview.makePreviewCGImage()
    guard remainsCurrent(.cpuOverviewPacked) else { return nil }
    let detail = viewport.detail.makePreviewCGImage()
    guard remainsCurrent(.cpuDetailPacked), let overview, let detail else { return nil }
    let sample = viewport.overview.previewStatisticsSample()
    return RenderedPreview(
      cgImage: overview, rendererName: "CPU viewport", detail: detail,
      statistics: RenderedPreviewStatistics { sample.statistics() ?? .empty })
  }

  nonisolated private static func renderCPUPreview(
    _ request: PreviewRenderRequest,
    parameters: ProcessingParameters,
    remainsCurrent: (PreviewRenderCheckpoint) -> Bool
  ) -> RenderedPreview? {
    // Preserve the density path's sensor-space flat-field geometry, but
    // defer its allocation/resizing until a CPU render actually needs it.
    let flatField: UInt16Image? =
      parameters.densityPipelineEnabled
      ? request.flatField?.resized(width: request.source.width, height: request.source.height)
        ?? unityFlatField(for: request.source)
      : nil
    guard remainsCurrent(.flatFieldPrepared) else { return nil }
    let rendered = request.cpuPreparation.render(parameters: parameters, flatField: flatField)
    guard remainsCurrent(.cpuCorrectionComplete) else { return nil }
    guard let preview = rendered.makePreviewCGImage() else { return nil }
    guard remainsCurrent(.cpuPacked) else { return nil }
    let sample = rendered.previewStatisticsSample()
    return RenderedPreview(
      cgImage: preview, rendererName: "CPU", detail: nil,
      statistics: RenderedPreviewStatistics { sample.statistics() ?? .empty })
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
  }

  private func cancelRenderLoop() {
    // Synchronous engine calls drain before the next context starts. Invalidate
    // their token so the worker can skip later stages, keeping only one worker.
    renderContextGeneration += 1
    pendingRender = nil
    pendingStatistics = nil
    publishedStatisticsRequest = nil
    previewDetail = nil
    isRendering = renderTask != nil
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

  nonisolated private static func decodeRawPreview(
    _ url: URL,
    maxDimension: Int,
    resizeToBound: Bool = true
  ) throws -> UInt16Image {
    let decoded = try RawImageDecoder.decode(
      url,
      profile: .rawTherapeeCameraScan,
      maxDimension: maxDimension
    ).image
    guard resizeToBound else { return decoded }
    return decoded.resizedToFit(maxDimension: maxDimension)
  }

  nonisolated private static func makeRawPreviewSession(
    for url: URL,
    maxDimension: Int,
    kind: PreviewSourceKind
  ) throws -> CachedPreviewSession {
    let display = try decodeRawPreview(url, maxDimension: maxDimension)
    let analysis = display.resizedToFit(maxDimension: analysisPreviewMaxDimension)
    guard let renderer = StillPreviewRenderer(image: display, analysisImage: analysis) else {
      throw CocoaError(.coderInvalidValue)
    }
    return CachedPreviewSession(
      sourceKind: kind,
      displaySource: display,
      analysisSource: analysis,
      previewRenderer: renderer,
      sourcePixelDimensions: fullResolutionDimensions(of: url))
  }

  nonisolated private static func makeRawFullPreviewSession(
    for url: URL
  ) throws -> CachedPreviewSession {
    let display = try decodeRawPreview(
      url, maxDimension: rawFullPreviewDecodeBound, resizeToBound: false)
    let analysis = display.resizedToFit(maxDimension: analysisPreviewMaxDimension)
    let continuousEditSource = display.resizedToFit(
      maxDimension: continuousEditPreviewMaxDimension)
    guard
      let renderer = StillPreviewRenderer(image: display, analysisImage: analysis),
      let continuousEditRenderer = StillPreviewRenderer(
        image: continuousEditSource, analysisImage: analysis)
    else {
      throw CocoaError(.coderInvalidValue)
    }
    return CachedPreviewSession(
      sourceKind: .rawFull,
      displaySource: display,
      analysisSource: analysis,
      previewRenderer: renderer,
      continuousEditSource: continuousEditSource,
      continuousEditRenderer: continuousEditRenderer,
      sourcePixelDimensions: fullResolutionDimensions(of: url))
  }

  nonisolated private static func makeFastPreviewSession(
    for url: URL
  ) throws -> CachedPreviewSession {
    if FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) {
      return try makeRawPreviewSession(
        for: url,
        maxDimension: rawDraftPreviewMaxDimension,
        kind: .rawDraft)
    }
    let display = try StandardImageDecoder.decodePreview(
      url, maxDimension: displayPreviewMaxDimension)
    guard let renderer = StillPreviewRenderer(image: display) else {
      throw CocoaError(.coderInvalidValue)
    }
    return CachedPreviewSession(
      sourceKind: .standardThumbnail,
      displaySource: display,
      analysisSource: display.resizedToFit(maxDimension: analysisPreviewMaxDimension),
      previewRenderer: renderer,
      sourcePixelDimensions: fullResolutionDimensions(of: url))
  }

  nonisolated private static func makeSidebarScanAnalysis(
    for url: URL, preparationHook: (@Sendable () -> Void)? = nil
  ) throws -> SidebarScanAnalysis {
    try Task.checkCancellation()
    let source: UInt16Image
    let dimensions: PixelDimensions?
    if FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) {
      let decoded = try RawImageDecoder.extractThumbnail(url, maxDimension: thumbnailMaxDimension)
      source = decoded.image
      dimensions = decoded.fullResolutionDimensions
    } else {
      source = try StandardImageDecoder.decodePreview(url, maxDimension: thumbnailMaxDimension)
      dimensions = fullResolutionDimensions(of: url)
    }
    try Task.checkCancellation()
    let fingerprint = try ScanFingerprint(image: source)
    preparationHook?()
    try Task.checkCancellation()
    let thumbnail = source.makePreviewCGImage().flatMap(PreviewBitmap.invertedCGImage)
    try Task.checkCancellation()
    return SidebarScanAnalysis(
      thumbnail: thumbnail,
      fingerprint: fingerprint,
      fullResolutionDimensions: dimensions,
      exposureEV: approximateExposureEV(source))
  }

  nonisolated private static func makeStackPreviewSource(
    for url: URL,
    tier: ScanStackPreviewTier
  ) throws -> UInt16Image {
    let isRaw = FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
    switch tier {
    case .draft:
      if isRaw {
        return try decodeRawPreview(url, maxDimension: rawDraftPreviewMaxDimension)
      }
      return try StandardImageDecoder.decodePreview(
        url, maxDimension: displayPreviewMaxDimension)
    case .inspect:
      if isRaw {
        return try decodeRawPreview(url, maxDimension: rawInspectPreviewMaxDimension)
      }
      return try StandardImageDecoder.decodePreview(
        url, maxDimension: rawInspectPreviewMaxDimension)
    case .full:
      if isRaw {
        return try decodeRawPreview(
          url, maxDimension: rawFullPreviewDecodeBound, resizeToBound: false)
      }
      return try StandardImageDecoder.decode(url)
    }
  }

  nonisolated private static func approximateExposureEV(_ image: UInt16Image) -> Double {
    let pixelCount = image.width * image.height
    let step = max(1, pixelCount / 4_096)
    var luminances: [Double] = []
    luminances.reserveCapacity(min(pixelCount, 4_096))
    for pixelIndex in stride(from: 0, to: pixelCount, by: step) {
      let base = pixelIndex * image.channels
      let encoded: Double
      if image.channels == 1 {
        encoded = Double(image.pixels[base]) / Double(UInt16.max)
      } else {
        let blue = Double(image.pixels[base]) / Double(UInt16.max)
        let green = Double(image.pixels[base + 1]) / Double(UInt16.max)
        let red = Double(image.pixels[base + 2]) / Double(UInt16.max)
        encoded = 0.0722 * blue + 0.7152 * green + 0.2126 * red
      }
      guard encoded > 0.001, encoded < 0.999 else { continue }
      let linear =
        encoded <= 0.04045
        ? encoded / 12.92
        : pow((encoded + 0.055) / 1.055, 2.4)
      luminances.append(linear)
    }
    guard !luminances.isEmpty else { return 0 }
    luminances.sort()
    let middle = luminances.count / 2
    let median =
      luminances.count.isMultiple(of: 2)
      ? (luminances[middle - 1] + luminances[middle]) / 2
      : luminances[middle]
    return log2(max(median, 1e-9))
  }
}

/// One selected-file three-pass camera-scan buffer for settings-only re-export.
/// This is not a roll cache and not a second in-flight decode.
struct SelectedFileExportDecodeCache: Equatable, Sendable {
  private(set) var key: String?
  private(set) var image: UInt16Image?

  func image(forKey key: String) -> UInt16Image? {
    guard self.key == key else { return nil }
    return image
  }

  mutating func retain(key: String, image: UInt16Image, selectedKey: String?) {
    guard key == selectedKey else { return }
    self.key = key
    self.image = image
  }

  mutating func dropIfNotSelected(_ selectedKey: String?) {
    guard key != selectedKey else { return }
    removeAll()
  }

  mutating func removeAll() {
    key = nil
    image = nil
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

/// Only point adjustments may publish an intermediate completed revision.
/// Keep geometry and interpretation changes behind a generation boundary.
private struct PreviewRenderContext: Equatable {
  let selection: URL
  let sourceGeneration: Int
  let showOriginal: Bool
  let geometry: ProcessingParameters

  init(
    selection: URL, sourceGeneration: Int,
    parameters: ProcessingParameters, showOriginal: Bool
  ) {
    self.selection = selection
    self.sourceGeneration = sourceGeneration
    self.showOriginal = showOriginal
    // A canonical geometry-only value shares the engine's coordinate types
    // and equality while excluding tone, color, and other point adjustments.
    var geometry = ProcessingParameters(
      borderCrop: parameters.borderCrop,
      flip: parameters.flip,
      rotation: parameters.rotation,
      straightenAngle: parameters.straightenAngle,
      filmType: parameters.filmType,
      densityPipelineEnabled: parameters.densityPipelineEnabled,
      cropRect: parameters.cropRect,
      cropRectCoordinateSpace: parameters.cropRectCoordinateSpace,
      perspectiveCrop: parameters.perspectiveCrop,
      manualCrop: parameters.manualCrop,
      dustRepairs: parameters.dustRepairs)
    geometry.filmNegativeParams.enabled = parameters.filmNegativeParams.enabled
    geometry.filmNegativeParams.rendering = parameters.filmNegativeParams.rendering
    self.geometry = geometry
  }
}

/// Checkpoints sit between synchronous stages. A generation change never
/// interrupts a live engine call or starts an overlapping rendering worker.
enum PreviewRenderCheckpoint: Equatable, Sendable {
  case started
  case gpuOverviewComplete
  case gpuDetailComplete
  case cpuViewportComplete
  case cpuOverviewPacked
  case cpuDetailPacked
  case flatFieldPrepared
  case cpuCorrectionComplete
  case cpuPacked
}

private final class PreviewRenderCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() { lock.withLock { cancelled = true } }
}

private struct PreviewRenderRequest: Sendable {
  let revision: Int
  let contextGeneration: Int
  let cancellation: PreviewRenderCancellation
  let sourceGeneration: Int
  let selection: URL
  let source: UInt16Image
  let renderer: StillPreviewRenderer?
  let overviewRenderer: StillPreviewRenderer?
  let parameters: ProcessingParameters
  let showOriginal: Bool
  let logicalDimensions: PixelDimensions
  let usesContinuousEditPreview: Bool
  let interactionStart: ContinuousClock.Instant
  let submitTime: ContinuousClock.Instant
  let cpuPreparation: CPUPreviewPreparationCache
  let otherCPUPreparation: CPUPreviewPreparationCache?
  let viewportRevision: Int
  let demand: PreviewRenderDemand?
  let cachedResult: RenderedPreview?
  let flatField: UInt16Image?
}

private struct SidebarScanAnalysis: Sendable {
  let thumbnail: CGImage?
  let fingerprint: ScanFingerprint
  let fullResolutionDimensions: PixelDimensions?
  let exposureEV: Double

  var detectionRecord: ScanDetectionRecord {
    ScanDetectionRecord(
      fingerprint: fingerprint,
      fullResolutionDimensions: fullResolutionDimensions,
      exposureEV: exposureEV)
  }
}

private struct ScanDetectionRecord: Sendable {
  let fingerprint: ScanFingerprint
  let fullResolutionDimensions: PixelDimensions?
  let exposureEV: Double
}

enum ScanStackPreviewTier: Int, CaseIterable, Sendable {
  case draft
  case inspect
  case full

  var statusLabel: String {
    switch self {
    case .draft: "preview"
    case .inspect: "inspect"
    case .full: "full-resolution"
    }
  }
}

private struct StackPreviewMemberCache: Sendable {
  let stackID: String
  let tier: ScanStackPreviewTier
  let images: [UInt16Image]
}

private struct PreparedStackCombine: Sendable {
  let result: MultiScanStackResult
  let members: [UInt16Image]
}

private struct PreviewRenderWorkerResult: Sendable {
  let rendered: RenderedPreview?
  let began: ContinuousClock.Instant?
  let finished: ContinuousClock.Instant?
}

private struct PreviewStatisticsRequest: Sendable {
  let revision: Int
  let sourceGeneration: Int
  let sample: RenderedPreviewStatistics
}

private struct CanvasSnapshotRequest: Sendable {
  let key: String
  let image: CGImage
  let parameters: ProcessingParameters
  let logicalDimensions: PixelDimensions
  let sourcePixelDimensions: PixelDimensions?
  let generation: Int
  var byteCount: Int { image.bytesPerRow * image.height }
}
