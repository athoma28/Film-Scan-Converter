import CoreGraphics
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@Suite("Still preview production renderer")
struct StillPreviewBenchmarkTests {
  private static let benchmarkIterations = 500
  private static let p95LatencyThresholdMs: Double = 33.0
  private static let proxyWidth = 1080
  private static let proxyHeight = 720

  private static let curvePoints = [
    CurvePoint(input: 0, output: 0),
    CurvePoint(input: 0.3, output: 0.15),
    CurvePoint(input: 0.7, output: 0.85),
    CurvePoint(input: 1, output: 1),
  ]

  private static func createRandomImage(width: Int, height: Int) -> UInt16Image {
    UInt16Image(
      width: width, height: height, channels: 3,
      pixels: (0..<(width * height * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
  }

  private static func makeParameterGrid(count: Int) -> [ProcessingParameters] {
    var parameters = [ProcessingParameters]()
    parameters.reserveCapacity(count)
    let filmTypes: [FilmType] = [.colourNegative, .blackAndWhiteNegative, .slide, .cropOnly]
    let temperatures = [0, -50, 25, 80]
    let tints = [0, -30, 15, 60]
    let gammas = [0, -35, 15, 40]
    let shadows = [0, 30, 60, -30]
    let highlights = [0, -30, -45, 30]
    let saturations = [100, 75, 150, 0, 200]

    var rng = SystemRandomNumberGenerator()
    for index in 0..<count {
      let curvesEnabled = index % 3 != 0
      let wheelsEnabled = index % 4 != 0
      parameters.append(
        ProcessingParameters(
          filmType: filmTypes.randomElement(using: &rng)!,
          gamma: gammas.randomElement(using: &rng)!,
          shadows: shadows.randomElement(using: &rng)!,
          highlights: highlights.randomElement(using: &rng)!,
          temperature: temperatures.randomElement(using: &rng)!,
          tint: tints.randomElement(using: &rng)!,
          saturation: saturations.randomElement(using: &rng)!,
          curveEnabled: curvesEnabled,
          curveControlPoints: curvesEnabled ? curvePoints : [],
          highlightWheel: wheelsEnabled ? ColorWheel(hue: 35, strength: 0.4) : ColorWheel(),
          midtoneWheel: wheelsEnabled ? ColorWheel(hue: 190, strength: 0.25) : ColorWheel(),
          shadowWheel: wheelsEnabled ? ColorWheel(hue: 285, strength: 0.5) : ColorWheel()
        )
      )
    }
    return parameters
  }

  @Test("Production renderer p95 below 33 ms over 500 current-pipeline changes")
  func productionRendererBurstBenchmark() {
    let image = Self.createRandomImage(width: Self.proxyWidth, height: Self.proxyHeight)
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create production still preview renderer")
      return
    }

    let parameters = Self.makeParameterGrid(count: Self.benchmarkIterations)
    var latenciesMs = [Double]()
    latenciesMs.reserveCapacity(Self.benchmarkIterations)
    var failedRenders = 0

    for snapshot in parameters {
      let start = ContinuousClock.now
      let image = renderer.render(parameters: snapshot, showOriginal: false)
      let elapsed = start.duration(to: .now)

      if image == nil {
        failedRenders += 1
        continue
      }
      let milliseconds = Double(elapsed.components.seconds) * 1000.0
        + Double(elapsed.components.attoseconds) / 1e15
      latenciesMs.append(milliseconds)
    }

    #expect(failedRenders == 0, "\(failedRenders) renders failed out of \(Self.benchmarkIterations)")
    guard !latenciesMs.isEmpty else { return }

    let sorted = latenciesMs.sorted()
    let p50 = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let p99 = sorted[Int(Double(sorted.count) * 0.99)]
    let mean = latenciesMs.reduce(0, +) / Double(latenciesMs.count)

    print(
      "Production renderer benchmark (\(Self.benchmarkIterations) iterations, "
        + "\(Self.proxyWidth)x\(Self.proxyHeight), curves and wheels active):"
    )
    print("  p50: \(String(format: "%.2f", p50)) ms")
    print("  p95: \(String(format: "%.2f", p95)) ms")
    print("  p99: \(String(format: "%.2f", p99)) ms")
    print("  mean: \(String(format: "%.2f", mean)) ms")

    #expect(
      p95 <= Self.p95LatencyThresholdMs,
      "p95 production renderer latency \(String(format: "%.2f", p95)) ms above \(String(format: "%.0f", Self.p95LatencyThresholdMs)) ms threshold"
    )
  }

  @Test("Production renderer handles curves and wheels across all film types")
  func productionRendererAllFilmTypes() {
    let image = Self.createRandomImage(width: 256, height: 256)
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create production still preview renderer")
      return
    }

    for filmType in FilmType.allCases {
      let parameters = ProcessingParameters(
        filmType: filmType,
        gamma: -30,
        shadows: 40,
        highlights: -30,
        temperature: 30,
        tint: -20,
        saturation: 120,
        curveEnabled: true,
        curveControlPoints: Self.curvePoints,
        highlightWheel: ColorWheel(hue: 35, strength: 0.4),
        midtoneWheel: ColorWheel(hue: 190, strength: 0.25),
        shadowWheel: ColorWheel(hue: 285, strength: 0.5)
      )
      let rendered = renderer.render(parameters: parameters, showOriginal: false)
      #expect(rendered != nil, "Production renderer failed for film type \(filmType)")
      if let rendered {
        #expect(rendered.width > 0)
        #expect(rendered.height > 0)
      }
    }
  }

