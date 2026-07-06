import CryptoKit
import FilmScanEngine
import Foundation

// MARK: - Corpus

let corpus: [(stem: String, filmType: FilmType, rotation: Int, scene: String)] = [
  ("DSCF0669", .blackAndWhiteNegative, 3, "black-and-white night exterior"),
  ("DSCF0718", .colourNegative, 1, "color negative outdoor daylight"),
  ("DSCF0729", .colourNegative, 1, "color negative mixed indoor lighting"),
  ("DSCF2417", .blackAndWhiteNegative, 0, "black-and-white daylight portrait"),
  ("DSCF2422", .colourNegative, 3, "color negative indoor portrait"),
]

// MARK: - Presets

func bgrChannel(_ r: Double, _ g: Double, _ b: Double) -> BGRChannelValues {
  BGRChannelValues(blue: b, green: g, red: r)
}

private struct ColorBasePreset {
  let gamma: Int
  let shadows: Int
  let highlights: Int
  let temp: Int
  let tint: Int
}

private let colorBasePresets: [String: ColorBasePreset] = [
  "DSCF0718": ColorBasePreset(
    gamma: -5, shadows: 0, highlights: -20, temp: 10, tint: 0),
  "DSCF0729": ColorBasePreset(
    gamma: 20, shadows: 30, highlights: -20, temp: 0, tint: -5),
  "DSCF2422": ColorBasePreset(
    gamma: 20, shadows: 30, highlights: 10, temp: 10, tint: -10),
]

private func presets(for stem: String, filmType: FilmType) -> [(String, ProcessingParameters)] {

  func bwPreset(name: String, gamma: Int = 0, shadows: Int = 0, highlights: Int = 0)
    -> (String, ProcessingParameters)
  {
    (
      name,
      ProcessingParameters(
        filmType: .blackAndWhiteNegative,
        gamma: gamma,
        shadows: shadows,
        highlights: highlights,
        filmNegativeParams: .blackAndWhite
      )
    )
  }

  func colorPreset(
    name: String,
    gamma: Int = 0,
    shadows: Int = 0,
    highlights: Int = 0,
    temp: Int = 0,
    tint: Int = 0
  ) -> (String, ProcessingParameters) {
    let fnp = FilmNegativeParams(enabled: true)
    return (
      name,
      ProcessingParameters(
        filmType: .colourNegative,
        gamma: gamma,
        shadows: shadows,
        highlights: highlights,
        temperature: temp,
        tint: tint,
        filmNegativeParams: fnp
      )
    )
  }

  if filmType == .blackAndWhiteNegative {
    return [
      bwPreset(name: "neutral"),
      bwPreset(name: "tonal_recovery", gamma: 12, shadows: 25, highlights: -35),
      bwPreset(name: "contrast", gamma: 2, shadows: -12, highlights: 8),
    ]
  }

  guard let base = colorBasePresets[stem] else {
    return [colorPreset(name: "film_base_only")]
  }

  return [
    colorPreset(name: "film_base_only"),
    colorPreset(name: "tuned", gamma: base.gamma, shadows: base.shadows,
                highlights: base.highlights, temp: base.temp, tint: base.tint),
    colorPreset(name: "tuned_cooler", gamma: base.gamma, shadows: base.shadows,
                highlights: base.highlights, temp: base.temp - 10, tint: base.tint),
  ]
}

// MARK: - Output models

struct SampleResult: Codable {
  let bestSeconds: Double
  let medianSeconds: Double
  let samplesSeconds: [Double]
}

struct QualityMetrics: Codable {
  let grayPercentiles: [Double]
  let blackClipPercent: Double
  let whiteClipPercent: Double
  let grayStddev: Double
  let entropyBits: Double
  let rgbMedians: [Double]
}

struct EditResult: Codable {
  let edit: String
  let settings: [String: Int]
  let coldProcess: SampleResult
  let warmProcess: SampleResult
  let quality: QualityMetrics
  let outputShape: [Int]
  let outputBytes: Int
}

struct StemResult: Codable {
  let scene: String
  let decodedShape: [Int]
  let decodedBytes: Int
  let decodeBest: Double
  let decodeMedian: Double
  let edits: [EditResult]
}

