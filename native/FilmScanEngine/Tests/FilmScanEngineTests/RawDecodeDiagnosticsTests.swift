import Foundation
import Testing

@testable import FilmScanEngine

private var representativeRawURL: URL? {
  SampleRawCorpus.triplets().first(where: { !$0.isMonochrome })?.rawURL
    ?? SampleRawCorpus.rawURLs().first
}

private var representativeRawAvailable: Bool {
  representativeRawURL != nil
}

private func expectHexDigest(
  _ digest: String,
  _ boundary: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    digest.count == 64, "\(boundary) digest length: \(digest.count)", sourceLocation: sourceLocation
  )
  #expect(
    digest.allSatisfy { $0.isHexDigit && !$0.isUppercase },
    "\(boundary) digest must be lowercase hex: \(digest)", sourceLocation: sourceLocation)
}

private func repeatedDigest(_ character: Character) -> String {
  String(repeating: String(character), count: 64)
}

@Suite("RAW decode stage-boundary diagnostics")
struct RawDecodeDiagnosticsTests {
  @Test(
    "Full-resolution camera-scan stage digests are complete and repeatable",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; stage-digest test skipped")
  )
  func fullResolutionCameraScanDigests() throws {
    let rawURL = try #require(representativeRawURL)

    let first = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )
    let second = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )

    let firstDiagnostics = try #require(first.diagnostics)
    let secondDiagnostics = try #require(second.diagnostics)

    #expect(firstDiagnostics.hasCompleteStageDigests)
    #expect(firstDiagnostics.mosaicRawWidth > 0)
    #expect(firstDiagnostics.mosaicRawHeight > 0)
    #expect(firstDiagnostics.mosaicCFABytes == (firstDiagnostics.mosaicFilters == 9 ? 36 : 0))

    for digest in RawDecodeDeterminism.boundaryDigests(of: firstDiagnostics) {
      expectHexDigest(digest.sha256, digest.boundary)
    }

    // The current serial build must be deterministic across repeated decodes.
    #expect(firstDiagnostics == secondDiagnostics)
    let allBoundariesAgree =
      RawDecodeDeterminism
      .agreement([firstDiagnostics, secondDiagnostics])
      .allSatisfy(\.allAgree)
    #expect(allBoundariesAgree)
    #expect(first.image.pixels == second.image.pixels)
  }

  @Test(
    "Preview camera-scan decode collects stage digests",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; preview stage-digest test skipped")
  )
  func previewCameraScanDigests() throws {
    let rawURL = try #require(representativeRawURL)

    let result = try RawImageDecoder.decode(
      rawURL,
      fullResolution: false,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )

    let diagnostics = try #require(result.diagnostics)
    for digest in RawDecodeDeterminism.boundaryDigests(of: diagnostics) {
      expectHexDigest(digest.sha256, digest.boundary)
    }
  }

  @Test(
    "Diagnostics are opt-in and camera-scan only",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; diagnostics opt-in test skipped")
  )
  func diagnosticsAreOptIn() throws {
    let rawURL = try #require(representativeRawURL)

    let defaultDecode = try RawImageDecoder.decode(
      rawURL,
      fullResolution: false,
      profile: .rawTherapeeCameraScan
    )
    #expect(defaultDecode.diagnostics == nil)

    // Other profiles decode normally but do not collect stage digests.
    let compatibilityDecode = try RawImageDecoder.decode(
      rawURL,
      fullResolution: false,
      profile: .rawPyCompatibility,
      collectDiagnostics: true
    )
    #expect(compatibilityDecode.diagnostics == nil)
  }

  @Test("Boundary digests are listed in pipeline order")
  func boundaryDigestOrder() {
    let diagnostics = RawDecodeDiagnostics(
      mosaicRawWidth: 1,
      mosaicRawHeight: 2,
      mosaicFilters: 9,
      mosaicCFABytes: 36,
      unpackedMosaicSHA256: "a",
      demosaicedSHA256: "b",
      processedImageSHA256: "c",
      postISOImageSHA256: "d",
      swiftImageSHA256: "e"
    )

    #expect(
      RawDecodeDeterminism.boundaryDigests(of: diagnostics) == [
        StageBoundaryDigest(boundary: "unpackedMosaic", sha256: "a"),
        StageBoundaryDigest(boundary: "demosaicedImage", sha256: "b"),
        StageBoundaryDigest(boundary: "processedImage", sha256: "c"),
        StageBoundaryDigest(boundary: "postISOImage", sha256: "d"),
        StageBoundaryDigest(boundary: "swiftImage", sha256: "e"),
      ]
    )
  }

  @Test("Agreement reports all-agree for identical samples")
  func agreementForIdenticalSamples() {
    let diagnostics = RawDecodeDiagnostics(
      mosaicRawWidth: 1,
      mosaicRawHeight: 2,
      mosaicFilters: 9,
      mosaicCFABytes: 36,
      unpackedMosaicSHA256: repeatedDigest("a"),
      demosaicedSHA256: repeatedDigest("b"),
      processedImageSHA256: repeatedDigest("c"),
      postISOImageSHA256: repeatedDigest("d"),
      swiftImageSHA256: repeatedDigest("e")
    )

    let agreement = RawDecodeDeterminism.agreement([diagnostics, diagnostics, diagnostics])

    #expect(diagnostics.hasCompleteStageDigests)
    #expect(agreement.count == 5)
    let allAgree = agreement.allSatisfy { $0.allAgree && $0.distinctDigests == 1 }
    #expect(allAgree)
  }

  @Test("Agreement rejects missing or malformed digests")
  func agreementRejectsInvalidDigests() {
    let incomplete = RawDecodeDiagnostics(
      mosaicRawWidth: 1,
      mosaicRawHeight: 2,
      mosaicFilters: 9,
      mosaicCFABytes: 36,
      unpackedMosaicSHA256: "",
      demosaicedSHA256: repeatedDigest("b"),
      processedImageSHA256: repeatedDigest("c"),
      postISOImageSHA256: repeatedDigest("d"),
      swiftImageSHA256: repeatedDigest("e")
    )

    #expect(!incomplete.hasCompleteStageDigests)
    let agreement = RawDecodeDeterminism.agreement([incomplete, incomplete])
    #expect(agreement.first?.boundary == "unpackedMosaic")
    #expect(agreement.first?.distinctDigests == 1)
    #expect(agreement.first?.allAgree == false)
  }

  @Test("Agreement isolates the first divergent boundary")
  func agreementIsolatesDivergentBoundary() {
    let baseline = RawDecodeDiagnostics(
      mosaicRawWidth: 1,
      mosaicRawHeight: 2,
      mosaicFilters: 9,
      mosaicCFABytes: 36,
      unpackedMosaicSHA256: repeatedDigest("a"),
      demosaicedSHA256: repeatedDigest("b"),
      processedImageSHA256: repeatedDigest("c"),
      postISOImageSHA256: repeatedDigest("d"),
      swiftImageSHA256: repeatedDigest("e")
    )
    let diverged = RawDecodeDiagnostics(
      mosaicRawWidth: 1,
      mosaicRawHeight: 2,
      mosaicFilters: 9,
      mosaicCFABytes: 36,
      unpackedMosaicSHA256: repeatedDigest("a"),
      demosaicedSHA256: repeatedDigest("f"),
      processedImageSHA256: repeatedDigest("c"),
      postISOImageSHA256: repeatedDigest("d"),
      swiftImageSHA256: repeatedDigest("e")
    )

    let agreement = RawDecodeDeterminism.agreement([baseline, diverged])

    #expect(
      agreement == [
        StageBoundaryAgreement(boundary: "unpackedMosaic", distinctDigests: 1, allAgree: true),
        StageBoundaryAgreement(boundary: "demosaicedImage", distinctDigests: 2, allAgree: false),
        StageBoundaryAgreement(boundary: "processedImage", distinctDigests: 1, allAgree: true),
        StageBoundaryAgreement(boundary: "postISOImage", distinctDigests: 1, allAgree: true),
        StageBoundaryAgreement(boundary: "swiftImage", distinctDigests: 1, allAgree: true),
      ]
    )
  }

  @Test("Agreement over no samples is empty")
  func agreementOverNoSamples() {
    #expect(RawDecodeDeterminism.agreement([]) == [])
  }

  @Test("Diagnostics round-trip through Codable")
  func codableRoundTrip() throws {
    let diagnostics = RawDecodeDiagnostics(
      mosaicRawWidth: 7752,
      mosaicRawHeight: 5184,
      mosaicFilters: 9,
      mosaicCFABytes: 36,
      unpackedMosaicSHA256: String(repeating: "a", count: 64),
      demosaicedSHA256: String(repeating: "b", count: 64),
      processedImageSHA256: String(repeating: "c", count: 64),
      postISOImageSHA256: String(repeating: "d", count: 64),
      swiftImageSHA256: String(repeating: "e", count: 64)
    )

    let data = try JSONEncoder().encode(diagnostics)
    #expect(try JSONDecoder().decode(RawDecodeDiagnostics.self, from: data) == diagnostics)
  }
}
