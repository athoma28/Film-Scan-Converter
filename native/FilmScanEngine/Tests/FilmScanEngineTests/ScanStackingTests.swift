import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Repeated scan detection and stacking")
struct ScanStackingTests {
  @Test("Fingerprint matches an exposure bracket and rejects another negative")
  func exposureInvariantFingerprint() throws {
    let reference = syntheticImage(width: 112, height: 84, channels: 3, seed: 7)
    let bracket = syntheticImage(
      width: 112,
      height: 84,
      channels: 3,
      seed: 7,
      exposureEV: 1.2,
      translationX: 4,
      translationY: -3)
    let different = syntheticImage(width: 112, height: 84, channels: 3, seed: 91)

    let fingerprints = try [reference, bracket, different].map {
      try ScanFingerprint(image: $0)
    }
    let same = SameNegativeDetector.match(
      fingerprints[0], fingerprints[1], minimumConfidence: 0.88)
    let other = SameNegativeDetector.match(fingerprints[0], fingerprints[2])

    #expect(same.isMatch)
    #expect(same.confidence >= 0.88)
    #expect(!other.isMatch)
    #expect(
      SameNegativeDetector.groupAdjacent(fingerprints, minimumConfidence: 0.88)
        == [[0, 1], [2]])
  }

  @Test("A shared holder around different interiors does not form a stack")
  func sharedHolderDoesNotGroupDifferentFrames() throws {
    let first = syntheticHolderCapture(interiorSeed: 11)
    let second = syntheticHolderCapture(interiorSeed: 77)
    let fingerprints = try [first, second].map { try ScanFingerprint(image: $0) }
    let match = SameNegativeDetector.match(fingerprints[0], fingerprints[1])

    #expect(!match.isMatch)
    #expect(SameNegativeDetector.groupAdjacent(fingerprints) == [[0], [1]])
  }

  @Test("Stacker recovers a known integer translation")
  func knownTranslation() throws {
    let reference = syntheticImage(width: 96, height: 72, channels: 3, seed: 12)
    let shifted = syntheticImage(
      width: 96,
      height: 72,
      channels: 3,
      seed: 12,
      translationX: 5,
      translationY: -4)

    let result = try MultiScanStacker.combine(
      images: [reference, shifted], mode: .noiseReduction)

    #expect(result.effectiveMode == .noiseReduction)
    #expect(result.alignments.count == 2)
    #expect(result.alignments[1].translationX == 5)
    #expect(result.alignments[1].translationY == -4)
    #expect(result.alignments[1].confidence >= 0.72)
    #expect(abs(result.exposureOffsetsEV[1]) < 0.05)
  }

  @Test("Exposure-normalized robust mean reduces independent noise")
  func noiseReductionLowersVariance() throws {
    let truth = syntheticImage(width: 88, height: 66, channels: 1, seed: 22)
    let noisy = (0..<4).map { index in
      syntheticImage(
        width: 88,
        height: 66,
        channels: 1,
        seed: 22,
        noiseSeed: UInt64(100 + index),
        noiseAmplitude: 0.025)
    }

    let result = try MultiScanStacker.combine(images: noisy, mode: .noiseReduction)
    let firstError = linearMeanSquaredError(noisy[0], truth)
    let stackedError = linearMeanSquaredError(result.image, truth)

    #expect(result.effectiveMode == .noiseReduction)
    #expect(stackedError < firstError * 0.60)
  }

  @Test("Automatic mode selects HDR and ignores clipped bracket samples")
  func hdrClippedRecovery() throws {
    let truth = syntheticImage(width: 104, height: 78, channels: 3, seed: 38)
    let normal = syntheticImage(width: 104, height: 78, channels: 3, seed: 38)
    let bright = syntheticImage(
      width: 104, height: 78, channels: 3, seed: 38, exposureEV: 2)
    let dark = syntheticImage(
      width: 104, height: 78, channels: 3, seed: 38, exposureEV: -2)

    let result = try MultiScanStacker.combine(
      images: [normal, bright, dark], mode: .automatic)

    #expect(result.effectiveMode == .hdr)
    #expect(abs(result.exposureOffsetsEV[1] - 2) < 0.08)
    #expect(abs(result.exposureOffsetsEV[2] + 2) < 0.08)
    let truthLinear = linearComponents(truth)
    let brightTruthIndices = truthLinear.indices.filter { truthLinear[$0] > 0.62 }
    let outputLinear = linearComponents(result.image)
    #expect(!brightTruthIndices.isEmpty)
    let meanBrightError =
      brightTruthIndices.reduce(0.0) {
        $0 + abs(outputLinear[$1] - truthLinear[$1])
      } / Double(brightTruthIndices.count)
    #expect(meanBrightError < 0.025)
  }

  @Test("Moderate RGB stack rejects a localized contaminated capture")
  func moderateRGBRobustness() throws {
    let truth = syntheticImage(width: 192, height: 144, channels: 3, seed: 51)
    var captures = (0..<4).map { index in
      syntheticImage(
        width: 192,
        height: 144,
        channels: 3,
        seed: 51,
        noiseSeed: UInt64(700 + index),
        noiseAmplitude: 0.018)
    }
    captures[3] = replacingPatch(
      in: captures[3],
      xRange: 72..<120,
      yRange: 48..<96,
      linearValue: 0.97)

    let result = try MultiScanStacker.combine(images: captures, mode: .noiseReduction)
    let firstError = linearMeanSquaredError(captures[0], truth)
    let stackedError = linearMeanSquaredError(result.image, truth)

    #expect(result.effectiveMode == .noiseReduction)
    #expect(result.image.width == 192)
    #expect(result.image.height == 144)
    #expect(result.image.channels == 3)
    #expect(stackedError < firstError * 0.65)
  }

  @Test("Stacker rejects incompatible image geometry and channels")
  func rejectsIncompatibleInputs() {
    let reference = syntheticImage(width: 64, height: 48, channels: 3, seed: 2)
    let wrongSize = syntheticImage(width: 63, height: 48, channels: 3, seed: 2)
    let wrongChannels = syntheticImage(width: 64, height: 48, channels: 1, seed: 2)

    #expect(
      throws: ScanStackError.incompatibleDimensions(
        index: 1,
        expectedWidth: 64,
        expectedHeight: 48,
        actualWidth: 63,
        actualHeight: 48
      )
    ) {
      try MultiScanStacker.combine(images: [reference, wrongSize])
    }
    #expect(throws: ScanStackError.incompatibleChannels(index: 1, expected: 3, actual: 1)) {
      try MultiScanStacker.combine(images: [reference, wrongChannels])
    }
  }

  @Test("Stacker reports task cancellation")
  func reportsCancellation() async {
    let reference = syntheticImage(width: 96, height: 72, channels: 3, seed: 63)
    let candidate = syntheticImage(width: 96, height: 72, channels: 3, seed: 63)
    let task = Task.detached {
      try MultiScanStacker.combine(images: [reference, candidate], mode: .noiseReduction)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  private func syntheticImage(
    width: Int,
    height: Int,
    channels: Int,
    seed: Int,
    exposureEV: Double = 0,
    translationX: Int = 0,
    translationY: Int = 0,
    noiseSeed: UInt64? = nil,
    noiseAmplitude: Double = 0
  ) -> UInt16Image {
    var pixels = [UInt16](repeating: 0, count: width * height * channels)
    var generator = noiseSeed ?? 1
    let exposure = pow(2, exposureEV)
    for y in 0..<height {
      for x in 0..<width {
        let sourceX = x - translationX
        let sourceY = y - translationY
        for channel in 0..<channels {
          let value: Double
          if sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height {
            value = sceneValue(
              x: sourceX,
              y: sourceY,
              width: width,
              height: height,
              channel: channel,
              seed: seed)
          } else {
            value = 0.008 + 0.002 * Double(channel)
          }
          var noisyValue = value * exposure
          if noiseSeed != nil {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double((generator >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
            noisyValue += (unit * 2 - 1) * noiseAmplitude
          }
          pixels[(y * width + x) * channels + channel] = encodeSRGB(noisyValue)
        }
      }
    }
    return UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
  }

  private func syntheticHolderCapture(interiorSeed: Int) -> UInt16Image {
    let width = 160
    let height = 120
    let insetX = width / 5
    let insetY = height / 5
    var pixels = [UInt16](repeating: 0, count: width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let interior = x >= insetX && x < width - insetX && y >= insetY && y < height - insetY
        let value: Double
        if interior {
          value = sceneValue(
            x: x - insetX,
            y: y - insetY,
            width: width - insetX * 2,
            height: height - insetY * 2,
            channel: 1,
            seed: interiorSeed)
        } else {
          value = 0.62 + 0.04 * Double((x + y) % 5) / 5
        }
        let encoded = encodeSRGB(value)
        let base = (y * width + x) * 3
        pixels[base] = UInt16((Double(encoded) * 0.86).rounded())
        pixels[base + 1] = encoded
        pixels[base + 2] = UInt16((Double(encoded) * 0.93).rounded())
      }
    }
    return UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
  }

  private func replacingPatch(
    in image: UInt16Image,
    xRange: Range<Int>,
    yRange: Range<Int>,
    linearValue: Double
  ) -> UInt16Image {
    var pixels = image.pixels
    let replacement = encodeSRGB(linearValue)
    for y in yRange {
      for x in xRange {
        let base = (y * image.width + x) * image.channels
        for channel in 0..<image.channels {
          pixels[base + channel] = replacement
        }
      }
    }
    return UInt16Image(
      width: image.width,
      height: image.height,
      channels: image.channels,
      pixels: pixels)
  }

  private func sceneValue(
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    channel: Int,
    seed: Int
  ) -> Double {
    var hash = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ seed &* 83_492_791))
    hash ^= hash >> 13
    hash &*= 0xff51_afd7_ed55_8ccd
    hash ^= hash >> 33
    let random = Double(hash & 0xffff) / 65_535
    let wave = 0.5 + 0.5 * sin(Double(x + seed) * 0.19) * cos(Double(y - seed) * 0.13)
    let radialX = (Double(x) - Double(width) * 0.47) / Double(width)
    let radialY = (Double(y) - Double(height) * 0.52) / Double(height)
    let ring = 0.5 + 0.5 * cos(sqrt(radialX * radialX + radialY * radialY) * 37)
    let base = 0.025 + 0.70 * (0.50 * wave + 0.30 * ring + 0.20 * random)
    let channelScale = channel == 0 ? 0.86 : (channel == 1 ? 1.0 : 0.93)
    return min(0.88, base * channelScale)
  }

  private func encodeSRGB(_ linear: Double) -> UInt16 {
    let value = min(max(linear, 0), 1)
    let encoded =
      value <= 0.003_130_8
      ? value * 12.92
      : 1.055 * pow(value, 1 / 2.4) - 0.055
    return UInt16((encoded * 65_535).rounded())
  }

  private func decodeSRGB(_ encoded: UInt16) -> Double {
    let value = Double(encoded) / 65_535
    return value <= 0.04045
      ? value / 12.92
      : pow((value + 0.055) / 1.055, 2.4)
  }

  private func linearComponents(_ image: UInt16Image) -> [Double] {
    image.pixels.map(decodeSRGB)
  }

  private func linearMeanSquaredError(_ image: UInt16Image, _ truth: UInt16Image) -> Double {
    let actual = linearComponents(image)
    let expected = linearComponents(truth)
    return zip(actual, expected).reduce(0.0) { result, pair in
      let difference = pair.0 - pair.1
      return result + difference * difference
    } / Double(actual.count)
  }
}
