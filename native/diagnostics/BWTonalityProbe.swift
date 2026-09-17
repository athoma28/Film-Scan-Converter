// A small diagnostic linked against an existing release FilmScanEngine build.
// This reports the shipped behavior; it does not assert that a flat curve is correct.
import FilmScanEngine
import Foundation

let source = UInt16Image(
  width: 256, height: 256, channels: 3,
  pixels: (0...65_535).flatMap { [UInt16](repeating: UInt16($0), count: 3) })
let plateauInputs = 45_875...58_981  // 0.7...0.9 in the unnormalized UInt16 ramp.
var profiles: [[String: Any]] = []
for profile in [CalibratedMonochromeProfile.generic, .shanghaiGP3] {
  var parameters = ProcessingParameters()
  parameters.filmType = .blackAndWhiteNegative
  parameters.filmNegativeParams = .blackAndWhite
  parameters.filmNegativeParams.calibratedMonochromeProfile = profile
  // No measured median: gain = 1. The report separately explains normalization.
  let output = FilmProcessing.correctedPreview(image: source, parameters: parameters)
  let values = plateauInputs.map { output.pixels[$0 * output.channels] }
  profiles.append([
    "profile": profile.rawValue,
    "inputCodeRange": [plateauInputs.lowerBound, plateauInputs.upperBound],
    "distinctInputCodes": plateauInputs.count,
    "distinctOutputCodes16": Set(values).count,
    "outputRange16": [Int(values.min()!), Int(values.max()!)],
    "toneSamples": [0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95].map { input in
      [
        "input": input,
        "output": FilmNegativeProcessing.calibratedMonochromeToneCurve(input, profile: profile),
      ]
    },
  ])
}
// Isolate merging with perfect alignment and known exposure offsets. Registration
// is deliberately bypassed: it should not obscure the range/precision question.
func encodedImage(linearValues: [Double], exposureScale: Double) -> UInt16Image {
  UInt16Image(
    width: linearValues.count, height: 1, channels: 3,
    pixels: linearValues.flatMap { value in
      let linear = min(max(value * exposureScale, 0), 1)
      let encoded =
        linear <= 0.003_130_8 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
      return [UInt16](repeating: UInt16((encoded * 65_535).rounded()), count: 3)
    })
}

let radiance = [1.05, 1.20, 1.40, 1.60]
let captures = [1.0, 0.5, 0.25].map {
  encodedImage(linearValues: radiance, exposureScale: $0)
}
let alignments = [ScanStackAlignment](
  repeating: ScanStackAlignment(translationX: 0, translationY: 0, confidence: 1, overlap: 1),
  count: 3)
let brightReference = try StackAnalysis.merge(
  images: captures, alignments: alignments, exposureOffsetsEV: [0, -1, -2], mode: .hdr)
let shortReference = try StackAnalysis.merge(
  images: Array(captures.reversed()), alignments: alignments,
  exposureOffsetsEV: [0, 1, 2], mode: .hdr)
func firstChannel(_ image: UInt16Image) -> [Int] {
  stride(from: 0, to: image.pixels.count, by: image.channels).map { Int(image.pixels[$0]) }
}

let lowCodes = UInt16Image(
  width: 51, height: 1, channels: 3,
  pixels: (0...50).flatMap { [UInt16](repeating: UInt16($0), count: 3) })
let lowCodeMerge = try StackAnalysis.merge(
  images: [lowCodes, lowCodes, lowCodes], alignments: alignments,
  exposureOffsetsEV: [0, 0, 0], mode: .noiseReduction)

let result: [String: Any] = [
  "diagnostic": "B&W Natural tonality, production CPU pipeline, no RAW decode",
  "dimensions": [source.width, source.height],
  "profiles": profiles,
  "hdrMerge": [
    "referenceRelativeLinearRadiance": radiance,
    "captureExposureOffsetsEV": [0, -1, -2],
    "brightReferenceOutputCodes16": firstChannel(brightReference),
    "shortReferenceOutputCodes16": firstChannel(shortReference),
    "alignment": "identity; exposure offsets supplied, not estimated",
  ],
  "mergePrecision": [
    "inputCodeRange16": [0, 50],
    "distinctInputCodes": 51,
    "distinctOutputCodes16": Set(firstChannel(lowCodeMerge)).count,
    "outputCodes16": Set(firstChannel(lowCodeMerge)).sorted(),
    "captures": "three identical, noiseless, zero exposure offset",
  ],
]
let json = try JSONSerialization.data(
  withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
