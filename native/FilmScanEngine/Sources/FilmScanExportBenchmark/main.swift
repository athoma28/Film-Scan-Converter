import CryptoKit
import Darwin
import FilmScanEngine
import Foundation

struct StageTimings: Codable {
  let decodeSeconds: Double
  let processingSeconds: Double
  let geometrySeconds: Double
  let pixelPackingSeconds: Double
  let encodingFinalizationSeconds: Double

  var totalSeconds: Double {
    decodeSeconds + processingSeconds + geometrySeconds
      + pixelPackingSeconds + encodingFinalizationSeconds
  }
}

struct ExportSample: Codable {
  let repetition: Int
  let runClass: String
  let sourceShape: [Int]
  let outputShape: [Int]
  let stages: StageTimings
  let decodeSubstages: RawDecodeTimings
  let decodeUnaccountedSeconds: Double
  let peakResidentBytes: UInt64
  let residentBytesAfterDecode: UInt64
  let residentBytesAfterProcessing: UInt64
  let residentBytesAfterWrite: UInt64
  var residentBytesAfterRelease: UInt64
  let physicalFootprintBytesAfterDecode: UInt64
  let physicalFootprintBytesAfterProcessing: UInt64
  let physicalFootprintBytesAfterWrite: UInt64
  var physicalFootprintBytesAfterRelease: UInt64
  let peakPhysicalFootprintBytes: UInt64
  var reusableBytesAfterRelease: UInt64
  var heapStatisticsAfterRelease: NativeHeapStatistics?
  let packedPixelBytes: Int
  let outputBytes: Int
  let outputSHA256: String
  let outputRemovedAfterRun: Bool
}

struct FormatResult: Codable {
  let format: ExportFormat
  let samples: [ExportSample]
  let medianTotalSeconds: Double
  let medianStageSeconds: StageTimings
  let medianDecodeSubstages: RawDecodeTimings
  let p95TotalSeconds: Double
  let p95StageSeconds: StageTimings
  let p95DecodeSubstages: RawDecodeTimings
}

struct FileResult: Codable {
  let file: String
  let megapixels: Double
  let decoder: String
  let formats: [FormatResult]
}

struct BenchmarkReport: Codable {
  let generatedAt: String
  let configuration: String
  let repetitions: Int
  let framePercent: Int
  let cleanupPolicy: String
  let peakResidentMemoryNote: String
  let files: [FileResult]
}

struct DeterminismSample: Codable {
  let repetition: Int
  let runClass: String
  let demosaicWorkerCount: Int
  let sourceShape: [Int]
  let writerInputShape: [Int]
  let decodeSeconds: Double
  let decodeSubstages: RawDecodeTimings
  let decodeUnaccountedSeconds: Double
  let processingSeconds: Double
  let geometrySeconds: Double
  let pixelPackingSeconds: Double
  let encodingFinalizationSeconds: Double
  let diagnostics: RawDecodeDiagnostics
  let correctedImageSHA256: String
  let writerInputPixelsSHA256: String
  let outputSHA256: String
  let outputBytes: Int
  let peakPhysicalFootprintBytes: UInt64
  var physicalFootprintBytesAfterRelease: UInt64
  let outputRemovedAfterRun: Bool
}

struct DeterminismFileResult: Codable {
  let file: String
  let megapixels: Double
  let decoder: String
  let repetitions: Int
  let deterministic: Bool
  let firstDivergentBoundary: String?
  let boundaryAgreement: [StageBoundaryAgreement]
  let samples: [DeterminismSample]
}

struct DeterminismReport: Codable {
  let generatedAt: String
  let mode: String
  let configuration: String
  let repetitions: Int
  let framePercent: Int
  let writerContract: String
  let deterministic: Bool
  let boundaryNote: String
  let cleanupPolicy: String
  let files: [DeterminismFileResult]
}

struct CorrectionScenarioSample: Codable {
  let repetition: Int
  let scenario: String
  let passes: [String]
  let sourceShape: [Int]
  let outputShape: [Int]
  let decodeSeconds: Double
  let processingSeconds: Double
  let geometrySeconds: Double
  let pixelPackingSeconds: Double
  let encodingFinalizationSeconds: Double
  let correctedImageSHA256: String
  let writerInputPixelsSHA256: String
  let outputSHA256: String
  let outputBytes: Int
  let physicalFootprintBytesAfterDecode: UInt64
  let physicalFootprintBytesAfterProcessing: UInt64
  let physicalFootprintBytesAfterWrite: UInt64
  var physicalFootprintBytesAfterRelease: UInt64
  let peakPhysicalFootprintBytes: UInt64
  var heapStatisticsAfterRelease: NativeHeapStatistics?
  let outputRemovedAfterRun: Bool
}

struct CorrectionScenarioResult: Codable {
  let scenario: String
  let passes: [String]
  let samples: [CorrectionScenarioSample]
  let medianProcessingSeconds: Double
  let p95ProcessingSeconds: Double
  let medianPhysicalFootprintBytesAfterProcessing: UInt64
  let medianPhysicalFootprintBytesAfterRelease: UInt64
}

struct CorrectionScenarioFileResult: Codable {
  let file: String
  let megapixels: Double
  let decoder: String
  let repetitions: Int
  let scenarios: [CorrectionScenarioResult]
}

