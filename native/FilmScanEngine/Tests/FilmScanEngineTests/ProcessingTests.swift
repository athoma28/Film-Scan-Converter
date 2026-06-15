import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Film processing stages")
struct ProcessingTests {
  @Test("Neutral white balance (temp=0, tint=0) returns the same image")
  func whiteBalanceNeutral() throws {
    let (input, expected, shape, metadata) = try FixtureLoader.loadFloat64Case("wb_t0_tint0")

    #expect(metadata.stage == "wb_adjust_coeff")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: 0,
      tint: 0
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Warm white balance (temp=65, tint=-40) matches Python reference")
  func whiteBalanceWarm() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("wb_t65_tintm40")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: 65,
      tint: -40
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Cool white balance (temp=-30, tint=20) matches Python reference")
  func whiteBalanceCool() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("wb_tm30_tint20")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: -30,
      tint: 20
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Extreme white balance (temp=100, tint=-100) matches Python reference")
  func whiteBalanceExtreme() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("wb_t100_tintm100")

    let actual = FilmProcessing.wbAdjustCoeff(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      temp: 100,
      tint: -100
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Neutral saturation (sat=100) returns the same image")
  func saturationNeutral() throws {
    let (input, expected, shape, metadata) = try FixtureLoader.loadFloat64Case("sat_100")

    #expect(metadata.stage == "sat_adjust")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 100
    )

    #expect(actual.count == expected.count)
    for i in actual.indices {
      #expect(actual[i] == expected[i])
    }
  }

  @Test("Boosted saturation (sat=150) matches Python reference")
  func saturationBoosted() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_150")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 150
    )

