import Dispatch
import Foundation

/// The requested strategy for combining repeated captures of one film frame.
public enum ScanStackMode: String, Codable, CaseIterable, Sendable {
  case automatic
  case noiseReduction
  case hdr
}

/// Errors produced while fingerprinting, registering, or combining scan captures.
public enum ScanStackError: Error, Equatable, LocalizedError, Sendable {
  case insufficientImages
  case unsupportedChannelCount(Int)
  case incompatibleDimensions(
    index: Int, expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
  case incompatibleChannels(index: Int, expected: Int, actual: Int)
  case lowTexture(index: Int)
  case alignmentFailed(index: Int, confidence: Double, overlap: Double)
  case exposureEstimationFailed(index: Int)

  public var errorDescription: String? {
    switch self {
    case .insufficientImages:
      "At least two scans are required for stacking."
    case .unsupportedChannelCount(let channels):
      "Scan stacking supports one- or three-channel images, not \(channels)-channel images."
    case .incompatibleDimensions(
      let index, let expectedWidth, let expectedHeight, let actualWidth, let actualHeight):
      "Scan \(index + 1) is \(actualWidth)x\(actualHeight), but the reference is \(expectedWidth)x\(expectedHeight)."
    case .incompatibleChannels(let index, let expected, let actual):
      "Scan \(index + 1) has \(actual) channels, but the reference has \(expected)."
    case .lowTexture(let index):
      "Scan \(index + 1) does not contain enough detail for reliable automatic alignment."
    case .alignmentFailed(let index, let confidence, let overlap):
      "Scan \(index + 1) could not be aligned reliably (confidence \(confidence), overlap \(overlap))."
    case .exposureEstimationFailed(let index):
      "Scan \(index + 1) does not have enough unclipped overlap to estimate its exposure."
    }
  }
}

/// A compact exposure-invariant representation used to compare imported scans.
///
/// The values are robustly normalized log-luminance samples. Clipped samples
/// use a sentinel and are excluded from matching, which keeps brackets useful
/// even when their shadows or highlights do not overlap completely.
public struct ScanFingerprint: Equatable, Sendable {
  public static let clippedSample = Int16.min

  public let width: Int
  public let height: Int
  public let values: [Int16]
  public let textureScore: Double

  public init(image: UInt16Image, maximumDimension: Int = 64, borderPercent: Double = 20) throws {
    guard image.channels == 1 || image.channels == 3 else {
      throw ScanStackError.unsupportedChannelCount(image.channels)
    }
    let interior = StackAnalysis.inset(image, borderPercent: borderPercent)
    let dimensions = StackAnalysis.scaledDimensions(
      width: interior.width,
      height: interior.height,
      maximumDimension: max(8, maximumDimension)
    )
    let plane = StackAnalysis.normalizedLogLuminance(
      interior,
      width: dimensions.width,
      height: dimensions.height
    )
    width = plane.width
    height = plane.height
    textureScore = plane.textureScore
    values = plane.values.map { value in
      guard let value else { return Self.clippedSample }
      let quantized = Int((min(max(value, -4), 4) * 4_096).rounded())
      return Int16(clamping: quantized)
    }
  }
}

/// The result of comparing two exposure-invariant fingerprints.
public struct SameNegativeMatch: Equatable, Sendable {
  public let isMatch: Bool
  /// Correlation-derived confidence in `0...1`.
  public let confidence: Double
  /// Offset into the right-hand fingerprint for a sample in the left-hand one.
  public let translationX: Int
  public let translationY: Int
  public let overlap: Double

  public init(
    isMatch: Bool,
    confidence: Double,
    translationX: Int,
    translationY: Int,
    overlap: Double
  ) {
    self.isMatch = isMatch
    self.confidence = confidence
    self.translationX = translationX
    self.translationY = translationY
    self.overlap = overlap
  }
}

/// Exposure-invariant matching and conservative grouping for adjacent imports.
public enum SameNegativeDetector {
  public static func match(
    _ reference: ScanFingerprint,
    _ candidate: ScanFingerprint,
    minimumConfidence: Double = 0.92
  ) -> SameNegativeMatch {
    guard reference.width == candidate.width,
      reference.height == candidate.height,
      min(reference.textureScore, candidate.textureScore) >= 0.08
    else {
      return SameNegativeMatch(
        isMatch: false,
        confidence: 0,
        translationX: 0,
        translationY: 0,
        overlap: 0)
    }

    let maximumShift = max(
      2, Int((Double(min(reference.width, reference.height)) * 0.10).rounded()))
    let search = StackAnalysis.searchFingerprintTranslation(
      reference: reference,
      candidate: candidate,
      centerX: 0,
      centerY: 0,
      radiusX: maximumShift,
      radiusY: maximumShift
    )
    let confidence = StackAnalysis.registrationConfidence(
      correlation: search.correlation,
      peakGap: search.peakGap,
      overlap: search.overlap)
    let accepted =
      search.correlation >= 0.88
      && search.overlap >= 0.78
      && search.peakGap >= 0.008
      && confidence >= min(max(minimumConfidence, 0), 1)
    return SameNegativeMatch(
      isMatch: accepted,
      confidence: confidence,
      translationX: search.translationX,
      translationY: search.translationY,
      overlap: search.overlap)
  }