struct CorrectionScenarioReport: Codable {
  let generatedAt: String
  let mode: String
  let configuration: String
  let repetitions: Int
  let framePercent: Int
  let writerContract: String
  let scenarioNote: String
  let cleanupPolicy: String
  let peakResidentMemoryNote: String
  let files: [CorrectionScenarioFileResult]
}

private struct MeasuredExportRun {
  let sample: ExportSample
  let decoderVersion: String
  let megapixels: Double
  let summary: String
}

private struct ProcessMemorySnapshot {
  let residentBytes: UInt64
  let physicalFootprintBytes: UInt64
  let peakPhysicalFootprintBytes: UInt64
  let reusableBytes: UInt64
}

struct Options {
  let rawDirectory: URL
  let outputURL: URL
  let repetitions: Int
  let formats: [ExportFormat]
  let framePercent: Int
  let allFiles: Bool
  let selectedFilename: String?
  let fileLimit: Int?
  let determinism: Bool
  let corrections: Bool
}

#if DEBUG
  private let buildConfiguration = "debug"
#else
  private let buildConfiguration = "release"
#endif

private let usage = """
  Usage: FilmScanExportBenchmark RAW_DIRECTORY OUTPUT_JSON [REPETITIONS]
           [--formats=tiff,jpeg,png,dng] [--frame-percent=N]
           [--file=NAME.raf | --all] [--limit=N]
           [--determinism | --corrections]

  The default run benchmarks the first RAF in lexical order in all formats.
  Every generated image is hashed and deleted immediately after its run; only
  the compact JSON report remains.

  --determinism repeats full-resolution camera-scan decodes of each selected
  file with stage-boundary SHA-256 capture, writes one LZW TIFF per
  repetition, and reports per-boundary digest agreement so a threaded decode
  candidate's first divergent stage can be isolated. Use at least 5
  repetitions. --formats is not accepted in this mode.

  --corrections decodes each selected file once per repetition at full
  resolution, then measures the five documented full-resolution correction
  scenarios (neutral, tone, protected-color, dye-mixing, combined) against
  the same decoded image, reporting per-scenario processing time, Mach
  physical footprint, allocations, and corrected/writer-input/output hashes.
  One LZW TIFF per scenario is written and removed. --formats is not
  accepted in this mode.
  """

private func parseOptions() -> Options? {
  let arguments = CommandLine.arguments
  guard arguments.count >= 3 else { return nil }

  let extras = Array(arguments.dropFirst(3))
  var requestedRepetitions: Int?
  var formats = ExportFormat.allCases
  var formatsExplicit = false
  var framePercent = 0
  var allFiles = false
  var selectedFilename: String?
  var fileLimit: Int?
  var determinism = false
  var corrections = false

  for argument in extras {
    if argument == "--all" {
      allFiles = true
    } else if argument == "--determinism" {
      determinism = true
    } else if argument == "--corrections" {
      corrections = true
    } else if argument.hasPrefix("--file=") {
      selectedFilename = String(argument.dropFirst("--file=".count))
    } else if argument.hasPrefix("--frame-percent=") {
      guard let value = Int(argument.dropFirst("--frame-percent=".count)), value >= 0 else {
        return nil
      }
      framePercent = value
    } else if argument.hasPrefix("--formats=") {
      let names = argument.dropFirst("--formats=".count).split(separator: ",")
      let parsed = names.compactMap { ExportFormat(rawValue: String($0).lowercased()) }
      guard parsed.count == names.count, !parsed.isEmpty else { return nil }
      formats = parsed
      formatsExplicit = true
    } else if argument.hasPrefix("--limit=") {
      guard let value = Int(argument.dropFirst("--limit=".count)), value > 0 else {
        return nil
      }
      fileLimit = value
    } else if let value = Int(argument) {
      guard value > 0, requestedRepetitions == nil else { return nil }
      requestedRepetitions = value
    } else {
      return nil
    }
  }

  guard !(allFiles && selectedFilename != nil) else { return nil }
  // Determinism and corrections modes fix one writer contract (LZW TIFF) so
  // repeated samples stay comparable; format matrices belong to the default
  // mode. The two evidence modes are mutually exclusive.
  guard !(determinism && formatsExplicit) else { return nil }
  guard !(corrections && formatsExplicit) else { return nil }
  guard !(determinism && corrections) else { return nil }
  let repetitions = requestedRepetitions ?? (determinism ? 5 : 3)
  guard !determinism || repetitions >= 5 else { return nil }
  guard !corrections || repetitions >= 1 else { return nil }
  return Options(
    rawDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
    outputURL: URL(fileURLWithPath: arguments[2]),
    repetitions: repetitions,
    formats: (determinism || corrections) ? [.tiff] : formats,
    framePercent: framePercent,
    allFiles: allFiles,
    selectedFilename: selectedFilename,
    fileLimit: fileLimit,
    determinism: determinism,
    corrections: corrections
  )
}

guard let options = parseOptions() else {
  FileHandle.standardError.write(Data((usage + "\n").utf8))
  exit(2)
}

let availableFiles = try RecursiveFileDiscovery.files(
  under: options.rawDirectory,
  extensions: ["raf"]
)