struct BenchmarkReport: Codable {
  let generatedAt: String
  let fullResolution: Bool
  let repetitions: Int
  let corpus: [[String: String]]
  let results: [String: StemResult]
}

// MARK: - Timing

private func seconds(_ duration: Duration) -> Double {
  let c = duration.components
  return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

private func median(_ values: [Double]) -> Double {
  let s = values.sorted()
  let m = s.count / 2
  return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
}

private func measure(repetitions: Int, _ block: () -> Void) -> SampleResult {
  var samples = [Double]()
  samples.reserveCapacity(repetitions)
  for _ in 0..<repetitions {
    let start = ContinuousClock.now
    block()
    samples.append(seconds(start.duration(to: .now)))
  }
  return SampleResult(
    bestSeconds: samples.min()!,
    medianSeconds: median(samples),
    samplesSeconds: samples
  )
}

// MARK: - Quality

private func computeQuality(_ image: UInt16Image) -> QualityMetrics {
  let totalPixels = image.width * image.height
  let channels = image.channels

  var blackClip = 0
  var whiteClip = 0
  var sumGray: Double = 0
  var grayValues = [Double]()
  grayValues.reserveCapacity(totalPixels)

  var rgbMedians = [Double](repeating: 0, count: channels)

  if channels == 3 {
    var rChannel = [UInt16]()
    var gChannel = [UInt16]()
    var bChannel = [UInt16]()
    rChannel.reserveCapacity(totalPixels)
    gChannel.reserveCapacity(totalPixels)
    bChannel.reserveCapacity(totalPixels)

    for i in 0..<totalPixels {
      let base = i * 3
      let b = image.pixels[base]
      let g = image.pixels[base + 1]
      let r = image.pixels[base + 2]
      bChannel.append(b)
      gChannel.append(g)
      rChannel.append(r)

      let gray = (Double(b) + Double(g) + Double(r)) / 3.0
      sumGray += gray
      grayValues.append(gray)

      if b == 0 && g == 0 && r == 0 { blackClip += 1 }
      if b == 65535 && g == 65535 && r == 65535 { whiteClip += 1 }
    }

    let sortedR = rChannel.sorted()
    let sortedG = gChannel.sorted()
    let sortedB = bChannel.sorted()
    rgbMedians = [
      sortedR.isEmpty ? 0 : Double(sortedR[sortedR.count / 2]),
      sortedG.isEmpty ? 0 : Double(sortedG[sortedG.count / 2]),
      sortedB.isEmpty ? 0 : Double(sortedB[sortedB.count / 2]),
    ]
  } else {
    for i in 0..<totalPixels {
      let v = image.pixels[i]
      sumGray += Double(v)
      grayValues.append(Double(v))
      if v == 0 { blackClip += 1 }
      if v == 65535 { whiteClip += 1 }
    }
    rgbMedians = [Double(grayValues.sorted()[grayValues.count / 2])]
  }

  let meanGray = sumGray / Double(totalPixels)
  var varianceSum: Double = 0
  for v in grayValues {
    let d = v - meanGray
    varianceSum += d * d
  }
  let grayStddev = sqrt(varianceSum / Double(totalPixels))

  let sortedGray = grayValues.sorted()
  let p1 = sortedGray[Int(Double(totalPixels) * 0.01)]
  let p5 = sortedGray[Int(Double(totalPixels) * 0.05)]
  let p50 = sortedGray[totalPixels / 2]
  let p95 = sortedGray[Int(Double(totalPixels) * 0.95)]
  let p99 = sortedGray[min(Int(Double(totalPixels) * 0.99), totalPixels - 1)]

  var histogram = [Int](repeating: 0, count: 256)
  for v in grayValues {
    let bin = min(Int(v / 256), 255)
    histogram[bin] += 1
  }
  var entropyBits: Double = 0
  for count in histogram {
    if count > 0 {
      let p = Double(count) / Double(totalPixels)
      entropyBits -= p * log2(p)
    }
  }

  return QualityMetrics(
    grayPercentiles: [p1, p5, p50, p95, p99],
    blackClipPercent: Double(blackClip) / Double(totalPixels) * 100,
    whiteClipPercent: Double(whiteClip) / Double(totalPixels) * 100,
    grayStddev: grayStddev,
    entropyBits: entropyBits,
    rgbMedians: rgbMedians
  )
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  FileHandle.standardError.write(
    Data(
      "Usage: FilmScanProcessingBenchmark RAW_DIRECTORY OUTPUT_JSON [REPETITIONS] [--full-resolution]\n"
        .utf8))
  exit(2)
}

let rawDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])
let repetitions = arguments.dropFirst(3).compactMap(Int.init).first ?? 3
let fullResolution = arguments.contains("--full-resolution")