  /// Partitions import-ordered fingerprints into contiguous groups.
  ///
  /// Every additional member must match the first fingerprint in its current
  /// group. This avoids false groups caused by transitive A≈B≈C chaining.
  public static func groupAdjacent(
    _ fingerprints: [ScanFingerprint],
    minimumConfidence: Double = 0.92
  ) -> [[Int]] {
    guard !fingerprints.isEmpty else { return [] }
    var groups: [[Int]] = [[0]]
    for index in fingerprints.indices.dropFirst() {
      let anchor = groups[groups.count - 1][0]
      if match(
        fingerprints[anchor],
        fingerprints[index],
        minimumConfidence: minimumConfidence
      ).isMatch {
        groups[groups.count - 1].append(index)
      } else {
        groups.append([index])
      }
    }
    return groups
  }
}

/// Integer translation that maps a reference pixel to a source scan pixel.
public struct ScanStackAlignment: Codable, Equatable, Sendable {
  public let translationX: Int
  public let translationY: Int
  public let confidence: Double
  public let overlap: Double

  public init(
    translationX: Int,
    translationY: Int,
    confidence: Double,
    overlap: Double
  ) {
    self.translationX = translationX
    self.translationY = translationY
    self.confidence = confidence
    self.overlap = overlap
  }
}

/// The composite and diagnostics produced by `MultiScanStacker`.
public struct MultiScanStackResult: Equatable, Sendable {
  public let image: UInt16Image
  public let effectiveMode: ScanStackMode
  public let alignments: [ScanStackAlignment]
  /// Relative linear exposure in stops versus the first image. Positive is brighter.
  public let exposureOffsetsEV: [Double]

  public init(
    image: UInt16Image,
    effectiveMode: ScanStackMode,
    alignments: [ScanStackAlignment],
    exposureOffsetsEV: [Double]
  ) {
    self.image = image
    self.effectiveMode = effectiveMode
    self.alignments = alignments
    self.exposureOffsetsEV = exposureOffsetsEV
  }
}

/// Registers and combines repeated captures of a static film negative.
public enum MultiScanStacker {
  /// Combines images in the first image's coordinate system and exposure.
  ///
  /// The engine's `UInt16Image` contract is display-encoded sRGB. Stacking is
  /// performed after inverse-sRGB linearization and encoded back to that same
  /// contract so the existing film-inversion pipeline can process the result.
  public static func combine(
    images: [UInt16Image],
    mode: ScanStackMode = .automatic
  ) throws -> MultiScanStackResult {
    guard images.count >= 2 else { throw ScanStackError.insufficientImages }
    let reference = images[0]
    let referencePlanes = try StackAnalysis.prepareReference(reference)
    var alignments = [
      ScanStackAlignment(translationX: 0, translationY: 0, confidence: 1, overlap: 1)
    ]
    var exposureOffsetsEV = [0.0]
    for index in images.indices.dropFirst() {
      let registration = try StackAnalysis.registration(
        reference: reference, candidate: images[index], index: index,
        referencePlanes: referencePlanes)
      alignments.append(registration.alignment)
      exposureOffsetsEV.append(registration.exposureEV)
    }

    let effectiveMode = StackAnalysis.effectiveMode(mode, exposureOffsetsEV: exposureOffsetsEV)

    let combined = try StackAnalysis.merge(
      images: images,
      alignments: alignments,
      exposureOffsetsEV: exposureOffsetsEV,
      mode: effectiveMode)
    return MultiScanStackResult(
      image: combined,
      effectiveMode: effectiveMode,
      alignments: alignments,
      exposureOffsetsEV: exposureOffsetsEV)
  }

  /// Loads captures sequentially and merges their original samples in bounded
  /// row bands. Temporary storage is removed on success, failure, or cancellation.
  public static func combine(
    imageCount: Int,
    mode: ScanStackMode = .automatic,
    loadImage: @Sendable (Int) async throws -> UInt16Image
  ) async throws -> MultiScanStackResult {
    guard imageCount >= 2 else { throw ScanStackError.insufficientImages }
    let stored = try StoredScanStack()
    for index in 0..<imageCount {
      try Task.checkCancellation()
      let image = try await loadImage(index)
      try Task.checkCancellation()
      try stored.append(image)
    }
    return try stored.finish(mode: mode)
  }

}

private enum StackTransfer {
  static let encodedToLinear: [Double] = (0...Int(UInt16.max)).map { encoded in
    let value = Double(encoded) / Double(UInt16.max)
    return value <= 0.04045
      ? value / 12.92
      : pow((value + 0.055) / 1.055, 2.4)
  }

  static let linearToEncoded: [UInt16] = (0...Int(UInt16.max)).map { linearIndex in
    let linear = Double(linearIndex) / Double(UInt16.max)
    let encoded =
      linear <= 0.003_130_8
      ? linear * 12.92
      : 1.055 * pow(linear, 1 / 2.4) - 0.055
    return UInt16((min(max(encoded, 0), 1) * Double(UInt16.max)).rounded())
  }

  static func decode(_ value: UInt16) -> Double {
    encodedToLinear[Int(value)]
  }

  static func encode(_ value: Double) -> UInt16 {
    let index = Int((min(max(value, 0), 1) * Double(UInt16.max)).rounded())
    return linearToEncoded[index]
  }
}

enum StackAnalysis {
  static let mergeParallelPixelThreshold = 100_000

