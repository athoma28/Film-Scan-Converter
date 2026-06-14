import CryptoKit
import FilmScanEngine
import Foundation

struct BenchmarkResult: Codable {
  let file: String
  let decoder: String
  let fullResolution: Bool
  let shape: [Int]
  let bytes: Int
  let sha256: String
  let minimum: UInt16
  let maximum: UInt16
  let channelMeansBGR: [Double]
  let blackClipPercent: Double
  let whiteClipPercent: Double
  let bestSeconds: Double
  let medianSeconds: Double
  let samplesSeconds: [Double]
}

struct BenchmarkReport: Codable {
  let generatedAt: String
  let repetitions: Int
  let fullResolution: Bool
  let results: [BenchmarkResult]
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  FileHandle.standardError.write(
    Data(
      "Usage: FilmScanRawBenchmark RAW_DIRECTORY OUTPUT_JSON [REPETITIONS] [--full-resolution]\n"
        .utf8)
  )
  exit(2)
}

let rawDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])
let repetitions = arguments.dropFirst(3).compactMap(Int.init).first ?? 3
let fullResolution = arguments.contains("--full-resolution")
let files = try FileManager.default.contentsOfDirectory(
  at: rawDirectory,
  includingPropertiesForKeys: nil
).filter { $0.pathExtension.lowercased() == "raf" }.sorted {
  $0.lastPathComponent < $1.lastPathComponent
}

guard !files.isEmpty else {
  FileHandle.standardError.write(Data("No RAF files found in \(rawDirectory.path)\n".utf8))
  exit(2)
}

var results = [BenchmarkResult]()
for file in files {
  var samples = [Double]()
  var result: RawDecodeResult?
  for _ in 0..<repetitions {
    let start = ContinuousClock.now
    result = try RawImageDecoder.decode(file, fullResolution: fullResolution)
    samples.append(seconds(start.duration(to: .now)))
  }
  let decoded = result!.image
  let metrics = metrics(for: decoded)
  let benchmark = BenchmarkResult(
    file: file.lastPathComponent,
    decoder: result!.decoderVersion,
    fullResolution: fullResolution,
    shape: [decoded.height, decoded.width, decoded.channels],
    bytes: decoded.pixels.count * MemoryLayout<UInt16>.size,
    sha256: sha256(decoded.pixels),
    minimum: metrics.minimum,
    maximum: metrics.maximum,
    channelMeansBGR: metrics.channelMeans,
    blackClipPercent: metrics.blackClipPercent,
    whiteClipPercent: metrics.whiteClipPercent,
    bestSeconds: samples.min()!,
    medianSeconds: median(samples),
    samplesSeconds: samples
  )
  results.append(benchmark)
  print(
    "\(benchmark.file): best=\(String(format: "%.4f", benchmark.bestSeconds))s "
      + "median=\(String(format: "%.4f", benchmark.medianSeconds))s \(benchmark.shape)"
  )
}

let report = BenchmarkReport(
  generatedAt: ISO8601DateFormatter().string(from: Date()),
  repetitions: repetitions,
  fullResolution: fullResolution,
  results: results
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: outputURL)

func sha256(_ pixels: [UInt16]) -> String {
  pixels.withUnsafeBytes {
    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
  }
}

func median(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  let middle = sorted.count / 2
  if sorted.count.isMultiple(of: 2) {
    return (sorted[middle - 1] + sorted[middle]) / 2
  }
  return sorted[middle]
}

func seconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

func metrics(for image: UInt16Image) -> (
  minimum: UInt16,
  maximum: UInt16,
  channelMeans: [Double],
  blackClipPercent: Double,
  whiteClipPercent: Double
) {
  var minimum = UInt16.max
  var maximum = UInt16.min
  var sums = [Double](repeating: 0, count: image.channels)
  var black = 0
  var white = 0
  for (index, pixel) in image.pixels.enumerated() {
    minimum = Swift.min(minimum, pixel)
    maximum = Swift.max(maximum, pixel)
    sums[index % image.channels] += Double(pixel)
    if pixel == 0 { black += 1 }
    if pixel == UInt16.max { white += 1 }
  }
  let pixelsPerChannel = Double(image.width * image.height)
  let componentCount = Double(image.pixels.count)
  return (
    minimum,
    maximum,
    sums.map { $0 / pixelsPerChannel },
    Double(black) / componentCount * 100,
    Double(white) / componentCount * 100
  )
}
