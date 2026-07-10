import Dispatch
import Foundation

private final class SendableMutableBuffer<Element>: @unchecked Sendable {
  let baseAddress: UnsafeMutablePointer<Element>

  init(_ baseAddress: UnsafeMutablePointer<Element>) {
    self.baseAddress = baseAddress
  }
}

public struct BGRChannelValues: Codable, Equatable, Sendable {
  public var blue: Double
  public var green: Double
  public var red: Double

  public init(blue: Double, green: Double, red: Double) {
    self.blue = blue
    self.green = green
    self.red = red
  }

  fileprivate subscript(channel: Int) -> Double {
    switch channel {
    case 0: blue
    case 1: green
    case 2: red
    default: preconditionFailure("BGR channel index must be 0, 1, or 2")
    }
  }
}

public struct CaptureNormalizationParameters: Codable, Equatable, Sendable {
  public var blackLevel: BGRChannelValues
  public var epsilon: Double

  public init(
    blackLevel: BGRChannelValues = BGRChannelValues(blue: 0, green: 0, red: 0),
    epsilon: Double = 1e-6
  ) {
    precondition(epsilon > 0 && epsilon <= 1, "Epsilon must be in the range (0, 1]")
    self.blackLevel = blackLevel
    self.epsilon = epsilon
  }
}

public struct ImageRegion: Codable, Equatable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public enum FilmBaseMeasurementError: Error, Equatable, Sendable {
  case emptyRegion
  case invalidRegion
  case noSamples
}

public struct FilmBaseMeasurement: Codable, Equatable, Sendable {
  public var baseDensity: BGRChannelValues
  public var medianTransmittance: BGRChannelValues
  public var trimmedMeanTransmittance: BGRChannelValues
  public var sampleCount: Int
  public var rejectedFraction: Double
  public var confidence: Double

  public init(
    baseDensity: BGRChannelValues,
    medianTransmittance: BGRChannelValues,
    trimmedMeanTransmittance: BGRChannelValues,
    sampleCount: Int,
    rejectedFraction: Double,
    confidence: Double
  ) {
    self.baseDensity = baseDensity
    self.medianTransmittance = medianTransmittance
    self.trimmedMeanTransmittance = trimmedMeanTransmittance
    self.sampleCount = sampleCount
    self.rejectedFraction = rejectedFraction
    self.confidence = confidence
  }
}

public struct RollProfile: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var rollID: String
  public var filmStockID: FilmStockProfileID
  public var captureProfileID: CaptureProfileID
  public var measuredBaseDensity: BGRChannelValues?
  public var measurementCount: Int
  public var exposureBias: Double
  public var whiteBalanceCorrection: BGRChannelValues

  public init(
    schemaVersion: Int = 2,
    rollID: String,
    filmStockID: FilmStockProfileID,
    captureProfileID: CaptureProfileID,
    measuredBaseDensity: BGRChannelValues? = nil,
    measurementCount: Int = 0,
    exposureBias: Double = 0,
    whiteBalanceCorrection: BGRChannelValues = BGRChannelValues(blue: 1, green: 1, red: 1)
  ) {
    self.schemaVersion = schemaVersion
    self.rollID = rollID
    self.filmStockID = filmStockID
    self.captureProfileID = captureProfileID
    self.measuredBaseDensity = measuredBaseDensity
    self.measurementCount = measurementCount
    self.exposureBias = exposureBias
    self.whiteBalanceCorrection = whiteBalanceCorrection
  }

  public init(
    schemaVersion: Int = 2,
    rollID: String,
    filmStockID: FilmStockProfileID,
    captureProfileID: CaptureProfileID,
    measurements: [FilmBaseMeasurement],
    exposureBias: Double = 0,
    whiteBalanceCorrection: BGRChannelValues = BGRChannelValues(blue: 1, green: 1, red: 1)
  ) {
    self.init(
      schemaVersion: schemaVersion,
      rollID: rollID,
      filmStockID: filmStockID,
      captureProfileID: captureProfileID,
      measuredBaseDensity: Self.rollBaseDensity(from: measurements),
      measurementCount: measurements.count,
      exposureBias: exposureBias,
      whiteBalanceCorrection: whiteBalanceCorrection
    )
  }

  private static func rollBaseDensity(from measurements: [FilmBaseMeasurement]) -> BGRChannelValues? {
    guard !measurements.isEmpty else { return nil }
    return BGRChannelValues(
      blue: median(measurements.map(\.baseDensity.blue).sorted()),
      green: median(measurements.map(\.baseDensity.green).sorted()),
      red: median(measurements.map(\.baseDensity.red).sorted())
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case rollID
    case filmStockID
    case captureProfileID
    case measuredBaseDensity
    case measurementCount
    case exposureBias
    case whiteBalanceCorrection
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    rollID = try container.decodeIfPresent(String.self, forKey: .rollID) ?? ""

    if let typedID = try? container.decode(FilmStockProfileID.self, forKey: .filmStockID) {
      filmStockID = typedID
    } else {
      filmStockID = FilmStockProfileID(
        rawValue: try container.decode(String.self, forKey: .filmStockID))
    }
    if let typedID = try? container.decode(CaptureProfileID.self, forKey: .captureProfileID) {
      captureProfileID = typedID
    } else {
      captureProfileID = CaptureProfileID(
        rawValue: try container.decode(String.self, forKey: .captureProfileID))
    }

    measuredBaseDensity = try container.decodeIfPresent(
      BGRChannelValues.self, forKey: .measuredBaseDensity)
    measurementCount = try container.decodeIfPresent(Int.self, forKey: .measurementCount) ?? 0
    exposureBias = try container.decodeIfPresent(Double.self, forKey: .exposureBias) ?? 0
    whiteBalanceCorrection = try container.decodeIfPresent(
      BGRChannelValues.self, forKey: .whiteBalanceCorrection
    ) ?? BGRChannelValues(blue: 1, green: 1, red: 1)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(rollID, forKey: .rollID)
    try container.encode(filmStockID, forKey: .filmStockID)
    try container.encode(captureProfileID, forKey: .captureProfileID)
    try container.encodeIfPresent(measuredBaseDensity, forKey: .measuredBaseDensity)
    try container.encode(measurementCount, forKey: .measurementCount)
    try container.encode(exposureBias, forKey: .exposureBias)
    try container.encode(whiteBalanceCorrection, forKey: .whiteBalanceCorrection)
  }
}

