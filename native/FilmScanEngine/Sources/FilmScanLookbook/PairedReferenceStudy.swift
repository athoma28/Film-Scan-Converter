import FilmScanEngine
import Foundation

/// Offline control-reachability experiment. All pixels are rendered by the production
/// CPU pipeline; no user settings or bundled profiles are modified.
enum PairedReferenceStudy {
  struct Job: Decodable {
    var raw: String?
    var target: String?
    var directory: String
    var stock: String?
    var monochrome: Bool?
    var parameters: ProcessingParameters?
    var name: String?
    var optimize: Bool?
    var autoClassify: Bool?
    var refineColor: Bool?
    var displayLook: String?
    var measuredMedians: BGRChannelValues?
    var captureRecipe: Bool?
  }

  struct Metadata: Codable {
    var width: Int
    var height: Int
    var channels: Int
    var medians: BGRChannelValues
    var variants: [String]
  }

  static func write(_ image: UInt16Image, name: String, directory: URL) throws {
    try image.pixels.withUnsafeBytes {
      try Data($0).write(to: directory.appendingPathComponent(name + ".bgr16"))
    }
    let display =
      image.channels == 1
      ? UInt16Image(
        width: image.width, height: image.height, channels: 3,
        pixels: image.pixels.flatMap { [$0, $0, $0] }) : image
    try display.write(
      to: directory.appendingPathComponent(name + ".png"), format: .png,
      parameters: ExportParameters(format: .png))
  }

  static func run(manifest: String) throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jobs = try decoder.decode(
      [Job].self,
      from: Data(contentsOf: URL(fileURLWithPath: manifest)))
    for job in jobs {
      let directory = URL(fileURLWithPath: job.directory, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let raw = job.raw, var parameters = job.parameters, let name = job.name {
        let start = Date()
        let image = try RawImageDecoder.decode(
          URL(fileURLWithPath: raw), fullResolution: true,
          profile: .rawTherapeeCameraScan
        ).image
        // Match the app's export analysis size, independently of the fitting proxy.
        parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(
          image: image.resizedToFit(maxDimension: 256), borderPercent: 20)
        let rendered = FilmProcessing.correctedPreview(image: image, parameters: parameters)
        try rendered.write(
          to: directory.appendingPathComponent(name + ".jpg"), format: .jpeg,
          parameters: ExportParameters(format: .jpeg, jpegQuality: 0.96))
        try write(
          rendered.resizedToFit(maxDimension: 900), name: name + "-check", directory: directory)
        try encoder.encode([
          "width": Double(rendered.width), "height": Double(rendered.height),
          "decodeRenderExportSeconds": Date().timeIntervalSince(start),
        ])
        .write(to: directory.appendingPathComponent(name + "-export.json"))
        print("full export \(raw)")
        continue
      }
      if let raw = job.raw {
        print("decode \(raw)")
        let image = try RawImageDecoder.decode(
          URL(fileURLWithPath: raw),
          profile: .rawTherapeeCameraScan
        ).image.resizedToFit(maxDimension: 900)
        let analysis = image.resizedToFit(maxDimension: 256)
        let medians = FilmNegativeProcessing.computeMedians(image: analysis, borderPercent: 20)
        let base: FilmBase =
          job.monochrome == true
          ? .blackAndWhite
          : job.stock == "harmanphoenixii" ? .colorCyanMask : .colorC41
        var natural = base.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
        natural.filmNegativeParams.measuredMedians = medians
        natural = LookRecipe.capturing(natural, id: "natural", title: "Film base only")
          .applying(to: natural)
        let variants: [(String, ProcessingParameters)] =
          [("natural", natural)]
          + LookRecipe.recommended(for: base).map { ($0.id, $0.applying(to: natural)) }
        for (name, var parameters) in variants {
          parameters.filmNegativeParams.measuredMedians = medians
          let rendered = FilmProcessing.correctedPreview(image: image, parameters: parameters)
          try write(rendered, name: name, directory: directory)
          try writeParameters(
            parameters, name: name, directory: directory, captureRecipe: job.captureRecipe != false)
        }
        try write(image, name: "scan", directory: directory)
        try encoder.encode(
          Metadata(
            width: image.width, height: image.height,
            channels: image.channels, medians: medians, variants: variants.map(\.0))
        )
        .write(to: directory.appendingPathComponent("metadata.json"))
        if let target = job.target {
          // Use the app's color-managed decoder, including embedded orientation.
          let reference = try StandardImageDecoder.decodePreview(
            URL(fileURLWithPath: target),
            maxDimension: 1200)
          try write(reference, name: "reference", directory: directory)
        }
      } else if var parameters = job.parameters, let name = job.name {
        let metadata = try decoder.decode(
          Metadata.self,
          from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        let data = try Data(contentsOf: directory.appendingPathComponent("scan.bgr16"))
        let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        guard pixels.count == metadata.width * metadata.height * metadata.channels else {
          throw CocoaError(.fileReadCorruptFile)
        }
        let image = UInt16Image(
          width: metadata.width, height: metadata.height,
          channels: metadata.channels, pixels: pixels)
        if job.autoClassify == true {
          parameters = FilmBase.automaticallyClassifiedParameters(
            base: ProcessingParameters(photoAdjustments: .init()),
            image: image.resizedToFit(maxDimension: 256))
        } else {
          parameters.filmNegativeParams.measuredMedians = job.measuredMedians ?? metadata.medians
        }
        if let lookName = job.displayLook {
          guard
            let look = LookRecipe.named(lookName)
              ?? LookRecipe.factory.first(where: { $0.id == lookName || $0.title == lookName })
          else {
            throw NSError(
              domain: "PairedReferenceStudy", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "Unknown look recipe \(lookName)"])
          }
          parameters = look.applying(to: parameters)
        }
        if job.optimize == true {
          parameters = try fitBasicControls(
            image: image, parameters: parameters,
            directory: directory)
        }
        if job.refineColor == true {
          parameters = try ProImageColorStudy.fit(
            image: image, parameters: parameters,
            directory: directory, name: name)
        }
        if job.captureRecipe != false { parameters.syncLegacyColorFieldsFromPhotoAdjustments() }
        try write(
          FilmProcessing.correctedPreview(image: image, parameters: parameters),
          name: name, directory: directory)
        try writeParameters(
          parameters, name: name, directory: directory, captureRecipe: job.captureRecipe != false)
        print("render \(directory.lastPathComponent)/\(name)")
      }
    }
  }

