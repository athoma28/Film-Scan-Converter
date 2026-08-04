import CryptoKit
import Foundation
import Testing

@testable import FilmScanEngine

private struct CorrectionScenarioReference: Decodable {
  struct ScenarioDigest: Decodable {
    let scenario: String
    let correctedImageSHA256: String
  }

  let schemaVersion: Int
  let generator: String
  let recorded: String
  let profile: String
  let fullResolution: Bool
  let notes: String
  let file: String
  let imageShape: [Int]
  let scenarios: [ScenarioDigest]
}

private let expectedCorrectionFile = "fuji400-fresh/DSCF2833.RAF"

private func loadCorrectionScenarioReference() throws -> CorrectionScenarioReference {
  let data = try Data(
    contentsOf: FixtureLoader.fixtureURL("", file: "correction_scenario_reference.json")
  )
  return try JSONDecoder().decode(CorrectionScenarioReference.self, from: data)
}

private var correctionRawAvailable: Bool {
  SampleRawCorpus.uniqueURL(named: expectedCorrectionFile) != nil
}

private func expectCorrectionDigest(
  _ digest: String,
  _ scenario: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(digest.count == 64, "\(scenario) digest length", sourceLocation: sourceLocation)
  #expect(
    digest.allSatisfy { $0.isHexDigit && !$0.isUppercase },
    "\(scenario) digest must be lowercase hex", sourceLocation: sourceLocation)
}

@Suite("Full-resolution correction scenario reference")
struct CorrectionScenarioReferenceTests {
  @Test("Committed correction reference fixture has a valid, complete schema")
  func referenceFixtureSchema() throws {
    let reference = try loadCorrectionScenarioReference()
    #expect(reference.schemaVersion == 1)
    #expect(reference.generator.contains("FilmScanExportBenchmark --corrections"))
    #expect(!reference.recorded.isEmpty)
    #expect(reference.profile == "rawTherapeeCameraScan")
    #expect(reference.fullResolution)
    #expect(!reference.notes.isEmpty)
    #expect(reference.file == expectedCorrectionFile)
    #expect(reference.imageShape.count == 3)
    #expect(reference.imageShape.allSatisfy { $0 > 0 })
    #expect(reference.imageShape.last == 3)

    #expect(
      reference.scenarios.map(\.scenario) == CorrectionScenario.allCases.map(\.rawValue),
      "Fixture must pin exactly the five documented scenarios in order")
    for digest in reference.scenarios {
      expectCorrectionDigest(digest.correctedImageSHA256, digest.scenario)
    }
  }

  @Test(
    "Full-resolution corrected images reproduce recorded scenario digests",
    .enabled(
      if: correctionRawAvailable,
      "referenced sample-raw corpus unavailable; byte-identity test skipped")
  )
  func fullResolutionCorrectionScenarioByteIdentity() throws {
    let reference = try loadCorrectionScenarioReference()
    #expect(reference.profile == "rawTherapeeCameraScan")
    #expect(reference.fullResolution)
    try #require(reference.imageShape.count == 3)

    let rawURL = try #require(SampleRawCorpus.uniqueURL(named: reference.file))

    // Reproduce the benchmark's base parameters exactly: medians measured from
    // the same 640px embedded preview, then the scenario deltas on top.
    let preview = try RawImageDecoder.extractThumbnail(rawURL, maxDimension: 640).image
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: preview)
    let base = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative
    )

    let decoded = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan
    ).image
    #expect(
      [decoded.height, decoded.width, decoded.channels] == reference.imageShape,
      "\(reference.file) decoded shape \(decoded.height)x\(decoded.width)x\(decoded.channels)"
    )

    for scenarioDigest in reference.scenarios {
      let scenario = try #require(
        CorrectionScenario(rawValue: scenarioDigest.scenario),
        "Unknown scenario \(scenarioDigest.scenario)")
      let parameters = scenario.processingParameters(base: base)
      let corrected = FilmProcessing.correctedPreview(image: decoded, parameters: parameters)
      let digest = corrected.pixels.withUnsafeBytes {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
      }
      #expect(
        digest == scenarioDigest.correctedImageSHA256,
        "\(reference.file) \(scenario.rawValue) corrected digest \(digest) != \(scenarioDigest.correctedImageSHA256)"
      )
    }
  }
}
