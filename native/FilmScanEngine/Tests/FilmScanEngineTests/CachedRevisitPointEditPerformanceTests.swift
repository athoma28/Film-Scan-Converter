import AppKit
import CryptoKit
@preconcurrency import Darwin
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Cached RAW revisit first point-edit measurement", .serialized)
@MainActor
struct CachedRevisitPointEditPerformanceTests {
  private static let frames = [
    "fuji400-fresh/DSCF2833.RAF", "fuji400-fresh/DSCF2851.RAF",
  ]

  @Test(
    "Compare identical warm and first-after-revisit full-source CPU exposure edits",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_CACHED_REVISIT_EDIT_TESTS"] == "1",
      "set RUN_CACHED_REVISIT_EDIT_TESTS=1 with Fuji DSCF2833 and DSCF2851"))
  func matchedWarmAndRevisitEdits() async throws {
    let deadline = ContinuousClock.now + .seconds(900)
    let files = Self.frames.map(SampleRawCorpus.url(relativePath:))
    for file in files {
      try #require(FileManager.default.fileExists(atPath: file.path), "Missing \(file.path)")
    }
    let output = try freshOutput()
    let sourceFileHashes = try Dictionary(
      uniqueKeysWithValues: zip(Self.frames, files).map { ($0.0, try fileHash($0.1)) })
    let provenance = try provenance()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-cached-revisit-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "fsc-cached-revisit-edit-\(UUID().uuidString)"
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
      try await waitUntil("model release", deadline: deadline) { releasedModel == nil }
    } catch {
      model?.closeAllScans()
      model = nil
      try? await waitUntil("failed measurement release", deadline: deadline) {
        releasedModel == nil
      }
      throw error
    }
    let memoryAfterRelease = try memorySample()
    for (frame, file) in zip(Self.frames, files) {
      try #require(try fileHash(file) == sourceFileHashes[frame], "RAW source changed: \(frame)")
    }
    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()), provenance: provenance,
      inputSHA256: sourceFileHashes, memoryBeforeModel: memoryBeforeModel,
      measurement: measurement, memoryAfterVerifiedModelRelease: memoryAfterRelease)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(
      !FileManager.default.fileExists(atPath: output.path), "Output path is no longer fresh")
    try encoder.encode(report).write(to: output, options: .atomic)
    print(
      "CACHED_REVISIT_EDIT: 3 matched pairs; report \(output.path). Model publication, CPU render, and process footprint; preparation attribution is a source-backed inference."
    )
  }

  private func measure(
    model: AppModel, files: [URL], deadline: ContinuousClock.Instant
  ) async throws -> Measurement {
    let warmupStart = ContinuousClock.now
    model.importFiles(files)
    try await settled(model, file: files[0], files: files, deadline: deadline)
    try #require(model.parameters.photoAdjustments.schemaVersion == 4)
    try #require(model.parameters.photoAdjustments.exposureEV == 0)
    let source = try #require(model.decodedImage)
    let sourcePixelsHash = pixelHash(source)
    let warmupMilliseconds = milliseconds(since: warmupStart)
    let warmed = try state(
      model, label: "initial selected CPU correction and both decoded sessions settled")
    var pairs: [Pair] = []
    for index in 0..<3 {
      let order = index.isMultiple(of: 2) ? ["warm", "revisit"] : ["revisit", "warm"]
      var samples: [EditSample] = []
      for arm in order {
        var revisit: RevisitSample?
        if arm == "revisit" {
          revisit = try await cachedRevisit(model, files: files, deadline: deadline)
        }
        samples.append(
          try await edit(
            model, arm: arm, pair: index, files: files, revisit: revisit, deadline: deadline))
        // Returning to zero is outside the timed arm. The timed render already
        // populated geometry; this reset leaves the next warm control prepared.
        model.setExposureEV(0)
        try await settled(model, file: files[0], files: files, deadline: deadline)
        try #require(model.parameters.photoAdjustments.exposureEV == 0)
      }
      pairs.append(Pair(index: index, order: order, edits: samples))
    }
    let beforeOracle = try state(model, label: "all paired edits settled before independent oracle")
    let finalSource = try #require(model.decodedImage)
    try #require(pixelHash(finalSource) == sourcePixelsHash)
    var targetParameters = model.parameters
    targetParameters.photoAdjustments.exposureEV = 0.25
    // This independent complete production CPU render is deliberately after
    // every timer so its geometry, allocation, and hashing cannot warm an arm.
    let oracle = try cpuOracle(image: finalSource, parameters: targetParameters)
    for sample in pairs.flatMap(\.edits) {
      try #require(
        sample.previewSHA256 == oracle.hash, "Timed arm differs from the same-source production CPU"
      )
      try #require(sample.width == oracle.width && sample.height == oracle.height)
      try #require(
        sample.parameters == targetParameters, "Matched arms must use identical target parameters")
    }
    let afterOracle = try state(model, label: "after untimed independent CPU/hash guards")
    try await model.flushSettings()
    model.closeAllScans()
    try await waitUntil("Close All drain", deadline: deadline) {
      !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive && !model.isAnalyzingScanStacks
    }
    try #require(model.previewImage == nil && model.previewCacheSessionCount == 0)
    let afterClose = try state(model, label: "Close All settled")
    return Measurement(
      warmupMilliseconds: warmupMilliseconds, sourceWidth: source.width,
      sourceHeight: source.height,
      onePassSourcePixelsSHA256: sourcePixelsHash, oracle: oracle,
      initialWarmState: warmed, pairs: pairs, beforeOracle: beforeOracle,
      afterOracle: afterOracle, afterCloseAll: afterClose)
  }

  private func cachedRevisit(
    _ model: AppModel, files: [URL], deadline: ContinuousClock.Instant
  ) async throws -> RevisitSample {
    try #require(model.parameters.photoAdjustments.exposureEV == 0)
    let beforeDeparture = try state(model, label: "before A departure")
    let decodesBefore = model.fullResolutionPreviewDecodeCount
    model.selection = files[1]
    model.loadSelection()
    try await settled(model, file: files[1], files: files, deadline: deadline)
    let beforeReturn = try state(model, label: "B settled before cached A return")
    let countersBeforeReturn = counters(model)
    let start = ContinuousClock.now
    model.selection = files[0]
    model.loadSelection()
    try await settled(model, file: files[0], files: files, deadline: deadline)
    let returnMilliseconds = milliseconds(since: start)
    let returnWork = counters(model).subtracting(countersBeforeReturn)
    try #require(
      model.fullResolutionPreviewDecodeCount == decodesBefore,
      "Both RAW sessions must survive navigation")
    try #require(
      returnWork.corrections == 0 && returnWork.renderedCacheHits == 1,
      "A return must reuse the corrected raster")
    try #require(model.parameters.photoAdjustments.exposureEV == 0)
    return RevisitSample(
      beforeDeparture: beforeDeparture, beforeReturn: beforeReturn,
      afterReturn: try state(model, label: "cached A return settled"),
      returnMilliseconds: returnMilliseconds, returnWork: returnWork)
  }

  private func edit(
    _ model: AppModel, arm: String, pair: Int, files: [URL], revisit: RevisitSample?,
    deadline: ContinuousClock.Instant
  ) async throws -> EditSample {
    try #require(model.selection == files[0] && model.parameters.photoAdjustments.exposureEV == 0)
    try #require(!StillPreviewRenderer.supports(parameters: model.parameters, showOriginal: false))
    let before = try state(model, label: "\(arm) \(pair) before exposure")
    let workBefore = counters(model)
    let revision = model.publishedRenderRevision
    let start = ContinuousClock.now
    model.setExposureEV(0.25)
    try await waitUntil("\(arm) full exposure publication", deadline: deadline) {
      model.publishedRenderRevision > revision && model.previewSourceKind == .rawFull
        && model.publishedPreviewParameters?.photoAdjustments.exposureEV == 0.25
        && model.previewImage != nil && model.previewDetail == nil && !model.isRendering
    }
    let publicationMilliseconds = milliseconds(since: start)
    let render = model.renderStats
    try await settled(model, file: files[0], files: files, deadline: deadline)
    let settledMilliseconds = milliseconds(since: start)
    let work = counters(model).subtracting(workBefore)
    try #require(work.publishedFullSourceDecodes == 0)
    try #require(work.corrections == 1 && work.renderedCacheHits == 0)
    try #require(model.publishedPreviewParameters == model.parameters)
    try #require(!model.isShowingRetainedCanvas && !model.showOriginal)
    let image = try #require(model.previewImage.flatMap(PreviewBitmap.cgImage))
    return EditSample(
      arm: arm, pair: pair, publicationMilliseconds: publicationMilliseconds,
      publicationAndStatisticsSettledMilliseconds: settledMilliseconds,
      lastPreparationMilliseconds: render.lastPreparationMs,
      lastQueueWaitMilliseconds: render.lastQueueWaitMs,
      lastRenderMilliseconds: render.lastRenderMs,
      lastInteractionPublicationMilliseconds: render.lastInteractionLatencyMs,
      before: before, after: try state(model, label: "\(arm) \(pair) after exposure"),
      work: work, revisit: revisit, previewSHA256: try imageHash(image),
      width: image.width, height: image.height, parameters: model.parameters)
  }

  private func settled(
    _ model: AppModel, file: URL, files: [URL], deadline: ContinuousClock.Instant
  ) async throws {
    try await waitUntil(
      "settled two-session preview for \(file.lastPathComponent)", deadline: deadline
    ) {
      model.selection == file && model.previewSourceKind == .rawFull && model.previewImage != nil
        && files.allSatisfy { model.cachedPreviewKind(for: $0) == .rawFull }
        && !model.isLoading && !model.isRendering && !model.previewBackgroundWorkIsActive
        && !model.canvasSnapshotWorkIsActive && !model.isAnalyzingScanStacks
        && model.previewStatisticsRevision == model.publishedRenderRevision
    }
    try #require(model.previewCacheSessionCount == 2)
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

  private func state(_ model: AppModel, label: String) throws -> State {
    State(
      label: label, chargedPreviewBytes: model.previewCachePhysicalBytes,
      previewBudgetBytes: model.previewMemoryByteLimit, sessions: model.previewCacheSessionCount,
      retainedCanvases: model.retainedCanvasPreviewCount, counters: counters(model),
      memory: try memorySample())
  }

  private func counters(_ model: AppModel) -> Counters {
    Counters(
      publishedFullSourceDecodes: model.fullResolutionPreviewDecodeCount,
      corrections: model.previewCorrectionCount, renderedCacheHits: model.previewRenderCacheHits,
      statisticsComputations: model.previewStatisticsComputationCount,
      submittedSnapshots: model.renderStats.submittedSnapshots,
      displayedRenders: model.renderStats.displayedRenders)
  }

  private func cpuOracle(image: UInt16Image, parameters: ProcessingParameters) throws -> Oracle {
    let expected = try #require(
      FilmProcessing.correctedPreview(image: image, parameters: parameters).makePreviewCGImage())
    return Oracle(hash: try imageHash(expected), width: expected.width, height: expected.height)
  }

  private func imageHash(_ image: CGImage) throws -> String {
    SHA256.hash(data: try #require(image.dataProvider?.data as Data?)).description
  }

  private func fileHash(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).description
  }

  private func pixelHash(_ image: UInt16Image) -> String {
    image.pixels.withUnsafeBytes { SHA256.hash(data: Data($0)).description }
  }

  private func freshOutput() throws -> URL {
    let url =
      ProcessInfo.processInfo.environment["CACHED_REVISIT_EDIT_OUTPUT"].map {
        URL(fileURLWithPath: $0)
      }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "fsc-cached-revisit-edit-\(UUID().uuidString).json")
    try #require(
      !FileManager.default.fileExists(atPath: url.path), "CACHED_REVISIT_EDIT_OUTPUT must be fresh")
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
    try #require(result == KERN_SUCCESS, "Mach footprint sample failed: \(result)")
    return MemorySample(
      physicalFootprintBytes: UInt64(info.phys_footprint),
      processLifetimePeakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak)),
      reusableBytes: UInt64(info.reusable))
  }

  private func provenance() throws -> Provenance {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let testBundle = Bundle.allBundles.first {
      $0.bundleURL.pathExtension == "xctest"
        && $0.bundleURL.lastPathComponent.contains("FilmScanEngine")
    }
    let binary = try #require(testBundle?.executableURL ?? Bundle.main.executableURL)
    let sources = [
      "harness": URL(fileURLWithPath: #filePath),
      "appModel": root.appendingPathComponent(
        "native/FilmScanEngine/Sources/FilmScanConverterMac/AppModel.swift"),
      "previewSessionCache": root.appendingPathComponent(
        "native/FilmScanEngine/Sources/FilmScanConverterMac/PreviewSessionCache.swift"),
      "cpuPreparation": root.appendingPathComponent(
        "native/FilmScanEngine/Sources/FilmScanEngine/CPUPreviewPreparationCache.swift"),
    ]
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    let hardware = String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return Provenance(
      sourceRevision: try gitOutput(["rev-parse", "HEAD"], root: root),
      dirtyStatus: try gitOutput(["status", "--porcelain"], root: root),
      sourceSHA256: try sources.mapValues(fileHash), binaryPath: binary.path,
      binaryRole: testBundle == nil ? "runtime executable" : "loaded test bundle executable",
      binarySHA256: try fileHash(binary), hardware: hardware,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
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
    let statisticsComputations: Int
    let submittedSnapshots: Int
    let displayedRenders: Int

    func subtracting(_ other: Counters) -> Counters {
      Counters(
        publishedFullSourceDecodes: publishedFullSourceDecodes - other.publishedFullSourceDecodes,
        corrections: corrections - other.corrections,
        renderedCacheHits: renderedCacheHits - other.renderedCacheHits,
        statisticsComputations: statisticsComputations - other.statisticsComputations,
        submittedSnapshots: submittedSnapshots - other.submittedSnapshots,
        displayedRenders: displayedRenders - other.displayedRenders)
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

  private struct RevisitSample: Codable {
    let beforeDeparture: State
    let beforeReturn: State
    let afterReturn: State
    let returnMilliseconds: Double
    let returnWork: Counters
  }

  private struct EditSample: Codable {
    let arm: String
    let pair: Int
    let publicationMilliseconds: Double
    let publicationAndStatisticsSettledMilliseconds: Double
    let lastPreparationMilliseconds: Double
    let lastQueueWaitMilliseconds: Double
    let lastRenderMilliseconds: Double
    let lastInteractionPublicationMilliseconds: Double
    let before: State
    let after: State
    let work: Counters
    let revisit: RevisitSample?
    let previewSHA256: String
    let width: Int
    let height: Int
    let parameters: ProcessingParameters
  }

  private struct Pair: Codable {
    let index: Int
    let order: [String]
    let edits: [EditSample]
  }

  private struct Oracle: Codable {
    let hash: String
    let width: Int
    let height: Int
  }

  private struct Measurement: Codable {
    let warmupMilliseconds: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let onePassSourcePixelsSHA256: String
    let oracle: Oracle
    let initialWarmState: State
    let pairs: [Pair]
    let beforeOracle: State
    let afterOracle: State
    let afterCloseAll: State
  }

  private struct Provenance: Codable {
    let sourceRevision: String
    let dirtyStatus: String
    let sourceSHA256: [String: String]
    let binaryPath: String
    let binaryRole: String
    let binarySHA256: String
    let hardware: String
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let thermalStateAtStart: Int
  }

  private struct Report: Encodable {
    let schemaVersion = 1
    let status = "current-source matched warm/revisit baseline collection"
    let generatedAt: String
    let provenance: Provenance
    let inputSHA256: [String: String]
    let memoryBeforeModel: MemorySample
    let measurement: Measurement
    let memoryAfterVerifiedModelRelease: MemorySample
    let limits = [
      "One-pass full-source AppModel CPU correction; no gesture, proxy, export, native-input, or screen measurement.",
      "Three alternating-order pairs are descriptive samples, not a population-tail or general improvement estimate.",
      "First RAW decoding and selected initial CPU warp are untimed; both sessions must remain decoded during all arms.",
      "CPU preparation loss on cached revisit is inferred from source ownership; no internal geometry-build timer is instrumented.",
      "Charged cache bytes are accounting, distinct from process physical footprint and reusable pages.",
      "Peak footprint covers the process lifetime, including untimed source hashing and the final CPU oracle.",
      "Filesystem caches are uncontrolled; no physically cold-disk claim is made.",
      "The production CPU hash guard runs after timed arms; photographic quality and Metal parity are not established.",
      "Source files are hashed at execution; comparisons require a frozen binary and a matching complete source/toolchain manifest.",
    ]
  }
}
