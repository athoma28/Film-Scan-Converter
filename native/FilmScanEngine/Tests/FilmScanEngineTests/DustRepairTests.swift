import FilmScanPreviewRenderer
import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Localized dust healing")
struct DustRepairTests {
  private let width = 128
  private let height = 96

  private func point(_ x: Int, _ y: Int) -> SIMD2<Double> {
    SIMD2((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
  }

  private func texturedImage(channels: Int, dusty: Bool) -> UInt16Image {
    var pixels = [UInt16]()
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<channels {
          let texture = (x + y) % 2 == 0 ? 1_000 : -1_000
          let value = 20_000 + x * 100 + y * 20 + channel * 3_000 + texture
          let dust = dusty && abs(x - 64) <= 1 && abs(y - 48) <= 1
          pixels.append(UInt16(dust ? 100 : value))
        }
      }
    }
    return UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
  }

  @Test("Explicit donor restores texture and boundary color for mono and color scans")
  func restoresTextureWithoutBlur() {
    for channels in [1, 3] {
      let image = texturedImage(channels: channels, dusty: true)
      let clean = texturedImage(channels: channels, dusty: false)
      let stroke = DustRepairStroke(
        points: [point(64, 48)], radius: 4 / Double(width), sourcePoint: point(88, 48))
      let repaired = DustRepair.apply(to: image, strokes: [stroke])
      #expect(repaired == clean)
      #expect(image == texturedImage(channels: channels, dusty: true))
      #expect(DustRepair.apply(to: image, strokes: [stroke]) == repaired)
    }
  }

  @Test("Automatic donor is deterministic and repairs only the chosen spot")
  func automaticDonorAndLocality() {
    var pixels = [UInt16](repeating: 31_000, count: width * height * 3)
    for channel in 0..<3 {
      pixels[(48 * width + 64) * 3 + channel] = 50
      pixels[(20 * width + 20) * 3 + channel] = 70
    }
    let image = UInt16Image(width: width, height: height, channels: 3, pixels: pixels)
    let strokes = [DustRepairStroke(points: [point(64, 48)], radius: 3 / Double(width))]
    let first = DustRepair.apply(to: image, strokes: strokes)
    let second = DustRepair.apply(to: image, strokes: strokes)
    #expect(first == second)
    #expect(first.pixels[(48 * width + 64) * 3] == 31_000)
    #expect(first.pixels[(20 * width + 20) * 3] == 70)
    #expect(zip(image.pixels, first.pixels).filter { $0 != $1 }.count == 3)
  }

  @Test("Healing strokes interpolate sparse pointer samples with a fixed donor offset")
  func continuousStroke() {
    var pixels = [UInt16](repeating: 28_000, count: width * height)
    for x in 40...60 { pixels[48 * width + x] = 100 }
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let stroke = DustRepairStroke(
      points: [point(40, 48), point(60, 48)], radius: 4 / Double(width),
      sourcePoint: point(40, 64))
    let repaired = DustRepair.apply(to: image, strokes: [stroke])
    #expect((40...60).allSatisfy { repaired.pixels[48 * width + $0] == 28_000 })
    #expect(repaired.pixels[40 * width + 50] == image.pixels[40 * width + 50])
  }

  @Test("The brush boundary feathers instead of replacing its outer pixels abruptly")
  func featheredEdge() {
    var pixels = [UInt16](repeating: 30_000, count: width * height)
    for y in 46...50 {
      for x in 62...66 { pixels[y * width + x] = 10_000 }
    }
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let stroke = DustRepairStroke(
      points: [point(64, 48)], radius: 3 / Double(width), sourcePoint: point(88, 48))
    let output = DustRepair.apply(to: image, strokes: [stroke])
    #expect(output.pixels[48 * width + 64] == 30_000)
    let edge = output.pixels[50 * width + 66]
    #expect(edge > 10_000 && edge < 30_000)
    #expect(output.pixels[48 * width + 67] == image.pixels[48 * width + 67])
  }