public enum BaseDensitySource: String, Codable, Equatable, Sendable {
  case measuredRoll
  case measuredFrame
  case automaticEstimate
  case stockCaptureDefault
  case manualPicker
}

public struct ResolvedBaseDensity: Codable, Equatable, Sendable {
  public var baseDensity: BGRChannelValues
  public var source: BaseDensitySource

  public init(baseDensity: BGRChannelValues, source: BaseDensitySource) {
    self.baseDensity = baseDensity
    self.source = source
  }
}

public struct AutomaticRebateCandidate: Codable, Equatable, Sendable {
  public var region: ImageRegion
  public var measurement: FilmBaseMeasurement
  public var confidence: Double

  public init(region: ImageRegion, measurement: FilmBaseMeasurement, confidence: Double) {
    self.region = region
    self.measurement = measurement
    self.confidence = confidence
  }
}

public struct GenericC41Profile: Codable, Equatable, Sendable {
  public var densitySlope: BGRChannelValues
  public var densityOffset: BGRChannelValues

  public init(
    densitySlope: BGRChannelValues = BGRChannelValues(blue: 1.0, green: 1.0, red: 1.0),
    densityOffset: BGRChannelValues = BGRChannelValues(blue: 0.0, green: 0.0, red: 0.0)
  ) {
    precondition(
      densitySlope.blue >= 0 && densitySlope.green >= 0 && densitySlope.red >= 0,
      "Density slopes must be nonnegative"
    )
    self.densitySlope = densitySlope
    self.densityOffset = densityOffset
  }

  public static let identity = GenericC41Profile()
}

public enum DisplayToneMap: String, Codable, Equatable, Sendable {
  case linear
  case reinhard
}

public struct DisplayRenderingParameters: Codable, Equatable, Sendable {
  public var exposureEV: Double
  public var whiteBalance: BGRChannelValues
  public var toneMap: DisplayToneMap
  public var maximumSceneGain: Double

  public init(
    exposureEV: Double = 0,
    whiteBalance: BGRChannelValues = BGRChannelValues(blue: 1, green: 1, red: 1),
    toneMap: DisplayToneMap = .linear,
    maximumSceneGain: Double = 16
  ) {
    precondition(exposureEV.isFinite, "Display exposure must be finite")
    precondition(
      whiteBalance.blue.isFinite && whiteBalance.blue >= 0
        && whiteBalance.green.isFinite && whiteBalance.green >= 0
        && whiteBalance.red.isFinite && whiteBalance.red >= 0,
      "Display white-balance gains must be finite and nonnegative"
    )
    precondition(
      maximumSceneGain.isFinite && maximumSceneGain > 0,
      "Maximum scene gain must be finite and positive"
    )
    self.exposureEV = exposureEV
    self.whiteBalance = whiteBalance
    self.toneMap = toneMap
    self.maximumSceneGain = maximumSceneGain
  }
}

public enum FilmNegativeProcessing {
  private static let maxOutput: Double = 65535.0
  public static let calibrationTargetFraction: Double = 1.0 / 24.0
  static let fusedPowerLawParallelPixelThreshold = 1_000_000

  // ── Accelerated UInt16 → linear sRGB LUT ──

  /// Shared UInt16 sRGB-to-linear lookup table. The Rec.2020 matrix is applied
  /// after lookup so off-diagonal terms are not scaled twice.
  private static let sRGBToLinearLUT: [Float] = {
    var lut = [Float](repeating: 0, count: 65536)
    for i in 0...65535 {
      lut[i] = Float(sRGBToLinear(Double(i) / maxOutput))
    }
    return lut
  }()

  // ── Fused power-law inversion (UInt16 → UInt16, single pass) ──