let selectedFiles: [URL]
if let selectedFilename = options.selectedFilename {
  selectedFiles = availableFiles.filter {
    $0.lastPathComponent == selectedFilename
      || $0.path.replacingOccurrences(of: options.rawDirectory.path + "/", with: "")
        == selectedFilename
  }
} else if options.allFiles {
  selectedFiles = availableFiles
} else {
  selectedFiles = Array(availableFiles.prefix(1))
}
let files = options.fileLimit.map { Array(selectedFiles.prefix($0)) } ?? selectedFiles

if options.selectedFilename != nil, selectedFiles.count > 1 {
  FileHandle.standardError.write(
    Data(
      "The requested basename is present in more than one stock folder; pass its root-relative path.\n"
        .utf8
    )
  )
  exit(2)
}
guard !files.isEmpty else {
  FileHandle.standardError.write(Data("No matching RAF files found.\n".utf8))
  exit(2)
}

let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
  "FilmScanExportBenchmark-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(
  at: scratchDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratchDirectory) }

if options.determinism {
  try runDeterminism(options: options, files: files, scratchDirectory: scratchDirectory)
} else if options.corrections {
  try runCorrections(options: options, files: files, scratchDirectory: scratchDirectory)
} else {
  try runBenchmark(options: options, files: files, scratchDirectory: scratchDirectory)
}

private func runBenchmark(options: Options, files: [URL], scratchDirectory: URL) throws {
  var fileResults = [FileResult]()
  for sourceURL in files {
    let preview = try RawImageDecoder.extractThumbnail(sourceURL, maxDimension: 640).image
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: preview)
    let processingParameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative
    )

    var decoderVersion = "unknown"
    var formatResults = [FormatResult]()
    var megapixels = 0.0

    for format in options.formats {
      var samples = [ExportSample]()
      for repetition in 1...options.repetitions {
        let destinationURL = scratchDirectory.appendingPathComponent(
          "\(sourceURL.deletingPathExtension().lastPathComponent)-\(format.rawValue)-\(repetition).\(format.fileExtension)"
        )
        let run = try autoreleasepool {
          try measureExport(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            processingParameters: processingParameters,
            format: format,
            framePercent: options.framePercent,
            repetition: repetition
          )
        }
        decoderVersion = run.decoderVersion
        megapixels = run.megapixels
        var releasedSample = run.sample
        let releasedMemory = processMemorySnapshot()
        releasedSample.residentBytesAfterRelease = releasedMemory.residentBytes
        releasedSample.physicalFootprintBytesAfterRelease = releasedMemory.physicalFootprintBytes
        releasedSample.reusableBytesAfterRelease = releasedMemory.reusableBytes
        releasedSample.heapStatisticsAfterRelease = RawImageDecoder.defaultHeapStatistics()
        samples.append(releasedSample)
        print(run.summary)
      }

      formatResults.append(
        FormatResult(
          format: format,
          samples: samples,
          medianTotalSeconds: median(samples.map(\.stages.totalSeconds)),
          medianStageSeconds: StageTimings(
            decodeSeconds: median(samples.map(\.stages.decodeSeconds)),
            processingSeconds: median(samples.map(\.stages.processingSeconds)),
            geometrySeconds: median(samples.map(\.stages.geometrySeconds)),
            pixelPackingSeconds: median(samples.map(\.stages.pixelPackingSeconds)),
            encodingFinalizationSeconds: median(
              samples.map(\.stages.encodingFinalizationSeconds))
          ),
          medianDecodeSubstages: RawDecodeTimings(
            openSeconds: median(samples.map(\.decodeSubstages.openSeconds)),
            unpackSeconds: median(samples.map(\.decodeSubstages.unpackSeconds)),
            demosaicSeconds: median(samples.map(\.decodeSubstages.demosaicSeconds)),
            libRawPostprocessSeconds: median(
              samples.map(\.decodeSubstages.libRawPostprocessSeconds)),
            processedImageSeconds: median(samples.map(\.decodeSubstages.processedImageSeconds)),
            isoPolicySeconds: median(samples.map(\.decodeSubstages.isoPolicySeconds)),
            swiftCopySwizzleSeconds: median(
              samples.map(\.decodeSubstages.swiftCopySwizzleSeconds))
          ),
          p95TotalSeconds: percentile(samples.map(\.stages.totalSeconds), fraction: 0.95),
          p95StageSeconds: StageTimings(
            decodeSeconds: percentile(samples.map(\.stages.decodeSeconds), fraction: 0.95),
            processingSeconds: percentile(samples.map(\.stages.processingSeconds), fraction: 0.95),
            geometrySeconds: percentile(samples.map(\.stages.geometrySeconds), fraction: 0.95),
            pixelPackingSeconds: percentile(
              samples.map(\.stages.pixelPackingSeconds), fraction: 0.95),
            encodingFinalizationSeconds: percentile(
              samples.map(\.stages.encodingFinalizationSeconds), fraction: 0.95)
          ),
          p95DecodeSubstages: RawDecodeTimings(
            openSeconds: percentile(samples.map(\.decodeSubstages.openSeconds), fraction: 0.95),
            unpackSeconds: percentile(samples.map(\.decodeSubstages.unpackSeconds), fraction: 0.95),
            demosaicSeconds: percentile(
              samples.map(\.decodeSubstages.demosaicSeconds), fraction: 0.95),
            libRawPostprocessSeconds: percentile(
              samples.map(\.decodeSubstages.libRawPostprocessSeconds), fraction: 0.95),
            processedImageSeconds: percentile(
              samples.map(\.decodeSubstages.processedImageSeconds), fraction: 0.95),
            isoPolicySeconds: percentile(
              samples.map(\.decodeSubstages.isoPolicySeconds), fraction: 0.95),
            swiftCopySwizzleSeconds: percentile(
              samples.map(\.decodeSubstages.swiftCopySwizzleSeconds), fraction: 0.95)
          )
        )
      )
    }

    fileResults.append(
      FileResult(
        file: sourceURL.path.replacingOccurrences(
          of: options.rawDirectory.path + "/",
          with: ""
        ),
        megapixels: megapixels,
        decoder: decoderVersion,
        formats: formatResults
      )
    )
  }

  let report = BenchmarkReport(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    configuration:
      "\(buildConfiguration)-mode full-resolution RAW decode and production export path",
    repetitions: options.repetitions,
    framePercent: options.framePercent,
    cleanupPolicy:
      "Each generated export is hashed and deleted immediately after its measured run.",
    peakResidentMemoryNote:
      "ru_maxrss and Mach resident_size include reclaimable reusable pages. physicalFootprintBytes and ledger peak physical footprint are the resource-safety measures; reusableBytes explains resident memory that macOS can reclaim.",
    files: fileResults
  )
  let parentDirectory = options.outputURL.deletingLastPathComponent()
  try FileManager.default.createDirectory(
    at: parentDirectory, withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(report).write(to: options.outputURL, options: .atomic)
  print("Wrote \(options.outputURL.path)")
}

