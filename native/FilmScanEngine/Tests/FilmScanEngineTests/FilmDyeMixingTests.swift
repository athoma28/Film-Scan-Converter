import CoreGraphics
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Film dye mixing")
struct FilmDyeMixingTests {
  @Test("Dye mixing preserves neutrals while correcting directed crossover")
  func neutralPreservingDirectedMixing() {
    let input = RenderReadyLinearImage(
      width: 2,
      height: 1,
      pixels: [
        0.35, 0.35, 0.35,
        0.20, 0.40, 0.80,
      ]
    )
    let mixing = FilmDyeMixingParameters(
      redFromGreen: -0.10,
      redFromBlue: 0.20,
      greenFromRed: 0.15,
      greenFromBlue: -0.05,
      blueFromRed: 0.10,
      blueFromGreen: 0.25
    )

    let output = input.applyingFilmDyeMixing(mixing)

    #expect(output.pixels[0] == 0.35)
    #expect(output.pixels[1] == 0.35)
    #expect(output.pixels[2] == 0.35)
    #expect(abs(output.pixels[3] - 0.31) < 1e-12)
    #expect(abs(output.pixels[4] - 0.47) < 1e-12)
    #expect(abs(output.pixels[5] - 0.72) < 1e-12)
  }

  @Test("Neutral dye mixing is an exact no-op")
  func neutralIsExactNoOp() {
    let input = RenderReadyLinearImage(
      width: 1,
      height: 1,
      pixels: [-0.2, 0.5, 2.0]
    )

    let output = input.applyingFilmDyeMixing(.neutral)

    #expect(output == input)
    #expect(FilmDyeMixingParameters.neutral.isNeutral)
  }

  @Test("Power-law processing applies dye mixing before display rendering")
  func powerLawProcessingUsesDyeMixingSeam() {
    let image = UInt16Image(
      width: 2,
      height: 1,
      channels: 3,
      pixels: [8_000, 18_000, 42_000, 30_000, 34_000, 38_000]
    )
    var filmNegative = FilmNegativeParams.legacyColourNegative
    filmNegative.measuredMedians = BGRChannelValues(
      blue: 20_000, green: 26_000, red: 32_000)
    let mixing = FilmDyeMixingParameters(
      redFromGreen: -0.12,
      greenFromBlue: 0.08,
      blueFromRed: -0.06
    )
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      filmDyeMixing: mixing
    )

    let actual = FilmProcessing.correctedPreview(image: image, parameters: parameters)
    let expected = FilmNegativeProcessing.renderPowerLawDisplay(
      FilmNegativeProcessing.powerLawRenderReadyLinear(image: image, params: filmNegative)
        .applyingFilmDyeMixing(mixing)
    )

    #expect(actual == expected)
  }

  @Test("Basic positive-scan inversion applies dye mixing in linear light")
  func basicInversionUsesDyeMixingSeam() throws {
    let image = UInt16Image(
      width: 1,
      height: 1,
      channels: 3,
      pixels: [12_000, 28_000, 46_000]
    )
    let mixing = FilmDyeMixingParameters(
      redFromBlue: -0.15,
      blueFromRed: 0.10
    )
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: FilmNegativeParams(enabled: false),
      filmDyeMixing: mixing
    )

    let neutral = FilmProcessing.correctedPreview(
      image: image,
      parameters: ProcessingParameters(
        filmType: .colourNegative,
        filmNegativeParams: FilmNegativeParams(enabled: false)
      )
    )
    let actual = FilmProcessing.correctedPreview(image: image, parameters: parameters)

    #expect(actual != neutral)
    #expect(actual.width == image.width && actual.height == image.height)
    #expect(actual.channels == 3)
    try #require(actual.pixels.count == 3)
    // Independent reference: invert, apply sRGB EOTF, convert to Rec.2020,
    // mix red by -0.15*(blue-red) and blue by 0.10*(red-blue), then encode sRGB.
    // This catches mixing in display values or in the wrong linear working space.
    let expected: [UInt16] = [51747, 38026, 0]
    for index in expected.indices {
      #expect(abs(Int(actual.pixels[index]) - Int(expected[index])) <= 1)
    }
  }

  @Test("Density processing applies dye mixing on the shared linear seam")
  func densityProcessingUsesDyeMixingSeam() {
    let image = UInt16Image(
      width: 1, height: 1, channels: 3,
      pixels: [12_000, 20_000, 36_000]
    )
    let flatField = UInt16Image(
      width: 1, height: 1, channels: 3,
      pixels: [UInt16](repeating: 65_535, count: 3)
    )
    let baseDensity = BGRChannelValues(blue: 0, green: 0, red: 0)
    let mixing = FilmDyeMixingParameters(
      redFromGreen: 0.12,
      greenFromBlue: -0.08,
      blueFromRed: 0.05
    )
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmDyeMixing: mixing,
      densityPipelineEnabled: true,
      densityBaseDensity: baseDensity
    )

    let actual = FilmProcessing.correctedPreview(
      image: image,
      parameters: parameters,
      flatField: flatField
    )
    let expectedLinear = FilmNegativeProcessing.densityToRenderReadyLinear(
      image: image,
      flatField: flatField,
      baseDensity: baseDensity
    ).applyingFilmDyeMixing(mixing)
    let expected = FilmNegativeProcessing.renderDisplay(sceneLinear: expectedLinear.pixels)
      .map { UInt16(min(max($0 * 65_535, 0), 65_535)) }

    #expect(actual.pixels == expected)
  }

  @Test("Old processing settings decode with neutral dye mixing")
  func processingParametersBackwardCompatibility() throws {
    let oldDocument = """
      {
        "filmType": 1,
        "filmNegativeParams": {
          "enabled": true,
          "redRatio": 1.36,
          "greenExp": 1.5,
          "blueRatio": 0.86
        }
      }
      """

    let decoded = try JSONDecoder().decode(
      ProcessingParameters.self,
      from: Data(oldDocument.utf8)
    )

    #expect(decoded.filmDyeMixing == .neutral)
    #expect(decoded.densityCorrection == .identity)
  }

  @Test("App model clamps and resets dye mixing")
  @MainActor
  func appModelSetterContract() {
    let model = AppModel()

    model.setFilmDyeMixing(\.redFromGreen, to: 0.75)
    #expect(model.parameters.filmDyeMixing.redFromGreen == 0.5)
    model.resetFilmDyeMixing()
    #expect(model.parameters.filmDyeMixing == .neutral)
  }

  @Test("GPU dye mixing matches CPU within two display codes")
  func gpuParity() throws {
    let width = 73
    let height = 47
    let image = UInt16Image(
      width: width,
      height: height,
      channels: 3,
      pixels: (0..<(width * height * 3)).map { index in
        UInt16(truncatingIfNeeded: index &* 7_919 &+ 12_347)
      }
    )
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      filmDyeMixing: FilmDyeMixingParameters(
        redFromGreen: -0.12,
        redFromBlue: 0.08,
        greenFromRed: 0.05,
        greenFromBlue: -0.09,
        blueFromRed: 0.11,
        blueFromGreen: -0.04
      )
    )
    let renderer = try #require(StillPreviewRenderer(image: image))
    let gpu = try #require(renderer.render(parameters: parameters, showOriginal: false))
    let cpu = try #require(
      FilmProcessing.correctedPreview(image: image, parameters: parameters)
        .makePreviewCGImage()
    )
    try expectPreviewRGBPixelsMatch(
      gpu, cpu, tolerance: 2, label: "Dye mixing", requireOpaque: true)
  }
}
