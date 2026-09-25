import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Opt-in focused highlight and shadow response")
struct FocusedToneResponseTests {
  private func encoded(_ x: Double, _ parameters: PhotoAdjustmentParameters) -> Double {
    PhotographicTone.encode(
      PhotographicTone.luminance(PhotographicTone.decode(x), parameters: parameters))
  }

  @Test("All version 3 control corners and individual limits retain strict tone order")
  func monotonicControls() {
    let keys: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.exposureEV, \.brightness, \.contrast, \.highlights, \.shadows,
    ]
    var cases = [PhotoAdjustmentParameters(schemaVersion: 3)]
    for key in keys {
      for value in [-1.0, -0.25, 0.25, 1] {
        var p = PhotoAdjustmentParameters(schemaVersion: 3)
        p[keyPath: key] = value * (key == \.exposureEV ? 4 : 1)
        cases.append(p)
      }
    }
    for corner in 0..<32 {
      var p = PhotoAdjustmentParameters(schemaVersion: 3)
      for (index, key) in keys.enumerated() {
        p[keyPath: key] =
          (corner & (1 << index) == 0 ? -1 : 1)
          * (key == \.exposureEV ? 4 : 1)
      }
      cases.append(p)
    }
    for p in cases {
      var previous = -1.0
      for sample in 0...4096 {
        let output = PhotographicTone.luminance(
          PhotographicTone.decode(Double(sample) / 4096), parameters: p)
        #expect(output.isFinite && output >= 0 && output < 1)
        #expect(output > previous, "Tone reversal at \(sample), \(p)")
        previous = output
      }
      #expect(PhotographicTone.luminance(0, parameters: p) == 0)
    }
  }

  @Test("Focused ranges keep their direction, endpoints and unit-slope interior joins")
  func rangeDirectionAndJoins() {
    let neutral = PhotoAdjustmentParameters(schemaVersion: 3)
    let epsilon = 1e-6
    for amount in [-1.0, -0.25, 0.25, 1] {
      let shadows = PhotoAdjustmentParameters(schemaVersion: 3, shadows: amount)
      let highlights = PhotoAdjustmentParameters(schemaVersion: 3, highlights: amount)
      for x in [0.05, 0.2, 0.5] {
        #expect((encoded(x, shadows) - encoded(x, neutral)) * amount > 0)
      }
      for x in [0.5, 0.75, 0.95] {
        #expect((encoded(x, highlights) - encoded(x, neutral)) * amount > 0)
      }
      for p in [shadows, highlights] {
        #expect(PhotographicTone.luminance(0, parameters: p) == 0)
        #expect(
          PhotographicTone.luminance(1, parameters: p)
            == PhotographicTone.luminance(1, parameters: neutral))
      }
      for (join, p) in [(0.65, shadows), (0.4, highlights)] {
        let center = encoded(join, p)
        let leftSlope = (center - encoded(join - epsilon, p)) / epsilon
        let rightSlope = (encoded(join + epsilon, p) - center) / epsilon
        #expect(abs(leftSlope - 1) < 2e-5)
        #expect(abs(rightSlope - 1) < 2e-5)
      }
      #expect(encoded(0.8, shadows) == encoded(0.8, neutral))
      #expect(encoded(0.3, highlights) == encoded(0.3, neutral))
    }
  }

  @Test("Small focused edits act more on tails and less on neighboring midtones")
  func responseAllocation() {
    let neutral = PhotoAdjustmentParameters(schemaVersion: 2)
    for amount in [-0.25, 0.25] {
      for highlights in [false, true] {
        let old = PhotoAdjustmentParameters(
          schemaVersion: 2, highlights: highlights ? amount : 0,
          shadows: highlights ? 0 : amount)
        var candidate = old
        candidate.schemaVersion = 3
        let tail = highlights ? 0.95 : 0.08
        let middle = highlights ? 0.6 : 0.45
        #expect(
          abs(encoded(tail, candidate) - encoded(tail, neutral))
            > abs(encoded(tail, old) - encoded(tail, neutral)))
        #expect(
          abs(encoded(middle, candidate) - encoded(middle, neutral))
            < abs(encoded(middle, old) - encoded(middle, neutral)))
      }
    }
  }

  @Test("A modest contrast increase no longer cancels this small deep-shadow lift")
  func deepShadowCombination() {
    let old = PhotoAdjustmentParameters(schemaVersion: 2, contrast: 0.1, shadows: 0.25)
    var candidate = old
    candidate.schemaVersion = 3
    for input in [0.001, 0.002, 0.005] {
      #expect(PhotographicTone.luminance(input, parameters: old) < input)
      #expect(PhotographicTone.luminance(input, parameters: candidate) > input * 1.1)
    }
  }

  @Test("Neutral focused controls preserve exact version 2 production pixels")
  func neutralRangesPreserveVersionTwo() {
    let sampleCount = 24 * 16 * 3
    let pixels: [UInt16] = (0..<sampleCount).map { index in
      let sample: Int = 2048 + (index * 149) % 60_000
      return UInt16(sample)
    }
    let image = UInt16Image(width: 24, height: 16, channels: 3, pixels: pixels)
    for base in [FilmBase.colorC41, .colorCyanMask, .slide] {
      var old = base.applyingInvert(to: ProcessingParameters())
      old.photoAdjustments = PhotoAdjustmentParameters(
        schemaVersion: 2, exposureEV: 0.4, brightness: -0.2, contrast: 0.3,
        temperatureShiftMired: 10, tint: 0.05, saturation: 0.2,
        vibrance: 0.1, warmHueRecovery: 0.15, whites: 0.1, blacks: -0.05)
      var candidate = old
      candidate.photoAdjustments.schemaVersion = 3
      #expect(
        FilmProcessing.correctedPreview(image: image, parameters: candidate)
          == FilmProcessing.correctedPreview(image: image, parameters: old))
    }
  }

  @Test("Versions 3 and 4 decode while built-in looks stay on version 2")
  func versionCompatibility() throws {
    #expect(PhotoAdjustmentParameters.currentSchemaVersion == 4)
    #expect(PhotoAdjustmentParameters.maximumSupportedSchemaVersion == 4)
    #expect(PhotoAdjustmentParameters().schemaVersion == 4)
    #expect(LookRecipe.factory.allSatisfy { $0.photoAdjustments.schemaVersion == 2 })
    for version in 1...4 {
      let original = PhotoAdjustmentParameters(
        schemaVersion: version, highlights: -0.25, shadows: 0.25)
      #expect(
        try JSONDecoder().decode(
          PhotoAdjustmentParameters.self,
          from: JSONEncoder().encode(original)) == original)
    }
    let missing = try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: Data("{}".utf8))
    #expect(missing.schemaVersion == 1)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        PhotoAdjustmentParameters.self,
        from: Data(#"{"schemaVersion":5}"#.utf8))
    }
  }

  @Test("The real app correction parser carries version 3 and retains destination base and framing")
  @MainActor
  func correctionDocument() throws {
    var source = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
    source.photoAdjustments = .init(schemaVersion: 3, highlights: -0.25, shadows: 0.25)
    let settings = CorrectionSettings(capturing: source)
    let document = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(CorrectionSettings.self, from: document)
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.recipe.photoAdjustments == source.photoAdjustments)
    var destination = FilmBase.colorCyanMask.applyingInvert(to: ProcessingParameters())
    destination.manualCrop = .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
    destination.rotation = 90
    let result = decoded.applying(to: destination)
    #expect(result.photoAdjustments == source.photoAdjustments)
    #expect(FilmBase.resolved(from: result) == .colorCyanMask)
    #expect(result.filmNegativeParams.rendering == destination.filmNegativeParams.rendering)
    #expect(
      result.filmNegativeParams.densityProfileID
        == destination.filmNegativeParams.densityProfileID)
    #expect(result.manualCrop == destination.manualCrop)
    #expect(result.rotation == destination.rotation)
  }
}
