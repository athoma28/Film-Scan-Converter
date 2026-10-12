import AppKit
import CoreGraphics
import CryptoKit
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import ImageIO
import Metal

/// Standalone diagnostic, linked with the exact engine/renderer snapshot under test
/// and the app's CorrectionSettings.swift. Does not change app settings or profiles.
private final class MatrixTextPasteboard: CorrectionSettingsPasteboard {
  var text: String?
  func clearContents() -> Int { text = nil; return 0 }
  func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool { true }
  func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
    text = string
    return true
  }
  func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }
  func string(forType type: NSPasteboard.PasteboardType) -> String? { text }
}

@main
struct XT5MatrixProbe {
  struct Manifest: Decodable {
    let arm: String
    let tier: String
    let frames: [Frame]
    let report: String?
  }

  struct Frame: Decodable {
    let key: String
    let raw: String
    let target: String?
    let directory: String
    let stock: String
    let monochrome: Bool
    let recipes: [Recipe]?
  }

  struct Recipe: Decodable {
    let name: String
    let parameters: ProcessingParameters
    let measuredMedians: BGRChannelValues?
    /// False is reserved for exact historical preference replays whose private
    /// invert state cannot be represented by a current public-control recipe.
    let captureRecipe: Bool?
  }

  struct RecipeDocument: Encodable {
    let schemaVersion = 2
    let recipe: LookRecipe
    let requiredFilmBase: FilmBase
  }

  static func error(_ message: String) -> NSError {
    NSError(domain: "XT5MatrixProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }

  static func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: encode(value))
  }

