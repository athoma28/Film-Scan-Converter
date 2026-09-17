import CryptoKit
@preconcurrency import Darwin
import FilmScanEngine
import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanConverterMac

@Suite("Real RAW preview-scale performance", .serialized)
struct PreviewScalePerformanceTests {
  private struct MemorySample: Codable {
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let reusableBytes: UInt64
  }

  private struct LatencySummary: Codable {
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let maximumMilliseconds: Double
  }

  private struct ContinuousEditProxyResult: Codable {
    let width: Int
    let height: Int
    let sourcePayloadBytes: Int
    let retainedRendererBytes: Int
    let uncroppedRender: LatencySummary
    let croppedRender: LatencySummary
  }

  private struct TierResult: Codable {
    let name: String
    let requestedMaximumDimension: Int
    let width: Int
    let height: Int
    let sourcePayloadBytes: Int
    let retainedRendererBytes: Int
    let decodeMilliseconds: Double
    let rendererInitializationMilliseconds: Double
    let uncroppedRender: LatencySummary
    let croppedRender: LatencySummary
    let continuousEditProxy: ContinuousEditProxyResult?
    let memoryBeforeDecode: MemorySample
    let memoryAfterDecode: MemorySample
    let memoryAfterRendererInitialization: MemorySample
    let memoryAfterRenders: MemorySample
  }

  private struct Report: Codable {
    let generatedAt: String
    let hardware: String
    let input: String
    let inputSHA256: String
    let repetitions: Int
    let tiers: [TierResult]
    let memoryAfterTierRelease: MemorySample
    let note: String
  }

  @Test(
    "Measure edit rendering at draft, inspect, and full-sensor RAW tiers",
    .enabled(
      if: ProcessInfo.processInfo.environment["RUN_PREVIEW_SCALE_BENCHMARK"] == "1",
      "set RUN_PREVIEW_SCALE_BENCHMARK=1 with the local Fuji 400 corpus")
  )
  func measureRealRAWPreviewScale() throws {
    let input = SampleRawCorpus.url(relativePath: "fuji400-fresh/DSCF2833.RAF")
    try #require(FileManager.default.fileExists(atPath: input.path), "Missing local RAW fixture")
    let tiers = [
      (name: "draft", maximumDimension: 640),
      (name: "inspect", maximumDimension: 4_000),
      (name: "full-sensor", maximumDimension: 100_000),
    ]
    StillPreviewRenderer.warmUp()
    var results: [TierResult] = []
    for tier in tiers {
      results.append(
        try autoreleasepool {
          try measureTier(
            name: tier.name,
            maximumDimension: tier.maximumDimension,
            input: input)
        })
    }

    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      hardware: hardwareDescription(),
      input: "sample-raw/fuji400-fresh/DSCF2833.RAF",
      inputSHA256: try fileHash(input),
      repetitions: 3,
      tiers: results,
      memoryAfterTierRelease: memorySample(),
      note:
        "Release-mode direct StillPreviewRenderer benchmark. Each tier warms the uncropped and fixed-manual-crop paths once, then alternates their order across three exposure values. Every timed render also computes the same bounded CGImage statistics used before app publication, forcing consumption of the Core Image result. The current renderer has no viewport/zoom input, so Fit and 100% request the same source-sized surface. Publication and screen presentation are not measured. Physical footprint is a process-wide Mach ledger sample and the lifetime peak is order-dependent."
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let output = ProcessInfo.processInfo.environment["FSC_PREVIEW_SCALE_OUTPUT"] {
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    print("PREVIEW_SCALE \(String(decoding: data, as: UTF8.self))")
  }

  private func measureTier(
    name: String,
    maximumDimension: Int,
    input: URL
  ) throws -> TierResult {
    let memoryBeforeDecode = memorySample()
    let decodeStart = ContinuousClock.now
    let source = try RawImageDecoder.decode(
      input,
      profile: .rawTherapeeCameraScan,
      maxDimension: maximumDimension
    ).image
    let decodeMilliseconds = milliseconds(decodeStart.duration(to: .now))
    let memoryAfterDecode = memorySample()

    var filmNegative = FilmNegativeParams.colourNegative
    filmNegative.measuredMedians = FilmNegativeProcessing.computeMedians(image: source)
    let parameters = ProcessingParameters(
      filmType: .colourNegative,
      filmNegativeParams: filmNegative,
      photoAdjustments: .init(
        exposureEV: 0,
        brightness: 0.12,
        contrast: 0.18,
        highlights: -0.2,
        shadows: 0.15,
        temperatureShiftMired: 18,
        tint: -0.08,
        saturation: 0.1,
        vibrance: 0.2
      )
    )
    let rendererStart = ContinuousClock.now
    let renderer = try #require(StillPreviewRenderer(image: source))
    let rendererInitializationMilliseconds = milliseconds(rendererStart.duration(to: .now))
    let memoryAfterRendererInitialization = memorySample()

    var croppedParameters = parameters
    croppedParameters.manualCrop = .init(x: 0.17, y: 0.13, width: 0.63, height: 0.71)
    try #require(StillPreviewRenderer.supports(parameters: croppedParameters, showOriginal: false))
    try consumeRender(renderer: renderer, parameters: parameters)
    try consumeRender(renderer: renderer, parameters: croppedParameters)
    let measurements = try measureAlternatingRenders(
      renderer: renderer,
      uncroppedParameters: parameters,
      croppedParameters: croppedParameters,
      exposures: [-0.35, 0.0, 0.35])
    let continuousEditProxy: ContinuousEditProxyResult?
    if name == "full-sensor" {
      let proxySource = source.resizedToFit(
        maxDimension: AppModel.continuousEditPreviewMaxDimension)
      let proxyRenderer = try #require(
        StillPreviewRenderer(
          image: proxySource, analysisImage: source.resizedToFit(maxDimension: 256)))
      try consumeRender(renderer: proxyRenderer, parameters: parameters)
      try consumeRender(renderer: proxyRenderer, parameters: croppedParameters)
      let proxyMeasurements = try measureAlternatingRenders(
        renderer: proxyRenderer,
        uncroppedParameters: parameters,
        croppedParameters: croppedParameters,
        exposures: [-0.35, 0.0, 0.35])
      continuousEditProxy = ContinuousEditProxyResult(
        width: proxySource.width,
        height: proxySource.height,
        sourcePayloadBytes: proxySource.pixels.count * MemoryLayout<UInt16>.stride,
        retainedRendererBytes: proxyRenderer.retainedRGBAByteCount,
        uncroppedRender: summarize(proxyMeasurements.uncropped),
        croppedRender: summarize(proxyMeasurements.cropped))
    } else {
      continuousEditProxy = nil
    }
    let memoryAfterRenders = memorySample()

    return TierResult(
      name: name,
      requestedMaximumDimension: maximumDimension,
      width: source.width,
      height: source.height,
      sourcePayloadBytes: source.pixels.count * MemoryLayout<UInt16>.stride,
      retainedRendererBytes: renderer.retainedRGBAByteCount,
      decodeMilliseconds: decodeMilliseconds,
      rendererInitializationMilliseconds: rendererInitializationMilliseconds,
      uncroppedRender: summarize(measurements.uncropped),
      croppedRender: summarize(measurements.cropped),
      continuousEditProxy: continuousEditProxy,
      memoryBeforeDecode: memoryBeforeDecode,
      memoryAfterDecode: memoryAfterDecode,
      memoryAfterRendererInitialization: memoryAfterRendererInitialization,
      memoryAfterRenders: memoryAfterRenders)
  }

