// Bounded research experiments, not changes to the app's rendering defaults.
import Dispatch
import FilmScanEngine
import Foundation

@main
enum ResearchPassTwoProbe {
  static let maximum = 65_535.0
  static let candidateKnots = [
    0.989069, 0.912663, 0.668040, 0.603132, 0.488223, 0.330530,
    0.157710, 0.13518075, 0.11265150, 0.09012225, 0.067593,
  ]

  static func candidate(_ input: Double, gain: Double = 1) -> Double {
    let position = min(max(input * gain, 0), 1) * 10
    let lower = min(Int(position), 9)
    return candidateKnots[lower]
      + (candidateKnots[lower + 1] - candidateKnots[lower]) * (position - Double(lower))
  }

  static func code(_ value: Double) -> Int {
    Int((min(max(value, 0), 1) * maximum).rounded())
  }

  static func elapsedMS(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }

  static func grayRamp() -> UInt16Image {
    UInt16Image(
      width: 256, height: 256, channels: 3,
      pixels: (0...65_535).flatMap { [UInt16](repeating: UInt16($0), count: 3) })
  }

  static func curveProbe() -> [String: Any] {
    let interval = 45_875...58_981
    let outputs = interval.map { code(candidate(Double($0) / maximum)) }
    let output8 = interval.map { Int((candidate(Double($0) / maximum) * 255).rounded()) }
    let maximumChange = (0...65_535).map { index in
      let input = Double(index) / maximum
      return abs(candidate(input) - FilmNegativeProcessing.calibratedMonochromeToneCurve(input))
    }.max()!
    let medians = BGRChannelValues(blue: 20_000, green: 20_000, red: 20_000)
    let gain = FilmNegativeProcessing.calibratedMonochromeInputGain(measuredMedians: medians)
    let samples = [0.72, 0.76, 0.80, 0.84, 0.88]
    return [
      "kind": "Analytical candidate only; app profile unchanged",
      "inputCodeRange16": [interval.lowerBound, interval.upperBound],
      "distinctInputCodes": interval.count,
      "distinctCandidateOutputCodes16": Set(outputs).count,
      "candidateOutputRange16": [outputs.min()!, outputs.max()!],
      "distinctCandidateOutputCodes8": Set(output8).count,
      "maximumChangeOnFullRampIn8BitCodeUnits": maximumChange * 255,
      "edgeInputSamples": samples,
      "edgeCandidateCodes16Gain1": samples.map { code(candidate($0)) },
      "edgeCandidateCodes16Median20000": samples.map { code(candidate($0, gain: gain)) },
      "gainForMedian20000": gain,
      "resampling": [
        "sourcePair": [0.6, 0.9],
        "invertThenAverageEncoded":
          (FilmNegativeProcessing.calibratedMonochromeToneCurve(0.6)
          + FilmNegativeProcessing.calibratedMonochromeToneCurve(0.9)) / 2,
        "averageEncodedThenInvert": FilmNegativeProcessing.calibratedMonochromeToneCurve(0.75),
      ],
    ]
  }

  static func precisionProbe() throws -> [String: Any] {
    let input = grayRamp()
    let alignment = ScanStackAlignment(
      translationX: 0, translationY: 0, confidence: 1, overlap: 1)
    let current = try StackAnalysis.merge(
      images: [input, input, input], alignments: [alignment, alignment, alignment],
      exposureOffsetsEV: [0, 0, 0], mode: .noiseReduction)
    let linearValues = (0...65_535).map {
      FilmNegativeProcessing.sRGBToLinear(Double($0) / maximum)
    }
    let intervals = 4096
    let table = (0...intervals).map {
      FilmNegativeProcessing.linearToSRGB(Double($0) / Double(intervals))
    }
    func interpolated(_ linear: Double) -> Double {
      let position = linear * Double(intervals)
      let lower = min(Int(position), intervals - 1)
      return table[lower] + (table[lower + 1] - table[lower]) * (position - Double(lower))
    }
    var methods: [[String: Any]] = []
    for name in [
      "currentMerge", "directTransfer", "interpolated4096", "linearFloat16", "linearFloat32",
    ] {
      let values = linearValues.enumerated().map { index, linear in
        switch name {
        case "currentMerge": return Int(current.pixels[index * 3])
        case "interpolated4096": return code(interpolated(linear))
        case "linearFloat16":
          return code(FilmNegativeProcessing.linearToSRGB(Double(Float16(linear))))
        case "linearFloat32":
          return code(FilmNegativeProcessing.linearToSRGB(Double(Float(linear))))
        default: return code(FilmNegativeProcessing.linearToSRGB(linear))
        }
      }
      methods.append([
        "method": name,
        "distinctOutputCodes16": Set(values).count,
        "changedCodes": values.enumerated().filter { $0.offset != $0.element }.count,
        "maximumAbsoluteCodeError": values.enumerated().map { abs($0.offset - $0.element) }.max()!,
        "low51UniqueCodes": Set(values.prefix(51)).sorted(),
      ])
    }
    return [
      "kind": "Unit-exposure 16-bit encoded ramp round trip; no HDR range or GPU arithmetic test",
      "methods": methods,
      "interpolatedTableBytes": table.count * MemoryLayout<Double>.stride,
    ]
  }