  static func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      .write(to: url, options: .atomic)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func imageDigest(_ image: UInt16Image) -> String {
    image.pixels.withUnsafeBytes { bytes in
      var hasher = SHA256()
      hasher.update(bufferPointer: bytes)
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }

  static func fileDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Exact endpoint clipping of the stored UInt16 samples, before any display
  /// packing. RGB order in the report; source storage is BGR (or one channel).
  static func clipping(_ image: UInt16Image) -> [String: Any] {
    let count = image.width * image.height
    var zero = [Int](repeating: 0, count: 3)
    var maximum = [Int](repeating: 0, count: 3)
    var anyZero = 0
    var anyMaximum = 0
    for pixel in 0..<count {
      var low = false
      var high = false
      for channel in 0..<3 {
        let index = pixel * image.channels + (image.channels == 1 ? 0 : 2 - channel)
        let value = image.pixels[index]
        if value == 0 { zero[channel] += 1; low = true }
        if value == .max { maximum[channel] += 1; high = true }
      }
      if low { anyZero += 1 }
      if high { anyMaximum += 1 }
    }
    let channels: [[String: Any]] = ["red", "green", "blue"].enumerated().map { channel, name in
      ["name": name, "zeroCount": zero[channel], "maxCount": maximum[channel],
       "zeroFraction": Double(zero[channel]) / Double(count),
       "maxFraction": Double(maximum[channel]) / Double(count)]
    }
    return ["pixelCount": count, "channelsRGB": channels,
            "anyZeroFraction": Double(anyZero) / Double(count),
            "anyMaxFraction": Double(anyMaximum) / Double(count)]
  }

  static func writeRaster(_ image: UInt16Image, name: String, directory: URL) throws {
    try image.pixels.withUnsafeBytes {
      try Data($0).write(to: directory.appendingPathComponent(name + ".bgr16"))
    }
    let display = image.channels == 1
      ? UInt16Image(width: image.width, height: image.height, channels: 3,
                    pixels: image.pixels.flatMap { [$0, $0, $0] }) : image
    try display.write(to: directory.appendingPathComponent(name + ".png"), format: .png,
                      parameters: ExportParameters(format: .png))
  }

  static func rgba(_ cgImage: CGImage) -> [UInt8]? {
    guard cgImage.width > 0, cgImage.height > 0,
      cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32,
      [.noneSkipLast, .premultipliedLast, .last].contains(cgImage.alphaInfo),
      cgImage.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little,
      cgImage.bytesPerRow >= cgImage.width * 4,
      let data = cgImage.dataProvider?.data,
      CFDataGetLength(data) >= cgImage.bytesPerRow * (cgImage.height - 1) + cgImage.width * 4,
      let pointer = CFDataGetBytePtr(data)
    else { return nil }
    var pixels: [UInt8] = []
    pixels.reserveCapacity(cgImage.width * cgImage.height * 4)
    for y in 0..<cgImage.height {
      pixels.append(contentsOf: UnsafeBufferPointer(
        start: pointer.advanced(by: y * cgImage.bytesPerRow), count: cgImage.width * 4))
    }
    return pixels
  }

  static func parity(image: UInt16Image, cpu: UInt16Image,
                     parameters: ProcessingParameters,
                     renderer: StillPreviewRenderer?, hasMetal: Bool) -> [String: Any] {
    let start = Date()
    let staticSupport = StillPreviewRenderer.supports(parameters: parameters, showOriginal: false)
    guard hasMetal else {
      return ["status": "failed", "reason": "Metal unavailable; GPU comparison not performed"]
    }
    guard let renderer else {
      return ["status": "failed", "reason": "Production GPU renderer could not be created"]
    }
    let instanceSupport = renderer.supports(parameters: parameters, showOriginal: false)
    guard staticSupport && instanceSupport else {
      let routedToCPU = renderer.render(parameters: parameters, showOriginal: false) == nil
      return ["status": routedToCPU ? "cpuFallback" : "failed",
              "staticSupport": staticSupport, "instanceSupport": instanceSupport,
              "explicitCPURoute": routedToCPU,
              "reason": staticSupport ? "Source-dependent density precision gate" : "Unsupported GPU parameters",
              "seconds": Date().timeIntervalSince(start)]
    }
    let expected = ImageGeometry.outputDimensions(
      source: PixelDimensions(width: image.width, height: image.height), parameters: parameters)
    guard let gpu = renderer.render(parameters: parameters, showOriginal: false),
      let cpuCG = cpu.makePreviewCGImage(),
      gpu.width == expected.width, gpu.height == expected.height,
      gpu.width == cpuCG.width, gpu.height == cpuCG.height,
      let gpuBytes = rgba(gpu), let cpuBytes = rgba(cpuCG), gpuBytes.count == cpuBytes.count
    else {
      return ["status": "failed", "reason": "GPU render, dimensions, or bitmap-layout validation failed"]
    }
    var maxima = [Int](repeating: 0, count: 3)
    var total: Int64 = 0
    var differingPixels = 0
    for index in stride(from: 0, to: gpuBytes.count, by: 4) {
      var different = false
      for channel in 0..<3 {
        let delta = abs(Int(gpuBytes[index + channel]) - Int(cpuBytes[index + channel]))
        maxima[channel] = max(maxima[channel], delta)
        total += Int64(delta)
        different = different || delta != 0
      }
      if different { differingPixels += 1 }
    }
    let maximum = maxima.max() ?? 0
    return ["status": maximum <= 2 ? "passed" : "failed", "tolerance": 2,
            "units": "8-bit display RGB levels", "maximumRGBError": maximum,
            "maximumPerChannelRGB": maxima,
            "meanRGBError": Double(total) / Double(gpu.width * gpu.height * 3),
            "pixelCount": gpu.width * gpu.height, "differentPixels": differingPixels,
            "seconds": Date().timeIntervalSince(start)]
  }

  static func parserCheck(document: Data, image: UInt16Image, expected: UInt16Image,
                          parameters: ProcessingParameters) throws -> [String: Any] {
    let pasteboard = MatrixTextPasteboard()
    pasteboard.text = String(decoding: document, as: UTF8.self)
    let clipboard = CorrectionSettingsClipboard(pasteboard: pasteboard)
    guard let settings = try clipboard.read() else {
      return ["status": "failed", "reason": "Actual app text parser rejected schema-2 recipe"]
    }
    var destination = FilmBase.resolved(from: parameters)
      .applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
    destination.filmNegativeParams.measuredMedians = parameters.filmNegativeParams.measuredMedians
    let recreated = settings.applying(to: destination)
    let sameParameters = recreated == parameters
    let reproduced = FilmProcessing.correctedPreview(image: image, parameters: recreated)
    let samePixels = reproduced == expected
    destination.rotation = 1
    destination.borderCrop = 7
    destination.filmDyeMixing.redFromGreen = 0.13
    let transferred = settings.applying(to: destination)
    let preservesFraming = transferred.rotation == 1 && transferred.borderCrop == 7
    let preservesCalibration = transferred.filmDyeMixing == destination.filmDyeMixing
    let passed = sameParameters && samePixels && preservesFraming && preservesCalibration
    return ["status": passed ? "passed" : "failed", "exactParameters": sameParameters,
            "exactPixels": samePixels, "framingPreserved": preservesFraming,
            "privateCalibrationPreserved": preservesCalibration,
            "scope": "Current app text clipboard parser; canonical film base; 900px production CPU pixels"]
  }

  static func generatedRecipes(frame: Frame, image: UInt16Image,
                               medians: BGRChannelValues) throws -> [Recipe] {
    let base: FilmBase = frame.monochrome ? .blackAndWhite
      : frame.stock == "harmanphoenixii" ? .colorCyanMask : .colorC41
    var natural = base.applyingInvert(to: ProcessingParameters(photoAdjustments: .init()))
    natural.filmNegativeParams.measuredMedians = medians
    natural = LookRecipe.capturing(natural, id: "natural", title: "Film base only")
      .applying(to: natural)
    guard let recommended = LookRecipe.recommended(for: base).first else {
      throw error("No recommended clean recipe for \(base)")
    }
    var automatic = FilmBase.automaticallyClassifiedParameters(
      base: ProcessingParameters(photoAdjustments: .init()),
      image: image.resizedToFit(maxDimension: 256))
    automatic.filmNegativeParams.measuredMedians = medians
    automatic = LookRecipe.capturing(automatic, id: "automatic", title: "Automatic")
      .applying(to: automatic)
    return [Recipe(name: "natural", parameters: natural, measuredMedians: nil, captureRecipe: true),
            Recipe(name: "clean", parameters: recommended.applying(to: natural),
                   measuredMedians: nil, captureRecipe: true),
            Recipe(name: "automatic", parameters: automatic, measuredMedians: nil, captureRecipe: true)]
  }

  static func jpeg(_ rendered: UInt16Image, name: String, directory: URL) throws -> [String: Any] {
    let start = Date()
    let url = directory.appendingPathComponent(name + ".jpg")
    try rendered.write(to: url, format: .jpeg,
                       parameters: ExportParameters(format: .jpeg, jpegQuality: 0.96))
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let readback = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw error("Could not independently read exported JPEG \(url.path)") }
    guard readback.width == rendered.width, readback.height == rendered.height else {
      throw error("Exported JPEG dimensions differ from corrected image")
    }
    return ["width": rendered.width, "height": rendered.height,
            "readbackWidth": readback.width, "readbackHeight": readback.height,
            "readback": "ImageIO full JPEG decompression", "sha256": try fileDigest(url),
            "path": url.path, "seconds": Date().timeIntervalSince(start)]
  }