private enum BenchmarkError: Error {
  case missingStageDiagnostics
}

private struct MeasuredDeterminismRun {
  let sample: DeterminismSample
  let decoderVersion: String
  let megapixels: Double
  let summary: String
}

private func runDeterminism(options: Options, files: [URL], scratchDirectory: URL) throws {
  var fileResults = [DeterminismFileResult]()
  for sourceURL in files {
    let preview = try RawImageDecoder.extractThumbnail(sourceURL, maxDimension: 640).image
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: preview)
    let processingParameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative
    )

    var decoderVersion = "unknown"
    var megapixels = 0.0
    var samples = [DeterminismSample]()

    for repetition in 1...options.repetitions {
      let destinationURL = scratchDirectory.appendingPathComponent(
        "\(sourceURL.deletingPathExtension().lastPathComponent)-determinism-\(repetition).tiff")
      let run = try autoreleasepool {
        try measureDeterminismSample(
          sourceURL: sourceURL,
          destinationURL: destinationURL,
          processingParameters: processingParameters,
          framePercent: options.framePercent,
          repetition: repetition
        )
      }
      decoderVersion = run.decoderVersion
      megapixels = run.megapixels
      var sample = run.sample
      sample.physicalFootprintBytesAfterRelease = processMemorySnapshot().physicalFootprintBytes
      samples.append(sample)
      print(run.summary)
      print(determinismDigestSummary(sample))
    }

    let agreement =
      RawDecodeDeterminism.agreement(samples.map(\.diagnostics)) + [
        digestAgreement(boundary: "correctedImage", digests: samples.map(\.correctedImageSHA256)),
        digestAgreement(
          boundary: "writerInputPixels", digests: samples.map(\.writerInputPixelsSHA256)),
        digestAgreement(boundary: "outputFile", digests: samples.map(\.outputSHA256)),
      ]
    let deterministic = agreement.allSatisfy(\.allAgree)
    let firstDivergent = agreement.first(where: { !$0.allAgree })?.boundary
    print(
      "\(sourceURL.lastPathComponent) determinism: "
        + (deterministic
          ? "all \(agreement.count) boundaries agree across \(samples.count) repetitions"
          : "FIRST DIVERGENT BOUNDARY: \(firstDivergent ?? "unknown")")
    )

    fileResults.append(
      DeterminismFileResult(
        file: sourceURL.path.replacingOccurrences(
          of: options.rawDirectory.path + "/",
          with: ""
        ),
        megapixels: megapixels,
        decoder: decoderVersion,
        repetitions: options.repetitions,
        deterministic: deterministic,
        firstDivergentBoundary: firstDivergent,
        boundaryAgreement: agreement,
        samples: samples
      )
    )
  }

  let report = DeterminismReport(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    mode: "camera-scan-determinism",
    configuration:
      "\(buildConfiguration)-mode repeated full-resolution camera-scan decode with stage-boundary SHA-256 capture",
    repetitions: options.repetitions,
    framePercent: options.framePercent,
    writerContract:
      "One LZW TIFF per repetition, matching the default benchmark's selected compression.",
    deterministic: fileResults.allSatisfy(\.deterministic),
    boundaryNote:
      "Boundaries are listed in pipeline order: unpackedMosaic, demosaicedImage, processedImage, postISOImage, swiftImage, correctedImage, writerInputPixels, outputFile. The first boundary with allAgree == false is the first stage a candidate build allowed to diverge. writerInputPixels is the image handed to the writer before packing; packed bytes and the encoded file are deterministic functions of it plus format parameters. Digests hash raw buffer bytes and compare runs of the same build on the same machine. Diagnostic hashing is included in decodeSeconds; decodeUnaccountedSeconds records decode work not assigned to the production substage timers.",
    cleanupPolicy:
      "Each generated export is hashed and deleted immediately after its measured run.",
    files: fileResults
  )
  let parentDirectory = options.outputURL.deletingLastPathComponent()
  try FileManager.default.createDirectory(
    at: parentDirectory, withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(report).write(to: options.outputURL, options: .atomic)
  print("Wrote \(options.outputURL.path)")
}