  // Natural B&W first reduces BGR to one integer gray. Every subsequent point
  // operation can therefore be precomputed for its 65,536 possible values.
  // Use a three-component table to preserve matrix/rounding behavior exactly.
  static func lookupProbe() -> [[String: Any]] {
    let ramp = grayRamp()
    var generator: UInt64 = 20_260_913
    var samples: [UInt16] = []
    for index in 0..<(256 * 256 * 3) {
      generator = generator &* 6_364_136_223_846_793_005 &+ 1
      samples.append(index < 3078 ? UInt16(index / 3) : UInt16(truncatingIfNeeded: generator >> 32))
    }
    let source = UInt16Image(width: 256, height: 256, channels: 3, pixels: samples)
    var results: [[String: Any]] = []
    for scenario in 0..<3 {
      var parameters = ProcessingParameters()
      parameters.filmType = .blackAndWhiteNegative
      parameters.filmNegativeParams = .blackAndWhite
      parameters.filmNegativeParams.measuredMedians = .init(
        blue: 29_000, green: 28_000, red: 27_000)
      parameters.filmNegativeParams.monochromeExposureEV = 0.15
      if scenario == 1 {
        parameters.photoAdjustments = .init(
          exposureEV: 0.5, brightness: 0.1, contrast: 0.3, highlights: -0.3, shadows: 0.2)
        parameters.curveEnabled = true
        parameters.curveControlPoints = [
          .init(input: 0, output: 0), .init(input: 0.3, output: 0.25),
          .init(input: 0.7, output: 0.8), .init(input: 1, output: 1),
        ]
      } else if scenario == 2 {
        parameters.gamma = 20
        parameters.shadows = -15
        parameters.highlights = 10
      }
      let referenceStart = DispatchTime.now().uptimeNanoseconds
      let reference = FilmProcessing.correctedPreview(image: source, parameters: parameters)
      let referenceMS = elapsedMS(referenceStart)

      let tableStart = DispatchTime.now().uptimeNanoseconds
      var suffixParameters = parameters
      // Slide skips negative inversion and the zero-light override, while using
      // the same tone/curve stages. This probe uses neutral color controls.
      suffixParameters.filmType = .slide
      let suffix = FilmProcessing.correctedPreview(image: ramp, parameters: suffixParameters)
      let fn = parameters.filmNegativeParams
      let lut = (0...65_535).flatMap { index in
        let inverted = code(
          FilmNegativeProcessing.calibratedMonochromeToneCurve(
            Double(index) / maximum, negativeExposureEV: fn.monochromeExposureEV,
            measuredMedians: fn.measuredMedians, profile: fn.calibratedMonochromeProfile))
        return Array(suffix.pixels[(inverted * 3)..<(inverted * 3 + 3)])
      }
      let tableMS = elapsedMS(tableStart)
      let applyStart = DispatchTime.now().uptimeNanoseconds
      var pixels = [UInt16](repeating: 0, count: source.pixels.count)
      for index in 0..<(source.width * source.height) {
        let base = index * 3
        let blue = Double(source.pixels[base])
        let green = Double(source.pixels[base + 1])
        let red = Double(source.pixels[base + 2])
        let gray = Int(min(max(0.114 * blue + 0.587 * green + 0.299 * red, 0), maximum))
        let sensorBlack =
          max(blue, max(green, red)) <= Double(FilmNegativeProcessing.sensorBlackThreshold)
        for channel in 0..<3 {
          pixels[base + channel] = sensorBlack ? .max : lut[gray * 3 + channel]
        }
      }
      let applyMS = elapsedMS(applyStart)
      let errors = zip(reference.pixels, pixels).map { abs(Int($0) - Int($1)) }
      results.append([
        "scenario": ["natural", "semanticToneAndCurve", "legacyTone"][scenario],
        "pixelCount": source.width * source.height,
        "comparedComponents": pixels.count,
        "differentComponents": errors.filter { $0 != 0 }.count,
        "maximumAbsoluteCodeError": errors.max()!,
        "tableBytes": lut.count * MemoryLayout<UInt16>.stride,
        "referenceMSOneSample": referenceMS,
        "tableBuildMSOneSample": tableMS,
        "tableApplyMSOneSample": applyMS,
      ])
    }
    return results
  }

