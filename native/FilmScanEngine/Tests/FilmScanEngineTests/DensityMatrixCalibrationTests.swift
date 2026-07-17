import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Density-matrix calibration")
struct DensityMatrixCalibrationTests {
  @Test("Density correction uses explicit BGR rows and offset")
  func densityCorrectionBGRApplication() {
    let correction = DensityCorrectionMatrix(
      blueOutput: BGRChannelValues(blue: 2, green: 3, red: 5),
      greenOutput: BGRChannelValues(blue: 7, green: 11, red: 13),
      redOutput: BGRChannelValues(blue: 17, green: 19, red: 23),
      offset: BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3)
    )

    let corrected = correction.applying(
      to: BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3)
    )

    #expect(abs(corrected.blue - 2.4) < 1e-12)
    #expect(abs(corrected.green - 7.0) < 1e-12)
    #expect(abs(corrected.red - 12.7) < 1e-12)
  }

  @Test("Fitter recovers a known affine correction and improves held-out error")
  func recoversKnownCorrection() throws {
    let expected = DensityCorrectionMatrix(
      blueOutput: BGRChannelValues(blue: 1.08, green: -0.06, red: 0.03),
      greenOutput: BGRChannelValues(blue: 0.04, green: 0.95, red: 0.07),
      redOutput: BGRChannelValues(blue: -0.03, green: 0.08, red: 1.04),
      offset: BGRChannelValues(blue: 0.015, green: -0.01, red: 0.02)
    )
    let c41 = GenericC41Profile(
      densitySlope: BGRChannelValues(blue: 1.2, green: 0.9, red: 1.1),
      densityOffset: BGRChannelValues(blue: -0.03, green: 0.02, red: 0.01)
    )
    let inputs = [
      BGRChannelValues(blue: 0.05, green: 0.12, red: 0.24),
      BGRChannelValues(blue: 0.18, green: 0.04, red: 0.31),
      BGRChannelValues(blue: 0.29, green: 0.27, red: 0.06),
      BGRChannelValues(blue: 0.42, green: 0.11, red: 0.17),
      BGRChannelValues(blue: 0.14, green: 0.39, red: 0.28),
      BGRChannelValues(blue: 0.34, green: 0.22, red: 0.46),
      BGRChannelValues(blue: 0.08, green: 0.31, red: 0.13),
      BGRChannelValues(blue: 0.37, green: 0.08, red: 0.35),
      BGRChannelValues(blue: 0.23, green: 0.44, red: 0.19),
      BGRChannelValues(blue: 0.48, green: 0.36, red: 0.09),
    ]
    let samples = inputs.enumerated().map { index, input in
      let corrected = expected.applying(to: input)
      let target = BGRChannelValues(
        blue: c41.densitySlope.blue * corrected.blue + c41.densityOffset.blue,
        green: c41.densitySlope.green * corrected.green + c41.densityOffset.green,
        red: c41.densitySlope.red * corrected.red + c41.densityOffset.red
      )
      return DensityCalibrationSample(
        sourceFrameID: "frame-\(index)",
        measuredDensity: input,
        targetLogExposure: target,
        weight: index.isMultiple(of: 2) ? 2 : 1,
        partition: index < 7 ? .fit : .validation
      )
    }

    let report = try DensityMatrixCalibrator.fit(
      samples: samples,
      c41Profile: c41,
      regularization: 1e-10,
      minimumValidationImprovement: 0.01
    )

    assertMatrixEqual(report.correction, expected, tolerance: 1e-7)
    #expect(report.fitMetrics.sampleCount == 7)
    #expect(report.validationMetrics.sampleCount == 3)
    #expect(report.validationMetrics.weightedRMSE < 1e-8)
    #expect(report.validationBaselineMetrics.weightedRMSE > 0.01)
    #expect(report.relativeValidationImprovement > 0.99)
    #expect(report.passesHeldOutGate)
  }

  @Test("Frame-level leakage between fit and validation is rejected")
  func rejectsFrameLeakage() {
    let samples = calibrationSamples()
      + [
        DensityCalibrationSample(
          sourceFrameID: "fit-0",
          measuredDensity: BGRChannelValues(blue: 0.2, green: 0.3, red: 0.4),
          targetLogExposure: BGRChannelValues(blue: 0.2, green: 0.3, red: 0.4),
          partition: .validation
        )
      ]

    #expect(throws: DensityMatrixCalibrationError.frameAppearsInBothPartitions("fit-0")) {
      try DensityMatrixCalibrator.fit(samples: samples, c41Profile: .identity)
    }
  }

  @Test("A validation partition is required")
  func requiresHeldOutSamples() {
    let samples: [DensityCalibrationSample] = [
      makeFitSample(index: 0, measuredDensity: BGRChannelValues(blue: 0, green: 0, red: 0)),
      makeFitSample(index: 1, measuredDensity: BGRChannelValues(blue: 1, green: 0, red: 0)),
      makeFitSample(index: 2, measuredDensity: BGRChannelValues(blue: 0, green: 1, red: 0)),
      makeFitSample(index: 3, measuredDensity: BGRChannelValues(blue: 0, green: 0, red: 1)),
    ]

    #expect(throws: DensityMatrixCalibrationError.missingValidationSamples) {
      try DensityMatrixCalibrator.fit(samples: samples, c41Profile: .identity)
    }
  }

  @Test("Calibration document and report round-trip through JSON")
  func calibrationDocumentsRoundTrip() throws {
    let document = DensityMatrixCalibrationDocument(
      captureProfile: CaptureProfile(
        id: CaptureProfileID(rawValue: "x-t5-cslite"),
        cameraModel: "Fujifilm X-T5",
        backlightDescription: "CS-Lite"
      ),
      stockProfile: FilmStockProfile.genericColorNegative,
      samples: calibrationSamples(),
      regularization: 0.001,
      minimumValidationImprovement: 0.02
    )

    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(DensityMatrixCalibrationDocument.self, from: data)

    #expect(decoded == document)
  }

  @Test("An already-perfect identity baseline does not pass the improvement gate")
  func identityBaselineDoesNotPass() throws {
    let report = try DensityMatrixCalibrator.fit(
      samples: calibrationSamples(),
      c41Profile: .identity
    )

    #expect(!report.passesHeldOutGate)
    #expect(report.relativeValidationImprovement.isFinite)
    _ = try JSONEncoder().encode(report)
  }

  private func calibrationSamples() -> [DensityCalibrationSample] {
    let fitInputs = [
      BGRChannelValues(blue: 0, green: 0, red: 0),
      BGRChannelValues(blue: 1, green: 0, red: 0),
      BGRChannelValues(blue: 0, green: 1, red: 0),
      BGRChannelValues(blue: 0, green: 0, red: 1),
    ]
    let fit = fitInputs.enumerated().map { index, input in
      DensityCalibrationSample(
        sourceFrameID: "fit-\(index)",
        measuredDensity: input,
        targetLogExposure: input,
        partition: .fit
      )
    }
    return fit + [
      DensityCalibrationSample(
        sourceFrameID: "validation-0",
        measuredDensity: BGRChannelValues(blue: 0.2, green: 0.3, red: 0.4),
        targetLogExposure: BGRChannelValues(blue: 0.2, green: 0.3, red: 0.4),
        partition: .validation
      )
    ]
  }

  private func makeFitSample(
    index: Int,
    measuredDensity: BGRChannelValues
  ) -> DensityCalibrationSample {
    DensityCalibrationSample(
      sourceFrameID: "fit-\(index)",
      measuredDensity: measuredDensity,
      targetLogExposure: BGRChannelValues(blue: 0.1, green: 0.2, red: 0.3),
      partition: .fit
    )
  }

  private func assertMatrixEqual(
    _ actual: DensityCorrectionMatrix,
    _ expected: DensityCorrectionMatrix,
    tolerance: Double
  ) {
    let actualValues = [
      actual.blueOutput.blue, actual.blueOutput.green, actual.blueOutput.red,
      actual.greenOutput.blue, actual.greenOutput.green, actual.greenOutput.red,
      actual.redOutput.blue, actual.redOutput.green, actual.redOutput.red,
      actual.offset.blue, actual.offset.green, actual.offset.red,
    ]
    let expectedValues = [
      expected.blueOutput.blue, expected.blueOutput.green, expected.blueOutput.red,
      expected.greenOutput.blue, expected.greenOutput.green, expected.greenOutput.red,
      expected.redOutput.blue, expected.redOutput.green, expected.redOutput.red,
      expected.offset.blue, expected.offset.green, expected.offset.red,
    ]
    for (actual, expected) in zip(actualValues, expectedValues) {
      #expect(abs(actual - expected) < tolerance)
    }
  }
}
