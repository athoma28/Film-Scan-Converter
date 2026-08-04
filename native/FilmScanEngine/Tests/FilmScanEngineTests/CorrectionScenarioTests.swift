import CryptoKit
import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Full-resolution correction scenarios")
struct CorrectionScenarioTests {
  private static func syntheticImage(width: Int = 256, height: Int = 192) -> UInt16Image {
    var pixels = [UInt16]()
    pixels.reserveCapacity(width * height * 3)
    var state: UInt64 = 0x4d59_5df4_d0f3_3173
    for _ in 0..<(width * height * 3) {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      pixels.append(UInt16(truncatingIfNeeded: state >> 16))
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private static func syntheticBaseParameters() -> ProcessingParameters {
    let image = Self.syntheticImage()
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: image)
    return ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative
    )
  }

  private static func sha256(_ pixels: [UInt16]) -> String {
    pixels.withUnsafeBytes {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
  }

  @Test("Inventory matches the five documented scenarios in order")
  func inventoryMatchesDocumentedOrder() {
    #expect(
      CorrectionScenario.allCases.map(\.rawValue)
        == ["neutral", "tone", "protectedColor", "dyeMixing", "combined"])
    #expect(
      Set(CorrectionScenario.allCases.map(\.displayName)).count
        == CorrectionScenario.allCases.count)
  }

  @Test("Neutral scenario guarantees neutral adjustments")
  func neutralGuaranteesNeutrality() {
    let parameters = CorrectionScenario.neutral.processingParameters(
      base: Self.syntheticBaseParameters())
    #expect(parameters.photoAdjustments.isNeutral)
    #expect(parameters.filmDyeMixing.isNeutral)
  }

  @Test("Tone scenario activates tone but not color or dye mixing")
  func toneActivatesToneOnly() {
    let parameters = CorrectionScenario.tone.processingParameters(
      base: Self.syntheticBaseParameters())
    #expect(parameters.photoAdjustments.hasToneAdjustment)
    #expect(!parameters.photoAdjustments.hasColorAdjustment)
    #expect(parameters.filmDyeMixing.isNeutral)
  }

  @Test("Protected-color scenario activates color but not tone or dye mixing")
  func protectedColorActivatesColorOnly() {
    let parameters = CorrectionScenario.protectedColor.processingParameters(
      base: Self.syntheticBaseParameters())
    #expect(parameters.photoAdjustments.hasColorAdjustment)
    #expect(!parameters.photoAdjustments.hasToneAdjustment)
    #expect(parameters.filmDyeMixing.isNeutral)
  }

  @Test("Dye-mixing scenario activates dye mixing but no photo adjustments")
  func dyeMixingActivatesDyeMixingOnly() {
    let parameters = CorrectionScenario.dyeMixing.processingParameters(
      base: Self.syntheticBaseParameters())
    #expect(!parameters.filmDyeMixing.isNeutral)
    #expect(parameters.photoAdjustments.isNeutral)
  }

  @Test("Combined scenario activates tone, protected color, and dye mixing")
  func combinedActivatesEverything() {
    let parameters = CorrectionScenario.combined.processingParameters(
      base: Self.syntheticBaseParameters())
    #expect(parameters.photoAdjustments.hasToneAdjustment)
    #expect(parameters.photoAdjustments.hasColorAdjustment)
    #expect(!parameters.filmDyeMixing.isNeutral)
  }

  @Test("Scenarios preserve base film type, film-negative parameters, and geometry")
  func scenariosPreserveBaseContract() {
    let base = Self.syntheticBaseParameters()
    for scenario in CorrectionScenario.allCases {
      let parameters = scenario.processingParameters(base: base)
      #expect(parameters.filmType == base.filmType, "\(scenario.rawValue) film type")
      #expect(
        parameters.filmNegativeParams == base.filmNegativeParams,
        "\(scenario.rawValue) film-negative parameters")
      #expect(parameters.cropRect == base.cropRect, "\(scenario.rawValue) crop")
      #expect(
        parameters.perspectiveCrop == base.perspectiveCrop,
        "\(scenario.rawValue) perspective")
      #expect(parameters.manualCrop == base.manualCrop, "\(scenario.rawValue) manual crop")
    }
  }

  @Test("Scenario passes match the documented correction seam in pipeline order")
  func passesMatchSeam() {
    #expect(CorrectionScenario.neutral.passes == [])
    #expect(CorrectionScenario.tone.passes == ["linearTone"])
    #expect(CorrectionScenario.protectedColor.passes == ["protectedColor"])
    #expect(CorrectionScenario.dyeMixing.passes == ["filmDyeMixing"])
    #expect(
      CorrectionScenario.combined.passes
        == ["filmDyeMixing", "linearTone", "protectedColor"])
  }

  @Test("Corrected pixels are deterministic per scenario")
  func correctedPixelsAreDeterministic() {
    let image = Self.syntheticImage()
    let base = Self.syntheticBaseParameters()
    for scenario in CorrectionScenario.allCases {
      let parameters = scenario.processingParameters(base: base)
      let first = FilmProcessing.correctedPreview(image: image, parameters: parameters)
      let second = FilmProcessing.correctedPreview(image: image, parameters: parameters)
      #expect(
        Self.sha256(first.pixels) == Self.sha256(second.pixels),
        "\(scenario.rawValue) corrected pixels repeat deterministically")
    }
  }

  @Test("Adjusted scenarios change corrected pixels from the neutral baseline")
  func adjustedScenariosChangePixels() {
    let image = Self.syntheticImage()
    let base = Self.syntheticBaseParameters()
    let neutralHash = Self.sha256(
      FilmProcessing.correctedPreview(
        image: image,
        parameters: CorrectionScenario.neutral.processingParameters(base: base)
      ).pixels
    )
    for scenario in [CorrectionScenario.tone, .protectedColor, .dyeMixing, .combined] {
      let corrected = FilmProcessing.correctedPreview(
        image: image,
        parameters: scenario.processingParameters(base: base)
      )
      #expect(
        Self.sha256(corrected.pixels) != neutralHash,
        "\(scenario.rawValue) must change corrected pixels from the neutral baseline")
    }
  }

  @Test("Scenario inventory is Codable and round-trips stably")
  func codableRoundTrip() throws {
    let encoded = try JSONEncoder().encode(CorrectionScenario.allCases)
    let decoded = try JSONDecoder().decode([CorrectionScenario].self, from: encoded)
    #expect(decoded == CorrectionScenario.allCases)
  }
}