  static func hdrNoiseProbe() throws -> [String: Any] {
    // All eight combinations of three independent +/- noises. Their variances
    // follow the shot-noise exposure law, but this is a constructed fixture,
    // not a measurement or fitted noise model of the owner's camera.
    let scales = [1.0, 0.25, 0.0625]
    let truth = 0.8
    let captures = scales.enumerated().map { frame, scale in
      UInt16Image(
        width: 8, height: 1, channels: 3,
        pixels: (0..<8).flatMap { combination in
          let sign = (combination & (1 << frame)) == 0 ? -1.0 : 1.0
          let normalized = truth + sign * 0.001 / sqrt(scale)
          let value = UInt16(code(FilmNegativeProcessing.linearToSRGB(normalized * scale)))
          return [UInt16](repeating: value, count: 3)
        })
    }
    let alignment = ScanStackAlignment(
      translationX: 0, translationY: 0, confidence: 1, overlap: 1)
    let merged = try StackAnalysis.merge(
      images: captures, alignments: [alignment, alignment, alignment],
      exposureOffsetsEV: [0, -2, -4], mode: .hdr)
    func decoded(_ image: UInt16Image) -> [Double] {
      stride(from: 0, to: image.pixels.count, by: 3).map {
        FilmNegativeProcessing.sRGBToLinear(Double(image.pixels[$0]) / maximum)
      }
    }
    func mse(_ values: [Double]) -> Double {
      values.reduce(0) { $0 + ($1 - truth) * ($1 - truth) } / Double(values.count)
    }
    let referenceMSE = mse(decoded(captures[0]))
    let mergedMSE = mse(decoded(merged))
    return [
      "kind": "Eight constructed independent sign combinations; known alignment/exposure",
      "linearTruth": truth,
      "exposureOffsetsEV": [0, -2, -4],
      "normalizedNoiseAmplitudes": [0.001, 0.002, 0.004],
      "longestCaptureMSE": referenceMSE,
      "productionMergedMSE": mergedMSE,
      "mergedToLongestMSERatio": mergedMSE / referenceMSE,
      "idealEqualWeightVarianceRatio": 21.0 / 9.0,
      "idealInverseVarianceWeightRatio": 1.0 / (1 + 0.25 + 0.0625),
      "mergedLinearValues": decoded(merged),
    ]
  }

  static func persistenceProbe() throws -> [[String: Any]] {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-settings-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PerFileSettingsStore(baseDirectory: directory)
    // One tiny warm-up, then just three samples per synthetic history size.
    try store.save(.init(settingsByPath: [:], editedPaths: []))
    var results: [[String: Any]] = []
    for count in [1, 100, 640, 1000] {
      var settings: [String: ProcessingParameters] = [:]
      for index in 0..<count {
        var params = ProcessingParameters()
        params.filmType = .blackAndWhiteNegative
        params.filmNegativeParams = .blackAndWhite
        params.photoAdjustments.exposureEV = Double(index % 20) / 10
        settings["/synthetic/roll/frame-\(index).RAF"] = params
      }
      let state = PerFileSettingsStore.State(
        settingsByPath: settings, editedPaths: Set(settings.keys))
      var saveTimes: [Double] = []
      for _ in 0..<3 {
        let start = DispatchTime.now().uptimeNanoseconds
        try store.save(state)
        saveTimes.append(elapsedMS(start))
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
      var encodings: [[String: Any]] = []
      for compact in [false, true] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        let document = PerFileSettingsStore.Document(
          settingsByPath: settings, editedPaths: state.editedPaths)
        var times: [Double] = []
        var byteCount = 0
        for _ in 0..<3 {
          let start = DispatchTime.now().uptimeNanoseconds
          let data = try encoder.encode(document)
          times.append(elapsedMS(start))
          byteCount = data.count
        }
        encodings.append(["compact": compact, "bytes": byteCount, "encodeMS": times])
      }
      results.append([
        "storedPaths": count,
        "productionSaveMS": saveTimes,
        "productionFileBytes": attributes[.size] as! NSNumber,
        "encodingOnly": encodings,
      ])
    }
    return results
  }

  static func main() throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let result: [String: Any] = [
      "kind": "Bounded research pass; no RAW decode, full app, or GPU benchmark",
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "curveCandidate": curveProbe(),
      "transferPrecision": try precisionProbe(),
      "naturalBWLookup": lookupProbe(),
      "hdrNoiseWeighting": try hdrNoiseProbe(),
      "settingsPersistence": try persistenceProbe(),
    ]
    var timed = result
    timed["probeWallMS"] = elapsedMS(start)
    let data = try JSONSerialization.data(
      withJSONObject: timed, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}
