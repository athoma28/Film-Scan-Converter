import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Protected photographic color adjustments")
struct ProtectedColorAdjustmentTests {
  @Test("Neutral color parameters preserve every sample exactly")
  func neutralIsExactIdentity() {
    let pixels: [Double] = [-0.25, 0, 0.5, 0.1, 1.2, 4]
    let image = RenderReadyLinearImage(width: 2, height: 1, pixels: pixels)

    let adjusted = image.applyingProtectedColorAdjustments(.init())

    #expect(adjusted.pixels == pixels)
  }

  @Test("Saturation and vibrance preserve neutral grayscale")
  func chromaControlsPreserveGrayscale() {
    let pixels: [Double] = [0, 0, 0, 0.18, 0.18, 0.18, 1.5, 1.5, 1.5]
    let image = RenderReadyLinearImage(width: 3, height: 1, pixels: pixels)
    let parameters = PhotoAdjustmentParameters(saturation: 1, vibrance: 1)

    let adjusted = image.applyingProtectedColorAdjustments(parameters)

    assertEqual(adjusted.pixels, pixels)
  }

  @Test("Saturation increases opponent chroma without changing luminance")
  func saturationPreservesLuminance() {
    let image = RenderReadyLinearImage(width: 1, height: 1, pixels: [0.08, 0.25, 0.7])
    let adjusted = image.applyingProtectedColorAdjustments(
      PhotoAdjustmentParameters(saturation: 0.6)
    )

    #expect(opponentChroma(adjusted.pixels) > opponentChroma(image.pixels))
    #expect(abs(luminance(adjusted.pixels) - luminance(image.pixels)) < 1e-12)
  }

  @Test("Positive vibrance favors muted colors over already saturated colors")
  func vibranceIsSelective() {
    let muted = RenderReadyLinearImage(width: 1, height: 1, pixels: [0.28, 0.30, 0.34])
    let saturated = RenderReadyLinearImage(width: 1, height: 1, pixels: [0.02, 0.12, 0.72])
    let parameters = PhotoAdjustmentParameters(vibrance: 1)

    let mutedAdjusted = muted.applyingProtectedColorAdjustments(parameters)
    let saturatedAdjusted = saturated.applyingProtectedColorAdjustments(parameters)
    let mutedGain = opponentChroma(mutedAdjusted.pixels) / opponentChroma(muted.pixels)
    let saturatedGain = opponentChroma(saturatedAdjusted.pixels) / opponentChroma(saturated.pixels)

    #expect(mutedGain > saturatedGain)
    #expect(saturatedGain >= 1)
  }

  @Test("Temperature and tint use luminance-preserving opponent axes")
  func temperatureAndTintUseOpponentAxes() {
    let gray = RenderReadyLinearImage(width: 2, height: 1, pixels: [0, 0, 0, 0.25, 0.25, 0.25])
    let warm = gray.applyingProtectedColorAdjustments(
      PhotoAdjustmentParameters(temperatureShiftMired: 100)
    )
    let magenta = gray.applyingProtectedColorAdjustments(
      PhotoAdjustmentParameters(tint: 1)
    )

    #expect(warm.pixels[0] == 0 && warm.pixels[1] == 0 && warm.pixels[2] == 0)
    #expect(warm.pixels[5] > warm.pixels[3])
    #expect(magenta.pixels[5] > magenta.pixels[4])
    #expect(magenta.pixels[3] > magenta.pixels[4])
    #expect(abs(luminance(Array(warm.pixels[3...5])) - 0.25) < 1e-12)
    #expect(abs(luminance(Array(magenta.pixels[3...5])) - 0.25) < 1e-12)
  }

  @Test("Highlight protection attenuates color shifts above display white")
  func highlightProtectionAttenuatesAdjustments() {
    let image = RenderReadyLinearImage(
      width: 2,
      height: 1,
      pixels: [0.25, 0.25, 0.25, 2, 2, 2]
    )
    let adjusted = image.applyingProtectedColorAdjustments(
      PhotoAdjustmentParameters(temperatureShiftMired: 100, tint: 1)
    )

    let lowRelativeShift = opponentChroma(Array(adjusted.pixels[0...2])) / 0.25
    let highRelativeShift = opponentChroma(Array(adjusted.pixels[3...5])) / 2
    #expect(highRelativeShift < lowRelativeShift * 0.35)
  }

  @Test("Gamut protection reduces chroma without rotating opponent hue")
  func gamutProtectionPreservesHue() {
    let image = RenderReadyLinearImage(width: 1, height: 1, pixels: [0.01, 0.05, 0.95])
    let adjusted = image.applyingProtectedColorAdjustments(
      PhotoAdjustmentParameters(saturation: 1, vibrance: 1)
    )
    let sourceOpponent = opponent(image.pixels)
    let adjustedOpponent = opponent(adjusted.pixels)
    let cosine = dot(sourceOpponent, adjustedOpponent)
      / (magnitude(sourceOpponent) * magnitude(adjustedOpponent))

    #expect(adjusted.pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(cosine > 0.999_999)
    #expect(abs(luminance(adjusted.pixels) - luminance(image.pixels)) < 1e-12)
  }

  @Test("Protected color controls produce finite output for invalid samples")
  func nonNeutralAdjustmentSanitizesInvalidInput() {
    let image = RenderReadyLinearImage(
      width: 2,
      height: 1,
      pixels: [.nan, .infinity, -.infinity, -1, 2, 10]
    )

    let adjusted = image.applyingProtectedColorAdjustments(
      PhotoAdjustmentParameters(tint: 0.25, saturation: 0.5)
    )

    #expect(adjusted.pixels.allSatisfy { $0.isFinite })
  }

  private func luminance(_ bgr: [Double]) -> Double {
    0.0593017 * bgr[0] + 0.6780 * bgr[1] + 0.2626983 * bgr[2]
  }

  private func opponent(_ bgr: [Double]) -> [Double] {
    let y = luminance(bgr)
    return [bgr[0] - y, bgr[1] - y, bgr[2] - y]
  }

  private func opponentChroma(_ bgr: [Double]) -> Double {
    magnitude(opponent(bgr))
  }

  private func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
    zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
  }

  private func magnitude(_ values: [Double]) -> Double {
    sqrt(dot(values, values))
  }

  private func assertEqual(_ actual: [Double], _ expected: [Double], tolerance: Double = 1e-12) {
    #expect(actual.count == expected.count)
    for index in actual.indices {
      #expect(abs(actual[index] - expected[index]) <= tolerance)
    }
  }
}
