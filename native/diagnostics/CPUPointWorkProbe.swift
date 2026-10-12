import CryptoKit
import Darwin
import FilmScanEngine
import Foundation

let availableCases = [
  "colorC41", "colorCyanMask", "blackAndWhite", "straighten-viewport",
  "perspective-viewport", "slide", "calibrated-color",
]
let usage = """
  Usage: CPUPointWorkProbe RAW OUTPUT.json full|proxy [CASE,CASE,...]
  Timed cases: \(availableCases.joined(separator: ","))
  Every run also hashes 72 untimed synthetic branch cases. Output must be new.
  Use run-cpu-point-work-probe.py to build and record reproducible provenance.
  """
func usageError(_ message: String) -> Never {
  FileHandle.standardError.write(Data("\(message)\n\(usage)\n".utf8))
  exit(2)
}
if CommandLine.arguments.count == 2,
  ["--help", "-h"].contains(CommandLine.arguments[1])
{
  print(usage)
  exit(0)
}
guard (4...5).contains(CommandLine.arguments.count) else {
  usageError("Provide a RAW path, new JSON output and full or proxy mode.")
}
guard ["full", "proxy"].contains(CommandLine.arguments[3]) else {
  usageError("Mode must be full or proxy.")
}
var selectedCases: Set<String>?
if CommandLine.arguments.count == 5 {
  let names = CommandLine.arguments[4].split(separator: ",", omittingEmptySubsequences: false)
    .map(String.init)
  guard !names.isEmpty, Set(names).count == names.count,
    names.allSatisfy({ availableCases.contains($0) })
  else { usageError("Case names must be known, nonempty and unique.") }
  selectedCases = Set(names)
}

func seconds(_ d: Duration) -> Double {
  Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func hash(_ image: UInt16Image) -> String {
  image.pixels.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
}
let raw = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: raw.path, isDirectory: &isDirectory),
  !isDirectory.boolValue
else { usageError("RAW input must be an existing file.") }
guard !FileManager.default.fileExists(atPath: output.path),
  FileManager.default.fileExists(
    atPath: output.deletingLastPathComponent().path, isDirectory: &isDirectory),
  isDirectory.boolValue
else { usageError("JSON output must be new and its parent directory must exist.") }
let full = CommandLine.arguments[3] == "full"
let decode = try RawImageDecoder.decode(raw, profile: .rawTherapeeCameraScan, maxDimension: 100_000)
let source = full ? decode.image : decode.image.resizedToFit(maxDimension: 2048)
let medians = FilmNegativeProcessing.computeMedians(image: source.resizedToFit(maxDimension: 256))
var cases: [(String, ProcessingParameters, Bool)] = []
for base in [FilmBase.colorC41, .colorCyanMask, .blackAndWhite] {
  var p = base.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
  p.filmNegativeParams.measuredMedians = medians
  p.photoAdjustments = .init(
    exposureEV: 0.2, brightness: 0.05, contrast: 0.2, highlights: -0.15, shadows: 0.2,
    temperatureShiftMired: 8, tint: -0.1, saturation: 0.15, vibrance: 0.1,
    whites: 0.1, blacks: -0.1)
  if base == .colorCyanMask {
    p.highlightWheel = .init(hue: 35, strength: 0.15)
    p.midtoneWheel = .init(hue: 210, strength: 0.2)
    p.shadowWheel = .init(hue: 270, strength: 0.1)
  }
  cases.append((base.rawValue, p, false))
}
var straightened = cases[0].1
straightened.straightenAngle = 1.7
cases.append(("straighten-viewport", straightened, true))
var perspective = cases[0].1
perspective.perspectiveCrop = .init(
  topLeft: .init(x: 0.05, y: 0.03), topRight: .init(x: 0.94, y: 0.08),
  bottomRight: .init(x: 0.92, y: 0.95), bottomLeft: .init(x: 0.03, y: 0.92))
