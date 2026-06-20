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

func extractRGBAPixels(_ cgImage: CGImage) -> [UInt8]? {
  guard let data = cgImage.dataProvider?.data,
    let ptr = CFDataGetBytePtr(data)
  else { return nil }
  let count = cgImage.width * cgImage.height * 4
  return Array(UnsafeBufferPointer(start: ptr, count: count))
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
    photo: PhotoAdjustmentParameters = PhotoAdjustmentParameters()
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
    var parts = "\(filmType) T\(temperature) tint\(tint) γ\(gamma) s\(shadows) h\(highlights) sat\(saturation) curve=\(curveEnabled) wheels=\(wheelsEnabled)"
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
          combos.append(ParameterCombo(
            filmType: ft,
            photo: PhotoAdjustmentParameters(
              exposureEV: ev, brightness: bri, contrast: con)))
        }
      }
    }

    for hl in highlightValues {
      combos.append(ParameterCombo(
        filmType: ft,
        photo: PhotoAdjustmentParameters(highlights: hl)))
    }
    for sh in shadowValues {
      combos.append(ParameterCombo(
        filmType: ft,
        photo: PhotoAdjustmentParameters(shadows: sh)))
    }

    combos.append(ParameterCombo(
      filmType: ft,
      photo: PhotoAdjustmentParameters(
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
      [combo.temperature != 0, combo.tint != 0,
        combo.gamma != 0, combo.shadows != 0, combo.highlights != 0,
        combo.saturation != 100
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

func cpuRender(image: UInt16Image, parameters: ProcessingParameters) -> CGImage? {
  let corrected = FilmProcessing.correctedPreview(image: image, parameters: parameters)
  return corrected.makePreviewCGImage()
}

print("Film Scan Preview Comparator")
print("============================")
print("Metal available: \(hasMetal)")
print("Image size: \(imageSize)×\(imageSize)")
print()

let images: [(String, UInt16Image)] = [
  ("gradient", makeGradient(width: imageSize, height: imageSize)),
  ("checkerboard", makeCheckerboard(width: imageSize, height: imageSize)),
  ("solid-dark", makeSolid(0, width: imageSize, height: imageSize)),
  ("solid-mid", makeSolid(32768, width: imageSize, height: imageSize)),
  ("solid-bright", makeSolid(65535, width: imageSize, height: imageSize)),
]

let baseCombos = parameterGrid()
let toneCombos = toneControlGrid()
let combos = baseCombos + toneCombos
print("Parameter combinations to test: \(combos.count) (base: \(baseCombos.count), tone: \(toneCombos.count))")
print()

var totalComparisons = 0
var totalFailures = 0
var worstMaxDiff = 0
var worstMeanDiff = 0.0
var worstCombo: ParameterCombo?
var worstImageName = ""
var filmModeStats: [FilmType: (count: Int, maxDiff: Int, maxMean: Double)] = [:]

for (imageName, image) in images {
  guard let renderer = StillPreviewRenderer(image: image) else {
    print("WARNING: Could not create GPU renderer for \(imageName)")
    continue
  }

  print("Testing \(imageName) (\(image.width)×\(image.height))…")

  for (index, combo) in combos.enumerated() {
    let parameters = ProcessingParameters(
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

    guard let gpuCG = renderer.render(parameters: parameters, showOriginal: false),
      let gpuPixels = extractRGBAPixels(gpuCG),
      let cpuCG = cpuRender(image: image, parameters: parameters),
      let cpuPixels = extractRGBAPixels(cpuCG)
    else {
      totalFailures += 1
      continue
    }

    totalComparisons += 1
    let stats = comparePixels(gpu: gpuPixels, cpu: cpuPixels)

    if stats.maxR > 0 || stats.maxG > 0 || stats.maxB > 0 {
      let maxDiff = max(stats.maxR, max(stats.maxG, stats.maxB))
      if maxDiff > worstMaxDiff {
        worstMaxDiff = maxDiff
        worstMeanDiff = stats.meanDiff
        worstCombo = combo
        worstImageName = imageName
      }

      let existing = filmModeStats[combo.filmType] ?? (0, 0, 0)
      filmModeStats[combo.filmType] = (
        existing.count + 1,
        max(existing.maxDiff, maxDiff),
        max(existing.maxMean, stats.meanDiff)
      )
    }

    if (index + 1) % 30 == 0 || index == combos.count - 1 {
      print("  \(index + 1)/\(combos.count)")
    }
  }
}

print()
print("=== COMPARISON RESULTS ===")
print()
print("Total comparisons: \(totalComparisons)")
print("Render failures: \(totalFailures)")
print()
print("Worst-case difference:")
if let worstCombo, worstMaxDiff > 0 {
  print("  Image: \(worstImageName)")
  print("  Parameters: \(worstCombo)")
  print("  Max per-channel diff: \(worstMaxDiff) (of 255)")
  print("  Mean per-pixel diff: \(String(format: "%.2f", worstMeanDiff))")
} else {
  print("  All comparisons pixel-identical!")
}
print()

if filmModeStats.isEmpty {
  print("All film modes: pixel-identical across all parameter combinations.")
} else {
  print("Per film-mode summary:")
  for filmType in [FilmType.colourNegative, FilmType.blackAndWhiteNegative, FilmType.slide] {
    if let s = filmModeStats[filmType] {
      print(
        "  \(filmType): \(s.count) combos with diffs, max=\(s.maxDiff), worst-mean=\(String(format: "%.2f", s.maxMean))"
      )
    } else {
      print("  \(filmType): all pixel-identical")
    }
  }
}
print()

let tolerance = 2
if worstMaxDiff <= tolerance {
  print("PASS: All differences within \(tolerance)-level tolerance.")
  print("GPU preview is visually equivalent to CPU authoritative path.")
} else {
  print("WARNING: Maximum channel difference \(worstMaxDiff) exceeds \(tolerance)-level tolerance.")
  print()
  print("DIAGNOSTIC: Worst-case pixel-by-pixel breakdown")
  print("----------------------------------------------")

  var diagImage = makeGradient(width: imageSize, height: imageSize)
  if worstImageName == "checkerboard" {
    diagImage = makeCheckerboard(width: imageSize, height: imageSize)
  } else if worstImageName == "solid-dark" {
    diagImage = makeSolid(0, width: imageSize, height: imageSize)
  } else if worstImageName == "solid-mid" {
    diagImage = makeSolid(32768, width: imageSize, height: imageSize)
  } else if worstImageName == "solid-bright" {
    diagImage = makeSolid(65535, width: imageSize, height: imageSize)
  }

  guard let renderer = StillPreviewRenderer(image: diagImage),
    let wc = worstCombo
  else {
    fatalError("Could not create diagnostic renderer")
  }
  let params = ProcessingParameters(
    filmType: wc.filmType,
    gamma: wc.gamma,
    shadows: wc.shadows,
    highlights: wc.highlights,
    temperature: wc.temperature,
    tint: wc.tint,
    saturation: wc.saturation,
    curveEnabled: wc.curveEnabled,
    curveControlPoints: wc.curveEnabled
      ? [
        CurvePoint(input: 0, output: 0),
        CurvePoint(input: 0.3, output: 0.15),
        CurvePoint(input: 0.7, output: 0.85),
        CurvePoint(input: 1, output: 1),
      ] : [],
    highlightWheel: wc.wheelsEnabled ? ColorWheel(hue: 35, strength: 0.4) : ColorWheel(),
    midtoneWheel: wc.wheelsEnabled ? ColorWheel(hue: 190, strength: 0.25) : ColorWheel(),
    shadowWheel: wc.wheelsEnabled ? ColorWheel(hue: 285, strength: 0.5) : ColorWheel(),
    photoAdjustments: wc.photo
  )
  guard let gc = renderer.render(parameters: params, showOriginal: false),
    let gp = extractRGBAPixels(gc),
    let cc = cpuRender(image: diagImage, parameters: params),
    let cp = extractRGBAPixels(cc)
  else {
    print("Diagnostic render failed")
    fatalError("Diagnostic render failed")
  }

  print("Worst combo: \(wc)")
  print()
  print("First 10 pixels (R G B):")
  for i in 0..<min(10, gp.count / 4) {
    let o = i * 4
    print(
      "  px[\(i)] GPU=(\(gp[o]),\(gp[o+1]),\(gp[o+2])) CPU=(\(cp[o]),\(cp[o+1]),\(cp[o+2])) Δ=(\(abs(Int(gp[o])-Int(cp[o]))),\(abs(Int(gp[o+1])-Int(cp[o+1]))),\(abs(Int(gp[o+2])-Int(cp[o+2]))))"
    )
  }

  var maxDiffs = [Int]()
  maxDiffs.reserveCapacity(gp.count / 4)
  for i in 0..<(gp.count / 4) {
    let o = i * 4
    let redDiff = abs(Int(gp[o]) - Int(cp[o]))
    let greenDiff = abs(Int(gp[o + 1]) - Int(cp[o + 1]))
    let blueDiff = abs(Int(gp[o + 2]) - Int(cp[o + 2]))
    maxDiffs.append(max(redDiff, max(greenDiff, blueDiff)))
  }
  if let worstIdx = maxDiffs.enumerated().max(by: { $0.element < $1.element }) {
    let o = worstIdx.offset * 4
    print()
    print(
      "Worst pixel [\(worstIdx.offset)]: GPU=(\(gp[o]),\(gp[o+1]),\(gp[o+2])) CPU=(\(cp[o]),\(cp[o+1]),\(cp[o+2])) diff=\(worstIdx.element)"
    )
  }
}
