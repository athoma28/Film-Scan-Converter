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

  private static func createDeterministicImage(width: Int, height: Int) -> UInt16Image {
    let componentCount = width * height * 3
    var pixels = [UInt16]()
    pixels.reserveCapacity(componentCount)
    // Stable seed from the commit that exposed the source-conversion drift.
    var state: UInt64 = 0x67CD_9321_9D23_E551
    for _ in 0..<componentCount {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      pixels.append(UInt16(truncatingIfNeeded: state >> 32))
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
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

  @Test(
    "Production renderer p95 below 33 ms over 500 current-pipeline changes",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PERFORMANCE_TESTS"] == "1",
      "set RUN_PERFORMANCE_TESTS=1 to run the 500-render benchmark")
  )
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
    let image = Self.createDeterministicImage(width: 128, height: 96)
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

  @Test("Production renderer renders zero-light negative pixels as neutral white")
  func productionRendererNeutralizesZeroLight() {
    let image = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [0, 128, 256, 512, 512, 512]
    )
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create production still preview renderer")
      return
    }
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = BGRChannelValues(blue: 20_000, green: 20_000, red: 20_000)
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      photoAdjustments: PhotoAdjustmentParameters(brightness: 0.5)
    )

    guard let rendered = renderer.render(parameters: parameters, showOriginal: false),
      let pixels = rgbaPixels(rendered)
    else {
      #expect(Bool(false), "Could not render or extract sensor-black comparison pixels")
      return
    }

    #expect(Array(pixels[0..<3]) == [255, 255, 255])
    #expect(pixels[4..<7].contains { $0 > 0 })
  }

  @Test("Production renderer matches CPU across parameter grid")
  func productionRendererMatchesCPUParameterGrid() {
    let image = Self.createDeterministicImage(width: 64, height: 48)
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create production still preview renderer")
      return
    }

    let curvePoints = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.3, output: 0.15),
      CurvePoint(input: 0.7, output: 0.85),
      CurvePoint(input: 1, output: 1),
    ]
    var protectedFilmNegative = FilmNegativeParams.colourNegative
    protectedFilmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    let protectedWarmVibrance = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(
        temperatureShiftMired: 55,
        tint: -0.3,
        saturation: 0.4,
        vibrance: 0.7
      )
    )
    let protectedGamutEdge = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(saturation: 0.8, vibrance: 0.8)
    )
    let toneExposurePlus = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(exposureEV: 1)
    )
    let toneExposureMinus = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(exposureEV: -1)
    )
    let toneContrastPlus = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(contrast: 0.5)
    )
    let toneHighlightsRecover = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(highlights: 0.5)
    )
    let toneShadowsLift = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(shadows: 0.5)
    )
    let toneFullCombo = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: protectedFilmNegative,
      photoAdjustments: PhotoAdjustmentParameters(
        exposureEV: 0.5,
        brightness: 0.2,
        contrast: 0.3,
        highlights: -0.3,
        shadows: 0.3
      )
    )

    let configs: [(String, ProcessingParameters)] = [
      ("neutral-neg", ProcessingParameters(filmType: .colourNegative)),
      ("neutral-slide", ProcessingParameters(filmType: .slide)),
      ("warm", ProcessingParameters(filmType: .colourNegative, temperature: 50, tint: -30)),
      ("cool", ProcessingParameters(filmType: .colourNegative, temperature: -50, tint: 30)),
      ("gamma-up", ProcessingParameters(filmType: .colourNegative, gamma: 40)),
      ("gamma-down", ProcessingParameters(filmType: .colourNegative, gamma: -35)),
      ("shadows-boost", ProcessingParameters(filmType: .colourNegative, shadows: 60)),
      ("highlights-pull", ProcessingParameters(filmType: .colourNegative, highlights: -45)),
      ("sat-boost", ProcessingParameters(filmType: .colourNegative, saturation: 150)),
      ("sat-zero", ProcessingParameters(filmType: .colourNegative, saturation: 0)),
      ("exposure-combo", ProcessingParameters(
        filmType: .colourNegative, gamma: -35, shadows: 60, highlights: -45)),
      ("wb-combo", ProcessingParameters(
        filmType: .colourNegative, temperature: 65, tint: -40, saturation: 130)),
      ("protected-warm-vibrance", protectedWarmVibrance),
      ("protected-gamut-edge", protectedGamutEdge),
      ("tone-exposure-plus", toneExposurePlus),
      ("tone-exposure-minus", toneExposureMinus),
      ("tone-contrast-plus", toneContrastPlus),
      ("tone-highlights-recover", toneHighlightsRecover),
      ("tone-shadows-lift", toneShadowsLift),
      ("tone-full-combo", toneFullCombo),
      ("curve-only", ProcessingParameters(
        filmType: .colourNegative, curveEnabled: true, curveControlPoints: curvePoints)),
      ("wheels-only", ProcessingParameters(
        filmType: .colourNegative,
        highlightWheel: ColorWheel(hue: 35, strength: 0.4),
        midtoneWheel: ColorWheel(hue: 190, strength: 0.25),
        shadowWheel: ColorWheel(hue: 285, strength: 0.5))),
      ("curves-and-wheels", ProcessingParameters(
        filmType: .colourNegative,
        curveEnabled: true, curveControlPoints: curvePoints,
        highlightWheel: ColorWheel(hue: 35, strength: 0.4),
        midtoneWheel: ColorWheel(hue: 190, strength: 0.25),
        shadowWheel: ColorWheel(hue: 285, strength: 0.5))),
      ("full-combo", ProcessingParameters(
        filmType: .colourNegative,
        gamma: 35, shadows: 40, highlights: -30,
        temperature: 45, tint: -25, saturation: 145,
        curveEnabled: true, curveControlPoints: curvePoints,
        highlightWheel: ColorWheel(hue: 35, strength: 0.4),
        midtoneWheel: ColorWheel(hue: 190, strength: 0.25),
        shadowWheel: ColorWheel(hue: 285, strength: 0.5))),
      ("per-channel-curves", ProcessingParameters(
        filmType: .colourNegative,
        redCurveEnabled: true,
        redCurveControlPoints: [CurvePoint(input: 0, output: 0.05), CurvePoint(input: 0.45, output: 0.7), CurvePoint(input: 1, output: 0.95)],
        greenCurveEnabled: true,
        greenCurveControlPoints: [CurvePoint(input: 0, output: 0), CurvePoint(input: 0.5, output: 0.3), CurvePoint(input: 1, output: 1)],
        blueCurveEnabled: true,
        blueCurveControlPoints: [CurvePoint(input: 0, output: 0.1), CurvePoint(input: 0.65, output: 0.45), CurvePoint(input: 1, output: 1)]
      )),
      ("slide-curves", ProcessingParameters(
        filmType: .slide, curveEnabled: true, curveControlPoints: curvePoints)),
      ("slide-wheels", ProcessingParameters(
        filmType: .slide,
        highlightWheel: ColorWheel(hue: 120, strength: 0.3),
        midtoneWheel: ColorWheel(hue: 60, strength: 0.2),
        shadowWheel: ColorWheel(hue: 300, strength: 0.4))),
    ]

    var maxDiff = 0
    var worstName = ""
    for (name, parameters) in configs {
      guard
        let gpu = renderer.render(parameters: parameters, showOriginal: false),
        let cpu = FilmProcessing.correctedPreview(image: image, parameters: parameters)
          .makePreviewCGImage(),
        let gpuPixels = rgbaPixels(gpu),
        let cpuPixels = rgbaPixels(cpu)
      else {
        #expect(Bool(false), "Render failed for \(name)")
        continue
      }

      #expect(gpu.width == cpu.width, "\(name): width mismatch")
      #expect(gpu.height == cpu.height, "\(name): height mismatch")
      #expect(gpuPixels.count == cpuPixels.count, "\(name): pixel count mismatch")

      var comboMax = 0
      for index in gpuPixels.indices {
        let diff = abs(Int(gpuPixels[index]) - Int(cpuPixels[index]))
        comboMax = max(comboMax, diff)
      }
      if comboMax > maxDiff {
        maxDiff = comboMax
        worstName = name
      }
    }

    #expect(maxDiff <= 2,
      "Production renderer max diff \(maxDiff)/255 at '\(worstName)'; should be <= 2 for visual equivalence")
  }

  @Test("Tone controls match CPU within 2/255 across representative parameter grid")
  func toneControlsMatchCPU() {
    let image = Self.createDeterministicImage(width: 64, height: 48)
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create production still preview renderer")
      return
    }

    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    var blackAndWhiteNegative = FilmNegativeParams.blackAndWhite
    blackAndWhiteNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)

    let configs: [(String, ProcessingParameters)] = [
      ("exposure+1", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(exposureEV: 1))),
      ("exposure-1", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(exposureEV: -1))),
      ("brightness+0.5", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(brightness: 0.5))),
      ("brightness-0.5", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(brightness: -0.5))),
      ("contrast+0.5", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(contrast: 0.5))),
      ("contrast-0.5", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(contrast: -0.5))),
      ("highlights+0.5", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(highlights: 0.5))),
      ("shadows+0.5", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(shadows: 0.5))),
      ("tone-combo", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(
          exposureEV: 0.5, brightness: 0.2, contrast: 0.3,
          highlights: -0.3, shadows: 0.3))),
      ("tone-with-color", ProcessingParameters(
        filmType: .colourNegative, filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(
          exposureEV: 0.5, contrast: 0.3,
          temperatureShiftMired: 20, tint: -0.2, saturation: 0.3))),
      ("slide-exposure", ProcessingParameters(
        filmType: .slide,
        photoAdjustments: PhotoAdjustmentParameters(exposureEV: 0.5))),
      ("bw-negative-exposure", ProcessingParameters(
        filmType: .blackAndWhiteNegative, filmNegativeParams: blackAndWhiteNegative,
        photoAdjustments: PhotoAdjustmentParameters(exposureEV: -0.5))),
    ]

    var maxDiff = 0
    var worstName = ""
    for (name, parameters) in configs {
      guard
        let gpu = renderer.render(parameters: parameters, showOriginal: false),
        let cpu = FilmProcessing.correctedPreview(image: image, parameters: parameters)
          .makePreviewCGImage(),
        let gpuPixels = rgbaPixels(gpu),
        let cpuPixels = rgbaPixels(cpu)
      else {
        #expect(Bool(false), "Render failed for \(name)")
        continue
      }

      #expect(gpu.width == cpu.width, "\(name): width mismatch")
      #expect(gpu.height == cpu.height, "\(name): height mismatch")
      #expect(gpuPixels.count == cpuPixels.count, "\(name): pixel count mismatch")

      var comboMax = 0
      for index in gpuPixels.indices {
        let diff = abs(Int(gpuPixels[index]) - Int(cpuPixels[index]))
        comboMax = max(comboMax, diff)
      }
      if comboMax > maxDiff {
        maxDiff = comboMax
        worstName = name
      }
    }

    #expect(maxDiff <= 2,
      "Tone control GPU renderer max diff \(maxDiff)/255 at '\(worstName)'; should be <= 2 for visual equivalence")
  }

  private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
    guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
      return nil
    }
    return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
  }
}