private func determinismDigestSummary(_ sample: DeterminismSample) -> String {
  let decodeBoundaries = RawDecodeDeterminism.boundaryDigests(of: sample.diagnostics)
  let allBoundaries =
    decodeBoundaries + [
      StageBoundaryDigest(
        boundary: "correctedImage",
        sha256: sample.correctedImageSHA256
      ),
      StageBoundaryDigest(
        boundary: "writerInputPixels",
        sha256: sample.writerInputPixelsSHA256
      ),
      StageBoundaryDigest(
        boundary: "outputFile",
        sha256: sample.outputSHA256
      ),
    ]
  let digests = allBoundaries.map { "\($0.boundary)=\($0.sha256)" }.joined(separator: " ")
  return
    "\(digests) peakPhysicalFootprintBytes=\(sample.peakPhysicalFootprintBytes) "
    + "physicalFootprintBytesAfterRelease=\(sample.physicalFootprintBytesAfterRelease)"
}

private func runCorrections(options: Options, files: [URL], scratchDirectory: URL) throws {
  var fileResults = [CorrectionScenarioFileResult]()
  for sourceURL in files {
    let preview = try RawImageDecoder.extractThumbnail(sourceURL, maxDimension: 640).image
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: preview)
    let baseParameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative
    )

    var decoderVersion = "unknown"
    var megapixels = 0.0
    var scenarioSamples: [String: [CorrectionScenarioSample]] = [:]

    for repetition in 1...options.repetitions {
      let decodeStart = ContinuousClock.now
      let decodeResult = try RawImageDecoder.decode(
        sourceURL,
        fullResolution: true,
        profile: .rawTherapeeCameraScan
      )
      let decodeSeconds = seconds(decodeStart.duration(to: .now))
      let memoryAfterDecode = processMemorySnapshot()
      let decoded = decodeResult.image
      decoderVersion = decodeResult.decoderVersion
      megapixels = Double(decoded.width * decoded.height) / 1_000_000
      print(
        "\(sourceURL.lastPathComponent) correction repetition \(repetition): "
          + "decode=\(formatted(decodeSeconds))s "
          + "physicalFootprintBytesAfterDecode=\(memoryAfterDecode.physicalFootprintBytes)")

      for scenario in CorrectionScenario.allCases {
        let destinationURL = scratchDirectory.appendingPathComponent(
          "\(sourceURL.deletingPathExtension().lastPathComponent)-"
            + "\(scenario.rawValue)-\(repetition).tiff")
        let parameters = scenario.processingParameters(base: baseParameters)
        var sample = try autoreleasepool {
          try measureCorrectionScenario(
            destinationURL: destinationURL,
            decoded: decoded,
            decodeSeconds: decodeSeconds,
            memoryAfterDecode: memoryAfterDecode,
            parameters: parameters,
            scenario: scenario,
            framePercent: options.framePercent,
            repetition: repetition
          )
        }
        sample.physicalFootprintBytesAfterRelease =
          processMemorySnapshot().physicalFootprintBytes
        sample.heapStatisticsAfterRelease = RawImageDecoder.defaultHeapStatistics()
        scenarioSamples[scenario.rawValue, default: []].append(sample)
        print(correctionScenarioSummary(sourceURL: sourceURL, sample: sample))
      }
    }

    let scenarioResults = CorrectionScenario.allCases.map { scenario in
      let samples = scenarioSamples[scenario.rawValue] ?? []
      return CorrectionScenarioResult(
        scenario: scenario.rawValue,
        passes: scenario.passes,
        samples: samples,
        medianProcessingSeconds: median(samples.map(\.processingSeconds)),
        p95ProcessingSeconds: percentile(
          samples.map(\.processingSeconds), fraction: 0.95),
        medianPhysicalFootprintBytesAfterProcessing: samples.isEmpty
          ? 0
          : UInt64(
            median(samples.map { Double($0.physicalFootprintBytesAfterProcessing) })),
        medianPhysicalFootprintBytesAfterRelease: samples.isEmpty
          ? 0
          : UInt64(median(samples.map { Double($0.physicalFootprintBytesAfterRelease) }))
      )
    }

    fileResults.append(
      CorrectionScenarioFileResult(
        file: sourceURL.path.replacingOccurrences(
          of: options.rawDirectory.path + "/",
          with: ""
        ),
        megapixels: megapixels,
        decoder: decoderVersion,
        repetitions: options.repetitions,
        scenarios: scenarioResults
      )
    )
  }

  let report = CorrectionScenarioReport(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    mode: "correction-scenarios",
    configuration:
      "\(buildConfiguration)-mode full-resolution RAW decode with the five documented correction scenarios",
    repetitions: options.repetitions,
    framePercent: options.framePercent,
    writerContract:
      "One LZW TIFF per scenario per repetition, matching the determinism mode's selected compression.",
    scenarioNote:
      "Scenarios are neutral, tone, protected-color, dye-mixing, and combined. One full-resolution decode is shared by all five scenarios in each repetition, so decodeSeconds and physicalFootprintBytesAfterDecode repeat across that repetition. Each scenario applies its deterministic parameter delta over the benchmark base parameters. correctedImage is the image after correction before framing; writerInputPixels is the framed writer input; both are SHA-256 of raw pixel bytes. physicalFootprintBytes and peakPhysicalFootprintBytes are Mach ledger metrics; peakPhysicalFootprintBytes is process-lifetime and therefore order-dependent. heapStatisticsAfterRelease describes default-allocator blocks after scenario intermediates and output are released.",
    cleanupPolicy:
      "Each generated export is hashed and deleted immediately after its measured run.",
    peakResidentMemoryNote:
      "ru_maxrss and Mach resident_size include reclaimable reusable pages. physicalFootprintBytes and ledger peak physical footprint are the resource-safety measures; reusableBytes explains resident memory that macOS can reclaim.",
    files: fileResults
  )
  let parentDirectory = options.outputURL.deletingLastPathComponent()
  try FileManager.default.createDirectory(
    at: parentDirectory, withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(report).write(to: options.outputURL, options: .atomic)
  print("Wrote \(options.outputURL.path)")
}