cases.append(("perspective-viewport", perspective, true))
var slide = cases[0].1
slide.filmType = .slide
cases.append(("slide", slide, false))
var calibrated = cases[1].1
calibrated.filmNegativeParams = .colourNegative
calibrated.filmNegativeParams.measuredMedians = medians
cases.append(("calibrated-color", calibrated, false))
// Untimed branch oracles exercise the scalar seam on serial and banded inputs, including
// sensor black, one-channel replication, disabled inversion, curves and wheels.
var oracles = [String: String]()
for size in [(64, 48), (1024, 256)] {
  for channels in [1, 3] {
    let count = size.0 * size.1 * channels
    let pixels: [UInt16] = (0..<count).map { index -> UInt16 in
      if index < 12 { return 0 }
      if index < 18 { return 1024 }
      if index < 24 { return 1025 }
      return UInt16((index * 7919 + 17) % 65_536)
    }
    let image = UInt16Image(width: size.0, height: size.1, channels: channels, pixels: pixels)
    for version in [2, 3, 4] {
      for filmType in [FilmType.colourNegative, .blackAndWhiteNegative, .slide] {
        for enabled in [false, true] {
          var p = calibrated
          p.filmType = filmType
          p.filmNegativeParams =
            filmType == .blackAndWhiteNegative ? .blackAndWhite : .colourNegative
          p.filmNegativeParams.enabled = enabled
          p.photoAdjustments.schemaVersion = version
          p.curveEnabled = true
          p.curveControlPoints = [
            .init(input: 0, output: 0.02), .init(input: 0.5, output: 0.4),
            .init(input: 1, output: 0.95),
          ]
          oracles["\(size.0)x\(size.1)-\(channels)-\(version)-\(filmType.rawValue)-\(enabled)"] =
            hash(
              FilmProcessing.correctedPreview(image: image, parameters: p))
        }
      }
    }
  }
}
if let selectedCases {
  cases = cases.filter { selectedCases.contains($0.0) }
}
var records = [[String: Any]]()
for (name, settings, viewport) in cases {
  let cache = CPUPreviewPreparationCache(image: source)
  var p = settings
  // Complete correction warms geometry/analysis. Overview preparation belongs
  // to the first timed viewport request, identically in both executables.
  _ = cache.render(parameters: p)
  var samples = [[String: Any]]()
  for ev in [0.2, -0.2, 0.4] {
    p.photoAdjustments.exposureEV = ev
    let start = ContinuousClock.now
    let image: UInt16Image
    var overview: UInt16Image?
    if viewport {
      guard
        let result = cache.renderViewport(
          parameters: p, region: ImageRegion(x: 256, y: 128, width: 1200, height: 800),
          overviewMaximumDimension: 1024)
      else { usageError("Source geometry is too small for the fixed \(name) viewport.") }
      image = result.detail
      overview = result.overview
    } else {
      image = cache.render(parameters: p)
    }
    let duration = seconds(start.duration(to: .now))
    var sample: [String: Any] = [
      "exposureEV": ev, "seconds": duration, "sha256": hash(image),
      "width": image.width, "height": image.height,
      "retainedGeometryBytes": cache.retainedGeometryByteCount,
    ]
    if let overview {
      sample["overviewSHA256"] = hash(overview)
      sample["overviewWidth"] = overview.width
      sample["overviewHeight"] = overview.height
    }
    samples.append(sample)
  }
  records.append([
    "name": name,
    "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)),
    "samples": samples,
  ])
  FileHandle.standardOutput.write(Data("\(name): \(samples.map { $0["seconds"]! })\n".utf8))
}
let data = try JSONSerialization.data(
  withJSONObject: [
    "date": ISO8601DateFormatter().string(from: Date()),
    "raw": raw.path, "rawSHA256": SHA256.hash(data: try Data(contentsOf: raw)).description,
    "sourceSHA256": hash(source), "sourceWidth": source.width, "sourceHeight": source.height,
    "mode": full ? "full" : "proxy", "cases": records,
    "branchOracles": oracles,
    "note":
      "Three exposure values per case; warmed geometry. Timed CPU correction only, including first overview preparation for viewport cases. Output hashes outside timing. Full-sensor one-pass source; no export, bitmap packing, publication or screen-latency measurement.",
  ], options: [.prettyPrinted, .sortedKeys])
try data.write(to: output, options: .atomic)
