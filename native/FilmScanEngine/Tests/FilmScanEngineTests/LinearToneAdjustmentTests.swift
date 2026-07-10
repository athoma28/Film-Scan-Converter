import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Linear tone adjustments on the unclamped linear seam")
struct LinearToneAdjustmentTests {
  private func makeImage(pixels: [Double]) -> RenderReadyLinearImage {
    precondition(pixels.count.isMultiple(of: 3))
    let count = pixels.count / 3
    return RenderReadyLinearImage(width: count, height: 1, pixels: pixels)
  }

  @Test("Neutral tone parameters return the exact same pixels")
  func neutralIdentity() {
    let pixels: [Double] = [0, 0.18, 1, -0.1, 1.5, 8, 0.0003, 0.0003, 0.0003]
    let image = makeImage(pixels: pixels)
    let neutral = PhotoAdjustmentParameters()

    let result = image.applyingLinearToneAdjustments(neutral)

    #expect(result.pixels.count == pixels.count)
    for i in pixels.indices {
      #expect(result.pixels[i] == pixels[i])
    }
  }

  @Test("Positive exposure multiplies all channels by 2^EV")
  func positiveExposure() {
    let pixels: [Double] = [0.1, 0.2, 0.3]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(exposureEV: 1)

    let result = image.applyingLinearToneAdjustments(params)

    let expected = pixels.map { $0 * 2 }
    for i in pixels.indices {
      #expect(abs(result.pixels[i] - expected[i]) < 1e-12)
    }
  }

  @Test("Negative exposure darkens the image")
  func negativeExposure() {
    let pixels: [Double] = [0.4, 0.5, 0.6]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(exposureEV: -1)

    let result = image.applyingLinearToneAdjustments(params)

    let expected = pixels.map { $0 * 0.5 }
    for i in pixels.indices {
      #expect(abs(result.pixels[i] - expected[i]) < 1e-12)
    }
  }

  @Test("Zero exposure is identity")
  func zeroExposure() {
    let pixels: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(exposureEV: 0, brightness: 0, contrast: 0)

    let result = image.applyingLinearToneAdjustments(params)

    for i in pixels.indices {
      #expect(result.pixels[i] == pixels[i])
    }
  }

  @Test("Positive brightness adds a linear offset")
  func positiveBrightness() {
    let pixels: [Double] = [0, 0.18, 0.5, 0.09, 0.18, 1.0]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(brightness: 0.5)

    let result = image.applyingLinearToneAdjustments(params)

    let offset = 0.5 * 0.18
    for i in pixels.indices {
      #expect(abs(result.pixels[i] - (pixels[i] + offset)) < 1e-12)
    }
  }

  @Test("Negative brightness subtracts a linear offset")
  func negativeBrightness() {
    let pixels: [Double] = [0.5, 0.5, 0.5]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(brightness: -1)

    let result = image.applyingLinearToneAdjustments(params)

    let offset = -1 * 0.18
    for i in pixels.indices {
      #expect(abs(result.pixels[i] - (pixels[i] + offset)) < 1e-12)
    }
  }

  @Test("Brightness follows the pipeline tone reference")
  func brightnessUsesToneReference() {
    let pixels = [0.04, 0.04, 0.04]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(brightness: 0.5)

    let result = image.applyingLinearToneAdjustments(
      params,
      referenceLuminance: 0.04
    )

    for value in result.pixels {
      #expect(abs(value - 0.06) < 1e-12)
    }
  }

  @Test("Positive contrast increases the gap between dark and bright")
  func positiveContrast() {
    let dark: Double = 0.09
    let mid: Double = 0.18
    let bright: Double = 0.36
    let pixels: [Double] = [dark, dark, dark, mid, mid, mid, bright, bright, bright]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(contrast: 1)

    let result = image.applyingLinearToneAdjustments(params)

    let resultDark = result.pixels[0]
    let resultMid = result.pixels[3]
    let resultBright = result.pixels[6]

    #expect(resultDark < dark)
    #expect(abs(resultMid - mid) < 1e-10)
    #expect(resultBright > bright)
  }

