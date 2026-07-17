import Foundation

public enum DensityCalibrationPartition: String, Codable, Equatable, Sendable {
  case fit
  case validation
}

public struct DensityCalibrationSample: Codable, Equatable, Sendable {
  public var sourceFrameID: String
  public var measuredDensity: BGRChannelValues
  public var targetLogExposure: BGRChannelValues
  public var weight: Double
  public var partition: DensityCalibrationPartition

  public init(
    sourceFrameID: String,
    measuredDensity: BGRChannelValues,
    targetLogExposure: BGRChannelValues,
    weight: Double = 1,
    partition: DensityCalibrationPartition
  ) {
    self.sourceFrameID = sourceFrameID
    self.measuredDensity = measuredDensity
    self.targetLogExposure = targetLogExposure
    self.weight = weight
    self.partition = partition
  }
}

public struct DensityCalibrationMetrics: Codable, Equatable, Sendable {
  public var sampleCount: Int
  public var weightedRMSE: Double
  public var channelRMSE: BGRChannelValues

  public init(
    sampleCount: Int,
    weightedRMSE: Double,
    channelRMSE: BGRChannelValues
  ) {
    self.sampleCount = sampleCount
    self.weightedRMSE = weightedRMSE
    self.channelRMSE = channelRMSE
  }
}

public struct DensityMatrixCalibrationReport: Codable, Equatable, Sendable {
  public var correction: DensityCorrectionMatrix
  public var fitMetrics: DensityCalibrationMetrics
  public var validationMetrics: DensityCalibrationMetrics
  public var validationBaselineMetrics: DensityCalibrationMetrics
  public var relativeValidationImprovement: Double
  public var minimumValidationImprovement: Double
  public var passesHeldOutGate: Bool

  public init(
    correction: DensityCorrectionMatrix,
    fitMetrics: DensityCalibrationMetrics,
    validationMetrics: DensityCalibrationMetrics,
    validationBaselineMetrics: DensityCalibrationMetrics,
    relativeValidationImprovement: Double,
    minimumValidationImprovement: Double,
    passesHeldOutGate: Bool
  ) {
    self.correction = correction
    self.fitMetrics = fitMetrics
    self.validationMetrics = validationMetrics
    self.validationBaselineMetrics = validationBaselineMetrics
    self.relativeValidationImprovement = relativeValidationImprovement
    self.minimumValidationImprovement = minimumValidationImprovement
    self.passesHeldOutGate = passesHeldOutGate
  }
}

public struct DensityMatrixCalibrationDocument: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var captureProfile: CaptureProfile
  public var stockProfile: FilmStockProfile
  public var samples: [DensityCalibrationSample]
  public var regularization: Double
  public var minimumValidationImprovement: Double

  public init(
    schemaVersion: Int = currentSchemaVersion,
    captureProfile: CaptureProfile,
    stockProfile: FilmStockProfile,
    samples: [DensityCalibrationSample],
    regularization: Double = 0.001,
    minimumValidationImprovement: Double = 0.01
  ) {
    self.schemaVersion = schemaVersion
    self.captureProfile = captureProfile
    self.stockProfile = stockProfile
    self.samples = samples
    self.regularization = regularization
    self.minimumValidationImprovement = minimumValidationImprovement
  }
}

public struct DensityMatrixCalibrationOutput: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var candidateCaptureProfile: CaptureProfile
  public var calibrationStockProfileID: FilmStockProfileID
  public var report: DensityMatrixCalibrationReport

  public init(
    schemaVersion: Int = currentSchemaVersion,
    candidateCaptureProfile: CaptureProfile,
    calibrationStockProfileID: FilmStockProfileID,
    report: DensityMatrixCalibrationReport
  ) {
    self.schemaVersion = schemaVersion
    self.candidateCaptureProfile = candidateCaptureProfile
    self.calibrationStockProfileID = calibrationStockProfileID
    self.report = report
  }
}

public enum DensityMatrixCalibrationError: Error, Equatable, Sendable {
  case insufficientFitSamples(Int)
  case missingValidationSamples
  case frameAppearsInBothPartitions(String)
  case invalidSample(Int)
  case invalidRegularization
  case invalidMinimumValidationImprovement
  case nonPositiveDensitySlope
  case singularFit
}

