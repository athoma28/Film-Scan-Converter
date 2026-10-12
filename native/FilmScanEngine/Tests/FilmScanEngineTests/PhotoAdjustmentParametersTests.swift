import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Modern photo adjustment parameters")
struct PhotoAdjustmentParametersTests {
  @Test("Neutral parameters are exact identity values")
  func neutralIdentity() {
    let parameters = PhotoAdjustmentParameters()

    #expect(parameters.schemaVersion == PhotoAdjustmentParameters.currentSchemaVersion)
    #expect(parameters.exposureEV == 0)
    #expect(parameters.brightness == 0)
    #expect(parameters.contrast == 0)
    #expect(parameters.highlights == 0)
    #expect(parameters.shadows == 0)
    #expect(parameters.temperatureShiftMired == 0)
    #expect(parameters.tint == 0)
    #expect(parameters.saturation == 0)
    #expect(parameters.vibrance == 0)
    #expect(parameters.isNeutral)
  }

  @Test("Center-weighted UI mapping is bounded, symmetric, and monotonic")
  func centerWeightedMapping() {
    let positions = stride(from: -1.0, through: 1.0, by: 0.1)
    let values = positions.map {
      PhotoAdjustmentParameters.centerWeightedAmount(
        normalizedPosition: $0,
        negativeLimit: 2,
        positiveLimit: 4
      )
    }

    #expect(values == values.sorted())
    #expect(values.first == -2)
    #expect(values.last == 4)
    #expect(values[10] == 0)

    let negative = PhotoAdjustmentParameters.centerWeightedAmount(
      normalizedPosition: -0.5, negativeLimit: 3, positiveLimit: 3)
    let positive = PhotoAdjustmentParameters.centerWeightedAmount(
      normalizedPosition: 0.5, negativeLimit: 3, positiveLimit: 3)
    #expect(abs(negative + positive) < 1e-12)
    #expect(abs(positive) < 1.5)
  }

  @Test("UI mapping clamps out-of-range positions")
  func centerWeightedMappingClamps() {
    #expect(
      PhotoAdjustmentParameters.centerWeightedAmount(
        normalizedPosition: -5, negativeLimit: 2, positiveLimit: 4) == -2)
    #expect(
      PhotoAdjustmentParameters.centerWeightedAmount(
        normalizedPosition: 5, negativeLimit: 2, positiveLimit: 4) == 4)
  }

  @Test("Legacy integer controls migrate deterministically without replacing them")
  func legacyMigration() {
    let migrated = PhotoAdjustmentParameters.migratingLegacy(
      gamma: 50,
      shadows: -25,
      highlights: 80,
      temperature: 40,
      tint: -20,
      saturation: 125
    )

    #expect(migrated.brightness > 0)
    #expect(migrated.shadows < 0)
    #expect(migrated.highlights > 0)
    #expect(migrated.temperatureShiftMired > 0)
    #expect(migrated.tint < 0)
    #expect(migrated.saturation > 0)
    #expect(migrated.exposureEV == 0)
    #expect(migrated.contrast == 0)
    #expect(migrated.vibrance == 0)
  }

  @Test("Processing settings migrate useful legacy controls and ignore removed no-op fields")
  func processingParametersMigratesOldJSON() throws {
    let json = Data(
      #"{"filmType":1,"whitePoint":30,"blackPoint":-20,"removeDust":true,"gamma":50,"shadows":-25,"highlights":80,"temperature":40,"tint":-20,"saturation":125}"#
        .utf8
    )

    let decoded = try JSONDecoder().decode(ProcessingParameters.self, from: json)

    #expect(decoded.gamma == 50)
    #expect(decoded.saturation == 125)
    #expect(
      decoded.photoAdjustments
        == .migratingLegacy(
          gamma: 50,
          shadows: -25,
          highlights: 80,
          temperature: 40,
          tint: -20,
          saturation: 125
        ))
    let migratedJSON = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
    #expect(!migratedJSON.contains("whitePoint"))
    #expect(!migratedJSON.contains("blackPoint"))
    #expect(!migratedJSON.contains("removeDust"))
  }

  @Test("All supported saved versions preserve every adjustment", arguments: 1...4)
  func codableRoundTrip(version: Int) throws {
    let parameters = PhotoAdjustmentParameters(
      schemaVersion: version,
      exposureEV: 1.25,
      brightness: -0.2,
      contrast: 0.35,
      highlights: -0.4,
      shadows: 0.3,
      temperatureShiftMired: 18,
      tint: -0.1,
      saturation: 0.2,
      vibrance: 0.45, warmHueRecovery: 0.25, whites: 0.2, blacks: -0.3,
      shadowFloor: 0.3, midtoneLevel: -0.2, highlightCeiling: -0.4
    )

    let encoded = try JSONEncoder().encode(parameters)
    let decoded = try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: encoded)

    #expect(decoded == parameters)
  }

  @Test(
    "Saved versions retain present values and neutral defaults for omitted controls",
    arguments: 1...4)
  func omittedControlsDefaultToNeutral(version: Int) throws {
    let saved = Data("{\"schemaVersion\":\(version),\"brightness\":-0.5,\"highlights\":0.4}".utf8)
    let decoded = try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: saved)
    #expect(
      decoded
        == PhotoAdjustmentParameters(schemaVersion: version, brightness: -0.5, highlights: 0.4))
    // Historical defaults must stay neutral even if new-edit initialization changes.
    #expect(decoded.whites == 0)
    #expect(decoded.blacks == 0)
    #expect(decoded.shadowFloor == 0)
    #expect(decoded.midtoneLevel == 0)
    #expect(decoded.highlightCeiling == 0)
  }

  @Test("Documents without a tone version retain the version 1 defaults")
  func missingVersionDefaultsToLegacy() throws {
    let decoded = try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: Data("{}".utf8))
    #expect(decoded == PhotoAdjustmentParameters(schemaVersion: 1))
  }

  @Test("Unknown saved tone versions are rejected", arguments: [0, 5])
  func unsupportedVersionIsRejected(version: Int) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        PhotoAdjustmentParameters.self, from: Data("{\"schemaVersion\":\(version)}".utf8))
    }
  }

  @Test("New edits use version 4 while supporting saved versions 1 through 4")
  func currentVersionContract() {
    #expect(PhotoAdjustmentParameters.currentSchemaVersion == 4)
    #expect(PhotoAdjustmentParameters.maximumSupportedSchemaVersion == 4)
    #expect(PhotoAdjustmentParameters().schemaVersion == 4)
  }

  @Test("Processing settings retain current photographic controls through serialization")
  func processingSettingsRoundTrip() throws {
    let original = ProcessingParameters(
      photoAdjustments: .init(exposureEV: 1, whites: 0.2, blacks: -0.3))
    #expect(
      try JSONDecoder().decode(
        ProcessingParameters.self, from: JSONEncoder().encode(original)) == original)
  }

  @Test(
    "Every numeric adjustment rejects nonfinite saved values",
    arguments: [
      "exposureEV", "brightness", "contrast", "highlights", "shadows", "whites", "blacks",
      "shadowFloor", "midtoneLevel", "highlightCeiling", "temperatureShiftMired",
      "tint", "saturation", "vibrance", "warmHueRecovery",
    ], ["NaN", "Inf", "-Inf"])
  func rejectsNonfiniteAdjustment(field: String, value: String) {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
    #expect(throws: DecodingError.self) {
      try decoder.decode(
        PhotoAdjustmentParameters.self,
        from: Data("{\"schemaVersion\":4,\"\(field)\":\"\(value)\"}".utf8))
    }
  }

}