private func measureCorrectionScenario(
  destinationURL: URL,
  decoded: UInt16Image,
  decodeSeconds: Double,
  memoryAfterDecode: ProcessMemorySnapshot,
  parameters: ProcessingParameters,
  scenario: CorrectionScenario,
  framePercent: Int,
  repetition: Int
) throws -> CorrectionScenarioSample {
  defer { try? FileManager.default.removeItem(at: destinationURL) }

  let processingStart = ContinuousClock.now
  let corrected = FilmProcessing.correctedPreview(
    image: decoded,
    parameters: parameters
  )
  let processingSeconds = seconds(processingStart.duration(to: .now))
  let correctedHash = sha256Pixels(corrected.pixels)
  let memoryAfterProcessing = processMemorySnapshot()

  let geometryStart = ContinuousClock.now
  let output = corrected.addingFrame(percent: framePercent)
  let geometrySeconds = seconds(geometryStart.duration(to: .now))
  let writerInputHash = sha256Pixels(output.pixels)

  let exportParameters = ExportParameters(
    format: .tiff,
    framePercent: framePercent,
    jpegQuality: 0.95,
    tiffCompression: .lzw
  )
  let writeMetrics = try output.writeMeasured(
    to: destinationURL,
    format: .tiff,
    parameters: exportParameters
  )
  let memoryAfterWrite = processMemorySnapshot()
  let outputHash = try sha256File(destinationURL)

  try FileManager.default.removeItem(at: destinationURL)
  let removed = !FileManager.default.fileExists(atPath: destinationURL.path)
  guard removed else {
    throw CocoaError(.fileWriteUnknown)
  }
  return CorrectionScenarioSample(
    repetition: repetition,
    scenario: scenario.rawValue,
    passes: scenario.passes,
    sourceShape: [decoded.height, decoded.width, decoded.channels],
    outputShape: [output.height, output.width, output.channels],
    decodeSeconds: decodeSeconds,
    processingSeconds: processingSeconds,
    geometrySeconds: geometrySeconds,
    pixelPackingSeconds: writeMetrics.pixelPackingSeconds,
    encodingFinalizationSeconds: writeMetrics.encodingFinalizationSeconds,
    correctedImageSHA256: correctedHash,
    writerInputPixelsSHA256: writerInputHash,
    outputSHA256: outputHash,
    outputBytes: writeMetrics.outputBytes,
    physicalFootprintBytesAfterDecode: memoryAfterDecode.physicalFootprintBytes,
    physicalFootprintBytesAfterProcessing: memoryAfterProcessing.physicalFootprintBytes,
    physicalFootprintBytesAfterWrite: memoryAfterWrite.physicalFootprintBytes,
    physicalFootprintBytesAfterRelease: 0,
    peakPhysicalFootprintBytes: memoryAfterWrite.peakPhysicalFootprintBytes,
    heapStatisticsAfterRelease: nil,
    outputRemovedAfterRun: removed
  )
}

private func correctionScenarioSummary(
  sourceURL: URL,
  sample: CorrectionScenarioSample
) -> String {
  "\(sourceURL.lastPathComponent) \(sample.scenario) run \(sample.repetition): "
    + "process=\(formatted(sample.processingSeconds))s "
    + "corrected=\(sample.correctedImageSHA256.prefix(12))… "
    + "output=\(sample.outputSHA256.prefix(12))… "
    + "physicalFootprintAfterProcessing=\(sample.physicalFootprintBytesAfterProcessing) "
    + "physicalFootprintAfterRelease=\(sample.physicalFootprintBytesAfterRelease) "
    + "peakPhysicalFootprint=\(sample.peakPhysicalFootprintBytes) "
    + "removed=\(sample.outputRemovedAfterRun)"
}

