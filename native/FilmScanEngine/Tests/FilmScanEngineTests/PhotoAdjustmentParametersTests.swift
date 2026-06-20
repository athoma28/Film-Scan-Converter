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

  @Test("Processing settings decode old JSON into the versioned adjustment contract")
  func processingParametersMigratesOldJSON() throws {
    let json = Data(
      #"{"filmType":1,"gamma":50,"shadows":-25,"highlights":80,"temperature":40,"tint":-20,"saturation":125}"#.utf8
    )

    let decoded = try JSONDecoder().decode(ProcessingParameters.self, from: json)

    #expect(decoded.gamma == 50)
    #expect(decoded.saturation == 125)
    #expect(decoded.photoAdjustments == .migratingLegacy(
      gamma: 50,
      shadows: -25,
      highlights: 80,
      temperature: 40,
      tint: -20,
      saturation: 125
    ))
  }

  @Test("Versioned adjustment parameters round trip through JSON")
  func codableRoundTrip() throws {
    let parameters = PhotoAdjustmentParameters(
      exposureEV: 1.25,
      brightness: -0.2,
      contrast: 0.35,
      highlights: -0.4,
      shadows: 0.3,
      temperatureShiftMired: 18,
      tint: -0.1,
      saturation: 0.2,
      vibrance: 0.45
    )

    let encoded = try JSONEncoder().encode(parameters)
    let decoded = try JSONDecoder().decode(PhotoAdjustmentParameters.self, from: encoded)

    #expect(decoded == parameters)
  }
}
