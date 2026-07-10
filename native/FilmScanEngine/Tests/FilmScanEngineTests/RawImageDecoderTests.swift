import CryptoKit
import Foundation
import Testing

@testable import FilmScanEngine

private let rawDecoderRepositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private var rawCorpusAvailable: Bool {
  FileManager.default.fileExists(
    atPath: rawDecoderRepositoryRoot.appending(path: "sample-raw").path
  )
}

private struct RawDecodeReference: Decodable {
  struct Entry: Decodable {
    let file: String
    let shape: [Int]
    let sha256: String
    let colorDescription: String
  }

  let entries: [Entry]
  let fullResolution: Entry
}

@Suite("LibRaw decoding")
struct RawImageDecoderTests {
  @Test("Default heap statistics distinguish live from reserved memory")
  func defaultHeapStatisticsAreAvailable() throws {
    let statistics = try #require(RawImageDecoder.defaultHeapStatistics())
    #expect(statistics.blocksInUse > 0)
    #expect(statistics.sizeAllocated >= statistics.sizeInUse)
    #expect(statistics.maxSizeInUse >= statistics.sizeInUse)
  }

  @Test("RAW decode profiles expose stable C bridge values")
  func rawDecodeProfileBridgeValues() {
    #expect(RawDecodeProfile.rawPyCompatibility.rawValue == 0)
    #expect(RawDecodeProfile.rawTherapeeCameraScan.rawValue == 1)
  }

  @Test("RAW decode timing totals preserve their measured components")
  func rawDecodeTimingTotals() {
    let timings = RawDecodeTimings(
      openSeconds: 1,
      unpackSeconds: 2,
      demosaicSeconds: 3,
      libRawPostprocessSeconds: 4,
      processedImageSeconds: 5,
      isoPolicySeconds: 6,
      swiftCopySwizzleSeconds: 7
    )

    #expect(timings.nativeDecodeSeconds == 21)
    #expect(timings.totalSeconds == 28)
  }

  @Test(
    "Representative RAF corpus matches RawPy reference pixels",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; RAW parity test skipped")
  )
  func representativeRAFCorpus() throws {
    let reference = try JSONDecoder().decode(
      RawDecodeReference.self,
      from: Data(contentsOf: FixtureLoader.fixtureURL("", file: "raw_decode_reference.json"))
    )
    let rawDirectory = repositoryRoot.appending(path: "sample-raw")

    for entry in reference.entries {
      let result = try RawImageDecoder.decode(rawDirectory.appending(path: entry.file))

      #expect([result.image.height, result.image.width, result.image.channels] == entry.shape)
      #expect(sha256(result.image.pixels) == entry.sha256)
      #expect(result.colorDescription == entry.colorDescription)
    }
  }

  @Test(
    "Full-resolution RAF decode matches RawPy reference pixels",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; full-resolution RAW parity test skipped")
  )
  func fullResolutionRAF() throws {
    let reference = try loadReference()
    let rawDirectory = repositoryRoot.appending(path: "sample-raw")

    let entry = reference.fullResolution
    let result = try RawImageDecoder.decode(
      rawDirectory.appending(path: entry.file),
      fullResolution: true
    )

    #expect([result.image.height, result.image.width, result.image.channels] == entry.shape)
    #expect(sha256(result.image.pixels) == entry.sha256)
    #expect(result.colorDescription == entry.colorDescription)
  }

  @Test(
    "Representative RAF completes the interactive correction preview pipeline",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; RAW preview-pipeline test skipped")
  )
  func interactiveCorrectionPreview() throws {
    let rawURL = repositoryRoot.appending(path: "sample-raw/DSCF2422.RAF")

    let decoded = try RawImageDecoder.decode(rawURL).image
    let proxy = decoded.resizedToFit(maxDimension: 720)
    let corrected = FilmProcessing.correctedPreview(
      image: proxy,
      parameters: ProcessingParameters(
        rotation: 3,
        filmType: .colourNegative,
        gamma: 20,
        shadows: 30,
        highlights: 10,
        temperature: 10,
        tint: -10,
        saturation: 110
      )
    )

    #expect(max(corrected.width, corrected.height) == 720)
    #expect(corrected.channels == 3)
    #expect(corrected.makePreviewCGImage() != nil)
  }

  @Test(
    "RawTherapee camera-scan preset preserves representative RAF tone and chroma",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; camera-scan quality guard skipped")
  )
  func rawTherapeeCameraScanQualityGuard() throws {
    let rawURL = repositoryRoot.appending(path: "sample-raw/DSCF2422.RAF")
    let result = try RawImageDecoder.decode(rawURL, profile: .rawTherapeeCameraScan)
    #expect(result.isoSpeed > 0)
    #expect(result.processing.contains(.isoSharpen) || result.processing.contains(.isoDenoise))
    let decoded = result.image
    let proxy = decoded.resizedToFit(maxDimension: 720)
    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: proxy)
    let corrected = FilmProcessing.correctedPreview(
      image: proxy,
      parameters: ProcessingParameters(
        filmType: .colourNegative,
        filmNegativeParams: filmNegative
      )
    )