  /// Applies power-law film negative inversion and display encoding in a single
  /// fused pass. Uses a precomputed Float LUT for sRGB-to-linear conversion,
  /// then applies the Rec.2020 matrices and Double `pow` for the per-channel
  /// power-law step to preserve precision.
  ///
  /// This is 2–3× faster than the separate
  /// `powerLawRenderReadyLinear` + `renderPowerLawDisplay` path for the common
  /// case (no additional tone or colour adjustments).
  public static func applyFusedPowerLawInversion(
    image: UInt16Image,
    params: FilmNegativeParams,
    borderPercent: Double = 20.0
  ) -> UInt16Image {
    precondition(image.channels == 3, "Film negative inversion requires 3-channel BGR image")
    guard params.enabled else { return image }

    let redExp = -(params.greenExp * params.redRatio)
    let greenExp = -params.greenExp
    let blueExp = -(params.greenExp * params.blueRatio)
    let inputFloor = 1.0 / maxOutput

    let bMedian = params.measuredMedians?.blue
      ?? image.channelMedian(channel: 0, borderPercent: borderPercent)
    let gMedian = params.measuredMedians?.green
      ?? image.channelMedian(channel: 1, borderPercent: borderPercent)
    let rMedian = params.measuredMedians?.red
      ?? image.channelMedian(channel: 2, borderPercent: borderPercent)

    let multipliers = computeMultipliers(
      medians: BGRChannelValues(blue: bMedian, green: gMedian, red: rMedian),
      params: params
    )

    let pixelCount = image.width * image.height
    var output = [UInt16](repeating: 0, count: pixelCount * 3)

    @Sendable func processPixel(_ i: Int, output: UnsafeMutablePointer<UInt16>) {
      let base = i * 3
      let b = image.pixels[base]
      let g = image.pixels[base + 1]
      let r = image.pixels[base + 2]

      let linearB = Double(sRGBToLinearLUT[Int(b)])
      let linearG = Double(sRGBToLinearLUT[Int(g)])
      let linearR = Double(sRGBToLinearLUT[Int(r)])
      var linB = 0.8955953 * linearB + 0.0880133 * linearG + 0.0163914 * linearR
      var linG = 0.0113623 * linearB + 0.9195404 * linearG + 0.0690973 * linearR
      var linR = 0.0433131 * linearB + 0.3292830 * linearG + 0.6274039 * linearR

      linB = multipliers.b * pow(max(linB, inputFloor), blueExp)
      linG = multipliers.g * pow(max(linG, inputFloor), greenExp)
      linR = multipliers.r * pow(max(linR, inputFloor), redExp)

      let srgbB = 1.1187297 * linB - 0.1005789 * linG - 0.0181508 * linR
      let srgbG = -0.0083494 * linB + 1.1328999 * linG - 0.1245505 * linR
      let srgbR = -0.0728499 * linB - 0.5876411 * linG + 1.6604910 * linR

      output[base] = displayEncodedFilmNegativeValue(srgbB)
      output[base + 1] = displayEncodedFilmNegativeValue(srgbG)
      output[base + 2] = displayEncodedFilmNegativeValue(srgbR)
    }

    let workerCount = min(8, ProcessInfo.processInfo.activeProcessorCount)
    output.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      if pixelCount >= fusedPowerLawParallelPixelThreshold, workerCount > 1 {
        let sendableBuffer = SendableMutableBuffer(baseAddress)
        let pixelsPerWorker = (pixelCount + workerCount - 1) / workerCount
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
          let start = worker * pixelsPerWorker
          let end = min(start + pixelsPerWorker, pixelCount)
          guard start < end else { return }
          for pixelIndex in start..<end {
            processPixel(pixelIndex, output: sendableBuffer.baseAddress)
          }
        }
      } else {
        for pixelIndex in 0..<pixelCount {
          processPixel(pixelIndex, output: baseAddress)
        }
      }
    }

    return UInt16Image(width: image.width, height: image.height, channels: 3, pixels: output)
  }
  /// Near-zero source values become clipped highlights after negative
  /// inversion. Demosaic and black-level subtraction leave real holder masks
  /// slightly above code zero, so neutralize the whole clipped range instead
  /// of preserving a channel-biased fringe.
  public static let sensorBlackThreshold: UInt16 = 1024

  public static func applyPowerLawInversion(
    image: UInt16Image,
    params: FilmNegativeParams,
    borderPercent: Double = 20.0
  ) -> UInt16Image {
    applyFusedPowerLawInversion(image: image, params: params, borderPercent: borderPercent)
  }

  /// Produces the unclamped linear Rec.2020 result. Uses a Float LUT to
  /// eliminate the sRGB→linear pow() calls while keeping Double precision
  /// for the power-law step and matrix arithmetic.
  public static func powerLawRenderReadyLinear(
    image: UInt16Image,
    params: FilmNegativeParams,
    borderPercent: Double = 20.0
  ) -> RenderReadyLinearImage {
    precondition(image.channels == 3, "Film negative inversion requires 3-channel BGR image")

    let redExp = -(params.greenExp * params.redRatio)
    let greenExp = -params.greenExp
    let blueExp = -(params.greenExp * params.blueRatio)
    let inputFloor = 1.0 / maxOutput

    let multipliers: (r: Double, g: Double, b: Double)
    if params.enabled {
      let medians = params.measuredMedians
        ?? computeMedians(image: image, borderPercent: borderPercent)
      multipliers = computeMultipliers(medians: medians, params: params)
    } else {
      multipliers = (r: 1, g: 1, b: 1)
    }

    let pixelCount = image.width * image.height
    let totalComponents = pixelCount * 3
    var output = [Double](repeating: 0, count: totalComponents)

    for i in 0..<pixelCount {
      let base = i * 3
      let b = image.pixels[base]
      let g = image.pixels[base + 1]
      let r = image.pixels[base + 2]

      let linearB = Double(sRGBToLinearLUT[Int(b)])
      let linearG = Double(sRGBToLinearLUT[Int(g)])
      let linearR = Double(sRGBToLinearLUT[Int(r)])
      var linB = 0.8955953 * linearB + 0.0880133 * linearG + 0.0163914 * linearR
      var linG = 0.0113623 * linearB + 0.9195404 * linearG + 0.0690973 * linearR
      var linR = 0.0433131 * linearB + 0.3292830 * linearG + 0.6274039 * linearR

      if params.enabled {
        linB = multipliers.b * pow(max(linB, inputFloor), blueExp)
        linG = multipliers.g * pow(max(linG, inputFloor), greenExp)
        linR = multipliers.r * pow(max(linR, inputFloor), redExp)
      }

      output[base] = linB
      output[base + 1] = linG
      output[base + 2] = linR
    }

    return RenderReadyLinearImage(width: image.width, height: image.height, pixels: output)
  }

  /// Applies the RawTherapee-compatible display encoding and tone curve to an
  /// unclamped power-law result.
  public static func renderPowerLawDisplay(
    _ image: RenderReadyLinearImage
  ) -> UInt16Image {
    let pixelCount = image.pixelCount
    var output = [UInt16](repeating: 0, count: image.pixels.count)
    for pixelIndex in 0..<pixelCount {
      let base = pixelIndex * 3
      let linB = image.pixels[base]
      let linG = image.pixels[base + 1]
      let linR = image.pixels[base + 2]

      let srgbB = 1.1187297 * linB - 0.1005789 * linG - 0.0181508 * linR
      let srgbG = -0.0083494 * linB + 1.1328999 * linG - 0.1245505 * linR
      let srgbR = -0.0728499 * linB - 0.5876411 * linG + 1.6604910 * linR

      output[base] = displayEncodedFilmNegativeValue(srgbB)
      output[base + 1] = displayEncodedFilmNegativeValue(srgbG)
      output[base + 2] = displayEncodedFilmNegativeValue(srgbR)
    }
    return UInt16Image(width: image.width, height: image.height, channels: 3, pixels: output)
  }

  public static func normalizedTransmittance(
    image: UInt16Image,
    flatField: UInt16Image,
    parameters: CaptureNormalizationParameters = CaptureNormalizationParameters()
  ) -> [Double] {
    precondition(image.channels == 3, "Capture normalization requires a 3-channel BGR image")
    precondition(
      image.width == flatField.width
        && image.height == flatField.height
        && image.channels == flatField.channels,
      "Flat field must match the image dimensions and channels"
    )

    var result = [Double](repeating: 0, count: image.pixels.count)
    for index in image.pixels.indices {
      let black = parameters.blackLevel[index % 3]
      let signal = max(Double(image.pixels[index]) - black, 0)
      let clearSignal = max(Double(flatField.pixels[index]) - black, parameters.epsilon)
      result[index] = min(max(signal / clearSignal, parameters.epsilon), 1)
    }
    return result
  }

  public static func opticalDensity(
    transmittance: [Double],
    epsilon: Double = 1e-6
  ) -> [Double] {
    precondition(epsilon > 0 && epsilon <= 1, "Epsilon must be in the range (0, 1]")
    return transmittance.map { -log10(min(max($0, epsilon), 1)) }
  }

  public static func subtractBaseDensity(
    density: [Double],
    baseDensity: BGRChannelValues
  ) -> [Double] {
    precondition(density.count.isMultiple(of: 3), "Density data must contain BGR pixels")
    return density.enumerated().map { index, value in
      max(value - baseDensity[index % 3], 0)
    }
  }

  public static func normalizedImageDensity(
    image: UInt16Image,
    flatField: UInt16Image,
    baseDensity: BGRChannelValues,
    parameters: CaptureNormalizationParameters = CaptureNormalizationParameters()
  ) -> [Double] {
    let transmittance = normalizedTransmittance(
      image: image,
      flatField: flatField,
      parameters: parameters
    )
    let density = opticalDensity(transmittance: transmittance, epsilon: parameters.epsilon)
    return subtractBaseDensity(density: density, baseDensity: baseDensity)
  }

  public static func measureBaseDensity(
    image: UInt16Image,
    flatField: UInt16Image,
    region: ImageRegion,
    parameters: CaptureNormalizationParameters = CaptureNormalizationParameters(),
    trimFraction: Double = 0.1
  ) throws -> FilmBaseMeasurement {
    precondition(image.channels == 3, "Base-density measurement requires a 3-channel BGR image")
    precondition(
      image.width == flatField.width
        && image.height == flatField.height
        && image.channels == flatField.channels,
      "Flat field must match the image dimensions and channels"
    )
    precondition(
      trimFraction >= 0 && trimFraction < 0.5,
      "Trim fraction must be in the range [0, 0.5)"
    )

    guard region.width > 0 && region.height > 0 else {
      throw FilmBaseMeasurementError.emptyRegion
    }
    guard
      region.x >= 0,
      region.y >= 0,
      region.x + region.width <= image.width,
      region.y + region.height <= image.height
    else {
      throw FilmBaseMeasurementError.invalidRegion
    }

    var samples = [[Double](), [Double](), [Double]()]
    samples[0].reserveCapacity(region.width * region.height)
    samples[1].reserveCapacity(region.width * region.height)
    samples[2].reserveCapacity(region.width * region.height)

    for y in region.y..<(region.y + region.height) {
      for x in region.x..<(region.x + region.width) {
        let base = (y * image.width + x) * image.channels
        for channel in 0..<3 {
          let black = parameters.blackLevel[channel]
          let signal = max(Double(image.pixels[base + channel]) - black, 0)
          let clearSignal = max(Double(flatField.pixels[base + channel]) - black, parameters.epsilon)
          let transmittance = min(max(signal / clearSignal, parameters.epsilon), 1)
          samples[channel].append(transmittance)
        }
      }
    }

    guard samples.allSatisfy({ !$0.isEmpty }) else {
      throw FilmBaseMeasurementError.noSamples
    }

    let sorted = samples.map { $0.sorted() }
    let medians = BGRChannelValues(
      blue: median(sorted[0]),
      green: median(sorted[1]),
      red: median(sorted[2])
    )
    let trimmedMeans = BGRChannelValues(
      blue: trimmedMean(sorted[0], trimFraction: trimFraction),
      green: trimmedMean(sorted[1], trimFraction: trimFraction),
      red: trimmedMean(sorted[2], trimFraction: trimFraction)
    )
    let dropCount = Int(Double(sorted[0].count) * trimFraction)
    let rejectedFraction = Double(dropCount * 2) / Double(sorted[0].count)
    let confidence = confidenceScore(
      medians: medians,
      trimmedMeans: trimmedMeans,
      rejectedFraction: rejectedFraction
    )

    return FilmBaseMeasurement(
      baseDensity: BGRChannelValues(
        blue: -log10(medians.blue),
        green: -log10(medians.green),
        red: -log10(medians.red)
      ),
      medianTransmittance: medians,
      trimmedMeanTransmittance: trimmedMeans,
      sampleCount: sorted[0].count,
      rejectedFraction: rejectedFraction,
      confidence: confidence
    )
  }

  public static func resolveBaseDensity(
    rollProfile: RollProfile? = nil,
    frameMeasurement: BGRChannelValues? = nil,
    automaticBaseDensity: BGRChannelValues? = nil,
    defaultBaseDensity: BGRChannelValues? = nil,
    manualBaseDensity: BGRChannelValues? = nil
  ) -> ResolvedBaseDensity? {
    if let rollBase = rollProfile?.measuredBaseDensity {
      return ResolvedBaseDensity(baseDensity: rollBase, source: .measuredRoll)
    }
    if let frameMeasurement {
      return ResolvedBaseDensity(baseDensity: frameMeasurement, source: .measuredFrame)
    }
    if let automaticBaseDensity {
      return ResolvedBaseDensity(baseDensity: automaticBaseDensity, source: .automaticEstimate)
    }
    if let defaultBaseDensity {
      return ResolvedBaseDensity(baseDensity: defaultBaseDensity, source: .stockCaptureDefault)
    }
    if let manualBaseDensity {
      return ResolvedBaseDensity(baseDensity: manualBaseDensity, source: .manualPicker)
    }
    return nil
  }

  public static func automaticRebateCandidates(
    image: UInt16Image,
    flatField: UInt16Image,
    parameters: CaptureNormalizationParameters = CaptureNormalizationParameters(),
    edgeFraction: Double = 0.08,
    minimumConfidence: Double = 0.45
  ) -> [AutomaticRebateCandidate] {
    precondition(image.channels == 3, "Automatic rebate estimation requires a 3-channel BGR image")
    precondition(
      image.width == flatField.width
        && image.height == flatField.height
        && image.channels == flatField.channels,
      "Flat field must match the image dimensions and channels"
    )
    precondition(edgeFraction > 0 && edgeFraction <= 0.25, "Edge fraction must be in the range (0, 0.25]")
    precondition(
      minimumConfidence >= 0 && minimumConfidence <= 1,
      "Minimum confidence must be in the range [0, 1]"
    )

    let stripWidth = max(1, Int((Double(image.width) * edgeFraction).rounded()))
    let stripHeight = max(1, Int((Double(image.height) * edgeFraction).rounded()))
    let regions = [
      ImageRegion(x: 0, y: 0, width: image.width, height: stripHeight),
      ImageRegion(x: 0, y: image.height - stripHeight, width: image.width, height: stripHeight),
      ImageRegion(x: 0, y: 0, width: stripWidth, height: image.height),
      ImageRegion(x: image.width - stripWidth, y: 0, width: stripWidth, height: image.height),
    ]

    let interior = ImageRegion(
      x: stripWidth,
      y: stripHeight,
      width: image.width - stripWidth * 2,
      height: image.height - stripHeight * 2
    )
    guard interior.width > 0 && interior.height > 0 else {
      return []
    }
    let interiorLuminance = regionMedianLuminance(
      image: image,
      flatField: flatField,
      region: interior,
      parameters: parameters
    )

    return regions.compactMap { region in
      guard let measurement = try? measureBaseDensity(
        image: image,
        flatField: flatField,
        region: region,
        parameters: parameters
      ) else {
        return nil
      }
      let edgeLuminance = luminance(measurement.medianTransmittance)
      let separation = max(0, edgeLuminance - interiorLuminance)
      let separationScore = min(separation / 0.12, 1)
      let confidence = measurement.confidence * separationScore
      guard confidence >= minimumConfidence else {
        return nil
      }
      return AutomaticRebateCandidate(
        region: region,
        measurement: measurement,
        confidence: confidence
      )
    }
    .sorted {
      if $0.confidence == $1.confidence {
        return $0.region.y == $1.region.y
          ? $0.region.x < $1.region.x
          : $0.region.y < $1.region.y
      }
      return $0.confidence > $1.confidence
    }
  }

  public static func genericC41SceneEstimate(
    baseSubtractedDensity: [Double],
    profile: GenericC41Profile = .identity
  ) -> [Double] {
    precondition(
      baseSubtractedDensity.count.isMultiple(of: 3),
      "Density data must contain BGR pixels"
    )

    return baseSubtractedDensity.enumerated().map { index, density in
      let channel = index % 3
      let logE = profile.densitySlope[channel] * density + profile.densityOffset[channel]
      return pow(10, logE)
    }
  }

  public static func normalizeSceneExposure(
    sceneLinear: [Double]
  ) -> [Double] {
    precondition(
      sceneLinear.count.isMultiple(of: 3),
      "Scene-linear data must contain BGR pixels"
    )
    guard !sceneLinear.isEmpty else { return sceneLinear }

    let pixelCount = sceneLinear.count / 3
    var greenValues: [Double] = []
    greenValues.reserveCapacity(pixelCount)
    for i in 0..<pixelCount {
      greenValues.append(sceneLinear[i * 3 + 1])
    }
    greenValues.sort()
    let medianGreen = FilmNegativeProcessing.medianOfSorted(greenValues)
    let scale = medianGreen > 0 ? 1.0 / medianGreen : 1.0

    return sceneLinear.map { $0 * scale }
  }

  public static func renderDisplay(
    sceneLinear: [Double],
    parameters: DisplayRenderingParameters = DisplayRenderingParameters()
  ) -> [Double] {
    precondition(
      sceneLinear.count.isMultiple(of: 3),
      "Scene-linear data must contain BGR pixels"
    )

    let exposureGain = exp2(parameters.exposureEV)
    return sceneLinear.enumerated().map { index, value in
      if value.isNaN || value <= 0 { return 0 }
      if value == .infinity { return 1 }

      let requestedGain = exposureGain * parameters.whiteBalance[index % 3]
      let gain = min(requestedGain, parameters.maximumSceneGain)
      let exposed = value * gain
      if !exposed.isFinite { return 1 }

      switch parameters.toneMap {
      case .linear:
        return min(exposed, 1)
      case .reinhard:
        return exposed / (1 + exposed)
      }
    }
  }

  public static func densityToSceneLinear(
    image: UInt16Image,
    flatField: UInt16Image,
    baseDensity: BGRChannelValues,
    c41Profile: GenericC41Profile = .identity,
    parameters: CaptureNormalizationParameters = CaptureNormalizationParameters()
  ) -> [Double] {
    let density = normalizedImageDensity(
      image: image,
      flatField: flatField,
      baseDensity: baseDensity,
      parameters: parameters
    )
    let scene = genericC41SceneEstimate(
      baseSubtractedDensity: density,
      profile: c41Profile
    )
    return normalizeSceneExposure(sceneLinear: scene)
  }

  public static func densityToRenderReadyLinear(
    image: UInt16Image,
    flatField: UInt16Image,
    baseDensity: BGRChannelValues,
    c41Profile: GenericC41Profile = .identity,
    parameters: CaptureNormalizationParameters = CaptureNormalizationParameters()
  ) -> RenderReadyLinearImage {
    RenderReadyLinearImage(
      width: image.width,
      height: image.height,
      pixels: densityToSceneLinear(
        image: image,
        flatField: flatField,
        baseDensity: baseDensity,
        c41Profile: c41Profile,
        parameters: parameters
      )
    )
  }

  fileprivate static func medianOfSorted(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
    return sorted[mid]
  }

  public static func computeMedians(
    image: UInt16Image,
    borderPercent: Double = 20.0
  ) -> BGRChannelValues {
    BGRChannelValues(
      blue: image.channelMedian(channel: 0, borderPercent: borderPercent),
      green: image.channelMedian(channel: 1, borderPercent: borderPercent),
      red: image.channelMedian(channel: 2, borderPercent: borderPercent)
    )
  }

  public static func computeMultipliers(
    medians: BGRChannelValues,
    params: FilmNegativeParams
  ) -> (r: Double, g: Double, b: Double) {
    let rexp = -(params.greenExp * params.redRatio)
    let gexp = -params.greenExp
    let bexp = -(params.greenExp * params.blueRatio)
    let target = calibrationTargetFraction
    let working = linearSRGBToRec2020(
      red: sRGBToLinear(medians.red / maxOutput),
      green: sRGBToLinear(medians.green / maxOutput),
      blue: sRGBToLinear(medians.blue / maxOutput)
    )
    let rInput = max(working.red, 1.0 / maxOutput)
    let gInput = max(working.green, 1.0 / maxOutput)
    let bInput = max(working.blue, 1.0 / maxOutput)
    let r = target / pow(rInput, rexp)
    let g = target / pow(gInput, gexp)
    let b = target / pow(bInput, bexp)
    return (r, g, b)
  }

  public static func sRGBToLinear(_ value: Double) -> Double {
    let clamped = min(max(value, 0), 1)
    if clamped <= 0.04045 {
      return clamped / 12.92
    }
    return pow((clamped + 0.055) / 1.055, 2.4)
  }

  public static func linearToSRGB(_ value: Double) -> Double {
    let clamped = min(max(value, 0), 1)
    if clamped <= 0.0031308 {
      return clamped * 12.92
    }
    return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
  }

  public static func linearSRGBToRec2020(
    red: Double, green: Double, blue: Double
  ) -> (red: Double, green: Double, blue: Double) {
    (
      0.6274039 * red + 0.3292830 * green + 0.0433131 * blue,
      0.0690973 * red + 0.9195404 * green + 0.0113623 * blue,
      0.0163914 * red + 0.0880133 * green + 0.8955953 * blue
    )
  }

  public static func linearRec2020ToSRGB(
    red: Double, green: Double, blue: Double
  ) -> (red: Double, green: Double, blue: Double) {
    (
      1.6604910 * red - 0.5876411 * green - 0.0728499 * blue,
      -0.1245505 * red + 1.1328999 * green - 0.0083494 * blue,
      -0.0181508 * red - 0.1005789 * green + 1.1187297 * blue
    )
  }

  public static func rawTherapeeFilmNegativeToneCurve(_ value: Double) -> Double {
    let first = piecewiseLinear(
      value,
      points: [(0, 0), (0.8854460194005137, 1)]
    )
    let x = [0.0, 0.0397505754145333, 0.5466974543314932, 1.0]
    let y = [0.0, 0.020171771436200074, 0.6941997473367765, 1.0]
    let ypp = [0.0, 6.2215877061143505, -3.688563301251906, 0.0]
    let interval: Int
    if first <= x[1] {
      interval = 0
    } else if first <= x[2] {
      interval = 1
    } else {
      interval = 2
    }
    let h = x[interval + 1] - x[interval]
    let a = (x[interval + 1] - first) / h
    let b = (first - x[interval]) / h
    let result = a * y[interval] + b * y[interval + 1]
      + ((a * a * a - a) * ypp[interval]
        + (b * b * b - b) * ypp[interval + 1]) * h * h / 6.0
    return min(max(result, 0), 1)
  }

  private static func displayEncodedFilmNegativeValue(_ linear: Double) -> UInt16 {
    let encoded = linearToSRGB(linear)
    let curved = rawTherapeeFilmNegativeToneCurve(encoded)
    return UInt16(min(max(curved * maxOutput, 0), maxOutput))
  }

  private static func piecewiseLinear(
    _ value: Double,
    points: [(Double, Double)]
  ) -> Double {
    let x = min(max(value, 0), 1)
    for index in 0..<(points.count - 1) {
      let lower = points[index]
      let upper = points[index + 1]
      if x <= upper.0 {
        let width = upper.0 - lower.0
        let t = width > 0 ? (x - lower.0) / width : 0
        return lower.1 + t * (upper.1 - lower.1)
      }
    }
    return points.last?.1 ?? x
  }

  public static func classifyFilmScan(
    image: UInt16Image,
    borderPercent: Double = 20.0,
    maxSamples: Int = 4_096,
    weakPrior: FilmType? = nil
  ) -> FilmClassification {
    guard image.channels == 3 else {
      return FilmClassification(
        filmType: .cropOnly,
        filmNegativePreset: .off,
        confidence: 0
      )
    }

    let medians = computeMedians(image: image, borderPercent: borderPercent)
    let r = max(medians.red, 1)
    let g = max(medians.green, 1)
    let b = max(medians.blue, 1)
    let orangeOrderScore =
      channelDominanceScore(ratio: r / g, threshold: 1.05, span: 0.30) * 0.55
      + channelDominanceScore(ratio: g / b, threshold: 1.05, span: 0.30) * 0.45
    let redBlueSeparation = channelDominanceScore(ratio: r / b, threshold: 1.20, span: 0.80)
    let orangeMaskScore = min(max(orangeOrderScore * 0.65 + redBlueSeparation * 0.35, 0), 1)

    let chroma = sampledChroma(image: image, maxSamples: maxSamples)
    let classification: FilmClassification
    if chroma.mean < 0.045 && chroma.median < 0.055 {
      let confidence = min(max(1.0 - chroma.mean / 0.045, 0), 1)
      classification = FilmClassification(
        filmType: .blackAndWhiteNegative,
        filmNegativePreset: .blackAndWhite,
        confidence: max(confidence, 0.75)
      )
    } else if orangeMaskScore >= 0.45 {
      classification = FilmClassification(
        filmType: .colourNegative,
        filmNegativePreset: .colourNegative,
        confidence: orangeMaskScore
      )
    } else {
      classification = FilmClassification(
        filmType: .slide,
        filmNegativePreset: .off,
        confidence: max(0.55, 1.0 - orangeMaskScore)
      )
    }

    // A user-confirmed roll identity is deliberately weaker than confident
    // per-image evidence. It only resolves the classifier's narrow uncertain
    // band and never turns crop-only mode into an automatic film identity.
    guard classification.confidence < 0.65, let weakPrior else {
      return classification
    }
    switch weakPrior {
    case .blackAndWhiteNegative:
      return FilmClassification(
        filmType: .blackAndWhiteNegative,
        filmNegativePreset: .blackAndWhite,
        confidence: classification.confidence
      )
    case .colourNegative:
      return FilmClassification(
        filmType: .colourNegative,
        filmNegativePreset: .colourNegative,
        confidence: classification.confidence
      )
    case .slide:
      return FilmClassification(
        filmType: .slide,
        filmNegativePreset: .off,
        confidence: classification.confidence
      )
    case .cropOnly:
      return classification
    }
  }
}

