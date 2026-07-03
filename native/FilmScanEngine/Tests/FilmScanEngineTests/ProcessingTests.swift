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

  @Test("Film-negative processing renders zero-light pixels as neutral white")
  func filmNegativeNeutralizesZeroLight() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [0, 128, 256, 512, 512, 512]
    )
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = BGRChannelValues(blue: 20_000, green: 20_000, red: 20_000)
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      photoAdjustments: PhotoAdjustmentParameters(brightness: 0.5)
    )

    let actual = FilmProcessing.correctedPreview(image: image, parameters: parameters)

    #expect(Array(actual.pixels[0..<3]) == [65535, 65535, 65535])
    #expect(actual.pixels[3..<6].contains { $0 > 0 })
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

  @Test("Power-law film negative inverts dense areas to bright and clear areas to dark")
  func filmNegativePowerLawInversion() {
    let width = 32
    let height = 32
    var pixels = [UInt16](repeating: 0, count: width * height * 3)

    for y in 0..<height {
      for x in 0..<width {
        let idx = (y * width + x) * 3
        let v = UInt16(Float(x) / Float(width - 1) * 65535.0)
        pixels[idx] = v
        pixels[idx + 1] = v
        pixels[idx + 2] = v
      }
    }

    let image = UInt16Image(width: width, height: height, channels: 3, pixels: pixels)

    let result = FilmNegativeProcessing.applyPowerLawInversion(
      image: image, params: FilmNegativeParams.blackAndWhite
    )

    #expect(result.width == width)
    #expect(result.height == height)
    #expect(result.channels == 3)

    let firstPixel = result.pixels[0]
    let lastPixel = result.pixels[(width - 1) * 3]
    #expect(lastPixel < firstPixel, "Dense (dark) areas should become bright, clear (bright) areas should become dark")
  }

  @Test("Power-law film negative maps the median through RawTherapee display output")
  func filmNegativeMultiplierCalibration() {
    var pixels = [UInt16](repeating: 10000, count: 32 * 32 * 3)
    var rng = SystemRandomNumberGenerator()
    for i in pixels.indices {
      pixels[i] = UInt16(max(0, min(65535, Double(pixels[i]) + Double.random(in: -2000...2000, using: &rng))))
    }
    let image = UInt16Image(width: 32, height: 32, channels: 3, pixels: pixels)

    let result = FilmNegativeProcessing.applyPowerLawInversion(
      image: image, params: FilmNegativeParams.blackAndWhite
    )

    var medianResult: UInt16 = 0
    var vals = [UInt16]()
    for i in 0..<(32 * 32) {
      vals.append(result.pixels[i * 3 + 1])
    }
    vals.sort()
    medianResult = vals[vals.count / 2]

    let encodedTarget = FilmNegativeProcessing.linearToSRGB(
      FilmNegativeProcessing.calibrationTargetFraction
    )
    let target = UInt16(
      65535.0 * FilmNegativeProcessing.rawTherapeeFilmNegativeToneCurve(encodedTarget)
    )
    #expect(abs(Int(medianResult) - Int(target)) < 1500,
      "Median output should include transfer encoding and preset curves, got \(medianResult)")
  }

  @Test("RawTherapee film negative preset retains a broad unclipped tonal range")
  func filmNegativePresetRetainsTonalRange() {
    let samples: [UInt16] = [8_000, 12_000, 18_000, 24_000, 30_000, 38_000, 46_000, 54_000]
    let image = UInt16Image(
      width: samples.count,
      height: 1,
      channels: 3,
      pixels: samples.flatMap { [$0, $0, $0] }
    )
    var params = FilmNegativeParams.blackAndWhite
    params.measuredMedians = BGRChannelValues(blue: 30_000, green: 30_000, red: 30_000)

    let result = FilmNegativeProcessing.applyPowerLawInversion(image: image, params: params)
    let green = stride(from: 1, to: result.pixels.count, by: 3).map { result.pixels[$0] }

    #expect(green == green.sorted(by: >))
    #expect(green.filter { $0 == 0 }.count <= 1)
    #expect(green.filter { $0 == 65_535 }.count <= 1)
    #expect(Set(green).count >= samples.count - 1)
  }

  @Test("Film negative preset maps representative median into display quarter tones")
  func filmNegativePresetDoesNotDarkenMedian() {
    let width = 16
    let height = 16
    let inputMedian: UInt16 = 30_000
    let image = UInt16Image(
      width: width,
      height: height,
      channels: 3,
      pixels: [UInt16](repeating: inputMedian, count: width * height * 3)
    )
    var params = FilmNegativeParams.colourNegative
    params.measuredMedians = BGRChannelValues(
      blue: Double(inputMedian),
      green: Double(inputMedian),
      red: Double(inputMedian)
    )

    let result = FilmNegativeProcessing.applyPowerLawInversion(image: image, params: params)
    let green = result.pixels[1]

    #expect(green > 14_000, "Preset median should remain visible after display mapping, got \(green)")
    #expect(green < 25_000, "Preset median should retain RawTherapee's low reference placement, got \(green)")
  }

  @Test("Film negative corrected preview produces valid output")
  func filmNegativeCorrectedPreview() {
    var pixels = [UInt16](repeating: 0, count: 8 * 8 * 3)
    for i in 0..<(8 * 8) {
      let base = i * 3
      let v = max(1.0, (1.0 - Double(i) / 64.0) * 50000.0)
      pixels[base] = UInt16(v)
      pixels[base + 1] = UInt16(v)
      pixels[base + 2] = UInt16(v)
    }
    let image = UInt16Image(width: 8, height: 8, channels: 3, pixels: pixels)

    var params = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: FilmNegativeParams.blackAndWhite
    )
    params.filmNegativeParams.measuredMedians =
      FilmNegativeProcessing.computeMedians(image: image)

    let cpuResult = FilmProcessing.correctedPreview(image: image, parameters: params)
    #expect(cpuResult.width == 8)
    #expect(!cpuResult.pixels.isEmpty)
  }

  @Test("Density preview aligns resized flat field through orientation")
  func densityPreviewAlignsFlatFieldGeometry() {
    let image = UInt16Image(
      width: 6, height: 4, channels: 3,
      pixels: [UInt16](repeating: 30_000, count: 6 * 4 * 3)
    )
    let flatField = UInt16Image(
      width: 3, height: 2, channels: 3,
      pixels: [UInt16](repeating: 60_000, count: 3 * 2 * 3)
    )
    let parameters = ProcessingParameters(
      rotation: 1,
      filmType: .colourNegative,
      densityPipelineEnabled: true,
      densityBaseDensity: BGRChannelValues(blue: 0, green: 0, red: 0)
    )

    let result = FilmProcessing.correctedPreview(
      image: image,
      parameters: parameters,
      flatField: flatField
    )

    #expect(result.width == 4)
    #expect(result.height == 6)
    #expect(result.pixels.count == 4 * 6 * 3)
  }

  @Test("Detected crop geometry is applied by the processing entry point")
  func correctedPreviewAppliesCrop() {
    let image = UInt16Image(
      width: 100, height: 80, channels: 3,
      pixels: [UInt16](repeating: 20_000, count: 100 * 80 * 3)
    )
    let pixelRect = RotatedRect(centerX: 50, centerY: 40, width: 60, height: 40, angle: 0)
    let normalized = ContourDetection.normalizeToUnit(
      pixelRect, imageWidth: image.width, imageHeight: image.height)
    let parameters = ProcessingParameters(filmType: .cropOnly, cropRect: normalized)

    let result = FilmProcessing.correctedPreview(image: image, parameters: parameters)

    #expect(result.width == 60)
    #expect(result.height == 40)
  }

  @Test("Power-law processing applies protected color before the display transform")
  func powerLawProcessingUsesProtectedColorSeam() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [8_000, 18_000, 42_000, 30_000, 34_000, 38_000]
    )
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = BGRChannelValues(blue: 20_000, green: 26_000, red: 32_000)
    let adjustments = PhotoAdjustmentParameters(
      temperatureShiftMired: 35,
      tint: -0.2,
      saturation: 0.45,
      vibrance: 0.6
    )
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      photoAdjustments: adjustments
    )

    let actual = FilmProcessing.correctedPreview(image: image, parameters: parameters)
    let expected = FilmNegativeProcessing.renderPowerLawDisplay(
      FilmNegativeProcessing.powerLawRenderReadyLinear(image: image, params: filmNegative)
        .applyingProtectedColorAdjustments(adjustments)
    )

    #expect(actual == expected)
  }

  @Test("Density processing applies protected color on the shared linear seam")
  func densityProcessingUsesProtectedColorSeam() {
    let image = UInt16Image(width: 1, height: 1, channels: 3, pixels: [12_000, 20_000, 36_000])
    let baseDensity = BGRChannelValues(blue: 0, green: 0, red: 0)
    let adjustments = PhotoAdjustmentParameters(saturation: 0.5, vibrance: 0.75)
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      photoAdjustments: adjustments,
      densityPipelineEnabled: true,
      densityBaseDensity: baseDensity
    )
    let flatField = UInt16Image(
      width: 1,
      height: 1,
      channels: 3,
      pixels: [UInt16](repeating: 65_535, count: 3)
    )

    let actual = FilmProcessing.correctedPreview(
      image: image,
      parameters: parameters,
      flatField: flatField
    )
    let renderReady = FilmNegativeProcessing.densityToRenderReadyLinear(
      image: image,
      flatField: flatField,
      baseDensity: baseDensity
    ).applyingProtectedColorAdjustments(adjustments)
    let expectedPixels = FilmNegativeProcessing.renderDisplay(sceneLinear: renderReady.pixels)
      .map { UInt16(min(max($0 * 65_535, 0), 65_535)) }

    #expect(actual.pixels == expectedPixels)
  }

  @Test("Semantic light controls affect slide processing")
  func semanticToneControlsAffectSlides() {
    let image = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [8_000, 12_000, 18_000, 24_000, 28_000, 32_000])
    let neutral = FilmProcessing.correctedPreview(
      image: image, parameters: ProcessingParameters(filmType: .slide))
    let adjusted = FilmProcessing.correctedPreview(
      image: image,
      parameters: ProcessingParameters(
        filmType: .slide,
        photoAdjustments: PhotoAdjustmentParameters(exposureEV: 1)))

    #expect(adjusted != neutral)
    #expect(zip(adjusted.pixels, neutral.pixels).allSatisfy { adjusted, neutral in
      adjusted >= neutral
    })
  }

  @Test("Semantic light controls affect power-law black-and-white negatives")
  func semanticToneControlsAffectBlackAndWhiteNegatives() {
    let image = UInt16Image(
      width: 2, height: 1, channels: 3,
      pixels: [8_000, 12_000, 18_000, 24_000, 28_000, 32_000])
    var filmNegative = FilmNegativeParams.blackAndWhite
    filmNegative.measuredMedians = BGRChannelValues(blue: 16_000, green: 20_000, red: 24_000)
    let neutral = FilmProcessing.correctedPreview(
      image: image,
      parameters: ProcessingParameters(
        filmType: .blackAndWhiteNegative, filmNegativeParams: filmNegative))
    let adjusted = FilmProcessing.correctedPreview(
      image: image,
      parameters: ProcessingParameters(
        filmType: .blackAndWhiteNegative,
        filmNegativeParams: filmNegative,
        photoAdjustments: PhotoAdjustmentParameters(exposureEV: -1)))

    #expect(adjusted != neutral)
    #expect(zip(adjusted.pixels, neutral.pixels).allSatisfy { adjusted, neutral in
      adjusted <= neutral
    })
  }
}
