import Dispatch
import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Exact Natural B&W lookup")
struct NaturalMonochromeLookupTests {
  @Test("Both Natural profiles match the ordinary renderer across gray codes and varied BGR")
  func exactOutput() {
    let varied = variedImage(width: 256, height: 256)
    let ramp = UInt16Image(
      width: 256, height: 256, channels: 3,
      pixels: (0...65_535).flatMap { [UInt16](repeating: UInt16($0), count: 3) })
    for profile in [CalibratedMonochromeProfile.generic, .shanghaiGP3] {
      let cache = NaturalMonochromeLookupCache()
      for scenario in 0..<6 {
        let parameters = parameters(profile: profile, scenario: scenario)
        for source in [ramp, varied] {
          let reference = ordinary(source, parameters)
          let actual = cache.apply(image: source, parameters: parameters)
          #expect(actual == reference, "Profile \(profile), tone scenario \(scenario)")
        }
      }
    }
  }

  @Test("Zero-light masking uses max original channel and runs after all tone operations")
  func zeroLightMask() {
    let source = UInt16Image(
      width: 6, height: 1, channels: 3,
      pixels: [
        0, 0, 0, 1_024, 1_024, 1_024, 1_025, 0, 0,
        0, 1_025, 0, 0, 0, 1_025, 65_535, 65_535, 65_535,
      ])
    var parameters = parameters()
    parameters.curveEnabled = true
    parameters.curveControlPoints = [.init(input: 0, output: 0.2), .init(input: 1, output: 0.8)]
    let actual = NaturalMonochromeLookupCache().apply(image: source, parameters: parameters)
    #expect(actual == ordinary(source, parameters))
    #expect(actual.pixels.prefix(6).allSatisfy { $0 == .max })
    #expect(actual.pixels.dropFirst(6).allSatisfy { $0 < .max })
  }

  @Test("Lookup follows automatic crop, orientation, straighten, and manual crop")
  func geometryOrder() {
    let source = variedImage(width: 192, height: 128)
    for perspective in [false, true] {
      var parameters = parameters(scenario: 1)
      parameters.cropRect = RotatedRect(
        centerX: 0.5, centerY: 0.5, width: 0.92, height: 0.85, angle: 3)
      if perspective {
        parameters.perspectiveCrop = PerspectiveCrop(
          topLeft: .init(x: 0.05, y: 0.07), topRight: .init(x: 0.92, y: 0.02),
          bottomRight: .init(x: 0.95, y: 0.91), bottomLeft: .init(x: 0.02, y: 0.96))
      }
      parameters.borderCrop = 3
      parameters.rotation = 1
      parameters.flip = true
      parameters.straightenAngle = 7
      parameters.manualCrop = .init(x: 0.04, y: 0.03, width: 0.9, height: 0.93)
      var geometry = parameters
      geometry.filmType = .cropOnly
      let transformed = FilmProcessing.correctedPreview(image: source, parameters: geometry)
      let actual = NaturalMonochromeLookupCache().apply(image: transformed, parameters: parameters)
      #expect(actual == ordinary(source, parameters))
    }
  }

  @Test(
    "Large images dispatch to lookup while small and incompatible inputs retain ordinary rendering")
  func dispatch() {
    let small = variedImage(width: 8, height: 8)
    let parameters = parameters(scenario: 1)
    #expect(!NaturalMonochromeLookupCache.shouldUse(image: small, parameters: parameters))
    let large = variedImage(width: 1_000, height: 1_000)
    #expect(NaturalMonochromeLookupCache.shouldUse(image: large, parameters: parameters))
    #expect(
      FilmProcessing.correctedPreview(image: large, parameters: parameters)
        == ordinary(large, parameters))

