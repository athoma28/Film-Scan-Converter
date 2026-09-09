@preconcurrency import Darwin
import Foundation
import Testing

@testable import FilmScanConverterMac
@testable import FilmScanEngine

@Suite("Preview analysis performance", .serialized)
struct PreviewAnalysisPerformanceTests {
  @Test(
    "Measure CPU preview diagnostics and Darkroom analysis",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PREVIEW_ANALYSIS_BENCHMARKS"] == "1",
      "set RUN_PREVIEW_ANALYSIS_BENCHMARKS=1 for the release benchmark")
  )
  func benchmark() throws {
    // Run each case in its own process when comparing process-lifetime peaks.
    let selectedCase = ProcessInfo.processInfo.environment["PREVIEW_ANALYSIS_CASE"]
    for channels in [3, 1] {
      let name = "statistics-40mp-\(channels)ch"
      guard selectedCase == nil || selectedCase == name else { continue }
      let image = analysisBenchmarkImage(width: 7728, height: 5200, channels: channels)
      try measure(name) {
        try #require(AppModel.previewStatistics(for: image))
      }
    }
    for flat in [false, true] {
      let name = flat ? "darkroom-flat" : "darkroom-textured"
      guard selectedCase == nil || selectedCase == name else { continue }
      let image = analysisBenchmarkImage(width: 1000, height: 667, flat: flat)
      try measure(name) {
        DensityPrintProcessing.analyze(
          image: image,
          profile: NegativeDensityProfileCatalog.harmanPhoenixII,
          paper: DensityPaperProfileCatalog.fujiCrystalArchive)
      }
    }
  }

  private func measure<T: Equatable>(_ name: String, body: () throws -> T) throws {
    let expected = try body()
    var samples = [Double]()
    for _ in 0..<5 {
      let start = ContinuousClock.now
      let actual = try body()
      let elapsed = start.duration(to: .now).components
      samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
      #expect(actual == expected)
    }
    let sorted = samples.sorted()
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    #expect(status == KERN_SUCCESS)
    let report: [String: Any] = [
      "case": name,
      "samplesMilliseconds": samples,
      "p50Milliseconds": sorted[2],
      "p95Milliseconds": sorted[4],
      "physicalFootprintBytes": info.phys_footprint,
      "peakPhysicalFootprintBytes": info.ledger_phys_footprint_peak,
    ]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("PREVIEW_ANALYSIS \(String(decoding: json, as: UTF8.self))")
  }
}

func analysisBenchmarkImage(
  width: Int, height: Int, channels: Int = 3, flat: Bool = false
) -> UInt16Image {
  var pixels = [UInt16](repeating: 30_000, count: width * height * channels)
  if !flat {
    var state: UInt64 = 0x67CD_9321_9D23_E551
    for index in pixels.indices {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      pixels[index] = UInt16(truncatingIfNeeded: state >> 32)
    }
  }
  return UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
}
