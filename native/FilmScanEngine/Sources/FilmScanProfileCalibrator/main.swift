import Darwin
import FilmScanEngine
import Foundation

private func fail(_ message: String, status: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(status)
}

private let usage = """
  Usage: FilmScanProfileCalibrator <calibration-input.json> <report-output.json>

  Fits a regularized affine BGR matrix in base-subtracted density space, scores
  it against frame-level held-out samples, and writes a candidate capture
  profile plus fit/validation metrics. It never installs the candidate profile.
  """

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  print(usage)
  exit(0)
}
guard arguments.count == 2 else {
  fail(usage)
}

let inputURL = URL(fileURLWithPath: arguments[0])
let outputURL = URL(fileURLWithPath: arguments[1])

do {
  let inputData = try Data(contentsOf: inputURL)
  let document = try JSONDecoder().decode(
    DensityMatrixCalibrationDocument.self,
    from: inputData
  )
  guard document.schemaVersion == DensityMatrixCalibrationDocument.currentSchemaVersion else {
    fail(
      "Unsupported calibration schema version \(document.schemaVersion); "
        + "this build supports \(DensityMatrixCalibrationDocument.currentSchemaVersion)."
    )
  }

  let output = try DensityMatrixCalibrator.calibrate(document: document)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let outputData = try encoder.encode(output)
  try outputData.write(to: outputURL, options: .atomic)

  let baseline = output.report.validationBaselineMetrics.weightedRMSE
  let fitted = output.report.validationMetrics.weightedRMSE
  let improvement = output.report.relativeValidationImprovement * 100
  let gate = output.report.passesHeldOutGate ? "PASS" : "FAIL"
  print(
    String(
      format:
        "Held-out gate %@ — RMSE %.8f vs identity %.8f (%+.2f%%); report: %@",
      gate,
      fitted,
      baseline,
      improvement,
      outputURL.path
    )
  )
  if !output.report.passesHeldOutGate {
    exit(2)
  }
} catch {
  fail("Calibration failed: \(error)")
}