  struct RecipeDocument: Encodable {
    let schemaVersion = 2
    let recipe: LookRecipe
    let requiredFilmBase: FilmBase
  }

  static func writeParameters(
    _ parameters: ProcessingParameters, name: String, directory: URL, captureRecipe: Bool
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(parameters).write(to: directory.appendingPathComponent(name + ".json"))
    if captureRecipe {
      let recipe = LookRecipe.capturing(parameters, id: "snapshot", title: "Snapshot")
      try encoder.encode(
        RecipeDocument(recipe: recipe, requiredFilmBase: FilmBase.resolved(from: parameters))
      )
      .write(to: directory.appendingPathComponent(name + ".recipe.json"))
    }
  }

  /// A bounded coordinate search of the actual public sliders. This is an
  /// attainable recipe, not a claim to have found the global optimum.
  static func fitBasicControls(
    image: UInt16Image, parameters: ProcessingParameters,
    directory: URL
  ) throws -> ProcessingParameters {
    let targetBytes = try Data(contentsOf: directory.appendingPathComponent("target.bgr16"))
    let targetPixels = targetBytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    let mask = try Data(contentsOf: directory.appendingPathComponent("train-mask.u8"))
    guard targetPixels.count == image.width * image.height * 3,
      mask.count == image.width * image.height
    else { throw CocoaError(.fileReadCorruptFile) }
    let small = image.resizedToFit(maxDimension: 192)
    let target = UInt16Image(
      width: image.width, height: image.height, channels: 3,
      pixels: targetPixels
    ).resizedToFit(maxDimension: 192)
    var indices: [Int] = []
    for y in 0..<small.height {
      for x in 0..<small.width {
        let sx = min(
          image.width - 1, Int((Double(x) + 0.5) * Double(image.width) / Double(small.width)))
        let sy = min(
          image.height - 1, Int((Double(y) + 0.5) * Double(image.height) / Double(small.height)))
        if mask[sy * image.width + sx] != 0 { indices.append(y * small.width + x) }
      }
    }
    guard !indices.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    let paths: [WritableKeyPath<PhotoAdjustmentParameters, Double>] = [
      \.exposureEV, \.brightness, \.contrast, \.highlights, \.shadows,
      \.temperatureShiftMired, \.tint, \.saturation, \.vibrance,
    ]
    let steps = [0.5, 0.08, 0.25, 0.3, 0.3, 20, 0.2, 0.3, 0.3]
    let bounds = [
      (-3.0, 3.0), (-0.5, 0.5), (-1.0, 1.0), (-1.0, 1.0),
      (-1.0, 1.0), (-100.0, 100.0), (-1.0, 1.0), (-1.0, 1.0), (-1.0, 1.0),
    ]
    func score(_ p: ProcessingParameters) -> Double {
      let result = FilmProcessing.correctedPreview(image: small, parameters: p)
      var total = 0.0
      for i in indices {
        for c in 0..<3 {
          total += abs(
            Double(result.pixels[i * result.channels + (result.channels == 1 ? 0 : c)])
              - Double(target.pixels[i * 3 + c]))
        }
      }
      return total / Double(indices.count * 3) / 65535
    }
    var best = parameters
    var bestScore = score(best)
    for scale in [1.0, 0.5, 0.25, 0.125] {
      for _ in 0..<4 {
        var improved = false
        for (i, path) in paths.enumerated() {
          if !best.filmType.supportsColorCorrections && i >= 5 { continue }
          let center = best
          for sign in [-1.0, 1.0] {
            var trial = center
            trial.photoAdjustments[keyPath: path] = min(
              bounds[i].1,
              max(
                bounds[i].0,
                center.photoAdjustments[keyPath: path] + sign * scale * steps[i]))
            trial.syncLegacyColorFieldsFromPhotoAdjustments()
            let error = score(trial)
            if error + 0.00001 < bestScore {
              best = trial
              bestScore = error
              improved = true
            }
          }
        }
        if !improved { break }
      }
    }
    return best
  }
}
