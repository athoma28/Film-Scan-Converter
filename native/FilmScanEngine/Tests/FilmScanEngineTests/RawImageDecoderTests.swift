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

private var xT5RegressionSamplesAvailable: Bool {
  ["DSCF2819.RAF", "DSCF2820.RAF", "DSCF2823.RAF"]
    .allSatisfy { SampleRawCorpus.uniqueURL(named: $0) != nil }
}

private var pairedBlackAndWhiteSamplesAvailable: Bool {
  SampleRawCorpus.triplets().filter(\.isMonochrome).count >= 3
}

private var pairedColorSamplesAvailable: Bool {
  SampleRawCorpus.triplets().filter { !$0.isMonochrome }.count >= 3
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

private var rawReferenceCorpusAvailable: Bool {
  guard
    let data = try? Data(
      contentsOf: FixtureLoader.fixtureURL("", file: "raw_decode_reference.json")
    ),
    let reference = try? JSONDecoder().decode(RawDecodeReference.self, from: data)
  else { return false }
  return (reference.entries + [reference.fullResolution]).allSatisfy {
    SampleRawCorpus.uniqueURL(named: $0.file) != nil
  }
}

private var representativeRawURL: URL? {
  SampleRawCorpus.triplets().first(where: { !$0.isMonochrome })?.rawURL
    ?? SampleRawCorpus.rawURLs().first
}

private var representativeRawAvailable: Bool {
  representativeRawURL != nil
}

@Suite("LibRaw decoding")
struct RawImageDecoderTests {
  @Test(
    "Calibrated color profile tracks paired Camera Raw references",
    .enabled(
      if: pairedColorSamplesAvailable,
      "paired color RAW/JPEG/XMP samples unavailable; calibration guard skipped")
  )
  func calibratedColorProfileTracksCameraRawReferences() throws {
    let triplets = SampleRawCorpus.triplets().filter { !$0.isMonochrome }
    var calibratedErrors: [Double] = []
    var legacyErrors: [Double] = []
    for triplet in triplets {
      let reference = try SampleRawCorpus.loadAlignedReference(triplet)
      let medians = FilmNegativeProcessing.computeMedians(
        image: reference.raw,
        borderPercent: 20
      )
      var calibratedParams = FilmNegativeParams.colourNegative
      calibratedParams.measuredMedians = medians
      let rendered = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: calibratedParams
        )
      )
      var legacyParams = FilmNegativeParams.legacyColourNegative
      legacyParams.measuredMedians = medians
      let legacy = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: legacyParams
        )
      )
      let calibratedError = referenceMAE(rendered, against: reference)
      let legacyError = referenceMAE(legacy, against: reference)
      calibratedErrors.append(calibratedError)
      legacyErrors.append(legacyError)
      #expect(
        calibratedError < 0.23,
        "\(triplet.stockID)/\(triplet.stem) mean absolute colour error \(calibratedError)"
      )
    }
    let calibratedMean = calibratedErrors.reduce(0, +) / Double(calibratedErrors.count)
    let legacyMean = legacyErrors.reduce(0, +) / Double(legacyErrors.count)
    #expect(
      calibratedMean < 0.15,
      "generic calibrated colour mean absolute error \(calibratedMean)"
    )
    #expect(calibratedMean < legacyMean)
  }

  @Test(
    "Calibrated B&W profile tracks paired Camera Raw references",
    .enabled(
      if: pairedBlackAndWhiteSamplesAvailable,
      "paired B&W RAW/JPEG/XMP samples unavailable; calibration guard skipped")
  )
  func calibratedBlackAndWhiteProfileTracksCameraRawReferences() throws {
    let triplets = SampleRawCorpus.triplets().filter(\.isMonochrome)
    var meanAbsoluteErrors: [Double] = []
    for triplet in triplets {
      let reference = try SampleRawCorpus.loadAlignedReference(triplet)
      var filmNegative = FilmNegativeParams.blackAndWhite
      filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(
        image: reference.raw,
        borderPercent: 20
      )
      let rendered = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .blackAndWhiteNegative,
          filmNegativeParams: filmNegative
        )
      )
      let meanAbsoluteError = referenceMAE(rendered, against: reference)
      meanAbsoluteErrors.append(meanAbsoluteError)
      #expect(
        meanAbsoluteError < 0.25,
        "\(triplet.stockID)/\(triplet.stem) mean absolute tone error \(meanAbsoluteError)")
    }

    #expect(
      meanAbsoluteErrors.reduce(0, +) / Double(meanAbsoluteErrors.count) < 0.18
    )
  }

  @Test(
    "Half-resolution X-T5 decode fully interpolates bright X-Trans frames",
    .enabled(
      if: xT5RegressionSamplesAvailable,
      "X-T5 regression samples unavailable; X-Trans artifact guard skipped")
  )
  func halfResolutionXT5DecodeHasNoMosaicGrid() throws {
    for filename in ["DSCF2819.RAF", "DSCF2820.RAF", "DSCF2823.RAF"] {
      let rawURL = try #require(SampleRawCorpus.uniqueURL(named: filename))
      let image = try RawImageDecoder.decode(
        rawURL, profile: .rawTherapeeCameraScan).image
      let proxy = image.resizedToFit(maxDimension: 640)
      var extremeGreenPixels = 0
      for pixelIndex in 0..<(proxy.width * proxy.height) {
        let base = pixelIndex * 3
        let red = proxy.pixels[base]
        let green = proxy.pixels[base + 1]
        let blue = proxy.pixels[base + 2]
        if green > 60_000, red < 10_000, blue < 10_000 {
          extremeGreenPixels += 1
        }
      }
      let fraction = Double(extremeGreenPixels) / Double(proxy.width * proxy.height)
      #expect(
        fraction < 0.0005,
        "\(filename) retained the X-Trans mosaic grid (extreme-green fraction \(fraction))")
    }
  }

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
    .enabled(
      if: rawReferenceCorpusAvailable,
      "referenced sample-raw corpus unavailable; RAW parity test skipped")
  )
  func representativeRAFCorpus() throws {
    let reference = try JSONDecoder().decode(
      RawDecodeReference.self,
      from: Data(contentsOf: FixtureLoader.fixtureURL("", file: "raw_decode_reference.json"))
    )
    for entry in reference.entries {
      let rawURL = try #require(SampleRawCorpus.uniqueURL(named: entry.file))
      let result = try RawImageDecoder.decode(rawURL)

      #expect([result.image.height, result.image.width, result.image.channels] == entry.shape)
      #expect(sha256(result.image.pixels) == entry.sha256)
      #expect(result.colorDescription == entry.colorDescription)
    }
  }

  @Test(
    "Full-resolution RAF decode matches RawPy reference pixels",
    .enabled(
      if: rawReferenceCorpusAvailable,
      "referenced sample-raw corpus unavailable; full-resolution RAW parity test skipped")
  )
  func fullResolutionRAF() throws {
    let reference = try loadReference()
    let entry = reference.fullResolution
    let rawURL = try #require(SampleRawCorpus.uniqueURL(named: entry.file))
    let dimensions = try RawImageDecoder.fullResolutionDimensions(rawURL)
    let result = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true
    )

    #expect(dimensions.width == entry.shape[1])
    #expect(dimensions.height == entry.shape[0])
    #expect([result.image.height, result.image.width, result.image.channels] == entry.shape)
    #expect(sha256(result.image.pixels) == entry.sha256)
    #expect(result.colorDescription == entry.colorDescription)
  }

  @Test(
    "Representative RAF completes the interactive correction preview pipeline",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; RAW preview-pipeline test skipped")
  )
  func interactiveCorrectionPreview() throws {
    let rawURL = try #require(representativeRawURL)

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
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; camera-scan quality guard skipped")
  )
  func rawTherapeeCameraScanQualityGuard() throws {
    let rawURL = try #require(representativeRawURL)
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

    // Exclude the film-holder border: its zero-light pixels deliberately map to
    // display white and are not evidence of scene-tone clipping.
    let inset = max(1, min(corrected.width, corrected.height) / 10)
    let pixelCount = (corrected.width - inset * 2) * (corrected.height - inset * 2)
    var clippedPixels = 0
    var chromaSum = 0.0
    for y in inset..<(corrected.height - inset) {
      for x in inset..<(corrected.width - inset) {
        let base = (y * corrected.width + x) * 3
        let channels = corrected.pixels[base..<(base + 3)]
        let minimum = Double(channels.min() ?? 0)
        let maximum = Double(channels.max() ?? 0)
        if minimum == 0 || maximum == 65_535 {
          clippedPixels += 1
        }
        chromaSum += maximum > 0 ? (maximum - minimum) / maximum : 0
      }
    }

    let clippedFraction = Double(clippedPixels) / Double(pixelCount)
    let meanChroma = chromaSum / Double(pixelCount)
    #expect(clippedFraction < 0.15, "clipped pixel fraction: \(clippedFraction)")
    #expect(meanChroma > 0.05, "mean chroma: \(meanChroma)")
  }

  @Test(
    "Full-resolution X-Trans camera-scan decode uses three-pass interpolation",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; X-Trans demosaic test skipped")
  )
  func fullResolutionXTransUsesThreePassInterpolation() throws {
    let rawURL = try #require(representativeRawURL)

    let result = try RawImageDecoder.decode(
      rawURL,
      fullResolution: true,
      profile: .rawTherapeeCameraScan
    )
    let dimensions = try RawImageDecoder.fullResolutionDimensions(rawURL)

    #expect(result.processing.contains(.xTransThreePass))
    #expect(dimensions.width == result.image.width)
    #expect(dimensions.height == result.image.height)
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
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; embedded thumbnail test skipped")
  )
  func embeddedThumbnailDecode() throws {
    let rawURL = try #require(representativeRawURL)

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
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; bounded thumbnail test skipped")
  )
  func embeddedThumbnailDecodeRespectsPreviewBound() throws {
    let rawURL = try #require(representativeRawURL)

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

  private func referenceMAE(
    _ rendered: UInt16Image,
    against reference: SampleRawAlignedReference,
    sampleStride: Int = 16
  ) -> Double {
    var error = 0.0
    var componentCount = 0
    for y in stride(from: 0, to: reference.target.height, by: sampleStride) {
      for x in stride(from: 0, to: reference.target.width, by: sampleStride) {
        let renderedBase = (
          (reference.targetOriginY + y) * rendered.width
            + reference.targetOriginX + x
        ) * rendered.channels
        let targetBase = (y * reference.target.width + x) * reference.target.channels
        for channel in 0..<3 {
          let renderedValue = rendered.pixels[
            renderedBase + (rendered.channels == 1 ? 0 : channel)
          ]
          let targetValue = reference.target.pixels[
            targetBase + (reference.target.channels == 1 ? 0 : channel)
          ]
          error += abs(Double(renderedValue) - Double(targetValue)) / 65_535
          componentCount += 1
        }
      }
    }
    return error / Double(componentCount)
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