let rafFiles = try FileManager.default.contentsOfDirectory(
  at: rawDirectory,
  includingPropertiesForKeys: nil
).filter { $0.pathExtension.lowercased() == "raf" }

guard !rafFiles.isEmpty else {
  FileHandle.standardError.write(Data("No RAF files found in \(rawDirectory.path)\n".utf8))
  exit(2)
}

let rafMap = Dictionary(uniqueKeysWithValues: rafFiles.map { ($0.deletingPathExtension().lastPathComponent, $0) })

var reportResults = [String: StemResult]()
let corpusJSON: [[String: String]] = corpus.map {
  ["stem": $0.stem, "scene": $0.scene, "rotation": String($0.rotation)]
}

for entry in corpus {
  guard let fileURL = rafMap[entry.stem] else {
    print("\(entry.stem): RAF not found in \(rawDirectory.path), skipping")
    continue
  }

  // --- Decode ---
  var decodeSamples = [Double]()
  var decoded: UInt16Image?
  for _ in 0..<repetitions {
    let start = ContinuousClock.now
    let result = try RawImageDecoder.decode(fileURL, fullResolution: fullResolution)
    decodeSamples.append(seconds(start.duration(to: .now)))
    decoded = result.image
  }

  guard let image = decoded else {
    print("\(entry.stem): decode failed, skipping")
    continue
  }

  let decodeBest = decodeSamples.min()!
  let decodeMedian = median(decodeSamples)

  print(
    "\(entry.stem): decode best=\(String(format: "%.4f", decodeBest))s "
      + "median=\(String(format: "%.4f", decodeMedian))s "
      + "[\(image.height)x\(image.width)x\(image.channels)]"
  )

  // --- Process each edit ---
  var editResults = [EditResult]()
  for (editName, params) in presets(for: entry.stem, filmType: entry.filmType) {
    var p = params
    p.rotation = entry.rotation

    let settings: [String: Int] = [
      "gamma": p.gamma, "shadows": p.shadows, "highlights": p.highlights,
      "temp": p.temperature, "tint": p.tint,
    ]

    // Cold: measure correctedPreview (fires independent of decode caching)
    let cold = measure(repetitions: repetitions) {
      _ = FilmProcessing.correctedPreview(image: image, parameters: p)
    }

    // Warm: same thing repeated (CPU caches hot)
    let warm = measure(repetitions: repetitions) {
      _ = FilmProcessing.correctedPreview(image: image, parameters: p)
    }

    // Quality (use last output)
    let output = FilmProcessing.correctedPreview(image: image, parameters: p)
    let quality = computeQuality(output)

    editResults.append(
      EditResult(
        edit: editName,
        settings: settings,
        coldProcess: cold,
        warmProcess: warm,
        quality: quality,
        outputShape: [output.height, output.width, output.channels],
        outputBytes: output.pixels.count * MemoryLayout<UInt16>.size
      )
    )

    print(
      "  \(editName): cold=\(String(format: "%.4f", cold.bestSeconds))s "
        + "warm=\(String(format: "%.4f", warm.bestSeconds))s "
        + "entropy=\(String(format: "%.3f", quality.entropyBits)) bits"
    )
  }

  reportResults[entry.stem] = StemResult(
    scene: entry.scene,
    decodedShape: [image.height, image.width, image.channels],
    decodedBytes: image.pixels.count * MemoryLayout<UInt16>.size,
    decodeBest: decodeBest,
    decodeMedian: decodeMedian,
    edits: editResults
  )
}

let report = BenchmarkReport(
  generatedAt: ISO8601DateFormatter().string(from: Date()),
  fullResolution: fullResolution,
  repetitions: repetitions,
  corpus: corpusJSON,
  results: reportResults
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: outputURL)
print("Wrote \(outputURL.path)")
