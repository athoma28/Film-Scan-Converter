import CoreGraphics
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanEngine

private var phoenixSampleRawAvailable: Bool {
  SampleRawCorpus.triplets().contains { $0.stockID == "harmanphoenixii" }
}

@Suite("Density-print inversion")
struct DensityPrintProcessingTests {
  @Test("Identity unmix at strength zero is a row-normalized identity")
  func unmixIdentityAtZeroStrength() {
    var profile = NegativeDensityProfileCatalog.harmanPhoenixII
    profile = profile.withUnmix(flatRGB: profile.unmixRGBFlat, strength: 0)
    let (blue, green, red) = profile.appliedUnmixBGR()
    assertChannel(blue, blue: 1, green: 0, red: 0)
    assertChannel(green, blue: 0, green: 1, red: 0)
    assertChannel(red, blue: 0, green: 0, red: 1)
  }

  @Test("Unmix blend is identity-mixed then row-normalized")
  func unmixBlendRowNormalizes() {
    let matrix: [Double] = [
      2, 0, 0,
      0, 2, 0,
      0, 0, 2,
    ]
    let profile = NegativeDensityProfileCatalog.genericC41.withUnmix(
      flatRGB: matrix, strength: 1)
    let identity = profile.appliedUnmixBGR()
    assertChannel(identity.0, blue: 1, green: 0, red: 0)
    assertChannel(identity.1, blue: 0, green: 1, red: 0)
    assertChannel(identity.2, blue: 0, green: 0, red: 1)

    let half = NegativeDensityProfile(
      id: NegativeDensityProfileID(rawValue: "blend"),
      displayName: "Blend",
      provenance: .tuned,
      unmixRGB: [
        [2, 1, 0],
        [0, 1, 0],
        [0, 0, 1],
      ],
      unmixStrength: 0.5
    )
    let blended = half.appliedUnmixBGR()
    assertChannel(blended.0, blue: 1, green: 0, red: 0)
    assertChannel(blended.1, blue: 0, green: 1, red: 0)
    assertChannel(blended.2, blue: 0, green: 0.25, red: 0.75)
  }

  @Test("Density-print analysis insets 20% like calibrated inversion")
  func densityPrintAnalysisDefaultBorderMatchesCalibratedMedians() {
    #expect(DensityPrintProcessing.analyzeBorderPercent == 20)
  }