  struct NormalizedPlane: Sendable {
    let width: Int
    let height: Int
    let values: [Double?]
    let center: Double
    let scale: Double
    let textureScore: Double
  }

  struct Pyramid: Sendable {
    let coarse: NormalizedPlane
    let fine: NormalizedPlane
  }

  struct TranslationSearch {
    let translationX: Int
    let translationY: Int
    let correlation: Double
    let overlap: Double
    let peakGap: Double
  }

  struct MergeSource: Sendable {
    let pixels: [UInt16]
    let rowOffset: Int
    let translationX: Int
    let translationY: Int
    let inverseExposureScale: Double
  }

  final class MergeCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func shouldStop() -> Bool {
      let taskCancelled = Task.isCancelled
      lock.lock()
      if taskCancelled { stopped = true }
      let result = stopped
      lock.unlock()
      return result
    }
  }

  static func prepareReference(_ image: UInt16Image) throws -> Pyramid {
    guard image.channels == 1 || image.channels == 3 else {
      throw ScanStackError.unsupportedChannelCount(image.channels)
    }
    let planes = registrationPyramid(for: image)
    guard planes.coarse.textureScore >= 0.08 else {
      throw ScanStackError.lowTexture(index: 0)
    }
    return planes
  }

  static func registration(
    reference: UInt16Image, candidate: UInt16Image, index: Int,
    referencePlanes: Pyramid
  ) throws -> (alignment: ScanStackAlignment, exposureEV: Double) {
    try Task.checkCancellation()
    guard candidate.width == reference.width, candidate.height == reference.height else {
      throw ScanStackError.incompatibleDimensions(
        index: index, expectedWidth: reference.width, expectedHeight: reference.height,
        actualWidth: candidate.width, actualHeight: candidate.height)
    }
    guard candidate.channels == reference.channels else {
      throw ScanStackError.incompatibleChannels(
        index: index, expected: reference.channels, actual: candidate.channels)
    }
    let candidatePlanes = registrationPyramid(for: candidate)
    guard candidatePlanes.coarse.textureScore >= 0.08 else {
      throw ScanStackError.lowTexture(index: index)
    }
    let alignment = registerTranslation(
      reference: reference, candidate: candidate,
      referencePlanes: referencePlanes, candidatePlanes: candidatePlanes)
    guard alignment.confidence >= 0.72, alignment.overlap >= 0.80 else {
      throw ScanStackError.alignmentFailed(
        index: index, confidence: alignment.confidence, overlap: alignment.overlap)
    }
    guard
      let exposureEV = exposureOffsetEV(
        reference: reference, candidate: candidate, alignment: alignment)
    else { throw ScanStackError.exposureEstimationFailed(index: index) }
    return (alignment, exposureEV)
  }

  static func effectiveMode(_ mode: ScanStackMode, exposureOffsetsEV: [Double]) -> ScanStackMode {
    guard mode == .automatic else { return mode }
    let spread = (exposureOffsetsEV.max() ?? 0) - (exposureOffsetsEV.min() ?? 0)
    return spread >= 0.5 ? .hdr : .noiseReduction
  }

  static func inset(_ image: UInt16Image, borderPercent: Double) -> UInt16Image {
    let fraction = min(max(borderPercent, 0), 40) / 100
    let insetX = min(
      Int((Double(image.width) * fraction).rounded()),
      max(image.width / 2 - 1, 0))
    let insetY = min(
      Int((Double(image.height) * fraction).rounded()),
      max(image.height / 2 - 1, 0))
    let width = max(1, image.width - insetX * 2)
    let height = max(1, image.height - insetY * 2)
    guard width != image.width || height != image.height else { return image }

    var pixels = [UInt16](repeating: 0, count: width * height * image.channels)
    for y in 0..<height {
      let sourceStart = ((y + insetY) * image.width + insetX) * image.channels
      let destinationStart = y * width * image.channels
      let count = width * image.channels
      pixels.replaceSubrange(
        destinationStart..<(destinationStart + count),
        with: image.pixels[sourceStart..<(sourceStart + count)])
    }
    return UInt16Image(
      width: width, height: height, channels: image.channels, pixels: pixels)
  }

  static func scaledDimensions(
    width: Int,
    height: Int,
    maximumDimension: Int
  ) -> (width: Int, height: Int) {
    let largest = max(width, height)
    guard largest > maximumDimension else { return (width, height) }
    let scale = Double(maximumDimension) / Double(largest)
    return (
      max(1, Int((Double(width) * scale).rounded())),
      max(1, Int((Double(height) * scale).rounded()))
    )
  }

  static func registrationPyramid(for image: UInt16Image) -> Pyramid {
    let coarseDimensions = scaledDimensions(
      width: image.width, height: image.height, maximumDimension: 128)
    let fineDimensions = scaledDimensions(
      width: image.width, height: image.height, maximumDimension: 512)
    return Pyramid(
      coarse: normalizedLogLuminance(
        image, width: coarseDimensions.width, height: coarseDimensions.height),
      fine: normalizedLogLuminance(
        image, width: fineDimensions.width, height: fineDimensions.height))
  }

