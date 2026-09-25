import FilmScanEngine
import Foundation

/// A diagnostic of public color and grading controls. The objective
/// separates luma and opponent-channel residuals; it is not a perceptual metric.
enum ProImageColorStudy {
  static func fit(
    image: UInt16Image, parameters: ProcessingParameters,
    directory: URL, name: String
  ) throws -> ProcessingParameters {
    let data = try Data(contentsOf: directory.appendingPathComponent("target.bgr16"))
    let target = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    let mask = try Data(contentsOf: directory.appendingPathComponent("color-train-mask.u8"))
    guard image.channels == 3, target.count == image.pixels.count,
      mask.count == image.width * image.height
    else { throw CocoaError(.fileReadCorruptFile) }
    let indices = stride(from: 0, to: mask.count, by: 7).filter { mask[$0] != 0 }
    guard !indices.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    let cache = CPUPreviewPreparationCache(image: image)
    func score(_ p: ProcessingParameters) -> Double {
      let rendered = cache.render(parameters: p)
      var sum = 0.0
      for index in indices {
        let base = index * 3
        let db = (Double(rendered.pixels[base]) - Double(target[base])) / 65535
        let dg = (Double(rendered.pixels[base + 1]) - Double(target[base + 1])) / 65535
        let dr = (Double(rendered.pixels[base + 2]) - Double(target[base + 2])) / 65535
        let luma = 0.0722 * db + 0.7152 * dg + 0.2126 * dr
        sum +=
          0.5 * abs(luma) + abs(dr - dg) + abs(db - dg)
          + 0.1 * (abs(db) + abs(dg) + abs(dr))
      }
      return sum / Double(indices.count)
    }
    let densityControlCount = 2
    let photoPaths: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.exposureEV, \.brightness, \.contrast, \.temperatureShiftMired,
      \.tint, \.saturation, \.vibrance,
    ]
    let steps = [0.125, 0.02, 0.125, 10, 0.1, 0.15, 0.15]
    let bounds = [
      (-3.0, 3.0), (-0.5, 0.5), (-1.0, 1.0), (-100.0, 100.0),
      (-1.0, 1.0), (-1.0, 1.0), (-1.0, 1.0),
    ]
    var best = parameters
    var bestScore = score(best)
    let originalScore = bestScore
    var evaluations = 1
    for scale in [1.0, 0.5, 0.25, 0.125] {
      for _ in 0..<5 {
        var improved = false
        for i in 0..<(densityControlCount + photoPaths.count) {
          let center = best
          for sign in [-1.0, 1.0] {
            var trial = center
            if i < densityControlCount {
              let value =
                i == 0
                ? center.filmNegativeParams.densityUnmixStrength
                : (center.filmNegativeParams.densityCastRemovalStrength ?? 0.5)
              let updated = min(1, max(0, value + sign * scale * 0.08))
              if i == 0 {
                trial.filmNegativeParams.densityUnmixStrength = updated
              } else {
                trial.filmNegativeParams.densityCastRemovalStrength = updated
              }
            } else {
              let j = i - densityControlCount
              let path = photoPaths[j]
              trial.photoAdjustments[keyPath: path] = min(
                bounds[j].1,
                max(
                  bounds[j].0,
                  center.photoAdjustments[keyPath: path] + sign * scale * steps[j]))
              trial.syncLegacyColorFieldsFromPhotoAdjustments()
            }
            let value = score(trial)
            evaluations += 1
            if value + 0.000001 < bestScore {
              best = trial
              bestScore = value
              improved = true
            }
          }
        }
        if !improved { break }
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode([
      "initialTrainingObjective": originalScore,
      "finalTrainingObjective": bestScore, "renderEvaluations": Double(evaluations),
    ])
    .write(to: directory.appendingPathComponent(name + "-fit.json"))
    return best
  }
}
