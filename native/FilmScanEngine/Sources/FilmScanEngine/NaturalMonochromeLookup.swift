import Foundation

/// Compiles Natural B&W's integer-gray point pipeline without allocating a
/// full-image Double buffer. Call from the same render worker as the CPU path.
/// The lock serializes construction as well as LRU updates, so concurrent
/// preview/export requests cannot queue duplicate builds or grow pending state.
final class NaturalMonochromeLookupCache: @unchecked Sendable {
  static let shared = NaturalMonochromeLookupCache()

  // A fresh 65,536-entry tone table costs more than directly processing a tiny
  // preview. Start conservatively; this also bounds table work during analysis.
  static let minimumPixelCount = 1_000_000
  static let inversionCapacity = 2
  static let toneCapacity = 4

  private let lock = NSLock()
  private var inversions = BoundedTables<InversionKey>(
    capacity: NaturalMonochromeLookupCache.inversionCapacity)
  private var tones = BoundedTables<ToneKey>(capacity: NaturalMonochromeLookupCache.toneCapacity)

  static func shouldUse(image: UInt16Image, parameters: ProcessingParameters) -> Bool {
    image.width * image.height >= minimumPixelCount
      && isEligible(image: image, parameters: parameters)
  }

  static func isEligible(image: UInt16Image, parameters: ProcessingParameters) -> Bool {
    // Natural B&W ignores inherited color intent, dye mixing, RGB curves, and
    // color wheels. Build with the B&W suffix so those hidden controls remain
    // ignored. Classic/color/slide/density and single-channel inputs stay on
    // their ordinary paths. All spatial operations have already run.
    image.channels == 3
      && parameters.filmType == .blackAndWhiteNegative
      && parameters.filmNegativeParams.enabled
      && parameters.filmNegativeParams.rendering == .calibratedMonochrome
  }

  func apply(image: UInt16Image, parameters: ProcessingParameters) -> UInt16Image {
    precondition(Self.isEligible(image: image, parameters: parameters))
    let table = compiledTable(parameters: parameters)
    let source = image.pixels
    let pixelCount = image.width * image.height
    var output = [UInt16](repeating: 0, count: source.count)

    @Sendable func processPixel(_ pixelIndex: Int, output: UnsafeMutablePointer<UInt16>) {
      let base = pixelIndex * 3
      let blue = source[base]
      let green = source[base + 1]
      let red = source[base + 2]
      if max(blue, max(green, red)) <= FilmNegativeProcessing.sensorBlackThreshold {
        output[base] = .max
        output[base + 1] = .max
        output[base + 2] = .max
        return
      }
      // Keep the exact Double expression and truncation used by ordinary
      // calibrated inversion. Sensor black depends on max BGR, not this gray.
      let gray = Int(
        min(
          max(
            0.114 * Double(blue) + 0.587 * Double(green) + 0.299 * Double(red), 0), 65_535))
      let tableBase = gray * 3
      output[base] = table[tableBase]
      output[base + 1] = table[tableBase + 1]
      output[base + 2] = table[tableBase + 2]
    }

    FilmProcessing.processCorrectionPixels(
      &output, pixelCount: pixelCount, processPixel: processPixel)
    return UInt16Image(width: image.width, height: image.height, channels: 3, pixels: output)
  }

  func compiledTable(parameters: ProcessingParameters) -> [UInt16] {
    lock.lock()
    defer { lock.unlock() }
    let inversionKey = InversionKey(parameters.filmNegativeParams)
    let inversion = inversions.value(for: inversionKey) {
      FilmNegativeProcessing.calibratedMonochromeInversionLUT(
        params: parameters.filmNegativeParams)
    }
    let toneKey = ToneKey(parameters)
    let tone = tones.value(for: toneKey) {
      var ramp = [UInt16](repeating: 0, count: 65_536 * 3)
      for input in 0...65_535 {
        let base = input * 3
        ramp[base] = UInt16(input)
        ramp[base + 1] = UInt16(input)
        ramp[base + 2] = UInt16(input)
      }
      return FilmProcessing.applyDisplayPointAdjustments(
        image: UInt16Image(width: 256, height: 256, channels: 3, pixels: ramp),
        parameters: parameters
      ).pixels
    }

    // Compose after inversion's rounded UInt16 boundary. Keep three outputs:
    // Rec.2020 matrix arithmetic can round nominal gray channels differently.
    var table = [UInt16](repeating: 0, count: 65_536 * 3)
    for input in 0...65_535 {
      let from = Int(inversion[input]) * 3
      let to = input * 3
      table[to] = tone[from]
      table[to + 1] = tone[from + 1]
      table[to + 2] = tone[from + 2]
    }
    return table
  }

  struct Statistics {
    let inversionTables: Int
    let toneTables: Int
    let inversionBuilds: Int
    let toneBuilds: Int
  }

  var statistics: Statistics {
    lock.lock()
    defer { lock.unlock() }
    return Statistics(
      inversionTables: inversions.entries.count, toneTables: tones.entries.count,
      inversionBuilds: inversions.buildCount, toneBuilds: tones.buildCount)
  }

  private struct InversionKey: Equatable {
    let profile: CalibratedMonochromeProfile
    let greenMedian: Double?
    let exposureEV: Double

    init(_ parameters: FilmNegativeParams) {
      profile = parameters.calibratedMonochromeProfile
      // The current normalization reads only green. Do not invalidate the
      // inversion table for unrelated film parameters or red/blue medians.
      greenMedian = parameters.measuredMedians.map { max($0.green, 1) }
      exposureEV = parameters.monochromeExposureEV
    }
  }

  private struct ToneKey: Equatable {
    let exposureEV: Double
    let brightness: Double
    let contrast: Double
    let highlights: Double
    let shadows: Double
    let legacyGamma: Int
    let legacyHighlights: Int
    let legacyShadows: Int
    let curveEnabled: Bool
    let curve: [CurvePoint]

    init(_ parameters: ProcessingParameters) {
      let photo = parameters.photoAdjustments
      exposureEV = photo.exposureEV
      brightness = photo.brightness
      contrast = photo.contrast
      highlights = photo.highlights
      shadows = photo.shadows
      // Semantic tone suppresses the frozen legacy operators in production.
      legacyGamma = photo.hasToneAdjustment ? 0 : parameters.gamma
      legacyHighlights = photo.hasToneAdjustment ? 0 : parameters.highlights
      legacyShadows = photo.hasToneAdjustment ? 0 : parameters.shadows
      curveEnabled = parameters.curveEnabled
      curve = parameters.curveEnabled ? parameters.curveControlPoints : []
    }
  }

  private struct BoundedTables<Key: Equatable> {
    let capacity: Int
    var entries: [(key: Key, pixels: [UInt16])] = []
    var buildCount = 0

    mutating func value(for key: Key, build: () -> [UInt16]) -> [UInt16] {
      if let index = entries.firstIndex(where: { $0.key == key }) {
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.pixels
      }
      let pixels = build()
      buildCount += 1
      if entries.count == capacity { entries.removeFirst() }
      entries.append((key, pixels))
      return pixels
    }
  }
}