  static func run(frame: Frame, manifest: Manifest, hasMetal: Bool) throws -> [String: Any] {
    let start = Date()
    let directory = URL(fileURLWithPath: frame.directory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rawURL = URL(fileURLWithPath: frame.raw)
    let rawHash = try fileDigest(rawURL)
    let decodeStart = Date()
    let decoded = try RawImageDecoder.decode(
      rawURL, fullResolution: manifest.tier == "full", profile: .rawTherapeeCameraScan,
      collectDiagnostics: true)
    let decodeSeconds = Date().timeIntervalSince(decodeStart)
    let image = manifest.tier == "full" ? decoded.image : decoded.image.resizedToFit(maxDimension: 900)
    let small = image.resizedToFit(maxDimension: 900)
    let medians = FilmNegativeProcessing.computeMedians(
      image: image.resizedToFit(maxDimension: 256), borderPercent: 20)
    let recipes = try frame.recipes ?? generatedRecipes(frame: frame, image: image, medians: medians)
    guard !recipes.isEmpty, Set(recipes.map(\.name)).count == recipes.count,
      recipes.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("/") && $0.name != "metadata" })
    else { throw error("Recipe names must be nonempty, unique filenames") }
    let renderer = hasMetal ? StillPreviewRenderer(image: small) : nil
    var renders: [String: Any] = [:]
    var failures: [String] = []
    for recipe in recipes {
      try autoreleasepool {
        var parameters = recipe.parameters
        parameters.filmNegativeParams.measuredMedians = recipe.measuredMedians ?? medians
        // Frozen historical preferences must retain their original representation.
        if recipe.captureRecipe != false { parameters.syncLegacyColorFieldsFromPhotoAdjustments() }
        let parametersData = try encode(parameters)
        try parametersData.write(to: directory.appendingPathComponent(recipe.name + ".json"))
        let renderStart = Date()
        let rendered = FilmProcessing.correctedPreview(image: image, parameters: parameters)
        let renderSeconds = Date().timeIntervalSince(renderStart)
        let proxy = rendered.resizedToFit(maxDimension: 900)
        try writeRaster(proxy, name: recipe.name, directory: directory)
        let cpuSmall = manifest.tier == "full"
          ? FilmProcessing.correctedPreview(image: small, parameters: parameters) : rendered
        let parityResult = parity(image: small, cpu: cpuSmall, parameters: parameters,
                                  renderer: renderer, hasMetal: hasMetal)
        let parserResult: [String: Any]
        if recipe.captureRecipe != false {
          let document = try encode(RecipeDocument(
            recipe: LookRecipe.capturing(parameters, id: "snapshot", title: "Snapshot"),
            requiredFilmBase: FilmBase.resolved(from: parameters)))
          try document.write(to: directory.appendingPathComponent(recipe.name + ".recipe.json"))
          parserResult = try parserCheck(document: document, image: small,
                                         expected: cpuSmall, parameters: parameters)
        } else {
          parserResult = ["status": "excludedLegacyPreference",
                          "reason": "Frozen private inversion state is intentionally not a current public recipe"]
        }
        if parityResult["status"] as? String == "failed" { failures.append(recipe.name + ": Metal parity") }
        if parserResult["status"] as? String == "failed" { failures.append(recipe.name + ": app parser") }
        var result: [String: Any] = [
          "width": proxy.width, "height": proxy.height, "channels": proxy.channels,
          "fullWidth": rendered.width, "fullHeight": rendered.height, "fullChannels": rendered.channels,
          "medians": try object(parameters.filmNegativeParams.measuredMedians!),
          "medianPolicy": recipe.measuredMedians == nil ? "fresh-256-border20" : "explicit-frozen-override",
          "parametersSHA256": digest(parametersData), "correctedImageSHA256": imageDigest(rendered),
          "proxyImageSHA256": imageDigest(proxy),
          "pngSHA256": try fileDigest(directory.appendingPathComponent(recipe.name + ".png")),
          "clipping": clipping(rendered), "proxyClipping": clipping(proxy),
          "renderSeconds": renderSeconds, "appParser": parserResult, "metalParity": parityResult,
          "validationSourceDimensions": ["width": small.width, "height": small.height],
        ]
        if manifest.tier == "full"
          && (recipe.name == "clean" || recipe.name.hasPrefix("preference") || recipe.captureRecipe == false)
        {
          result["jpeg"] = try jpeg(rendered, name: recipe.name, directory: directory)
        }
        renders[recipe.name] = result
        print("\(manifest.arm) \(manifest.tier) \(frame.key) \(recipe.name): parser=\(parserResult["status"]!) metal=\(parityResult["status"]!)")
      }
    }
    if manifest.tier == "preview" { try writeRaster(small, name: "scan", directory: directory) }
    var metadata: [String: Any] = [
      "schemaVersion": 1, "arm": manifest.arm, "tier": manifest.tier, "key": frame.key,
      "width": small.width, "height": small.height, "channels": small.channels,
      "rawWidth": decoded.image.width, "rawHeight": decoded.image.height, "rawChannels": decoded.image.channels,
      "medians": try object(medians), "variants": recipes.map(\.name),
      "raw": rawURL.path, "rawSHA256": rawHash,
      "sourceImageSHA256": imageDigest(image), "decodedClipping": clipping(decoded.image),
      "scanClipping": clipping(small),
      "decode": ["seconds": decodeSeconds, "timings": try object(decoded.timings),
                 "diagnostics": try object(decoded.diagnostics),
                 "decoderVersion": decoded.decoderVersion, "colorDescription": decoded.colorDescription,
                 "isoSpeed": decoded.isoSpeed, "processingFlags": decoded.processing.rawValue,
                 "demosaicWorkers": decoded.demosaicWorkerCount, "unpackWorkers": decoded.unpackWorkerCount],
      "renders": renders, "failures": failures, "status": failures.isEmpty ? "passed" : "failed",
      "elapsedSeconds": Date().timeIntervalSince(start),
    ]
    if let target = frame.target, manifest.tier == "preview" {
      let targetURL = URL(fileURLWithPath: target)
      let reference = try StandardImageDecoder.decodePreview(targetURL, maxDimension: 1200)
      try writeRaster(reference, name: "reference", directory: directory)
      metadata["reference"] = ["width": reference.width, "height": reference.height,
                               "channels": reference.channels, "target": target,
                               "targetSHA256": try fileDigest(targetURL)]
    }
    try writeJSON(metadata, to: directory.appendingPathComponent("metadata.json"))
    return ["key": frame.key, "directory": directory.path,
            "status": failures.isEmpty ? "passed" : "failed", "failures": failures,
            "variants": recipes.map(\.name)]
  }

  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw error("Usage: XT5MatrixProbe /absolute/manifest.json")
    }
    let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    guard ["preview", "full"].contains(manifest.tier), !manifest.frames.isEmpty else {
      throw error("Manifest requires preview/full tier and at least one frame")
    }
    let hasMetal = MTLCreateSystemDefaultDevice() != nil
    var results: [[String: Any]] = []
    let start = Date()
    for frame in manifest.frames {
      do {
        results.append(try autoreleasepool { try run(frame: frame, manifest: manifest, hasMetal: hasMetal) })
      } catch {
        print("FAIL \(manifest.arm) \(manifest.tier) \(frame.key): \(error)")
        results.append(["key": frame.key, "directory": frame.directory,
                        "status": "failed", "error": String(describing: error)])
      }
    }
    let failureCount = results.filter { $0["status"] as? String != "passed" }.count
    let reportURL = manifest.report.map { URL(fileURLWithPath: $0) }
      ?? manifestURL.appendingPathExtension("results.json")
    try writeJSON(["schemaVersion": 1, "arm": manifest.arm, "tier": manifest.tier,
                   "hasMetal": hasMetal, "frames": results, "expectedFrames": manifest.frames.count,
                   "completedFrames": results.count, "failedFrames": failureCount,
                   "elapsedSeconds": Date().timeIntervalSince(start),
                   "status": failureCount == 0 ? "passed" : "failed"], to: reportURL)
    print("\(manifest.arm) \(manifest.tier): \(results.count) frames, \(failureCount) failed. \(reportURL.path)")
    if failureCount != 0 { exit(1) }
  }
}