private func measureDeterminismSample(
  sourceURL: URL,
  destinationURL: URL,
  processingParameters: ProcessingParameters,
  framePercent: Int,
  repetition: Int
) throws -> MeasuredDeterminismRun {
  defer { try? FileManager.default.removeItem(at: destinationURL) }

  let decodeStart = ContinuousClock.now
  let decodeResult = try RawImageDecoder.decode(
    sourceURL,
    fullResolution: true,
    profile: .rawTherapeeCameraScan,
    collectDiagnostics: true
  )
  let decodeSeconds = seconds(decodeStart.duration(to: .now))
  guard let diagnostics = decodeResult.diagnostics else {
    throw BenchmarkError.missingStageDiagnostics
  }
  let decoded = decodeResult.image

  let processingStart = ContinuousClock.now
  let processed = FilmProcessing.correctedPreview(
    image: decoded,
    parameters: processingParameters
  )
  let processingSeconds = seconds(processingStart.duration(to: .now))
  let correctedHash = sha256Pixels(processed.pixels)

  let geometryStart = ContinuousClock.now
  let output = processed.addingFrame(percent: framePercent)
  let geometrySeconds = seconds(geometryStart.duration(to: .now))
  let writerInputHash = sha256Pixels(output.pixels)

  let exportParameters = ExportParameters(
    format: .tiff,
    framePercent: framePercent,
    jpegQuality: 0.95,
    tiffCompression: .lzw
  )
  let writeMetrics = try output.writeMeasured(
    to: destinationURL,
    format: .tiff,
    parameters: exportParameters
  )
  let peakFootprint = processMemorySnapshot().peakPhysicalFootprintBytes
  let outputHash = try sha256File(destinationURL)

  try FileManager.default.removeItem(at: destinationURL)
  let removed = !FileManager.default.fileExists(atPath: destinationURL.path)
  guard removed else {
    throw CocoaError(.fileWriteUnknown)
  }

  let sample = DeterminismSample(
    repetition: repetition,
    runClass: repetition == 1 ? "first-run" : "warm-filesystem-cache",
    demosaicWorkerCount: decodeResult.demosaicWorkerCount,
    sourceShape: [decoded.height, decoded.width, decoded.channels],
    writerInputShape: [output.height, output.width, output.channels],
    decodeSeconds: decodeSeconds,
    decodeSubstages: decodeResult.timings,
    decodeUnaccountedSeconds: max(0, decodeSeconds - decodeResult.timings.totalSeconds),
    processingSeconds: processingSeconds,
    geometrySeconds: geometrySeconds,
    pixelPackingSeconds: writeMetrics.pixelPackingSeconds,
    encodingFinalizationSeconds: writeMetrics.encodingFinalizationSeconds,
    diagnostics: diagnostics,
    correctedImageSHA256: correctedHash,
    writerInputPixelsSHA256: writerInputHash,
    outputSHA256: outputHash,
    outputBytes: writeMetrics.outputBytes,
    peakPhysicalFootprintBytes: peakFootprint,
    physicalFootprintBytesAfterRelease: 0,
    outputRemovedAfterRun: removed
  )

  let summary =
    "\(sourceURL.lastPathComponent) determinism run \(repetition): "
    + "decode=\(formatted(decodeSeconds))s "
    + "[open=\(formatted(decodeResult.timings.openSeconds))s "
    + "unpack=\(formatted(decodeResult.timings.unpackSeconds))s "
    + "demosaic=\(formatted(decodeResult.timings.demosaicSeconds))s "
    + "xtransWorkers=\(decodeResult.demosaicWorkerCount) "
    + "post=\(formatted(decodeResult.timings.libRawPostprocessSeconds))s "
    + "image=\(formatted(decodeResult.timings.processedImageSeconds))s "
    + "iso=\(formatted(decodeResult.timings.isoPolicySeconds))s "
    + "copy=\(formatted(decodeResult.timings.swiftCopySwizzleSeconds))s] "
    + "unaccounted=\(formatted(max(0, decodeSeconds - decodeResult.timings.totalSeconds)))s "
    + "process=\(formatted(processingSeconds))s "
    + "write=\(formatted(writeMetrics.encodingFinalizationSeconds))s "
    + "swiftImage=\(diagnostics.swiftImageSHA256.prefix(12))… "
    + "output=\(outputHash.prefix(12))… "
    + "removed=\(removed)"
  return MeasuredDeterminismRun(
    sample: sample,
    decoderVersion: decodeResult.decoderVersion,
    megapixels: Double(decoded.width * decoded.height) / 1_000_000,
    summary: summary
  )
}

private func digestAgreement(boundary: String, digests: [String]) -> StageBoundaryAgreement {
  let distinct = Set(digests).count
  return StageBoundaryAgreement(
    boundary: boundary,
    distinctDigests: distinct,
    allAgree: distinct == 1
  )
}

private func sha256Pixels(_ pixels: [UInt16]) -> String {
  pixels.withUnsafeBytes {
    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
  }
}

private func seconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func median(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  let middle = sorted.count / 2
  if sorted.count.isMultiple(of: 2) {
    return (sorted[middle - 1] + sorted[middle]) / 2
  }
  return sorted[middle]
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
  precondition(!values.isEmpty)
  precondition((0...1).contains(fraction))
  let sorted = values.sorted()
  let index = min(Int(ceil(Double(sorted.count) * fraction)) - 1, sorted.count - 1)
  return sorted[index]
}

private func formatted(_ value: Double) -> String {
  String(format: "%.4f", value)
}

