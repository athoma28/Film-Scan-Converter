import FilmScanEngine
import Foundation
import Testing

@Suite("CPU pipeline performance")
struct CPUPipelineBenchmarkTests {
  private static let benchmarkIterations = 200
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

  private static func createSolidImage(width: Int, height: Int, value: UInt16) -> UInt16Image {
    UInt16Image(
      width: width, height: height, channels: 3,
      pixels: [UInt16](repeating: value, count: width * height * 3)
    )
  }

  @Test(
    "CPU correctedPreview burst benchmark (power-law, all adjustments)",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PERFORMANCE_TESTS"] == "1",
      "set RUN_PERFORMANCE_TESTS=1 to run the CPU benchmark")
  )
  func cpuPowerLawBurstBenchmark() {
    let image = Self.createRandomImage(width: Self.proxyWidth, height: Self.proxyHeight)
    var params: [ProcessingParameters] = []
    params.reserveCapacity(Self.benchmarkIterations)
    let filmTypes: [FilmType] = [.colourNegative, .blackAndWhiteNegative, .slide, .cropOnly]
    let temperatures = [0, -50, 25, 80]
    let tints = [0, -30, 15, 60]
    let gammas = [0, -35, 15, 40]
    let shadows = [0, 30, 60, -30]
    let highlights = [0, -30, -45, 30]
    let saturations = [100, 75, 150, 0, 200]

    var rng = SystemRandomNumberGenerator()
    for index in 0..<Self.benchmarkIterations {
      let curvesEnabled = index % 3 != 0
      let wheelsEnabled = index % 4 != 0
      var p = ProcessingParameters(
        filmType: filmTypes.randomElement(using: &rng)!,
        gamma: gammas.randomElement(using: &rng)!,
        shadows: shadows.randomElement(using: &rng)!,
        highlights: highlights.randomElement(using: &rng)!,
        temperature: temperatures.randomElement(using: &rng)!,
        tint: tints.randomElement(using: &rng)!,
        saturation: saturations.randomElement(using: &rng)!,
        curveEnabled: curvesEnabled,
        curveControlPoints: curvesEnabled ? Self.curvePoints : [],
        highlightWheel: wheelsEnabled ? ColorWheel(hue: 35, strength: 0.4) : ColorWheel(),
        midtoneWheel: wheelsEnabled ? ColorWheel(hue: 190, strength: 0.25) : ColorWheel(),
        shadowWheel: wheelsEnabled ? ColorWheel(hue: 285, strength: 0.5) : ColorWheel()
      )
      p.filmNegativeParams.measuredMedians = BGRChannelValues(blue: 20_000, green: 26_000, red: 32_000)
      params.append(p)
    }

    var latenciesMs = [Double]()
    latenciesMs.reserveCapacity(Self.benchmarkIterations)

    for snapshot in params {
      let start = ContinuousClock.now
      let result = FilmProcessing.correctedPreview(image: image, parameters: snapshot)
      let elapsed = start.duration(to: .now)
      let ms = Double(elapsed.components.seconds) * 1000.0
        + Double(elapsed.components.attoseconds) / 1e15
      latenciesMs.append(ms)

      if result.pixels.isEmpty {
        Issue.record("Empty result")
      }
    }

    let sorted = latenciesMs.sorted()
    let p50 = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let p99 = sorted[Int(Double(sorted.count) * 0.99)]
    let mean = latenciesMs.reduce(0, +) / Double(latenciesMs.count)

    print(
      "CPU power-law benchmark (\(Self.benchmarkIterations) iterations, "
        + "\(Self.proxyWidth)x\(Self.proxyHeight)):")
    print("  p50: \(String(format: "%.2f", p50)) ms")
    print("  p95: \(String(format: "%.2f", p95)) ms")
    print("  p99: \(String(format: "%.2f", p99)) ms")
    print("  mean: \(String(format: "%.2f", mean)) ms")
  }

  @Test(
    "CPU density pipeline burst benchmark",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PERFORMANCE_TESTS"] == "1",
      "set RUN_PERFORMANCE_TESTS=1 to run the CPU density benchmark")
  )
  func cpuDensityBurstBenchmark() {
    let image = Self.createSolidImage(width: Self.proxyWidth, height: Self.proxyHeight, value: 30_000)
    let flatField = Self.createSolidImage(width: Self.proxyWidth, height: Self.proxyHeight, value: 60_000)

    var params: [ProcessingParameters] = []
    params.reserveCapacity(Self.benchmarkIterations)
    let saturations = [100, 75, 150, 0, 200]

    var rng = SystemRandomNumberGenerator()
    for index in 0..<Self.benchmarkIterations {
      let curvesEnabled = index % 3 != 0
      let wheelsEnabled = index % 4 != 0
      var p = ProcessingParameters(
        filmType: .colourNegative,
        saturation: saturations.randomElement(using: &rng)!,
        curveEnabled: curvesEnabled,
        curveControlPoints: curvesEnabled ? Self.curvePoints : [],
        highlightWheel: wheelsEnabled ? ColorWheel(hue: 35, strength: 0.4) : ColorWheel(),
        midtoneWheel: wheelsEnabled ? ColorWheel(hue: 190, strength: 0.25) : ColorWheel(),
        shadowWheel: wheelsEnabled ? ColorWheel(hue: 285, strength: 0.5) : ColorWheel()
      )
      p.densityPipelineEnabled = true
      p.densityBaseDensity = BGRChannelValues(blue: 0.15, green: 0.12, red: 0.18)
      params.append(p)
    }

    var latenciesMs = [Double]()
    latenciesMs.reserveCapacity(Self.benchmarkIterations)

    for snapshot in params {
      let start = ContinuousClock.now
      let result = FilmProcessing.correctedPreview(
        image: image, parameters: snapshot, flatField: flatField)
      let elapsed = start.duration(to: .now)
      let ms = Double(elapsed.components.seconds) * 1000.0
        + Double(elapsed.components.attoseconds) / 1e15
      latenciesMs.append(ms)

      if result.pixels.isEmpty {
        Issue.record("Empty result")
      }
    }

    let sorted = latenciesMs.sorted()
    let p50 = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let p99 = sorted[Int(Double(sorted.count) * 0.99)]
    let mean = latenciesMs.reduce(0, +) / Double(latenciesMs.count)

    print(
      "CPU density benchmark (\(Self.benchmarkIterations) iterations, "
        + "\(Self.proxyWidth)x\(Self.proxyHeight)):")
    print("  p50: \(String(format: "%.2f", p50)) ms")
    print("  p95: \(String(format: "%.2f", p95)) ms")
    print("  p99: \(String(format: "%.2f", p99)) ms")
    print("  mean: \(String(format: "%.2f", mean)) ms")
  }

  @Test(
    "Export CGImage16 creation benchmark",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PERFORMANCE_TESTS"] == "1",
      "set RUN_PERFORMANCE_TESTS=1 to run the export benchmark")
  )
  func exportCGImage16Benchmark() {
    let iterations = 50
    let image = Self.createRandomImage(width: Self.proxyWidth, height: Self.proxyHeight)
    var latenciesMs = [Double]()

    for _ in 0..<iterations {
      let start = ContinuousClock.now
      let cgImage = image.makeExportCGImage16()
      let elapsed = start.duration(to: .now)
      let ms = Double(elapsed.components.seconds) * 1000.0
        + Double(elapsed.components.attoseconds) / 1e15
      latenciesMs.append(ms)

      if cgImage == nil {
        Issue.record("CGImage creation failed")
      }
    }

    let sorted = latenciesMs.sorted()
    let p50 = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let mean = latenciesMs.reduce(0, +) / Double(latenciesMs.count)

    print(
      "CGImage16 export benchmark (\(iterations) iterations, "
        + "\(Self.proxyWidth)x\(Self.proxyHeight)):")
    print("  p50: \(String(format: "%.2f", p50)) ms")
    print("  p95: \(String(format: "%.2f", p95)) ms")
    print("  mean: \(String(format: "%.2f", mean)) ms")
  }

  @Test(
    "DNG writer buildImageData benchmark",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PERFORMANCE_TESTS"] == "1",
      "set RUN_PERFORMANCE_TESTS=1 to run the DNG benchmark")
  )
  func dngWriterBenchmark() {
    let iterations = 20
    let image = Self.createRandomImage(width: 3840, height: 2160)
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("DNGWriterBenchmark_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let url = tempDir.appendingPathComponent("bench.dng")
    let params = ExportParameters(format: .dng)
    var latenciesMs = [Double]()

    for _ in 0..<iterations {
      let start = ContinuousClock.now
      try? image.write(to: url, format: .dng, parameters: params)
      let elapsed = start.duration(to: .now)
      let ms = Double(elapsed.components.seconds) * 1000.0
        + Double(elapsed.components.attoseconds) / 1e15
      latenciesMs.append(ms)
    }

    let sorted = latenciesMs.sorted()
    let p50 = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let mean = latenciesMs.reduce(0, +) / Double(latenciesMs.count)

    print(
      "DNG writer benchmark (\(iterations) iterations, 3840x2160):")
    print("  p50: \(String(format: "%.2f", p50)) ms")
    print("  p95: \(String(format: "%.2f", p95)) ms")
    print("  mean: \(String(format: "%.2f", mean)) ms")
  }
}
