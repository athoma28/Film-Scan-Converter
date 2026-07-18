import FilmScanEngine
import Foundation

private let usage = """
  Usage: FilmScanReferenceCalibrator SAMPLE_RAW_ROOT REPORT_JSON [--stride=N]

  Recursively discovers RAF/JPEG/XMP triplets, aligns Adobe's exported crop to
  the app-facing half-resolution camera-scan decode, and fits monotone generic
  and per-stock negative curves. JPEGs whose names contain "cnegprofile" are
  treated as FSC outputs and are never selected as Camera Raw targets.
  """

private struct XMPSettings {
  let cropTop: Double
  let cropLeft: Double
  let cropBottom: Double
  let cropRight: Double
  let exposure: Double
  let monochrome: Bool
}

private struct ReferenceTriplet {
  let stockID: String
  let stem: String
  let rawURL: URL
  let targetURL: URL
  let xmpURL: URL
  let xmp: XMPSettings
}

private struct PixelPair {
  let rawB: UInt16
  let rawG: UInt16
  let rawR: UInt16
  let targetB: UInt16
  let targetG: UInt16
  let targetR: UInt16
}

private struct ReferenceFrame {
  let stockID: String
  let stem: String
  let monochrome: Bool
  let xmpExposure: Double
  let medians: BGRChannelValues
  let pairs: [PixelPair]
  let currentMAE: Double
  let legacyMAE: Double
}

private struct CurveCandidate {
  let referenceMedians: BGRChannelValues
  let exposureNormalization: Double
  let colorNormalization: Double
  let curves: [[Double]]
}

private struct FrameScore: Codable {
  let stockID: String
  let stem: String
  let xmpExposure: Double
  let currentMAE: Double
  let legacyMAE: Double
  let candidateMAE: Double
  let leaveOneOutMAE: Double
}

private struct CandidateReport: Codable {
  let frameCount: Int
  let referenceMediansBGR: [Double]
  let exposureNormalization: Double
  let colorNormalization: Double
  let curvesBGR: [[Double]]
  let currentMeanAbsoluteError: Double
  let legacyMeanAbsoluteError: Double
  let fittedMeanAbsoluteError: Double
  let leaveOneOutMeanAbsoluteError: Double
  let frames: [FrameScore]
}

private struct CalibrationReport: Codable {
  let schemaVersion: Int
  let generatedAt: String
  let sampleRoot: String
  let decodeProfile: String
  let stride: Int
  let discoveredTriplets: Int
  let genericColor: CandidateReport?
  let genericMonochrome: CandidateReport?
  let stockProfiles: [String: CandidateReport]
}

private struct Options {
  let root: URL
  let output: URL
  let stride: Int
}

private func parseOptions() -> Options? {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count >= 2 else { return nil }
  var stride = 16
  for argument in arguments.dropFirst(2) {
    guard argument.hasPrefix("--stride="),
      let value = Int(argument.dropFirst("--stride=".count)),
      value > 0
    else { return nil }
    stride = value
  }
  return Options(
    root: URL(fileURLWithPath: arguments[0], isDirectory: true),
    output: URL(fileURLWithPath: arguments[1]),
    stride: stride
  )
}

guard let options = parseOptions() else {
  FileHandle.standardError.write(Data((usage + "\n").utf8))
  exit(2)
}