  @Test("Production renderer stays visually equivalent to authoritative CPU pipeline")
  func productionRendererMatchesAuthoritativePipeline() {
    let image = Self.createRandomImage(width: 128, height: 96)
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create production still preview renderer")
      return
    }
    let redCurve = [
      CurvePoint(input: 0, output: 0.05),
      CurvePoint(input: 0.45, output: 0.7),
      CurvePoint(input: 1, output: 0.95),
    ]
    let greenCurve = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.3),
      CurvePoint(input: 1, output: 1),
    ]
    let blueCurve = [
      CurvePoint(input: 0, output: 0.1),
      CurvePoint(input: 0.65, output: 0.45),
      CurvePoint(input: 1, output: 1),
    ]
    let parameters = ProcessingParameters(
      flip: true,
      rotation: 1,
      filmType: .colourNegative,
      gamma: 35,
      shadows: 40,
      highlights: -30,
      temperature: 45,
      tint: -25,
      saturation: 145,
      curveEnabled: true,
      curveControlPoints: Self.curvePoints,
      redCurveEnabled: true,
      redCurveControlPoints: redCurve,
      greenCurveEnabled: true,
      greenCurveControlPoints: greenCurve,
      blueCurveEnabled: true,
      blueCurveControlPoints: blueCurve,
      highlightWheel: ColorWheel(hue: 35, strength: 0.4),
      midtoneWheel: ColorWheel(hue: 190, strength: 0.25),
      shadowWheel: ColorWheel(hue: 285, strength: 0.5)
    )

    guard
      let gpu = renderer.render(parameters: parameters, showOriginal: false),
      let cpu = FilmProcessing.correctedPreview(image: image, parameters: parameters)
        .makePreviewCGImage(),
      let gpuPixels = rgbaPixels(gpu),
      let cpuPixels = rgbaPixels(cpu)
    else {
      #expect(Bool(false), "Could not render or extract comparison pixels")
      return
    }

    #expect(gpu.width == cpu.width)
    #expect(gpu.height == cpu.height)
    #expect(gpuPixels.count == cpuPixels.count)
    var maxDifference = 0
    for index in gpuPixels.indices {
      maxDifference = max(maxDifference, abs(Int(gpuPixels[index]) - Int(cpuPixels[index])))
    }
    #expect(maxDifference <= 2, "Production renderer differs from CPU by \(maxDifference)/255")
  }

  private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
    guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
      return nil
    }
    return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
  }
}
