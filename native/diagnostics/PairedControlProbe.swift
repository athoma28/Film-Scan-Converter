import AppKit
import FilmScanEngine
import Foundation

private final class TextPasteboard: CorrectionSettingsPasteboard {
  var text: String?
  func clearContents() -> Int {
    text = nil
    return 0
  }
  func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool { true }
  func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
    text = string
    return true
  }
  func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }
  func string(forType type: NSPasteboard.PasteboardType) -> String? { text }
}

@main
struct PairedControlProbe {
  struct Metadata: Decodable {
    let width: Int
    let height: Int
    let channels: Int
    let medians: BGRChannelValues
  }

  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
      .compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(".corrections.json") }
    precondition(!files.isEmpty, "Generate the paired-reference report first")
    let pasteboard = TextPasteboard()
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    var pixelChecks = 0
    var sources: [URL: UInt16Image] = [:]
    var namedPresetCount = 0
    let skinPresetURL = root.appendingPathComponent("skin-presets.json")
    if FileManager.default.fileExists(atPath: skinPresetURL.path) {
      let document = try JSONDecoder().decode(
        NamedCorrectionPresetStore.Document.self,
        from: Data(contentsOf: skinPresetURL))
      precondition(document.schemaVersion == 2)
      precondition(Set(document.presets.map(\.id)).count == document.presets.count)
      for preset in document.presets {
        let data = try JSONEncoder().encode(preset.settings)
        pasteboard.text = String(decoding: data, as: UTF8.self)
        let decoded = try clipboard.read()
        precondition(decoded == preset.settings)
      }
      namedPresetCount = document.presets.count
    }
    for file in files {
      pasteboard.text = try String(contentsOf: file, encoding: .utf8)
      guard let settings = try clipboard.read() else {
        preconditionFailure("Invalid recipe: \(file)")
      }
      let name = String(file.lastPathComponent.dropLast(".corrections.json".count))
      let directory = file.deletingLastPathComponent()
      let metadata = try JSONDecoder().decode(
        Metadata.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
      var expected = try JSONDecoder().decode(
        ProcessingParameters.self,
        from: Data(contentsOf: directory.appendingPathComponent(name + ".json")))
      expected.filmNegativeParams.measuredMedians = metadata.medians
      var destination = FilmBase.resolved(from: expected).applyingInvert(
        to: ProcessingParameters(photoAdjustments: .init()))
      destination.filmNegativeParams.measuredMedians = expected.filmNegativeParams.measuredMedians
      let recreated = settings.applying(to: destination)
      precondition(recreated == expected, "Recipe omits scored state: \(file.path)")
      if sources[directory] == nil {
        let data = try Data(contentsOf: directory.appendingPathComponent("scan.bgr16"))
        let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        precondition(pixels.count == metadata.width * metadata.height * metadata.channels)
        sources[directory] = UInt16Image(
          width: metadata.width, height: metadata.height,
          channels: metadata.channels, pixels: pixels)
      }
      let rendered = FilmProcessing.correctedPreview(
        image: sources[directory]!, parameters: recreated)
      let scored = try Data(contentsOf: directory.appendingPathComponent(name + ".bgr16"))
      precondition(
        rendered.pixels.withUnsafeBytes { Data($0) } == scored,
        "App-applied recipe does not recreate scored pixels: \(file.path)")
      pixelChecks += 1
      destination.rotation = 1
      destination.borderCrop = 7
      destination.filmDyeMixing.redFromGreen = 0.13
      let applied = settings.applying(to: destination)
      precondition(applied.rotation == 1 && applied.borderCrop == 7)
      precondition(applied.photoAdjustments == settings.recipe.photoAdjustments)
      precondition(applied.redCurveControlPoints == settings.recipe.redCurveControlPoints)
      precondition(applied.greenCurveControlPoints == settings.recipe.greenCurveControlPoints)
      precondition(applied.blueCurveControlPoints == settings.recipe.blueCurveControlPoints)
      precondition(applied.filmDyeMixing == destination.filmDyeMixing)
    }

    let pixel = UInt16Image(width: 1, height: 1, channels: 3, pixels: [20_000, 20_000, 20_000])
    var parameters = ProcessingParameters(filmType: .slide)
    parameters.curveEnabled = true
    parameters.curveControlPoints = [
      CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 0.5),
    ]
    let masterOnly = FilmProcessing.correctedPreview(image: pixel, parameters: parameters)
    parameters.redCurveEnabled = true
    parameters.redCurveControlPoints = [
      CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1),
    ]
    let withRed = FilmProcessing.correctedPreview(image: pixel, parameters: parameters)

    let input = (blue: 0.1, green: 0.2, red: 0.6)
    let desaturated = ProtectedColorAdjustment.apply(
      blue: input.blue, green: input.green,
      red: input.red, parameters: PhotoAdjustmentParameters(saturation: -1))
    let y =
      input.blue * ProtectedColorAdjustment.blueLuminance
      + input.green * ProtectedColorAdjustment.greenLuminance
      + input.red * ProtectedColorAdjustment.redLuminance
    let beforeChroma = abs(input.blue - y) + abs(input.green - y) + abs(input.red - y)
    let afterChroma =
      abs(desaturated.blue - y) + abs(desaturated.green - y) + abs(desaturated.red - y)
    let report: [String: Any] = [
      "recipesReadThroughAppTextClipboard": files.count,
      "exactAppAppliedPixelChecks": pixelChecks,
      "canonicalFilmBaseReproduction": true,
      "namedSkinPresetsDecoded": namedPresetCount,
      "framingPreserved": true,
      "masterOnlyBGR": masterOnly.pixels,
      "masterWithIdentityRedBGR": withRed.pixels,
      "saturationMinusOneInputBGR": [input.blue, input.green, input.red],
      "saturationMinusOneOutputBGR": [desaturated.blue, desaturated.green, desaturated.red],
      "remainingLinearChromaFraction": afterChroma / beforeChroma,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}
