import AppKit
import CryptoKit
@preconcurrency import Darwin
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Sustained real RAW preview navigation measurement", .serialized)
@MainActor
struct SustainedPreviewPerformanceTests {
  private static let defaultFrames = [
    "fuji400-fresh/DSCF2833.RAF", "fuji400-fresh/DSCF2851.RAF",
    "fuji400-fresh/DSCF2856.RAF",
  ]

  private static let capacityFrames = [
    "fuji400-fresh/DSCF2833.RAF", "fuji400-fresh/DSCF2851.RAF",
    "fuji400-fresh/DSCF2856.RAF", "fuji400-fresh/DSCF2865.RAF",
    "fuji400-fresh/DSCF2873.RAF", "fuji400-fresh/DSCF2881.RAF",
    "fuji400-fresh/DSCF2888.RAF", "fuji400-fresh/DSCF2892.RAF",
  ]

  @Test(
    "Measure repeated full-source eviction, retained revisits, pressure, and release",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_SUSTAINED_PREVIEW_TESTS"] == "1",
      "set RUN_SUSTAINED_PREVIEW_TESTS=1 with the named Fuji RAW corpus"))
  func sustainedNavigationAndPressure() async throws {
    let environment = ProcessInfo.processInfo.environment
    let configuration = try configuration(environment["SUSTAINED_PREVIEW_COHORT"])
    let frames = configuration.frames
    let loops = min(8, max(2, Int(environment["SUSTAINED_PREVIEW_LOOPS"] ?? "4") ?? 4))
    let deadline = ContinuousClock.now + .seconds(1_200)
    let output = try freshOutput(environment["SUSTAINED_PREVIEW_OUTPUT"])
    let files = frames.map(SampleRawCorpus.url(relativePath:))
    for file in files {
      try #require(FileManager.default.fileExists(atPath: file.path), "Missing \(file.path)")
    }
    let inputHashes = try Dictionary(
      uniqueKeysWithValues: zip(frames, files).map { ($0.0, try fileHash($0.1)) })
    try #require(Set(frames).count == frames.count, "Cohort paths must be distinct")
    if configuration.requiresByteCapacity {
      try #require(frames.count == 8 && Set(inputHashes.values).count == 8)
    }
    let provenance = try provenance()
    let beforeModel = try memorySample()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-sustained-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "fsc-sustained-preview-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    var initialSettings: [String: ProcessingParameters] = [:]
    for (index, file) in files.enumerated() {
      var parameters: ProcessingParameters
      if configuration.requiresByteCapacity {
        parameters = FilmBase.colorC41.applyingInvert(
          to: ProcessingParameters(photoAdjustments: .init(schemaVersion: 4)))
        parameters.perspectiveCrop = .init(
          topLeft: .init(x: 0.08, y: 0.10), topRight: .init(x: 0.93, y: 0.08),
          bottomRight: .init(x: 0.91, y: 0.92), bottomLeft: .init(x: 0.10, y: 0.90))
        parameters.straightenAngle = 2
      } else {
        parameters = LookRecipe.cleanInvert.applying(
          to: FilmBase.colorC41.applyingInvert(to: .init()))
        parameters.photoAdjustments.exposureEV = Double(index) * 0.125
      }
      parameters.filmBaseChosenByUser = true
      if configuration.requiresByteCapacity {
        try #require(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
      }
      initialSettings[file.standardizedFileURL.path] = parameters
    }
    try store.save(.init(settingsByPath: initialSettings, editedPaths: Set(initialSettings.keys)))
    var model: AppModel? = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store, preferences: preferences)
    weak var releasedModel = model
    model?.setPreviewCacheLimit(configuration.cacheDepth)
    if configuration.requiresByteCapacity {
      try #require(
        model?.previewMemoryByteLimit == 3_072 * 1_024 * 1_024,
        "fuji-eight-cpu requires the normal 3 GiB machine preview budget")
    }
    let measurement: Measurement
    do {
      measurement = try await measure(
        model: try #require(model), files: files, initialSettings: initialSettings,
        configuration: configuration, loops: loops, deadline: deadline)
      model = nil
      try await waitUntil("model release", deadline: deadline) { releasedModel == nil }
    } catch {
      model?.closeAllScans()
      model = nil
      // Native work already in progress may have to drain before releasing its
      // owner. Preserve the original failure after allowing that bounded drain.
      try? await waitUntil("failed measurement model release", deadline: deadline) {
        releasedModel == nil
      }
      throw error
    }
    let afterRelease = try memorySample()
    for (frame, file) in zip(frames, files) {
      try #require(try fileHash(file) == inputHashes[frame], "Source bytes changed: \(frame)")
    }
    let configuredParameters = try Dictionary(
      uniqueKeysWithValues: zip(frames, files).map { frame, file in
        (frame, try #require(initialSettings[file.standardizedFileURL.path]))
      })
    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()), provenance: provenance,
      cohort: configuration.name, framePaths: frames, loops: loops,
      configuredFrameCount: frames.count,
      configuredCacheDepth: configuration.cacheDepth, geometry: configuration.geometry,
      configuredParametersByFrame: configuredParameters,
      inputSHA256: inputHashes,
      memoryBeforeModel: beforeModel, measurement: measurement,
      memoryAfterVerifiedModelRelease: afterRelease, limits: limits(configuration))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(
      !FileManager.default.fileExists(atPath: output.path), "Output path is no longer fresh")
    try encoder.encode(report).write(to: output, options: .atomic)
    print(
      "SUSTAINED_PREVIEW: \(loops) loops, \(measurement.navigation.count) measured switches; JSON \(output.path). AppModel publication and process footprint only; no native input, screen, or general improvement claim."
    )
  }

  private func measure(
    model: AppModel, files: [URL], initialSettings: [String: ProcessingParameters],
    configuration: Configuration, loops: Int, deadline: ContinuousClock.Instant
  ) async throws -> Measurement {
    let frames = configuration.frames
    var hashes: [String: String] = [:]
    var parametersByFrame: [String: ProcessingParameters] = [:]
    var sourceDimensionsByFrame: [String: PixelDimensions] = [:]
    var states: [State] = []
    var warmup: [SwitchSample] = []
    let beforeImport = counters(model)
    let importStart = ContinuousClock.now
    model.importFiles(files)
    try await settled(model, file: files[0], deadline: deadline)
    let importMilliseconds = milliseconds(since: importStart)
    try validateFullPreview(model, file: files[0], initialSettings: initialSettings)
    hashes[frames[0]] = try previewHash(model)
    parametersByFrame[frames[0]] = model.parameters
    sourceDimensionsByFrame[frames[0]] = try #require(model.sourcePixelDimensions)
    states.append(try state(model, label: "first full-source import", files: files, frames: frames))
    let importWork = counters(model).subtracting(beforeImport)
    for index in 1..<files.count {
      let sample = try await select(
        model, file: files[index], frame: frames[index], phase: "warmup", iteration: 0,
        files: files, frames: frames, initialSettings: initialSettings,
        expectedHash: nil, deadline: deadline)
      hashes[frames[index]] = try previewHash(model)
      parametersByFrame[frames[index]] = model.parameters
      sourceDimensionsByFrame[frames[index]] = try #require(model.sourcePixelDimensions)
      warmup.append(sample)
    }
    states.append(
      try state(model, label: "\(files.count)-frame warmup settled", files: files, frames: frames))
    let beforeNavigation = counters(model)
    var navigation: [SwitchSample] = []
    for iteration in 0..<loops {
      for (index, file) in files.enumerated() {
        navigation.append(
          try await select(
            model, file: file, frame: frames[index], phase: "navigation",
            iteration: iteration, files: files, frames: frames, initialSettings: initialSettings,
            expectedHash: hashes[frames[index]], deadline: deadline))
      }
    }
    let navigationWork = counters(model).subtracting(beforeNavigation)
    states.append(try state(model, label: "navigation settled", files: files, frames: frames))
    var byteCapacityEvidence: ByteCapacityEvidence?
    if configuration.requiresByteCapacity {
      let pressureGuardStates = states + warmup.map(\.settled) + navigation.map(\.settled)
      for sample in pressureGuardStates {
        try #require(
          sample.memoryPressureHandlingCount == 0,
          "Byte-capacity collection requires no memory-pressure drop-handler calls before deliberate simulation"
        )
      }
      let capacityStates = [states[1]] + navigation.map(\.settled)
      for sample in capacityStates {
        try #require(sample.sessions <= configuration.cacheDepth)
        try #require(sample.chargedPreviewBytes <= sample.previewBudgetBytes)
        try #require(sample.sourceKind == PreviewSourceKind.rawFull.rawValue)
        let selected = try #require(sample.selection)
        let selectedFrame = try #require(
          frames.first { URL(fileURLWithPath: $0).lastPathComponent == selected })
        try #require(sample.cachedSourceKinds[selectedFrame] == PreviewSourceKind.rawFull.rawValue)
      }
      let evictedBelowDepth = capacityStates.filter { sample in
        sample.sessions < configuration.cacheDepth && sample.fullSourceSessions < frames.count
      }
      try #require(
        !evictedBelowDepth.isEmpty,
        "Previously warmed full sessions must evict while total session count is below depth 8")
      let firstEvidence = try #require(evictedBelowDepth.first)
      let missingFull = frames.filter {
        firstEvidence.cachedSourceKinds[$0] != PreviewSourceKind.rawFull.rawValue
      }
      try #require(!missingFull.isEmpty)
      byteCapacityEvidence = ByteCapacityEvidence(
        firstObservedState: firstEvidence.label,
        previouslyWarmedFramesWithoutFullSession: missingFull,
        sessionsAtFirstEvidence: firstEvidence.sessions,
        fullSourceSessionsAtFirstEvidence: firstEvidence.fullSourceSessions,
        chargedPreviewBytesAtFirstEvidence: firstEvidence.chargedPreviewBytes,
        previewBudgetBytes: firstEvidence.previewBudgetBytes,
        memoryPressureHandlingCountAtFirstEvidence: firstEvidence.memoryPressureHandlingCount)
    }

    // Returning to an evicted frame may immediately restore a corrected canvas.
    // A new edit must replace any such older pixels before its full-source result.
    model.selection = files[0]
    model.loadSelection()
    let editStartedWithRetainedCanvas = model.isShowingRetainedCanvas
    let oldExposure = try #require(initialSettings[files[0].standardizedFileURL.path])
      .photoAdjustments.exposureEV
    let editedExposure = oldExposure + 0.25
    let editRevision = model.publishedRenderRevision
    model.setExposureEV(editedExposure)
    try await waitUntil("new edit replaces retained pixels", deadline: deadline) {
      model.publishedRenderRevision > editRevision && !model.isShowingRetainedCanvas
        && model.publishedPreviewParameters?.photoAdjustments.exposureEV == editedExposure
        && !model.isRendering
    }
    try await settled(model, file: files[0], deadline: deadline)
    try #require(model.parameters.photoAdjustments.exposureEV == editedExposure)
    try #require(model.publishedPreviewParameters == model.parameters)
    let editedHash = try previewHash(model)
    try #require(editedHash != hashes[frames[0]], "Exposure must change the corrected pixels")
    hashes[frames[0]] = editedHash
    parametersByFrame[frames[0]] = model.parameters
    states.append(
      try state(model, label: "retained revisit after edit", files: files, frames: frames))
    model.showOriginal = true
    try await settled(model, file: files[0], deadline: deadline)
    try #require(!model.isShowingRetainedCanvas)
    let originalHash = try previewHash(model)
    try #require(originalHash != editedHash, "Original must display different pixels")
    states.append(try state(model, label: "Original comparison", files: files, frames: frames))
    model.selection = files[1]
    model.loadSelection()
    try await settled(model, file: files[1], deadline: deadline)
    try #require(!model.showOriginal)
    model.selection = files[2]
    model.loadSelection()
    try await settled(model, file: files[2], deadline: deadline)
    model.selection = files[0]
    model.loadSelection()
    try await settled(model, file: files[0], deadline: deadline)
    try #require(
      try previewHash(model) == editedHash, "Original departure must preserve corrected pixels")
    try #require(model.parameters.photoAdjustments.exposureEV == editedExposure)

    // This invokes the app's pressure handler; it is not system-wide memory
    // pressure and does not establish OS pressure notification or thermal cost.
    let pressureHash = try previewHash(model)
    let pressureDimensions = try #require(model.previewImage?.size)
    states.append(
      try state(model, label: "before simulated app pressure", files: files, frames: frames))
    let handlingCountBeforeSimulation = model.previewMemoryPressureHandlingCount
    if configuration.requiresByteCapacity {
      try #require(
        handlingCountBeforeSimulation == 0,
        "No memory-pressure drop-handler call may precede byte-capacity simulation")
    }
    model.handlePreviewMemoryPressure(isUnderPressure: true)
    try #require(model.previewMemoryPressureHandlingCount == handlingCountBeforeSimulation + 1)
    try await waitUntil("pressure drain", deadline: deadline) {
      !model.previewBackgroundWorkIsActive && !model.canvasSnapshotWorkIsActive
        && !model.isRendering
    }
    try #require(model.previewCacheSessionCount == 1)
    try #require(model.retainedCanvasPreviewCount == 0)
    try #require(model.previewImage?.size == pressureDimensions)
    try #require(try previewHash(model) == pressureHash)
    states.append(
      try state(model, label: "simulated app pressure settled", files: files, frames: frames))
    let handlingCountBeforeRelease = model.previewMemoryPressureHandlingCount
    model.handlePreviewMemoryPressure(isUnderPressure: false)
    try #require(model.previewMemoryPressureHandlingCount == handlingCountBeforeRelease)
    try await settled(model, file: files[0], deadline: deadline)
    states.append(
      try state(
        model, label: "pressure released and background settled", files: files, frames: frames))
    var recovery: [SwitchSample] = []
    var currentSettings = initialSettings
    currentSettings[files[0].standardizedFileURL.path] = parametersByFrame[frames[0]]
    for index in [1, 2, 0] {
      recovery.append(
        try await select(
          model, file: files[index], frame: frames[index], phase: "pressure recovery",
          iteration: 0, files: files, frames: frames, initialSettings: currentSettings,
          expectedHash: hashes[frames[index]], deadline: deadline))
    }
    try await model.flushSettings()
    let finalCounters = counters(model)
    model.closeAllScans()
    try await waitUntil("Close All drain", deadline: deadline) {
      !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive && !model.isAnalyzingScanStacks
    }
    try #require(model.previewImage == nil)
    try #require(model.previewCacheSessionCount == 0)
    try #require(model.retainedCanvasPreviewCount == 0)
    try #require(model.previewCachePhysicalBytes == 0)
    states.append(try state(model, label: "Close All settled", files: files, frames: frames))
    return Measurement(
      importToFullSettledMilliseconds: importMilliseconds,
      importWork: importWork, warmup: warmup,
      navigation: navigation, navigationWork: navigationWork,
      editStartedWithRetainedCanvas: editStartedWithRetainedCanvas,
      recovery: recovery, states: states, finalCounters: finalCounters,
      correctedPreviewSHA256: hashes, fullSourceParametersByFrame: parametersByFrame,
      fullSourceDimensionsByFrame: sourceDimensionsByFrame,
      byteCapacityEvidence: byteCapacityEvidence)
  }

  private func select(
    _ model: AppModel, file: URL, frame: String, phase: String, iteration: Int,
    files: [URL], frames: [String], initialSettings: [String: ProcessingParameters],
    expectedHash: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> SwitchSample {
    let workBefore = counters(model)
    let kindBefore = model.cachedPreviewKind(for: file)?.rawValue
    let revision = model.publishedRenderRevision
    let start = ContinuousClock.now
    model.selection = file
    model.loadSelection()
    let immediateRetainedCanvas = model.isShowingRetainedCanvas
    if immediateRetainedCanvas {
      try #require(model.publishedPreviewParameters == model.parameters)
      try #require(
        model.previewImage?.size
          == model.sourcePixelDimensions.map {
            let dimensions = ImageGeometry.outputDimensions(
              source: $0, parameters: model.parameters)
            return CGSize(width: dimensions.width, height: dimensions.height)
          })
    }
    if !immediateRetainedCanvas {
      try await waitUntil("current publication for \(frame)", deadline: deadline) {
        model.selection == file && model.previewImage != nil
          && model.publishedRenderRevision > revision && !model.isLoading && !model.isRendering
      }
    }
    let firstPublicationMilliseconds = milliseconds(since: start)
    let firstPublicationKind = model.previewSourceKind?.rawValue
    let firstPublicationRetainedCanvas = model.isShowingRetainedCanvas
    let firstPublicationLogicalDimensions = logicalPreviewDimensions(model)
    let firstPublicationBitmapDimensions = bitmapDimensions(model)
    try await settled(model, file: file, deadline: deadline)
    let fullSettledMilliseconds = milliseconds(since: start)
    try validateFullPreview(model, file: file, initialSettings: initialSettings)
    if let expectedHash {
      try #require(
        try previewHash(model) == expectedHash, "Corrected pixels changed on revisit: \(frame)")
    }
    return SwitchSample(
      phase: phase, iteration: iteration, frame: frame, cachedSourceKindBeforeSelection: kindBefore,
      immediateRetainedCanvas: immediateRetainedCanvas,
      firstPublicationSourceKind: firstPublicationKind,
      firstPublicationUsedRetainedCanvas: firstPublicationRetainedCanvas,
      firstPublicationLogicalDimensions: firstPublicationLogicalDimensions,
      firstPublicationBitmapDimensions: firstPublicationBitmapDimensions,
      firstPublicationMilliseconds: firstPublicationMilliseconds,
      fullSettledMilliseconds: fullSettledMilliseconds,
      work: counters(model).subtracting(workBefore),
      settled: try state(
        model, label: "\(phase) \(iteration) \(frame)", files: files, frames: frames))
  }

  private func validateFullPreview(
    _ model: AppModel, file: URL, initialSettings: [String: ProcessingParameters]
  ) throws {
    let expected = try #require(initialSettings[file.standardizedFileURL.path])
    try #require(model.parameters.photoAdjustments == expected.photoAdjustments)
    try #require(
      model.parameters.filmNegativeParams.densityProfileID
        == expected.filmNegativeParams.densityProfileID)
    try #require(FilmBase.resolved(from: model.parameters) == .colorC41)
    try #require(model.parameters.borderCrop == expected.borderCrop)
    try #require(model.parameters.flip == expected.flip)
    try #require(model.parameters.rotation == expected.rotation)
    try #require(model.parameters.cropRect == expected.cropRect)
    try #require(model.parameters.cropRectCoordinateSpace == expected.cropRectCoordinateSpace)
    try #require(model.parameters.perspectiveCrop == expected.perspectiveCrop)
    try #require(model.parameters.straightenAngle == expected.straightenAngle)
    try #require(model.parameters.manualCrop == expected.manualCrop)
    try #require(model.publishedPreviewParameters == model.parameters)
    try #require(!model.isShowingRetainedCanvas && !model.showOriginal)
    let source = try #require(model.sourcePixelDimensions)
    try #require(
      model.cachedPreviewKind(for: file) == .rawFull,
      "Settled selected full RAW session must remain cached: \(file.lastPathComponent), source \(source.width)×\(source.height)"
    )
    let dimensions = ImageGeometry.outputDimensions(source: source, parameters: model.parameters)
    try #require(
      model.previewImage?.size == CGSize(width: dimensions.width, height: dimensions.height))
  }

  private func settled(
    _ model: AppModel, file: URL, deadline: ContinuousClock.Instant
  ) async throws {
    try await waitUntil("settled full preview for \(file.lastPathComponent)", deadline: deadline) {
      model.selection == file && model.previewSourceKind == .rawFull && model.previewImage != nil
        && !model.isLoading && !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive && !model.isAnalyzingScanStacks
        && model.previewStatisticsRevision == model.publishedRenderRevision
    }
  }

  private func waitUntil(
    _ label: String, deadline overallDeadline: ContinuousClock.Instant,
    condition: @MainActor () -> Bool
  ) async throws {
    let deadline = min(overallDeadline, ContinuousClock.now + .seconds(180))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out: \(label)")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func counters(_ model: AppModel) -> Counters {
    Counters(
      publishedFullSourceDecodes: model.fullResolutionPreviewDecodeCount,
      corrections: model.previewCorrectionCount, renderedCacheHits: model.previewRenderCacheHits,
      lookaheadSubmissions: model.lookaheadPreviewRequestCount,
      statisticsComputations: model.previewStatisticsComputationCount,
      submittedSnapshots: model.renderStats.submittedSnapshots,
      displayedRenders: model.renderStats.displayedRenders,
      droppedSnapshots: model.renderStats.droppedSnapshots)
  }

  private func state(_ model: AppModel, label: String, files: [URL], frames: [String]) throws
    -> State
  {
    let cachedKinds = Dictionary(
      uniqueKeysWithValues: zip(frames, files).compactMap { frame, file in
        model.cachedPreviewKind(for: file).map { (frame, $0.rawValue) }
      })
    return State(
      label: label, selection: model.selection?.lastPathComponent,
      sourceKind: model.previewSourceKind?.rawValue,
      retainedCanvasVisible: model.isShowingRetainedCanvas,
      sourceDimensions: model.sourcePixelDimensions,
      logicalPreviewDimensions: logicalPreviewDimensions(model),
      bitmapDimensions: bitmapDimensions(model),
      sessions: model.previewCacheSessionCount, retainedCanvases: model.retainedCanvasPreviewCount,
      fullSourceSessions: cachedKinds.values.filter { $0 == PreviewSourceKind.rawFull.rawValue }
        .count,
      chargedPreviewBytes: model.previewCachePhysicalBytes,
      previewBudgetBytes: model.previewMemoryByteLimit,
      memoryPressureHandlingCount: model.previewMemoryPressureHandlingCount,
      cachedSourceKinds: cachedKinds, counters: counters(model), memory: try memorySample())
  }

  private func configuration(_ name: String?) throws -> Configuration {
    try #require(
      name == nil || name == "" || name == "fuji-three" || name == "fuji-eight-cpu",
      "Unknown SUSTAINED_PREVIEW_COHORT: \(name ?? "")")
    if name == "fuji-eight-cpu" {
      return Configuration(
        name: "fuji-eight-cpu", frames: Self.capacityFrames, cacheDepth: 8,
        geometry: "C-41 schema 4, fixed perspective corners, 2 degree straighten, EV 0",
        requiresByteCapacity: true)
    }
    return Configuration(
      name: "fuji-three", frames: Self.defaultFrames, cacheDepth: 2,
      geometry: "Clean Invert C-41 without added geometry", requiresByteCapacity: false)
  }

  private func limits(_ configuration: Configuration) -> [String] {
    let capacityLimit =
      configuration.requiresByteCapacity
      ? "Exactly eight unique sources use the default depth eight and normal 3 GiB budget. With zero pressure drop-handler calls asserted before deliberate simulation, loss of previously warmed full sessions below depth eight demonstrates byte/reservation eviction; charged bytes need not reach the admission reservation limit."
      : "The two-session count limit drives this three-source cohort's eviction; the normal machine byte budget is not deliberately saturated."
    return [
      "Programmatic AppModel publication, not native-input or screen-presentation latency.",
      "Immediate retained-canvas publication and settled full-source output are timed separately; no full-detail first-display claim is made.",
      "Each named frame receives a settled full-source warmup; filesystem caches are uncontrolled.",
      capacityLimit,
      "Selected full-source cache presence and charged bytes within budget are asserted. Aggregate admission reservation bytes are not directly exposed or measured.",
      "Charged preview bytes are accounting, distinct from process physical footprint.",
      "Peak footprint covers the process lifetime and is not a per-switch peak.",
      "Pressure is simulated by the app handler, not induced system-wide memory pressure.",
      "The pressure handling count observes every true drop-handler call, including OS notifications and deliberate simulation; false calls do not increment it. The default three-source mode reports this count without requiring zero.",
      "Full-source decode count covers completed results accepted after cancellation/generation guards, before speculative admission; it is not a count of all native decodes or admitted sessions.",
      "Lookahead count is scheduler submissions, including work cancelled before native decoding. Admission skips, rejected speculative results, native completions, and native cancellations are not separately counted.",
      "This current-source cohort and descriptive samples do not establish general performance or memory gains or before/after capacity improvement.",
      "Bitmap hashes and source hashes check reuse correctness, not photographic quality or independent CPU/Metal parity.",
      "Close All and weak-model release establish ownership release, not return of all physical memory to the OS.",
      "Source/toolchain binary-manifest evidence should accompany this report for comparisons.",
    ]
  }

  private func previewHash(_ model: AppModel) throws -> String {
    let image = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let data = try #require(image.dataProvider?.data as Data?)
    return SHA256.hash(data: data).description
  }

  private func logicalPreviewDimensions(_ model: AppModel) -> PixelDimensions? {
    model.previewImage.map {
      PixelDimensions(width: Int($0.size.width), height: Int($0.size.height))
    }
  }

  private func bitmapDimensions(_ model: AppModel) -> PixelDimensions? {
    model.previewImage.flatMap(PreviewBitmap.cgImage).map {
      PixelDimensions(width: $0.width, height: $0.height)
    }
  }

  private func fileHash(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).description
  }

  private func freshOutput(_ path: String?) throws -> URL {
    let url =
      path.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "fsc-sustained-preview-\(UUID().uuidString).json")
    try #require(
      !FileManager.default.fileExists(atPath: url.path), "SUSTAINED_PREVIEW_OUTPUT must be fresh")
    return url
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds)
      / 1e15
  }

  private func memorySample() throws -> MemorySample {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    try #require(result == KERN_SUCCESS, "Mach physical-footprint sample failed: \(result)")
    return MemorySample(
      physicalFootprintBytes: UInt64(info.phys_footprint),
      processLifetimePeakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak)),
      reusableBytes: UInt64(info.reusable))
  }

  private func provenance() throws -> Provenance {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let harness = URL(fileURLWithPath: #filePath)
    let appModel = root.appendingPathComponent(
      "native/FilmScanEngine/Sources/FilmScanConverterMac/AppModel.swift")
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    let hardware = String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return Provenance(
      sourceRevision: try gitOutput(["rev-parse", "HEAD"], root: root),
      dirtyStatus: try gitOutput(["status", "--porcelain"], root: root),
      harnessSHA256: try fileHash(harness), appModelSHA256: try fileHash(appModel),
      hardware: hardware, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      processorCount: ProcessInfo.processInfo.processorCount,
      thermalStateAtStart: ProcessInfo.processInfo.thermalState.rawValue)
  }

  private func gitOutput(_ arguments: [String], root: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "Source provenance command failed")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct Counters: Codable {
    let publishedFullSourceDecodes: Int
    let corrections: Int
    let renderedCacheHits: Int
    let lookaheadSubmissions: Int
    let statisticsComputations: Int
    let submittedSnapshots: Int
    let displayedRenders: Int
    let droppedSnapshots: Int

    func subtracting(_ other: Counters) -> Counters {
      Counters(
        publishedFullSourceDecodes: publishedFullSourceDecodes - other.publishedFullSourceDecodes,
        corrections: corrections - other.corrections,
        renderedCacheHits: renderedCacheHits - other.renderedCacheHits,
        lookaheadSubmissions: lookaheadSubmissions - other.lookaheadSubmissions,
        statisticsComputations: statisticsComputations - other.statisticsComputations,
        submittedSnapshots: submittedSnapshots - other.submittedSnapshots,
        displayedRenders: displayedRenders - other.displayedRenders,
        droppedSnapshots: droppedSnapshots - other.droppedSnapshots)
    }
  }

  private struct Configuration {
    let name: String
    let frames: [String]
    let cacheDepth: Int
    let geometry: String
    let requiresByteCapacity: Bool
  }

  private struct ByteCapacityEvidence: Codable {
    let firstObservedState: String
    let previouslyWarmedFramesWithoutFullSession: [String]
    let sessionsAtFirstEvidence: Int
    let fullSourceSessionsAtFirstEvidence: Int
    let chargedPreviewBytesAtFirstEvidence: Int
    let previewBudgetBytes: Int
    let memoryPressureHandlingCountAtFirstEvidence: Int
  }

  private struct MemorySample: Codable {
    let physicalFootprintBytes: UInt64
    let processLifetimePeakPhysicalFootprintBytes: UInt64
    let reusableBytes: UInt64
  }

  private struct State: Codable {
    let label: String
    let selection: String?
    let sourceKind: String?
    let retainedCanvasVisible: Bool
    let sourceDimensions: PixelDimensions?
    let logicalPreviewDimensions: PixelDimensions?
    let bitmapDimensions: PixelDimensions?
    let sessions: Int
    let retainedCanvases: Int
    let fullSourceSessions: Int
    let chargedPreviewBytes: Int
    let previewBudgetBytes: Int
    let memoryPressureHandlingCount: Int
    let cachedSourceKinds: [String: String]
    let counters: Counters
    let memory: MemorySample
  }

  private struct SwitchSample: Codable {
    let phase: String
    let iteration: Int
    let frame: String
    let cachedSourceKindBeforeSelection: String?
    let immediateRetainedCanvas: Bool
    let firstPublicationSourceKind: String?
    let firstPublicationUsedRetainedCanvas: Bool
    let firstPublicationLogicalDimensions: PixelDimensions?
    let firstPublicationBitmapDimensions: PixelDimensions?
    let firstPublicationMilliseconds: Double
    let fullSettledMilliseconds: Double
    let work: Counters
    let settled: State
  }

  private struct Measurement: Codable {
    let importToFullSettledMilliseconds: Double
    let importWork: Counters
    let warmup: [SwitchSample]
    let navigation: [SwitchSample]
    let navigationWork: Counters
    let editStartedWithRetainedCanvas: Bool
    let recovery: [SwitchSample]
    let states: [State]
    let finalCounters: Counters
    let correctedPreviewSHA256: [String: String]
    let fullSourceParametersByFrame: [String: ProcessingParameters]
    let fullSourceDimensionsByFrame: [String: PixelDimensions]
    let byteCapacityEvidence: ByteCapacityEvidence?
  }

  private struct Provenance: Codable {
    let sourceRevision: String
    let dirtyStatus: String
    let harnessSHA256: String
    let appModelSHA256: String
    let hardware: String
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let processorCount: Int
    let thermalStateAtStart: Int
  }

  private struct Report: Encodable {
    let schemaVersion = 2
    let status = "current-source baseline collection"
    let generatedAt: String
    let provenance: Provenance
    let cohort: String
    let framePaths: [String]
    let loops: Int
    let configuredFrameCount: Int
    let configuredCacheDepth: Int
    let geometry: String
    let configuredParametersByFrame: [String: ProcessingParameters]
    let inputSHA256: [String: String]
    let memoryBeforeModel: MemorySample
    let measurement: Measurement
    let memoryAfterVerifiedModelRelease: MemorySample
    let limits: [String]
  }
}