  static func normalizedLogLuminance(
    _ image: UInt16Image,
    width: Int,
    height: Int
  ) -> NormalizedPlane {
    var logs = [Double?](repeating: nil, count: width * height)
    var usable = [Double]()
    usable.reserveCapacity(width * height)
    for y in 0..<height {
      for x in 0..<width {
        let luminance = sampledLinearLuminance(
          image,
          outputX: x,
          outputY: y,
          outputWidth: width,
          outputHeight: height)
        guard luminance > 0.001, luminance < 0.995 else { continue }
        let value = log2(luminance)
        logs[y * width + x] = value
        usable.append(value)
      }
    }
    let center = median(usable) ?? 0
    let deviations = usable.map { abs($0 - center) }
    let mad = median(deviations) ?? 0
    let sorted = usable.sorted()
    let q1 = percentile(sorted, fraction: 0.25) ?? center
    let q3 = percentile(sorted, fraction: 0.75) ?? center
    let scale = max(mad * 1.4826, (q3 - q1) / 1.349, 0.000_1)
    let normalized = logs.map { $0.map { min(max(($0 - center) / scale, -6), 6) } }
    let texture = normalizedTexture(normalized, width: width, height: height)
    return NormalizedPlane(
      width: width,
      height: height,
      values: normalized,
      center: center,
      scale: scale,
      textureScore: texture)
  }

  static func sampledLinearLuminance(
    _ image: UInt16Image,
    outputX: Int,
    outputY: Int,
    outputWidth: Int,
    outputHeight: Int
  ) -> Double {
    let startX = Double(outputX) * Double(image.width) / Double(outputWidth)
    let endX = Double(outputX + 1) * Double(image.width) / Double(outputWidth)
    let startY = Double(outputY) * Double(image.height) / Double(outputHeight)
    let endY = Double(outputY + 1) * Double(image.height) / Double(outputHeight)
    var sum = 0.0
    var count = 0
    // A bounded 4x4 stratified sample keeps fingerprint cost independent of
    // the source resolution while remaining deterministic.
    for sampleY in 0..<4 {
      let fy = startY + (Double(sampleY) + 0.5) * (endY - startY) / 4
      let sourceY = min(image.height - 1, max(0, Int(fy)))
      for sampleX in 0..<4 {
        let fx = startX + (Double(sampleX) + 0.5) * (endX - startX) / 4
        let sourceX = min(image.width - 1, max(0, Int(fx)))
        sum += linearLuminance(image, x: sourceX, y: sourceY)
        count += 1
      }
    }
    return sum / Double(count)
  }

  static func linearLuminance(_ image: UInt16Image, x: Int, y: Int) -> Double {
    let base = (y * image.width + x) * image.channels
    if image.channels == 1 {
      return StackTransfer.decode(image.pixels[base])
    }
    let blue = StackTransfer.decode(image.pixels[base])
    let green = StackTransfer.decode(image.pixels[base + 1])
    let red = StackTransfer.decode(image.pixels[base + 2])
    return 0.0722 * blue + 0.7152 * green + 0.2126 * red
  }

  static func normalizedTexture(
    _ values: [Double?],
    width: Int,
    height: Int
  ) -> Double {
    guard width > 1, height > 1 else { return 0 }
    var squaredGradient = 0.0
    var count = 0
    for y in 0..<height {
      for x in 0..<width {
        guard let value = values[y * width + x] else { continue }
        if x + 1 < width, let right = values[y * width + x + 1] {
          let difference = value - right
          squaredGradient += difference * difference
          count += 1
        }
        if y + 1 < height, let below = values[(y + 1) * width + x] {
          let difference = value - below
          squaredGradient += difference * difference
          count += 1
        }
      }
    }
    return count == 0 ? 0 : sqrt(squaredGradient / Double(count))
  }

  static func searchFingerprintTranslation(
    reference: ScanFingerprint,
    candidate: ScanFingerprint,
    centerX: Int,
    centerY: Int,
    radiusX: Int,
    radiusY: Int
  ) -> TranslationSearch {
    var best = TranslationSearch(
      translationX: 0, translationY: 0, correlation: -1, overlap: 0, peakGap: 0)
    var second = -1.0
    for dy in (centerY - radiusY)...(centerY + radiusY) {
      for dx in (centerX - radiusX)...(centerX + radiusX) {
        let score = fingerprintCorrelation(reference, candidate, dx: dx, dy: dy)
        if score.correlation > best.correlation {
          second = best.correlation
          best = TranslationSearch(
            translationX: dx,
            translationY: dy,
            correlation: score.correlation,
            overlap: score.overlap,
            peakGap: 0)
        } else if score.correlation > second {
          second = score.correlation
        }
      }
    }
    return TranslationSearch(
      translationX: best.translationX,
      translationY: best.translationY,
      correlation: best.correlation,
      overlap: best.overlap,
      peakGap: max(0, best.correlation - second))
  }

