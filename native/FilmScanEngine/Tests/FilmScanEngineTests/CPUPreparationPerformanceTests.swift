import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Reusable CPU preparation and bounded linear scratch")
struct CPUPreparationPerformanceTests {
  static func image(width: Int, height: Int) -> UInt16Image {
    UInt16Image(
      width: width, height: height, channels: 3,
      pixels: (0..<(width * height * 3)).map { UInt16(2_000 + ($0 * 7919) % 62_000) })
  }

  @Test("Cached geometry and Darkroom analysis preserve pixels and invalidate independently")
  func cachedPreparation() {
    let source = Self.image(width: 96, height: 64)
    let cache = CPUPreviewPreparationCache(image: source)
    var p = ProcessingParameters(rotation: 1, straightenAngle: 2, filmType: .colourNegative)
    p.manualCrop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    p.filmNegativeParams.enabled = true
    p.filmNegativeParams.rendering = .densityPrint
    for exposure in [0.0, 0.5, -0.3] {
      p.photoAdjustments.exposureEV = exposure
      #expect(
        cache.render(parameters: p) == FilmProcessing.correctedPreview(image: source, parameters: p)
      )
    }
    #expect(cache.geometryBuildCount == 1)
    #expect(cache.analysisBuildCount == 1)
    p.filmNegativeParams.densityUnmixStrength = 0.3
    #expect(
      cache.render(parameters: p) == FilmProcessing.correctedPreview(image: source, parameters: p))
    #expect(cache.geometryBuildCount == 1)
    #expect(cache.analysisBuildCount == 2)
    p.straightenAngle = -3
    #expect(
      cache.render(parameters: p) == FilmProcessing.correctedPreview(image: source, parameters: p))
    #expect(cache.geometryBuildCount == 2)
    #expect(cache.analysisBuildCount == 3)
    p.filmType = .cropOnly
    #expect(
      cache.render(parameters: p) == FilmProcessing.correctedPreview(image: source, parameters: p))
  }

  @Test("Banded color/tone seam matches a whole-frame reference exactly")
  func bandedColor() {
    let source = Self.image(width: 613, height: 433)
    let p = PhotoAdjustmentParameters(
      exposureEV: 0.4, brightness: 0.1, contrast: 0.3,
      highlights: -0.4, shadows: 0.2, temperatureShiftMired: 12, tint: -0.1,
      saturation: 0.15, vibrance: 0.2)
    var dye = FilmDyeMixingParameters()
    dye.blueFromRed = 0.12
    let expected = FilmProcessing.applySemanticLinearAdjustmentsToDisplayBand(
      source, parameters: p, dyeMixing: dye, applyColorAdjustments: true)
    let actual = FilmProcessing.applySemanticLinearAdjustmentsToDisplayImage(
      source, parameters: p, dyeMixing: dye, applyColorAdjustments: true)
    #expect(actual == expected)
  }

  @Test("Banded power-law uses whole-image medians and the original operation order")
  func bandedPowerLaw() {
    let source = Self.image(width: 613, height: 433)
    var p = ProcessingParameters(filmType: .colourNegative)
    p.filmNegativeParams.enabled = true
    p.photoAdjustments = .init(
      schemaVersion: 1, exposureEV: 0.4, contrast: 0.2, highlights: -0.3,
      shadows: 0.1, temperatureShiftMired: 10, saturation: 0.1)
    p.filmDyeMixing.blueFromRed = 0.1
    var reference = FilmNegativeProcessing.powerLawRenderReadyLinear(
      image: source, params: p.filmNegativeParams)
    reference.applyFilmDyeMixing(p.filmDyeMixing)
    reference.applyLinearToneAdjustments(
      p.photoAdjustments,
      referenceLuminance: FilmNegativeProcessing.calibrationTargetFraction)
    reference.applyProtectedColorAdjustments(p.photoAdjustments)
    let encoded = FilmNegativeProcessing.renderPowerLawDisplay(reference)
    let expected = FilmProcessing.applyDisplayPointAdjustments(
      image: encoded, parameters: p,
      usedLinearColorSeam: true, usedLinearToneSeam: true)
    #expect(FilmProcessing.correctedPreview(image: source, parameters: p) == expected)
  }

  @Test("Deferred statistics retain the same sample ranks and values")
  func statisticsSample() {
    for size in [(1, 1), (43, 79), (613, 433)] {
      let image = Self.image(width: size.0, height: size.1)
      let sample = image.previewStatisticsSample()
      #expect(
        sample.image.width * sample.image.height <= RenderReadyLinearImage.statisticsSampleLimit)
      #expect(sample.statistics() == image.previewStatistics())
    }
  }
}
