import Foundation
import Testing

@testable import FilmScanEngine

/// Regression coverage for the in-place, parallelized linear-seam operators.
///
/// These tests pin the contract that the new mutating variants reproduce the
/// copy-based reference math exactly (bit-for-bit), and that the parallel path
/// used above the one-megapixel threshold is deterministic.
@Suite("Render-ready linear seam in-place operators")
struct RenderReadyLinearSeamTests {
  private static let parallelThreshold = 1_000_000

  private func makeLinearImage(pixels: [Double]) -> RenderReadyLinearImage {
    precondition(pixels.count.isMultiple(of: 3))
    return RenderReadyLinearImage(width: pixels.count / 3, height: 1, pixels: pixels)
  }

  private func deterministicLinearPixels(pixelCount: Int) -> [Double] {
    var state: UInt64 = 0x9e37_79b9_7f4a_7c15
    var pixels = [Double]()
    pixels.reserveCapacity(pixelCount * 3)
    for _ in 0..<(pixelCount * 3) {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      pixels.append(Double(state >> 40) / Double(1 << 24) * 8.0 + 0.0001)
    }
    return pixels
  }

  private func deterministicUInt16Pixels(pixelCount: Int) -> [UInt16] {
    var state: UInt64 = 0x4d59_5df4_d0f3_3173
    var pixels = [UInt16]()
    pixels.reserveCapacity(pixelCount * 3)
    for _ in 0..<(pixelCount * 3) {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      pixels.append(UInt16(truncatingIfNeeded: state >> 16))
    }
    return pixels
  }

  @Test("In-place tone adjustment matches the copy-based reference exactly")
  func inPlaceToneMatchesCopy() {
    let pixels: [Double] = [
      0.0, 0.18, 1.0,
      -0.1, 1.5, 8.0,
      0.0003, 0.0003, 0.0003,
      0.02, 0.5, 2.0,
    ]
    let image = makeLinearImage(pixels: pixels)
    let parameters = PhotoAdjustmentParameters(
      exposureEV: 0.5, brightness: -0.3, contrast: 0.6, highlights: 0.4, shadows: -0.5
    )
    let reference = image.applyingLinearToneAdjustments(
      parameters,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction
    )
    var inPlace = image
    inPlace.applyLinearToneAdjustments(
      parameters,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction
    )
    #expect(inPlace == reference)
  }

  @Test("In-place protected-color adjustment matches the copy-based reference exactly")
  func inPlaceProtectedColorMatchesCopy() {
    let pixels: [Double] = [
      0.0, 0.0, 0.0,
      0.18, 0.18, 0.18,
      0.08, 0.25, 0.7,
      0.02, 0.12, 0.72,
      2.0, 2.0, 2.0,
    ]
    let image = makeLinearImage(pixels: pixels)
    let parameters = PhotoAdjustmentParameters(
      temperatureShiftMired: 40, tint: 0.2, saturation: 0.5, vibrance: 0.4
    )
    let reference = image.applyingProtectedColorAdjustments(parameters)
    var inPlace = image
    inPlace.applyProtectedColorAdjustments(parameters)
    #expect(inPlace == reference)
  }

  @Test("In-place dye mixing matches the copy-based reference exactly")
  func inPlaceDyeMixingMatchesCopy() {
    let pixels: [Double] = [
      0.35, 0.35, 0.35,
      0.20, 0.40, 0.80,
      0.01, 0.90, 0.30,
    ]
    let image = makeLinearImage(pixels: pixels)
    let mixing = FilmDyeMixingParameters(
      redFromGreen: -0.08, redFromBlue: 0.04,
      greenFromRed: 0.03, greenFromBlue: -0.06,
      blueFromRed: 0.07, blueFromGreen: -0.03
    )
    let reference = image.applyingFilmDyeMixing(mixing)
    var inPlace = image
    inPlace.applyFilmDyeMixing(mixing)
    #expect(inPlace == reference)
  }

  @Test("In-place combined sequence matches the copy-based sequence exactly")
  func inPlaceCombinedSequenceMatchesCopySequence() {
    let pixels: [Double] = [
      0.0, 0.18, 1.0,
      0.08, 0.25, 0.7,
      0.02, 0.12, 0.72,
      0.0003, 0.0003, 0.0003,
    ]
    let image = makeLinearImage(pixels: pixels)
    let tone = PhotoAdjustmentParameters(
      exposureEV: -0.75, brightness: 0.2, contrast: 0.4, highlights: -0.3, shadows: 0.3
    )
    let color = PhotoAdjustmentParameters(
      temperatureShiftMired: 40, tint: 0.2, saturation: 0.5, vibrance: 0.4
    )
    let mixing = FilmDyeMixingParameters(
      redFromGreen: -0.08, redFromBlue: 0.04,
      greenFromRed: 0.03, greenFromBlue: -0.06,
      blueFromRed: 0.07, blueFromGreen: -0.03
    )

    var reference = image.applyingFilmDyeMixing(mixing)
    reference = reference.applyingLinearToneAdjustments(
      tone, referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction)
    reference = reference.applyingProtectedColorAdjustments(color)

    var inPlace = image
    inPlace.applyFilmDyeMixing(mixing)
    inPlace.applyLinearToneAdjustments(
      tone, referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction)
    inPlace.applyProtectedColorAdjustments(color)

    #expect(inPlace == reference)
  }