private func run(options: Options) throws {
  let triplets = try discoverTriplets(under: options.root)
  guard !triplets.isEmpty else {
    FileHandle.standardError.write(Data("No RAF/JPEG/XMP triplets found.\n".utf8))
    exit(2)
  }

  var frames: [ReferenceFrame] = []
  for (index, triplet) in triplets.enumerated() {
    print("[\(index + 1)/\(triplets.count)] \(triplet.stockID)/\(triplet.stem)")
    frames.append(try loadFrame(triplet, stride: options.stride))
  }

  let colorFrames = frames.filter { !$0.monochrome }
  let monochromeFrames = frames.filter(\.monochrome)
  let genericColor = colorFrames.count >= 3
    ? calibrate(colorFrames, monochrome: false)
    : nil
  let genericMonochrome = monochromeFrames.count >= 3
    ? calibrate(monochromeFrames, monochrome: true)
    : nil

  var stockProfiles: [String: CandidateReport] = [:]
  for (stockID, stockFrames) in Dictionary(grouping: frames, by: \.stockID) {
    guard stockFrames.count >= 3 else { continue }
    let modes = Set(stockFrames.map(\.monochrome))
    guard modes.count == 1 else { continue }
    stockProfiles[stockID] = calibrate(
      stockFrames,
      monochrome: modes.first == true
    )
  }

  let report = CalibrationReport(
    schemaVersion: 2,
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    sampleRoot: options.root.path,
    decodeProfile: "rawTherapeeCameraScan half-resolution",
    stride: options.stride,
    discoveredTriplets: triplets.count,
    genericColor: genericColor,
    genericMonochrome: genericMonochrome,
    stockProfiles: stockProfiles
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try FileManager.default.createDirectory(
    at: options.output.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try encoder.encode(report).write(to: options.output, options: .atomic)
  print("Wrote \(options.output.path)")
}

try run(options: options)

private func discoverTriplets(under root: URL) throws -> [ReferenceTriplet] {
  let files = try RecursiveFileDiscovery.files(
    under: root,
    extensions: ["raf", "xmp", "jpg", "jpeg"]
  )
  let grouped = Dictionary(grouping: files) { $0.deletingLastPathComponent() }
  var result: [ReferenceTriplet] = []
  for (directory, directoryFiles) in grouped {
    for rawURL in directoryFiles where rawURL.pathExtension.lowercased() == "raf" {
      let stem = rawURL.deletingPathExtension().lastPathComponent
      guard
        let xmpURL = directoryFiles.first(where: {
          $0.pathExtension.lowercased() == "xmp"
            && $0.deletingPathExtension().lastPathComponent
              .caseInsensitiveCompare(stem) == .orderedSame
        }),
        let targetURL = preferredTarget(stem: stem, files: directoryFiles)
      else { continue }
      let xmpText = try String(contentsOf: xmpURL, encoding: .utf8)
      let relativeDirectory = directory == root
        ? root.lastPathComponent
        : directory.path.replacingOccurrences(of: root.path + "/", with: "")
      result.append(
        ReferenceTriplet(
          stockID: relativeDirectory,
          stem: stem,
          rawURL: rawURL,
          targetURL: targetURL,
          xmpURL: xmpURL,
          xmp: parseXMP(xmpText)
        )
      )
    }
  }
  return result.sorted { ($0.stockID, $0.stem) < ($1.stockID, $1.stem) }
}

private func preferredTarget(stem: String, files: [URL]) -> URL? {
  let lowerStem = stem.lowercased()
  let candidates = files.filter {
    let name = $0.deletingPathExtension().lastPathComponent.lowercased()
    return ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
      && (name == lowerStem || name.hasPrefix(lowerStem + "-")
        || name.hasPrefix(lowerStem + "_"))
      && !$0.lastPathComponent.lowercased().contains("cnegprofile")
  }
  func rank(_ url: URL) -> Int {
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
    if name == lowerStem { return 0 }
    if name == lowerStem + "-adobe" { return 1 }
    return 2
  }
  return candidates.sorted {
    let lhs = rank($0)
    let rhs = rank($1)
    return lhs == rhs ? $0.lastPathComponent < $1.lastPathComponent : lhs < rhs
  }.first
}

private func parseXMP(_ text: String) -> XMPSettings {
  func value(_ name: String, fallback: Double) -> Double {
    let marker = "crs:\(name)=\""
    guard let start = text.range(of: marker)?.upperBound,
      let end = text[start...].firstIndex(of: "\"")
    else { return fallback }
    return Double(text[start..<end]) ?? fallback
  }
  return XMPSettings(
    cropTop: value("CropTop", fallback: 0),
    cropLeft: value("CropLeft", fallback: 0),
    cropBottom: value("CropBottom", fallback: 1),
    cropRight: value("CropRight", fallback: 1),
    exposure: value("Exposure2012", fallback: 0),
    monochrome: text.contains("ConvertToGrayscale=\"True\"")
  )
}

private func loadFrame(_ triplet: ReferenceTriplet, stride: Int) throws -> ReferenceFrame {
  let decoded = try RawImageDecoder.decode(
    triplet.rawURL,
    profile: .rawTherapeeCameraScan
  ).image
  let fullRaw = try RawImageDecoder.fullResolutionDimensions(triplet.rawURL)
  let targetFull = try StandardImageDecoder.fullResolutionDimensions(triplet.targetURL)
  let scaleX = Double(decoded.width) / Double(fullRaw.width)
  let scaleY = Double(decoded.height) / Double(fullRaw.height)
  let targetMaxDimension = max(
    1,
    Int(
      round(
        max(
          Double(targetFull.width) * scaleX,
          Double(targetFull.height) * scaleY
        )
      )
    )
  )
  let target = try StandardImageDecoder.decodePreview(
    triplet.targetURL,
    maxDimension: targetMaxDimension
  )

  let cropWidth = max(triplet.xmp.cropRight - triplet.xmp.cropLeft, 1e-6)
  let cropHeight = max(triplet.xmp.cropBottom - triplet.xmp.cropTop, 1e-6)
  let adobeActiveWidth = Double(targetFull.width) / cropWidth
  let adobeActiveHeight = Double(targetFull.height) / cropHeight
  let activeOriginX = (Double(fullRaw.width) - adobeActiveWidth) / 2
  let activeOriginY = (Double(fullRaw.height) - adobeActiveHeight) / 2
  let originX = Int(
    round(
      (activeOriginX + triplet.xmp.cropLeft * adobeActiveWidth) * scaleX
    )
  )
  let originY = Int(
    round(
      (activeOriginY + triplet.xmp.cropTop * adobeActiveHeight) * scaleY
    )
  )
  guard originX >= 0, originY >= 0,
    originX + target.width <= decoded.width,
    originY + target.height <= decoded.height
  else {
    throw NSError(
      domain: "FilmScanReferenceCalibrator",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Aligned target \(target.width)x\(target.height) at \(originX),\(originY) exceeds RAW \(decoded.width)x\(decoded.height) for \(triplet.stem)"
      ]
    )
  }

  let medians = FilmNegativeProcessing.computeMedians(image: decoded, borderPercent: 20)
  var currentParams = triplet.xmp.monochrome
    ? FilmNegativeParams.blackAndWhite
    : FilmNegativeParams.colourNegative
  currentParams.measuredMedians = medians
  let filmType: FilmType = triplet.xmp.monochrome
    ? .blackAndWhiteNegative
    : .colourNegative
  let current = FilmProcessing.correctedPreview(
    image: decoded,
    parameters: ProcessingParameters(
      filmType: filmType,
      filmNegativeParams: currentParams
    )
  )
  var legacyParams = triplet.xmp.monochrome
    ? FilmNegativeParams.legacyBlackAndWhite
    : FilmNegativeParams.legacyColourNegative
  legacyParams.measuredMedians = medians
  let legacy = FilmProcessing.correctedPreview(
    image: decoded,
    parameters: ProcessingParameters(
      filmType: filmType,
      filmNegativeParams: legacyParams
    )
  )

  var pairs: [PixelPair] = []
  pairs.reserveCapacity((target.width / stride + 1) * (target.height / stride + 1))
  var currentError = 0.0
  var legacyError = 0.0
  var componentCount = 0
  for y in Swift.stride(from: 0, to: target.height, by: stride) {
    for x in Swift.stride(from: 0, to: target.width, by: stride) {
      let rawBase = ((originY + y) * decoded.width + originX + x) * 3
      let targetBase = (y * target.width + x) * target.channels
      let targetB = target.pixels[targetBase]
      let targetG = target.channels == 1 ? targetB : target.pixels[targetBase + 1]
      let targetR = target.channels == 1 ? targetB : target.pixels[targetBase + 2]
      let pair = PixelPair(
        rawB: decoded.pixels[rawBase],
        rawG: decoded.pixels[rawBase + 1],
        rawR: decoded.pixels[rawBase + 2],
        targetB: targetB,
        targetG: targetG,
        targetR: targetR
      )
      pairs.append(pair)
      let targetChannels = [targetB, targetG, targetR]
      let currentBase = ((originY + y) * current.width + originX + x) * current.channels
      let legacyBase = ((originY + y) * legacy.width + originX + x) * legacy.channels
      for channel in 0..<3 {
        let currentValue = current.pixels[
          currentBase + (current.channels == 1 ? 0 : channel)
        ]
        let legacyValue = legacy.pixels[
          legacyBase + (legacy.channels == 1 ? 0 : channel)
        ]
        currentError += abs(
          Double(currentValue) - Double(targetChannels[channel])
        ) / 65_535
        legacyError += abs(
          Double(legacyValue) - Double(targetChannels[channel])
        ) / 65_535
        componentCount += 1
      }
    }
  }
  return ReferenceFrame(
    stockID: triplet.stockID,
    stem: triplet.stem,
    monochrome: triplet.xmp.monochrome,
    xmpExposure: triplet.xmp.exposure,
    medians: medians,
    pairs: pairs,
    currentMAE: currentError / Double(componentCount),
    legacyMAE: legacyError / Double(componentCount)
  )
}

private func calibrate(_ frames: [ReferenceFrame], monochrome: Bool) -> CandidateReport {
  let exposureGrid = [0.0, 0.25, 0.5, 0.75, 1.0]
  let colorGrid = monochrome ? [0.0] : [0.0, 0.25, 0.5, 0.75, 1.0]
  var bestStrengths = (exposure: 0.0, color: 0.0)
  var bestHeldOutError = Double.greatestFiniteMagnitude

  for exposure in exposureGrid {
    for color in colorGrid {
      var totalError = 0.0
      var totalComponents = 0
      for heldOutIndex in frames.indices {
        let training = frames.indices.filter { $0 != heldOutIndex }.map { frames[$0] }
        guard !training.isEmpty else { continue }
        let candidate = fitCandidate(
          training,
          monochrome: monochrome,
          exposureNormalization: exposure,
          colorNormalization: color
        )
        let score = score(frame: frames[heldOutIndex], candidate: candidate, monochrome: monochrome)
        totalError += score.errorSum
        totalComponents += score.componentCount
      }
      let error = totalError / Double(max(totalComponents, 1))
      if error < bestHeldOutError {
        bestHeldOutError = error
        bestStrengths = (exposure, color)
      }
    }
  }

  let candidate = fitCandidate(
    frames,
    monochrome: monochrome,
    exposureNormalization: bestStrengths.exposure,
    colorNormalization: bestStrengths.color
  )
  let leaveOneOutScores = frames.indices.map { heldOutIndex -> Double in
    let training = frames.indices.filter { $0 != heldOutIndex }.map { frames[$0] }
    guard !training.isEmpty else { return .nan }
    let heldOutCandidate = fitCandidate(
      training,
      monochrome: monochrome,
      exposureNormalization: bestStrengths.exposure,
      colorNormalization: bestStrengths.color
    )
    let scored = score(
      frame: frames[heldOutIndex],
      candidate: heldOutCandidate,
      monochrome: monochrome
    )
    return scored.errorSum / Double(scored.componentCount)
  }
  var frameScores: [FrameScore] = []
  var fittedError = 0.0
  var fittedComponents = 0
  for (frameIndex, frame) in frames.enumerated() {
    let scored = score(frame: frame, candidate: candidate, monochrome: monochrome)
    fittedError += scored.errorSum
    fittedComponents += scored.componentCount
    frameScores.append(
      FrameScore(
        stockID: frame.stockID,
        stem: frame.stem,
        xmpExposure: frame.xmpExposure,
        currentMAE: frame.currentMAE,
        legacyMAE: frame.legacyMAE,
        candidateMAE: scored.errorSum / Double(scored.componentCount),
        leaveOneOutMAE: leaveOneOutScores[frameIndex]
      )
    )
  }
  let count = Double(frames.count)
  return CandidateReport(
    frameCount: frames.count,
    referenceMediansBGR: [
      candidate.referenceMedians.blue,
      candidate.referenceMedians.green,
      candidate.referenceMedians.red,
    ],
    exposureNormalization: candidate.exposureNormalization,
    colorNormalization: candidate.colorNormalization,
    curvesBGR: candidate.curves,
    currentMeanAbsoluteError: frames.map(\.currentMAE).reduce(0, +) / count,
    legacyMeanAbsoluteError: frames.map(\.legacyMAE).reduce(0, +) / count,
    fittedMeanAbsoluteError: fittedError / Double(fittedComponents),
    leaveOneOutMeanAbsoluteError: bestHeldOutError,
    frames: frameScores
  )
}

private func fitCandidate(
  _ frames: [ReferenceFrame],
  monochrome: Bool,
  exposureNormalization: Double,
  colorNormalization: Double
) -> CurveCandidate {
  let reference = BGRChannelValues(
    blue: median(frames.map { $0.medians.blue }),
    green: median(frames.map { $0.medians.green }),
    red: median(frames.map { $0.medians.red })
  )
  let knotCount = 11
  let channelCount = monochrome ? 1 : 3
  var sums = Array(
    repeating: Array(repeating: 0.0, count: knotCount),
    count: channelCount
  )
  var weights = Array(
    repeating: Array(repeating: 0.0, count: knotCount),
    count: channelCount
  )

  for frame in frames {
    let gains = normalizationGains(
      medians: frame.medians,
      reference: reference,
      exposureStrength: exposureNormalization,
      colorStrength: colorNormalization
    )
    for pair in frame.pairs {
      if monochrome {
        let raw = (
          0.114 * Double(pair.rawB)
            + 0.587 * Double(pair.rawG)
            + 0.299 * Double(pair.rawR)
        ) / 65_535 * gains.green
        let target = (
          0.114 * Double(pair.targetB)
            + 0.587 * Double(pair.targetG)
            + 0.299 * Double(pair.targetR)
        ) / 65_535
        accumulate(
          input: raw,
          output: target,
          sums: &sums[0],
          weights: &weights[0]
        )
      } else {
        let raw = [pair.rawB, pair.rawG, pair.rawR]
        let target = [pair.targetB, pair.targetG, pair.targetR]
        let channelGains = [gains.blue, gains.green, gains.red]
        for channel in 0..<3 {
          accumulate(
            input: Double(raw[channel]) / 65_535 * channelGains[channel],
            output: Double(target[channel]) / 65_535,
            sums: &sums[channel],
            weights: &weights[channel]
          )
        }
      }
    }
  }

  var curves: [[Double]] = []
  for channel in 0..<channelCount {
    var values = zip(sums[channel], weights[channel]).map { sum, weight in
      weight > 0 ? sum / weight : Double.nan
    }
    fillMissing(&values)
    values = monotoneDecreasing(values, weights: weights[channel])
    curves.append(values.map { min(max($0, 0), 1) })
  }
  if monochrome {
    curves = [curves[0], curves[0], curves[0]]
  }
  return CurveCandidate(
    referenceMedians: reference,
    exposureNormalization: exposureNormalization,
    colorNormalization: colorNormalization,
    curves: curves
  )
}

private func accumulate(
  input: Double,
  output: Double,
  sums: inout [Double],
  weights: inout [Double]
) {
  let position = min(max(input, 0), 1) * Double(sums.count - 1)
  let lower = min(Int(position), sums.count - 1)
  let upper = min(lower + 1, sums.count - 1)
  let fraction = position - Double(lower)
  let lowerWeight = 1 - fraction
  sums[lower] += output * lowerWeight
  weights[lower] += lowerWeight
  if upper != lower {
    sums[upper] += output * fraction
    weights[upper] += fraction
  }
}

private func fillMissing(_ values: inout [Double]) {
  let populated = values.indices.filter { values[$0].isFinite }
  guard let first = populated.first, let last = populated.last else {
    values = (0..<values.count).map { 1 - Double($0) / Double(values.count - 1) }
    return
  }
  for index in 0..<first { values[index] = values[first] }
  for index in (last + 1)..<values.count { values[index] = values[last] }
  for index in populated.dropLast() {
    guard let next = populated.first(where: { $0 > index }) else { continue }
    guard next > index + 1 else { continue }
    for missing in (index + 1)..<next {
      let fraction = Double(missing - index) / Double(next - index)
      values[missing] = values[index] + (values[next] - values[index]) * fraction
    }
  }
}

private func monotoneDecreasing(_ values: [Double], weights: [Double]) -> [Double] {
  struct Block {
    var start: Int
    var end: Int
    var weight: Double
    var value: Double
  }
  var blocks: [Block] = []
  for index in values.indices {
    let weight = max(weights[index], 1)
    blocks.append(Block(start: index, end: index, weight: weight, value: values[index]))
    while blocks.count >= 2,
      blocks[blocks.count - 2].value < blocks[blocks.count - 1].value
    {
      let right = blocks.removeLast()
      let left = blocks.removeLast()
      let combinedWeight = left.weight + right.weight
      blocks.append(
        Block(
          start: left.start,
          end: right.end,
          weight: combinedWeight,
          value: (left.value * left.weight + right.value * right.weight) / combinedWeight
        )
      )
    }
  }
  var result = values
  for block in blocks {
    for index in block.start...block.end { result[index] = block.value }
  }
  return result
}

private func normalizationGains(
  medians: BGRChannelValues,
  reference: BGRChannelValues,
  exposureStrength: Double,
  colorStrength: Double
) -> BGRChannelValues {
  let exposure = pow(
    max(reference.green, 1) / max(medians.green, 1),
    exposureStrength
  )
  func channelGain(frame: Double, referenceChannel: Double) -> Double {
    let frameRatio = max(frame, 1) / max(medians.green, 1)
    let referenceRatio = max(referenceChannel, 1) / max(reference.green, 1)
    return exposure * pow(referenceRatio / frameRatio, colorStrength)
  }
  return BGRChannelValues(
    blue: channelGain(frame: medians.blue, referenceChannel: reference.blue),
    green: exposure,
    red: channelGain(frame: medians.red, referenceChannel: reference.red)
  )
}

private func score(
  frame: ReferenceFrame,
  candidate: CurveCandidate,
  monochrome: Bool
) -> (errorSum: Double, componentCount: Int) {
  let gains = normalizationGains(
    medians: frame.medians,
    reference: candidate.referenceMedians,
    exposureStrength: candidate.exposureNormalization,
    colorStrength: candidate.colorNormalization
  )
  var error = 0.0
  var count = 0
  for pair in frame.pairs {
    if monochrome {
      let rawGray = (
        0.114 * Double(pair.rawB)
          + 0.587 * Double(pair.rawG)
          + 0.299 * Double(pair.rawR)
      ) / 65_535 * gains.green
      let predicted = curveValue(candidate.curves[0], input: rawGray)
      let target = (
        0.114 * Double(pair.targetB)
          + 0.587 * Double(pair.targetG)
          + 0.299 * Double(pair.targetR)
      ) / 65_535
      error += abs(predicted - target)
      count += 1
    } else {
      let raw = [pair.rawB, pair.rawG, pair.rawR]
      let target = [pair.targetB, pair.targetG, pair.targetR]
      let channelGains = [gains.blue, gains.green, gains.red]
      for channel in 0..<3 {
        let predicted = curveValue(
          candidate.curves[channel],
          input: Double(raw[channel]) / 65_535 * channelGains[channel]
        )
        error += abs(predicted - Double(target[channel]) / 65_535)
        count += 1
      }
    }
  }
  return (error, count)
}

private func curveValue(_ curve: [Double], input: Double) -> Double {
  let position = min(max(input, 0), 1) * Double(curve.count - 1)
  let lower = min(Int(position), curve.count - 2)
  let fraction = position - Double(lower)
  return curve[lower] + (curve[lower + 1] - curve[lower]) * fraction
}

private func median(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  let middle = sorted.count / 2
  return sorted.count.isMultiple(of: 2)
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle]
}