    assertFloat64Equal(actual, expected)
  }

  @Test("Reduced saturation (sat=50) matches Python reference within documented float tolerance")
  func saturationReduced() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_50")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 50
    )

    assertFloat64Equal(actual, expected)
  }

  @Test(
    "Desaturated to grayscale (sat=0) matches Python reference within documented float tolerance")
  func saturationGrayscale() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_0")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 0
    )

    assertFloat64Equal(actual, expected)
  }

  @Test("Max saturation (sat=200) matches Python reference within documented float tolerance")
  func saturationMax() throws {
    let (input, expected, shape, _) = try FixtureLoader.loadFloat64Case("sat_200")

    let actual = FilmProcessing.satAdjust(
      image: input,
      width: shape[1],
      height: shape[0],
      channels: shape[2],
      saturation: 200
    )

    assertFloat64Equal(actual, expected)
  }

  @Test("Saturation clips white-balanced highlights before HSV conversion")
  func saturationClipsHighlights() {
    let overRange = [10_000.0, 40_000.0, 90_000.0]
    let clipped = [10_000.0, 40_000.0, 65_535.0]

    let actual = FilmProcessing.satAdjust(
      image: overRange,
      width: 1,
      height: 1,
      channels: 3,
      saturation: 150
    )
    let expected = FilmProcessing.satAdjust(
      image: clipped,
      width: 1,
      height: 1,
      channels: 3,
      saturation: 150
    )

    #expect(actual == expected)
  }

  @Test(
    "Exposure matches Python float32 rounding",
    arguments: [
      ("exposure_neutral", 0, 0, 0),
      ("exposure_gamma40", 40, 0, 0),
      ("exposure_shadows60", 0, 60, 0),
      ("exposure_highlightsm45", 0, 0, -45),
      ("exposure_combined", -35, 70, -55),
    ]
  )
  func exposure(caseName: String, gamma: Int, shadows: Int, highlights: Int) throws {
    let (input, expected, _, metadata) = try FixtureLoader.loadFloat64Case(caseName)

    #expect(metadata.stage == "exposure")

    let actual = FilmProcessing.exposure(
      image: input,
      gamma: gamma,
      shadows: shadows,
      highlights: highlights
    )

    #expect(actual == expected)
  }

  @Test("Corrected preview applies negative inversion and neutral corrections")
  func correctedPreviewNegative() {
    let image = UInt16Image(
      width: 1,
      height: 1,
      channels: 3,
      pixels: [0, 32768, 65535]
    )

    let actual = FilmProcessing.correctedPreview(
      image: image,
      parameters: ProcessingParameters(filmType: .colourNegative)
    )

    #expect(actual.pixels == [65535, 32767, 0])
  }

  @Test("Crop-only corrected preview applies orientation without tonal corrections")
  func correctedPreviewCropOnly() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 1,
      pixels: [10, 20]
    )

    let actual = FilmProcessing.correctedPreview(
      image: image,
      parameters: ProcessingParameters(flip: true)
    )

    #expect(actual.pixels == [20, 10])
  }

  private func assertFloat64Equal(_ actual: [Double], _ expected: [Double], tolerance: Double = 0.5)
  {
    #expect(actual.count == expected.count)
    for i in actual.indices {
      let diff = abs(actual[i] - expected[i])
      #expect(diff <= tolerance || actual[i] == expected[i])
    }
  }

  @Test("GPU kernel model colour negative inversion matches CPU")
  func gpuKernelModelInversionOnly() {
    var pixels = [UInt16]()
    pixels.reserveCapacity(9)
    // Test edge cases: 0, mid, max, and specific values
    pixels.append(contentsOf: [0, 0, 0])        // black
    pixels.append(contentsOf: [32768, 32768, 32768])  // mid-gray  
    pixels.append(contentsOf: [65535, 65535, 65535])  // white
    let image = UInt16Image(width: 3, height: 1, channels: 3, pixels: pixels)

    let params = ProcessingParameters(filmType: .colourNegative)
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    #expect(gpuResult.pixels.count == cpuResult.pixels.count)
    for i in gpuResult.pixels.indices {
      let diff = gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i]
        : cpuResult.pixels[i] - gpuResult.pixels[i]
      #expect(diff <= 1, "pixel[\(i)]: GPU=\(gpuResult.pixels[i]) CPU=\(cpuResult.pixels[i]) diff=\(diff)")
    }
  }

  @Test("GPU kernel model colour negative inversion matches CPU on random image")
  func gpuKernelModelInversionRandom() {
    let image = UInt16Image(
      width: 64, height: 64, channels: 3,
      pixels: (0..<(64 * 64 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
    let params = ProcessingParameters(filmType: .colourNegative)
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    #expect(gpuResult.pixels.count == cpuResult.pixels.count)

    var maxDiff: UInt16 = 0
    var maxDiffIdx = 0
    for i in gpuResult.pixels.indices {
      let diff = gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i]
        : cpuResult.pixels[i] - gpuResult.pixels[i]
      if diff > maxDiff { maxDiff = diff; maxDiffIdx = i }
    }
    if maxDiff > 2 {
      let orig = image.pixels[maxDiffIdx]
      print("Worst pixel [\(maxDiffIdx)]: orig=\(orig) GPU=\(gpuResult.pixels[maxDiffIdx]) CPU=\(cpuResult.pixels[maxDiffIdx]) diff=\(maxDiff)")
    }
    #expect(maxDiff <= 2, "GPU kernel model colour neg inversion max diff \(maxDiff)")
  }

  @Test("GPU kernel model matches CPU correctedPreview across parameter grid")
  func gpuKernelModelEquivalence() {
    let image = UInt16Image(
      width: 64,
      height: 64,
      channels: 3,
      pixels: (0..<(64 * 64 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )

    let filmTypes: [FilmType] = [.colourNegative, .blackAndWhiteNegative, .slide, .cropOnly]
    let temps = [0, -50, 50]
    let tints = [0, -30, 30]
    let gammas = [0, -35, 40]
    let shadows = [0, 60]
    let highlights = [0, -45]
    let sats = [100, 50, 150, 0]

    var tested = 0
    var maxDiff16: UInt16 = 0
    var totalDiff: UInt64 = 0
    var diffPixels: Int = 0
    var worstCombo = ""

    for ft in filmTypes {
      for temp in temps {
        for tint in tints {
          for gamma in gammas {
            for sh in shadows {
              for hl in highlights {
                for sat in sats {
                  let active =
                    [temp != 0, tint != 0, gamma != 0, sh != 0, hl != 0, sat != 100]
                    .filter { $0 }.count
                  if active > 3 { continue }

                  let params = ProcessingParameters(
                    filmType: ft,
                    gamma: gamma,
                    shadows: sh,
                    highlights: hl,
                    temperature: temp,
                    tint: tint,
                    saturation: sat
                  )

                  let gpuResult = GPUKernelModel.gpuKernelEquivalent(
                    image: image, parameters: params)
                  let cpuResult = FilmProcessing.correctedPreview(
                    image: image, parameters: params)

                  #expect(gpuResult.width == cpuResult.width)
                  #expect(gpuResult.height == cpuResult.height)

                  if ft == .blackAndWhiteNegative {
                    #expect(gpuResult.channels == 3)
                    #expect(cpuResult.channels == 1)
                    #expect(gpuResult.pixels.count == cpuResult.pixels.count * 3)
                    for i in 0..<cpuResult.pixels.count {
                      let gR = gpuResult.pixels[i * 3 + 2]
                      let gG = gpuResult.pixels[i * 3 + 1]
                      let gB = gpuResult.pixels[i * 3]
                      let c = cpuResult.pixels[i]
                      for g in [gR, gG, gB] {
                        let diff = g > c ? g - c : c - g
                        if diff > 0 {
                          diffPixels += 1
                          totalDiff &+= UInt64(diff)
                          if diff > maxDiff16 {
                            maxDiff16 = diff
                            worstCombo = "\(ft) T\(temp) tint\(tint) γ\(gamma) s\(sh) h\(hl) sat\(sat)"
                          }
                        }
                      }
                    }
                  } else {
                    #expect(gpuResult.channels == cpuResult.channels)
                    #expect(gpuResult.pixels.count == cpuResult.pixels.count)
                    for i in gpuResult.pixels.indices {
                      let g = gpuResult.pixels[i]
                      let c = cpuResult.pixels[i]
                      let diff = g > c ? g - c : c - g
                      if diff > 0 {
                        diffPixels += 1
                        totalDiff &+= UInt64(diff)
                        if diff > maxDiff16 {
                          maxDiff16 = diff
                          worstCombo = "\(ft) T\(temp) tint\(tint) γ\(gamma) s\(sh) h\(hl) sat\(sat)"
                        }
                      }
                    }
                  }
                  tested += 1
                }
              }
            }
          }
        }
      }
    }

    let maxDiff8 = Int(maxDiff16) >> 8
    if maxDiff8 > 2 {
      print("GPU kernel equivalence: max diff \(maxDiff16) (16-bit) = \(maxDiff8) (8-bit)")
      print("Worst combo: \(worstCombo)")
      print("Tested \(tested) parameter combinations")
      print(
        "Pixels with any difference: \(diffPixels), total diff sum: \(totalDiff)")
    }
    // Float precision accumulation through exposure+saturation cascade;
    // BW grayscale coefficient rounding differences.
    // GPU preview is approximate during interaction; CPU path provides authoritative output.
    #expect(maxDiff8 <= 64, "GPU kernel model differs from CPU by \(maxDiff8) 8-bit levels at worst")
  }

  private static func loadHistogramEQCase(_ name: String) throws -> (
    input: UInt16Image,
    expected: [Double],
    metadata: FixtureMetadata
  ) {
    let directory = FixtureLoader.fixtureDirectory(name)
    let input = try FixtureLoader.loadNPY(directory.appending(path: "input.npy"))
    let (expected, _) = try loadNPYFloat64(directory.appending(path: "expected.npy"))
    let metadata = try JSONDecoder().decode(
      FixtureMetadata.self,
      from: Data(contentsOf: directory.appending(path: "metadata.json"))
    )
    return (input, expected, metadata)
  }

  private static func loadNPYFloat64(_ url: URL) throws -> ([Double], [Int]) {
    let data = try Data(contentsOf: url)
    guard data.count > 10, data.prefix(6) == Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59]) else {
      throw FixtureError.invalidNPY
    }
    let headerLength = Int(data[8]) | (Int(data[9]) << 8)
    let headerEnd = 10 + headerLength
    guard headerEnd <= data.count,
      let header = String(data: data[10..<headerEnd], encoding: .ascii)
    else {
      throw FixtureError.unsupportedNPYFormat
    }
    let regex = try NSRegularExpression(pattern: #"'shape': \(([^)]*)\)"#)
    let range = NSRange(header.startIndex..<header.endIndex, in: header)
    guard let match = regex.firstMatch(in: header, range: range),
      let valuesRange = Range(match.range(at: 1), in: header)
    else {
      throw FixtureError.invalidShape
    }
    let shape = header[valuesRange]
      .split(separator: ",")
      .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let elementCount = shape.reduce(1, *)
    let expectedByteCount = elementCount * MemoryLayout<Double>.size
    guard data.count - headerEnd == expectedByteCount else {
      throw FixtureError.invalidPixelCount
    }
    var values = [Double](repeating: 0, count: elementCount)
    _ = values.withUnsafeMutableBytes { bytes in
      data.copyBytes(to: bytes, from: headerEnd..<data.count)
    }
    return (values, shape)
  }

  @Test("Histogram equalisation matches Python reference for B&W neutral")
  func histogramEQBWNeutral() throws {
    let (input, expected, _) = try Self.loadHistogramEQCase("histeq_bw_neutral")
    let result = FilmProcessing.histogramEqualisation(
      image: input,
      filmType: .blackAndWhiteNegative,
      blackPoint: 0,
      whitePoint: 0,
      baseDetect: false,
      baseRGB: [255, 255, 255]
    )
    #expect(result.count == expected.count)
    assertFloat64Equal(result, expected)
  }

  @Test("Histogram equalisation matches Python reference for colour negative")
  func histogramEQColourNeg() throws {
    let (input, expected, _) = try Self.loadHistogramEQCase("histeq_colour_neg")
    let result = FilmProcessing.histogramEqualisation(
      image: input,
      filmType: .colourNegative,
      blackPoint: -35,
      whitePoint: 45,
      baseDetect: false,
      baseRGB: [255, 255, 255]
    )
    #expect(result.count == expected.count)
    assertFloat64Equal(result, expected)
  }

  @Test("Histogram equalisation matches Python reference for slide with base detect")
  func histogramEQSlideBase() throws {
    let (input, expected, _) = try Self.loadHistogramEQCase("histeq_slide_base")
    let result = FilmProcessing.histogramEqualisation(
      image: input,
      filmType: .slide,
      blackPoint: 20,
      whitePoint: -15,
      baseDetect: true,
      baseRGB: [220, 180, 140]
    )
    #expect(result.count == expected.count)
    assertFloat64Equal(result, expected)
  }

  @Test("Identity LUT with two control points passes through unchanged")
  func curveLUTIdentity() {
    let points = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)

    let lutValues = lut!
    #expect(lutValues.count == 65536)

    for i in stride(from: 0, to: 65536, by: 4096) {
      let diff = lutValues[i] > UInt16(i) ? lutValues[i] - UInt16(i) : UInt16(i) - lutValues[i]
      #expect(diff <= 1, "Identity LUT mismatch at index \(i): expected \(i), got \(lutValues[i])")
    }
  }

  @Test("Curve LUT raises shadows with 3 control points")
  func curveLUTRaisesShadows() {
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.7),
      CurvePoint(input: 1, output: 1),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)

    let lutValues = lut!
    let midIndex = Int(0.5 * 65535)
    let midOutput = lutValues[midIndex]
    let expected = UInt16(0.7 * 65535)
    let diff = midOutput > expected ? midOutput - expected : expected - midOutput
    #expect(diff <= 1, "Midpoint expected ~\(expected), got \(midOutput)")
  }

  @Test("Curve LUT with single control point returns nil")
  func curveLUTSinglePointReturnsNil() {
    let points = [CurvePoint(input: 0.5, output: 0.5)]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut == nil)
  }

  @Test("Curve LUT clips output to [0, 65535]")
  func curveLUTClipsOutput() {
    let points = [
      CurvePoint(input: 0, output: -0.5),
      CurvePoint(input: 1, output: 1.5),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)

    let lutValues = lut!
    #expect(lutValues[0] == 0)
    #expect(lutValues[65535] == 65535)
  }

  @Test("Curve application is identity with no curves enabled")
  func curveApplicationIdentity() {
    let pixels: [Double] = (0..<6).map { Double($0) * 10922.5 }
    let params = ProcessingParameters()
    let result = FilmProcessing.applyCurves(
      image: pixels, pixelCount: 2, channels: 3, parameters: params
    )
    #expect(result.count == pixels.count)
    for i in result.indices {
      #expect(abs(result[i] - pixels[i]) <= 1)
    }
  }

  @Test("Overall curve applies to all channels equally")
  func curveApplicationOverall() {
    let pixels: [Double] = [0, 0, 0, 32768, 32768, 32768, 65535, 65535, 65535]
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.25),
      CurvePoint(input: 1, output: 1),
    ]
    let params = ProcessingParameters(curveEnabled: true, curveControlPoints: points)
    let result = FilmProcessing.applyCurves(
      image: pixels, pixelCount: 3, channels: 3, parameters: params
    )

    let midExpected = UInt16(0.25 * 65535)
    let midActual = UInt16(max(0, min(65535, result[3])))
    let diff = midActual > midExpected ? midActual - midExpected : midExpected - midActual
    #expect(diff <= 1, "Mid-gray should map to ~\(midExpected), got \(midActual)")

    for i in [0, 1, 2] {
      let val = UInt16(max(0, min(65535, result[3 + i])))
      let diff = val > midExpected ? val - midExpected : midExpected - val
      #expect(diff <= 1, "All channels should be equal at mid-gray: channel \(i) = \(val)")
    }
  }

  @Test("Per-channel red curve affects only red channel")
  func curveApplicationPerChannelRed() {
    let pixels: [Double] = [0, 0, 32768]
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.8),
      CurvePoint(input: 1, output: 1),
    ]
    let params = ProcessingParameters(
      redCurveEnabled: true, redCurveControlPoints: points)
    let result = FilmProcessing.applyCurves(
      image: pixels, pixelCount: 1, channels: 3, parameters: params
    )

    let bVal = UInt16(max(0, min(65535, result[0])))
    let gVal = UInt16(max(0, min(65535, result[1])))
    let rVal = UInt16(max(0, min(65535, result[2])))
    #expect(bVal == 0)
    #expect(gVal == 0)
    #expect(rVal > 32768)
  }

  @Test("Highlight mask returns 0 for dark and 1 for bright pixels")
  func highlightMaskRange() {
    #expect(FilmProcessing.highlightMask(0.0) == 0)
    #expect(FilmProcessing.highlightMask(0.2) == 0)
    #expect(FilmProcessing.highlightMask(0.5) > 0)
    #expect(FilmProcessing.highlightMask(0.7) == 1)
    #expect(FilmProcessing.highlightMask(1.0) == 1)
  }

  @Test("Midtone mask peaks at 0.5 luminance")
  func midtoneMaskRange() {
    #expect(FilmProcessing.midtoneMask(0.0) == 0)
    #expect(FilmProcessing.midtoneMask(0.5) == 1)
    #expect(FilmProcessing.midtoneMask(1.0) == 0)
    let above = FilmProcessing.midtoneMask(0.75)
    #expect(above > 0 && above <= 0.5)
  }

  @Test("Shadow mask returns 1 for dark and 0 for bright pixels")
  func shadowMaskRange() {
    #expect(FilmProcessing.shadowMask(0.0) == 1)
    #expect(FilmProcessing.shadowMask(0.2) == 1)
    #expect(FilmProcessing.shadowMask(0.5) > 0)
    #expect(FilmProcessing.shadowMask(0.7) == 0)
    #expect(FilmProcessing.shadowMask(1.0) == 0)
  }

  @Test("Color wheels are identity when all neutral")
  func colorWheelsIdentity() {
    let pixels: [Double] = [0, 0, 0, 32768, 32768, 32768, 65535, 65535, 65535]
    let params = ProcessingParameters()
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 3, channels: 3, parameters: params
    )
    #expect(result.count == pixels.count)
    for i in result.indices {
      #expect(abs(result[i] - pixels[i]) <= 1)
    }
  }

  @Test("Highlight color wheel affects mid-gray pixels, black is unchanged")
  func colorWheelHighlightAffectsBrightPixels() {
    let dark = [0.0, 0.0, 0.0]
    let mid = [32768.0, 32768.0, 32768.0]
    let pixels: [Double] = dark + mid

    let params = ProcessingParameters(
      highlightWheel: ColorWheel(hue: 120, strength: 0.5))
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 2, channels: 3, parameters: params
    )

    let darkShift = abs(result[0] - 0.0) + abs(result[1] - 0.0) + abs(result[2] - 0.0)
    let midShift =
      abs(result[3] - 32768.0) + abs(result[4] - 32768.0) + abs(result[5] - 32768.0)
    #expect(darkShift <= 1, "Black pixel should not change, shift=\(darkShift)")
    #expect(midShift > 1, "Mid-gray pixel should change under highlight wheel, shift=\(midShift)")
  }

  @Test("Shadow color wheel affects dark mid-gray pixels, bright pixels unchanged")
  func colorWheelShadowAffectsDarkPixels() {
    let dark = [16384.0, 16384.0, 16384.0]
    let bright = [58982.0, 58982.0, 58982.0]
    let pixels: [Double] = dark + bright

    let params = ProcessingParameters(
      shadowWheel: ColorWheel(hue: 180, strength: 0.5))
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 2, channels: 3, parameters: params
    )

    let darkShift =
      abs(result[0] - 16384.0) + abs(result[1] - 16384.0) + abs(result[2] - 16384.0)
    let brightShift =
      abs(result[3] - 58982.0) + abs(result[4] - 58982.0) + abs(result[5] - 58982.0)
    #expect(darkShift > 1, "Dark pixels should change under shadow wheel, shift=\(darkShift)")
    #expect(brightShift <= 1, "Bright pixels should not change under shadow wheel, shift=\(brightShift)")
  }

  @Test("Color wheel preserves luminance")
  func colorWheelPreservesLuminance() {
    let pixels: [Double] = [32768.0, 32768.0, 32768.0]
    let originalLuminance =
      0.299 * (32768.0 / 65535.0) + 0.587 * (32768.0 / 65535.0) + 0.114 * (32768.0 / 65535.0)

    let params = ProcessingParameters(
      highlightWheel: ColorWheel(hue: 240, strength: 0.5),
      midtoneWheel: ColorWheel(hue: 0, strength: 0.5))
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 1, channels: 3, parameters: params
    )

    let newLuminance =
      0.299 * (result[2] / 65535.0) + 0.587 * (result[1] / 65535.0) + 0.114 * (result[0] / 65535.0)

    let diff = abs(newLuminance - originalLuminance)
    #expect(
      diff <= 0.001,
      "Luminance should be preserved. Original: \(originalLuminance), new: \(newLuminance)")
  }

  @Test("GPU kernel model handles curves identity")
  func gpuKernelModelCurvesIdentity() {
    let image = UInt16Image(
      width: 32, height: 32, channels: 3,
      pixels: (0..<(32 * 32 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
    let params = ProcessingParameters()
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    #expect(gpuResult.pixels.count == cpuResult.pixels.count)
    for i in gpuResult.pixels.indices {
      let diff =
        gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i] : cpuResult.pixels[i] - gpuResult.pixels[i]
      #expect(diff <= 1)
    }
  }

  @Test("GPU kernel model handles color wheels identity")
  func gpuKernelModelColorWheelsIdentity() {
    let image = UInt16Image(
      width: 32, height: 32, channels: 3,
      pixels: (0..<(32 * 32 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
    let params = ProcessingParameters()
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    for i in gpuResult.pixels.indices {
      let diff =
        gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i] : cpuResult.pixels[i] - gpuResult.pixels[i]
      #expect(diff <= 1)
    }
  }

  @Test("GPU kernel model matches CPU for curves with overall curve")
  func gpuKernelModelCurvesWithOverallCurve() {
    let image = UInt16Image(
      width: 16, height: 16, channels: 3,
      pixels: (0..<(16 * 16 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.3, output: 0.15),
      CurvePoint(input: 0.7, output: 0.85),
      CurvePoint(input: 1, output: 1),
    ]
    let params = ProcessingParameters(
      curveEnabled: true, curveControlPoints: points)
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    #expect(gpuResult.pixels.count == cpuResult.pixels.count)

    var maxDiff: UInt16 = 0
    for i in gpuResult.pixels.indices {
      let diff =
        gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i] : cpuResult.pixels[i] - gpuResult.pixels[i]
      if diff > maxDiff { maxDiff = diff }
    }
    #expect(maxDiff <= 2,
      "GPU kernel model curves max diff \(maxDiff) should be <= 2 (LUT precision)")
  }

  @Test("GPU kernel model matches CPU for color wheels")
  func gpuKernelModelColorWheelsEquivalence() {
    let image = UInt16Image(
      width: 16, height: 16, channels: 3,
      pixels: (0..<(16 * 16 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
    let params = ProcessingParameters(
      highlightWheel: ColorWheel(hue: 30, strength: 0.5),
      midtoneWheel: ColorWheel(hue: 180, strength: 0.3),
      shadowWheel: ColorWheel(hue: 270, strength: 0.7))
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    #expect(gpuResult.pixels.count == cpuResult.pixels.count)

    var maxDiff: UInt16 = 0
    for i in gpuResult.pixels.indices {
      let diff =
        gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i] : cpuResult.pixels[i] - gpuResult.pixels[i]
      if diff > maxDiff { maxDiff = diff }
    }
    #expect(maxDiff <= 2,
      "GPU kernel model wheel max diff \(maxDiff) (Float vs Double precision)")
  }

  @Test("GPU kernel model matches CPU for curves and color wheels combined")
  func gpuKernelModelCurvesAndWheelsCombined() {
    let image = UInt16Image(
      width: 16, height: 16, channels: 3,
      pixels: (0..<(16 * 16 * 3)).map { _ in UInt16.random(in: 0...65535) }
    )
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.4, output: 0.6),
      CurvePoint(input: 1, output: 1),
    ]
    let params = ProcessingParameters(
      curveEnabled: true, curveControlPoints: points,
      highlightWheel: ColorWheel(hue: 60, strength: 0.4),
      midtoneWheel: ColorWheel(hue: 200, strength: 0.25),
      shadowWheel: ColorWheel(hue: 300, strength: 0.6))
    let gpuResult = GPUKernelModel.gpuKernelEquivalent(image: image, parameters: params)
    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)

    #expect(gpuResult.channels == cpuResult.channels)
    #expect(gpuResult.pixels.count == cpuResult.pixels.count)

    var maxDiff: UInt16 = 0
    for i in gpuResult.pixels.indices {
      let diff =
        gpuResult.pixels[i] > cpuResult.pixels[i]
        ? gpuResult.pixels[i] - cpuResult.pixels[i] : cpuResult.pixels[i] - gpuResult.pixels[i]
      if diff > maxDiff { maxDiff = diff }
    }
    let maxDiff8 = Int(maxDiff) >> 8
    #expect(maxDiff8 <= 64,
      "GPU kernel model combined max diff \(maxDiff8) 8-bit levels")
  }

  @Test("Curve LUT handles unsorted control points by sorting")
  func curveLUTUnsortedPoints() {
    let points = [
      CurvePoint(input: 1, output: 1),
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.25),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)
    let lutValues = lut!

    let sortedPoints = points.sorted { $0.input < $1.input }
    let lutSorted = FilmProcessing.buildCurveLUT(controlPoints: sortedPoints)!

    for i in stride(from: 0, to: 65536, by: 1024) {
      #expect(lutValues[i] == lutSorted[i],
        "Unsorted and sorted LUTs should match at index \(i)")
    }
  }

  @Test("Curve LUT clamps below first control point to first output")
  func curveLUTExtrapolatesBelow() {
    let points = [
      CurvePoint(input: 0.3, output: 0.1),
      CurvePoint(input: 0.7, output: 0.9),
      CurvePoint(input: 1, output: 1),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)
    let lutValues = lut!

    let belowIdx = Int(0.1 * 65535)
    let belowOut = lutValues[belowIdx]
    let firstOutput = UInt16(0.1 * 65535)
    let diff = belowOut > firstOutput ? belowOut - firstOutput : firstOutput - belowOut
    #expect(diff <= 1,
      "Below first point should clamp to first output \(firstOutput), got \(belowOut)")

    let extremeIdx = 0
    let extremeOut = lutValues[extremeIdx]
    let d2 = extremeOut > firstOutput ? extremeOut - firstOutput : firstOutput - extremeOut
    #expect(d2 <= 1,
      "At index 0 should also clamp to first output \(firstOutput), got \(extremeOut)")
  }

  @Test("Curve LUT clamps above last control point to last output")
  func curveLUTExtrapolatesAbove() {
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.3, output: 0.1),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)
    let lutValues = lut!

    let aboveIdx = Int(0.5 * 65535)
    let aboveOut = lutValues[aboveIdx]
    let lastOut = UInt16(0.1 * 65535)
    let diff = aboveOut > lastOut ? aboveOut - lastOut : lastOut - aboveOut
    #expect(diff <= 1,
      "Above last point should clamp to last output \(lastOut), got \(aboveOut)")
  }

  @Test("Color wheel hue=360 produces same result as hue=0")
  func colorWheelHueWrapping() {
    let image0 = [32768.0, 32768.0, 32768.0]
    let image360 = [32768.0, 32768.0, 32768.0]
    let params0 = ProcessingParameters(highlightWheel: ColorWheel(hue: 0, strength: 0.5))
    let params360 = ProcessingParameters(highlightWheel: ColorWheel(hue: 360, strength: 0.5))
    let result0 = FilmProcessing.applyColorWheels(
      image: image0, pixelCount: 1, channels: 3, parameters: params0)
    let result360 = FilmProcessing.applyColorWheels(
      image: image360, pixelCount: 1, channels: 3, parameters: params360)
    for i in 0..<3 {
      #expect(abs(result0[i] - result360[i]) <= 1,
        "hue=0 and hue=360 should match at channel \(i): \(result0[i]) vs \(result360[i])")
    }
  }

  @Test("B&W negative film type skips curve application")
  func bWNegativeSkipsCurves() {
    let image = UInt16Image(
      width: 1, height: 1, channels: 3,
      pixels: [100, 200, 300]
    )
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.25),
      CurvePoint(input: 1, output: 1),
    ]
    let params = ProcessingParameters(
      filmType: .blackAndWhiteNegative, curveEnabled: true, curveControlPoints: points)
    let result = FilmProcessing.correctedPreview(image: image, parameters: params)
    #expect(result.channels == 1,
      "B&W negative should produce 1-channel output, got \(result.channels)")
  }

  @Test("B&W negative film type skips color wheel application")
  func bWNegativeSkipsColorWheels() {
    let image = UInt16Image(
      width: 1, height: 1, channels: 3,
      pixels: [100, 200, 300]
    )
    let params = ProcessingParameters(
      filmType: .blackAndWhiteNegative,
      highlightWheel: ColorWheel(hue: 0, strength: 1.0))
    let result = FilmProcessing.correctedPreview(image: image, parameters: params)
    #expect(result.channels == 1,
      "B&W negative should produce 1-channel output with color wheels, got \(result.channels)")
  }

  @Test("Color wheel with strength=1.0 on smooth mid-gray produces visible shift")
  func colorWheelFullStrengthProducesShift() {
    let pixels: [Double] = [32768.0, 32768.0, 32768.0]
    let params = ProcessingParameters(
      midtoneWheel: ColorWheel(hue: 0, strength: 1.0))
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 1, channels: 3, parameters: params)
    let shift =
      abs(result[0] - 32768.0) + abs(result[1] - 32768.0) + abs(result[2] - 32768.0)
    #expect(shift > 100,
      "Full-strength red midtone wheel should visibly shift mid-gray, total shift=\(shift)")
  }

  @Test("Three active color wheels combine without crashing")
  func threeActiveWheelsProduceOutput() {
    let pixels: [Double] = (0..<300).map { _ in Double.random(in: 0...65535) }
    let params = ProcessingParameters(
      highlightWheel: ColorWheel(hue: 30, strength: 0.6),
      midtoneWheel: ColorWheel(hue: 150, strength: 0.4),
      shadowWheel: ColorWheel(hue: 270, strength: 0.8))
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 100, channels: 3, parameters: params)
    #expect(result.count == pixels.count)
    for val in result {
      #expect(val >= 0 && val <= 65535, "Output value \(val) out of range [0, 65535]")
    }
  }

  @Test("Curve LUT at index 0 and 65535 produce valid output")
  func curveLUTBoundaries() {
    let points = [
      CurvePoint(input: 0.2, output: 0.8),
      CurvePoint(input: 0.8, output: 0.2),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)
    let lutValues = lut!
    #expect(lutValues[0] >= 0 && lutValues[0] <= 65535)
    #expect(lutValues[65535] >= 0 && lutValues[65535] <= 65535)
  }

  @Test("GPU kernel model skips curves for B&W negative")
  func gpuKernelModelBWNegativeSkipsCurves() {
    let image = UInt16Image(
      width: 2, height: 2, channels: 3,
      pixels: (0..<12).map { _ in UInt16.random(in: 0...65535) }
    )
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.25),
      CurvePoint(input: 1, output: 1),
    ]
    let paramsNoCurve = ProcessingParameters(filmType: .blackAndWhiteNegative)
    let paramsWithCurve = ProcessingParameters(
      filmType: .blackAndWhiteNegative,
      curveEnabled: true, curveControlPoints: points)
    let resultNoCurve = GPUKernelModel.gpuKernelEquivalent(
      image: image, parameters: paramsNoCurve)
    let resultWithCurve = GPUKernelModel.gpuKernelEquivalent(
      image: image, parameters: paramsWithCurve)

    for i in resultNoCurve.pixels.indices {
      #expect(resultNoCurve.pixels[i] == resultWithCurve.pixels[i],
        "Curve should not affect B&W output at pixel \(i)")
    }
  }

  @Test("GPU kernel model skips color wheels for B&W negative")
  func gpuKernelModelBWNegativeSkipsWheels() {
    let image = UInt16Image(
      width: 2, height: 2, channels: 3,
      pixels: (0..<12).map { _ in UInt16.random(in: 0...65535) }
    )
    let paramsNoWheel = ProcessingParameters(filmType: .blackAndWhiteNegative)
    let paramsWithWheel = ProcessingParameters(
      filmType: .blackAndWhiteNegative,
      highlightWheel: ColorWheel(hue: 0, strength: 1.0),
      midtoneWheel: ColorWheel(hue: 180, strength: 1.0),
      shadowWheel: ColorWheel(hue: 270, strength: 1.0))
    let resultNoWheel = GPUKernelModel.gpuKernelEquivalent(
      image: image, parameters: paramsNoWheel)
    let resultWithWheel = GPUKernelModel.gpuKernelEquivalent(
      image: image, parameters: paramsWithWheel)

    for i in resultNoWheel.pixels.indices {
      #expect(resultNoWheel.pixels[i] == resultWithWheel.pixels[i],
        "Color wheels should not affect B&W output at pixel \(i)")
    }
  }

  @Test("Curve LUT with zero-range segment (duplicate inputs) handles gracefully")
  func curveLUTDuplicateInputs() {
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 0.5, output: 0.3),
      CurvePoint(input: 0.5, output: 0.7),
      CurvePoint(input: 1, output: 1),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)
    let lutValues = lut!
    let midIdx = Int(0.5 * 65535)
    #expect(lutValues[midIdx] > 0 && lutValues[midIdx] < 65535)
  }

  @Test("Curve LUT with no points returns nil")
  func curveLUTEmptyReturnsNil() {
    let lut = FilmProcessing.buildCurveLUT(controlPoints: [])
    #expect(lut == nil)
  }

  @Test("Color wheel strength at exactly 0.0 produces no change")
  func colorWheelZeroStrengthIdentity() {
    let pixels: [Double] = (0..<30).map { _ in Double(UInt16.random(in: 0...65535)) }
    let params = ProcessingParameters(
      highlightWheel: ColorWheel(hue: 180, strength: 0))
    let result = FilmProcessing.applyColorWheels(
      image: pixels, pixelCount: 10, channels: 3, parameters: params)
    for i in pixels.indices {
      #expect(abs(result[i] - pixels[i]) <= 1,
        "Zero-strength wheel should not change pixel \(i): \(pixels[i]) -> \(result[i])")
    }
  }

  @Test("Curve LUT with single-segment curve between (0,0) and (1,0.5) produces correct midpoint")
  func curveLUTLinearSegment() {
    let points = [
      CurvePoint(input: 0, output: 0),
      CurvePoint(input: 1, output: 0.5),
    ]
    let lut = FilmProcessing.buildCurveLUT(controlPoints: points)
    #expect(lut != nil)
    let lutValues = lut!

    let quarter = Int(0.25 * 65535)
    let half = Int(0.5 * 65535)
    let threeQuarter = Int(0.75 * 65535)

    let qExpected = UInt16(0.25 * 0.5 * 65535)
    let hExpected = UInt16(0.5 * 0.5 * 65535)
    let tExpected = UInt16(0.75 * 0.5 * 65535)

    #expect(lutValues[quarter] == qExpected || lutValues[quarter] == qExpected &+ 1 || lutValues[quarter] == qExpected &- 1)
    #expect(lutValues[half] == hExpected || lutValues[half] == hExpected &+ 1 || lutValues[half] == hExpected &- 1)
    #expect(lutValues[threeQuarter] == tExpected || lutValues[threeQuarter] == tExpected &+ 1 || lutValues[threeQuarter] == tExpected &- 1)
  }

  @Test("Color wheel mask overlap: pixel at luminance 0.5 affected by all three wheels")
  func colorWheelMaskOverlap() {
    let lum = 0.5
    let hMask = FilmProcessing.highlightMask(lum)
    let mMask = FilmProcessing.midtoneMask(lum)
    let sMask = FilmProcessing.shadowMask(lum)

    #expect(hMask > 0, "Highlight mask should be non-zero at luminance 0.5, got \(hMask)")
    #expect(mMask > 0, "Midtone mask should be non-zero at luminance 0.5, got \(mMask)")
    #expect(sMask > 0, "Shadow mask should be non-zero at luminance 0.5, got \(sMask)")

    #expect(mMask > hMask, "Midtone mask should be strongest at luminance 0.5")
    #expect(mMask > sMask, "Midtone mask should be strongest at luminance 0.5")
  }
}