public enum DensityMatrixCalibrator {
  public static func fit(
    samples: [DensityCalibrationSample],
    c41Profile: GenericC41Profile,
    regularization: Double = 0.001,
    minimumValidationImprovement: Double = 0.01
  ) throws -> DensityMatrixCalibrationReport {
    guard regularization.isFinite, regularization >= 0 else {
      throw DensityMatrixCalibrationError.invalidRegularization
    }
    guard minimumValidationImprovement.isFinite,
      minimumValidationImprovement >= 0,
      minimumValidationImprovement <= 1
    else {
      throw DensityMatrixCalibrationError.invalidMinimumValidationImprovement
    }
    guard c41Profile.densitySlope.blue.isFinite,
      c41Profile.densitySlope.green.isFinite,
      c41Profile.densitySlope.red.isFinite,
      c41Profile.densitySlope.blue > 0,
      c41Profile.densitySlope.green > 0,
      c41Profile.densitySlope.red > 0
    else {
      throw DensityMatrixCalibrationError.nonPositiveDensitySlope
    }

    for (index, sample) in samples.enumerated() {
      guard !sample.sourceFrameID.isEmpty,
        sample.weight.isFinite,
        sample.weight > 0,
        isFinite(sample.measuredDensity),
        isFinite(sample.targetLogExposure)
      else {
        throw DensityMatrixCalibrationError.invalidSample(index)
      }
    }

    let fitSamples = samples.filter { $0.partition == .fit }
    let validationSamples = samples.filter { $0.partition == .validation }
    guard fitSamples.count >= 4 else {
      throw DensityMatrixCalibrationError.insufficientFitSamples(fitSamples.count)
    }
    guard !validationSamples.isEmpty else {
      throw DensityMatrixCalibrationError.missingValidationSamples
    }

    let fitFrameIDs = Set(fitSamples.map(\.sourceFrameID))
    let validationFrameIDs = Set(validationSamples.map(\.sourceFrameID))
    if let leakedFrame = fitFrameIDs.intersection(validationFrameIDs).sorted().first {
      throw DensityMatrixCalibrationError.frameAppearsInBothPartitions(leakedFrame)
    }

    let blue = try fitRow(
      samples: fitSamples,
      targetChannel: { sample in
        (sample.targetLogExposure.blue - c41Profile.densityOffset.blue)
          / c41Profile.densitySlope.blue
      },
      identityIndex: 0,
      regularization: regularization
    )
    let green = try fitRow(
      samples: fitSamples,
      targetChannel: { sample in
        (sample.targetLogExposure.green - c41Profile.densityOffset.green)
          / c41Profile.densitySlope.green
      },
      identityIndex: 1,
      regularization: regularization
    )
    let red = try fitRow(
      samples: fitSamples,
      targetChannel: { sample in
        (sample.targetLogExposure.red - c41Profile.densityOffset.red)
          / c41Profile.densitySlope.red
      },
      identityIndex: 2,
      regularization: regularization
    )

    let correction = DensityCorrectionMatrix(
      blueOutput: BGRChannelValues(blue: blue[0], green: blue[1], red: blue[2]),
      greenOutput: BGRChannelValues(blue: green[0], green: green[1], red: green[2]),
      redOutput: BGRChannelValues(blue: red[0], green: red[1], red: red[2]),
      offset: BGRChannelValues(blue: blue[3], green: green[3], red: red[3])
    )
    guard correction.isFinite else {
      throw DensityMatrixCalibrationError.singularFit
    }

    let fitMetrics = metrics(
      samples: fitSamples,
      correction: correction,
      c41Profile: c41Profile
    )
    let validationMetrics = metrics(
      samples: validationSamples,
      correction: correction,
      c41Profile: c41Profile
    )
    let baselineMetrics = metrics(
      samples: validationSamples,
      correction: .identity,
      c41Profile: c41Profile
    )
    let relativeImprovement: Double
    if baselineMetrics.weightedRMSE > 0 {
      relativeImprovement =
        (baselineMetrics.weightedRMSE - validationMetrics.weightedRMSE)
        / baselineMetrics.weightedRMSE
    } else {
      relativeImprovement = validationMetrics.weightedRMSE == 0 ? 0 : -1
    }
    let passesGate = validationMetrics.weightedRMSE < baselineMetrics.weightedRMSE
      && relativeImprovement >= minimumValidationImprovement

    return DensityMatrixCalibrationReport(
      correction: correction,
      fitMetrics: fitMetrics,
      validationMetrics: validationMetrics,
      validationBaselineMetrics: baselineMetrics,
      relativeValidationImprovement: relativeImprovement,
      minimumValidationImprovement: minimumValidationImprovement,
      passesHeldOutGate: passesGate
    )
  }

