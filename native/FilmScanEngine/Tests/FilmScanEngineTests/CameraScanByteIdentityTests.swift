import CryptoKit
import Darwin
import Foundation
import Testing

@testable import FilmScanEngine

private struct CameraScanDecodeReference: Decodable {
  struct Mosaic: Decodable {
    let rawWidth: Int
    let rawHeight: Int
    let filters: UInt32
    let cfaBytes: Int
  }

  struct StageSHA256: Decodable {
    let unpackedMosaic: String
    let demosaicedImage: String
    let processedImage: String
    let postISOImage: String
    let swiftImage: String
  }

  let schemaVersion: Int
  let generator: String
  let recorded: String
  let profile: String
  let fullResolution: Bool
  let notes: String
  let file: String
  let imageShape: [Int]
  let colorDescription: String
  let mosaic: Mosaic
  let stageSHA256: StageSHA256
}

private let expectedCameraScanFile = "fuji400-fresh/DSCF2833.RAF"

private func loadCameraScanReference() throws -> CameraScanDecodeReference {
  let data = try Data(
    contentsOf: FixtureLoader.fixtureURL("", file: "camera_scan_decode_reference.json")
  )
  return try JSONDecoder().decode(CameraScanDecodeReference.self, from: data)
}

private var cameraScanRawAvailable: Bool {
  SampleRawCorpus.uniqueURL(named: expectedCameraScanFile) != nil
}

private func expectReferenceDigest(
  _ digest: String,
  _ boundary: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(digest.count == 64, "\(boundary) digest length", sourceLocation: sourceLocation)
  #expect(
    digest.allSatisfy { $0.isHexDigit && !$0.isUppercase },
    "\(boundary) digest must be lowercase hex", sourceLocation: sourceLocation)
}

@Suite("Camera-scan full-resolution byte identity")
struct CameraScanByteIdentityTests {
  @Test("Committed reference fixture has a valid, complete schema")
  func referenceFixtureSchema() throws {
    let reference = try loadCameraScanReference()
    #expect(reference.schemaVersion == 1)
    #expect(reference.generator.contains("FilmScanExportBenchmark --determinism"))
    #expect(!reference.recorded.isEmpty)
    #expect(reference.profile == "rawTherapeeCameraScan")
    #expect(reference.fullResolution)
    #expect(!reference.notes.isEmpty)
    #expect(reference.file == expectedCameraScanFile)
    #expect(reference.imageShape.count == 3)
    #expect(reference.imageShape.allSatisfy { $0 > 0 })
    #expect(reference.imageShape.last == 3)
    #expect(!reference.colorDescription.isEmpty)
    #expect(reference.mosaic.rawWidth > 0)
    #expect(reference.mosaic.rawHeight > 0)
    #expect(reference.mosaic.filters == 9)
    #expect(reference.mosaic.cfaBytes == 36)

    let digests = [
      ("unpackedMosaic", reference.stageSHA256.unpackedMosaic),
      ("demosaicedImage", reference.stageSHA256.demosaicedImage),
      ("processedImage", reference.stageSHA256.processedImage),
      ("postISOImage", reference.stageSHA256.postISOImage),
      ("swiftImage", reference.stageSHA256.swiftImage),
    ]
    for (boundary, digest) in digests {
      expectReferenceDigest(digest, boundary)
    }
  }

  @Test(
    "Full-resolution X-Trans camera-scan decode matches recorded stage digests",
    .enabled(
      if: cameraScanRawAvailable,
      "referenced sample-raw corpus unavailable; byte-identity test skipped")
  )
  func fullResolutionCameraScanByteIdentity() throws {
    let reference = try loadCameraScanReference()
    #expect(reference.profile == "rawTherapeeCameraScan")
    #expect(reference.fullResolution)
    try #require(reference.imageShape.count == 3)

    let rawURL = try #require(SampleRawCorpus.uniqueURL(named: reference.file))
    let dimensions = try RawImageDecoder.fullResolutionDimensions(rawURL)
    xtransWorkerOverrideLock.lock()
    defer { xtransWorkerOverrideLock.unlock() }
    let result = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )
    let diagnostics = try #require(result.diagnostics)