  private func measureAlternatingRenders(
    renderer: StillPreviewRenderer,
    uncroppedParameters: ProcessingParameters,
    croppedParameters: ProcessingParameters,
    exposures: [Double]
  ) throws -> (uncropped: [Double], cropped: [Double]) {
    var uncropped: [Double] = []
    var cropped: [Double] = []
    for (index, exposure) in exposures.enumerated() {
      var uncroppedSnapshot = uncroppedParameters
      uncroppedSnapshot.photoAdjustments.exposureEV = exposure
      var croppedSnapshot = croppedParameters
      croppedSnapshot.photoAdjustments.exposureEV = exposure
      let pair =
        index.isMultiple(of: 2)
        ? [(croppedSnapshot, true), (uncroppedSnapshot, false)]
        : [(uncroppedSnapshot, false), (croppedSnapshot, true)]
      for (snapshot, isCropped) in pair {
        let start = ContinuousClock.now
        try consumeRender(renderer: renderer, parameters: snapshot)
        let sample = milliseconds(start.duration(to: .now))
        if isCropped {
          cropped.append(sample)
        } else {
          uncropped.append(sample)
        }
      }
    }
    return (uncropped, cropped)
  }

  private func consumeRender(
    renderer: StillPreviewRenderer,
    parameters: ProcessingParameters
  ) throws {
    let image = try #require(renderer.render(parameters: parameters, showOriginal: false))
    _ = try #require(StillPreviewRenderer.statistics(for: image))
  }

  private func summarize(_ samples: [Double]) -> LatencySummary {
    let sorted = samples.sorted()
    return LatencySummary(
      samplesMilliseconds: samples,
      medianMilliseconds: sorted[sorted.count / 2],
      maximumMilliseconds: sorted.last ?? 0)
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
  }

  private func memorySample() -> MemorySample {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else {
      return MemorySample(
        physicalFootprintBytes: 0,
        peakPhysicalFootprintBytes: 0,
        reusableBytes: 0)
    }
    return MemorySample(
      physicalFootprintBytes: UInt64(info.phys_footprint),
      peakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak)),
      reusableBytes: UInt64(info.reusable))
  }

  private func hardwareDescription() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &bytes, &size, nil, 0)
    return String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self)
  }

  private func fileHash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
