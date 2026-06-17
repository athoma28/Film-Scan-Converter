import Foundation

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
  public var schemaVersion: Int
  public var filmStockID: String
  public var captureProfileID: String
  public var measuredBaseDensity: BGRChannelValues?
  public var measurementCount: Int
  public var exposureBias: Double
  public var whiteBalanceCorrection: BGRChannelValues

  public init(
    schemaVersion: Int = 1,
    filmStockID: String,
    captureProfileID: String,
    measuredBaseDensity: BGRChannelValues? = nil,
    measurementCount: Int = 0,
    exposureBias: Double = 0,
    whiteBalanceCorrection: BGRChannelValues = BGRChannelValues(blue: 1, green: 1, red: 1)
  ) {
    self.schemaVersion = schemaVersion
    self.filmStockID = filmStockID
    self.captureProfileID = captureProfileID
    self.measuredBaseDensity = measuredBaseDensity
    self.measurementCount = measurementCount
    self.exposureBias = exposureBias
    self.whiteBalanceCorrection = whiteBalanceCorrection
  }

  public init(
    schemaVersion: Int = 1,
    filmStockID: String,
    captureProfileID: String,
    measurements: [FilmBaseMeasurement],
    exposureBias: Double = 0,
    whiteBalanceCorrection: BGRChannelValues = BGRChannelValues(blue: 1, green: 1, red: 1)
  ) {
    self.init(
      schemaVersion: schemaVersion,
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

public enum FilmNegativeProcessing {
  private static let maxOutput: Double = 65535.0
  public static let calibrationTargetFraction: Double = 0.5

  public static func applyPowerLawInversion(
    image: UInt16Image,
    params: FilmNegativeParams,
    borderPercent: Double = 20.0
  ) -> UInt16Image {
    precondition(image.channels == 3, "Film negative inversion requires 3-channel BGR image")
    guard params.enabled else {
      return image
    }

    let rexp = -(params.greenExp * params.redRatio)
    let gexp = -params.greenExp
    let bexp = -(params.greenExp * params.blueRatio)

    let bMedian: Double
    let gMedian: Double
    let rMedian: Double
    if let cached = params.measuredMedians {
      bMedian = Double(cached.blue)
      gMedian = Double(cached.green)
      rMedian = Double(cached.red)
    } else {
      bMedian = image.channelMedian(channel: 0, borderPercent: borderPercent)
      gMedian = image.channelMedian(channel: 1, borderPercent: borderPercent)
      rMedian = image.channelMedian(channel: 2, borderPercent: borderPercent)
    }

    let refInputB = max(bMedian, 1.0)
    let refInputG = max(gMedian, 1.0)
    let refInputR = max(rMedian, 1.0)

    let refOutput = maxOutput * calibrationTargetFraction

    let bMult = refOutput / pow(refInputB, bexp)
    let gMult = refOutput / pow(refInputG, gexp)
    let rMult = refOutput / pow(refInputR, rexp)

    var out = [UInt16](repeating: 0, count: image.pixels.count)
    let count = image.width * image.height
    for i in 0..<count {
      let base = i * 3
      let b = Double(image.pixels[base])
      let g = Double(image.pixels[base + 1])
      let r = Double(image.pixels[base + 2])

      out[base] = UInt16(min(max(bMult * pow(b, bexp), 0), maxOutput))
      out[base + 1] = UInt16(min(max(gMult * pow(g, gexp), 0), maxOutput))
      out[base + 2] = UInt16(min(max(rMult * pow(r, rexp), 0), maxOutput))
    }

    return UInt16Image(width: image.width, height: image.height, channels: 3, pixels: out)
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
    let target = maxOutput * calibrationTargetFraction
    let r = target / pow(max(medians.red, 1.0), rexp)
    let g = target / pow(max(medians.green, 1.0), gexp)
    let b = target / pow(max(medians.blue, 1.0), bexp)
    return (r, g, b)
  }

  public static func classifyFilmScan(
    image: UInt16Image,
    borderPercent: Double = 20.0,
    maxSamples: Int = 4_096
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
    if chroma.mean < 0.045 && chroma.median < 0.055 {
      let confidence = min(max(1.0 - chroma.mean / 0.045, 0), 1)
      return FilmClassification(
        filmType: .blackAndWhiteNegative,
        filmNegativePreset: .blackAndWhite,
        confidence: max(confidence, 0.75)
      )
    }

    if orangeMaskScore >= 0.45 {
      return FilmClassification(
        filmType: .colourNegative,
        filmNegativePreset: .colourNegative,
        confidence: orangeMaskScore
      )
    }

    return FilmClassification(
      filmType: .slide,
      filmNegativePreset: .off,
      confidence: max(0.55, 1.0 - orangeMaskScore)
    )
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