  static func fingerprintCorrelation(
    _ reference: ScanFingerprint,
    _ candidate: ScanFingerprint,
    dx: Int,
    dy: Int
  ) -> (correlation: Double, overlap: Double) {
    var pairs: [(Double, Double)] = []
    pairs.reserveCapacity(reference.width * reference.height)
    let minimumX = max(0, -dx)
    let maximumX = min(reference.width, candidate.width - dx)
    let minimumY = max(0, -dy)
    let maximumY = min(reference.height, candidate.height - dy)
    guard minimumX < maximumX, minimumY < maximumY else { return (-1, 0) }
    for y in minimumY..<maximumY {
      for x in minimumX..<maximumX {
        let left = reference.values[y * reference.width + x]
        let right = candidate.values[(y + dy) * candidate.width + x + dx]
        guard left != ScanFingerprint.clippedSample,
          right != ScanFingerprint.clippedSample
        else { continue }
        pairs.append((Double(left), Double(right)))
      }
    }
    let geometricOverlap =
      Double((maximumX - minimumX) * (maximumY - minimumY))
      / Double(reference.width * reference.height)
    guard pairs.count >= max(32, reference.width * reference.height / 5) else {
      return (-1, geometricOverlap)
    }
    return (pearsonCorrelation(pairs), geometricOverlap)
  }

  static func registerTranslation(
    reference: UInt16Image,
    candidate: UInt16Image,
    referencePlanes: Pyramid,
    candidatePlanes: Pyramid
  ) -> ScanStackAlignment {
    let coarseRadius = max(
      2,
      Int(
        (Double(min(referencePlanes.coarse.width, referencePlanes.coarse.height)) * 0.08).rounded())
    )
    let coarse = searchPlaneTranslation(
      reference: referencePlanes.coarse,
      candidate: candidatePlanes.coarse,
      centerX: 0,
      centerY: 0,
      radiusX: coarseRadius,
      radiusY: coarseRadius)
    let predictedFineX = Int(
      (Double(coarse.translationX) * Double(referencePlanes.fine.width)
        / Double(referencePlanes.coarse.width)).rounded())
    let predictedFineY = Int(
      (Double(coarse.translationY) * Double(referencePlanes.fine.height)
        / Double(referencePlanes.coarse.height)).rounded())
    let fine = searchPlaneTranslation(
      reference: referencePlanes.fine,
      candidate: candidatePlanes.fine,
      centerX: predictedFineX,
      centerY: predictedFineY,
      radiusX: 4,
      radiusY: 4)

    let predictedFullX = Int(
      (Double(fine.translationX) * Double(reference.width)
        / Double(referencePlanes.fine.width)).rounded())
    let predictedFullY = Int(
      (Double(fine.translationY) * Double(reference.height)
        / Double(referencePlanes.fine.height)).rounded())
    let refinementRadiusX = max(
      2, Int(ceil(Double(reference.width) / Double(referencePlanes.fine.width) / 2)) + 1)
    let refinementRadiusY = max(
      2, Int(ceil(Double(reference.height) / Double(referencePlanes.fine.height) / 2)) + 1)
    let full = searchDirectTranslation(
      reference: reference,
      candidate: candidate,
      referenceNormalization: referencePlanes.fine,
      candidateNormalization: candidatePlanes.fine,
      centerX: predictedFullX,
      centerY: predictedFullY,
      radiusX: refinementRadiusX,
      radiusY: refinementRadiusY)
    return ScanStackAlignment(
      translationX: full.translationX,
      translationY: full.translationY,
      confidence: registrationConfidence(
        correlation: full.correlation,
        peakGap: full.peakGap,
        overlap: full.overlap),
      overlap: full.overlap)
  }

  static func searchPlaneTranslation(
    reference: NormalizedPlane,
    candidate: NormalizedPlane,
    centerX: Int,
    centerY: Int,
    radiusX: Int,
    radiusY: Int
  ) -> TranslationSearch {
    var best = TranslationSearch(
      translationX: centerX,
      translationY: centerY,
      correlation: -1,
      overlap: 0,
      peakGap: 0)
    var second = -1.0
    for dy in (centerY - radiusY)...(centerY + radiusY) {
      for dx in (centerX - radiusX)...(centerX + radiusX) {
        let score = planeCorrelation(reference, candidate, dx: dx, dy: dy)
        if score.correlation > best.correlation {
          second = best.correlation
          best = TranslationSearch(
            translationX: dx,
            translationY: dy,
            correlation: score.correlation,
            overlap: score.overlap,
            peakGap: 0)
        } else if score.correlation > second {
          second = score.correlation
        }
      }
    }
    return TranslationSearch(
      translationX: best.translationX,
      translationY: best.translationY,
      correlation: best.correlation,
      overlap: best.overlap,
      peakGap: max(0, best.correlation - second))
  }

  static func planeCorrelation(
    _ reference: NormalizedPlane,
    _ candidate: NormalizedPlane,
    dx: Int,
    dy: Int
  ) -> (correlation: Double, overlap: Double) {
    let minimumX = max(0, -dx)
    let maximumX = min(reference.width, candidate.width - dx)
    let minimumY = max(0, -dy)
    let maximumY = min(reference.height, candidate.height - dy)
    guard minimumX < maximumX, minimumY < maximumY else { return (-1, 0) }
    var pairs: [(Double, Double)] = []
    pairs.reserveCapacity((maximumX - minimumX) * (maximumY - minimumY))
    for y in minimumY..<maximumY {
      for x in minimumX..<maximumX {
        guard let left = reference.values[y * reference.width + x],
          let right = candidate.values[(y + dy) * candidate.width + x + dx]
        else { continue }
        pairs.append((left, right))
      }
    }
    let overlap =
      Double((maximumX - minimumX) * (maximumY - minimumY))
      / Double(reference.width * reference.height)
    guard pairs.count >= max(64, reference.width * reference.height / 5) else {
      return (-1, overlap)
    }
    return (pearsonCorrelation(pairs), overlap)
  }