  @Test("Repeated stationary pointer samples preserve the feather and repair budget")
  func stationarySamplesDoNotAccumulate() {
    var pixels = [UInt16](repeating: 30_000, count: width * height)
    for y in 46...50 {
      for x in 62...66 { pixels[y * width + x] = 10_000 }
    }
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let stroke = DustRepairStroke(
      points: [point(64, 48)], radius: 3 / Double(width), sourcePoint: point(88, 48))
    let expected = DustRepair.apply(to: image, strokes: [stroke])
    let edge = expected.pixels[50 * width + 66]
    #expect(edge > 10_000 && edge < 30_000)
    var repeated = stroke
    repeated.points = Array(repeating: stroke.points[0], count: 3)
    #expect(DustRepair.apply(to: image, strokes: [repeated]) == expected)

    // One hundred maximum-radius stamps exactly fill the patch-work budget.
    // Repeating each pointer position must not make the same edits invalid.
    repeated.radius = DustRepair.maximumNormalizedRadius
    #expect(
      DustRepair.canApply(
        strokes: Array(repeating: repeated, count: 100), imageWidth: width, imageHeight: height))
  }

  @Test("Later repairs sample the immutable scan rather than earlier repaired pixels")
  func donorsRemainOriginal() {
    var pixels = [UInt16](repeating: 28_000, count: width * height)
    pixels[48 * width + 40] = 100
    pixels[48 * width + 80] = 100
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let strokes = [
      DustRepairStroke(
        points: [point(40, 48)], radius: 3 / Double(width), sourcePoint: point(104, 48)),
      DustRepairStroke(
        points: [point(80, 48)], radius: 3 / Double(width), sourcePoint: point(40, 48)),
    ]
    let repaired = DustRepair.apply(to: image, strokes: strokes)
    #expect(repaired.pixels[48 * width + 40] == 28_000)
    #expect(repaired.pixels[48 * width + 80] == 100)
    #expect(DustRepair.apply(to: image, strokes: Array(strokes.reversed())) == repaired)
  }

  @Test("Empty and malformed edits preserve exact pixels and safe donor bounds")
  func neutralAndInvalidInputs() {
    let image = texturedImage(channels: 3, dusty: true)
    #expect(DustRepair.apply(to: image, strokes: []) == image)
    let valid = DustRepairStroke(
      points: [point(64, 48)], radius: 4 / Double(width), sourcePoint: point(88, 48))
    #expect(DustRepair.apply(to: image, strokes: [valid]) != image)
    let invalid = [
      DustRepairStroke(points: [], radius: 0.02),
      DustRepairStroke(points: [point(64, 48)], radius: 0),
      DustRepairStroke(points: [point(64, 48)], radius: -.infinity),
      DustRepairStroke(points: [point(64, 48)], radius: .nan),
      DustRepairStroke(points: [point(64, 48)], radius: 0.9),
      DustRepairStroke(points: [SIMD2(.nan, 0.5)], radius: 0.02),
      DustRepairStroke(points: [SIMD2(-1, 0.5)], radius: 0.02),
      DustRepairStroke(points: [SIMD2(0.5, 1.1)], radius: 0.02),
      DustRepairStroke(points: [point(64, 48)], radius: 0.02, sourcePoint: SIMD2(.nan, 0.5)),
      DustRepairStroke(points: [point(64, 48)], radius: 0.02, sourcePoint: SIMD2(0.5, -0.1)),
    ]
    for stroke in invalid {
      #expect(!DustRepair.canApply(strokes: [stroke], imageWidth: width, imageHeight: height))
      #expect(DustRepair.apply(to: image, strokes: [stroke]) == image)
      // The entire invalid document is a no-op, including preceding valid work.
      #expect(DustRepair.apply(to: image, strokes: [valid, stroke]) == image)
    }
    let clippedDonor = DustRepairStroke(
      points: [point(64, 48)], radius: 0.02, sourcePoint: SIMD2(0, 0))
    #expect(DustRepair.apply(to: image, strokes: [clippedDonor]) == image)
    let tiny = UInt16Image(width: 1, height: 1, channels: 1, pixels: [12_345])
    #expect(
      DustRepair.apply(to: tiny, strokes: [.init(points: [SIMD2(0.5, 0.5)], radius: 0.01)])
        == tiny)
  }

  @Test("Resource limits reject complete strokes without applying a truncated path")
  func boundedWork() {
    let spot = DustRepairStroke(points: [point(64, 48)], radius: 0.05)
    #expect(DustRepair.canApply(strokes: [spot], imageWidth: width, imageHeight: height))
    #expect(
      !DustRepair.canApply(
        strokes: Array(repeating: spot, count: 101), imageWidth: width, imageHeight: height))
    let tooManyPoints = DustRepairStroke(
      points: Array(repeating: point(64, 48), count: DustRepair.maximumPointsPerStroke + 1),
      radius: 0.001)
    #expect(!DustRepair.canApply(strokes: [tooManyPoints], imageWidth: width, imageHeight: height))
    let fineSpot = DustRepairStroke(points: [point(64, 48)], radius: 0.001)
    #expect(
      !DustRepair.canApply(
        strokes: Array(repeating: fineSpot, count: DustRepair.maximumStrokeCount + 1),
        imageWidth: width, imageHeight: height))
    let manySamples = DustRepairStroke(
      points: Array(repeating: point(64, 48), count: DustRepair.maximumPointsPerStroke),
      radius: 0.001)
    #expect(
      !DustRepair.canApply(
        strokes: Array(repeating: manySamples, count: 9), imageWidth: width, imageHeight: height))
    let maximumDabs = DustRepairStroke(
      points: [SIMD2(0, 0.5), SIMD2(0.5, 0.5)], radius: 0.000_001)
    #expect(
      DustRepair.canApply(strokes: [maximumDabs], imageWidth: 32_767, imageHeight: 1))
    #expect(
      !DustRepair.canApply(strokes: [maximumDabs], imageWidth: 32_768, imageHeight: 1))
    let longFineStroke = DustRepairStroke(
      points: [SIMD2(0.01, 0.5), SIMD2(0.99, 0.5)], radius: 0.000_001)
    #expect(
      !DustRepair.canApply(
        strokes: [longFineStroke], imageWidth: 100_000, imageHeight: 10_000))
    let image = texturedImage(channels: 1, dusty: true)
    #expect(DustRepair.apply(to: image, strokes: Array(repeating: spot, count: 101)) == image)
  }

  @Test("Mask components reject large, long, sparse, and border regions with stable limits")
  func conservativeMaskComponents() {
    var pixels = [UInt16](repeating: 0, count: width * height)
    for y in 20...21 {
      for x in 20...21 { pixels[y * width + x] = 255 }
      for x in 60...61 { pixels[y * width + x] = 255 }
    }
    for x in 30...50 { pixels[40 * width + x] = 255 }
    for y in 55...70 {
      for x in 70...85 { pixels[y * width + x] = 255 }
    }
    pixels[0] = 255
    let mask = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let repairs = DustRepair.automaticRepairs(from: mask)
    #expect(repairs.count == 2)
    #expect(repairs == DustRepair.automaticRepairs(from: mask))
    #expect(repairs[0].points == [SIMD2(21.0 / 128, 21.0 / 96)])
    #expect(DustRepair.automaticRepairs(from: mask, maximumCount: 1) == Array(repairs.prefix(1)))
    #expect(DustRepair.automaticRepairs(from: mask, maximumCount: 0).isEmpty)
    let fullMask = UInt16Image(
      width: width, height: height, channels: 1,
      pixels: [UInt16](repeating: 255, count: width * height))
    #expect(DustRepair.automaticRepairs(from: fullMask).isEmpty)
  }

  @Test("Connected runs merge components before generating a single repair")
  func connectedRunMerge() {
    var pixels = [UInt16](repeating: 0, count: width * height)
    for x in [40, 42] { pixels[40 * width + x] = 255 }
    for x in 40...42 { pixels[41 * width + x] = 255 }
    let mask = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let repairs = DustRepair.automaticRepairs(from: mask)
    #expect(repairs.count == 1)
    #expect(repairs[0].points == [SIMD2(41.5 / 128, 41.0 / 96)])
  }

  @Test("Automatic mask seeds remain marked through component unions and hollow centers")
  func automaticCandidateSeeds() throws {
    var pixels = [UInt16](repeating: 0, count: width * height)
    // A ring's bounding-box center is not a valid flood-fill seed.
    for y in 40...42 {
      for x in 40...42 where x != 41 || y != 41 { pixels[y * width + x] = 255 }
    }
    // Separate row runs become one component when the next row joins them.
    for x in [70, 72] { pixels[40 * width + x] = 255 }
    for x in 70...72 { pixels[41 * width + x] = 255 }
    pixels[20 * width + 60] = 255
    // Border and long structures must stay excluded from candidate extraction.
    pixels[0] = 255
    for x in 10...30 { pixels[70 * width + x] = 255 }
    let mask = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let candidates = DustRepair.automaticRepairCandidates(from: mask)
    #expect(candidates.count == 3)
    #expect(candidates.map(\.stroke) == DustRepair.automaticRepairs(from: mask))
    #expect(candidates == DustRepair.automaticRepairCandidates(from: mask))
    #expect(
      DustRepair.automaticRepairCandidates(from: mask, maximumCount: 1)
        == Array(candidates.prefix(1)))
    #expect(DustRepair.automaticRepairCandidates(from: mask, maximumCount: 0).isEmpty)
    for candidate in candidates {
      #expect((0..<width).contains(candidate.maskSeed.x))
      #expect((0..<height).contains(candidate.maskSeed.y))
      #expect(pixels[candidate.maskSeed.y * width + candidate.maskSeed.x] != 0)
    }
    let ring = try #require(candidates.first { $0.stroke.points == [point(41, 41)] })
    #expect(ring.maskSeed != SIMD2(41, 41))
    let merged = try #require(
      candidates.first { $0.stroke.points == [SIMD2(71.5 / 128, 41.0 / 96)] })
    #expect(merged.maskSeed == SIMD2(70, 40))
  }

  @Test("Dense isolated candidates retain donor failures instead of claiming every stamp is usable")
  func automaticRepairDonorFailures() throws {
    var maskPixels = [UInt16](repeating: 0, count: width * height)
    var pixels = [UInt16](repeating: 28_000, count: width * height)
    for y in stride(from: 21, through: 63, by: 3) {
      for x in stride(from: 21, through: 66, by: 3) {
        maskPixels[y * width + x] = 255
        pixels[y * width + x] = 100
      }
    }
    let mask = UInt16Image(width: width, height: height, channels: 1, pixels: maskPixels)
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let repairs = DustRepair.automaticRepairs(from: mask)
    #expect(repairs.count == 240)
    #expect(DustRepair.canApply(strokes: repairs, imageWidth: width, imageHeight: height))
    let centerIndex = try #require(repairs.firstIndex { $0.points == [point(42, 42)] })
    let cornerIndex = try #require(repairs.firstIndex { $0.points == [point(21, 21)] })
    let applicable = DustRepair.applicableStrokeIndices(in: image, strokes: repairs)
    // Every donor around the middle is covered by another proposed stamp;
    // candidates near the outside still have clean neighboring texture.
    #expect(!applicable.contains(centerIndex))
    #expect(applicable.contains(cornerIndex))
    #expect(applicable.count < repairs.count)
    #expect(applicable == DustRepair.applicableStrokeIndices(in: image, strokes: repairs))
    let repaired = DustRepair.apply(to: image, strokes: repairs)
    #expect(repaired.pixels[42 * width + 42] == 100)
    #expect(repaired.pixels[21 * width + 21] == 28_000)

    // Appending one proposal to existing repairs must account for their
    // destinations too, rather than certifying the new stamp in isolation.
    let proposed = repairs[centerIndex]
    #expect(DustRepair.applicableStrokeIndices(in: image, strokes: [proposed]) == [0])
    let existing = repairs.enumerated().filter { $0.offset != centerIndex }.map(\.element)
    let combined = existing + [proposed]
    #expect(
      !DustRepair.applicableStrokeIndices(in: image, strokes: combined).contains(existing.count))
  }

  @Test("Saved mask stamps retain the donors chosen with rejected candidates excluded")
  func plannedStampsRetainRejectedDonorExclusions() throws {
    for channels in [1, 3] {
      var maskPixels = [UInt16](repeating: 0, count: width * height)
      var pixels = [UInt16](repeating: 30_000, count: width * height * channels)
      for y in stride(from: 21, through: 63, by: 3) {
        for x in stride(from: 21, through: 66, by: 3) {
          maskPixels[y * width + x] = .max
          for channel in 0..<channels { pixels[(y * width + x) * channels + channel] = 0 }
        }
      }
      let mask = UInt16Image(width: width, height: height, channels: 1, pixels: maskPixels)
      let image = UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
      let proposals = DustRepair.automaticRepairs(from: mask)
      let acceptedIndices = DustRepair.applicableStrokeIndices(in: image, strokes: proposals)
      try #require(proposals.count == 240 && acceptedIndices.count == 108)
      let reference = DustRepair.apply(to: image, strokes: proposals)
      let filtered = DustRepair.apply(
        to: image, strokes: acceptedIndices.map { proposals[$0] })
      let target = (24 * width + 27) * channels
      #expect(reference.pixels[target] == 30_000)
      // Removing rejected destinations lets the automatic donor move onto
      // a still-marked dark spot, despite passing the original planning check.
      #expect(filtered.pixels[target] == 17_283)
      #expect(filtered != reference)

      let plans = DustRepair.plannedSinglePointRepairs(in: image, strokes: proposals)
      #expect(plans.map(\.strokeIndex) == acceptedIndices)
      #expect(plans.allSatisfy { $0.stroke.sourcePoint != nil })
      #expect(plans == DustRepair.plannedSinglePointRepairs(in: image, strokes: proposals))
      let saved = plans.map(\.stroke)
      #expect(DustRepair.apply(to: image, strokes: saved) == reference)
      let reopened = try JSONDecoder().decode(
        [DustRepairStroke].self, from: JSONEncoder().encode(saved))
      #expect(reopened == saved)
      #expect(DustRepair.apply(to: image, strokes: reopened) == reference)
    }
  }

  @Test("Stamp plans preserve chosen donors and exclude existing paths without returning them")
  func stampPlansRespectExistingStrokeContract() throws {
    var pixels = [UInt16](repeating: 30_000, count: width * height)
    pixels[20 * width + 20] = 0
    pixels[48 * width + 64] = 0
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let path = DustRepairStroke(
      points: [point(28, 20), point(29, 20)], radius: 3 / Double(width),
      sourcePoint: point(28, 40))
    let stamp = DustRepairStroke(
      points: [point(64, 48)], radius: 4 / Double(width), sourcePoint: point(88, 48))
    let automatic = DustRepairStroke(points: [point(20, 20)], radius: 3 / Double(width))
    let clipped = DustRepairStroke(
      points: [point(80, 48)], radius: 3 / Double(width), sourcePoint: SIMD2(0, 0))
    let plans = DustRepair.plannedSinglePointRepairs(
      in: image, strokes: [path, stamp, automatic, clipped])
    try #require(plans.count == 2)
    #expect(plans.map(\.strokeIndex) == [1, 2])
    #expect(plans[0].stroke == stamp)
    let alone = try #require(
      DustRepair.plannedSinglePointRepairs(in: image, strokes: [automatic]).first)
    #expect(plans[1].stroke.sourcePoint != alone.stroke.sourcePoint)
    #expect(
      DustRepair.plannedSinglePointRepairs(
        in: image, strokes: [path, stamp, automatic, clipped], planningStrokeIndices: [2])
        == [plans[1]])
    #expect(
      DustRepair.applicableStrokeIndices(
        in: image, strokes: [path, stamp, automatic, clipped], checkingStrokeIndices: [1, 2])
        == [1, 2])
    #expect(
      DustRepair.applicableStrokeIndices(
        in: image, strokes: [path, stamp, automatic, clipped], checkingStrokeIndices: [3]
      )
      .isEmpty)
    let rejectedIndices: [Set<Int>] = [[], [-1], [4]]
    for indices in rejectedIndices {
      #expect(
        DustRepair.plannedSinglePointRepairs(
          in: image, strokes: [path, stamp, automatic, clipped], planningStrokeIndices: indices
        )
        .isEmpty)
      #expect(
        DustRepair.applicableStrokeIndices(
          in: image, strokes: [path, stamp, automatic, clipped], checkingStrokeIndices: indices
        )
        .isEmpty)
    }
    #expect(
      DustRepair.apply(to: image, strokes: [path] + plans.map(\.stroke))
        == DustRepair.apply(to: image, strokes: [path, stamp, automatic, clipped]))
    #expect(DustRepair.plannedSinglePointRepairs(in: image, strokes: []).isEmpty)
    let malformed = DustRepairStroke(points: [], radius: 0.02)
    #expect(DustRepair.plannedSinglePointRepairs(in: image, strokes: [stamp, malformed]).isEmpty)
  }

  @Test(
    "Full mask exclusion keeps skipped scratches and capped components out of donor texture",
    arguments: [false, true])
  func unproposedMarkedPixelsAreExcluded(capped: Bool) throws {
    var maskPixels = [UInt16](repeating: 0, count: width * height)
    var pixels = [UInt16](repeating: 30_000, count: width * height)
    func mark(_ x: Int, _ y: Int) {
      maskPixels[y * width + x] = .max
      pixels[y * width + x] = 0
    }
    let targetY = capped ? 80 : 20
    if capped {
      var count = 0
      for y in stride(from: 4, through: 40, by: 3) {
        for x in stride(from: 4, through: 61, by: 3) where count < 249 {
          mark(x, y)
          count += 1
        }
      }
      mark(27, targetY)
    } else {
      for x in 24...60 { mark(x, targetY) }
    }
    mark(20, targetY)
    let mask = UInt16Image(width: width, height: height, channels: 1, pixels: maskPixels)
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let candidates = DustRepair.automaticRepairCandidates(from: mask)
    try #require(candidates.count == (capped ? 250 : 1))
    let proposals = candidates.map(\.stroke)
    let unprotected = DustRepair.plannedSinglePointRepairs(in: image, strokes: proposals)
    let oldOutput = DustRepair.apply(to: image, strokes: unprotected.map(\.stroke))
    #expect(oldOutput.pixels[targetY * width + 20] == (capped ? 5_147 : 0))
    let protected = DustRepair.plannedSinglePointRepairs(
      in: image, strokes: proposals, excludingMask: mask)
    try #require(protected.contains { $0.stroke.points == [point(20, targetY)] })
    let output = DustRepair.apply(to: image, strokes: protected.map(\.stroke))
    #expect(output.pixels[targetY * width + 20] == 30_000)
    #expect(output.pixels[targetY * width + (capped ? 27 : 40)] == 0)
    let reopened = try JSONDecoder().decode(
      [DustRepairStroke].self, from: JSONEncoder().encode(protected.map(\.stroke)))
    #expect(DustRepair.apply(to: image, strokes: reopened) == output)
  }

  @Test("Mask exclusions project across resolution, remain bounded, and preserve chosen donors")
  func boundedMaskExclusionContract() throws {
    var maskPixels = [UInt16](repeating: 0, count: 64 * 48)
    var pixels = [UInt16](repeating: 30_000, count: width * height)
    pixels[20 * width + 20] = 0
    maskPixels[10 * 64 + 10] = .max
    for x in 24...60 {
      pixels[20 * width + x] = 0
      maskPixels[10 * 64 + x / 2] = .max
    }
    let smallMask = UInt16Image(width: 64, height: 48, channels: 1, pixels: maskPixels)
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
      .resized(width: width * 2, height: height * 2)
    let stamp = DustRepairStroke(points: [point(20, 20)], radius: (sqrt(2) / 2 + 1) / Double(width))
    let plans = DustRepair.plannedSinglePointRepairs(
      in: image, strokes: [stamp], excludingMask: smallMask)
    try #require(plans.count == 1)
    let output = DustRepair.apply(to: image, strokes: plans.map(\.stroke))
    #expect(output.pixels[40 * width * 2 + 40] == 30_000)
    #expect(output.pixels[41 * width * 2 + 41] == 30_000)
    #expect(output.pixels[40 * width * 2 + 80] == 0)

    let fullMask = UInt16Image(
      width: 64, height: 48, channels: 1,
      pixels: [UInt16](repeating: .max, count: 64 * 48))
    #expect(
      DustRepair.plannedSinglePointRepairs(in: image, strokes: [stamp], excludingMask: fullMask)
        .isEmpty)
    let chosen = DustRepairStroke(
      points: stamp.points, radius: stamp.radius, sourcePoint: point(40, 40))
    #expect(
      DustRepair.plannedSinglePointRepairs(in: image, strokes: [chosen], excludingMask: fullMask)
        .map(\.stroke) == [chosen])

    let oversizedMask = UInt16Image(
      width: DustRepair.maximumPlanningMaskDimension + 1, height: 1, channels: 1,
      pixels: [UInt16](repeating: 0, count: DustRepair.maximumPlanningMaskDimension + 1))
    #expect(
      DustRepair.plannedSinglePointRepairs(
        in: image, strokes: [chosen], excludingMask: oversizedMask
      )
      .isEmpty)
    let colorMask = UInt16Image(width: 1, height: 1, channels: 3, pixels: [0, 0, 0])
    #expect(
      DustRepair.plannedSinglePointRepairs(in: image, strokes: [stamp], excludingMask: colorMask)
        .isEmpty)
  }

  @Test(
    "Cancelled planning returns no work while persisted rendering stays exact", arguments: [1, 3])
  @MainActor
  func cancelledPlanningPreservesRendering(channels: Int) async throws {
    var pixels = [UInt16](repeating: 30_000, count: width * height * channels)
    for channel in 0..<channels { pixels[(48 * width + 64) * channels + channel] = 100 }
    let image = UInt16Image(width: width, height: height, channels: channels, pixels: pixels)
    let strokes = [DustRepairStroke(points: [point(64, 48)], radius: 3 / Double(width))]
    var marks = [UInt16](repeating: 0, count: width * height)
    marks[48 * width + 64] = .max
    let mask = UInt16Image(width: width, height: height, channels: 1, pixels: marks)
    let expected = DustRepair.apply(to: image, strokes: strokes)
    try #require(expected != image)
    #expect(DustRepair.applicableStrokeIndices(in: image, strokes: strokes) == [0])
    #expect(DustRepair.plannedSinglePointRepairs(in: image, strokes: strokes).count == 1)
    #expect(
      DustRepair.plannedSinglePointRepairs(in: image, strokes: strokes, excludingMask: mask).count
        == 1)

    let task = Task { @MainActor in
      #expect(Task.isCancelled)
      #expect(DustRepair.applicableStrokeIndices(in: image, strokes: strokes).isEmpty)
      #expect(
        DustRepair.applicableStrokeIndices(
          in: image, strokes: strokes, checkingStrokeIndices: [0]
        ).isEmpty)
      #expect(DustRepair.plannedSinglePointRepairs(in: image, strokes: strokes).isEmpty)
      #expect(
        DustRepair.plannedSinglePointRepairs(in: image, strokes: strokes, excludingMask: mask)
          .isEmpty)
      #expect(
        DustRepair.plannedSinglePointRepairs(
          in: image, strokes: strokes, excludingMask: mask, planningStrokeIndices: [0]
        )
        .isEmpty)
      #expect(DustRepair.apply(to: image, strokes: strokes) == expected)
    }
    // The inherited MainActor task cannot start before this test yields.
    task.cancel()
    await task.value
  }

  @Test("Repair planning requires every dab and preserves explicit donor rendering")
  func applicableStrokeRequiresCompletePath() {
    var pixels = [UInt16](repeating: 28_000, count: width * height)
    pixels[20 * width + 20] = 100
    pixels[48 * width + 40] = 100
    pixels[48 * width + 80] = 100
    let image = UInt16Image(width: width, height: height, channels: 1, pixels: pixels)
    let valid = DustRepairStroke(
      points: [point(20, 20)], radius: 3 / Double(width), sourcePoint: point(40, 20))
    let clipped = DustRepairStroke(
      points: [point(80, 48)], radius: 3 / Double(width), sourcePoint: SIMD2(0, 0))
    let partial = DustRepairStroke(
      points: [point(40, 48), point(80, 48)], radius: 3 / Double(width),
      sourcePoint: point(100, 48))
    let strokes = [valid, clipped, partial]
    #expect(DustRepair.applicableStrokeIndices(in: image, strokes: strokes) == [0])
    let output = DustRepair.apply(to: image, strokes: strokes)
    #expect(output.pixels[20 * width + 20] == 28_000)
    // Rendering retains its existing partial-stroke behavior; planning does
    // not silently change saved edits or treat partial success as complete.
    #expect(output.pixels[48 * width + 40] == 28_000)
    #expect(output.pixels[48 * width + 80] == 100)
    #expect(DustRepair.applicableStrokeIndices(in: image, strokes: []).isEmpty)
    let malformed = DustRepairStroke(points: [], radius: 0.02)
    #expect(DustRepair.applicableStrokeIndices(in: image, strokes: [valid, malformed]).isEmpty)
    #expect(image.pixels == pixels)
  }

  @Test("Render footprints share interpolation, stationary samples, and the minimum pixel radius")
  func renderFootprintsFollowDabs() {
    let stroke = DustRepairStroke(
      points: [point(40, 48), point(40, 48), point(42, 48)], radius: 0.001,
      sourcePoint: point(80, 48))
    let footprints = DustRepair.renderFootprints(
      strokes: [stroke], imageWidth: width, imageHeight: height)
    #expect(footprints.map(\.center) == [40.0, 40.5, 41, 41.5, 42].map { SIMD2($0, 48) })
    #expect(footprints.allSatisfy { $0.radius == 0.75 })
    var stationary = stroke
    stationary.points = Array(repeating: point(40, 48), count: 3)
    #expect(
      DustRepair.renderFootprints(
        strokes: [stationary], imageWidth: width, imageHeight: height
      ).count == 1)
    #expect(
      DustRepair.renderFootprints(strokes: [stroke], imageWidth: 0, imageHeight: height).isEmpty)
  }

  @Test("Healing persists with older settings defaulting to no repairs")
  func codableCompatibility() throws {
    let old = try JSONDecoder().decode(ProcessingParameters.self, from: Data("{}".utf8))
    #expect(old.dustRepairs.isEmpty)
    let stroke = DustRepairStroke(
      points: [point(64, 48), point(66, 48)], radius: 4 / Double(width),
      sourcePoint: point(88, 48))
    let p = ProcessingParameters(dustRepairs: [stroke])
    let decoded = try JSONDecoder().decode(ProcessingParameters.self, from: JSONEncoder().encode(p))
    #expect(decoded == p)
  }

  @Test("Repairs precede geometry and CPU preparation invalidates when repairs change")
  func processingAndCacheAgreement() {
    let image = texturedImage(channels: 3, dusty: true)
    let stroke = DustRepairStroke(
      points: [point(64, 48)], radius: 4 / Double(width), sourcePoint: point(88, 48))
    let repaired = DustRepair.apply(to: image, strokes: [stroke])
    var p = ProcessingParameters(
      flip: true, rotation: 1, filmType: .slide, photoAdjustments: .init(),
      manualCrop: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    p.photoAdjustments.exposureEV = 0.4
    let cache = CPUPreviewPreparationCache(image: image)
    #expect(
      cache.render(parameters: p) == FilmProcessing.correctedPreview(image: image, parameters: p))
    let expected = FilmProcessing.correctedPreview(image: repaired, parameters: p)
    p.dustRepairs = [stroke]
    #expect(FilmProcessing.correctedPreview(image: image, parameters: p) == expected)
    #expect(cache.render(parameters: p) == expected)
    #expect(cache.geometryBuildCount == 2)
    p.photoAdjustments.exposureEV = 0.2
    #expect(
      cache.render(parameters: p) == FilmProcessing.correctedPreview(image: image, parameters: p))
    #expect(cache.geometryBuildCount == 2)
    p.dustRepairs = []
    #expect(
      cache.render(parameters: p) == FilmProcessing.correctedPreview(image: image, parameters: p))
    #expect(cache.geometryBuildCount == 3)
  }

  @Test("Both density paths repair scans while preserving the calibration flat field")
  func densityFlatFieldIsolation() {
    let image = texturedImage(channels: 3, dusty: true)
    let stroke = DustRepairStroke(
      points: [point(64, 48)], radius: 4 / Double(width), sourcePoint: point(88, 48))
    let repaired = DustRepair.apply(to: image, strokes: [stroke])
    // A donor offset changes this field's center if repair were accidentally
    // applied to calibration data. Keep it independent of the edited scan.
    var fieldPixels = [UInt16]()
    fieldPixels.reserveCapacity(width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let discontinuity: Int = abs(x - 64) <= 1 && abs(y - 48) <= 1 ? 5_000 : 0
        let spatialLevel: Int = 45_000 + x * 50 + discontinuity
        for channel in 0..<3 {
          let channelLevel: Int = spatialLevel + channel * 1_000
          fieldPixels.append(UInt16(channelLevel))
        }
      }
    }
    let field = UInt16Image(width: width, height: height, channels: 3, pixels: fieldPixels)
    for schema in [1, 4] {
      var p = ProcessingParameters(
        filmType: .colourNegative,
        filmNegativeParams: .init(enabled: true, rendering: .powerLaw),
        photoAdjustments: .init(schemaVersion: schema),
        densityPipelineEnabled: true,
        densityBaseDensity: .init(blue: 0.2, green: 0.2, red: 0.2))
      p.filmNegativeParams.measuredMedians = .init(blue: 25_000, green: 28_000, red: 31_000)
      let expected = FilmProcessing.correctedPreview(
        image: repaired, parameters: p, flatField: field)
      p.dustRepairs = [stroke]
      #expect(
        FilmProcessing.correctedPreview(image: image, parameters: p, flatField: field) == expected)
    }
  }

  @Test("Saved repairs use the authoritative CPU path for corrected and Original views")
  func metalFallback() {
    var p = ProcessingParameters()
    #expect(StillPreviewRenderer.supports(parameters: p, showOriginal: false))
    p.dustRepairs = [.init(points: [point(64, 48)], radius: 0.02)]
    #expect(!StillPreviewRenderer.supports(parameters: p, showOriginal: false))
    #expect(!StillPreviewRenderer.supports(parameters: p, showOriginal: true))
  }
}
