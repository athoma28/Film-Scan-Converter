import CoreGraphics
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Metal

let hasMetal = MTLCreateSystemDefaultDevice() != nil
let imageSize = 256

func makeGradient(width: Int, height: Int) -> UInt16Image {
  var pixels = [UInt16]()
  pixels.reserveCapacity(width * height * 3)
  for y in 0..<height {
    for x in 0..<width {
      let r = UInt16(Double(x) / Double(width - 1) * 65535)
      let g = UInt16(Double(y) / Double(height - 1) * 65535)
      let b = UInt16(((Double(x) + Double(y)) / 2) / Double(max(width, height) - 1) * 65535)
      pixels.append(contentsOf: [b, g, r])
    }
  }
  return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
}

func makeCheckerboard(width: Int, height: Int) -> UInt16Image {
  let checkSize = max(width, height) / 8
  var pixels = [UInt16]()
  pixels.reserveCapacity(width * height * 3)
  for y in 0..<height {
    for x in 0..<width {
      let on = ((x / checkSize) + (y / checkSize)) % 2 == 0
      let v: UInt16 = on ? 49152 : 16384
      pixels.append(contentsOf: [v, v, v])
    }
  }
  return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
}

func makeSolid(_ value: UInt16, width: Int, height: Int) -> UInt16Image {
  let pixels = Array(repeating: value, count: width * height * 3)
  return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
}

/// Core Image can pad rows, especially after a quarter turn. Compare visible
/// RGB bytes only, never padding or the unused CPU alpha byte.
func extractRGBAPixels(_ cgImage: CGImage) -> [UInt8]? {
  guard cgImage.width > 0, cgImage.height > 0,
    cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32,
    [.noneSkipLast, .premultipliedLast, .last].contains(cgImage.alphaInfo),
    cgImage.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little,
    cgImage.bytesPerRow >= cgImage.width * 4,
    let data = cgImage.dataProvider?.data,
    CFDataGetLength(data) >= cgImage.bytesPerRow * (cgImage.height - 1) + cgImage.width * 4,
    let ptr = CFDataGetBytePtr(data)
  else { return nil }
  var pixels: [UInt8] = []
  pixels.reserveCapacity(cgImage.width * cgImage.height * 4)
  for y in 0..<cgImage.height {
    let row = ptr.advanced(by: y * cgImage.bytesPerRow)
    pixels.append(contentsOf: UnsafeBufferPointer(start: row, count: cgImage.width * 4))
  }
  return pixels
}

struct DiffStats {
  let maxR: Int
  let maxG: Int
  let maxB: Int
  let meanDiff: Double
  let pixelCount: Int
  let differentPixels: Int
}

func comparePixels(gpu: [UInt8], cpu: [UInt8]) -> DiffStats {
  var maxR = 0
  var maxG = 0
  var maxB = 0
  var sumDiff: Int64 = 0
  var differentPixels = 0
  let pixelCount = gpu.count / 4
  for i in stride(from: 0, to: gpu.count, by: 4) {
    let rDiff = abs(Int(gpu[i]) - Int(cpu[i]))
    let gDiff = abs(Int(gpu[i + 1]) - Int(cpu[i + 1]))
    let bDiff = abs(Int(gpu[i + 2]) - Int(cpu[i + 2]))
    maxR = max(maxR, rDiff)
    maxG = max(maxG, gDiff)
    maxB = max(maxB, bDiff)
    let maxChannelDiff = max(rDiff, max(gDiff, bDiff))
    sumDiff += Int64(maxChannelDiff)
    if maxChannelDiff > 0 { differentPixels += 1 }
  }
  return DiffStats(
    maxR: maxR, maxG: maxG, maxB: maxB,
    meanDiff: Double(sumDiff) / Double(pixelCount),
    pixelCount: pixelCount,
    differentPixels: differentPixels
  )
}