    let pixelCount = corrected.width * corrected.height
    var clippedPixels = 0
    var chromaSum = 0.0
    for pixelIndex in 0..<pixelCount {
      let base = pixelIndex * 3
      let channels = corrected.pixels[base..<(base + 3)]
      let minimum = Double(channels.min() ?? 0)
      let maximum = Double(channels.max() ?? 0)
      if minimum == 0 || maximum == 65_535 {
        clippedPixels += 1
      }
      chromaSum += maximum > 0 ? (maximum - minimum) / maximum : 0
    }

    let clippedFraction = Double(clippedPixels) / Double(pixelCount)
    let meanChroma = chromaSum / Double(pixelCount)
    #expect(clippedFraction < 0.15, "clipped pixel fraction: \(clippedFraction)")
    #expect(meanChroma > 0.05, "mean chroma: \(meanChroma)")
  }

  @Test(
    "Full-resolution X-Trans camera-scan decode uses three-pass interpolation",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; X-Trans demosaic test skipped")
  )
  func fullResolutionXTransUsesThreePassInterpolation() throws {
    let rawURL = repositoryRoot.appending(path: "sample-raw/DSCF2422.RAF")

    let result = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan
    )

    #expect(result.processing.contains(.xTransThreePass))
    #expect(result.image.width > 3_876)
    #expect(result.image.height > 2_592)
    #expect(result.timings.openSeconds > 0)
    #expect(result.timings.unpackSeconds > 0)
    #expect(result.timings.demosaicSeconds > 0)
    #expect(result.timings.libRawPostprocessSeconds >= 0)
    #expect(result.timings.processedImageSeconds > 0)
    #expect(result.timings.isoPolicySeconds > 0)
    #expect(result.timings.swiftCopySwizzleSeconds > 0)
  }

  @Test(
    "Representative RAF embedded thumbnail decodes into a 3-channel preview image",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; embedded thumbnail test skipped")
  )
  func embeddedThumbnailDecode() throws {
    let rawURL = repositoryRoot.appending(path: "sample-raw/DSCF2422.RAF")

    let thumbnail = try RawImageDecoder.extractThumbnail(rawURL)

    #expect(thumbnail.width > 0)
    #expect(thumbnail.height > 0)
    #expect(thumbnail.image.width == thumbnail.width)
    #expect(thumbnail.image.height == thumbnail.height)
    #expect(thumbnail.image.channels == 3)
    #expect(thumbnail.image.pixels.count == thumbnail.width * thumbnail.height * 3)
    #expect(thumbnail.image.makePreviewCGImage() != nil)
  }

  @Test(
    "Representative RAF embedded thumbnail decodes directly to the requested preview bound",
    .enabled(if: rawCorpusAvailable, "sample-raw corpus unavailable; bounded thumbnail test skipped")
  )
  func embeddedThumbnailDecodeRespectsPreviewBound() throws {
    let rawURL = repositoryRoot.appending(path: "sample-raw/DSCF2422.RAF")

    let thumbnail = try RawImageDecoder.extractThumbnail(rawURL, maxDimension: 640)

    #expect(max(thumbnail.width, thumbnail.height) <= 640)
    #expect(max(thumbnail.width, thumbnail.height) >= 600)
    #expect(thumbnail.image.width == thumbnail.width)
    #expect(thumbnail.image.height == thumbnail.height)
    #expect(thumbnail.image.pixels.count == thumbnail.width * thumbnail.height * 3)
  }

  @Test("Standard images do not enter the RAW decoder")
  func rejectsStandardImageExtension() {
    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.decode(URL(fileURLWithPath: "/tmp/scan.png"))
    }
  }

  @Test("Standard images do not enter embedded RAW thumbnail extraction")
  func thumbnailRejectsStandardImageExtension() {
    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.extractThumbnail(URL(fileURLWithPath: "/tmp/scan.png"))
    }
  }

  @Test("Missing RAW files report a LibRaw decode failure")
  func missingRAWFile() {
    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.decode(URL(fileURLWithPath: "/tmp/missing-film-scan.raf"))
    }
  }

  private var repositoryRoot: URL {
    rawDecoderRepositoryRoot
  }

  private func loadReference() throws -> RawDecodeReference {
    try JSONDecoder().decode(
      RawDecodeReference.self,
      from: Data(contentsOf: FixtureLoader.fixtureURL("", file: "raw_decode_reference.json"))
    )
  }

  private func sha256(_ pixels: [UInt16]) -> String {
    pixels.withUnsafeBytes {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
  }
}