  static func searchDirectTranslation(
    reference: UInt16Image,
    candidate: UInt16Image,
    referenceNormalization: NormalizedPlane,
    candidateNormalization: NormalizedPlane,
    centerX: Int,
    centerY: Int,
    radiusX: Int,
    radiusY: Int
  ) -> TranslationSearch {
    var best = TranslationSearch(
      translationX: centerX,
      translationY: centerY,
      correlation: -1,
      overlap: 0,
      peakGap: 0)
    var second = -1.0
    let samplingStep = max(1, min(reference.width, reference.height) / 192)
    for dy in (centerY - radiusY)...(centerY + radiusY) {
      for dx in (centerX - radiusX)...(centerX + radiusX) {
        let score = directCorrelation(
          reference,
          candidate,
          dx: dx,
          dy: dy,
          samplingStep: samplingStep,
          referenceNormalization: referenceNormalization,
          candidateNormalization: candidateNormalization)
        if score.correlation > best.correlation {
          second = best.correlation
          best = TranslationSearch(
            translationX: dx,
            translationY: dy,
            correlation: score.correlation,
            overlap: score.overlap,
            peakGap: 0)
        } else if score.correlation > second {
          second = score.correlation
        }
      }
    }
    return TranslationSearch(
      translationX: best.translationX,
      translationY: best.translationY,
      correlation: best.correlation,
      overlap: best.overlap,
      peakGap: max(0, best.correlation - second))
  }

  static func directCorrelation(
    _ reference: UInt16Image,
    _ candidate: UInt16Image,
    dx: Int,
    dy: Int,
    samplingStep: Int,
    referenceNormalization: NormalizedPlane,
    candidateNormalization: NormalizedPlane
  ) -> (correlation: Double, overlap: Double) {
    let minimumX = max(0, -dx)
    let maximumX = min(reference.width, candidate.width - dx)
    let minimumY = max(0, -dy)
    let maximumY = min(reference.height, candidate.height - dy)
    guard minimumX < maximumX, minimumY < maximumY else { return (-1, 0) }
    var pairs: [(Double, Double)] = []
    for y in stride(from: minimumY, to: maximumY, by: samplingStep) {
      for x in stride(from: minimumX, to: maximumX, by: samplingStep) {
        let left = linearLuminance(reference, x: x, y: y)
        let right = linearLuminance(candidate, x: x + dx, y: y + dy)
        guard left > 0.001, left < 0.995, right > 0.001, right < 0.995 else { continue }
        pairs.append(
          (
            min(
              max((log2(left) - referenceNormalization.center) / referenceNormalization.scale, -6),
              6),
            min(
              max((log2(right) - candidateNormalization.center) / candidateNormalization.scale, -6),
              6)
          ))
      }
    }
    let overlap =
      Double((maximumX - minimumX) * (maximumY - minimumY))
      / Double(reference.width * reference.height)
    guard pairs.count >= 64 else { return (-1, overlap) }
    return (pearsonCorrelation(pairs), overlap)
  }

  static func registrationConfidence(
    correlation: Double,
    peakGap: Double,
    overlap: Double
  ) -> Double {
    guard correlation.isFinite, correlation > 0 else { return 0 }
    let correlationScore = min(max(correlation, 0), 1)
    let overlapScore = min(max((overlap - 0.65) / 0.35, 0), 1)
    // Neighboring integer shifts naturally have similar scores on photographs;
    // use peak separation as a small ambiguity guard, not the primary metric.
    let peakScore = min(max(peakGap / 0.02, 0), 1)
    return min(
      max(
        correlationScore
          * (0.95 + 0.05 * peakScore)
          * (0.95 + 0.05 * overlapScore),
        0),
      1)
  }

  static func exposureOffsetEV(
    reference: UInt16Image,
    candidate: UInt16Image,
    alignment: ScanStackAlignment
  ) -> Double? {
    let dx = alignment.translationX
    let dy = alignment.translationY
    let minimumX = max(0, -dx)
    let maximumX = min(reference.width, candidate.width - dx)
    let minimumY = max(0, -dy)
    let maximumY = min(reference.height, candidate.height - dy)
    guard minimumX < maximumX, minimumY < maximumY else { return nil }
    let step = max(1, min(reference.width, reference.height) / 256)
    var offsets: [Double] = []
    offsets.reserveCapacity(((maximumX - minimumX) / step) * ((maximumY - minimumY) / step))
    for y in stride(from: minimumY, to: maximumY, by: step) {
      for x in stride(from: minimumX, to: maximumX, by: step) {
        let left = linearLuminance(reference, x: x, y: y)
        let right = linearLuminance(candidate, x: x + dx, y: y + dy)
        guard left > 0.01, left < 0.90, right > 0.01, right < 0.90 else { continue }
        offsets.append(log2(right / left))
      }
    }
    guard offsets.count >= 64, let result = median(offsets), result.isFinite else { return nil }
    return result
  }

