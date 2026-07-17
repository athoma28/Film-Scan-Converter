import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Metal

private let width = 1080
private let height = 720
private let warmupIterations = 12
private let measuredIterations = 120

private func makeImage() -> UInt16Image {
  var pixels = [UInt16](repeating: 0, count: width * height * 3)
  var state: UInt64 = 0x4d59_5df4_d0f3_3173
  for index in pixels.indices {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    pixels[index] = UInt16(truncatingIfNeeded: state >> 16)
  }
  return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
}

private func makeParameters(image: UInt16Image) -> [ProcessingParameters] {
  var filmNegative = FilmNegativeParams.colourNegative
  filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
  let curve = [
    CurvePoint(input: 0, output: 0),
    CurvePoint(input: 0.3, output: 0.15),
    CurvePoint(input: 0.7, output: 0.85),
    CurvePoint(input: 1, output: 1),
  ]

  return (0..<measuredIterations).map { index in
    let phase = Double(index % 9) / 8
    return ProcessingParameters(
      filmType: .colourNegative,
      curveEnabled: true,
      curveControlPoints: curve,
      highlightWheel: ColorWheel(hue: Double((index * 37) % 360), strength: 0.4),
      midtoneWheel: ColorWheel(hue: Double((index * 61) % 360), strength: 0.25),
      shadowWheel: ColorWheel(hue: Double((index * 83) % 360), strength: 0.5),
      filmNegativeParams: filmNegative,
      filmDyeMixing: FilmDyeMixingParameters(
        redFromGreen: -0.08,
        redFromBlue: 0.04,
        greenFromRed: 0.03,
        greenFromBlue: -0.06,
        blueFromRed: 0.07,
        blueFromGreen: -0.03
      ),
      photoAdjustments: PhotoAdjustmentParameters(
        exposureEV: -0.5 + phase,
        brightness: -0.15 + phase * 0.3,
        contrast: -0.35 + phase * 0.7,
        highlights: -0.4 + phase * 0.8,
        shadows: 0.4 - phase * 0.8,
        temperatureShiftMired: -80 + phase * 160,
        tint: -0.8 + phase * 1.6,
        saturation: 0.55 + phase * 0.45,
        vibrance: 0.5 + phase * 0.5
      )
    )
  }
}

private func milliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1_000
    + Double(duration.components.attoseconds) / 1e15
}

let image = makeImage()
guard let renderer = StillPreviewRenderer(image: image) else {
  fatalError("Metal-backed still-preview renderer is unavailable")
}
let parameters = makeParameters(image: image)

for index in 0..<warmupIterations {
  guard renderer.render(parameters: parameters[index], showOriginal: false) != nil else {
    fatalError("Warmup render failed")
  }
}

var latencies = [Double]()
latencies.reserveCapacity(measuredIterations)
for snapshot in parameters {
  let start = ContinuousClock.now
  guard renderer.render(parameters: snapshot, showOriginal: false) != nil else {
    fatalError("Measured render failed")
  }
  latencies.append(milliseconds(start.duration(to: .now)))
}

let sorted = latencies.sorted()
let median = sorted[sorted.count / 2]
let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
let mean = latencies.reduce(0, +) / Double(latencies.count)
let device = MTLCreateSystemDefaultDevice()

print("GPU: \(device?.name ?? "unavailable")")
print("Resolution: \(width)x\(height)")
print("Measured renders: \(measuredIterations)")
print("median_ms=\(String(format: "%.4f", median))")
print("p95_ms=\(String(format: "%.4f", p95))")
print("mean_ms=\(String(format: "%.4f", mean))")