private func channelDominanceScore(ratio: Double, threshold: Double, span: Double) -> Double {
  min(max((ratio - threshold) / span, 0), 1)
}

private func sampledChroma(image: UInt16Image, maxSamples: Int) -> (mean: Double, median: Double) {
  let pixelCount = image.width * image.height
  let step = max(1, pixelCount / max(1, maxSamples))
  var values: [Double] = []
  values.reserveCapacity(min(pixelCount, maxSamples))

  var index = 0
  while index < pixelCount {
    let base = index * 3
    let blue = Double(image.pixels[base])
    let green = Double(image.pixels[base + 1])
    let red = Double(image.pixels[base + 2])
    let maximum = max(blue, green, red, 1)
    let minimum = min(blue, green, red)
    values.append((maximum - minimum) / maximum)
    index += step
  }

  guard !values.isEmpty else { return (0, 0) }
  let mean = values.reduce(0, +) / Double(values.count)
  values.sort()
  return (mean, median(values))
}

private func median(_ sortedValues: [Double]) -> Double {
  guard !sortedValues.isEmpty else { return 0 }
  let mid = sortedValues.count / 2
  if sortedValues.count.isMultiple(of: 2) {
    return (sortedValues[mid - 1] + sortedValues[mid]) / 2.0
  }
  return sortedValues[mid]
}