struct ParameterCombo: Hashable, CustomStringConvertible {
  let filmType: FilmType
  let temperature: Int
  let tint: Int
  let gamma: Int
  let shadows: Int
  let highlights: Int
  let saturation: Int
  let curveEnabled: Bool
  let wheelsEnabled: Bool
  let photo: PhotoAdjustmentParameters
  init(
    filmType: FilmType,
    temperature: Int = 0,
    tint: Int = 0,
    gamma: Int = 0,
    shadows: Int = 0,
    highlights: Int = 0,
    saturation: Int = 100,
    curveEnabled: Bool = false,
    wheelsEnabled: Bool = false,
    photo: PhotoAdjustmentParameters = PhotoAdjustmentParameters(schemaVersion: 1)
  ) {
    self.filmType = filmType
    self.temperature = temperature
    self.tint = tint
    self.gamma = gamma
    self.shadows = shadows
    self.highlights = highlights
    self.saturation = saturation
    self.curveEnabled = curveEnabled
    self.wheelsEnabled = wheelsEnabled
    self.photo = photo
  }
  var description: String {
    var parts =
      "\(filmType) T\(temperature) tint\(tint) γ\(gamma) s\(shadows) h\(highlights) sat\(saturation) curve=\(curveEnabled) wheels=\(wheelsEnabled)"
    if photo.exposureEV != 0 { parts += " EV=\(String(format: "%.1f", photo.exposureEV))" }
    if photo.brightness != 0 { parts += " bri=\(String(format: "%.2f", photo.brightness))" }
    if photo.contrast != 0 { parts += " con=\(String(format: "%.2f", photo.contrast))" }
    if photo.highlights != 0 { parts += " hl=\(String(format: "%.2f", photo.highlights))" }
    if photo.shadows != 0 { parts += " sh=\(String(format: "%.2f", photo.shadows))" }
    return parts
  }
}

func toneControlGrid() -> [ParameterCombo] {
  var combos = [ParameterCombo]()
  let filmTypes: [FilmType] = [.colourNegative]

  let exposureValues: [Double] = [-1, 0, 1]
  let brightnessValues: [Double] = [-0.3, 0, 0.3]
  let contrastValues: [Double] = [-0.3, 0, 0.3]
  let highlightValues: [Double] = [-0.5, 0, 0.5]
  let shadowValues: [Double] = [-0.5, 0, 0.5]

  for ft in filmTypes {
    for ev in exposureValues {
      for bri in brightnessValues {
        for con in contrastValues {
          let active =
            [ev != 0, bri != 0, con != 0].filter { $0 }.count
          guard active <= 1 else { continue }
          combos.append(
            ParameterCombo(
              filmType: ft,
              photo: PhotoAdjustmentParameters(
                schemaVersion: 1,
                exposureEV: ev, brightness: bri, contrast: con)))
        }
      }
    }

    for hl in highlightValues {
      combos.append(
        ParameterCombo(
          filmType: ft,
          photo: PhotoAdjustmentParameters(schemaVersion: 1, highlights: hl)))
    }
    for sh in shadowValues {
      combos.append(
        ParameterCombo(
          filmType: ft,
          photo: PhotoAdjustmentParameters(schemaVersion: 1, shadows: sh)))
    }

    combos.append(
      ParameterCombo(
        filmType: ft,
        photo: PhotoAdjustmentParameters(
          schemaVersion: 1,
          exposureEV: 0.5, brightness: 0.2, contrast: 0.3,
          highlights: -0.3, shadows: 0.3)))
  }
  return combos
}

func parameterGrid() -> [ParameterCombo] {
  var combos = [ParameterCombo]()
  let filmTypes: [FilmType] = [.colourNegative, .blackAndWhiteNegative, .slide]
  let temps = [0, -65, 65]
  let tints = [0, -40, 40]
  let gammas = [0, -35, 40]
  let shadows = [0, 60]
  let highlights = [0, -45]
  let sats = [100, 50, 150, 0]

  for ft in filmTypes {
    for temp in temps {
      for tint in tints {
        for gamma in gammas {
          for sh in shadows {
            for hl in highlights {
              for sat in sats {
                combos.append(
                  ParameterCombo(
                    filmType: ft, temperature: temp, tint: tint,
                    gamma: gamma, shadows: sh, highlights: hl, saturation: sat,
                    curveEnabled: false, wheelsEnabled: false))
              }
            }
          }
        }
      }
    }
  }
  // De-duplicate: keep combos with ≤3 non-default parameters
  let baseCombos = combos.filter { combo in
    let active =
      [
        combo.temperature != 0, combo.tint != 0,
        combo.gamma != 0, combo.shadows != 0, combo.highlights != 0,
        combo.saturation != 100,
      ].filter { $0 }.count
    return active <= 3
  }
  let gradingCombos = filmTypes.flatMap { filmType in
    [
      ParameterCombo(
        filmType: filmType, temperature: 0, tint: 0, gamma: 0, shadows: 0,
        highlights: 0, saturation: 100, curveEnabled: true, wheelsEnabled: false),
      ParameterCombo(
        filmType: filmType, temperature: 0, tint: 0, gamma: 0, shadows: 0,
        highlights: 0, saturation: 100, curveEnabled: false, wheelsEnabled: true),
      ParameterCombo(
        filmType: filmType, temperature: 35, tint: -20, gamma: 25, shadows: 30,
        highlights: -25, saturation: 130, curveEnabled: true, wheelsEnabled: true),
    ]
  }
  return baseCombos + gradingCombos
}