    // The exact-output contract applies to the final-quality three-pass
    // camera-scan path; a one-pass fallback must fail this fixture loudly.
    #expect(result.processing.contains(.xTransThreePass))
    #expect(result.demosaicWorkerCount >= 1)
    #expect(
      result.processing.contains(.deterministicParallelXTrans)
        == (result.demosaicWorkerCount > 1))
    #expect(result.unpackWorkerCount >= 1)
    #expect(
      result.processing.contains(.parallelFujiUnpack) == (result.unpackWorkerCount > 1))
    #expect(dimensions.width == reference.imageShape[1], "\(reference.file) full-resolution width")
    #expect(
      dimensions.height == reference.imageShape[0], "\(reference.file) full-resolution height")
    #expect(
      [result.image.height, result.image.width, result.image.channels] == reference.imageShape,
      "\(reference.file) decoded shape \(result.image.height)x\(result.image.width)x\(result.image.channels)"
    )
    #expect(
      result.colorDescription == reference.colorDescription,
      "\(reference.file) color description \(result.colorDescription)")

    #expect(
      diagnostics.mosaicRawWidth == reference.mosaic.rawWidth, "\(reference.file) mosaic width")
    #expect(
      diagnostics.mosaicRawHeight == reference.mosaic.rawHeight, "\(reference.file) mosaic height")
    #expect(diagnostics.mosaicFilters == reference.mosaic.filters, "\(reference.file) CFA filters")
    #expect(diagnostics.mosaicCFABytes == reference.mosaic.cfaBytes, "\(reference.file) CFA bytes")

    let expectedDigests = [
      StageBoundaryDigest(boundary: "unpackedMosaic", sha256: reference.stageSHA256.unpackedMosaic),
      StageBoundaryDigest(
        boundary: "demosaicedImage", sha256: reference.stageSHA256.demosaicedImage),
      StageBoundaryDigest(boundary: "processedImage", sha256: reference.stageSHA256.processedImage),
      StageBoundaryDigest(boundary: "postISOImage", sha256: reference.stageSHA256.postISOImage),
      StageBoundaryDigest(boundary: "swiftImage", sha256: reference.stageSHA256.swiftImage),
    ]
    let actualDigests = RawDecodeDeterminism.boundaryDigests(of: diagnostics)
    #expect(actualDigests.count == expectedDigests.count)
    for (actual, expected) in zip(actualDigests, expectedDigests) {
      #expect(actual.boundary == expected.boundary)
      #expect(
        actual.sha256 == expected.sha256,
        "\(reference.file) \(expected.boundary) digest \(actual.sha256) != \(expected.sha256)")
    }

    // Byte identity of the delivered image itself, independent of the
    // diagnostics plumbing: the Swift-owned pixels must hash to the recorded
    // swiftImage boundary.
    let imageSHA256 = result.image.pixels.withUnsafeBytes {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
    #expect(
      imageSHA256 == reference.stageSHA256.swiftImage,
      "\(reference.file) pixel byte identity \(imageSHA256)")
  }

  @Test(
    "Wavefront X-Trans matches the serial one-worker oracle",
    .enabled(
      if: cameraScanRawAvailable,
      "referenced sample-raw corpus unavailable; wavefront identity test skipped")
  )
  func wavefrontMatchesSerialOracle() throws {
    let rawURL = try #require(SampleRawCorpus.uniqueURL(named: expectedCameraScanFile))

    xtransWorkerOverrideLock.lock()
    defer {
      unsetenv("FSC_XTRANS_WORKERS")
      xtransWorkerOverrideLock.unlock()
    }

    setenv("FSC_XTRANS_WORKERS", "1", 1)
    let serial = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )
    unsetenv("FSC_XTRANS_WORKERS")
    let wavefront = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )

    let serialDiagnostics = try #require(serial.diagnostics)
    let wavefrontDiagnostics = try #require(wavefront.diagnostics)
    #expect(serial.demosaicWorkerCount == 1)
    #expect(wavefront.demosaicWorkerCount > 1)
    #expect(serial.processing.contains(.xTransThreePass))
    #expect(wavefront.processing.contains(.xTransThreePass))
    #expect(wavefront.processing.contains(.deterministicParallelXTrans))
    #expect(!serial.processing.contains(.deterministicParallelXTrans))
    #expect(serialDiagnostics.demosaicedSHA256 == wavefrontDiagnostics.demosaicedSHA256)
    #expect(serialDiagnostics.swiftImageSHA256 == wavefrontDiagnostics.swiftImageSHA256)
  }

  @Test(
    "Parallel Fuji unpack matches the serial one-worker mosaic",
    .enabled(
      if: cameraScanRawAvailable,
      "referenced sample-raw corpus unavailable; unpack identity test skipped")
  )
  func parallelFujiUnpackMatchesSerialOracle() throws {
    let rawURL = try #require(SampleRawCorpus.uniqueURL(named: expectedCameraScanFile))

    xtransWorkerOverrideLock.lock()
    defer {
      unsetenv("FSC_UNPACK_WORKERS")
      xtransWorkerOverrideLock.unlock()
    }

    setenv("FSC_UNPACK_WORKERS", "1", 1)
    let serial = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )
    unsetenv("FSC_UNPACK_WORKERS")
    let parallel = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan,
      collectDiagnostics: true
    )

    let serialDiagnostics = try #require(serial.diagnostics)
    let parallelDiagnostics = try #require(parallel.diagnostics)
    #expect(serial.unpackWorkerCount == 1)
    #expect(parallel.unpackWorkerCount > 1)
    #expect(!serial.processing.contains(.parallelFujiUnpack))
    #expect(parallel.processing.contains(.parallelFujiUnpack))
    #expect(serialDiagnostics.unpackedMosaicSHA256 == parallelDiagnostics.unpackedMosaicSHA256)
    #expect(serialDiagnostics.demosaicedSHA256 == parallelDiagnostics.demosaicedSHA256)
    #expect(serialDiagnostics.swiftImageSHA256 == parallelDiagnostics.swiftImageSHA256)
  }
}

/// Serializes `FSC_XTRANS_WORKERS` and `FSC_UNPACK_WORKERS` so diagnostic
/// serial-oracle comparisons cannot interleave with another camera-scan decode
/// in the same process.
private let xtransWorkerOverrideLock = NSLock()
