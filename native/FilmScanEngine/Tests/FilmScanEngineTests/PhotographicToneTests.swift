import Foundation
import Testing

@testable import FilmScanEngine
@testable import FilmScanPreviewRenderer

@Suite("Photographic tone controls")
struct PhotographicToneTests {
  @Test("Every main slider and all combined corners preserve tone order and endpoints")
  func monotonicControls() {
    let keys: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.exposureEV, \.brightness, \.contrast, \.highlights, \.shadows,
    ]
    var cases: [PhotoAdjustmentParameters] = [.init()]
    for key in keys {
      for value in [-1.0, -0.5, 0.5, 1] {
        var p = PhotoAdjustmentParameters()
        p[keyPath: key] = value * (key == \.exposureEV ? 4 : 1)
        cases.append(p)
      }
    }
    for corner in 0..<32 {
      var p = PhotoAdjustmentParameters()
      for (index, key) in keys.enumerated() {
        p[keyPath: key] = (corner & (1 << index) == 0 ? -1 : 1) * (key == \.exposureEV ? 4 : 1)
      }
      cases.append(p)
    }
    for p in cases {
      var previous = -1.0
      for i in 0...4096 {
        let input = PhotographicTone.decode(Double(i) / 4096)
        let output = PhotographicTone.luminance(input, parameters: p)
        #expect(output.isFinite && output >= 0 && output < 1)
        #expect(output > previous, "Tone reversal or plateau at \(i), \(p)")
        previous = output
      }
      #expect(PhotographicTone.luminance(0, parameters: p) == 0)
    }
  }

  @Test("Brightness has no gray pedestal and contrast retains the white endpoint")
  func brightnessContrastEndpoints() {
    for value in [-1.0, -0.5, 0.5, 1] {
      let brightness = PhotoAdjustmentParameters(brightness: value)
      #expect(PhotographicTone.luminance(0, parameters: brightness) == 0)
      #expect(PhotographicTone.luminance(0.002, parameters: brightness) > 0)
      let contrast = PhotoAdjustmentParameters(contrast: value)
      #expect(abs(PhotographicTone.luminance(1, parameters: contrast) - 0.99) < 1e-9)
      #expect(abs(PhotographicTone.luminance(0.18, parameters: contrast) - 0.18) < 1e-9)
    }
  }

  @Test("Positive highlights brighten and never reverse the .6/.9 regression pair")
  func highlightsDirection() {
    let positive = PhotoAdjustmentParameters(highlights: 1)
    let negative = PhotoAdjustmentParameters(highlights: -1)
    let a = PhotographicTone.luminance(0.6, parameters: positive)
    let b = PhotographicTone.luminance(0.9, parameters: positive)
    #expect(a > 0.6 && b > a)
    #expect(PhotographicTone.luminance(0.6, parameters: negative) < 0.6)
  }

  @Test("A curve after exposure retains distinct bright values")
  func highlightHeadroomThroughCurves() {
    let levels: [UInt16] = [160, 192, 224, 255].map { $0 * 257 }
    let image = UInt16Image(
      width: levels.count, height: 1, channels: 3,
      pixels: levels.flatMap { [$0, $0, $0] })
    let p = ProcessingParameters(
      filmType: .slide, curveEnabled: true,
      curveControlPoints: [.init(input: 0, output: 0), .init(input: 1, output: 0.25)],
      photoAdjustments: .init(exposureEV: 2))
    let output = FilmProcessing.correctedPreview(image: image, parameters: p)
    let values = stride(from: 1, to: output.pixels.count, by: 3).map { output.pixels[$0] }
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    #expect(values.last! < 16_384)
  }

  @Test("Endpoint controls can be compensated by a later float curve")
  func endpointControlsDeferClipping() {
    var p = ProcessingParameters(
      filmType: .slide, curveEnabled: true,
      curveControlPoints: [.init(input: 0, output: 0.2), .init(input: 1, output: 0.6)],
      photoAdjustments: .init(schemaVersion: 2, whites: 1, blacks: -1))
    let curve = PhotographicCurves(p)
    #expect(curve.value(-0.1, channel: 1) < curve.value(0, channel: 1))
    #expect(curve.value(1.1, channel: 1) > curve.value(1, channel: 1))
    p.photoAdjustments = .init(schemaVersion: 2, blacks: 1)
    #expect(PhotographicTone.luminance(0, parameters: p.photoAdjustments) > 0)
  }

  private func v4Encoded(_ x: Double, _ parameters: PhotoAdjustmentParameters) -> Double {
    PhotographicTone.encode(
      PhotographicTone.luminance(PhotographicTone.decode(x), parameters: parameters))
  }

  @Test("Version 4 basic range sliders have separate broad and tail responses")
  func distinctVersionFourRanges() {
    let neutral = PhotoAdjustmentParameters(schemaVersion: 4)
    let shadows = PhotoAdjustmentParameters(schemaVersion: 4, shadows: 0.5)
    let blacks = PhotoAdjustmentParameters(schemaVersion: 4, blacks: 0.5)
    let highlights = PhotoAdjustmentParameters(schemaVersion: 4, highlights: 0.5)
    let whites = PhotoAdjustmentParameters(schemaVersion: 4, whites: 0.5)
    func delta(_ x: Double, _ parameters: PhotoAdjustmentParameters) -> Double {
      v4Encoded(x, parameters) - v4Encoded(x, neutral)
    }
    #expect(delta(0.4, shadows) > delta(0.4, blacks) * 3)
    #expect(abs(delta(0.35, blacks)) < 1e-12)
    #expect(delta(0.05, blacks) > delta(0.05, shadows) * 1.5)
    #expect(delta(0.6, highlights) > delta(0.6, whites) * 3)
    #expect(abs(delta(0.45, whites)) < 1e-12)
    #expect(delta(0.95, whites) > delta(0.95, highlights) * 1.5)
    for p in [shadows, blacks, highlights, whites] {
      #expect(PhotographicTone.luminance(0, parameters: p) == 0)
      #expect(
        PhotographicTone.luminance(1, parameters: p)
          == PhotographicTone.luminance(1, parameters: neutral))
    }
  }

  @Test("Version 4 grading levels move distinct points of the tone scale")
  func gradingLevels() {
    let neutral = PhotoAdjustmentParameters(schemaVersion: 4)
    let floor = PhotoAdjustmentParameters(schemaVersion: 4, shadowFloor: 1)
    let center = PhotoAdjustmentParameters(schemaVersion: 4, midtoneLevel: 1)
    let ceiling = PhotoAdjustmentParameters(schemaVersion: 4, highlightCeiling: -1)
    #expect(v4Encoded(0, floor) > 0.1)
    #expect(v4Encoded(0, center) == 0)
    #expect(v4Encoded(0, ceiling) == 0)
    #expect(v4Encoded(0.5, center) - v4Encoded(0.5, neutral) > 0.14)
    #expect(v4Encoded(0.05, center) == v4Encoded(0.05, neutral))
    #expect(v4Encoded(0.95, center) == v4Encoded(0.95, neutral))
    #expect(v4Encoded(1, ceiling) < v4Encoded(1, neutral) - 0.14)
  }

  @Test("All 1,024 independent version 4 tone and grading corners remain monotone")
  func versionFourMonotonicity() {
    let keys: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.exposureEV, \.brightness, \.contrast,
      \.highlights, \.shadows, \.whites, \.blacks,
      \.shadowFloor, \.midtoneLevel, \.highlightCeiling,
    ]
    for corner in 0..<(1 << keys.count) {
      var p = PhotoAdjustmentParameters(schemaVersion: 4)
      for (index, key) in keys.enumerated() {
        let limit = key == \.exposureEV ? 4.0 : 1.0
        p[keyPath: key] = corner & (1 << index) == 0 ? -limit : limit
      }
      var previous = -Double.infinity
      for sample in 0...1024 {
        let x = Double(sample) / 1024
        let y = PhotographicTone.luminance(PhotographicTone.decode(x), parameters: p)
        guard y.isFinite && y > previous else {
          Issue.record(
            "Tone reversal at corner \(corner), sample \(sample): \(previous) → \(y), \(p)")
          break
        }
        previous = y
      }
    }
  }

  @Test("Version 4 point fields do not alter older rendering contracts")
  func oldVersionsIgnoreNewLevels() {
    for version in 1...3 {
      var old = PhotoAdjustmentParameters(
        schemaVersion: version, highlights: 0.4, shadows: -0.35,
        whites: 0.2, blacks: -0.15)
      var withLevels = old
      withLevels.shadowFloor = 1
      withLevels.midtoneLevel = -1
      withLevels.highlightCeiling = 1
      for sample in 0...256 {
        let input = PhotographicTone.decode(Double(sample) / 256)
        #expect(
          PhotographicTone.luminance(input, parameters: old)
            == PhotographicTone.luminance(input, parameters: withLevels))
      }
      old.schemaVersion = 4
      #expect(PhotographicTone.luminance(0, parameters: old) == 0)
    }
  }

  @Test("Neutral version 4 tone matches version 2 exactly")
  func neutralVersionFourMatchesVersionTwo() {
    let old = PhotoAdjustmentParameters(
      schemaVersion: 2, exposureEV: 0.5, brightness: -0.2, contrast: 0.3)
    var current = old
    current.schemaVersion = 4
    for sample in 0...1024 {
      let input = PhotographicTone.decode(Double(sample) / 1024)
      #expect(
        PhotographicTone.luminance(input, parameters: current)
          == PhotographicTone.luminance(input, parameters: old))
    }
  }

  @Test("Saved version 1 edits decode unchanged; new controls round trip")
  func versionCompatibility() throws {
    let old = try JSONDecoder().decode(
      PhotoAdjustmentParameters.self,
      from: Data(#"{"schemaVersion":1,"brightness":-0.5,"highlights":0.4}"#.utf8))
    #expect(old.schemaVersion == 1 && old.brightness == -0.5 && old.highlights == 0.4)
    #expect(old.whites == 0 && old.blacks == 0)
    let missing = try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: Data("{}".utf8))
    #expect(missing.schemaVersion == 1)
    let modern = ProcessingParameters(
      photoAdjustments: .init(exposureEV: 1, whites: 0.2, blacks: -0.3))
    #expect(
      try JSONDecoder().decode(
        ProcessingParameters.self,
        from: JSONEncoder().encode(modern)) == modern)
  }

  @Test("Density crop uses the same analysis as the full sensor frame")
  func densityCropAnalysis() throws {
    let samples: [UInt16] = (0..<9216).map { index in UInt16(2048 + (index * 97) % 60000) }
    let image = UInt16Image(width: 64, height: 48, channels: 3, pixels: samples)
    var p = LookRecipe.cleanInvert.applying(to: FilmBase.colorC41.applyingInvert(to: .init()))
    let whole = FilmProcessing.correctedPreview(image: image, parameters: p)
    p.manualCrop = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let cropped = FilmProcessing.correctedPreview(image: image, parameters: p)
    var geometry = ProcessingParameters(filmType: .cropOnly)
    geometry.manualCrop = p.manualCrop
    #expect(cropped == FilmProcessing.prepareGeometry(image: whole, parameters: geometry))
    #expect(StillPreviewRenderer.supports(parameters: p, showOriginal: false))
    p.photoAdjustments.schemaVersion = 1
    #expect(!StillPreviewRenderer.supports(parameters: p, showOriginal: false))
  }

  @Test("Frozen paper response survives legacy decoding but does not affect modern tone")
  func legacyPaperCompatibility() throws {
    var p = try JSONDecoder().decode(
      ProcessingParameters.self,
      from: Data(
        #"{"photoAdjustments":{"schemaVersion":1},"filmNegativeParams":{"rendering":"densityPrint","densityPaperID":"fuji_crystal"}}"#
          .utf8))
    #expect(
      DensityPrintProcessing.resolvedPaper(for: p) == DensityPaperProfileCatalog.fujiCrystalArchive)
    let saved = try JSONDecoder().decode(ProcessingParameters.self, from: JSONEncoder().encode(p))
    #expect(saved.filmNegativeParams.legacyDensityPaperID == "fuji_crystal")
    p.photoAdjustments.schemaVersion = 2
    #expect(DensityPrintProcessing.resolvedPaper(for: p) == DensityPaperProfileCatalog.neutral)
  }

  @Test("Calibrated inversion no longer flattens its plateau or over-range input")
  func calibratedDetail() {
    let p = FilmNegativeParams.blackAndWhite
    let values = [0.71, 0.75, 0.79, 1.01, 1.1, 1.2].map {
      FilmNegativeProcessing.photographicCalibratedValue($0, channel: 1, params: p)
    }
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 > $1 })
  }
}
