import CryptoKit
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Bounded work-reuse measurements", .serialized)
struct PerformanceFollowupBenchmarks {
  @Test(
    "Alternating retained-source comparisons",
    .enabled(if: ProcessInfo.processInfo.environment["RUN_WORK_REUSE_BENCHMARK"] == "1"))
  func measure() throws {
    var samples: [String: [Double]] = [:]
    let image = CPUPreparationPerformanceTests.image(width: 2048, height: 1024)
    let tone = PhotoAdjustmentParameters(
      exposureEV: 0.4, contrast: 0.2, highlights: -0.3,
      shadows: 0.2, temperatureShiftMired: 10, saturation: 0.1)
    var p = ProcessingParameters(straightenAngle: 1.3, filmType: .colourNegative)
    p.filmNegativeParams.enabled = true
    p.filmNegativeParams.rendering = .densityPrint
    p.photoAdjustments = tone
    let cache = CPUPreviewPreparationCache(image: image)
    _ = cache.render(parameters: p)
    for repetition in 0..<3 {
      for banded in (repetition.isMultiple(of: 2) ? [false, true] : [true, false]) {
        let start = ContinuousClock.now
        let result =
          banded
          ? FilmProcessing.applySemanticLinearAdjustmentsToDisplayImage(
            image, parameters: tone, applyColorAdjustments: true)
          : FilmProcessing.applySemanticLinearAdjustmentsToDisplayBand(
            image, parameters: tone, applyColorAdjustments: true)
        #expect(result.pixels.count == image.pixels.count)
        samples[banded ? "color_banded_ms" : "color_whole_ms", default: []].append(
          milliseconds(start))
      }
      for cached in (repetition.isMultiple(of: 2) ? [false, true] : [true, false]) {
        p.photoAdjustments.exposureEV = Double(repetition) * 0.2
        let start = ContinuousClock.now
        let result =
          cached
          ? cache.render(parameters: p)
          : FilmProcessing.correctedPreview(image: image, parameters: p)
        #expect(result.width > 0)
        samples[
          cached ? "geometry_analysis_cached_ms" : "geometry_analysis_uncached_ms", default: []
        ].append(milliseconds(start))
      }
    }
    let url = SampleRawCorpus.url(relativePath: "fuji400-fresh/DSCF2833.RAF")
    let raw = try RawImageDecoder.decode(
      url, profile: .rawTherapeeCameraScan, maxDimension: 100_000
    ).image
    let renderer = try #require(
      StillPreviewRenderer(
        image: raw,
        analysisImage: raw.resizedToFit(maxDimension: 256)))
    var gpu = ProcessingParameters(filmType: .colourNegative)
    gpu.filmNegativeParams.enabled = true
    gpu.filmNegativeParams.rendering = .calibratedColor
    let region = CGRect(x: 0.25, y: 0.25, width: 0.2, height: 0.2)
    for pass in 0..<4 {
      for mode in (pass.isMultiple(of: 2) ? ["full", "fit", "region"] : ["region", "fit", "full"]) {
        gpu.photoAdjustments.exposureEV = Double(pass) * 0.1
        let start = ContinuousClock.now
        let raster = try #require(
          renderer.render(
            parameters: gpu, showOriginal: false,
            maximumDimension: mode == "fit" ? 2048 : nil,
            normalizedRegion: mode == "region" ? region : nil))
        // Force an equal bitmap consumer in each arm; creating a lazy CGImage
        // alone is not an end-to-end GPU timing.
        #expect(StillPreviewRenderer.statistics(for: raster)?.sampleCount ?? 0 > 0)
        if mode == "region" {
          let overview = try #require(
            renderer.render(parameters: gpu, showOriginal: false, maximumDimension: 1024))
          #expect(StillPreviewRenderer.statistics(for: overview)?.sampleCount ?? 0 > 0)
        }
        if pass > 0 { samples["gpu_\(mode)_ms", default: []].append(milliseconds(start)) }
      }
    }
    let report: [String: Any] = [
      "date": ISO8601DateFormatter().string(from: Date()),
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "cpuPixels": image.width * image.height,
      "rawDimensions": [raw.width, raw.height],
      "rawSHA256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }
        .joined(),
      "samples": samples,
      "note":
        "Three alternating release samples after GPU warmup. Region arm includes a 1024px overview. Every GPU raster has the same bitmap/statistics consumer. No native input, display presentation, energy, or process-footprint claim.",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let output = ProcessInfo.processInfo.environment["WORK_REUSE_BENCHMARK_OUTPUT"] {
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    print("WORK_REUSE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
  }

  private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds)
      / 1e15
  }
}
