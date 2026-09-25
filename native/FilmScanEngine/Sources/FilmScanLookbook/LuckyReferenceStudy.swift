import FilmScanEngine
import Foundation

/// Offline, unpaired reference study. Digital positives must never be inverted.
enum LuckyReferenceStudy {
  struct Recipe: Decodable {
    var name: String
    var look: String?
    var unmixRGB: [Double]?
    var unmixStrength: Double?
    var castRemoval: Double?
    var dyeMixing: FilmDyeMixingParameters?
    var adjustments: PhotoAdjustmentParameters?
  }

  static func run(repositoryRoot: URL) throws {
    let args = CommandLine.arguments.dropFirst()
    let output = URL(
      fileURLWithPath: args.first { !$0.hasPrefix("--") }
        ?? "/tmp/lucky200-study", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var recipes = [
      Recipe(name: "cleanInvert", look: LookRecipe.cleanInvert.id),
      Recipe(name: "foliage", look: LookRecipe.foliage.id),
    ]
    if let option = args.first(where: { $0.hasPrefix("--recipes=") }) {
      recipes += try JSONDecoder().decode(
        [Recipe].self,
        from: Data(contentsOf: URL(fileURLWithPath: String(option.dropFirst("--recipes=".count)))))
    }
    let root = repositoryRoot.appendingPathComponent("sample-raw/luckyc200")
    let sources = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "raf" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for source in sources {
      let stem = source.deletingPathExtension().lastPathComponent
      FileHandle.standardError.write(Data("study \(stem)\n".utf8))
      let image = try RawImageDecoder.decode(source, profile: .rawTherapeeCameraScan)
        .image.resizedToFit(maxDimension: 1200)
      // Lossless decoded scan samples allow an auditable offline patch analysis.
      try image.pixels.withUnsafeBytes { bytes in
        try Data(bytes).write(to: output.appendingPathComponent("\(stem)-scan.bgr16"))
      }
      try encoder.encode(["width": image.width, "height": image.height]).write(
        to: output.appendingPathComponent("\(stem)-size.json"))
      for recipe in recipes {
        var parameters = FilmBase.colorC41.applyingInvert(to: ProcessingParameters())
        if let lookID = recipe.look, let look = LookRecipe.named(lookID) {
          parameters = look.applying(to: parameters)
        }
        if let matrix = recipe.unmixRGB { parameters.filmNegativeParams.densityUnmixRGB = matrix }
        if let strength = recipe.unmixStrength {
          parameters.filmNegativeParams.densityUnmixStrength = strength
        }
        if let cleanup = recipe.castRemoval {
          parameters.filmNegativeParams.densityCastRemovalStrength = cleanup
        }
        if let mixing = recipe.dyeMixing { parameters.filmDyeMixing = mixing }
        if let adjustments = recipe.adjustments { parameters.photoAdjustments = adjustments }
        parameters.syncLegacyColorFieldsFromPhotoAdjustments()
        let rendered = FilmProcessing.correctedPreview(image: image, parameters: parameters)
        try rendered.write(
          to: output.appendingPathComponent("\(stem)-\(recipe.name).jpg"),
          format: .jpeg, parameters: ExportParameters(format: .jpeg, jpegQuality: 0.96))
        try encoder.encode(parameters).write(
          to: output.appendingPathComponent("\(stem)-\(recipe.name).json"))
      }
    }
  }
}