    for filmType in [FilmType.colourNegative, .slide, .cropOnly] {
      var incompatible = parameters
      incompatible.filmType = filmType
      #expect(!NaturalMonochromeLookupCache.isEligible(image: small, parameters: incompatible))
    }
    for rendering in [FilmNegativeRendering.powerLaw, .calibratedColor, .densityPrint] {
      var incompatible = parameters
      incompatible.filmNegativeParams.rendering = rendering
      #expect(!NaturalMonochromeLookupCache.isEligible(image: small, parameters: incompatible))
    }
    var disabled = parameters
    disabled.filmNegativeParams.enabled = false
    #expect(!NaturalMonochromeLookupCache.isEligible(image: small, parameters: disabled))
    let mono = UInt16Image(width: 1, height: 1, channels: 1, pixels: [32_768])
    #expect(!NaturalMonochromeLookupCache.isEligible(image: mono, parameters: parameters))
  }

  @Test(
    "Cache reuses only actual inputs, invalidates tone and inversion independently, and stays bounded"
  )
  func cacheInvalidation() {
    let cache = NaturalMonochromeLookupCache()
    var parameters = parameters(scenario: 1)
    let initial = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.inversionBuilds == 1)
    #expect(cache.statistics.toneBuilds == 1)

    // Hidden/inherited controls do not affect B&W, nor do red/blue medians.
    parameters.filmNegativeParams.measuredMedians = .init(blue: 3, green: 28_000, red: 65_535)
    parameters.filmNegativeParams.redRatio = 3.4
    parameters.filmNegativeParams.greenExp = 2.8
    parameters.filmNegativeParams.blueRatio = 0.4
    parameters.photoAdjustments.schemaVersion = 99
    parameters.photoAdjustments.temperatureShiftMired = 60
    parameters.photoAdjustments.tint = -0.8
    parameters.photoAdjustments.saturation = 1
    parameters.photoAdjustments.vibrance = -1
    parameters.temperature = 80
    parameters.tint = -70
    parameters.saturation = 0
    parameters.highlightWheel = .init(hue: 130, strength: 1)
    parameters.redCurveEnabled = true
    parameters.redCurveControlPoints = [.init(input: 0, output: 1), .init(input: 1, output: 0)]
    parameters.filmDyeMixing = .init(redFromGreen: 0.5, blueFromRed: -0.3)
    parameters.gamma = 100
    parameters.highlights = -100
    parameters.shadows = 100
    parameters.rotation = 2
    #expect(cache.compiledTable(parameters: parameters) == initial)
    #expect(cache.statistics.inversionBuilds == 1)
    #expect(cache.statistics.toneBuilds == 1)
    let source = variedImage(width: 128, height: 128)
    parameters.rotation = 0
    #expect(cache.apply(image: source, parameters: parameters) == ordinary(source, parameters))

    parameters.filmNegativeParams.monochromeExposureEV += 0.25
    #expect(cache.compiledTable(parameters: parameters) != initial)
    #expect(cache.statistics.inversionBuilds == 2)
    #expect(cache.statistics.toneBuilds == 1)
    parameters.filmNegativeParams.measuredMedians = .init(blue: 3, green: 19_000, red: 65_535)
    _ = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.inversionBuilds == 3)
    #expect(cache.statistics.toneBuilds == 1)
    parameters.filmNegativeParams.calibratedMonochromeProfile = .shanghaiGP3
    _ = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.inversionBuilds == 4)
    #expect(cache.statistics.toneBuilds == 1)

    for adjustment in 1...6 {
      parameters.photoAdjustments.brightness = Double(adjustment + 3) / 20
      _ = cache.compiledTable(parameters: parameters)
      #expect(cache.apply(image: source, parameters: parameters) == ordinary(source, parameters))
    }
    #expect(cache.statistics.inversionTables == NaturalMonochromeLookupCache.inversionCapacity)
    #expect(cache.statistics.toneTables == NaturalMonochromeLookupCache.toneCapacity)
    #expect(cache.statistics.inversionBuilds == 4)
    #expect(cache.statistics.toneBuilds == 7)

    parameters.curveControlPoints[1].output += 0.05
    _ = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.toneBuilds == 8)
    parameters.curveEnabled = false
    let withoutCurve = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.toneBuilds == 9)
    parameters.curveControlPoints[1].output += 0.05
    #expect(cache.compiledTable(parameters: parameters) == withoutCurve)
    #expect(cache.statistics.toneBuilds == 9)

    parameters.photoAdjustments = .init()
    _ = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.toneBuilds == 10)
    parameters.gamma = 30
    _ = cache.compiledTable(parameters: parameters)
    #expect(cache.statistics.toneBuilds == 11)
    #expect(cache.apply(image: source, parameters: parameters) == ordinary(source, parameters))
  }

  @Test("Concurrent requests share a single table build and produce the exact result")
  func concurrentRequests() {
    let cache = NaturalMonochromeLookupCache()
    let source = variedImage(width: 64, height: 64)
    let parameters = parameters(scenario: 2)
    let expected = ordinary(source, parameters)
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      #expect(cache.apply(image: source, parameters: parameters) == expected)
    }
    #expect(cache.statistics.inversionBuilds == 1)
    #expect(cache.statistics.toneBuilds == 1)
  }

  @Test(
    "Measure retained 2MP source with ordinary, cold lookup, and warm lookup rendering",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_NATURAL_BW_LOOKUP_BENCHMARK"] == "1",
      "set RUN_NATURAL_BW_LOOKUP_BENCHMARK=1 for the release benchmark")
  )
  func benchmark() throws {
    let source = variedImage(width: 2_048, height: 1_024)
    let parameters = parameters(scenario: 1)
    func timed(_ operation: () -> UInt16Image) -> (image: UInt16Image, milliseconds: Double) {
      let start = ContinuousClock.now
      let result = operation()
      let elapsed = start.duration(to: .now).components
      return (result, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }
    let reference = timed { ordinary(source, parameters) }
    let cache = NaturalMonochromeLookupCache()
    let cold = timed { cache.apply(image: source, parameters: parameters) }
    #expect(cold.image == reference.image)
    var warmSamples: [Double] = []
    for _ in 0..<3 {
      let warm = timed { cache.apply(image: source, parameters: parameters) }
      #expect(warm.image == reference.image)
      warmSamples.append(warm.milliseconds)
    }
    let differentComponents = zip(cold.image.pixels, reference.image.pixels).reduce(0) {
      $0 + ($1.0 == $1.1 ? 0 : 1)
    }
    let report: [String: Any] = [
      "case": "natural-bw-2mp-semantic-tone-master-curve",
      "pixelCount": source.width * source.height,
      "ordinaryMillisecondsOneSample": reference.milliseconds,
      "coldLookupMillisecondsOneSample": cold.milliseconds,
      "warmLookupMilliseconds": warmSamples,
      "differentComponents": differentComponents,
      "lookupDispatchMinimumPixels": NaturalMonochromeLookupCache.minimumPixelCount,
      "inversionTableBuilds": cache.statistics.inversionBuilds,
      "toneTableBuilds": cache.statistics.toneBuilds,
      "composedTableBytes": 65_536 * 3 * MemoryLayout<UInt16>.stride,
      "avoidedFullFrameDoubleBufferBytes": source.pixels.count * MemoryLayout<Double>.stride,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("NATURAL_BW_LOOKUP \(String(decoding: data, as: UTF8.self))")
  }

  private func ordinary(_ source: UInt16Image, _ parameters: ProcessingParameters) -> UInt16Image {
    FilmProcessing.correctedPreviewPowerLaw(
      image: source, parameters: parameters, useNaturalMonochromeLookup: false)
  }

  private func parameters(
    profile: CalibratedMonochromeProfile = .generic, scenario: Int = 0
  ) -> ProcessingParameters {
    var parameters = ProcessingParameters(
      filmType: .blackAndWhiteNegative, filmNegativeParams: .blackAndWhite)
    parameters.filmNegativeParams.calibratedMonochromeProfile = profile
    parameters.filmNegativeParams.measuredMedians = .init(blue: 29_000, green: 28_000, red: 27_000)
    parameters.filmNegativeParams.monochromeExposureEV = 0.15
    switch scenario {
    case 1:
      parameters.photoAdjustments = .init(
        exposureEV: 0.5, brightness: 0.1, contrast: 0.3, highlights: -0.3, shadows: 0.2)
    case 2:
      parameters.photoAdjustments = .init(
        exposureEV: -1.2, brightness: -0.05, contrast: -0.7, highlights: 0.8, shadows: -0.9)
    case 3:
      parameters.photoAdjustments = .init(exposureEV: 4, brightness: 1, contrast: 1)
    case 4:
      parameters.photoAdjustments = .init(exposureEV: -4, brightness: -1, contrast: -1)
    case 5:
      parameters.gamma = 20
      parameters.shadows = -15
      parameters.highlights = 10
    default:
      parameters.filmNegativeParams.measuredMedians = nil
      parameters.filmNegativeParams.monochromeExposureEV = 0
    }
    if scenario == 1 || scenario == 2 || scenario == 5 {
      parameters.curveEnabled = true
      parameters.curveControlPoints = [
        .init(input: 0, output: 0.02), .init(input: 0.3, output: 0.25),
        .init(input: 0.7, output: 0.8), .init(input: 1, output: 0.95),
      ]
    }
    return parameters
  }

  private func variedImage(width: Int, height: Int) -> UInt16Image {
    var generator: UInt64 = 20_260_913
    var pixels = [UInt16]()
    pixels.reserveCapacity(width * height * 3)
    for index in 0..<(width * height * 3) {
      generator = generator &* 6_364_136_223_846_793_005 &+ 1
      pixels.append(index < 3_078 ? UInt16(index / 3) : UInt16(truncatingIfNeeded: generator >> 32))
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }
}
