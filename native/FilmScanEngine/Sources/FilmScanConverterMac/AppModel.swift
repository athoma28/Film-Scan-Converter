import AppKit
import FilmScanEngine
import FilmScanPreviewRenderer
import os.signpost

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var files: [URL] = []
  @Published var selection: URL?
  @Published var selectedFiles: Set<URL> = []
  @Published private(set) var previewImage: NSImage?
  @Published private(set) var thumbnailImages: [String: NSImage] = [:]
  @Published private(set) var thumbnailLoadingPaths: Set<String> = []
  @Published private(set) var detectedScanStacks: [DetectedScanStack] = []
  @Published private(set) var enabledScanStackIDs: Set<String> = []
  @Published private(set) var scanStackModes: [String: ScanStackMode] = [:]
  @Published private(set) var isAnalyzingScanStacks = false
  @Published private(set) var isBuildingScanStack = false
  @Published private(set) var isUpgradingScanStack = false
  @Published private(set) var scanStackStatus = ""
  @Published private(set) var scanStackStatusID: String?
  @Published private(set) var decodedImage: UInt16Image?
  @Published private(set) var parameters = ProcessingParameters()
  @Published private(set) var isRendering = false
  @Published private(set) var isLoading = false
  @Published private(set) var isUpgradingRawPreview = false
  @Published var showOriginal = false {
    didSet {
      resetDustState(cancelTask: true)
      scheduleRender()
    }
  }
  @Published private(set) var status = "Drop film scans into the window to begin."
  @Published private(set) var statusKind: StatusKind = .info
  @Published private(set) var renderStats = RenderStats()
  @Published private(set) var previewStatistics = RenderReadyImageStatistics.empty
  @Published private(set) var previewSourceKind: PreviewSourceKind?
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
  @Published private(set) var appliedPresetName: String?
  @Published private(set) var settingsStatus: String = ""
  @Published private(set) var previewCacheLimit: Int
  @Published private(set) var availableCaptureProfiles: [CaptureProfile] = []
  @Published private(set) var availableFilmStockProfiles: [FilmStockProfile] = []
  @Published private(set) var availableRollProfiles: [RollProfile] = []
  @Published var selectedCaptureProfileID = CaptureProfile.default.id
  @Published var selectedFilmStockProfileID = FilmStockProfile.genericColorNegative.id
  @Published var selectedRollProfileID: String?
  @Published private(set) var profileStatus: String = ""
  @Published private(set) var undoActionName: String?
  @Published private(set) var redoActionName: String?

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
      do {
        let state = try settingsStore.loadState()
        settingsByPath = state.settingsByPath
        editedKeys = state.editedPaths
      } catch {
        setStatus(
          "Saved corrections could not be loaded; defaults are being used.",
          kind: .error)
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
    let appliedPresetName: String?
    let presetRollback: CorrectionSettings?
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
  private var previewCache: [String: CachedPreviewSession] = [:]
  private var previewCacheOrder: [String] = []
  private var previewCacheBytes = 0
  private var previewSource: UInt16Image?
  private var previewRenderer: StillPreviewRenderer?
  private var isPreviewingUncroppedCanvas = false
  private var isPreviewingSourceGeometry = false
  private var presetRollbacks: [String: CorrectionSettings] = [:]
  private var appliedPresetNames: [String: String] = [:]
  private var editHistories: [String: EditHistory<EditingSnapshot>] = [:]
  private var editTransaction: EditTransaction?
  private var loadTask: Task<Void, Never>?
  private var predecodeTask: Task<Void, Never>?
  private var thumbnailTasks: [String: Task<Void, Never>] = [:]
  private var thumbnailCacheOrder: [String] = []
  private var thumbnailCacheBytes = 0
  private var thumbnailByteCounts: [String: Int] = [:]
  private var failedThumbnailPaths: Set<String> = []
  private var scanAnalysisRecords: [String: ScanDetectionRecord] = [:]
  private var scanAnalysisTask: Task<Void, Never>?
  private var scanAnalysisGeneration = 0
  private var scanStackPreviewTask: Task<Void, Never>?
  private var scanStackPreviewGeneration = 0
  private var rebateTask: Task<Void, Never>?
  private var cropDetectionTask: Task<Void, Never>?
  private var dustDetectionTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var pendingRender: PreviewRenderRequest?
  private var activeExportQueue: [URL] = []
  private var activeExportDestinations: [URL] = []
  private var activeExportItemParameters: [ExportParameters] = []
  private var activeExportCorrelationIDs: [String] = []
  private var activeExportQueueWaitIntervals: [AppPerformanceInterval] = []
  private var exportTask: Task<Void, Never>?
  private var exportWasCancelled = false
  private var renderLoopGeneration = 0
  private var lastSubmitTime: Date = .distantPast
  private var lastRenderEnd: ContinuousClock.Instant = .now
  private var pendingFirstPreviewInterval: AppPerformanceInterval?
  private let rawFullPreviewDecodeGate = RawFullPreviewDecodeGate()
  private var rawFullDecodeURL: URL?
  /// Last three-pass camera-scan decode of the selected file. Settings-only
  /// re-export skips unpack and demosaic. Dropped on selection change.
  private var retainedExportDecode = SelectedFileExportDecodeCache()
  /// Test seam that replaces LibRaw for selected-file export-cache tests.
  var fullResolutionExportDecoder: (@Sendable (URL) throws -> UInt16Image)?
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
  /// Bounded sessions exclude the selected full-res buffer. A 4000px inspect
  /// frame is about 57 MiB of UInt16 RGB on the 40MP RAF; a 3200px lookahead
  /// frame is about 25 MiB. This cap therefore holds about four inspect frames
  /// or about ten lookahead frames before LRU demotion or eviction.
  nonisolated static let previewCacheByteLimit = 256 * 1_024 * 1_024
  nonisolated static let thumbnailMaxDimension = 192
  nonisolated static let thumbnailCacheCountLimit = 256
  nonisolated static let thumbnailCacheByteLimit = 48 * 1_024 * 1_024
  nonisolated static let maximumScanStackMembers = 8

  var previewCacheSessionCount: Int {
    previewCache.count
  }

  var previewCachePhysicalBytes: Int { previewCacheBytes }

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
      && !isUpgradingRawPreview
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

  /// Upcoming unseen files after `selected`, capped by the cache budget and
  /// decoded at the 3200px lookahead bound. Visited files keep their inspect
  /// preview through the normal cache; they are not re-queued here.
  nonisolated static func previewLookahead(
    files: [URL],
    selected: URL,
    cacheLimit: Int
  ) -> [URL] {
    guard let index = files.firstIndex(of: selected) else { return [] }
    let budget = max(0, cacheLimit - 1)
    let upcoming = Array(files.dropFirst(index + 1).prefix(budget))
    return Array(upcoming.prefix(rawLookaheadDetailCount))
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
  func requestThumbnail(for url: URL) {
    let key = settingsKey(url)
    guard thumbnailImages[key] == nil,
      thumbnailTasks[key] == nil,
      !thumbnailLoadingPaths.contains(key),
      !failedThumbnailPaths.contains(key)
    else {
      if thumbnailImages[key] != nil { touchThumbnailCache(key) }
      return
    }

    thumbnailLoadingPaths.insert(key)
    let task = Task { [weak self] in
      let worker = Task.detached(priority: .utility) {
        try? Self.makeSidebarScanAnalysis(for: url)
      }
      let analysis = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self else { return }
      self.thumbnailTasks[key] = nil
      self.thumbnailLoadingPaths.remove(key)
      guard let analysis else {
        self.failedThumbnailPaths.insert(key)
        return
      }
      self.publishSidebarScanAnalysis(analysis, for: url)
    }
    thumbnailTasks[key] = task
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
      scanStackStatus = "Stack disabled; showing the reference capture."
      scanStackStatusID = stack.id
      if selection.map(stack.contains) == true { loadSelection() }
    }
  }

  func setScanStackMode(_ mode: ScanStackMode, for stack: DetectedScanStack) {
    guard !isExporting, !isAnalyzingScanStacks else { return }
    scanStackModes[stack.id] = mode
    guard enabledScanStackIDs.contains(stack.id) else { return }
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

  private static let renderLog = OSLog(
    subsystem: "film.scan.converter", category: "StillPreview")
  private static let signpostLog = OSLog(
    subsystem: "film.scan.converter", category: "Signpost")

  func importFiles(_ urls: [URL]) {
    guard !isExporting else {
      setStatus("Wait for the active export to finish before importing more scans.", kind: .error)
      return
    }
    let supported = FileDropPolicy.supportedFiles(from: urls)
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
    schedulePreviewWork(after: selection)
  }

  private var loadGeneration = 0
  private var rebateGeneration = 0

  func loadSelection() {
    endEditingGesture()
    isPreviewingUncroppedCanvas = false
    isPreviewingSourceGeometry = false
    retainedExportDecode.dropIfNotSelected(selection.map(settingsKey))
    refreshHistoryAvailability()
    scanStackPreviewGeneration += 1
    scanStackPreviewTask?.cancel()
    scanStackPreviewTask = nil
    isBuildingScanStack = false
    isUpgradingScanStack = false
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

    guard let selection else {
      previewImage = nil
      decodedImage = nil
      previewSource = nil
      previewRenderer = nil
      previewStatistics = .empty
      previewSourceKind = nil
      appliedPresetName = nil
      isLoading = false
      isUpgradingRawPreview = false
      sourcePixelDimensions = nil
      cancelPredecode()
      setStatus("Drop film scans into the window to begin.")
      refreshHistoryAvailability()
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
    demoteUnselectedFullResPreviews()
    ImportLog.loadSelectionStarted(path: selection.lastPathComponent)

    decodedImage = nil
    previewSource = nil
    previewRenderer = nil
    previewSourceKind = nil
    let key = settingsKey(selection)
    let hasStoredSettings = settingsByPath[key] != nil
    parameters = settingsByPath[key] ?? ProcessingParameters()
    appliedPresetName = appliedPresetNames[key]
    cropRect = parameters.cropRect
    perspectiveCrop = parameters.perspectiveCrop
    manualCrop = parameters.manualCrop
    straightenAngle = parameters.straightenAngle
    showOriginal = false
    refreshHistoryAvailability()

    if let cached = previewCache[key] {
      ImportLog.loadSelectionCacheHit(path: selection.lastPathComponent)
      isLoading = false
      applyCachedSession(cached, selection: selection)
      touchPreviewCache(key)
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
      loadTask = Task { [weak self] in
        guard let self else { return }
        let conversionInterval = AppPerformanceSignposts.begin(
          .previewConversion, correlationID: loadCorrelationID,
          filename: selection.lastPathComponent)
        let session = await Task.detached(priority: .userInitiated) { () -> CachedPreviewSession? in
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
        }.value
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
          session, selection: selection, hasStoredSettings: hasStoredSettings)
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
        if hasStoredSettings {
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
    if selection?.standardizedFileURL == files.first?.standardizedFileURL,
      value != .cropOnly
    {
      sameRollFilmTypeHint = value
      reclassifyAutomaticBatchGuesses()
    }
    let medians =
      value == .blackAndWhiteNegative || value == .colourNegative
      ? computeFilmNegativeMedians()
      : nil
    if value == .blackAndWhiteNegative {
      selectedFilmStockProfileID = FilmStockProfile.genericBW.id
    } else if value == .colourNegative {
      selectedFilmStockProfileID = FilmStockProfile.genericColorNegative.id
    }
    updateParameters(actionName: "Film Type") {
      $0.filmType = value
      switch value {
      case .blackAndWhiteNegative:
        $0.filmNegativeParams = .blackAndWhite
        $0.filmNegativeParams.measuredMedians = medians
      case .colourNegative:
        $0.filmNegativeParams = .colourNegative
        $0.filmNegativeParams.measuredMedians = medians
      case .slide, .cropOnly:
        $0.filmNegativeParams.enabled = false
      }
    }
  }

  func setTemperature(_ value: Int) {
    updateParameters(actionName: "Temperature") {
      $0.temperature = value
      $0.photoAdjustments.updateColorIntentFromLegacy(
        temperature: value,
        tint: $0.tint,
        saturation: $0.saturation
      )
    }
  }

  func setSemanticTemperature(_ value: Double) {
    updateParameters(actionName: "Temperature") {
      $0.photoAdjustments.temperatureShiftMired = min(
        max(value, PhotoAdjustmentParameters.temperatureShiftRangeMired.lowerBound),
        PhotoAdjustmentParameters.temperatureShiftRangeMired.upperBound
      )
      $0.syncLegacyColorFieldsFromPhotoAdjustments()
    }
  }

  func setTint(_ value: Int) {
    updateParameters(actionName: "Tint") {
      $0.tint = value
      $0.photoAdjustments.updateColorIntentFromLegacy(
        temperature: $0.temperature,
        tint: value,
        saturation: $0.saturation
      )
    }
  }

  func setSemanticTint(_ value: Double) {
    updateParameters(actionName: "Tint") {
      $0.photoAdjustments.tint = min(
        max(value, PhotoAdjustmentParameters.tintRange.lowerBound),
        PhotoAdjustmentParameters.tintRange.upperBound
      )
      $0.syncLegacyColorFieldsFromPhotoAdjustments()
    }
  }

  func setSaturation(_ value: Int) {
    updateParameters(actionName: "Saturation") {
      $0.saturation = value
      $0.photoAdjustments.updateColorIntentFromLegacy(
        temperature: $0.temperature,
        tint: $0.tint,
        saturation: value
      )
    }
  }

  func setSemanticSaturation(_ value: Double) {
    updateParameters(actionName: "Saturation") {
      $0.photoAdjustments.saturation = min(
        max(value, PhotoAdjustmentParameters.saturationRange.lowerBound),
        PhotoAdjustmentParameters.saturationRange.upperBound
      )
      $0.syncLegacyColorFieldsFromPhotoAdjustments()
    }
  }

  func setVibrance(_ value: Double) {
    updateParameters(actionName: "Vibrance") {
      $0.photoAdjustments.vibrance = min(
        max(value, PhotoAdjustmentParameters.vibranceRange.lowerBound),
        PhotoAdjustmentParameters.vibranceRange.upperBound
      )
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
    updateParameters(actionName: "Exposure") { $0.photoAdjustments.exposureEV = value }
  }

  func setBrightness(_ value: Double) {
    updateParameters(actionName: "Brightness") { $0.photoAdjustments.brightness = value }
  }

  func setContrast(_ value: Double) {
    updateParameters(actionName: "Contrast") { $0.photoAdjustments.contrast = value }
  }

  func setSemanticHighlights(_ value: Double) {
    updateParameters(actionName: "Highlights") { $0.photoAdjustments.highlights = value }
  }

  func setSemanticShadows(_ value: Double) {
    updateParameters(actionName: "Shadows") { $0.photoAdjustments.shadows = value }
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

  func setHighlightWheelHue(_ value: Double) {
    updateParameters(actionName: "Highlights Color Wheel") { $0.highlightWheel.hue = value }
  }

  func setHighlightWheelStrength(_ value: Double) {
    updateParameters(actionName: "Highlights Color Wheel") { $0.highlightWheel.strength = value }
  }

  func setMidtoneWheelHue(_ value: Double) {
    updateParameters(actionName: "Midtones Color Wheel") { $0.midtoneWheel.hue = value }
  }

  func setMidtoneWheelStrength(_ value: Double) {
    updateParameters(actionName: "Midtones Color Wheel") { $0.midtoneWheel.strength = value }
  }

  func setShadowWheelHue(_ value: Double) {
    updateParameters(actionName: "Shadows Color Wheel") { $0.shadowWheel.hue = value }
  }

  func setShadowWheelStrength(_ value: Double) {
    updateParameters(actionName: "Shadows Color Wheel") { $0.shadowWheel.strength = value }
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

  func setFilmNegativeGreenExp(_ value: Double) {
    updateParameters(actionName: "Negative Profile") { $0.filmNegativeParams.greenExp = value }
  }

  func setFilmNegativeBlueRatio(_ value: Double) {
    updateParameters(actionName: "Negative Profile") { $0.filmNegativeParams.blueRatio = value }
  }

  func setCalibratedNegativeExposure(_ value: Double) {
    updateParameters(actionName: "Negative Exposure") {
      $0.filmNegativeParams.monochromeExposureEV = value
    }
  }

  func setDensityUnmixStrength(_ value: Double) {
    updateParameters(actionName: "Dye Unmix") {
      $0.filmNegativeParams.densityUnmixStrength = min(max(value, 0), 1)
    }
  }

  func setDensityProfileID(_ id: String) {
    updateParameters(actionName: "Physical Stock") {
      let profile = NegativeDensityProfileCatalog.profile(id: id)
      $0.filmNegativeParams.rendering = .densityPrint
      $0.filmNegativeParams.enabled = true
      $0.filmNegativeParams.densityProfileID = profile.id.rawValue
      $0.filmNegativeParams.densityUnmixRGB = profile.unmixRGBFlat
    }
  }

  func setDensityPaperID(_ id: String) {
    updateParameters(actionName: "Print Paper") {
      $0.filmNegativeParams.densityPaperID =
        DensityPaperProfileCatalog.profile(id: id).id.rawValue
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
        let paper = $0.filmNegativeParams.densityPaperID
        $0.filmNegativeParams = FilmNegativeParams.densityPrintGenericC41
        $0.filmNegativeParams.densityPaperID = paper
      case .densityPrintHarmanPhoenixII:
        $0.filmNegativeParams = FilmNegativeParams.densityPrintHarmanPhoenixII
      case .densityPrintFuji400:
        let paper = $0.filmNegativeParams.densityPaperID
        $0.filmNegativeParams = FilmNegativeParams.densityPrintFuji400
        $0.filmNegativeParams.densityPaperID = paper
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

  func applyKodachromeLikeLook() {
    applyAdaptiveDisplayLook(.kodachromeLike)
  }

  func applyAdaptiveDisplayLook(_ look: AdaptiveDisplayLook) {
    guard let source = previewSource, source.channels == 3 else {
      settingsStatus = "\(look.name) needs a loaded color scan."
      return
    }
    beginEditingGesture(named: look.name)
    capturePresetRollback(named: look.name)
    let applied = look.parameters(for: source, preserving: parameters)
    updateParameters(actionName: look.name) { $0 = applied }
    endEditingGesture()
    settingsStatus = "Applied \(look.name)."
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
    parameters = ProcessingParameters()
    clearPresetRollback()
    straightenAngle = 0
    if let selection { editedKeys.insert(settingsKey(selection)) }
    resetCropState(cancelTask: true)
    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender(immediate: true)
    }
    recordCurrentEdit(actionName: "Reset Corrections", before: historyBefore)
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
      applyCorrectionSettings(settings, actionName: "Paste Corrections")
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
    beginEditingGesture(named: "Apply \(preset.name)")
    capturePresetRollback(named: preset.name)
    applyCorrectionSettings(preset.settings, actionName: "Apply \(preset.name)")
    endEditingGesture()
    settingsStatus = "Applied preset “\(preset.name)”."
  }

  func removeAppliedPreset() {
    guard let selection else { return }
    let key = settingsKey(selection)
    guard let rollback = presetRollbacks[key] else { return }
    beginEditingGesture(named: "Remove \(appliedPresetNames[key] ?? "Preset")")
    presetRollbacks.removeValue(forKey: key)
    let name = appliedPresetNames.removeValue(forKey: key) ?? "preset"
    appliedPresetName = nil
    applyCorrectionSettings(rollback, actionName: "Remove \(name)")
    endEditingGesture()
    settingsStatus = "Removed “\(name)” and restored the previous adjustments."
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
    let historyBefore = currentEditingSnapshot()
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
    recordCurrentEdit(actionName: actionName, before: historyBefore)
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
    endEditingGesture()
    let settings = CorrectionSettings(capturing: parameters)
    for url in targets {
      let key = settingsKey(url)
      let historyBefore = editingSnapshot(for: key)
      let destination = settingsByPath[key] ?? ProcessingParameters()
      var applied = settings.applying(to: destination)
      applied.filmNegativeParams.measuredMedians = nil
      settingsByPath[key] = applied
      editedKeys.insert(key)
      recordEdit(
        for: key,
        actionName: actionName,
        before: historyBefore,
        after: editingSnapshot(for: key)
      )
    }
    persistSettings()
    refreshHistoryAvailability()
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

  func addSelectedToExportQueue() {
    let urls = consolidatedExportURLs(orderedSelectedFiles)
    guard isExporting, !urls.isEmpty,
      let destinationDirectory = exportParameters.destinationDirectory
    else {
      return
    }

    let itemParameters = exportParameters
    let destinations: [URL]
    do {
      destinations = try reserveDestinationURLs(
        for: urls,
        destinationDirectory: destinationDirectory,
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
      activeExportItemParameters.append(itemParameters)
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
    guard !isExporting else {
      rebateStatus = "Wait for the active export to finish before changing the flat field."
      return
    }
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
      scanStackStatus =
        "Stack disabled because flat-field correction must be applied before alignment."
      scanStackStatusID = nil
      loadSelection()
    } else {
      scheduleRender(immediate: true)
    }
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
    let displayParameters = previewDisplayParameters
    dustDetectionTask = Task { [weak self] in
      guard let self else { return }
      let mask = await Task.detached(priority: .userInitiated) {
        DustDetection.findMask(in: source)
      }.value
      guard !Task.isCancelled, self.selection == selectedURL else { return }
      let croppedMask =
        displayParameters.perspectiveCrop.flatMap {
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
      let finalMask =
        displayParameters.manualCrop.flatMap {
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
      self.dustMaskImage = PreviewBitmap.nsImage(from: cgImage)
      self.isDustDetectionRunning = false
      let detected = mask.pixels.reduce(into: 0) { count, value in
        if value != 0 { count += 1 }
      }
      self.dustStatus =
        detected == 0
        ? "No dust candidates found."
        : "Showing \(detected) dust-mask pixels."
    }
  }

  func clearDustMask() {
    resetDustState(cancelTask: true)
  }

  func clearCrop() {
    let historyBefore = currentEditingSnapshot()
    resetCropState(cancelTask: true)
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
    setPerspectiveCrop(
      PerspectiveCrop(
        topLeft: .init(x: 0.06, y: 0.06),
        topRight: .init(x: 0.94, y: 0.06),
        bottomRight: .init(x: 0.94, y: 0.94),
        bottomLeft: .init(x: 0.06, y: 0.94)
      ))
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
    let historyBefore = currentEditingSnapshot()
    resetDustState(cancelTask: true)
    cropRect = nil
    perspectiveCrop = crop
    parameters.cropRect = nil
    parameters.perspectiveCrop = crop
    cropStatus = "Perspective warp is active. Drag corners to align the grid."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
    recordCurrentEdit(actionName: "Perspective", before: historyBefore)
  }

  func clearPerspectiveCrop() {
    guard perspectiveCrop != nil || parameters.perspectiveCrop != nil else { return }
    let historyBefore = currentEditingSnapshot()
    resetDustState(cancelTask: true)
    perspectiveCrop = nil
    parameters.perspectiveCrop = nil
    cropStatus = manualCrop == nil ? "" : "Manual canvas crop is active."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
    recordCurrentEdit(actionName: "Clear Perspective", before: historyBefore)
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
    let historyBefore = currentEditingSnapshot()
    resetDustState(cancelTask: true)
    manualCrop = crop
    parameters.manualCrop = crop
    cropStatus = "Manual canvas crop is active."
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
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
    resetDustState(cancelTask: true)
    manualCrop = nil
    parameters.manualCrop = nil
    cropStatus = ""
    if let selection { editedKeys.insert(settingsKey(selection)) }
    saveParameters()
    scheduleRender(immediate: true)
    recordCurrentEdit(actionName: "Clear Crop", before: historyBefore)
  }

  func setStraightenAngle(_ angle: Double) {
    guard angle.isFinite else { return }
    let clamped = min(max(angle, -45), 45)
    guard abs(parameters.straightenAngle - clamped) > 0.000_001 else { return }
    let historyBefore = currentEditingSnapshot()
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
    let historyBefore = currentEditingSnapshot()
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
    guard !urls.isEmpty else { return }
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
    guard let destDir = exportParameters.destinationDirectory else {
      setStatus("Select an export destination folder first.", kind: .error)
      return
    }

    // Export has priority over speculative lookahead work. The decoder may
    // finish its current synchronous call, but cancellation prevents it from
    // advancing through the rest of the lookahead queue.
    cancelPredecode()
    cancelScanStackUpgradePreservingPreview()

    var params = exportParameters
    params.destinationDirectory = destDir
    let exportParams = params
    activeExportQueue = urls
    activeExportItemParameters = Array(repeating: exportParams, count: urls.count)
    exportQueueCount = max(0, urls.count - 1)
    do {
      activeExportDestinations = try reserveDestinationURLs(
        for: urls, destinationDirectory: destDir, format: exportParams.format)
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
        let nextIsFullResolutionRAW =
          index + 1 < self.activeExportQueue.count
          && Self.requiresFullResolutionExportDecode(self.activeExportQueue[index + 1])
        let currentIsStack = self.enabledScanStack(containing: firstURL) != nil
        let nextIsStack =
          index + 1 < self.activeExportQueue.count
          && self.enabledScanStack(containing: self.activeExportQueue[index + 1]) != nil
        let batchSize =
          Self.requiresFullResolutionExportDecode(firstURL) || nextIsFullResolutionRAW
            || currentIsStack || nextIsStack
          ? 1 : 2
        let endIndex = min(index + batchSize, self.activeExportQueue.count)
        var requests: [ExportManager.ExportRequest] = []
        for requestIndex in index..<endIndex {
          let url = self.activeExportQueue[requestIndex]
          let destinationURL = self.activeExportDestinations[requestIndex]
          let itemParameters = self.activeExportItemParameters[requestIndex]
          let correlationID = self.activeExportCorrelationIDs[requestIndex]
          AppPerformanceSignposts.end(self.activeExportQueueWaitIntervals[requestIndex])
          do {
            requests.append(
              try await self.makeExportRequest(
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
        self.activeExportItemParameters = []
        self.activeExportCorrelationIDs = []
        self.activeExportQueueWaitIntervals = []
        self.exportTask = nil
        self.exportQueueCount = 0
        let failures = results.filter { !$0.isSuccess }
        if wasCancelled {
          self.exportErrors = []
          self.setStatus(
            "Export cancelled after \(self.exportProgressCurrent) of \(self.exportProgressTotal) images."
          )
        } else if failures.isEmpty {
          self.setStatus(
            "Exported \(results.count) image\(results.count == 1 ? "" : "s") to \(destDir.lastPathComponent)."
          )
        } else {
          self.exportErrors = failures.compactMap { result in
            result.error.map { "\(result.sourceURL.lastPathComponent): \($0.localizedDescription)" }
          }
          self.setStatus(
            "Export complete with \(failures.count) error\(failures.count == 1 ? "" : "s").",
            kind: .error)
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

  private func populateFilmNegativeMedians(from image: UInt16Image) {
    guard image.channels == 3 else { return }
    parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
      image: image, borderPercent: 20.0)
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
    if let stored = settingsByPath[key] {
      fileParams = stored
    } else {
      let proxy = decoded.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension)
      let automatic = Self.automaticallyClassifiedParameters(
        base: ProcessingParameters(),
        image: proxy,
        weakPrior: sameRollFilmTypeHint
      )
      settingsByPath[key] = automatic
      automaticallyClassifiedKeys.insert(key)
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
      let gate = rawFullPreviewDecodeGate
      let image = try await Task.detached(priority: .userInitiated) {
        try await gate.run {
          if let decoder {
            return try decoder(url)
          }
          return try RawImageDecoder.decode(
            url,
            fullResolution: true,
            profile: .rawTherapeeCameraScan
          ).image
        }
      }.value
      fullResolutionExportDecodeCount += 1
      retainedExportDecode.retain(
        key: key,
        image: image,
        selectedKey: selection.map(settingsKey)
      )
      return image
    }
    return try await Task.detached(priority: .userInitiated) {
      return try Self.decodeImage(url)
    }.value
  }

  private func decodedScanStackForExport(
    _ stack: DetectedScanStack,
    mode: ScanStackMode
  ) async throws -> UInt16Image {
    scanStackStatusID = stack.id
    guard let firstMember = stack.members.first else {
      throw ScanStackError.insufficientImages
    }
    scanStackStatus =
      "Decoding stack capture 1 of \(stack.members.count): \(firstMember.lastPathComponent)"
    var composite = try await decodedImageForExport(firstMember)
    var effectiveMode = mode == .automatic ? ScanStackMode.noiseReduction : mode
    var automaticUsedHDR = false

    for (index, member) in stack.members.enumerated().dropFirst() {
      try Task.checkCancellation()
      scanStackStatus =
        "Decoding stack capture \(index + 1) of \(stack.members.count): \(member.lastPathComponent)"
      let candidate = try await decodedImageForExport(member)
      try Task.checkCancellation()
      scanStackStatus =
        "Aligning and combining capture \(index + 1) of \(stack.members.count)..."
      // Weight the existing composite by the number of captures it already
      // represents. Array copies share the immutable UInt16 pixel storage, so
      // only the composite, current candidate, and new output are resident.
      let accumulated = composite
      let worker = Task.detached(priority: .userInitiated) {
        let weightedComposite = Array(repeating: accumulated, count: index)
        return try MultiScanStacker.combine(
          images: weightedComposite + [candidate],
          mode: mode)
      }
      let result = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      composite = result.image
      if mode == .automatic {
        automaticUsedHDR = automaticUsedHDR || result.effectiveMode == .hdr
        effectiveMode = automaticUsedHDR ? .hdr : .noiseReduction
      }
    }
    try Task.checkCancellation()
    scanStackStatus =
      "Built full-resolution \(Self.scanStackModeLabel(effectiveMode)) stack from \(stack.members.count) captures."
    return composite
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
    destinationDirectory: URL,
    format: ExportFormat,
    alreadyReserved: [URL] = []
  ) throws -> [URL] {
    let existingNames = try FileManager.default.contentsOfDirectory(
      at: destinationDirectory,
      includingPropertiesForKeys: nil
    ).map { $0.lastPathComponent.lowercased() }
    var reservedNames = Set(existingNames)
    reservedNames.formUnion(
      alreadyReserved
        .filter {
          $0.deletingLastPathComponent().standardizedFileURL
            == destinationDirectory.standardizedFileURL
        }
        .map { $0.lastPathComponent.lowercased() })

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
    case .fuji400FreshAlternate:
      next.filmNegativeParams = FilmNegativeParams.fuji400FreshAlternate
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .fuji200ExpiredAlternate:
      next.filmNegativeParams = FilmNegativeParams.fuji200ExpiredAlternate
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .cinestill800TAlternate:
      next.filmNegativeParams = FilmNegativeParams.cinestill800TAlternate
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .harmanPhoenixIIAlternate:
      next.filmNegativeParams = FilmNegativeParams.harmanPhoenixIIAlternate
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .densityPrintGenericC41:
      let paper = next.filmNegativeParams.densityPaperID
      next.filmNegativeParams = FilmNegativeParams.densityPrintGenericC41
      next.filmNegativeParams.densityPaperID = paper
    case .densityPrintHarmanPhoenixII:
      next.filmNegativeParams = FilmNegativeParams.densityPrintHarmanPhoenixII
    case .densityPrintFuji400:
      let paper = next.filmNegativeParams.densityPaperID
      next.filmNegativeParams = FilmNegativeParams.densityPrintFuji400
      next.filmNegativeParams.densityPaperID = paper
    case .legacyColourNegative:
      next.filmNegativeParams = FilmNegativeParams.legacyColourNegative
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .blackAndWhite:
      next.filmNegativeParams = FilmNegativeParams.blackAndWhite
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .shanghaiGP3Alternate:
      next.filmNegativeParams = FilmNegativeParams.shanghaiGP3Alternate
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    case .legacyBlackAndWhite:
      next.filmNegativeParams = FilmNegativeParams.legacyBlackAndWhite
      next.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    }
    return next
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
  }

  func endEditingGesture() {
    guard let transaction = editTransaction else { return }
    editTransaction = nil
    recordEdit(
      for: transaction.key,
      actionName: transaction.actionName,
      before: transaction.before,
      after: editingSnapshot(for: transaction.key)
    )
    refreshHistoryAvailability()
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
      snapshotParameters = parameters
    } else {
      snapshotParameters = settingsByPath[key] ?? ProcessingParameters()
    }
    return EditingSnapshot(
      parameters: snapshotParameters,
      framePercent: exportParameters.framePercent,
      aspectRatio: exportParameters.aspectRatio,
      wasEdited: editedKeys.contains(key),
      wasAutomaticallyClassified: automaticallyClassifiedKeys.contains(key),
      appliedPresetName: appliedPresetNames[key],
      presetRollback: presetRollbacks[key]
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
    resetDustState(cancelTask: true)
    isPreviewingUncroppedCanvas = false
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
    if let name = snapshot.appliedPresetName {
      appliedPresetNames[key] = name
    } else {
      appliedPresetNames.removeValue(forKey: key)
    }
    if let rollback = snapshot.presetRollback {
      presetRollbacks[key] = rollback
    } else {
      presetRollbacks.removeValue(forKey: key)
    }
    appliedPresetName = snapshot.appliedPresetName

    saveParameters()
    if showOriginal {
      showOriginal = false
    } else {
      scheduleRender(immediate: true)
    }
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
    _ update: (inout ProcessingParameters) -> Void
  ) {
    let historyBefore = currentEditingSnapshot()
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
    recordCurrentEdit(actionName: actionName, before: historyBefore)
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
      setStatus(
        "Corrections changed, but could not be saved for the next launch.",
        kind: .error)
    }
  }

  private func applyCachedSession(_ session: CachedPreviewSession, selection: URL) {
    applyPreviewSession(
      session, selection: selection,
      hasStoredSettings: settingsByPath[settingsKey(selection)] != nil)
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
    previewRenderer = session.previewRenderer
    previewSourceKind = session.sourceKind
    sourcePixelDimensions = session.sourcePixelDimensions
    isLoading = false
    if session.sourceKind == .rawFull {
      isUpgradingRawPreview = false
    }
    if hasStoredSettings {
      if recalibrateFromSource {
        populateFilmNegativeMedians(from: session.analysisSource)
      }
    } else {
      applyAutomaticFilmClassification(from: session.analysisSource)
    }
    scheduleEnabledScanStackPreview(for: selection)
  }

  private func schedulePreviewWork(after selection: URL) {
    guard !isExporting else { return }
    guard files.contains(selection) else { return }

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
      isRaw && !blockedByStack && currentRank < PreviewSourceKind.rawDetail.qualityRank
    let needsSelectedFullRes =
      isRaw && !blockedByStack && currentRank < PreviewSourceKind.rawFull.qualityRank
    let lookahead = Self.previewLookahead(
      files: files, selected: selection, cacheLimit: previewCacheLimit)
    guard needsSelectedInspect || needsSelectedFullRes || !lookahead.isEmpty else {
      return
    }

    let generation = loadGeneration
    predecodeTask?.cancel()
    if needsSelectedInspect || needsSelectedFullRes {
      isUpgradingRawPreview = true
    }

    predecodeTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == self.loadGeneration {
          self.isUpgradingRawPreview = false
        }
      }
      if needsSelectedInspect {
        await self.decodeAndCacheRawInspect(selection, generation: generation)
      }
      if needsSelectedFullRes {
        async let fullWork: Void = self.decodeAndCacheRawFull(
          selection, generation: generation)
        async let lookaheadWork: Void = self.prefetchLookahead(
          lookahead, generation: generation)
        _ = await (fullWork, lookaheadWork)
      } else {
        await self.prefetchLookahead(lookahead, generation: generation)
      }
    }
  }

  private func prefetchLookahead(_ urls: [URL], generation: Int) async {
    for url in urls {
      guard !Task.isCancelled, generation == loadGeneration else { return }
      await decodeAndCachePreviewTier(
        url, generation: generation, applyIfSelected: true)
    }
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

    do {
      let session = try await Task.detached(priority: .userInitiated) {
        try Self.makeRawPreviewSession(
          for: url,
          maxDimension: Self.rawInspectPreviewMaxDimension,
          kind: .rawInspect)
      }.value
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
    generation: Int
  ) async {
    guard FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) else { return }
    if previewCache[settingsKey(url)]?.sourceKind == .rawFull { return }
    if selection == url, enabledScanStack(containing: url) != nil { return }
    if rawFullDecodeURL == url { return }
    rawFullDecodeURL = url
    defer {
      if rawFullDecodeURL == url { rawFullDecodeURL = nil }
    }

    let gate = rawFullPreviewDecodeGate
    do {
      let session = try await Task.detached(priority: .userInitiated) {
        try await gate.run {
          try Self.makeRawFullPreviewSession(for: url)
        }
      }.value
      // Keep at most one full-res preview: only retain it while this file is
      // still selected. Switching away demotes the previous file to the 4000px
      // inspect preview.
      guard selection == url, enabledScanStack(containing: url) == nil else { return }
      cacheSession(session, for: url)
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

    do {
      let session = try await Task.detached(priority: .utility) { () -> CachedPreviewSession in
        if isRaw {
          return try Self.makeRawPreviewSession(
            for: url,
            maxDimension: Self.rawDetailPreviewMaxDimension,
            kind: desiredKind)
        }
        return try Self.makeFastPreviewSession(for: url)
      }.value
      cacheSession(session, for: url)
      if settingsByPath[key] == nil {
        settingsByPath[key] = Self.automaticallyClassifiedParameters(
          base: ProcessingParameters(), image: session.analysisSource,
          weakPrior: sameRollFilmTypeHint)
        automaticallyClassifiedKeys.insert(key)
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
    }
  }

  private func cacheCurrentSession(for selection: URL) {
    guard let previewSource, let previewRenderer else {
      return
    }
    cacheSession(
      CachedPreviewSession(
        sourceKind: previewSourceKind ?? .rawDetail,
        displaySource: previewSource,
        analysisSource: previewSource.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension),
        previewRenderer: previewRenderer,
        sourcePixelDimensions: sourcePixelDimensions
      ),
      for: selection
    )
  }

  private func cacheSession(
    _ session: CachedPreviewSession,
    for url: URL,
    allowDowngrade: Bool = false
  ) {
    let key = settingsKey(url)
    if !allowDowngrade,
      let existing = previewCache[key],
      existing.sourceKind.qualityRank > session.sourceKind.qualityRank
    {
      return
    }
    replaceCachedSession(session, for: key)
    trimPreviewCache()
  }

  private func replaceCachedSession(_ session: CachedPreviewSession, for key: String) {
    if let previous = previewCache[key] { previewCacheBytes -= previous.byteCount }
    previewCache[key] = session
    previewCacheBytes += session.byteCount
    touchPreviewCache(key)
  }

  private func trimPreviewCache() {
    demoteUnselectedFullResPreviews()
    let selectedKey = selection.map { settingsKey($0) }
    while boundedPreviewCacheBytes > Self.previewCacheByteLimit {
      guard
        let key = previewCacheOrder.first(where: {
          $0 != selectedKey && previewCache[$0]?.sourceKind == .rawInspect
        })
      else { break }
      guard let session = previewCache[key] else { break }
      replaceCachedSession(Self.demotedSession(from: session, kind: .rawDetail), for: key)
    }
    while previewCacheOrder.count > previewCacheLimit
      || boundedPreviewCacheBytes > Self.previewCacheByteLimit
    {
      guard let evicted = previewCacheOrder.first(where: { $0 != selectedKey }) else {
        break
      }
      previewCacheOrder.removeAll { $0 == evicted }
      if let removed = previewCache.removeValue(forKey: evicted) {
        previewCacheBytes -= removed.byteCount
      }
    }
  }

  private var boundedPreviewCacheBytes: Int {
    previewCache.values.reduce(0) { partial, session in
      session.sourceKind == .rawFull ? partial : partial + session.byteCount
    }
  }

  private func demoteUnselectedFullResPreviews() {
    let selectedKey = selection.map { settingsKey($0) }
    let fullKeys = previewCache.compactMap { key, session -> String? in
      session.sourceKind == .rawFull && key != selectedKey ? key : nil
    }
    for key in fullKeys {
      guard let session = previewCache[key] else { continue }
      let demoted = Self.demotedSession(from: session, kind: .rawInspect)
      guard demoted.sourceKind == .rawInspect else { continue }
      replaceCachedSession(demoted, for: key)
    }
  }

  private func touchPreviewCache(_ key: String) {
    previewCacheOrder.removeAll { $0 == key }
    previewCacheOrder.append(key)
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

    // Invert the embedded JPEG / ImageIO thumbnail with CIColorInvert into
    // named sRGB. A 16-bit DeviceRGB complement looked uninverted in the
    // sidebar because SwiftUI swapped red/blue on that bitmap.
    if thumbnailImages[key] == nil,
      let cgImage = analysis.thumbnailSource.makePreviewCGImage(),
      let thumbnail = PreviewBitmap.invertedNSImage(from: cgImage)
    {
      let byteCount = analysis.thumbnailSource.width * analysis.thumbnailSource.height * 4
      thumbnailImages[key] = thumbnail
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
    isBuildingScanStack = true
    isUpgradingScanStack = false
    scanStackStatus = "Aligning \(stack.members.count) captures..."
    scanStackStatusID = stack.id

    scanStackPreviewTask = Task { [weak self] in
      guard let self else { return }
      var appliedImage: UInt16Image?
      do {
        for tier in ScanStackPreviewTier.allCases {
          try Task.checkCancellation()
          guard
            self.stackPreviewSessionIsCurrent(
              generation: generation, selectedURL: selectedURL, stack: stack)
          else { return }
          if let appliedImage, self.stackPreviewCoversSource(appliedImage) {
            break
          }

          if appliedImage != nil {
            self.isBuildingScanStack = false
            self.isUpgradingScanStack = true
            self.scanStackStatus = "Loading \(tier.statusLabel) stack..."
          }

          let result: MultiScanStackResult
          do {
            result = try await self.combinedStackResult(
              stack: stack, mode: mode, tier: tier)
          } catch {
            if appliedImage == nil { throw error }
            continue
          }
          try Task.checkCancellation()
          guard
            self.stackPreviewSessionIsCurrent(
              generation: generation, selectedURL: selectedURL, stack: stack)
          else { return }

          try self.applyAlignedStackPreview(
            result,
            stack: stack,
            calibrateFromSource: appliedImage == nil)
          appliedImage = result.image
        }
        guard
          self.stackPreviewSessionIsCurrent(
            generation: generation, selectedURL: selectedURL, stack: stack)
        else { return }
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
          self.scanStackStatus =
            "Showing the bounded stack; full-resolution upgrade failed: \(error.localizedDescription)"
        } else {
          self.scanStackStatus = "Stack could not be built: \(error.localizedDescription)"
          self.setStatus(self.scanStackStatus, kind: .error)
        }
      }
    }
  }

  private func combinedStackResult(
    stack: DetectedScanStack,
    mode: ScanStackMode,
    tier: ScanStackPreviewTier
  ) async throws -> MultiScanStackResult {
    if tier == .full {
      return try await combinedFullResolutionStackPreview(stack: stack, mode: mode)
    }
    let worker = Task.detached(priority: .userInitiated) {
      var images: [UInt16Image] = []
      images.reserveCapacity(stack.members.count)
      for url in stack.members {
        try Task.checkCancellation()
        images.append(try Self.makeStackPreviewSource(for: url, tier: tier))
      }
      try Task.checkCancellation()
      return try MultiScanStacker.combine(images: images, mode: mode)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private func combinedFullResolutionStackPreview(
    stack: DetectedScanStack,
    mode: ScanStackMode
  ) async throws -> MultiScanStackResult {
    guard let firstMember = stack.members.first else {
      throw ScanStackError.insufficientImages
    }
    scanStackStatus =
      "Decoding stack capture 1 of \(stack.members.count): \(firstMember.lastPathComponent)"
    var composite = try await decodeStackPreviewMember(firstMember, tier: .full)
    var lastResult: MultiScanStackResult?
    var automaticUsedHDR = false

    for (index, member) in stack.members.enumerated().dropFirst() {
      try Task.checkCancellation()
      scanStackStatus =
        "Decoding stack capture \(index + 1) of \(stack.members.count): \(member.lastPathComponent)"
      let candidate = try await decodeStackPreviewMember(member, tier: .full)
      try Task.checkCancellation()
      scanStackStatus =
        "Aligning full-resolution capture \(index + 1) of \(stack.members.count)..."
      let accumulated = composite
      let worker = Task.detached(priority: .userInitiated) {
        let weightedComposite = Array(repeating: accumulated, count: index)
        return try MultiScanStacker.combine(
          images: weightedComposite + [candidate],
          mode: mode)
      }
      let result = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      composite = result.image
      lastResult = result
      if mode == .automatic {
        automaticUsedHDR = automaticUsedHDR || result.effectiveMode == .hdr
      }
    }

    guard let lastResult else { throw ScanStackError.insufficientImages }
    let effectiveMode: ScanStackMode
    if mode == .automatic {
      effectiveMode = automaticUsedHDR ? .hdr : .noiseReduction
    } else {
      effectiveMode = lastResult.effectiveMode
    }
    return MultiScanStackResult(
      image: composite,
      effectiveMode: effectiveMode,
      alignments: lastResult.alignments,
      exposureOffsetsEV: lastResult.exposureOffsetsEV)
  }

  private func decodeStackPreviewMember(
    _ url: URL,
    tier: ScanStackPreviewTier
  ) async throws -> UInt16Image {
    if tier == .full, FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) {
      let gate = rawFullPreviewDecodeGate
      return try await Task.detached(priority: .userInitiated) {
        try await gate.run {
          try Self.makeStackPreviewSource(for: url, tier: .full)
        }
      }.value
    }
    return try await Task.detached(priority: .userInitiated) {
      try Self.makeStackPreviewSource(for: url, tier: tier)
    }.value
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
    if calibrateFromSource {
      populateFilmNegativeMedians(
        from: result.image.resizedToFit(maxDimension: Self.analysisPreviewMaxDimension))
    }
    let modeLabel = Self.scanStackModeLabel(result.effectiveMode)
    if stackPreviewCoversSource(result.image) {
      scanStackStatus =
        "Aligned \(stack.members.count) captures for \(modeLabel) at full resolution."
    } else {
      scanStackStatus = "Aligned \(stack.members.count) captures for \(modeLabel)."
    }
    scheduleRender(immediate: true)
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
    if isPreviewingSourceGeometry {
      displayParameters.cropRect = nil
      displayParameters.perspectiveCrop = nil
      displayParameters.straightenAngle = 0
      displayParameters.manualCrop = nil
    } else if isPreviewingUncroppedCanvas {
      displayParameters.manualCrop = nil
    }
    return displayParameters
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
      parameters: previewDisplayParameters,
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
      let result: RenderedPreview? = await Task.detached(priority: .userInitiated) {
        () -> RenderedPreview? in
        let useGPU =
          request.renderer != nil
          && !request.parameters.densityPipelineEnabled
          && request.parameters.cropRect == nil
          && request.parameters.perspectiveCrop == nil
          && abs(request.parameters.straightenAngle) < 0.000_001
          && request.parameters.manualCrop == nil
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
        var renderParameters = request.parameters
        if request.showOriginal {
          renderParameters.filmType = .cropOnly
        }
        let rendered = FilmProcessing.correctedPreview(
          image: request.source,
          parameters: renderParameters,
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
        previewDisplayParameters == request.parameters,
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

      previewImage = PreviewBitmap.nsImage(from: preview)
      previewStatistics = result.statistics
      if let interval = pendingFirstPreviewInterval,
        interval.filename == request.selection.lastPathComponent
      {
        AppPerformanceSignposts.end(interval)
        pendingFirstPreviewInterval = nil
      }
      if !status.localizedCaseInsensitiveContains("cancel") {
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

  private func capturePresetRollback(named name: String) {
    guard let selection else { return }
    let key = settingsKey(selection)
    presetRollbacks[key] = CorrectionSettings(capturing: parameters)
    appliedPresetNames[key] = name
    appliedPresetName = name
  }

  private func clearPresetRollback() {
    guard let selection else {
      appliedPresetName = nil
      return
    }
    let key = settingsKey(selection)
    presetRollbacks.removeValue(forKey: key)
    appliedPresetNames.removeValue(forKey: key)
    appliedPresetName = nil
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
    guard let renderer = StillPreviewRenderer(image: display, analysisImage: analysis) else {
      throw CocoaError(.coderInvalidValue)
    }
    return CachedPreviewSession(
      sourceKind: .rawFull,
      displaySource: display,
      analysisSource: analysis,
      previewRenderer: renderer,
      sourcePixelDimensions: fullResolutionDimensions(of: url))
  }

  nonisolated private static func demotedSession(
    from session: CachedPreviewSession,
    kind: PreviewSourceKind
  ) -> CachedPreviewSession {
    let maxDimension =
      switch kind {
      case .rawInspect: rawInspectPreviewMaxDimension
      case .rawDetail: rawDetailPreviewMaxDimension
      case .rawDraft: rawDraftPreviewMaxDimension
      default: rawDetailPreviewMaxDimension
      }
    let display = session.displaySource.resizedToFit(maxDimension: maxDimension)
    let analysis = session.analysisSource.resizedToFit(maxDimension: analysisPreviewMaxDimension)
    guard let renderer = StillPreviewRenderer(image: display, analysisImage: analysis) else {
      return session
    }
    return CachedPreviewSession(
      sourceKind: kind,
      displaySource: display,
      analysisSource: analysis,
      previewRenderer: renderer,
      sourcePixelDimensions: session.sourcePixelDimensions)
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

  nonisolated private static func makeThumbnailSource(for url: URL) throws -> UInt16Image {
    if FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased()) {
      return try RawImageDecoder.extractThumbnail(
        url, maxDimension: thumbnailMaxDimension
      ).image
    }
    return try StandardImageDecoder.decodePreview(
      url, maxDimension: thumbnailMaxDimension)
  }

  nonisolated private static func makeSidebarScanAnalysis(
    for url: URL
  ) throws -> SidebarScanAnalysis {
    let source = try makeThumbnailSource(for: url)
    return SidebarScanAnalysis(
      thumbnailSource: source,
      fingerprint: try ScanFingerprint(image: source),
      fullResolutionDimensions: fullResolutionDimensions(of: url),
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

private struct PreviewRenderRequest: Sendable {
  let selection: URL
  let source: UInt16Image
  let renderer: StillPreviewRenderer?
  let parameters: ProcessingParameters
  let showOriginal: Bool
  let submitTime: Date
  let flatField: UInt16Image?
}

private struct SidebarScanAnalysis: Sendable {
  let thumbnailSource: UInt16Image
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

enum PreviewSourceKind: String, Sendable {
  case embeddedRAW
  case rawDraft
  case standardThumbnail
  case rawDetail
  case rawInspect
  case rawFull
  case alignedStack

  var qualityRank: Int {
    switch self {
    case .embeddedRAW: 0
    case .rawDraft, .standardThumbnail: 1
    case .rawDetail: 2
    case .rawInspect: 3
    case .rawFull: 4
    case .alignedStack: 5
    }
  }
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

private actor RawFullPreviewDecodeGate {
  func run<T: Sendable>(_ operation: @Sendable () throws -> T) rethrows -> T {
    try operation()
  }
}

private struct CachedPreviewSession: Sendable {
  let sourceKind: PreviewSourceKind
  let displaySource: UInt16Image
  let analysisSource: UInt16Image
  let previewRenderer: StillPreviewRenderer
  let sourcePixelDimensions: PixelDimensions?

  var byteCount: Int {
    (displaySource.pixels.count + analysisSource.pixels.count)
      * MemoryLayout<UInt16>.stride
  }
}

private struct RenderedPreview: Sendable {
  let cgImage: CGImage
  let rendererName: String
  let statistics: RenderReadyImageStatistics
}
