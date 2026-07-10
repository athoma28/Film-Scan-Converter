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
}

private let usage = """
  Usage: FilmScanExportBenchmark RAW_DIRECTORY OUTPUT_JSON [REPETITIONS]
           [--formats=tiff,jpeg,png,dng] [--frame-percent=N]
           [--file=NAME.raf | --all] [--limit=N]

  The default run benchmarks the first RAF in lexical order in all formats.
  Every generated image is hashed and deleted immediately after its run; only
  the compact JSON report remains.
  """

private func parseOptions() -> Options? {
  let arguments = CommandLine.arguments
  guard arguments.count >= 3 else { return nil }

  let extras = Array(arguments.dropFirst(3))
  let repetitions = extras.compactMap { Int($0) }.first ?? 3
  guard repetitions > 0 else { return nil }

  var formats = ExportFormat.allCases
  var framePercent = 0
  var allFiles = false
  var selectedFilename: String?
  var fileLimit: Int?

  for argument in extras {
    if argument == "--all" {
      allFiles = true
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
    } else if argument.hasPrefix("--limit=") {
      guard let value = Int(argument.dropFirst("--limit=".count)), value > 0 else {
        return nil
      }
      fileLimit = value
    } else if Int(argument) == nil {
      return nil
    }
  }

  guard !(allFiles && selectedFilename != nil) else { return nil }
  return Options(
    rawDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
    outputURL: URL(fileURLWithPath: arguments[2]),
    repetitions: repetitions,
    formats: formats,
    framePercent: framePercent,
    allFiles: allFiles,
    selectedFilename: selectedFilename,
    fileLimit: fileLimit
  )
}

guard let options = parseOptions() else {
  FileHandle.standardError.write(Data((usage + "\n").utf8))
  exit(2)
}

let availableFiles = try FileManager.default.contentsOfDirectory(
  at: options.rawDirectory,
  includingPropertiesForKeys: nil
).filter { $0.pathExtension.lowercased() == "raf" }.sorted {
  $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
}

let selectedFiles: [URL]
if let selectedFilename = options.selectedFilename {
  selectedFiles = availableFiles.filter { $0.lastPathComponent == selectedFilename }
} else if options.allFiles {
  selectedFiles = availableFiles
} else {
  selectedFiles = Array(availableFiles.prefix(1))
}
let files = options.fileLimit.map { Array(selectedFiles.prefix($0)) } ?? selectedFiles

guard !files.isEmpty else {
  FileHandle.standardError.write(Data("No matching RAF files found.\n".utf8))
  exit(2)
}

let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
  "FilmScanExportBenchmark-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(
  at: scratchDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratchDirectory) }

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
        "\(sourceURL.deletingPathExtension().lastPathComponent)-\(format.rawValue)-\(repetition).\(format.fileExtension)")
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
          pixelPackingSeconds: percentile(samples.map(\.stages.pixelPackingSeconds), fraction: 0.95),
          encodingFinalizationSeconds: percentile(
            samples.map(\.stages.encodingFinalizationSeconds), fraction: 0.95)
        ),
        p95DecodeSubstages: RawDecodeTimings(
          openSeconds: percentile(samples.map(\.decodeSubstages.openSeconds), fraction: 0.95),
          unpackSeconds: percentile(samples.map(\.decodeSubstages.unpackSeconds), fraction: 0.95),
          demosaicSeconds: percentile(samples.map(\.decodeSubstages.demosaicSeconds), fraction: 0.95),
          libRawPostprocessSeconds: percentile(
            samples.map(\.decodeSubstages.libRawPostprocessSeconds), fraction: 0.95),
          processedImageSeconds: percentile(samples.map(\.decodeSubstages.processedImageSeconds), fraction: 0.95),
          isoPolicySeconds: percentile(samples.map(\.decodeSubstages.isoPolicySeconds), fraction: 0.95),
          swiftCopySwizzleSeconds: percentile(
            samples.map(\.decodeSubstages.swiftCopySwizzleSeconds), fraction: 0.95)
        )
      )
    )
  }

  fileResults.append(
    FileResult(
      file: sourceURL.lastPathComponent,
      megapixels: megapixels,
      decoder: decoderVersion,
      formats: formatResults
    )
  )
}

let report = BenchmarkReport(
  generatedAt: ISO8601DateFormatter().string(from: Date()),
  configuration: "release-mode full-resolution RAW decode and production export path",
  repetitions: options.repetitions,
  framePercent: options.framePercent,
  cleanupPolicy: "Each generated export is hashed and deleted immediately after its measured run.",
  peakResidentMemoryNote: "ru_maxrss and Mach resident_size include reclaimable reusable pages. physicalFootprintBytes and ledger peak physical footprint are the resource-safety measures; reusableBytes explains resident memory that macOS can reclaim.",
  files: fileResults
)
let parentDirectory = options.outputURL.deletingLastPathComponent()
try FileManager.default.createDirectory(
  at: parentDirectory, withIntermediateDirectories: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: options.outputURL, options: .atomic)
print("Wrote \(options.outputURL.path)")

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
