import CoreGraphics
import CryptoKit
import Darwin
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Metal

// Read-only audit of production tone operators. The runner records source/input hashes.
// No fitted recipes, saved edits, or defaults are changed.
@main
enum ToneControlAudit {
  static let encoder: JSONEncoder = {
    let result = JSONEncoder()
    result.outputFormatting = [.prettyPrinted, .sortedKeys]
    return result
  }()

  static func writeJSON(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }

  static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
  }

  static func metrics(_ image: UInt16Image, inset: Double = 0) -> [String: Any] {
    let dx = Int(Double(image.width) * inset)
    let dy = Int(Double(image.height) * inset)
    var black = 0, white = 0, anyBlack = 0, anyWhite = 0
    var luminances: [Double] = []
    for y in dy..<(image.height - dy) {
      for x in dx..<(image.width - dx) {
        let i = (y * image.width + x) * 3
        let b = image.pixels[i], g = image.pixels[i + 1], r = image.pixels[i + 2]
        black += [b, g, r].filter { $0 == 0 }.count
        // linearToSRGB(1) truncates to 65534 on this CPU path. Counting only
        // 65535 would incorrectly report no clipping for a saturated plateau.
        white += [b, g, r].filter { $0 >= 65_534 }.count
        anyBlack += min(b, g, r) == 0 ? 1 : 0
        anyWhite += max(b, g, r) >= 65_534 ? 1 : 0
        luminances.append((0.0722 * Double(b) + 0.7152 * Double(g) + 0.2126 * Double(r)) / 257)
      }
    }
    luminances.sort()
    let count = Double(luminances.count)
    return [
      "pixelCount": luminances.count, "insetFraction": inset,
      "blackChannelPercent": 100 * Double(black) / (count * 3),
      "nearWhiteChannelPercent": 100 * Double(white) / (count * 3),
      "anyBlackPixelPercent": 100 * Double(anyBlack) / count,
      "anyNearWhitePixelPercent": 100 * Double(anyWhite) / count,
      "encodedLuma255Quantiles": [0.0, 0.01, 0.5, 0.99, 1.0].map {
        luminances[Int($0 * (count - 1))]
      },
    ]
  }

  static func variants() -> [(String, PhotoAdjustmentParameters)] {
    var rows: [(String, PhotoAdjustmentParameters)] = [("neutral", .init())]
    for value in [-4.0, -2, -1, 1, 2, 4] {
      rows.append(("exposure_\(value)", .init(exposureEV: value)))
    }
    for value in [-1.0, -0.5, 0.5, 1] {
      rows.append(("brightness_\(value)", .init(brightness: value)))
      rows.append(("contrast_\(value)", .init(contrast: value)))
    }
    for value in [-1.0, 1] {
      rows.append(("highlights_\(value)", .init(highlights: value)))
      rows.append(("shadows_\(value)", .init(shadows: value)))
      rows.append(("whites_\(value)", .init(whites: value)))
      rows.append(("blacks_\(value)", .init(blacks: value)))
    }
    return rows
  }

  static func ramps(_ output: URL) throws {
    let ramp = UInt16Image(width: 65_536, height: 1, channels: 3,
      pixels: (0...65_535).flatMap { [UInt16] (repeating: UInt16($0), count: 3) })
    var report: [[String: Any]] = []
    var csv = "variant,input255,output255\n"
    for (name, adjustments) in variants() {
      let parameters = ProcessingParameters(filmType: .slide, photoAdjustments: adjustments)
      let rendered = FilmProcessing.correctedPreview(image: ramp, parameters: parameters)
      let green = stride(from: 1, to: rendered.pixels.count, by: 3).map { rendered.pixels[$0] }
      var row = metrics(rendered)
      row["name"] = name
      row["distinctGreenCodes"] = Set(green).count
      row["descendingGreenSteps"] = zip(green, green.dropFirst()).filter { $0 > $1 }.count
      row["blackOutput255"] = Double(green.first!) / 257
      row["whiteOutput255"] = Double(green.last!) / 257
      row["samplesInput255"] = [0, 1, 8, 32, 64, 118, 128, 192, 224, 255]
      row["samplesOutput255"] = [0, 1, 8, 32, 64, 118, 128, 192, 224, 255].map {
        Double(green[$0 * 257]) / 257
      }
      report.append(row)
      for code in stride(from: 0, through: 65_535, by: 257) {
        csv += "\(name),\(Double(code) / 257),\(Double(green[code]) / 257)\n"
      }
    }
    // A later curve cannot recover values clipped at the tone/display boundary.
    let lateCurve = ProcessingParameters(filmType: .slide, curveEnabled: true,
      curveControlPoints: [.init(input: 0, output: 0), .init(input: 1, output: 0.25)],
      photoAdjustments: .init(exposureEV: 2))
    let clipped = FilmProcessing.correctedPreview(image: ramp, parameters: lateCurve)
    report.append([
      "name": "exposure_2_then_quarter_output_curve",
      "input255": [160, 192, 224, 255],
      "output255": [160, 192, 224, 255].map { Double(clipped.pixels[$0 * 257 * 3 + 1]) / 257 },
    ])
    let linear = RenderReadyLinearImage(width: 2, height: 1,
      pixels: [0.6, 0.6, 0.6, 0.9, 0.9, 0.9])
    let adjusted = linear.applyingLinearToneAdjustments(.init(highlights: 1))
    report.append(["name": "highlight_order_reversal", "linearInput": [0.6, 0.9],
      "linearOutput": [adjusted.pixels[0], adjusted.pixels[3]]])
    try writeJSON(report, output.appendingPathComponent("ramps.json"))
    try csv.write(to: output.appendingPathComponent("ramps.csv"), atomically: true, encoding: .utf8)
  }

  struct Metadata: Decodable { let width: Int; let height: Int; let channels: Int }

  static func photographs(_ root: URL, _ output: URL) throws {
    let frames: [(String, FilmBase)] = [
      ("fuji400-fresh/DSCF2833", .colorC41),
      ("proimage/DSCF5800", .colorC41),
      ("harmanphoenixii/DSCF3079", .colorCyanMask),
      ("fuji400-fresh/DSCF2892", .colorC41),
      ("proimage/DSCF5809", .colorC41),
      ("harmanphoenixii/DSCF3091", .colorCyanMask),
    ]
    var report: [[String: Any]] = []
    for (frame, base) in frames {
      let directory = root.appendingPathComponent("dist/camera-raw-study/" + frame)
      let metadata = try JSONDecoder().decode(Metadata.self,
        from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
      let data = try Data(contentsOf: directory.appendingPathComponent("scan.bgr16"))
      let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
      precondition(pixels.count == metadata.width * metadata.height * metadata.channels)
      let scan = UInt16Image(width: metadata.width, height: metadata.height,
        channels: metadata.channels, pixels: pixels)
      var baseline = LookRecipe.cleanInvert.applying(to: base.applyingInvert(to: .init()))
      baseline.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: scan)
      let renderer = StillPreviewRenderer(image: scan)
      let destination = output.appendingPathComponent(frame)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try encoder.encode(baseline).write(to: destination.appendingPathComponent("baseline.json"))
      for (name, adjustments) in variants() where !name.hasSuffix("4.0") {
        var parameters = baseline
        if name.hasPrefix("exposure") { parameters.photoAdjustments.exposureEV = adjustments.exposureEV }
        if name.hasPrefix("brightness") { parameters.photoAdjustments.brightness = adjustments.brightness }
        if name.hasPrefix("contrast") { parameters.photoAdjustments.contrast = adjustments.contrast }
        if name.hasPrefix("highlights") { parameters.photoAdjustments.highlights = adjustments.highlights }
        if name.hasPrefix("shadows") { parameters.photoAdjustments.shadows = adjustments.shadows }
        if name.hasPrefix("whites") { parameters.photoAdjustments.whites = adjustments.whites }
        if name.hasPrefix("blacks") { parameters.photoAdjustments.blacks = adjustments.blacks }
        let rendered = FilmProcessing.correctedPreview(image: scan, parameters: parameters)
        try rendered.write(to: destination.appendingPathComponent(name + ".png"), format: .png,
          parameters: .init(format: .png))
        var row = metrics(rendered, inset: 0.1)
        row["frame"] = frame
        row["name"] = name
        row["filmBase"] = base.rawValue
        if let gpu = renderer?.render(parameters: parameters, showOriginal: false),
          let cpu = rendered.makePreviewCGImage() {
          row["gpuMaxDifference255"] = maxRGBDifference(cpu, gpu)
        } else { row["gpuStatus"] = "unavailable" }
        report.append(row)
      }
      print("Rendered \(frame)")
    }
    try writeJSON(report, output.appendingPathComponent("photographs.json"))
  }

  // Forces all CGImage output pixels to be consumed, rather than timing graph submission alone.
  static func maxRGBDifference(_ a: CGImage, _ b: CGImage) -> Int {
    precondition(a.width == b.width && a.height == b.height)
    precondition(a.bitsPerPixel == 32 && b.bitsPerPixel == 32)
    let dataA = a.dataProvider!.data!, dataB = b.dataProvider!.data!
    let bytesA = CFDataGetBytePtr(dataA)!, bytesB = CFDataGetBytePtr(dataB)!
    var worst = 0
    for y in 0..<a.height {
      for x in 0..<a.width {
        for c in 0..<3 {
          worst = max(worst, abs(Int(bytesA[y * a.bytesPerRow + x * 4 + c])
            - Int(bytesB[y * b.bytesPerRow + x * 4 + c])))
        }
      }
    }
    return worst
  }

  static func consumerContext(_ image: CGImage) -> CGContext {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    precondition(context.data != nil)
    return context
  }

  static func consume(_ image: CGImage) {
    _ = consumerContext(image)
  }

  static func memorySnapshot() throws -> [String: UInt64] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      throw NSError(domain: "ToneControlAudit.task_info", code: Int(result))
    }
    return [
      "physicalFootprintBytes": UInt64(info.phys_footprint),
      "peakPhysicalFootprintBytes": UInt64(max(0, info.ledger_phys_footprint_peak)),
      "residentBytes": UInt64(info.resident_size),
      "reusableBytes": UInt64(info.reusable),
    ]
  }

  static func summary(_ values: [Double]) -> [String: Any] {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    let median = sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    return ["samplesMilliseconds": values, "medianMilliseconds": median,
      "p95Milliseconds": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
      "maximumMilliseconds": sorted.last!]
  }

  // Same frame/settings/consumer as performance(), with no ramps or photograph
  // artifacts. Memory queries and hashing use a separate pass after timing so
  // their overhead is never attributed to the renderer or bitmap consumer.
  static func timingPerformance(_ root: URL, _ output: URL) throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw NSError(domain: "ToneControlAudit", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Timing-only collection requires Metal access"])
    }
    let before = try memorySnapshot()
    var report = try autoreleasepool { () throws -> [String: Any] in
      let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
      let raw = root.appendingPathComponent("sample-raw/fuji400-fresh/DSCF2833.RAF")
      let decodeStart = ContinuousClock.now
      let decoded = try RawImageDecoder.decode(raw,
        profile: .rawTherapeeCameraScan, maxDimension: 100_000)
      let decodeMilliseconds = milliseconds(decodeStart)
      let source = decoded.image
      let afterDecode = try withExtendedLifetime(source) { try memorySnapshot() }
      let analysis = source.resizedToFit(maxDimension: 256)
      let proxy = source.resizedToFit(maxDimension: 2048)
      var parameters = LookRecipe.cleanInvert.applying(to: FilmBase.colorC41.applyingInvert(to: .init()))
      parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: analysis)
      try encoder.encode(parameters).write(to: output.appendingPathComponent("parameters.json"))
      var cropped = parameters
      cropped.manualCrop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
      let cases = [("fit_drag_proxy", proxy, parameters), ("full_release", source, parameters),
        ("manual_crop_drag", proxy, cropped), ("manual_crop_release", source, cropped)]
      var measurements: [[String: Any]] = []
      for (name, input, base) in cases {
        let beforeRenderer = try memorySnapshot()
        var row = try autoreleasepool { () throws -> [String: Any] in
          let setupStart = ContinuousClock.now
          guard let renderer = StillPreviewRenderer(image: input, analysisImage: analysis) else {
            throw NSError(domain: "ToneControlAudit", code: 3,
              userInfo: [NSLocalizedDescriptionKey: "Renderer construction failed: \(name)"])
          }
          let setupMilliseconds = milliseconds(setupStart)
          let afterRenderer = try memorySnapshot()
          var samples: [[String: Any]] = []
          for ev in [0.0, -0.2, 0.2, 0.4] {
            var next = base
            next.photoAdjustments.exposureEV = ev
            let sample = try autoreleasepool { () throws -> [String: Any] in
              let start = ContinuousClock.now
              guard let image = renderer.render(parameters: next, showOriginal: false) else {
                throw NSError(domain: "ToneControlAudit", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "GPU render failed: \(name), EV \(ev)"])
              }
              let renderEnd = ContinuousClock.now
              let renderDuration = start.duration(to: renderEnd)
              let renderMS = Double(renderDuration.components.seconds) * 1_000
                + Double(renderDuration.components.attoseconds) / 1e15
              consume(image)
              let consumeMS = milliseconds(renderEnd)
              return ["exposureEV": ev, "warmup": ev == 0,
                "renderReturnMilliseconds": renderMS, "consumeMilliseconds": consumeMS,
                "totalMilliseconds": renderMS + consumeMS,
                "outputWidth": image.width, "outputHeight": image.height]
            }
            samples.append(sample)
          }
          let afterTiming = try memorySnapshot()
          var diagnostics: [[String: Any]] = []
          for ev in [-0.2, 0.2, 0.4] {
            var next = base
            next.photoAdjustments.exposureEV = ev
            var check: [String: Any] = ["exposureEV": ev]
            // Repeat each exact render to detect nondeterministic output. No
            // assertion compares the lower-resolution proxy with final detail.
            var hashes: [String] = []
            for _ in 0..<2 {
              try autoreleasepool {
                let beforeRender = try memorySnapshot()
                guard let image = renderer.render(parameters: next, showOriginal: false) else {
                  throw NSError(domain: "ToneControlAudit", code: 5)
                }
                let afterRender = try memorySnapshot()
                let context = consumerContext(image)
                let whileConsumed = try withExtendedLifetime((image, context)) { try memorySnapshot() }
                let data = Data(bytesNoCopy: context.data!,
                  count: context.bytesPerRow * context.height, deallocator: .none)
                let hash = withExtendedLifetime(context) {
                  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                hashes.append(hash)
                check["beforeRender"] = beforeRender
                check["afterRender"] = afterRender
                check["withConsumerSurface"] = whileConsumed
                check["consumerBytes"] = context.bytesPerRow * context.height
              }
              check["afterOutputRelease"] = try memorySnapshot()
            }
            guard Set(hashes).count == 1 else {
              throw NSError(domain: "ToneControlAudit", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Repeated output differs: \(name), EV \(ev)"])
            }
            check["consumedRGBA8SHA256"] = hashes[0]
            check["identicalRenderCount"] = hashes.count
            diagnostics.append(check)
          }
          let timed = samples.filter { !($0["warmup"] as! Bool) }
          return ["name": name, "gpuEligible": true,
            "sourceWidth": input.width, "sourceHeight": input.height,
            "manualCrop": name.hasPrefix("manual_crop") ? [0.1, 0.1, 0.8, 0.8] : [],
            "rendererSetupMilliseconds": setupMilliseconds,
            "samples": samples,
            "renderReturn": summary(timed.map { $0["renderReturnMilliseconds"] as! Double }),
            "consume": summary(timed.map { $0["consumeMilliseconds"] as! Double }),
            "total": summary(timed.map { $0["totalMilliseconds"] as! Double }),
            "logicalInputBytes": input.pixels.count * MemoryLayout<UInt16>.stride,
            "logicalRendererRGBABytes": renderer.retainedRGBAByteCount,
            "memoryBeforeRenderer": beforeRenderer, "memoryAfterRenderer": afterRenderer,
            "memoryAfterTiming": afterTiming, "untimedDiagnostics": diagnostics,
            "thermalStateAfter": ProcessInfo.processInfo.thermalState.rawValue]
        }
        row["memoryAfterRendererRelease"] = try memorySnapshot()
        measurements.append(row)
        print("\(name): render=\(row["renderReturn"]!), consume=\(row["consume"]!)")
      }
      return ["schemaVersion": 1, "device": device.name, "cases": measurements,
        "decodeMilliseconds": decodeMilliseconds,
        "decodeSubstages": try JSONSerialization.jsonObject(with: encoder.encode(decoded.timings)),
        "sourceShape": [source.height, source.width, source.channels],
        "analysisShape": [analysis.height, analysis.width, analysis.channels],
        "memoryBeforeDecode": before, "memoryAfterDecode": afterDecode,
        "memoryWithSourcesBeforeRelease": try withExtendedLifetime((source, proxy, analysis)) {
          try memorySnapshot()
        },
        "thermalStateBefore": thermalBefore,
        "thermalStateAfter": ProcessInfo.processInfo.thermalState.rawValue,
        "completedCases": measurements.count, "failedCases": 0, "skippedCases": 0,
        "note": "One first-in-process decode; filesystem cache uncontrolled and input hashed before running. Cases run sequentially in recorded order. EV 0 is warmup; timed EVs -0.2, +0.2, +0.4 match the historical cohort. renderReturn includes production synchronous raster materialization, not shader-only GPU time. consume includes fresh RGBA8 CGContext allocation, full draw and release. Memory/hash pass follows timing; process peak is cumulative across decode and prior cases. Shared CIContext remains alive after local source/renderer release. Thermal enum: 0 nominal, 1 fair, 2 serious, 3 critical. No app scheduling, input, presentation or ACR measurement; no image files. p95 is nearest rank and equals max for three samples."]
    }
    report["memoryAfterSourceRelease"] = try memorySnapshot()
    try writeJSON(report, output.appendingPathComponent("performance.json"))
  }

  static func performance(_ root: URL, _ output: URL) throws {
    let device = MTLCreateSystemDefaultDevice()
    let raw = root.appendingPathComponent("sample-raw/fuji400-fresh/DSCF2833.RAF")
    // Match makeRawFullPreviewSession: full sensor dimensions with the preview
    // demosaic, not the separate three-pass export decode.
    let source = try RawImageDecoder.decode(raw,
      profile: .rawTherapeeCameraScan, maxDimension: 100_000).image
    let analysis = source.resizedToFit(maxDimension: 256)
    let proxy = source.resizedToFit(maxDimension: 2048)
    var parameters = LookRecipe.cleanInvert.applying(to: FilmBase.colorC41.applyingInvert(to: .init()))
    parameters.filmNegativeParams.measuredMedians = FilmNegativeProcessing.computeMedians(image: analysis)
    var cropped = parameters
    cropped.manualCrop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    var measurements: [[String: Any]] = []
    let cases = [("fit_drag_proxy", proxy, parameters), ("full_release", source, parameters),
      ("manual_crop_drag", proxy, cropped), ("manual_crop_release", source, cropped)]
    for (name, input, base) in cases {
      let gpuEligible = StillPreviewRenderer.supports(parameters: base, showOriginal: false)
      if gpuEligible && device == nil {
        measurements.append(["name": name, "status": "skipped: Metal unavailable"])
        continue
      }
      let renderer = gpuEligible ? StillPreviewRenderer(image: input, analysisImage: analysis) : nil
      let cache = CPUPreviewPreparationCache(image: input, analysisImage: analysis)
      var times: [Double] = []
      for ev in [0.0, -0.2, 0.2, 0.4] {
        var next = base
        next.photoAdjustments.exposureEV = ev
        let elapsed = try autoreleasepool { () throws -> Double in
          let start = ContinuousClock.now
          if gpuEligible {
            guard let image = renderer?.render(parameters: next, showOriginal: false) else {
              throw NSError(domain: "ToneControlAudit", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected GPU render failed"])
            }
            consume(image)
          } else {
            let rendered = cache.render(parameters: next)
            consume(rendered.makePreviewCGImage()!)
          }
          return milliseconds(start)
        }
        if ev != 0 { times.append(elapsed) }
      }
      measurements.append(["name": name, "gpuEligible": gpuEligible,
        "sourceWidth": input.width, "sourceHeight": input.height,
        "samplesMilliseconds": times, "medianMilliseconds": times.sorted()[times.count / 2]])
      print("\(name): \(times)")
    }
    try writeJSON(["device": device?.name ?? "unavailable", "cases": measurements,
      "note": "Three warm direct-render samples, output fully consumed. Full-sensor one-pass preview decode; CPU uses production preparation cache. No app event, display presentation, or ACR timing. Source 40 MP; crop retains 64% of pixels."],
      output.appendingPathComponent("performance.json"))
  }

  static func main() throws {
    precondition(CommandLine.arguments.count == 3 ||
      (CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--timing-only"))
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    if CommandLine.arguments.last == "--timing-only" {
      try timingPerformance(root, output)
      return
    }
    try ramps(output)
    try photographs(root, output)
    try performance(root, output)
  }
}
