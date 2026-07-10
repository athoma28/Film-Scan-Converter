import Foundation
import Testing

@testable import FilmScanEngine

private let kodachromeLookRepositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private var kodachromeReferencePairAvailable: Bool {
  FileManager.default.fileExists(
    atPath: kodachromeLookRepositoryRoot.appending(path: "sample-raw/DSCF2879.JPG").path)
}

@Suite("Kodachrome-like adaptive look")
struct KodachromeLikeLookTests {
  @Test("Adaptive curve maps display percentiles into the reference tone envelope")
  func adaptiveCurveMapsReferencePercentiles() throws {
    let width = 1_000
    let values = (0..<width).map { UInt16(Double($0) / Double(width - 1) * 65_535) }
    let image = UInt16Image(
      width: width,
      height: 1,
      channels: 3,
      pixels: values.flatMap { [$0, $0, $0] }
    )

    let curve = try #require(
      KodachromeLikeLook.adaptiveCurve(for: image, borderPercent: 0)
    )
    #expect(curve.count == 5)
    #expect(abs(curve[1].input - 0.05) < 0.005)
    #expect(abs(curve[2].input - 0.50) < 0.005)
    #expect(abs(curve[3].input - 0.95) < 0.005)
    #expect(curve[1].output == KodachromeLikeLook.targetShadow)
    #expect(curve[2].output == KodachromeLikeLook.targetMidtone)
    #expect(curve[3].output == KodachromeLikeLook.targetHighlight)

    var parameters = ProcessingParameters()
    parameters.curveEnabled = true
    parameters.curveControlPoints = curve
    let corrected = FilmProcessing.applyCurves(
      image: image.pixels.map(Double.init),
      pixelCount: width,
      channels: 3,
      parameters: parameters
    )
    func output(at fraction: Double) -> Double {
      corrected[Int(fraction * Double(width - 1)) * 3] / 65_535
    }
    #expect(abs(output(at: 0.05) - KodachromeLikeLook.targetShadow) < 0.003)
    #expect(abs(output(at: 0.50) - KodachromeLikeLook.targetMidtone) < 0.003)
    #expect(abs(output(at: 0.95) - KodachromeLikeLook.targetHighlight) < 0.003)
  }

  @Test("Preset preserves frame geometry and installs an adaptive color-negative correction")
  func presetPreservesGeometry() {
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

    let result = KodachromeLikeLook.parameters(for: image, preserving: base, borderPercent: 0)

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
    #expect(result.photoAdjustments.saturation == 0.25)
    #expect(result.photoAdjustments.vibrance == 0.25)
    #expect(!result.redCurveEnabled)
  }

  @Test(
    "DSCF2879 receives the adaptive correction missing from per-frame auto color",
    .enabled(
      if: kodachromeReferencePairAvailable,
      "DSCF2879 reference sample unavailable; adaptive look regression skipped")
  )
  func adaptsDSCF2879() throws {
    let url = kodachromeLookRepositoryRoot.appending(path: "sample-raw/DSCF2879.JPG")
    let image = try StandardImageDecoder.decodePreview(url, maxDimension: 1_200)
    let result = KodachromeLikeLook.parameters(
      for: image,
      preserving: ProcessingParameters(rotation: 3),
      borderPercent: 20
    )

    #expect(result.rotation == 3)
    #expect(result.curveEnabled)
    #expect(result.curveControlPoints.count == 5)
    #expect(result.curveControlPoints[1].output == KodachromeLikeLook.targetShadow)
    #expect(result.curveControlPoints[2].output == KodachromeLikeLook.targetMidtone)
    #expect(result.curveControlPoints[3].output == KodachromeLikeLook.targetHighlight)
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