  @Test("Negative contrast reduces the gap between dark and bright")
  func negativeContrast() {
    let dark: Double = 0.09
    let mid: Double = 0.18
    let bright: Double = 0.36
    let pixels: [Double] = [dark, dark, dark, mid, mid, mid, bright, bright, bright]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(contrast: -1)

    let result = image.applyingLinearToneAdjustments(params)

    let resultDark = result.pixels[0]
    let resultMid = result.pixels[3]
    let resultBright = result.pixels[6]

    #expect(resultDark > dark)
    #expect(abs(resultMid - mid) < 1e-10)
    #expect(resultBright < bright)
  }

  @Test("Zero contrast is identity around the pivot")
  func zeroContrast() {
    let pixels: [Double] = [0.09, 0.18, 0.36, 0.18, 0.18, 0.18]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(contrast: 0)

    let result = image.applyingLinearToneAdjustments(params)

    for i in pixels.indices {
      #expect(abs(result.pixels[i] - pixels[i]) < 1e-12)
    }
  }

  @Test("Positive highlights compress bright pixels more than dark ones")
  func positiveHighlightsCompresses() {
    let darkPixel = 0.2
    let brightPixel = 2.0
    let pixels: [Double] = [darkPixel, darkPixel, darkPixel, brightPixel, brightPixel, brightPixel]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(highlights: 1)

    let result = image.applyingLinearToneAdjustments(params)

    let darkResult = result.pixels[0]
    let brightResult = result.pixels[3]

    let darkRatio = darkResult / darkPixel
    let brightRatio = brightResult / brightPixel

    #expect(darkRatio > brightRatio)
    #expect(brightRatio < 1)
    #expect(brightResult < brightPixel)
  }

  @Test("Negative highlights boost bright pixels more than dark ones")
  func negativeHighlightsBoosts() {
    let darkPixel = 0.2
    let brightPixel = 2.0
    let pixels: [Double] = [darkPixel, darkPixel, darkPixel, brightPixel, brightPixel, brightPixel]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(highlights: -1)

    let result = image.applyingLinearToneAdjustments(params)

    let darkResult = result.pixels[0]
    let brightResult = result.pixels[3]

    let darkRatio = darkResult / darkPixel
    let brightRatio = brightResult / brightPixel

    #expect(brightRatio > darkRatio)
    #expect(brightRatio > 1)
    #expect(brightResult > brightPixel)
  }

  @Test("Highlight range follows the pipeline tone reference")
  func highlightsUseToneReference() {
    let pixels = [0.2, 0.2, 0.2]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(highlights: 0.5)

    let defaultResult = image.applyingLinearToneAdjustments(params)
    let negativeResult = image.applyingLinearToneAdjustments(
      params,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction
    )

    #expect(defaultResult.pixels[0] == pixels[0])
    #expect(negativeResult.pixels[0] < pixels[0])
  }

  @Test("Positive shadows lift dark pixels more than bright ones")
  func positiveShadowsLift() {
    let darkPixel = 0.02
    let brightPixel = 1.0
    let pixels: [Double] = [darkPixel, darkPixel, darkPixel, brightPixel, brightPixel, brightPixel]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(shadows: 1)

    let result = image.applyingLinearToneAdjustments(params)

    let darkResult = result.pixels[0]
    let brightResult = result.pixels[3]

    let darkRatio = darkResult / darkPixel
    let brightRatio = brightResult / brightPixel

    #expect(darkRatio > brightRatio)
    #expect(darkRatio > 1)
    #expect(darkResult > darkPixel)
  }

  @Test("Negative shadows darken dark pixels more than bright ones")
  func negativeShadowsDarken() {
    let darkPixel = 0.05
    let brightPixel = 1.0
    let pixels: [Double] = [darkPixel, darkPixel, darkPixel, brightPixel, brightPixel, brightPixel]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(shadows: -1)

    let result = image.applyingLinearToneAdjustments(params)

    let darkResult = result.pixels[0]
    let brightResult = result.pixels[3]

    let darkRatio = darkResult / darkPixel
    let brightRatio = brightResult / brightPixel

    #expect(darkRatio < brightRatio)
    #expect(darkRatio < 1)
    #expect(darkResult < darkPixel)
  }