func legacyScenario(_ combo: ParameterCombo) -> ComparisonScenario {
  ComparisonScenario(name: combo.description, family: "legacy", parameters: legacyParameters(combo))
}

func legacyParameters(_ combo: ParameterCombo) -> ProcessingParameters {
  return ProcessingParameters(
    filmType: combo.filmType,
    gamma: combo.gamma,
    shadows: combo.shadows,
    highlights: combo.highlights,
    temperature: combo.temperature,
    tint: combo.tint,
    saturation: combo.saturation,
    curveEnabled: combo.curveEnabled,
    curveControlPoints: combo.curveEnabled
      ? [
        CurvePoint(input: 0, output: 0),
        CurvePoint(input: 0.3, output: 0.15),
        CurvePoint(input: 0.7, output: 0.85),
        CurvePoint(input: 1, output: 1),
      ] : [],
    highlightWheel: combo.wheelsEnabled ? ColorWheel(hue: 35, strength: 0.4) : ColorWheel(),
    midtoneWheel: combo.wheelsEnabled ? ColorWheel(hue: 190, strength: 0.25) : ColorWheel(),
    shadowWheel: combo.wheelsEnabled ? ColorWheel(hue: 285, strength: 0.5) : ColorWheel(),
    photoAdjustments: combo.photo
  )
}