private func trimmedMean(_ sortedValues: [Double], trimFraction: Double) -> Double {
  guard !sortedValues.isEmpty else { return 0 }
  let trimCount = Int(Double(sortedValues.count) * trimFraction)
  let start = min(trimCount, sortedValues.count - 1)
  let end = max(start + 1, sortedValues.count - trimCount)
  let kept = sortedValues[start..<end]
  return kept.reduce(0, +) / Double(kept.count)
}

private func confidenceScore(
  medians: BGRChannelValues,
  trimmedMeans: BGRChannelValues,
  rejectedFraction: Double
) -> Double {
  let channelPenalties = [
    relativeDifference(medians.blue, trimmedMeans.blue),
    relativeDifference(medians.green, trimmedMeans.green),
    relativeDifference(medians.red, trimmedMeans.red),
  ]
  let penalty = min(1, channelPenalties.max() ?? 0)
  return min(max(1 - penalty - rejectedFraction * 0.25, 0), 1)
}

private func regionMedianLuminance(
  image: UInt16Image,
  flatField: UInt16Image,
  region: ImageRegion,
  parameters: CaptureNormalizationParameters
) -> Double {
  guard let measurement = try? FilmNegativeProcessing.measureBaseDensity(
    image: image,
    flatField: flatField,
    region: region,
    parameters: parameters
  ) else {
    return 0
  }
  return luminance(measurement.medianTransmittance)
}

private func luminance(_ values: BGRChannelValues) -> Double {
  values.red * 0.2126 + values.green * 0.7152 + values.blue * 0.0722
}

private func relativeDifference(_ a: Double, _ b: Double) -> Double {
  let denominator = max(abs(a), abs(b), 1e-12)
  return abs(a - b) / denominator
}

extension UInt16Image {
  fileprivate func channelMedian(channel: Int, borderPercent: Double) -> Double {
    let bW = Int(Double(width) * borderPercent / 100.0)
    let bH = Int(Double(height) * borderPercent / 100.0)
    let x1 = bW
    let y1 = bH
    let x2 = width - bW
    let y2 = height - bH

    guard x2 > x1, y2 > y1 else {
      return 0
    }

    var values = [UInt16]()
    values.reserveCapacity((x2 - x1) * (y2 - y1))
    for y in y1..<y2 {
      for x in x1..<x2 {
        values.append(pixels[(y * width + x) * channels + channel])
      }
    }
    values.sort()
    guard !values.isEmpty else { return 0 }
    let mid = values.count / 2
    if values.count.isMultiple(of: 2) {
      return (Double(values[mid - 1]) + Double(values[mid])) / 2.0
    }
    return Double(values[mid])
  }
}