  @Test("Large-image in-place tone adjustment matches copy reference and is deterministic")
  func largeImageToneInPlaceMatchesCopy() {
    let pixelCount = Self.parallelThreshold + 100_000
    let pixels = deterministicLinearPixels(pixelCount: pixelCount)
    let image = RenderReadyLinearImage(width: pixelCount, height: 1, pixels: pixels)
    let parameters = PhotoAdjustmentParameters(
      exposureEV: -0.75, brightness: 0.2, contrast: 0.4, highlights: -0.3, shadows: 0.3
    )

    let reference = image.applyingLinearToneAdjustments(
      parameters,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction
    )
    var inPlace = image
    inPlace.applyLinearToneAdjustments(
      parameters,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction
    )

    #expect(inPlace == reference)
    #expect(inPlace == image.applyingLinearToneAdjustments(
      parameters,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction))
  }

  @Test("Large-image in-place protected-color adjustment matches copy reference")
  func largeImageProtectedColorInPlaceMatchesCopy() {
    let pixelCount = Self.parallelThreshold + 100_000
    let pixels = deterministicLinearPixels(pixelCount: pixelCount)
    let image = RenderReadyLinearImage(width: pixelCount, height: 1, pixels: pixels)
    let parameters = PhotoAdjustmentParameters(
      temperatureShiftMired: 40, tint: 0.2, saturation: 0.5, vibrance: 0.4
    )

    let reference = image.applyingProtectedColorAdjustments(parameters)
    var inPlace = image
    inPlace.applyProtectedColorAdjustments(parameters)

    #expect(inPlace == reference)
  }

  @Test("Large-image dye mixing is deterministic")
  func largeImageDyeMixingIsDeterministic() {
    let pixelCount = Self.parallelThreshold + 100_000
    let pixels = deterministicLinearPixels(pixelCount: pixelCount)
    let image = RenderReadyLinearImage(width: pixelCount, height: 1, pixels: pixels)
    let mixing = FilmDyeMixingParameters(
      redFromGreen: -0.08, redFromBlue: 0.04,
      greenFromRed: 0.03, greenFromBlue: -0.06,
      blueFromRed: 0.07, blueFromGreen: -0.03
    )

    var first = image
    first.applyFilmDyeMixing(mixing)
    var second = image
    second.applyFilmDyeMixing(mixing)

    #expect(first == second)
    #expect(first == image.applyingFilmDyeMixing(mixing))
  }

  @Test("Large-image calibrated-color combined correction is deterministic")
  func largeImageCalibratedColorCombinedCorrectionIsDeterministic() {
    let pixelCount = Self.parallelThreshold + 100_000
    let image = UInt16Image(
      width: pixelCount, height: 1, channels: 3,
      pixels: deterministicUInt16Pixels(pixelCount: pixelCount)
    )
    let base = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: FilmNegativeParams.colourNegative
    )
    let parameters = CorrectionScenario.combined.processingParameters(base: base)

    let first = FilmProcessing.correctedPreview(image: image, parameters: parameters)
    let second = FilmProcessing.correctedPreview(image: image, parameters: parameters)

    #expect(first == second)
  }

  @Test("Large-image power-law adjusted correction is deterministic")
  func largeImagePowerLawAdjustedCorrectionIsDeterministic() {
    let pixelCount = Self.parallelThreshold + 100_000
    let image = UInt16Image(
      width: pixelCount, height: 1, channels: 3,
      pixels: deterministicUInt16Pixels(pixelCount: pixelCount)
    )
    var filmNegative = FilmNegativeParams.legacyColourNegative
    filmNegative.measuredMedians = BGRChannelValues(blue: 20_000, green: 26_000, red: 32_000)
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      filmDyeMixing: FilmDyeMixingParameters(
        redFromGreen: -0.08, redFromBlue: 0.04,
        greenFromRed: 0.03, greenFromBlue: -0.06,
        blueFromRed: 0.07, blueFromGreen: -0.03
      ),
      photoAdjustments: PhotoAdjustmentParameters(
        exposureEV: -0.75, brightness: 0.2, contrast: 0.4, highlights: -0.3, shadows: 0.3,
        temperatureShiftMired: 40, tint: 0.2, saturation: 0.5, vibrance: 0.4
      )
    )

    let first = FilmProcessing.correctedPreview(image: image, parameters: parameters)
    let second = FilmProcessing.correctedPreview(image: image, parameters: parameters)

    #expect(first == second)
  }
}
