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

/// Exact frames used to fit the built-in alternate curves. Later corpus
/// additions remain validation data and must not silently redefine the fit set.
private let calibratedAlternateFitStems: [String: Set<String>] = [
  "fuji400-fresh": [
    "DSCF2555", "DSCF2833", "DSCF2865", "DSCF2873",
    "DSCF2888", "DSCF2892", "DSCF3115", "DSCF3127",
  ],
  "fuji200-expired": ["DSCF3160"],
  "cinestill800t": ["DSCF3247", "DSCF3277"],
  "harmanphoenixii": [
    "DSCF3077", "DSCF3079", "DSCF3082", "DSCF3083",
    "DSCF3084", "DSCF3085", "DSCF3086", "DSCF3087",
    "DSCF3088", "DSCF3089", "DSCF3091", "DSCF3092",
  ],
]

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
    var genericFitErrorsByStock: [String: [Double]] = [:]
    var alternateErrorsByStock: [String: [Double]] = [:]
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

      let alternateParams: FilmNegativeParams? =
        switch triplet.stockID {
        case "fuji400-fresh": .fuji400FreshAlternate
        case "fuji200-expired": .fuji200ExpiredAlternate
        case "cinestill800t": .cinestill800TAlternate
        case "harmanphoenixii": .harmanPhoenixIIAlternate
        default: nil
        }
      let belongsToAlternateFit =
        calibratedAlternateFitStems[triplet.stockID]?
        .contains(triplet.stem) == true
      if var alternateParams, belongsToAlternateFit {
        genericFitErrorsByStock[triplet.stockID, default: []].append(calibratedError)
        alternateParams.measuredMedians = medians
        let alternate = FilmProcessing.correctedPreview(
          image: reference.raw,
          parameters: ProcessingParameters(
            filmType: .colourNegative,
            filmNegativeParams: alternateParams
          )
        )
        alternateErrorsByStock[triplet.stockID, default: []].append(
          referenceMAE(alternate, against: reference)
        )
      }
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
    for stockID in [
      "fuji400-fresh", "fuji200-expired", "cinestill800t", "harmanphoenixii",
    ] {
      let generic = try #require(genericFitErrorsByStock[stockID])
      let alternate = try #require(alternateErrorsByStock[stockID])
      let genericMean = generic.reduce(0, +) / Double(generic.count)
      let alternateMean = alternate.reduce(0, +) / Double(alternate.count)
      #expect(
        alternateMean < genericMean,
        "\(stockID) alternate \(alternateMean) should beat generic \(genericMean) on its fit set"
      )
    }
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
    "Shanghai GP3 alternate tracks paired Camera Raw references and beats legacy",
    .enabled(
      if: pairedBlackAndWhiteSamplesAvailable,
      "paired B&W RAW/JPEG/XMP samples unavailable; calibration guard skipped")
  )
  func shanghaiGP3AlternateTracksCameraRawReferences() throws {
    let triplets = SampleRawCorpus.triplets().filter(\.isMonochrome)
    var alternateErrors: [Double] = []
    var legacyErrors: [Double] = []
    for triplet in triplets {
      let reference = try SampleRawCorpus.loadAlignedReference(triplet)
      let medians = FilmNegativeProcessing.computeMedians(
        image: reference.raw,
        borderPercent: 20
      )
      var alternate = FilmNegativeParams.shanghaiGP3Alternate
      alternate.measuredMedians = medians
      let alternateRender = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .blackAndWhiteNegative,
          filmNegativeParams: alternate
        )
      )
      var legacy = FilmNegativeParams.legacyBlackAndWhite
      legacy.measuredMedians = medians
      let legacyRender = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .blackAndWhiteNegative,
          filmNegativeParams: legacy
        )
      )
      let alternateError = referenceMAE(alternateRender, against: reference)
      let legacyError = referenceMAE(legacyRender, against: reference)
      alternateErrors.append(alternateError)
      legacyErrors.append(legacyError)
      #expect(
        alternateError < 0.25,
        "\(triplet.stockID)/\(triplet.stem) GP3 alternate tone error \(alternateError)")
    }

    let alternateMean = alternateErrors.reduce(0, +) / Double(alternateErrors.count)
    let legacyMean = legacyErrors.reduce(0, +) / Double(legacyErrors.count)
    #expect(alternateMean < 0.18)
    #expect(
      alternateMean < legacyMean,
      "GP3 alternate \(alternateMean) should beat legacy B&W \(legacyMean)")
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
        rawURL, profile: .rawTherapeeCameraScan
      ).image
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
    #expect(RawProcessingStages.deterministicParallelXTrans.rawValue == 1 << 5)
    #expect(RawProcessingStages.parallelFujiUnpack.rawValue == 1 << 6)
    #expect(RawProcessingStages.previewBound.rawValue == 1 << 7)
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
    #expect(result.demosaicWorkerCount >= 1)
    #expect(
      result.processing.contains(.deterministicParallelXTrans)
        == (result.demosaicWorkerCount > 1))
    #expect(result.unpackWorkerCount >= 1)
    #expect(
      result.processing.contains(.parallelFujiUnpack) == (result.unpackWorkerCount > 1))
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
    "Camera-scan preview bound interpolates a CFA-shrunk mosaic instead of the full sensor",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; preview-bound demosaic test skipped")
  )
  func cameraScanPreviewBoundShrinksMosaicBeforeDemosaic() throws {
    let rawURL = try #require(representativeRawURL)
    let bound = 800
    let result = try RawImageDecoder.decode(
      rawURL,
      profile: .rawTherapeeCameraScan,
      maxDimension: bound
    )
    let full = try RawImageDecoder.fullResolutionDimensions(rawURL)

    #expect(result.processing.contains(.previewBound))
    #expect(!result.processing.contains(.xTransThreePass))
    #expect(max(result.image.width, result.image.height) <= bound)
    #expect(max(result.image.width, result.image.height) >= bound / 3)
    #expect(result.image.channels == 3)
    #expect(full.width > result.image.width)
    #expect(full.height > result.image.height)
    #expect(result.image.makePreviewCGImage() != nil)
  }

  @Test(
    "Camera-scan 1200px preview bound interpolates below the full sensor",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; 1200px preview-bound test skipped")
  )
  func cameraScan1200PreviewBoundShrinksMosaicBeforeDemosaic() throws {
    let rawURL = try #require(representativeRawURL)
    let bound = 1_200
    let result = try RawImageDecoder.decode(
      rawURL,
      profile: .rawTherapeeCameraScan,
      maxDimension: bound
    )
    let full = try RawImageDecoder.fullResolutionDimensions(rawURL)

    #expect(result.processing.contains(.previewBound))
    #expect(!result.processing.contains(.xTransThreePass))
    #expect(max(result.image.width, result.image.height) <= bound)
    #expect(max(result.image.width, result.image.height) > 640)
    #expect(full.width > result.image.width)
  }

  @Test(
    "Camera-scan full-sensor 1-pass preview does not bin the mosaic",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; full-sensor 1-pass preview test skipped")
  )
  func cameraScanFullSensorOnePassPreviewSkipsMosaicShrink() throws {
    let rawURL = try #require(representativeRawURL)
    let result = try RawImageDecoder.decode(
      rawURL,
      profile: .rawTherapeeCameraScan,
      maxDimension: 100_000
    )
    let full = try RawImageDecoder.fullResolutionDimensions(rawURL)

    #expect(!result.processing.contains(.previewBound))
    #expect(!result.processing.contains(.xTransThreePass))
    #expect(max(result.image.width, result.image.height) > 2_400)
    #expect(max(result.image.width, result.image.height) >= max(full.width, full.height) * 9 / 10)
  }

  @Test(
    "Camera-scan 2400px preview bound interpolates below the full sensor",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; 2400px preview-bound test skipped")
  )
  func cameraScan2400PreviewBoundShrinksMosaicBeforeDemosaic() throws {
    let rawURL = try #require(representativeRawURL)
    let bound = 2_400
    let result = try RawImageDecoder.decode(
      rawURL,
      profile: .rawTherapeeCameraScan,
      maxDimension: bound
    )
    let full = try RawImageDecoder.fullResolutionDimensions(rawURL)

    #expect(result.processing.contains(.previewBound))
    #expect(!result.processing.contains(.xTransThreePass))
    #expect(max(result.image.width, result.image.height) <= bound)
    #expect(max(result.image.width, result.image.height) > 1_200)
    #expect(full.width > result.image.width)
  }

  @Test(
    "Camera-scan 400px preview bound decodes",
    .enabled(
      if: representativeRawAvailable,
      "sample-raw corpus unavailable; 400px preview-bound test skipped")
  )
  func cameraScan400PreviewBoundDecodes() throws {
    let rawURL = try #require(representativeRawURL)
    let result = try RawImageDecoder.decode(
      rawURL,
      profile: .rawTherapeeCameraScan,
      maxDimension: 400
    )
    #expect(result.processing.contains(.previewBound))
    #expect(max(result.image.width, result.image.height) <= 400)
    #expect(result.image.channels == 3)
  }

  @Test(
    "Camera-scan preview-bound latency sweep",
    .enabled(
      if: representativeRawAvailable
        && ProcessInfo.processInfo.environment["FSC_PREVIEW_BOUND_SWEEP"] == "1",
      "set FSC_PREVIEW_BOUND_SWEEP=1 with the sample-raw corpus to measure preview-bound decode")
  )
  func cameraScanPreviewBoundLatencySweep() throws {
    let rawURL = try #require(representativeRawURL)
    _ = try RawImageDecoder.decode(
      rawURL, profile: .rawTherapeeCameraScan, maxDimension: 400)
    let bounds = [1_200, 2_400, 3_200, 4_000, 5_000, 8_000]
    for bound in bounds {
      var walls: [Double] = []
      var last: RawDecodeResult?
      for _ in 0..<3 {
        let start = ContinuousClock.now
        last = try RawImageDecoder.decode(
          rawURL, profile: .rawTherapeeCameraScan, maxDimension: bound)
        walls.append(rawDecodeSweepSeconds(start.duration(to: .now)))
      }
      let result = try #require(last)
      let median = walls.sorted()[walls.count / 2]
      let full = try RawImageDecoder.fullResolutionDimensions(rawURL)
      print(
        "preview-bound \(bound): \(result.image.width)×\(result.image.height) "
          + "wallMedian=\(String(format: "%.3f", median))s "
          + "unpack=\(String(format: "%.3f", result.timings.unpackSeconds))s "
          + "demosaic=\(String(format: "%.3f", result.timings.demosaicSeconds))s "
          + "total=\(String(format: "%.3f", result.timings.totalSeconds))s"
      )
      #expect(max(result.image.width, result.image.height) <= max(bound, full.width, full.height))
      if max(full.width, full.height) > bound {
        #expect(result.processing.contains(.previewBound))
        #expect(max(result.image.width, result.image.height) <= bound)
      }
    }
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

  @Test("Truncated RAW files report a LibRaw decode failure")
  func truncatedRAWFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-truncated-raw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("truncated.raf")
    try Data("FUJIFILMCCD-RAW".utf8).write(to: url)

    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.decode(url)
    }
    #expect(throws: RawImageDecoderError.self) {
      try RawImageDecoder.extractThumbnail(url)
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
        let renderedBase =
          ((reference.targetOriginY + y) * rendered.width
            + reference.targetOriginX + x) * rendered.channels
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

private func rawDecodeSweepSeconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
