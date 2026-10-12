import AppKit
import CryptoKit
@preconcurrency import Darwin
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Cached RAW revisit first detailed CPU gesture measurement", .serialized)
@MainActor
struct DetailedCachedRevisitPerformanceTests {
  private static let frames = [
    "fuji400-fresh/DSCF2833.RAF", "fuji400-fresh/DSCF2851.RAF",
  ]

  @Test(
    "Measure matched first detailed exposure publications and full release refinement",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_DETAILED_CACHED_REVISIT_TESTS"] == "1",
      "set RUN_DETAILED_CACHED_REVISIT_TESTS=1 with Fuji DSCF2833 and DSCF2851"))
  func matchedFirstDetailedGestures() async throws {
    let environment = ProcessInfo.processInfo.environment
    let deadline = ContinuousClock.now + .seconds(900)
    let inputRoot =
      environment["DETAILED_CACHED_REVISIT_SAMPLE_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? SampleRawCorpus.root
    let files = Self.frames.map { inputRoot.appendingPathComponent($0) }
    for file in files {
      try #require(FileManager.default.fileExists(atPath: file.path), "Missing \(file.path)")
    }
    let inputHashes = try Dictionary(
      uniqueKeysWithValues: zip(Self.frames, files).map { ($0.0, try fileHash($0.1)) })
    try #require(Set(inputHashes.values).count == 2, "The two RAW inputs must be distinct")
    let output = try freshOutput(environment["DETAILED_CACHED_REVISIT_OUTPUT"])
    let provenance = try provenance()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-detailed-revisit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "fsc-detailed-revisit-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    var parameters = FilmBase.colorC41.applyingInvert(
      to: ProcessingParameters(photoAdjustments: .init(schemaVersion: 4)))
    parameters.filmBaseChosenByUser = true
    parameters.perspectiveCrop = .init(
      topLeft: .init(x: 0.08, y: 0.10), topRight: .init(x: 0.93, y: 0.08),
      bottomRight: .init(x: 0.91, y: 0.92), bottomLeft: .init(x: 0.10, y: 0.90))
    parameters.straightenAngle = 2
    try #require(!StillPreviewRenderer.supports(parameters: parameters, showOriginal: false))
    try store.save(
      .init(
        settingsByPath: Dictionary(
          uniqueKeysWithValues: files.map { ($0.standardizedFileURL.path, parameters) }),
        editedPaths: Set(files.map { $0.standardizedFileURL.path })))
    let memoryBeforeModel = try memorySample()
    var model: AppModel? = AppModel(
      profileStore: ProfileStore(baseDirectory: directory.appendingPathComponent("profiles")),
      settingsStore: store, preferences: preferences)
    weak var releasedModel = model
    model?.setPreviewCacheLimit(2)
    let measurement: Measurement
    do {
      measurement = try await measure(model: try #require(model), files: files, deadline: deadline)
      model = nil
      try await waitUntil("verified model release", deadline: deadline) { releasedModel == nil }
    } catch {
      model?.closeAllScans()
      model = nil
      try? await waitUntil("failed measurement model release", deadline: deadline) {
        releasedModel == nil
      }
      throw error
    }
    let memoryAfterRelease = try memorySample()
    for (frame, file) in zip(Self.frames, files) {
      try #require(try fileHash(file) == inputHashes[frame], "RAW source changed: \(frame)")
    }
    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()), provenance: provenance,
      framePaths: Self.frames, configuredParameters: parameters, inputSHA256: inputHashes,
      memoryBeforeModel: memoryBeforeModel, measurement: measurement,
      memoryAfterVerifiedModelRelease: memoryAfterRelease)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(!FileManager.default.fileExists(atPath: output.path), "Output is no longer fresh")
    try encoder.encode(report).write(to: output, options: .atomic)
    print(
      "DETAILED_CACHED_REVISIT: 3 matched pairs; JSON \(output.path). AppModel detail publication and full release refinement only; no screen-presentation or general improvement claim."
    )
  }

  private func measure(
    model: AppModel, files: [URL], deadline: ContinuousClock.Instant
  ) async throws -> Measurement {
    let trace = PreviewInteractionTrace(maximumEvents: 2_048)
    model.previewInteractionTrace = trace
    model.importFiles(files)
    try await settledFull(model, file: files[0], files: files, deadline: deadline)
    model.selection = files[1]
    model.loadSelection()
    try await settledFull(model, file: files[1], files: files, deadline: deadline)
    let secondaryParameters = model.parameters
    let secondaryFullHash = try imageHash(
      try #require(model.previewImage.flatMap(PreviewBitmap.cgImage)))
    model.selection = files[0]
    model.loadSelection()
    try await settledFull(model, file: files[0], files: files, deadline: deadline)
    let source = try #require(model.decodedImage)
    let sourceDimensions = PixelDimensions(width: source.width, height: source.height)
    let initialParameters = model.parameters
    try #require(initialParameters.photoAdjustments.schemaVersion == 4)
    try #require(initialParameters.photoAdjustments.exposureEV == 0)
    let fullDimensions = ImageGeometry.outputDimensions(
      source: sourceDimensions, parameters: initialParameters)
    let demand = PreviewRenderDemand(
      documentSize: CGSize(width: fullDimensions.width, height: fullDimensions.height),
      visibleRect: CGRect(x: 512, y: 384, width: 1_200, height: 800),
      backingScale: 2, magnification: 1)
    let detailRect = try #require(demand.detailRect)
    try #require(demand.overviewMaximumDimension == 1_024)
    try #require(detailRect == CGRect(x: 448, y: 320, width: 1_344, height: 960))
    try #require(detailRect.maxX <= Double(fullDimensions.width))
    try #require(detailRect.maxY <= Double(fullDimensions.height))
    model.setPreviewRenderDemand(demand)
    let initialFullHash = try imageHash(
      try #require(model.previewImage.flatMap(PreviewBitmap.cgImage)))
    let sourcePixelHash = pixelHash(source)
    let fullDecodeCount = model.fullResolutionPreviewDecodeCount
    var samples: [GestureSample] = []
    for pair in 0..<3 {
      let order = pair.isMultiple(of: 2) ? ["warm", "revisit"] : ["revisit", "warm"]
      for arm in order {
        try await prepareArm(
          model, files: files, initialParameters: initialParameters, expectedHash: initialFullHash,
          demand: demand, deadline: deadline)
        let revisit =
          arm == "revisit"
          ? try await cachedRevisit(
            model, files: files, expectedHash: initialFullHash,
            secondaryParameters: secondaryParameters, secondaryHash: secondaryFullHash,
            deadline: deadline)
          : nil
        samples.append(
          try await gesture(
            model, arm: arm, pair: pair + 1, files: files, demand: demand, trace: trace,
            revisit: revisit, deadline: deadline))
      }
    }
    try #require(model.fullResolutionPreviewDecodeCount == fullDecodeCount)
    try #require(trace.discardedEventCount == 0)
    try #require(pixelHash(try #require(model.decodedImage)) == sourcePixelHash)
    let beforeOracle = try state(model, label: "all timed arms settled before CPU oracles")
    let region = ImageRegion(
      x: Int(detailRect.minX), y: Int(detailRect.minY),
      width: Int(detailRect.width), height: Int(detailRect.height))
    var oracles: [Oracle] = []
    for sample in samples {
      let oracle = try cpuOracle(
        source: source, parameters: sample.parameters, region: region,
        overviewMaximumDimension: demand.overviewMaximumDimension)
      try #require(sample.overviewSHA256 == oracle.overviewSHA256)
      try #require(sample.detailSHA256 == oracle.detailSHA256)
      try #require(sample.fullSHA256 == oracle.fullSHA256)
      try #require(sample.fullDimensions == oracle.fullDimensions)
      try #require(sample.overviewDimensions == oracle.overviewDimensions)
      try #require(sample.detailDimensions == oracle.detailDimensions)
      oracles.append(oracle)
    }
    try #require(samples.allSatisfy { $0.parameters == samples[0].parameters })
    try await model.flushSettings()
    model.closeAllScans()
    try await waitUntil("Close All worker drain", deadline: deadline) {
      !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive && !model.isAnalyzingScanStacks
    }
    try #require(model.previewImage == nil && model.previewDetail == nil)
    try #require(model.previewCacheSessionCount == 0 && model.retainedCanvasPreviewCount == 0)
    try #require(model.previewCachePhysicalBytes == 0)
    let afterCloseAll = try state(model, label: "Close All with test source guard still alive")
    model.previewInteractionTrace = nil
    return Measurement(
      sourceDimensions: sourceDimensions, sourcePixelSHA256: sourcePixelHash,
      initialFullSHA256: initialFullHash, initialParameters: initialParameters,
      secondaryFullSHA256: secondaryFullHash, secondaryParameters: secondaryParameters,
      overviewMaximumDimension: demand.overviewMaximumDimension,
      detailRegion: Rect(
        x: detailRect.minX, y: detailRect.minY, width: detailRect.width, height: detailRect.height),
      samples: samples, oracles: oracles, beforeOracle: beforeOracle,
      afterCloseAll: afterCloseAll)
  }

  private func prepareArm(
    _ model: AppModel, files: [URL], initialParameters: ProcessingParameters,
    expectedHash: String, demand: PreviewRenderDemand, deadline: ContinuousClock.Instant
  ) async throws {
    try #require(model.selection == files[0])
    // Untimed bounded edits warm geometry, analysis and the exact requested
    // overview before either arm. The full EV 0 release precedes departure.
    model.beginEditingGesture(named: "Exposure")
    for exposure in [0.125, 0.0] {
      model.setExposureEV(exposure)
      try await detailedPublication(model, exposure: exposure, demand: demand, deadline: deadline)
    }
    model.endEditingGesture()
    try await settledFull(model, file: files[0], files: files, deadline: deadline)
    try #require(model.parameters == initialParameters)
    try #require(
      try imageHash(try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))) == expectedHash
    )
  }

  private func cachedRevisit(
    _ model: AppModel, files: [URL], expectedHash: String,
    secondaryParameters: ProcessingParameters, secondaryHash: String,
    deadline: ContinuousClock.Instant
  ) async throws -> RevisitSample {
    let beforeDeparture = try state(model, label: "A before departure")
    let decodes = model.fullResolutionPreviewDecodeCount
    model.selection = files[1]
    model.loadSelection()
    try await settledFull(model, file: files[1], files: files, deadline: deadline)
    try #require(model.parameters == secondaryParameters)
    try #require(
      try imageHash(try #require(model.previewImage.flatMap(PreviewBitmap.cgImage)))
        == secondaryHash)
    let beforeReturn = try state(model, label: "B before cached A return")
    let workBefore = counters(model)
    model.selection = files[0]
    model.loadSelection()
    try await settledFull(model, file: files[0], files: files, deadline: deadline)
    let work = counters(model).subtracting(workBefore)
    try #require(model.fullResolutionPreviewDecodeCount == decodes)
    try #require(work.corrections == 0 && work.renderedCacheHits == 1)
    try #require(
      try imageHash(try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))) == expectedHash
    )
    return RevisitSample(
      beforeDeparture: beforeDeparture, beforeReturn: beforeReturn,
      afterReturn: try state(model, label: "A cached return settled"), returnWork: work)
  }

  private func gesture(
    _ model: AppModel, arm: String, pair: Int, files: [URL], demand: PreviewRenderDemand,
    trace: PreviewInteractionTrace, revisit: RevisitSample?, deadline: ContinuousClock.Instant
  ) async throws -> GestureSample {
    try #require(model.selection == files[0] && model.parameters.photoAdjustments.exposureEV == 0)
    try #require(!StillPreviewRenderer.supports(parameters: model.parameters, showOriginal: false))
    let before = try state(model, label: "\(arm) \(pair) before detailed edit")
    let workBefore = counters(model)
    let revisionBefore = model.publishedRenderRevision
    let eventOffset = trace.events.count
    model.beginEditingGesture(named: "Exposure")
    let start = ContinuousClock.now
    model.setExposureEV(0.25)
    try await detailedPublication(model, exposure: 0.25, demand: demand, deadline: deadline)
    let observedPublicationMilliseconds = milliseconds(since: start)
    let viewportRevision = model.publishedRenderRevision
    try #require(viewportRevision > revisionBefore)
    let viewportRender = model.renderStats
    let viewportWork = counters(model).subtracting(workBefore)
    try #require(viewportWork.fullSourceDecodes == 0 && viewportWork.corrections == 1)
    try #require(viewportWork.renderedCacheHits == 0)
    let overview = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let detail = try #require(model.previewDetail.flatMap { PreviewBitmap.cgImage(from: $0.image) })
    let overviewHash = try imageHash(overview)
    let detailHash = try imageHash(detail)
    let overviewDimensions = PixelDimensions(width: overview.width, height: overview.height)
    let detailDimensions = PixelDimensions(width: detail.width, height: detail.height)
    let viewportState = try state(model, label: "\(arm) \(pair) detail published")
    let targetParameters = model.parameters
    let beforeRefinement = counters(model)
    let releaseStart = ContinuousClock.now
    model.endEditingGesture()
    try await waitUntil("\(arm) full release publication", deadline: deadline) {
      model.publishedRenderRevision > viewportRevision && model.previewDetail == nil
        && model.publishedPreviewParameters == targetParameters && !model.isRendering
    }
    let releaseToFullPublicationMilliseconds = milliseconds(since: releaseStart)
    let refinementRender = model.renderStats
    try await settledFull(model, file: files[0], files: files, deadline: deadline)
    let refinementWork = counters(model).subtracting(beforeRefinement)
    try #require(refinementWork.fullSourceDecodes == 0 && refinementWork.corrections == 1)
    try #require(refinementWork.renderedCacheHits == 0)
    let full = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    let events = Array(trace.events.dropFirst(eventOffset))
    let submitted = try #require(
      events.first { $0.stage == .requestSubmitted && $0.revision == viewportRevision })
    let publication = try #require(
      events.first { $0.stage == .modelPublished && $0.revision == viewportRevision })
    try #require(submitted.usesProxy == false && submitted.hasDetail == true)
    try #require(publication.renderer == "CPU viewport" && publication.hasDetail == true)
    try #require(submitted.sourceWidth == model.sourcePixelDimensions?.width)
    try #require(submitted.sourceHeight == model.sourcePixelDimensions?.height)
    let workerBegan = try #require(
      events.first { $0.stage == .workerBegan && $0.revision == viewportRevision })
    let workerFinished = try #require(
      events.first { $0.stage == .workerFinished && $0.revision == viewportRevision })
    return GestureSample(
      arm: arm, pair: pair,
      observedViewportPublicationMilliseconds: observedPublicationMilliseconds,
      modelViewportInteractionMilliseconds: viewportRender.lastInteractionLatencyMs,
      viewportRenderMilliseconds: viewportRender.lastRenderMs,
      viewportWorkerMilliseconds: workerFinished.milliseconds - workerBegan.milliseconds,
      releaseToFullPublicationMilliseconds: releaseToFullPublicationMilliseconds,
      refinementRenderMilliseconds: refinementRender.lastRenderMs,
      viewportWork: viewportWork, refinementWork: refinementWork,
      before: before, viewportPublished: viewportState,
      afterRefinement: try state(model, label: "\(arm) \(pair) full refinement settled"),
      revisit: revisit, events: events,
      overviewSHA256: overviewHash, detailSHA256: detailHash, fullSHA256: try imageHash(full),
      overviewDimensions: overviewDimensions, detailDimensions: detailDimensions,
      fullDimensions: PixelDimensions(width: full.width, height: full.height),
      parameters: targetParameters)
  }

  private func detailedPublication(
    _ model: AppModel, exposure: Double, demand: PreviewRenderDemand,
    deadline: ContinuousClock.Instant
  ) async throws {
    try await waitUntil("matching CPU detail publication", deadline: deadline) {
      model.previewSourceKind == .rawFull && !model.isLoading && !model.isRendering
        && model.publishedPreviewParameters?.photoAdjustments.exposureEV == exposure
        && model.previewDetail?.rect == demand.detailRect && model.previewImage != nil
    }
    try #require(model.publishedPreviewParameters == model.parameters)
    try #require(!model.isShowingRetainedCanvas && !model.showOriginal)
    try #require(model.previewImage?.size == demand.documentSize)
  }

  private func settledFull(
    _ model: AppModel, file: URL, files: [URL], deadline: ContinuousClock.Instant
  ) async throws {
    try await waitUntil("settled two-session full preview", deadline: deadline) {
      model.selection == file && model.previewSourceKind == .rawFull
        && model.previewImage != nil && model.previewDetail == nil
        && files.allSatisfy { model.cachedPreviewKind(for: $0) == .rawFull }
        && !model.isLoading && !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive && !model.isAnalyzingScanStacks
        && model.previewStatisticsRevision == model.publishedRenderRevision
    }
    try #require(model.previewCacheSessionCount == 2)
    try #require(model.publishedPreviewParameters == model.parameters)
    try #require(!model.showOriginal && !model.isShowingRetainedCanvas)
    let source = try #require(model.sourcePixelDimensions)
    let dimensions = ImageGeometry.outputDimensions(source: source, parameters: model.parameters)
    let image = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    try #require(image.width == dimensions.width && image.height == dimensions.height)
    try #require(
      model.previewImage?.size == CGSize(width: dimensions.width, height: dimensions.height))
  }

  private func cpuOracle(
    source: UInt16Image, parameters: ProcessingParameters, region: ImageRegion,
    overviewMaximumDimension: Int
  ) throws -> Oracle {
    let full = FilmProcessing.correctedPreview(image: source, parameters: parameters)
    let cache = CPUPreviewPreparationCache(image: source)
    let viewport = try #require(
      cache.renderViewport(
        parameters: parameters, region: region, overviewMaximumDimension: overviewMaximumDimension))
    try #require(
      viewport.overview
        == full.resizedToFit(maxDimension: 2_048).resizedToFit(
          maxDimension: overviewMaximumDimension))
    var detailPixels: [UInt16] = []
    detailPixels.reserveCapacity(region.width * region.height * full.channels)
    for y in region.y..<(region.y + region.height) {
      let start = (y * full.width + region.x) * full.channels
      detailPixels.append(contentsOf: full.pixels[start..<(start + region.width * full.channels)])
    }
    try #require(
      viewport.detail
        == UInt16Image(
          width: region.width, height: region.height, channels: full.channels, pixels: detailPixels)
    )
    return Oracle(
      fullSHA256: try imageHash(try #require(full.makePreviewCGImage())),
      overviewSHA256: try imageHash(try #require(viewport.overview.makePreviewCGImage())),
      detailSHA256: try imageHash(try #require(viewport.detail.makePreviewCGImage())),
      fullDimensions: PixelDimensions(width: full.width, height: full.height),
      overviewDimensions: PixelDimensions(
        width: viewport.overview.width, height: viewport.overview.height),
      detailDimensions: PixelDimensions(
        width: viewport.detail.width, height: viewport.detail.height))
  }

  private func waitUntil(
    _ label: String, deadline overall: ContinuousClock.Instant,
    condition: @MainActor () -> Bool
  ) async throws {
    let deadline = min(overall, ContinuousClock.now + .seconds(180))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out: \(label)")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func counters(_ model: AppModel) -> Counters {
    Counters(
      fullSourceDecodes: model.fullResolutionPreviewDecodeCount,
      corrections: model.previewCorrectionCount, renderedCacheHits: model.previewRenderCacheHits,
      statisticsComputations: model.previewStatisticsComputationCount,
      submittedSnapshots: model.renderStats.submittedSnapshots,
      displayedRenders: model.renderStats.displayedRenders,
      droppedSnapshots: model.renderStats.droppedSnapshots)
  }

  private func state(_ model: AppModel, label: String) throws -> State {
    State(
      label: label, chargedPreviewBytes: model.previewCachePhysicalBytes,
      previewBudgetBytes: model.previewMemoryByteLimit, sessions: model.previewCacheSessionCount,
      retainedCanvases: model.retainedCanvasPreviewCount, counters: counters(model),
      memory: try memorySample())
  }

  private func imageHash(_ image: CGImage) throws -> String {
    SHA256.hash(data: try #require(image.dataProvider?.data as Data?)).description
  }

  private func pixelHash(_ image: UInt16Image) -> String {
    image.pixels.withUnsafeBytes { SHA256.hash(data: Data($0)).description }
  }

  private func fileHash(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).description
  }

  private func freshOutput(_ path: String?) throws -> URL {
    let output =
      path.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "fsc-detailed-revisit-\(UUID().uuidString).json")
    try #require(
      !FileManager.default.fileExists(atPath: output.path),
      "DETAILED_CACHED_REVISIT_OUTPUT must be fresh")
    return output
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds)
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
    try #require(result == KERN_SUCCESS)
    return MemorySample(
      physicalFootprintBytes: UInt64(info.phys_footprint),
      processLifetimePeakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak)),
      reusableBytes: UInt64(info.reusable))
  }

  private func provenance() throws -> Provenance {
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sourcePaths = [
      "appModel": "Sources/FilmScanConverterMac/AppModel.swift",
      "previewSessionCache": "Sources/FilmScanConverterMac/PreviewSessionCache.swift",
      "cpuPreparation": "Sources/FilmScanEngine/CPUPreviewPreparationCache.swift",
      "viewportDemand": "Sources/FilmScanConverterMac/PreviewRenderDemand.swift",
    ]
    var hashes = try sourcePaths.mapValues { try fileHash(packageRoot.appendingPathComponent($0)) }
    hashes["harness"] = try fileHash(URL(fileURLWithPath: #filePath))
    let testBundle = Bundle.allBundles.first {
      $0.bundleURL.pathExtension == "xctest"
        && $0.bundleURL.lastPathComponent.contains("FilmScanEngine")
    }
    let binary = try #require(testBundle?.executableURL ?? Bundle.main.executableURL)
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    let hardware = String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return Provenance(
      sourceRevision: try gitOutput(["rev-parse", "HEAD"], directory: packageRoot),
      dirtyStatus: try gitOutput(["status", "--porcelain"], directory: packageRoot),
      sourceSHA256: hashes, binaryExecutableName: binary.lastPathComponent,
      binaryRole: testBundle == nil ? "runtime executable" : "loaded test bundle executable",
      binarySHA256: try fileHash(binary), hardware: hardware,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      thermalStateAtStart: ProcessInfo.processInfo.thermalState.rawValue)
  }

  private func gitOutput(_ arguments: [String], directory: URL) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct Counters: Codable {
    let fullSourceDecodes: Int
    let corrections: Int
    let renderedCacheHits: Int
    let statisticsComputations: Int
    let submittedSnapshots: Int
    let displayedRenders: Int
    let droppedSnapshots: Int

    func subtracting(_ other: Counters) -> Counters {
      Counters(
        fullSourceDecodes: fullSourceDecodes - other.fullSourceDecodes,
        corrections: corrections - other.corrections,
        renderedCacheHits: renderedCacheHits - other.renderedCacheHits,
        statisticsComputations: statisticsComputations - other.statisticsComputations,
        submittedSnapshots: submittedSnapshots - other.submittedSnapshots,
        displayedRenders: displayedRenders - other.displayedRenders,
        droppedSnapshots: droppedSnapshots - other.droppedSnapshots)
    }
  }

  private struct MemorySample: Codable {
    let physicalFootprintBytes: UInt64
    let processLifetimePeakPhysicalFootprintBytes: UInt64
    let reusableBytes: UInt64
  }

  private struct State: Codable {
    let label: String
    let chargedPreviewBytes: Int
    let previewBudgetBytes: Int
    let sessions: Int
    let retainedCanvases: Int
    let counters: Counters
    let memory: MemorySample
  }

  private struct Rect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  private struct RevisitSample: Codable {
    let beforeDeparture: State
    let beforeReturn: State
    let afterReturn: State
    let returnWork: Counters
  }

  private struct GestureSample: Codable {
    let arm: String
    let pair: Int
    let observedViewportPublicationMilliseconds: Double
    let modelViewportInteractionMilliseconds: Double
    let viewportRenderMilliseconds: Double
    let viewportWorkerMilliseconds: Double
    let releaseToFullPublicationMilliseconds: Double
    let refinementRenderMilliseconds: Double
    let viewportWork: Counters
    let refinementWork: Counters
    let before: State
    let viewportPublished: State
    let afterRefinement: State
    let revisit: RevisitSample?
    let events: [PreviewInteractionTrace.Event]
    let overviewSHA256: String
    let detailSHA256: String
    let fullSHA256: String
    let overviewDimensions: PixelDimensions
    let detailDimensions: PixelDimensions
    let fullDimensions: PixelDimensions
    let parameters: ProcessingParameters
  }

  private struct Oracle: Codable {
    let fullSHA256: String
    let overviewSHA256: String
    let detailSHA256: String
    let fullDimensions: PixelDimensions
    let overviewDimensions: PixelDimensions
    let detailDimensions: PixelDimensions
  }

  private struct Measurement: Codable {
    let sourceDimensions: PixelDimensions
    let sourcePixelSHA256: String
    let initialFullSHA256: String
    let initialParameters: ProcessingParameters
    let secondaryFullSHA256: String
    let secondaryParameters: ProcessingParameters
    let overviewMaximumDimension: Int
    let detailRegion: Rect
    let samples: [GestureSample]
    let oracles: [Oracle]
    let beforeOracle: State
    let afterCloseAll: State
  }

  private struct Provenance: Codable {
    let sourceRevision: String
    let dirtyStatus: String
    let sourceSHA256: [String: String]
    let binaryExecutableName: String
    let binaryRole: String
    let binarySHA256: String
    let hardware: String
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let thermalStateAtStart: Int
  }

  private struct Report: Encodable {
    let schemaVersion = 1
    let status = "report-only matched detailed gesture collection"
    let configuredCacheDepth = 2
    let pairedRepetitions = 3
    let visibleRegion = Rect(x: 512, y: 384, width: 1_200, height: 800)
    let backingScale = 2
    let magnification = 1
    let exposureStart = 0.0
    let exposureTarget = 0.25
    let generatedAt: String
    let provenance: Provenance
    let framePaths: [String]
    let configuredParameters: ProcessingParameters
    let inputSHA256: [String: String]
    let memoryBeforeModel: MemorySample
    let measurement: Measurement
    let memoryAfterVerifiedModelRelease: MemorySample
    let limits = [
      "Programmatic AppModel detailed publication, not native input or screen-presentation latency.",
      "One exposure value is timed inside a gesture; full refinement on release is measured separately.",
      "Each arm has untimed viewport reset and full refinement; revisit then reuses the complete cached raster without a new edit before the measured setter.",
      "The overview is bounded to 1024 pixels; its logical canvas dimensions do not imply a full-detail overview bitmap.",
      "Detailed requests use the full-source CPU owner, distinct from the Fit continuous-edit proxy; no Fit timing claim is made.",
      "Preparation reuse is a source-backed explanation. Selected CPU owner internals are not exposed or directly counted by this real-RAW harness.",
      "Accepted full-source decode results exclude obsolete/cancelled results and can precede speculative cache admission; this is not a native-start/completion/cancellation count.",
      "Charged preview bytes, process physical footprint and process-lifetime peak footprint are separate measurements; no physical cause is attributed.",
      "The Close All sample still has a test source guard; verified weak-model release is sampled after that guard leaves scope.",
      "Exact fresh CPU full/overview/detail comparisons occur after all timed arms; they check reuse correctness, not photographic quality or CPU/Metal parity.",
      "Input/filesystem caches and other machine workloads are uncontrolled; three paired samples do not establish general performance improvement.",
      "Runtime source hashes describe the execution checkout; external compiled-bundle manifests and source archives are required to bind frozen binaries to their actual source cohort.",
    ]
  }
}