struct ComparisonSummary {
  var expected = 0
  var completed = 0
  var cpuFallbacks = 0
  var failures = 0
  var outsideTolerance = 0
  var maximumError = 0
  var maximumMeanError = 0.0
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count <= 1,
  arguments.allSatisfy({ ["--suite=all", "--suite=legacy", "--suite=current"].contains($0) })
else {
  print("Usage: FilmScanPreviewComparator [--suite=all|legacy|current]")
  exit(2)
}
let suite = arguments.first?.split(separator: "=").last.map(String.init) ?? "all"
let tolerance = 2
let legacyScenarios = (parameterGrid() + toneControlGrid()).map(legacyScenario)
let currentScenarios = currentWorkflowScenarios()
let legacyImages: [(String, UInt16Image)] = [
  ("gradient", makeGradient(width: imageSize, height: imageSize)),
  ("checkerboard", makeCheckerboard(width: imageSize, height: imageSize)),
  ("solid-dark", makeSolid(0, width: imageSize, height: imageSize)),
  ("solid-mid", makeSolid(32768, width: imageSize, height: imageSize)),
  ("solid-bright", makeSolid(65535, width: imageSize, height: imageSize)),
]
let currentImages =
  legacyImages + [
    ("color-volume", makeColorVolume(width: 73, height: 47)),
    ("non-square-gradient", makeGradient(width: 79, height: 53)),
  ]
var batches: [(images: [(String, UInt16Image)], scenarios: [ComparisonScenario])] = []
if suite != "current" { batches.append((legacyImages, legacyScenarios)) }
if suite != "legacy" { batches.append((currentImages, currentScenarios)) }
let expectedComparisons = batches.reduce(0) { $0 + $1.images.count * $1.scenarios.count }
var summaries: [String: ComparisonSummary] = [:]
for batch in batches {
  for scenario in batch.scenarios {
    summaries[scenario.family, default: ComparisonSummary()].expected += batch.images.count
  }
}

print("Film Scan Preview Comparator")
print("Metal available: \(hasMetal); suite: \(suite)")
print("Expected comparisons: \(expectedComparisons)")
print("Current cases use FilmBase + LookRecipe; RGB tolerance: \(tolerance)/255")
guard hasMetal else {
  print("FAIL: Metal is unavailable; no GPU comparisons can be validated.")
  exit(1)
}

var worstCase: (image: String, scenario: String, stats: DiffStats)?
for batch in batches {
  for (imageName, image) in batch.images {
    print(
      "Testing \(imageName) (\(image.width)×\(image.height)), \(batch.scenarios.count) scenarios…")
    guard let renderer = StillPreviewRenderer(image: image) else {
      for scenario in batch.scenarios { summaries[scenario.family]!.failures += 1 }
      print("FAIL: Could not create GPU renderer for \(imageName)")
      continue
    }
    for scenario in batch.scenarios {
      autoreleasepool {
        let parameters = scenario.parameters
        // Flat density frames have no useful log span. They must explicitly
        // select the app's authoritative CPU path, not claim GPU parity after
        // dividing Float cancellation noise by the CPU's tiny epsilon span.
        let expectsCPUFallback =
          imageName.hasPrefix("solid-") && !scenario.showOriginal
          && parameters.filmType == .colourNegative && parameters.filmNegativeParams.enabled
          && parameters.filmNegativeParams.rendering == .densityPrint
        if expectsCPUFallback {
          guard !renderer.supports(parameters: parameters, showOriginal: scenario.showOriginal),
            renderer.render(parameters: parameters, showOriginal: scenario.showOriginal) == nil
          else {
            summaries[scenario.family]!.failures += 1
            print("FAIL: Expected explicit CPU fallback: \(imageName) \(scenario.name)")
            return
          }
          summaries[scenario.family]!.cpuFallbacks += 1
          return
        }
        var cpuParameters = parameters
        if scenario.showOriginal { cpuParameters.filmType = .cropOnly }
        guard
          StillPreviewRenderer.supports(
            parameters: parameters, showOriginal: scenario.showOriginal),
          renderer.supports(parameters: parameters, showOriginal: scenario.showOriginal),
          let gpu = renderer.render(parameters: parameters, showOriginal: scenario.showOriginal),
          let cpu = FilmProcessing.correctedPreview(image: image, parameters: cpuParameters)
            .makePreviewCGImage(),
          gpu.width
            == ImageGeometry.outputDimensions(
              source: .init(width: image.width, height: image.height), parameters: parameters
            ).width,
          gpu.height
            == ImageGeometry.outputDimensions(
              source: .init(width: image.width, height: image.height), parameters: parameters
            ).height,
          gpu.width == cpu.width, gpu.height == cpu.height,
          let gpuPixels = extractRGBAPixels(gpu), let cpuPixels = extractRGBAPixels(cpu),
          gpuPixels.count == cpuPixels.count
        else {
          summaries[scenario.family]!.failures += 1
          print("FAIL: Render/support/dimensions/pixel layout: \(imageName) \(scenario.name)")
          return
        }
        let stats = comparePixels(gpu: gpuPixels, cpu: cpuPixels)
        let maximum = max(stats.maxR, stats.maxG, stats.maxB)
        var summary = summaries[scenario.family]!
        summary.completed += 1
        summary.maximumError = max(summary.maximumError, maximum)
        summary.maximumMeanError = max(summary.maximumMeanError, stats.meanDiff)
        if maximum > tolerance {
          summary.outsideTolerance += 1
          print(
            "FAIL: \(imageName) \(scenario.name): RGB max \(stats.maxR)/\(stats.maxG)/\(stats.maxB), mean \(String(format: "%.4f", stats.meanDiff))"
          )
        }
        summaries[scenario.family] = summary
        if worstCase == nil
          || maximum > max(worstCase!.stats.maxR, worstCase!.stats.maxG, worstCase!.stats.maxB)
        {
          worstCase = (imageName, scenario.name, stats)
        }
      }
    }
  }
}

print("\nComparison results by family:")
for family in summaries.keys.sorted() {
  let summary = summaries[family]!
  print(
    "  \(family): GPU=\(summary.completed), CPU fallback=\(summary.cpuFallbacks), expected=\(summary.expected), failures=\(summary.failures), outside tolerance=\(summary.outsideTolerance), max=\(summary.maximumError)/255, worst mean=\(String(format: "%.4f", summary.maximumMeanError))"
  )
}
let completed = summaries.values.reduce(0) { $0 + $1.completed }
let failures = summaries.values.reduce(0) { $0 + $1.failures }
let cpuFallbacks = summaries.values.reduce(0) { $0 + $1.cpuFallbacks }
let outsideTolerance = summaries.values.reduce(0) { $0 + $1.outsideTolerance }
print("GPU comparisons: \(completed); verified CPU routes: \(cpuFallbacks)")
print("Total cases checked: \(completed + cpuFallbacks)/\(expectedComparisons)")
print("Render failures: \(failures)")
if let worstCase {
  print("Worst case: \(worstCase.image) \(worstCase.scenario)")
  print(
    "  RGB max: \(worstCase.stats.maxR)/\(worstCase.stats.maxG)/\(worstCase.stats.maxB); mean: \(String(format: "%.4f", worstCase.stats.meanDiff))"
  )
}
guard completed + cpuFallbacks == expectedComparisons, completed > 0, failures == 0,
  outsideTolerance == 0
else {
  print("FAIL: The full comparison cohort must complete within \(tolerance)/255.")
  exit(1)
}
print(
  "PASS: All \(completed) GPU comparisons within \(tolerance)/255; \(cpuFallbacks) explicit CPU routes verified. Synthetic coverage only; photographic and export acceptance remain separate."
)