private func measureExport(
  sourceURL: URL,
  destinationURL: URL,
  processingParameters: ProcessingParameters,
  format: ExportFormat,
  framePercent: Int,
  repetition: Int
) throws -> MeasuredExportRun {
  defer { try? FileManager.default.removeItem(at: destinationURL) }

  let decodeStart = ContinuousClock.now
  let decodeResult = try RawImageDecoder.decode(
    sourceURL,
    fullResolution: true,
    profile: .rawTherapeeCameraScan
  )
  let decodeSeconds = seconds(decodeStart.duration(to: .now))
  let memoryAfterDecode = processMemorySnapshot()
  let decoded = decodeResult.image

  let processingStart = ContinuousClock.now
  let processed = FilmProcessing.correctedPreview(
    image: decoded,
    parameters: processingParameters
  )
  let processingSeconds = seconds(processingStart.duration(to: .now))
  let memoryAfterProcessing = processMemorySnapshot()

  let geometryStart = ContinuousClock.now
  let output = processed.addingFrame(percent: framePercent)
  let geometrySeconds = seconds(geometryStart.duration(to: .now))

  let exportParameters = ExportParameters(
    format: format,
    framePercent: framePercent,
    jpegQuality: 0.95,
    tiffCompression: .lzw
  )
  let writeMetrics = try output.writeMeasured(
    to: destinationURL,
    format: format,
    parameters: exportParameters
  )
  let memoryAfterWrite = processMemorySnapshot()
  let outputHash = try sha256File(destinationURL)

  try FileManager.default.removeItem(at: destinationURL)
  let removed = !FileManager.default.fileExists(atPath: destinationURL.path)
  guard removed else {
    throw CocoaError(.fileWriteUnknown)
  }

  let timings = StageTimings(
    decodeSeconds: decodeSeconds,
    processingSeconds: processingSeconds,
    geometrySeconds: geometrySeconds,
    pixelPackingSeconds: writeMetrics.pixelPackingSeconds,
    encodingFinalizationSeconds: writeMetrics.encodingFinalizationSeconds
  )
  let sample = ExportSample(
    repetition: repetition,
    runClass: repetition == 1 ? "first-run" : "warm-filesystem-cache",
    sourceShape: [decoded.height, decoded.width, decoded.channels],
    outputShape: [output.height, output.width, output.channels],
    stages: timings,
    decodeSubstages: decodeResult.timings,
    decodeUnaccountedSeconds: max(0, decodeSeconds - decodeResult.timings.totalSeconds),
    peakResidentBytes: peakResidentBytes(),
    residentBytesAfterDecode: memoryAfterDecode.residentBytes,
    residentBytesAfterProcessing: memoryAfterProcessing.residentBytes,
    residentBytesAfterWrite: memoryAfterWrite.residentBytes,
    residentBytesAfterRelease: 0,
    physicalFootprintBytesAfterDecode: memoryAfterDecode.physicalFootprintBytes,
    physicalFootprintBytesAfterProcessing: memoryAfterProcessing.physicalFootprintBytes,
    physicalFootprintBytesAfterWrite: memoryAfterWrite.physicalFootprintBytes,
    physicalFootprintBytesAfterRelease: 0,
    peakPhysicalFootprintBytes: memoryAfterWrite.peakPhysicalFootprintBytes,
    reusableBytesAfterRelease: 0,
    heapStatisticsAfterRelease: nil,
    packedPixelBytes: writeMetrics.packedPixelBytes,
    outputBytes: writeMetrics.outputBytes,
    outputSHA256: outputHash,
    outputRemovedAfterRun: removed
  )

  let summary =
    "\(sourceURL.lastPathComponent) \(format.displayName) run \(repetition): "
    + "total=\(formatted(timings.totalSeconds))s "
    + "decode=\(formatted(timings.decodeSeconds))s "
    + "[open=\(formatted(decodeResult.timings.openSeconds))s "
    + "unpack=\(formatted(decodeResult.timings.unpackSeconds))s "
    + "demosaic=\(formatted(decodeResult.timings.demosaicSeconds))s "
    + "post=\(formatted(decodeResult.timings.libRawPostprocessSeconds))s "
    + "image=\(formatted(decodeResult.timings.processedImageSeconds))s "
    + "iso=\(formatted(decodeResult.timings.isoPolicySeconds))s "
    + "copy=\(formatted(decodeResult.timings.swiftCopySwizzleSeconds))s] "
    + "process=\(formatted(timings.processingSeconds))s "
    + "packed=\(writeMetrics.packedPixelBytes)B "
    + "pack=\(formatted(timings.pixelPackingSeconds))s "
    + "write=\(formatted(timings.encodingFinalizationSeconds))s "
    + "removed=\(removed)"
  return MeasuredExportRun(
    sample: sample,
    decoderVersion: decodeResult.decoderVersion,
    megapixels: Double(decoded.width * decoded.height) / 1_000_000,
    summary: summary
  )
}

private func peakResidentBytes() -> UInt64 {
  var usage = rusage()
  guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
  return UInt64(max(0, usage.ru_maxrss))
}

private func processMemorySnapshot() -> ProcessMemorySnapshot {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  guard result == KERN_SUCCESS else {
    return ProcessMemorySnapshot(
      residentBytes: 0,
      physicalFootprintBytes: 0,
      peakPhysicalFootprintBytes: 0,
      reusableBytes: 0
    )
  }
  return ProcessMemorySnapshot(
    residentBytes: UInt64(info.resident_size),
    physicalFootprintBytes: UInt64(info.phys_footprint),
    peakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak)),
    reusableBytes: UInt64(info.reusable)
  )
}

private func sha256File(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  while true {
    let data = try handle.read(upToCount: 1_048_576) ?? Data()
    if data.isEmpty { break }
    hasher.update(data: data)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