  public static func calibrate(
    document: DensityMatrixCalibrationDocument
  ) throws -> DensityMatrixCalibrationOutput {
    let report = try fit(
      samples: document.samples,
      c41Profile: document.stockProfile.c41Profile,
      regularization: document.regularization,
      minimumValidationImprovement: document.minimumValidationImprovement
    )
    var captureProfile = document.captureProfile
    captureProfile.schemaVersion = CaptureProfile.currentSchemaVersion
    captureProfile.densityCorrection = report.correction
    return DensityMatrixCalibrationOutput(
      candidateCaptureProfile: captureProfile,
      calibrationStockProfileID: document.stockProfile.id,
      report: report
    )
  }

  private static func fitRow(
    samples: [DensityCalibrationSample],
    targetChannel: (DensityCalibrationSample) -> Double,
    identityIndex: Int,
    regularization: Double
  ) throws -> [Double] {
    var normal = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
    var rhs = Array(repeating: 0.0, count: 4)

    for sample in samples {
      let x = [
        sample.measuredDensity.blue,
        sample.measuredDensity.green,
        sample.measuredDensity.red,
        1.0,
      ]
      let y = targetChannel(sample)
      for row in 0..<4 {
        rhs[row] += sample.weight * x[row] * y
        for column in 0..<4 {
          normal[row][column] += sample.weight * x[row] * x[column]
        }
      }
    }

    for index in 0..<4 {
      normal[index][index] += regularization
    }
    rhs[identityIndex] += regularization

    guard let solution = solve(normal, rhs) else {
      throw DensityMatrixCalibrationError.singularFit
    }
    return solution
  }

  private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
    var augmented = zip(matrix, vector).map { row, value in row + [value] }
    for pivot in 0..<4 {
      var bestRow = pivot
      for row in (pivot + 1)..<4
      where abs(augmented[row][pivot]) > abs(augmented[bestRow][pivot]) {
        bestRow = row
      }
      guard abs(augmented[bestRow][pivot]) > 1e-14 else { return nil }
      if bestRow != pivot {
        augmented.swapAt(bestRow, pivot)
      }

      let divisor = augmented[pivot][pivot]
      for column in pivot..<5 {
        augmented[pivot][column] /= divisor
      }
      for row in 0..<4 where row != pivot {
        let factor = augmented[row][pivot]
        for column in pivot..<5 {
          augmented[row][column] -= factor * augmented[pivot][column]
        }
      }
    }
    return augmented.map { $0[4] }
  }

  private static func metrics(
    samples: [DensityCalibrationSample],
    correction: DensityCorrectionMatrix,
    c41Profile: GenericC41Profile
  ) -> DensityCalibrationMetrics {
    var blueSquaredError = 0.0
    var greenSquaredError = 0.0
    var redSquaredError = 0.0
    var weightSum = 0.0

    for sample in samples {
      let corrected = correction.applying(to: sample.measuredDensity)
      let predicted = BGRChannelValues(
        blue: c41Profile.densitySlope.blue * corrected.blue + c41Profile.densityOffset.blue,
        green: c41Profile.densitySlope.green * corrected.green + c41Profile.densityOffset.green,
        red: c41Profile.densitySlope.red * corrected.red + c41Profile.densityOffset.red
      )
      blueSquaredError += sample.weight
        * squared(predicted.blue - sample.targetLogExposure.blue)
      greenSquaredError += sample.weight
        * squared(predicted.green - sample.targetLogExposure.green)
      redSquaredError += sample.weight
        * squared(predicted.red - sample.targetLogExposure.red)
      weightSum += sample.weight
    }

    let blueRMSE = sqrt(blueSquaredError / weightSum)
    let greenRMSE = sqrt(greenSquaredError / weightSum)
    let redRMSE = sqrt(redSquaredError / weightSum)
    return DensityCalibrationMetrics(
      sampleCount: samples.count,
      weightedRMSE: sqrt(
        (blueSquaredError + greenSquaredError + redSquaredError) / (3 * weightSum)
      ),
      channelRMSE: BGRChannelValues(blue: blueRMSE, green: greenRMSE, red: redRMSE)
    )
  }

  private static func isFinite(_ value: BGRChannelValues) -> Bool {
    value.blue.isFinite && value.green.isFinite && value.red.isFinite
  }

  private static func squared(_ value: Double) -> Double { value * value }
}