  @Test("Multiplicative controls preserve per-pixel channel ratios")
  func multiplicativePreservesChannelRatios() {
    let pixels: [Double] = [0.1, 0.3, 0.7, 0.05, 0.5, 1.5]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(
      exposureEV: 0.5,
      contrast: 0.3,
      highlights: -0.4,
      shadows: 0.3
    )

    let result = image.applyingLinearToneAdjustments(params)

    let ratio0 = result.pixels[0] / pixels[0]
    let ratio1 = result.pixels[1] / pixels[1]
    let ratio2 = result.pixels[2] / pixels[2]

    #expect(abs(ratio0 - ratio1) < 1e-10)
    #expect(abs(ratio1 - ratio2) < 1e-10)

    let ratio3 = result.pixels[3] / pixels[3]
    let ratio4 = result.pixels[4] / pixels[4]
    let ratio5 = result.pixels[5] / pixels[5]

    #expect(abs(ratio3 - ratio4) < 1e-10)
    #expect(abs(ratio4 - ratio5) < 1e-10)
  }

  @Test("Additive brightness shifts all channels equally preserving chromatic differences")
  func brightnessPreservesChromaticDifferences() {
    let pixels: [Double] = [0.1, 0.3, 0.7, 0.05, 0.5, 1.5]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(brightness: 0.5)

    let result = image.applyingLinearToneAdjustments(params)

    let d0_orig = pixels[2] - pixels[0]
    let d0_result = result.pixels[2] - result.pixels[0]
    #expect(abs(d0_result - d0_orig) < 1e-12)

    let d1_orig = pixels[5] - pixels[3]
    let d1_result = result.pixels[5] - result.pixels[3]
    #expect(abs(d1_result - d1_orig) < 1e-12)
  }

  @Test("Gain floor prevents total blackout even at extreme negative values")
  func gainFloorPreventsTotalBlackout() {
    let pixels: [Double] = [0.5, 0.5, 0.5]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(brightness: -1, highlights: 1, shadows: -1)

    let result = image.applyingLinearToneAdjustments(params)

    for pixel in result.pixels {
      #expect(pixel > 0)
      #expect(pixel.isFinite)
    }
  }

  @Test("Tone-adjusted image has same dimensions as input")
  func dimensionsPreserved() {
    let image = RenderReadyLinearImage(width: 20, height: 5, pixels: [Double](repeating: 0.18, count: 300))
    let params = PhotoAdjustmentParameters(exposureEV: 1, contrast: 0.5)

    let result = image.applyingLinearToneAdjustments(params)

    #expect(result.width == 20)
    #expect(result.height == 5)
    #expect(result.pixels.count == 300)
  }

  @Test("Negative pixels handled gracefully by contrast control")
  func negativePixelsInContrast() {
    let pixels: [Double] = [-0.1, -0.1, -0.1, 0.18, 0.18, 0.18]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(contrast: 1)

    let result = image.applyingLinearToneAdjustments(params)

    #expect(result.pixels[0] == pixels[0])
    #expect(result.pixels[1] == pixels[1])
    #expect(result.pixels[2] == pixels[2])
  }

  @Test("Tone adjustments do not introduce NaN or infinity")
  func noNaNOrInfinity() {
    let pixels: [Double] = [0, 0.18, 1, 5, 0.1, 0.2, 0.000001, 0.000001, 0.000001]
    let image = makeImage(pixels: pixels)
    let params = PhotoAdjustmentParameters(
      exposureEV: 4,
      brightness: 1,
      contrast: 1,
      highlights: 1,
      shadows: 1
    )

    let result = image.applyingLinearToneAdjustments(params)

    for pixel in result.pixels {
      #expect(!pixel.isNaN)
      #expect(pixel != .infinity)
      #expect(pixel != -.infinity)
      #expect(pixel.isFinite)
    }
  }
}
