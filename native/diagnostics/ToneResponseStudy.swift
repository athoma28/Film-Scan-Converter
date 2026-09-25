import CoreGraphics
import CryptoKit
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation

// Production CPU rendering only: analysis and visualization live in the runner.
// This executable neither fits nor installs parameters and never changes inputs.
@main
enum ToneResponseStudy {
  struct Frame: Decodable {
    let id: String
    let directory: String
    let filmBase: String
  }
  struct Variant: Codable {
    let id: String
    let deltas: [String: Double]
  }
  struct Profile: Codable {
    let name: String
    let schemaVersion: Int
    let photoOverrides: [String: Double]
    let variantIDs: [String]?
  }
  struct Study: Decodable {
    let frames: [Frame]
    let variants: [Variant]
    let profiles: [Profile]
    let compareMetal: Bool
    let preferenceCheckpoints: String
    let archiveDirectory: String
    let writeCorrectionDocuments: Bool
  }
  struct Metadata: Decodable {
    let width: Int
    let height: Int
    let channels: Int
    let medians: BGRChannelValues?
  }
  struct PreferenceLedger: Decodable {
    struct Frame: Decodable {
      struct Candidate: Decodable {
        let variant: String
        let imageSHA256: String
        let parameters: ProcessingParameters
      }
      let stock: String
      let frame: String
      let candidates: [Candidate]
    }
    let schemaVersion: Int
    let frames: [Frame]
  }
  struct CorrectionDocument: Encodable {
    let schemaVersion = 2
    let recipe: LookRecipe
  }
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
  }

  static let encoder: JSONEncoder = {
    let result = JSONEncoder()
    result.outputFormatting = [.prettyPrinted, .sortedKeys]
    return result
  }()

  static func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }

  static func readScan(_ directory: URL) throws -> (UInt16Image, Metadata) {
    let metadata = try JSONDecoder().decode(
      Metadata.self,
      from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
    let data = try Data(contentsOf: directory.appendingPathComponent("scan.bgr16"))
    guard metadata.width > 0, metadata.height > 0, metadata.channels == 3,
      data.count == metadata.width * metadata.height * metadata.channels * 2
    else {
      throw Failure("Invalid archived source: \(directory.path)")
    }
    let pixels = data.withUnsafeBytes {
      Array($0.bindMemory(to: UInt16.self)).map { UInt16(littleEndian: $0) }
    }
    return (
      UInt16Image(
        width: metadata.width, height: metadata.height,
        channels: metadata.channels, pixels: pixels), metadata
    )
  }

  static func preferenceChecks(_ study: Study, _ output: URL) throws {
    let ledgerData = try Data(contentsOf: URL(fileURLWithPath: study.preferenceCheckpoints))
    // Decode the frozen parameter objects with the production decoder. Do not
    // migrate them to a recipe, change versions, or reclassify the photograph.
    let ledger = try JSONDecoder().decode(PreferenceLedger.self, from: ledgerData)
    guard ledger.schemaVersion == 1 else { throw Failure("Unsupported preference ledger") }
    var checks: [[String: Any]] = []
    var failures = 0
    for frame in ledger.frames {
      let identifier = frame.stock + "/" + frame.frame
      let directory = URL(fileURLWithPath: study.archiveDirectory, isDirectory: true)
        .appendingPathComponent(identifier)
      let (scan, metadata) = try readScan(directory)
      guard let medians = metadata.medians else {
        throw Failure("Preference archive is missing historical medians: \(identifier)")
      }
      for candidate in frame.candidates {
        let relative = "preferences/\(identifier)/\(candidate.variant)"
        let destination = output.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try encoder.encode(candidate.parameters).write(
          to: destination.appendingPathComponent("parameters-decoded.json"))
        var parameters = candidate.parameters
        // This is the archived paired-study input contract that produced the
        // checkpoints, not new image analysis or a replacement preference.
        parameters.filmNegativeParams.measuredMedians = medians
        try encoder.encode(parameters).write(
          to: destination.appendingPathComponent("parameters-rendered.json"))
        let image = FilmProcessing.correctedPreview(image: scan, parameters: parameters)
        let png = destination.appendingPathComponent("render.png")
        try image.write(to: png, format: .png, parameters: .init(format: .png))
        let actual = SHA256.hash(data: try Data(contentsOf: png))
          .map { String(format: "%02x", $0) }.joined()
        let matches = actual == candidate.imageSHA256
        if !matches { failures += 1 }
        checks.append([
          "frame": identifier, "variant": candidate.variant,
          "expectedSHA256": candidate.imageSHA256, "actualSHA256": actual,
          "match": matches, "render": relative + "/render.png",
          "decodedParameters": relative + "/parameters-decoded.json",
          "renderedParameters": relative + "/parameters-rendered.json",
        ])
      }
    }
    guard checks.count >= 5 else { throw Failure("Expected all five frozen preference snapshots") }
    try writeJSON(
      [
        "schemaVersion": 1, "checks": checks, "failures": failures,
        "scope":
          "Fresh production CPU PNG renders from actual JSON-decoded frozen parameters plus the historical archived medians. Ledger and old image files are never modified.",
      ],
      to: output.appendingPathComponent("preference-checks.json"))
    if failures > 0 {
      throw Failure(
        "\(failures) fresh preference PNG hashes differ; inspect output, never rewrite the ledger")
    }
    print("Verified \(checks.count) freshly rendered preference snapshots")
  }

  static func assign(
    _ values: [String: Double], to p: inout PhotoAdjustmentParameters,
    additive: Bool
  ) throws {
    for (key, value) in values {
      let path: WritableKeyPath<PhotoAdjustmentParameters, Double>
      switch key {
      case "exposureEV": path = \.exposureEV
      case "brightness": path = \.brightness
      case "contrast": path = \.contrast
      case "highlights": path = \.highlights
      case "shadows": path = \.shadows
      case "whites": path = \.whites
      case "blacks": path = \.blacks
      case "shadowFloor": path = \.shadowFloor
      case "midtoneLevel": path = \.midtoneLevel
      case "highlightCeiling": path = \.highlightCeiling
      case "temperatureShiftMired": path = \.temperatureShiftMired
      case "tint": path = \.tint
      case "saturation": path = \.saturation
      case "vibrance": path = \.vibrance
      default: throw Failure("Unknown adjustment: \(key)")
      }
      guard value.isFinite else { throw Failure("Nonfinite adjustment: \(key)") }
      p[keyPath: path] = additive ? p[keyPath: path] + value : value
    }
  }

  // Normalize both bitmap layouts through the same fully consumed sRGB context.
  // The comparison is same-input 8-bit display output, not full-resolution export.
  static func rgba(_ image: CGImage) throws -> [UInt8] {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let bytes = context.data
    else { throw Failure("Cannot allocate comparison bitmap") }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(
      UnsafeBufferPointer(
        start: bytes.assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4))
  }

  static func compare(_ cpu: CGImage, _ gpu: CGImage) throws -> [String: Any] {
    guard cpu.width == gpu.width, cpu.height == gpu.height else {
      throw Failure("CPU/Metal output dimensions differ")
    }
    let a = try rgba(cpu)
    let b = try rgba(gpu)
    var maximum = 0
    var total: UInt64 = 0
    for i in a.indices where i % 4 != 3 {
      let difference = abs(Int(a[i]) - Int(b[i]))
      maximum = max(maximum, difference)
      total += UInt64(difference)
    }
    return [
      "maxRGBDifference255": maximum,
      "meanRGBDifference255": Double(total) / Double(cpu.width * cpu.height * 3),
    ]
  }

  static func signalStudy(_ output: URL) throws {
    let inputs = [0.0, 0.001, 0.01, 0.05, 0.18, 0.5, 0.75, 0.98, 1, 1.01, 1.1, 2, 4, 16]
    let evs = [-1.0, -0.5, -0.25, 0, 0.25, 0.5, 1, 2, 4]
    var rows: [[String: Any]] = []
    var reversals: [[String: Any]] = []
    for input in inputs {
      var previous: Double?
      var previousEV: Double?
      for ev in evs {
        let linear = RenderReadyLinearImage(
          width: 1, height: 1,
          pixels: [input, input, input])
        let result = linear.applyingLinearToneAdjustments(.init(exposureEV: ev)).pixels[1]
        guard result.isFinite else { throw Failure("Nonfinite native signal output") }
        rows.append(["inputLinearY": input, "exposureEV": ev, "outputLinearY": result])
        if let previous, let previousEV, previousEV >= 0, result < previous - 1e-12 {
          reversals.append([
            "inputLinearY": input, "fromEV": previousEV, "toEV": ev,
            "fromLinearY": previous, "toLinearY": result, "deltaLinearY": result - previous,
          ])
        }
        previous = result
        previousEV = ev
      }
    }
    try writeJSON(
      [
        "schemaVersion": 1,
        "toneVersion": PhotoAdjustmentParameters.currentSchemaVersion,
        "scope":
          "Authoritative production Swift floating tone seam on neutral Rec.2020 gray; all other controls zero. Not a photograph, not display quantization, and not proof that a selected photo contains over-white tone inputs.",
        "samples": rows, "positiveExposureDecreaseCases": reversals,
      ], to: output.appendingPathComponent("signal-response.json"))
  }

  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      throw Failure("Usage: ToneResponseStudy study.json output-directory")
    }
    let study = try JSONDecoder().decode(
      Study.self,
      from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try preferenceChecks(study, output)
    try signalStudy(output)
    var rows: [[String: Any]] = []
    var parityFailures = 0
    for frame in study.frames {
      let directory = URL(fileURLWithPath: frame.directory, isDirectory: true)
      let (scan, _) = try readScan(directory)
      guard let base = FilmBase(rawValue: frame.filmBase) else {
        throw Failure("Invalid film base: \(frame.id)")
      }
      // Leave medians unset: production computes its usual immutable 256px analysis.
      let recipe = LookRecipe.cleanInvert.applying(to: base.applyingInvert(to: .init()))
      let renderer = study.compareMetal ? StillPreviewRenderer(image: scan) : nil
      if study.compareMetal && renderer == nil { throw Failure("Metal unavailable: \(frame.id)") }
      for profile in study.profiles {
        guard
          (1...PhotoAdjustmentParameters.maximumSupportedSchemaVersion).contains(
            profile.schemaVersion)
        else {
          throw Failure("Unsupported requested schema: \(profile.schemaVersion)")
        }
        var baseline = recipe
        baseline.photoAdjustments.schemaVersion = profile.schemaVersion
        try assign(profile.photoOverrides, to: &baseline.photoAdjustments, additive: false)
        for variant in study.variants {
          if let allowed = profile.variantIDs, !allowed.contains(variant.id) { continue }
          var parameters = baseline
          try assign(variant.deltas, to: &parameters.photoAdjustments, additive: true)
          let relative = "\(frame.id)/\(profile.name)/\(variant.id)"
          let destination = output.appendingPathComponent(relative)
          try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
          let rendered = FilmProcessing.correctedPreview(image: scan, parameters: parameters)
          try rendered.write(
            to: destination.appendingPathComponent("render.png"), format: .png,
            parameters: .init(format: .png))
          try encoder.encode(parameters).write(
            to: destination.appendingPathComponent("parameters.json"))
          var row: [String: Any] = [
            "frame": frame.id, "profile": profile.name,
            "variant": variant.id, "width": rendered.width, "height": rendered.height,
            "render": relative + "/render.png", "parameters": relative + "/parameters.json",
            "metalStatus": study.compareMetal ? "compared" : "not-requested",
          ]
          if study.writeCorrectionDocuments {
            let document = CorrectionDocument(
              recipe: LookRecipe.capturing(
                parameters,
                id: "tone-response-\(profile.name)-\(variant.id)",
                title: "Tone response · \(profile.name) · \(variant.id)",
                summary:
                  "Explicit diagnostic candidate; apply only for review. Film base and framing are retained."
              ))
            try encoder.encode(document).write(
              to: destination.appendingPathComponent("corrections.json"))
            row["correctionDocument"] = relative + "/corrections.json"
          }
          if study.compareMetal {
            guard let gpu = renderer?.render(parameters: parameters, showOriginal: false),
              let cpu = rendered.makePreviewCGImage()
            else {
              throw Failure("Requested Metal comparison could not render: \(relative)")
            }
            let comparison = try compare(cpu, gpu)
            row["metalComparison"] = comparison
            if (comparison["maxRGBDifference255"] as! Int) > 2 { parityFailures += 1 }
          }
          rows.append(row)
        }
        print("Rendered \(frame.id), \(profile.name)")
      }
    }
    try writeJSON(
      ["schemaVersion": 1, "renders": rows, "parityFailures": parityFailures],
      to: output.appendingPathComponent("renders.json"))
    if parityFailures > 0 { throw Failure("\(parityFailures) CPU/Metal cases exceeded 2/255") }
  }
}
