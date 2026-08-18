import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Adaptive display looks")
struct AdaptiveDisplayLookTests {
  @Test("Prototype recipes keep Kodachrome-like Auto targets unchanged")
  func kodachromeRecipeMatchesHistoricalTargets() {
    #expect(AdaptiveDisplayLook.kodachromeLike.targetShadow == 0.058)
    #expect(AdaptiveDisplayLook.kodachromeLike.targetMidtone == 0.285)
    #expect(AdaptiveDisplayLook.kodachromeLike.targetHighlight == 0.790)
    #expect(AdaptiveDisplayLook.kodachromeLike.photoAdjustments.saturation == 0.25)
    #expect(AdaptiveDisplayLook.kodachromeLike.photoAdjustments.vibrance == 0.25)
    #expect(AdaptiveDisplayLook.kodachromeLike.highlightWheel.isNeutral)
    #expect(AdaptiveDisplayLook.kodachromeLike.shadowWheel.isNeutral)
  }

  @Test("Prototype looks install distinct tone envelopes and split-tones")
  func prototypesAreDistinctFromKodachrome() {
    #expect(AdaptiveDisplayLook.prototypes.count == 4)
    for look in AdaptiveDisplayLook.prototypes {
      #expect(look.name != AdaptiveDisplayLook.kodachromeLike.name)
      #expect(
        look.targetMidtone != AdaptiveDisplayLook.kodachromeLike.targetMidtone
          || !look.shadowWheel.isNeutral
          || look.photoAdjustments.temperatureShiftMired != 0
      )
    }
    #expect(
      AdaptiveDisplayLook.nightCinema.targetMidtone
        < AdaptiveDisplayLook.kodachromeLike.targetMidtone)
    #expect(
      AdaptiveDisplayLook.goldenCream.targetMidtone
        > AdaptiveDisplayLook.kodachromeLike.targetMidtone)
    #expect(
      AdaptiveDisplayLook.daylightPrint.targetHighlight
        > AdaptiveDisplayLook.kodachromeLike.targetHighlight)
    #expect(AdaptiveDisplayLook.blueHour.photoAdjustments.temperatureShiftMired < 0)
    #expect(AdaptiveDisplayLook.nightCinema.shadowWheel.hue > 180)
    #expect(AdaptiveDisplayLook.nightCinema.highlightWheel.hue < 60)
  }

  @Test("Night Cinema preserves geometry and installs a teal/orange correction")
  func nightCinemaPreservesGeometry() {
    let image = syntheticNegative(width: 40, height: 30)
    let crop = RotatedRect(centerX: 0.5, centerY: 0.5, width: 0.8, height: 0.7, angle: 0)
    var base = ProcessingParameters(
      borderCrop: 3,
      flip: true,
      rotation: 1,
      straightenAngle: 1.25,
      filmType: .slide,
      gamma: 20,
      temperature: 15,
      saturation: 70,
      cropRect: crop
    )
    base.densityPipelineEnabled = true
    base.redCurveEnabled = true
    base.redCurveControlPoints = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]

    let result = AdaptiveDisplayLook.nightCinema.parameters(
      for: image,
      preserving: base,
      borderPercent: 0
    )

    #expect(result.borderCrop == base.borderCrop)
    #expect(result.flip == base.flip)
    #expect(result.rotation == base.rotation)
    #expect(result.straightenAngle == base.straightenAngle)
    #expect(result.cropRect == base.cropRect)
    #expect(result.filmType == .colourNegative)
    #expect(result.filmNegativeParams.enabled)
    #expect(result.filmNegativeParams.measuredMedians != nil)
    #expect(!result.densityPipelineEnabled)
    #expect(result.gamma == 0)
    #expect(result.temperature == 0)
    #expect(result.saturation == 100)
    #expect(result.photoAdjustments.temperatureShiftMired == -10)
    #expect(result.shadowWheel.hue == 198)
    #expect(result.highlightWheel.hue == 38)
    #expect(!result.redCurveEnabled)
    #expect(result.curveEnabled)
    #expect(result.curveControlPoints[1].output == AdaptiveDisplayLook.nightCinema.targetShadow)
    #expect(result.curveControlPoints[2].output == AdaptiveDisplayLook.nightCinema.targetMidtone)
    #expect(result.curveControlPoints[3].output == AdaptiveDisplayLook.nightCinema.targetHighlight)
  }

  @Test("Adaptive curve maps display percentiles into a custom tone envelope")
  func adaptiveCurveHonorsCustomTargets() throws {
    let width = 1_000
    let values = (0..<width).map { UInt16(Double($0) / Double(width - 1) * 65_535) }
    let image = UInt16Image(
      width: width,
      height: 1,
      channels: 3,
      pixels: values.flatMap { [$0, $0, $0] }
    )
    let look = AdaptiveDisplayLook.goldenCream
    let curve = try #require(
      AdaptiveDisplayLook.adaptiveCurve(
        for: image,
        borderPercent: 0,
        targetShadow: look.targetShadow,
        targetMidtone: look.targetMidtone,
        targetHighlight: look.targetHighlight
      )
    )
    #expect(abs(curve[1].input - 0.05) < 0.005)
    #expect(abs(curve[2].input - 0.50) < 0.005)
    #expect(abs(curve[3].input - 0.95) < 0.005)
    #expect(curve[1].output == look.targetShadow)
    #expect(curve[2].output == look.targetMidtone)
    #expect(curve[3].output == look.targetHighlight)
  }

  private func syntheticNegative(width: Int, height: Int) -> UInt16Image {
    var pixels: [UInt16] = []
    pixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let amount = Double((x * 37 + y * 17) % 997) / 996
        pixels.append(UInt16((0.30 + amount * 0.65) * 65_535))
        pixels.append(UInt16((0.22 + amount * 0.68) * 65_535))
        pixels.append(UInt16((0.38 + amount * 0.60) * 65_535))
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }
}