  static func merge(
    images: [UInt16Image],
    alignments: [ScanStackAlignment],
    exposureOffsetsEV: [Double],
    mode: ScanStackMode
  ) throws -> UInt16Image {
    try Task.checkCancellation()
    let reference = images[0]
    let width = reference.width
    let height = reference.height
    let channels = reference.channels
    var preparedSources: [MergeSource] = []
    preparedSources.reserveCapacity(images.count)
    for index in images.indices {
      preparedSources.append(
        MergeSource(
          pixels: images[index].pixels,
          rowOffset: 0,
          translationX: alignments[index].translationX,
          translationY: alignments[index].translationY,
          inverseExposureScale: pow(2, -exposureOffsetsEV[index])
        ))
    }
    let pixels = try mergeRows(
      width: width, height: height, channels: channels,
      rows: 0..<height, sources: preparedSources, mode: mode)
    return UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
  }

  static func mergeRows(
    width: Int, height: Int, channels: Int, rows: Range<Int>,
    sources: [MergeSource], mode: ScanStackMode
  ) throws -> [UInt16] {
    try Task.checkCancellation()
    let pixelCount = width * rows.count
    // Initialize the transfer tables before workers race to use their lazy
    // storage for the first time.
    _ = StackTransfer.decode(0)
    _ = StackTransfer.encode(0)

    var output = [UInt16](repeating: 0, count: pixelCount * channels)
    let cancellation = MergeCancellationState()

    @Sendable func processRow(_ y: Int, output: UnsafeMutablePointer<UInt16>) -> Bool {
      guard !cancellation.shouldStop() else { return false }
      let destinationRow = (y - rows.lowerBound) * width * channels
      for x in 0..<width {
        let destinationBase = destinationRow + x * channels
        for channel in 0..<channels {
          var fallbackCount = 0
          var fallbackSum = 0.0
          var fallbackSumSquares = 0.0
          var fallbackMinimum = Double.infinity
          var fallbackMaximum = -Double.infinity

          var sampleCount = 0
          var sampleSum = 0.0
          var sampleSumSquares = 0.0
          var sampleMinimum = Double.infinity
          var sampleMaximum = -Double.infinity

          var weightedSum = 0.0
          var weightedSumSquares = 0.0
          var weightSum = 0.0
          var minimumWeight = 0.0
          var maximumWeight = 0.0

          for source in sources {
            let sourceX = x + source.translationX
            let sourceY = y + source.translationY
            guard sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height else {
              continue
            }
            let sourceBase = ((sourceY - source.rowOffset) * width + sourceX) * channels
            let original = StackTransfer.decode(source.pixels[sourceBase + channel])
            let normalized = original * source.inverseExposureScale

            fallbackCount += 1
            fallbackSum += normalized
            fallbackSumSquares += normalized * normalized
            fallbackMinimum = min(fallbackMinimum, normalized)
            fallbackMaximum = max(fallbackMaximum, normalized)

            switch mode {
            case .noiseReduction:
              guard original > 0.000_01, original < 0.999_9 else { continue }
              sampleCount += 1
              sampleSum += normalized
              sampleSumSquares += normalized * normalized
              sampleMinimum = min(sampleMinimum, normalized)
              sampleMaximum = max(sampleMaximum, normalized)

            case .hdr:
              let shadowWeight = min(1, original / 0.04)
              let highlightWeight = min(1, (1 - original) / 0.08)
              let weight = max(0, min(shadowWeight, highlightWeight))
              guard weight > 0 else { continue }
              sampleCount += 1
              weightedSum += normalized * weight
              weightedSumSquares += normalized * normalized * weight
              weightSum += weight
              if normalized < sampleMinimum {
                sampleMinimum = normalized
                minimumWeight = weight
              }
              if normalized > sampleMaximum {
                sampleMaximum = normalized
                maximumWeight = weight
              }

            case .automatic:
              preconditionFailure("Automatic mode must be resolved before merging")
            }
          }

          let merged: Double
          switch mode {
          case .noiseReduction:
            if sampleCount > 0 {
              merged = robustScalarMean(
                count: sampleCount,
                sum: sampleSum,
                sumSquares: sampleSumSquares,
                minimum: sampleMinimum,
                maximum: sampleMaximum)
            } else {
              merged = robustScalarMean(
                count: fallbackCount,
                sum: fallbackSum,
                sumSquares: fallbackSumSquares,
                minimum: fallbackMinimum,
                maximum: fallbackMaximum)
            }

          case .hdr:
            if sampleCount > 0, weightSum > 0 {
              merged = weightedRobustScalarMean(
                count: sampleCount,
                weightedSum: weightedSum,
                weightedSumSquares: weightedSumSquares,
                weightSum: weightSum,
                minimum: sampleMinimum,
                minimumWeight: minimumWeight,
                maximum: sampleMaximum,
                maximumWeight: maximumWeight)
            } else {
              merged = robustScalarMean(
                count: fallbackCount,
                sum: fallbackSum,
                sumSquares: fallbackSumSquares,
                minimum: fallbackMinimum,
                maximum: fallbackMaximum)
            }

          case .automatic:
            preconditionFailure("Automatic mode must be resolved before merging")
          }
          output[destinationBase + channel] = StackTransfer.encode(merged)
        }
      }
      return true
    }

    let workerCount = min(8, ProcessInfo.processInfo.activeProcessorCount)
    output.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      if pixelCount >= mergeParallelPixelThreshold, workerCount > 1 {
        let sendableBuffer = SendableMutableBuffer(baseAddress)
        let rowsPerWorker = (rows.count + workerCount - 1) / workerCount
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
          guard !cancellation.shouldStop() else { return }
          let start = rows.lowerBound + worker * rowsPerWorker
          let end = min(start + rowsPerWorker, rows.upperBound)
          guard start < end else { return }
          for y in start..<end {
            guard processRow(y, output: sendableBuffer.baseAddress) else { return }
          }
        }
      } else {
        for y in rows {
          guard processRow(y, output: baseAddress) else { return }
        }
      }
    }
    guard !cancellation.shouldStop() else { throw CancellationError() }
    return output
  }

  static func robustScalarMean(
    count: Int,
    sum: Double,
    sumSquares: Double,
    minimum: Double,
    maximum: Double
  ) -> Double {
    guard count > 0 else { return 0 }
    guard count >= 3 else { return sum / Double(count) }

    let minimumScore = scalarOutlierScore(
      candidate: minimum,
      count: count,
      sum: sum,
      sumSquares: sumSquares)
    let maximumScore = scalarOutlierScore(
      candidate: maximum,
      count: count,
      sum: sum,
      sumSquares: sumSquares)
    let outlier = maximumScore > minimumScore ? maximum : minimum
    guard max(minimumScore, maximumScore) > 1 else {
      return sum / Double(count)
    }
    return (sum - outlier) / Double(count - 1)
  }

  static func scalarOutlierScore(
    candidate: Double,
    count: Int,
    sum: Double,
    sumSquares: Double
  ) -> Double {
    let remainingCount = count - 1
    guard remainingCount > 0 else { return 0 }
    let remainingSum = sum - candidate
    let remainingMean = remainingSum / Double(remainingCount)
    let residualSquares = max(
      0,
      sumSquares - candidate * candidate
        - remainingSum * remainingSum / Double(remainingCount))
    let residualDeviation =
      remainingCount > 1
      ? sqrt(residualSquares / Double(remainingCount - 1))
      : 0
    let noiseFloor = max(
      8 / Double(UInt16.max),
      0.01 * max(abs(remainingMean), 0.02))
    let threshold = max(4.5 * residualDeviation, noiseFloor)
    return abs(candidate - remainingMean) / threshold
  }

  static func weightedRobustScalarMean(
    count: Int,
    weightedSum: Double,
    weightedSumSquares: Double,
    weightSum: Double,
    minimum: Double,
    minimumWeight: Double,
    maximum: Double,
    maximumWeight: Double
  ) -> Double {
    guard weightSum > 0 else { return 0 }
    guard count >= 3 else { return weightedSum / weightSum }

    let minimumScore = weightedScalarOutlierScore(
      candidate: minimum,
      candidateWeight: minimumWeight,
      weightedSum: weightedSum,
      weightedSumSquares: weightedSumSquares,
      weightSum: weightSum)
    let maximumScore = weightedScalarOutlierScore(
      candidate: maximum,
      candidateWeight: maximumWeight,
      weightedSum: weightedSum,
      weightedSumSquares: weightedSumSquares,
      weightSum: weightSum)
    let useMaximum = maximumScore > minimumScore
    guard max(minimumScore, maximumScore) > 1 else {
      return weightedSum / weightSum
    }
    let outlier = useMaximum ? maximum : minimum
    let outlierWeight = useMaximum ? maximumWeight : minimumWeight
    let remainingWeight = weightSum - outlierWeight
    guard remainingWeight > 1e-12 else { return weightedSum / weightSum }
    return (weightedSum - outlier * outlierWeight) / remainingWeight
  }

  static func weightedScalarOutlierScore(
    candidate: Double,
    candidateWeight: Double,
    weightedSum: Double,
    weightedSumSquares: Double,
    weightSum: Double
  ) -> Double {
    let remainingWeight = weightSum - candidateWeight
    guard candidateWeight > 0, remainingWeight > 1e-12 else { return 0 }
    let remainingSum = weightedSum - candidate * candidateWeight
    let remainingMean = remainingSum / remainingWeight
    let remainingSquares = weightedSumSquares - candidate * candidate * candidateWeight
    let variance = max(0, remainingSquares / remainingWeight - remainingMean * remainingMean)
    let noiseFloor = max(
      2 / Double(UInt16.max),
      0.01 * max(abs(remainingMean), 0.02))
    let threshold = max(4.5 * sqrt(variance), noiseFloor)
    return abs(candidate - remainingMean) / threshold
  }

  static func pearsonCorrelation(_ pairs: [(Double, Double)]) -> Double {
    guard !pairs.isEmpty else { return -1 }
    var leftSum = 0.0
    var rightSum = 0.0
    for pair in pairs {
      leftSum += pair.0
      rightSum += pair.1
    }
    let leftMean = leftSum / Double(pairs.count)
    let rightMean = rightSum / Double(pairs.count)
    var covariance = 0.0
    var leftVariance = 0.0
    var rightVariance = 0.0
    for pair in pairs {
      let left = pair.0 - leftMean
      let right = pair.1 - rightMean
      covariance += left * right
      leftVariance += left * left
      rightVariance += right * right
    }
    let denominator = sqrt(leftVariance * rightVariance)
    guard denominator > 1e-12 else { return -1 }
    return covariance / denominator
  }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  static func percentile(_ sorted: [Double], fraction: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    guard lower != upper else { return sorted[lower] }
    let weight = position - Double(lower)
    return sorted[lower] * (1 - weight) + sorted[upper] * weight
  }
}