  @Test("Phoenix II physical profile is a digital-scene tuned unmix on Crystal Archive paper")
  func phoenixPhysicalProfileIsDigitallyTuned() {
    let profile = NegativeDensityProfileCatalog.harmanPhoenixII
    #expect(profile.provenance == .tuned)
    #expect(profile.maskFamily == .cyan)
    #expect(profile.unmixRGB[1][0] == -0.075)
    #expect(profile.printGrade == 118)
    #expect(profile.castRemovalStrength == 0.55)
    #expect(
      FilmNegativeParams.densityPrintHarmanPhoenixII.densityPaperID
        == DensityPaperProfileCatalog.fujiCrystalArchive.id.rawValue)
  }

  @Test("H&D print density is monotone and encodes black/white via BPC")
  func printDensityMonotoneAndBlackPointCompensation() {
    let slope = 2.9
    let pivot = 0.2
    var previous = DensityPrintProcessing.printDensity(0, slope: slope, pivot: pivot)
    for step in 1...20 {
      let x = Double(step) / 20
      let current = DensityPrintProcessing.printDensity(x, slope: slope, pivot: pivot)
      #expect(current >= previous - 1e-9)
      previous = current
    }

    let black = DensityPrintProcessing.encodeReflectance(DensityPrintProcessing.dMax)
    let white = DensityPrintProcessing.encodeReflectance(0)
    #expect(black == 0)
    #expect(white == 65_535)

    let mid = FilmNegativeProcessing.sRGBToLinear(0.5)
    let encoded = FilmNegativeProcessing.linearToSRGB(mid)
    #expect(abs(encoded - 0.5) < 1e-6)
  }

  @Test("sRGB linearization round-trips at the endpoints and midtones")
  func sRGBRoundTrip() {
    for value in [0.0, 0.0031308, 0.04045, 0.18, 0.5, 1.0] {
      let linear = FilmNegativeProcessing.sRGBToLinear(value)
      let restored = FilmNegativeProcessing.linearToSRGB(linear)
      #expect(abs(restored - value) < 1e-6)
    }
  }

  @Test("Classifier selects Physical Phoenix for a cyan-mask scan")
  func classifierIdentifiesCyanMaskPhoenix() {
    let image = repeatedImage(
      width: 16,
      height: 16,
      bgr: [
        (blue: 33_888, green: 30_314, red: 24_727),
        (blue: 34_200, green: 30_100, red: 24_400),
        (blue: 33_500, green: 30_500, red: 25_100),
      ]
    )
    let classification = FilmNegativeProcessing.classifyFilmScan(image: image)
    #expect(classification.filmType == .colourNegative)
    #expect(classification.filmNegativePreset == .densityPrintHarmanPhoenixII)
    #expect(classification.confidence >= 0.45)
  }

  @Test("Density-print params round-trip through JSON")
  func densityPrintParamsCodableRoundTrip() throws {
    let original = FilmNegativeParams.densityPrintHarmanPhoenixII
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(FilmNegativeParams.self, from: encoded)
    #expect(decoded.rendering == .densityPrint)
    #expect(decoded.densityProfileID == original.densityProfileID)
    #expect(decoded.densityUnmixRGB == original.densityUnmixRGB)
    #expect(decoded.densityUnmixStrength == original.densityUnmixStrength)
    #expect(decoded.densityPaperID == DensityPaperProfileCatalog.fujiCrystalArchive.id.rawValue)
    #expect(decoded.enabled)
  }

  @Test("Bundled catalog includes remaining NegPy spec-sheet stocks")
  func bundledCatalogIncludesRemainingNegPyStocks() {
    let ids = Set(NegativeDensityProfileCatalog.bundled.map(\.id.rawValue))
    #expect(ids.contains("kodak_aerocolor_iv_2460"))
    #expect(ids.contains("fujicolor_c200"))
    #expect(ids.contains("fujicolor_superia_xtra_400"))
    #expect(
      NegativeDensityProfileCatalog.fujicolorC200.unmixRGB
        == NegativeDensityProfileCatalog.fujicolor400.unmixRGB)
  }

  @Test("RA4 paper dye mix preserves neutrals and Endura cools shadows")
  func ra4PaperDyeMixPreservesNeutrals() {
    let identity = DensityPaperProfileCatalog.neutral.appliedDyeMixBGR()
    assertChannel(identity.0, blue: 1, green: 0, red: 0)
    assertChannel(identity.1, blue: 0, green: 1, red: 0)
    assertChannel(identity.2, blue: 0, green: 0, red: 1)

    let endura = DensityPaperProfileCatalog.kodakEnduraPremier.appliedDyeMixBGR()
    #expect(abs(endura.0.blue + endura.0.green + endura.0.red - 1) < 1e-9)
    #expect(abs(endura.1.blue + endura.1.green + endura.1.red - 1) < 1e-9)
    #expect(abs(endura.2.blue + endura.2.green + endura.2.red - 1) < 1e-9)
    #expect(DensityPaperProfileCatalog.kodakEnduraPremier.channelGammaRGB[0] > 1)
    #expect(DensityPaperProfileCatalog.kodakEnduraPremier.channelGammaRGB[2] < 1)
    let crystalTint = DensityPaperProfileCatalog.fujiCrystalArchive.paperDMinBGR
    #expect(crystalTint.blue < crystalTint.red)
    #expect(crystalTint.green < crystalTint.red)
  }

  @Test("Quadratic coefficient recovers a known parabola")
  func quadraticCoefficientRecoversParabola() {
    // y = 2x² + 3x + 1 at x = 0, 1, 2
    let curv = DensityPrintProcessing.quadraticCoefficient(
      x0: 0, y0: 1,
      x1: 1, y1: 6,
      x2: 2, y2: 15
    )
    #expect(abs(curv - 2) < 1e-9)
  }

  @Test("Missing density paper id migrates to Neutral")
  func missingDensityPaperIDMigratesToNeutral() throws {
    let json = """
      {"enabled":true,"redRatio":1.36,"greenExp":1.5,"blueRatio":0.86,"rendering":"densityPrint","densityProfileID":"generic_c41","densityUnmixRGB":[],"densityUnmixStrength":-1}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(FilmNegativeParams.self, from: json)
    #expect(decoded.densityPaperID == "neutral")
  }

  @Test("User density-print JSON profiles load from a directory")
  func userDensityProfileJSONLoad() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fsc-density-profiles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var custom = NegativeDensityProfileCatalog.kodakPortra400
    custom.id = NegativeDensityProfileID(rawValue: "user_portra_400")
    custom.displayName = "User Portra 400"
    try JSONEncoder().encode(custom).write(
      to: directory.appendingPathComponent("user_portra_400.json"))

    let loaded = NegativeDensityProfileCatalog.load(from: directory)
    #expect(loaded.contains { $0.id.rawValue == "user_portra_400" })
    #expect(loaded.contains { $0.displayName == "User Portra 400" })
  }

  @Test("GPU density-print preview matches CPU within 2/255")
  func gpuDensityPrintMatchesCPU() {
    let image = deterministicImage(width: 64, height: 48)
    guard let renderer = StillPreviewRenderer(image: image) else {
      #expect(Bool(false), "Could not create still preview renderer")
      return
    }

    let configs: [(String, ProcessingParameters)] = [
      (
        "phoenix",
        ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: .densityPrintHarmanPhoenixII
        )
      ),
      (
        "generic-c41",
        ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: .densityPrintGenericC41
        )
      ),
      (
        "phoenix-exposure",
        ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: .densityPrintHarmanPhoenixII,
          photoAdjustments: PhotoAdjustmentParameters(exposureEV: 0.5)
        )
      ),
      (
        "endura-paper",
        ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: FilmNegativeParams.densityPrint(
            NegativeDensityProfileCatalog.genericC41,
            paper: DensityPaperProfileCatalog.kodakEnduraPremier
          )
        )
      ),
    ]

    var maxDiff = 0
    var worstName = ""
    for (name, parameters) in configs {
      guard
        let gpu = renderer.render(parameters: parameters, showOriginal: false),
        let cpu = FilmProcessing.correctedPreview(image: image, parameters: parameters)
          .makePreviewCGImage(),
        let gpuPixels = rgbaPixels(gpu),
        let cpuPixels = rgbaPixels(cpu)
      else {
        #expect(Bool(false), "Render failed for \(name)")
        continue
      }
      var comboMax = 0
      for index in gpuPixels.indices {
        comboMax = max(comboMax, abs(Int(gpuPixels[index]) - Int(cpuPixels[index])))
      }
      if comboMax > maxDiff {
        maxDiff = comboMax
        worstName = name
      }
    }
    #expect(
      maxDiff <= 2,
      "Density-print GPU max diff \(maxDiff)/255 at '\(worstName)'"
    )
  }

  @Test(
    "Physical density print MAE vs Camera Raw JPEGs is reported for Phoenix II",
    .enabled(
      if: phoenixSampleRawAvailable,
      "Harman Phoenix II sample-raw triplets unavailable; MAE comparison skipped")
  )
  func phoenixDensityPrintMAEAgainstCameraRaw() throws {
    let triplets = SampleRawCorpus.triplets().filter { $0.stockID == "harmanphoenixii" }
    #expect(!triplets.isEmpty)
    // Sampled 3-frame MAE vs Camera Raw JPEG (2026-08-15, 20% rebate inset
    // plus digital-scene unmix on Crystal Archive):
    // generic=0.179, alternate LUT=0.078, physical=0.090.
    // Decode+invert of every RAF is too slow for the default suite.
    let sampled = Array(triplets.prefix(3))

    var genericErrors: [Double] = []
    var alternateErrors: [Double] = []
    var physicalErrors: [Double] = []

    for triplet in sampled {
      let reference = try SampleRawCorpus.loadAlignedReference(triplet)
      let medians = FilmNegativeProcessing.computeMedians(image: reference.raw)

      var generic = FilmNegativeParams.colourNegative
      generic.measuredMedians = medians
      let genericRender = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .colourNegative, filmNegativeParams: generic)
      )

      var alternate = FilmNegativeParams.harmanPhoenixIIAlternate
      alternate.measuredMedians = medians
      let alternateRender = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .colourNegative, filmNegativeParams: alternate)
      )

      let physicalRender = FilmProcessing.correctedPreview(
        image: reference.raw,
        parameters: ProcessingParameters(
          filmType: .colourNegative,
          filmNegativeParams: .densityPrintHarmanPhoenixII
        )
      )

      genericErrors.append(referenceMAE(genericRender, against: reference))
      alternateErrors.append(referenceMAE(alternateRender, against: reference))
      physicalErrors.append(referenceMAE(physicalRender, against: reference))
    }

    let genericMean = mean(genericErrors)
    let alternateMean = mean(alternateErrors)
    let physicalMean = mean(physicalErrors)
    print(
      "Phoenix II MAE vs Camera Raw JPEG: generic=\(genericMean) alternate=\(alternateMean) physical=\(physicalMean)"
    )
    // Physical print is a different rendering model, not a Camera Raw LUT fit.
    // Guard only against producing a collapsed or inverted image.
    #expect(physicalMean < 0.55)
    #expect(alternateMean < genericMean)
  }

  @Test(
    "Real Phoenix II scans classify as Physical Phoenix",
    .enabled(
      if: phoenixSampleRawAvailable,
      "Harman Phoenix II sample-raw triplets unavailable; classifier check skipped")
  )
  func realPhoenixScansClassifyAsPhysicalPhoenix() throws {
    let triplets = SampleRawCorpus.triplets().filter { $0.stockID == "harmanphoenixii" }
    let sampled = Array(triplets.prefix(3))
    #expect(!sampled.isEmpty)
    for triplet in sampled {
      let image = try RawImageDecoder.decode(
        triplet.rawURL,
        profile: .rawTherapeeCameraScan
      ).image
      let classification = FilmNegativeProcessing.classifyFilmScan(image: image)
      let medians = FilmNegativeProcessing.computeMedians(image: image)
      #expect(
        classification.filmType == .colourNegative,
        "\(triplet.stem) type=\(classification.filmType) preset=\(classification.filmNegativePreset) medians B=\(medians.blue) G=\(medians.green) R=\(medians.red)"
      )
      #expect(
        classification.filmNegativePreset == .densityPrintHarmanPhoenixII,
        "\(triplet.stem) preset=\(classification.filmNegativePreset) medians B=\(medians.blue) G=\(medians.green) R=\(medians.red)"
      )
    }
  }

  private func mean(_ values: [Double]) -> Double {
    values.reduce(0, +) / Double(max(values.count, 1))
  }

  private func assertChannel(
    _ channel: BGRChannelValues,
    blue: Double,
    green: Double,
    red: Double,
    tolerance: Double = 1e-9
  ) {
    #expect(abs(channel.blue - blue) < tolerance)
    #expect(abs(channel.green - green) < tolerance)
    #expect(abs(channel.red - red) < tolerance)
  }

  private func repeatedImage(
    width: Int,
    height: Int,
    bgr samples: [(blue: UInt16, green: UInt16, red: UInt16)]
  ) -> UInt16Image {
    var pixels: [UInt16] = []
    pixels.reserveCapacity(width * height * 3)
    for index in 0..<(width * height) {
      let sample = samples[index % samples.count]
      pixels.append(sample.blue)
      pixels.append(sample.green)
      pixels.append(sample.red)
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private func deterministicImage(width: Int, height: Int) -> UInt16Image {
    let componentCount = width * height * 3
    var pixels = [UInt16]()
    pixels.reserveCapacity(componentCount)
    var state: UInt64 = 0x67CD_9321_9D23_E551
    for _ in 0..<componentCount {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      pixels.append(UInt16(truncatingIfNeeded: state >> 32))
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
    guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
      return nil
    }
    return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
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
}
