import Foundation

/// A non-destructive healing stroke in the original, unrotated scan.
/// Coordinates span image edges from 0 to 1, with the origin at the top left.
/// Radius is a fraction of source width, so a stroke retains its physical size
/// across draft, inspect, and full-resolution decodes. An explicit source point
/// is the donor corresponding to the first destination point; its offset follows
/// the entire stroke. Without a source point each dab chooses a nearby donor.
public struct DustRepairStroke: Codable, Equatable, Sendable {
  public var points: [SIMD2<Double>]
  public var radius: Double
  public var sourcePoint: SIMD2<Double>?

  public init(points: [SIMD2<Double>], radius: Double, sourcePoint: SIMD2<Double>? = nil) {
    self.points = points
    self.radius = radius
    self.sourcePoint = sourcePoint
  }
}

/// An automatic stamp and one marked pixel in its original mask component.
/// The seed belongs to the extraction mask, rather than the healing patch or
/// bounding-box center, so accepting a stamp can consume only its component.
public struct MaskRepairCandidate: Equatable, Sendable {
  public var stroke: DustRepairStroke
  public var maskSeed: SIMD2<Int>

  public init(stroke: DustRepairStroke, maskSeed: SIMD2<Int>) {
    self.stroke = stroke
    self.maskSeed = maskSeed
  }
}

/// A usable one-point stamp with the donor chosen while all proposed repairs
/// were excluded. The input index associates the plan with its mask component.
public struct PlannedDustRepair: Equatable, Sendable {
  public let strokeIndex: Int
  public let stroke: DustRepairStroke
}

/// One renderer dab in source pixel coordinates. Its positive footprint is
/// strictly inside `radius`; the boundary receives no feather contribution.
public struct DustRepairFootprint: Equatable, Sendable {
  public let center: SIMD2<Double>
  public let radius: Double
}

/// Deterministic, localized texture transfer with boundary color matching.
/// Detection is deliberately separate: this operator applies only saved strokes.
public enum DustRepair {
  /// Larger masks need deliberate manual work rather than one very large stamp.
  public static let maximumNormalizedRadius = 0.05
  public static let maximumStrokeCount = 2_000
  public static let maximumPointsPerStroke = 4_096
  public static let maximumTotalPointCount = 32_768
  public static let maximumDabCount = 32_768
  /// The optional identification mask is bounded independently of source size.
  public static let maximumPlanningMaskDimension = 2_048
  /// Sum of the squared normalized dab diameters. This bounds patch work even
  /// when a saved document contains many unusually large brushes.
  public static let maximumNormalizedPatchWork = 1.0

  /// The editor checks this before saving, so a resource limit never silently
  /// discards the end of a legitimate stroke. Invalid external edits are no-ops.
  public static func canApply(
    strokes: [DustRepairStroke], imageWidth: Int, imageHeight: Int
  ) -> Bool {
    guard imageWidth > 0, imageHeight > 0, strokes.count <= maximumStrokeCount else { return false }
    var totalPoints = 0
    var totalDabs = 0
    var patchWork = 0.0
    for stroke in strokes {
      guard stroke.radius.isFinite, stroke.radius > 0,
        stroke.radius <= maximumNormalizedRadius,
        !stroke.points.isEmpty, stroke.points.count <= maximumPointsPerStroke,
        stroke.points.allSatisfy(validPoint), stroke.sourcePoint.map(validPoint) ?? true
      else { return false }
      totalPoints += stroke.points.count
      guard totalPoints <= maximumTotalPointCount else { return false }
      let spacing = max(max(stroke.radius * Double(imageWidth), 0.75) * 0.5, 0.5)
      totalDabs += 1
      let dabWork = pow(stroke.radius * 2, 2)
      patchWork += dabWork
      var previous = stroke.points[0]
      for point in stroke.points.dropFirst() {
        guard point != previous else { continue }
        let distance = hypot(
          point.x * Double(imageWidth) - previous.x * Double(imageWidth),
          point.y * Double(imageHeight) - previous.y * Double(imageHeight))
        let demand = max(1, ceil(distance / spacing))
        guard demand <= Double(maximumDabCount - totalDabs) else { return false }
        let steps = Int(demand)
        totalDabs += steps
        patchWork += Double(steps) * dabWork
        guard totalDabs <= maximumDabCount else { return false }
        previous = point
      }
      guard totalDabs <= maximumDabCount, patchWork <= maximumNormalizedPatchWork + 1e-12
      else { return false }
    }
    return true
  }

  private struct Dab {
    var strokeIndex: Int
    var center: SIMD2<Double>
    var radius: Double
    var sourceOffset: SIMD2<Double>?
  }

  private struct ExclusionIndex {
    var dabs: [Dab]
    var buckets: [SIMD2<Int>: [Int]] = [:]
    var maximumRadius: Double
    var cellSize: Double

    init(dabs: [Dab]) {
      self.dabs = dabs
      maximumRadius = dabs.map(\.radius).max() ?? 1
      cellSize = max(4, maximumRadius * 2 + 2)
      for (index, dab) in dabs.enumerated() {
        let key = SIMD2(Int(floor(dab.center.x / cellSize)), Int(floor(dab.center.y / cellSize)))
        buckets[key, default: []].append(index)
      }
    }

    func overlaps(center: SIMD2<Double>, radius: Double) -> Bool {
      let reach = radius + maximumRadius + 1
      let x0 = Int(floor((center.x - reach) / cellSize))
      let x1 = Int(floor((center.x + reach) / cellSize))
      let y0 = Int(floor((center.y - reach) / cellSize))
      let y1 = Int(floor((center.y + reach) / cellSize))
      for y in y0...y1 {
        for x in x0...x1 {
          for index in buckets[SIMD2(x, y)] ?? [] {
            let dab = dabs[index]
            if hypot(dab.center.x - center.x, dab.center.y - center.y) < dab.radius + radius + 1 {
              return true
            }
          }
        }
      }
      return false
    }
  }

  /// A prefix over the bounded identification mask, never the full sensor raster.
  /// Rectangular queries conservatively cover donor texture and its sampled ring.
  private struct MaskExclusionIndex {
    let width: Int
    let height: Int
    let stride: Int
    let counts: [UInt32]

    init?(mask: UInt16Image) {
      guard mask.channels == 1, mask.width > 0, mask.height > 0,
        mask.width <= DustRepair.maximumPlanningMaskDimension,
        mask.height <= DustRepair.maximumPlanningMaskDimension,
        mask.pixels.count == mask.width * mask.height
      else { return nil }
      width = mask.width
      height = mask.height
      stride = width + 1
      var prefix = [UInt32](repeating: 0, count: stride * (height + 1))
      for y in 0..<height {
        guard !Task.isCancelled else { return nil }
        var rowCount: UInt32 = 0
        for x in 0..<width {
          if mask.pixels[y * width + x] != 0 { rowCount += 1 }
          prefix[(y + 1) * stride + x + 1] = prefix[y * stride + x + 1] + rowCount
        }
      }
      counts = prefix
    }

    func overlaps(
      center: SIMD2<Double>, radius: Double, imageWidth: Int, imageHeight: Int
    ) -> Bool {
      // The color-match ring extends one source pixel beyond the patch;
      // bilinear interpolation adds another. Project pixel centers into the
      // full-source mask, rounding outward even when its resolution differs.
      let margin = radius + 2
      let scaleX = Double(width) / Double(imageWidth)
      let scaleY = Double(height) / Double(imageHeight)
      let x0 = max(0, Int(floor((center.x - margin + 0.5) * scaleX - 0.5)))
      let x1 = min(width - 1, Int(ceil((center.x + margin + 0.5) * scaleX - 0.5)))
      let y0 = max(0, Int(floor((center.y - margin + 0.5) * scaleY - 0.5)))
      let y1 = min(height - 1, Int(ceil((center.y + margin + 0.5) * scaleY - 0.5)))
      guard x0 <= x1, y0 <= y1 else { return false }
      return counts[(y1 + 1) * stride + x1 + 1] + counts[y0 * stride + x0]
        > counts[y0 * stride + x1 + 1] + counts[(y1 + 1) * stride + x0]
    }
  }

  public static func apply(to image: UInt16Image, strokes: [DustRepairStroke]) -> UInt16Image {
    guard !strokes.isEmpty, image.channels == 1 || image.channels == 3 else { return image }
    guard canApply(strokes: strokes, imageWidth: image.width, imageHeight: image.height)
    else { return image }
    // This is the sole full-image allocation. Donors always sample the immutable
    // scan; later strokes cannot accidentally copy pixels from earlier repairs.
    var pixels = image.pixels
    let dabs = makeDabs(in: image, strokes: strokes)
    visitDonorMatches(in: image, dabs: dabs) { dab, match in
      if let match {
        heal(
          image: image, output: &pixels, center: dab.center, donor: match.point,
          radius: dab.radius, offsets: match.offsets)
      }
    }
    return UInt16Image(
      width: image.width, height: image.height, channels: image.channels, pixels: pixels)
  }

  /// Returns indices of strokes for which every interpolated dab has a usable donor on
  /// this source. Include existing repairs alongside proposed strokes so donor
  /// exclusion matches rendering. This makes no output raster and does not
  /// establish photographic quality or donor availability on another decode.
  /// Optional indices check only those strokes, while all supplied strokes
  /// remain donor exclusions. Invalid requested indices return no results.
  /// Cancellation returns no indices, including any already checked strokes.
  public static func applicableStrokeIndices(
    in image: UInt16Image, strokes: [DustRepairStroke],
    checkingStrokeIndices: Set<Int>? = nil
  ) -> [Int] {
    guard !Task.isCancelled, !strokes.isEmpty, image.channels == 1 || image.channels == 3,
      canApply(strokes: strokes, imageWidth: image.width, imageHeight: image.height),
      checkingStrokeIndices?.allSatisfy({ strokes.indices.contains($0) }) ?? true,
      !(checkingStrokeIndices?.isEmpty ?? false)
    else { return [] }
    var applicable = [Bool](repeating: true, count: strokes.count)
    let dabs = makeDabs(in: image, strokes: strokes)
    let completed = visitDonorMatches(
      in: image, dabs: dabs, shouldCancel: { Task.isCancelled },
      shouldVisit: { checkingStrokeIndices?.contains($0.strokeIndex) ?? true },
      visit: { dab, match in
        if case nil = match { applicable[dab.strokeIndex] = false }
      })
    guard completed, !Task.isCancelled else { return [] }
    return strokes.indices.filter {
      (checkingStrokeIndices?.contains($0) ?? true) && applicable[$0]
    }
  }

  /// Plans one-point stamps with explicit donors so removing rejected proposals
  /// cannot make their marked pixels eligible texture when the saved set renders.
  /// Include existing repairs for exclusions; multipoint strokes are not returned.
  /// Existing explicit source points stay unchanged. Normalized donor coordinates
  /// persist through the existing stroke format, but this source's plan does not
  /// establish donor quality or availability on a different decode.
  /// An optional full-source mask excludes all marked pixels from automatic
  /// donors, including unproposed components. It may have a different resolution
  /// but must have one channel and dimensions at most 2048; otherwise no plans
  /// are returned. This never changes deliberate explicit donor choices.
  /// Optional indices plan only those stamps, with all supplied strokes still
  /// excluded from donors. Invalid requested indices return no plans.
  /// Cancellation returns no plans, including any already checked stamps.
  public static func plannedSinglePointRepairs(
    in image: UInt16Image, strokes: [DustRepairStroke], excludingMask mask: UInt16Image? = nil,
    planningStrokeIndices: Set<Int>? = nil
  ) -> [PlannedDustRepair] {
    guard !Task.isCancelled, !strokes.isEmpty, image.channels == 1 || image.channels == 3,
      canApply(strokes: strokes, imageWidth: image.width, imageHeight: image.height),
      planningStrokeIndices?.allSatisfy({ strokes.indices.contains($0) }) ?? true,
      !(planningStrokeIndices?.isEmpty ?? false)
    else { return [] }
    let maskExclusions: MaskExclusionIndex?
    if let mask {
      guard let exclusions = MaskExclusionIndex(mask: mask) else { return [] }
      maskExclusions = exclusions
    } else {
      maskExclusions = nil
    }
    let dabs = makeDabs(in: image, strokes: strokes)
    var plans: [PlannedDustRepair] = []
    let completed = visitDonorMatches(
      in: image, dabs: dabs, shouldCancel: { Task.isCancelled },
      shouldVisit: {
        strokes[$0.strokeIndex].points.count == 1
          && (planningStrokeIndices?.contains($0.strokeIndex) ?? true)
      },
      additionalDonorExclusion: { center, radius in
        maskExclusions?.overlaps(
          center: center, radius: radius, imageWidth: image.width, imageHeight: image.height)
          ?? false
      },
      visit: { dab, match in
        guard let match else { return }
        var stroke = strokes[dab.strokeIndex]
        if stroke.sourcePoint == nil {
          stroke.sourcePoint = SIMD2(
            (match.point.x + 0.5) / Double(image.width),
            (match.point.y + 0.5) / Double(image.height))
        }
        plans.append(PlannedDustRepair(strokeIndex: dab.strokeIndex, stroke: stroke))
      })
    guard completed, !Task.isCancelled else { return [] }
    return plans
  }

  private static func makeDabs(in image: UInt16Image, strokes: [DustRepairStroke]) -> [Dab] {
    makeDabs(imageWidth: image.width, imageHeight: image.height, strokes: strokes)
  }

  /// Reuses the renderer's interpolation, stationary-sample handling and minimum
  /// pixel radius without allocating a source raster. Donor applicability must
  /// be checked separately before consuming marked cells under these footprints.
  public static func renderFootprints(
    strokes: [DustRepairStroke], imageWidth: Int, imageHeight: Int
  ) -> [DustRepairFootprint] {
    guard !Task.isCancelled,
      canApply(strokes: strokes, imageWidth: imageWidth, imageHeight: imageHeight)
    else { return [] }
    let dabs = makeDabs(imageWidth: imageWidth, imageHeight: imageHeight, strokes: strokes)
    guard !Task.isCancelled else { return [] }
    return dabs.map { DustRepairFootprint(center: $0.center, radius: $0.radius) }
  }

  private static func makeDabs(
    imageWidth: Int, imageHeight: Int, strokes: [DustRepairStroke]
  ) -> [Dab] {
    let width = Double(imageWidth)
    let height = Double(imageHeight)
    func pixelPoint(_ point: SIMD2<Double>) -> SIMD2<Double> {
      SIMD2(point.x * width - 0.5, point.y * height - 0.5)
    }
    var dabs: [Dab] = []
    for (strokeIndex, stroke) in strokes.enumerated() {
      let radius = max(stroke.radius * width, 0.75)
      let sourceOffset = stroke.sourcePoint.map { pixelPoint($0) - pixelPoint(stroke.points[0]) }
      var previous: SIMD2<Double>?
      for point in stroke.points {
        let end = pixelPoint(point)
        // Pointer release can repeat the last sample. A stationary sample must
        // not apply another feather blend or spend another dab of the budget.
        if end == previous { continue }
        let start = previous ?? end
        let delta = end - start
        let distance = hypot(delta.x, delta.y)
        let steps = max(1, Int(ceil(distance / max(radius * 0.5, 0.5))))
        for step in 1...steps {
          let center = start + delta * (Double(step) / Double(steps))
          dabs.append(
            Dab(
              strokeIndex: strokeIndex, center: center, radius: radius, sourceOffset: sourceOffset))
        }
        previous = end
      }
    }
    return dabs
  }

  private struct DonorMatch {
    var point: SIMD2<Double>
    var offsets: [Double]
  }

  @discardableResult
  private static func visitDonorMatches(
    in image: UInt16Image, dabs: [Dab], shouldCancel: () -> Bool = { false },
    shouldVisit: (Dab) -> Bool = { _ in true },
    additionalDonorExclusion: (SIMD2<Double>, Double) -> Bool = { _, _ in false },
    visit: (Dab, DonorMatch?) -> Void
  ) -> Bool {
    let exclusions = ExclusionIndex(dabs: dabs)
    for dab in dabs {
      guard !shouldCancel() else { return false }
      guard shouldVisit(dab) else { continue }
      let donor =
        dab.sourceOffset.map { dab.center + $0 }
        ?? automaticDonor(
          in: image, center: dab.center, radius: dab.radius, exclusions: exclusions,
          additionalExclusion: additionalDonorExclusion)
      if let donor,
        let boundary = boundaryMatch(
          in: image, center: dab.center, donor: donor, radius: dab.radius)
      {
        visit(dab, DonorMatch(point: donor, offsets: boundary.offsets))
      } else {
        visit(dab, nil)
      }
    }
    return true
  }

  /// Converts only small, compact mask components into opt-in healing stamps.
  /// A row-run scan keeps auxiliary storage bounded by image width, even for a
  /// rejected component covering the entire photograph. Long scratches, borders,
  /// large regions, and thin connected structures are excluded conservatively.
  public static func automaticRepairs(
    from mask: UInt16Image, maximumCount: Int = 250
  ) -> [DustRepairStroke] {
    automaticRepairCandidates(from: mask, maximumCount: maximumCount).map(\.stroke)
  }

  /// Retains a valid marked-pixel seed for each conservatively accepted mask
  /// component. Candidate order and stamps match `automaticRepairs` exactly.
  public static func automaticRepairCandidates(
    from mask: UInt16Image, maximumCount: Int = 250
  ) -> [MaskRepairCandidate] {
    guard mask.channels == 1, maximumCount > 0 else { return [] }
    let limit = min(maximumCount, 500)
    struct Run {
      var first: Int
      var last: Int
      var label: Int
    }
    struct Component {
      var x0: Int
      var x1: Int
      var y0: Int
      var y1: Int
      var area: Int
      var seed: SIMD2<Int>
      mutating func merge(_ other: Component) {
        x0 = min(x0, other.x0)
        x1 = max(x1, other.x1)
        y0 = min(y0, other.y0)
        y1 = max(y1, other.y1)
        area += other.area
      }
    }
    var previous: [Run] = []
    var components: [Int: Component] = [:]
    var nextLabel = 0
    var candidates: [MaskRepairCandidate] = []
    let maximumArea = max(16, min(4_096, mask.width * mask.height / 40_000))
    let maximumRadius = min(
      maximumNormalizedRadius * Double(mask.width), max(4, Double(mask.width) * 0.0125))
    func finish(_ component: Component) {
      let w = component.x1 - component.x0 + 1
      let h = component.y1 - component.y0 + 1
      let radius = hypot(Double(w), Double(h)) / 2 + 1
      guard component.area <= maximumArea, radius <= maximumRadius,
        max(w, h) <= max(3, min(w, h) * 3),
        Double(component.area) / Double(w * h) >= 0.25,
        component.x0 > 0, component.y0 > 0,
        component.x1 < mask.width - 1, component.y1 < mask.height - 1
      else { return }
      candidates.append(
        MaskRepairCandidate(
          stroke: DustRepairStroke(
            points: [
              SIMD2(
                Double(component.x0 + component.x1 + 1) / (2 * Double(mask.width)),
                Double(component.y0 + component.y1 + 1) / (2 * Double(mask.height)))
            ],
            radius: radius / Double(mask.width)),
          maskSeed: component.seed))
    }
    for y in 0...mask.height {
      var current: [Run] = []
      var parents: [Int: Int] = [:]
      func root(_ label: Int) -> Int {
        var result = label
        while let parent = parents[result] { result = parent }
        return result
      }
      if y < mask.height {
        var x = 0
        var previousCursor = 0
        while x < mask.width {
          guard mask.pixels[y * mask.width + x] != 0 else {
            x += 1
            continue
          }
          let first = x
          while x + 1 < mask.width, mask.pixels[y * mask.width + x + 1] != 0 { x += 1 }
          let last = x
          while previousCursor < previous.count, previous[previousCursor].last < first - 1 {
            previousCursor += 1
          }
          var neighbors: [Int] = []
          var cursor = previousCursor
          while cursor < previous.count, previous[cursor].first <= last + 1 {
            let label = root(previous[cursor].label)
            if !neighbors.contains(label) { neighbors.append(label) }
            cursor += 1
          }
          let label: Int
          if let existing = neighbors.first {
            label = existing
            for other in neighbors.dropFirst() where other != label {
              if let merged = components.removeValue(forKey: other) {
                components[label]?.merge(merged)
              }
              parents[other] = label
            }
            components[label]?.merge(
              Component(
                x0: first, x1: last, y0: y, y1: y, area: last - first + 1,
                seed: SIMD2(first, y)))
          } else {
            label = nextLabel
            nextLabel += 1
            components[label] = Component(
              x0: first, x1: last, y0: y, y1: y, area: last - first + 1,
              seed: SIMD2(first, y))
          }
          current.append(Run(first: first, last: last, label: label))
          x += 1
        }
      }
      for index in current.indices { current[index].label = root(current[index].label) }
      let active = Set(current.map(\.label))
      // Sorting makes component completion order stable across dictionary seeds.
      let complete = components.keys.filter { !active.contains($0) }.sorted()
      for label in complete {
        if let component = components.removeValue(forKey: label) { finish(component) }
        if candidates.count == limit { return candidates }
      }
      previous = current
    }
    return candidates
  }

  private static func validPoint(_ point: SIMD2<Double>) -> Bool {
    point.x.isFinite && point.y.isFinite && point.x >= 0 && point.x <= 1
      && point.y >= 0 && point.y <= 1
  }

  private static func sample(_ image: UInt16Image, x: Double, y: Double, channel: Int) -> Double? {
    guard x >= 0, y >= 0, x <= Double(image.width - 1), y <= Double(image.height - 1)
    else { return nil }
    let x0 = Int(x)
    let y0 = Int(y)
    let x1 = min(x0 + 1, image.width - 1)
    let y1 = min(y0 + 1, image.height - 1)
    let fx = x - Double(x0)
    let fy = y - Double(y0)
    let a = Double(image.pixels[(y0 * image.width + x0) * image.channels + channel])
    let b = Double(image.pixels[(y0 * image.width + x1) * image.channels + channel])
    let c = Double(image.pixels[(y1 * image.width + x0) * image.channels + channel])
    let d = Double(image.pixels[(y1 * image.width + x1) * image.channels + channel])
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
  }

  private static func boundaryMatch(
    in image: UInt16Image, center: SIMD2<Double>, donor: SIMD2<Double>, radius: Double
  ) -> (offsets: [Double], error: Double)? {
    // Require a complete donor patch; clipping a donor silently smears borders.
    guard donor.x - radius >= 0, donor.y - radius >= 0,
      donor.x + radius <= Double(image.width - 1),
      donor.y + radius <= Double(image.height - 1)
    else { return nil }
    var differences = [[Double]](repeating: [], count: image.channels)
    for channel in differences.indices { differences[channel].reserveCapacity(32) }
    var count = 0
    let ring = radius + 1
    for index in 0..<32 {
      let angle = Double(index) * .pi / 16
      let delta = SIMD2(cos(angle) * ring, sin(angle) * ring)
      guard
        let destination = sample(image, x: center.x + delta.x, y: center.y + delta.y, channel: 0),
        let source = sample(image, x: donor.x + delta.x, y: donor.y + delta.y, channel: 0)
      else { continue }
      for channel in 0..<image.channels {
        let a =
          channel == 0
          ? destination
          : sample(image, x: center.x + delta.x, y: center.y + delta.y, channel: channel)!
        let b =
          channel == 0
          ? source
          : sample(image, x: donor.x + delta.x, y: donor.y + delta.y, channel: channel)!
        differences[channel].append(a - b)
      }
      count += 1
    }
    guard count >= 8 else { return nil }
    // The boundary may cross the same scratch at a few angles, or interpolate
    // the edge of a dust spot. Those samples must not pull clean donor texture
    // toward the defect's color. A median retains the surrounding color offset;
    // trimmed residual energy compares donors without those sparse outliers.
    let offsets = differences.map { values -> Double in
      let sorted = values.sorted()
      return (sorted[(count - 1) / 2] + sorted[count / 2]) / 2
    }
    let retainedCount = max(1, count * 3 / 4)
    let error = (0..<image.channels).reduce(0.0) { total, channel in
      let residuals = differences[channel].map { value in
        let residual = value - offsets[channel]
        return residual * residual
      }.sorted()
      return total + residuals.prefix(retainedCount).reduce(0, +) / Double(retainedCount)
    }
    return (offsets, error)
  }

  private static func automaticDonor(
    in image: UInt16Image, center: SIMD2<Double>, radius: Double,
    exclusions: ExclusionIndex,
    additionalExclusion: (SIMD2<Double>, Double) -> Bool = { _, _ in false }
  ) -> SIMD2<Double>? {
    var best: SIMD2<Double>?
    var bestError = Double.infinity
    for multiplier in [2.5, 4.0, 6.0] {
      for direction in 0..<16 {
        let angle = Double(direction) * .pi / 8
        let distance = max(radius * multiplier, 4)
        let donor = center + SIMD2(cos(angle) * distance, sin(angle) * distance)
        guard !exclusions.overlaps(center: donor, radius: radius),
          !additionalExclusion(donor, radius),
          let boundary = boundaryMatch(in: image, center: center, donor: donor, radius: radius)
        else { continue }
        // Favor nearer donors on an exact match. Direction order breaks ties.
        let error = boundary.error + distance * 0.000_001
        if error < bestError {
          best = donor
          bestError = error
        }
      }
    }
    return best
  }

  private static func heal(
    image: UInt16Image, output: inout [UInt16], center: SIMD2<Double>, donor: SIMD2<Double>,
    radius: Double, offsets: [Double]
  ) {
    let x0 = max(0, Int(floor(center.x - radius)))
    let x1 = min(image.width - 1, Int(ceil(center.x + radius)))
    let y0 = max(0, Int(floor(center.y - radius)))
    let y1 = min(image.height - 1, Int(ceil(center.y + radius)))
    for y in y0...y1 {
      for x in x0...x1 {
        let dx = Double(x) - center.x
        let dy = Double(y) - center.y
        let distance = hypot(dx, dy) / radius
        guard distance < 1 else { continue }
        let t = min(max((1 - distance) / 0.3, 0), 1)
        let alpha = t * t * (3 - 2 * t)
        for channel in 0..<image.channels {
          guard let source = sample(image, x: donor.x + dx, y: donor.y + dy, channel: channel)
          else { continue }
          let index = (y * image.width + x) * image.channels + channel
          let corrected = min(max(source + offsets[channel], 0), 65_535)
          let blended = Double(output[index]) * (1 - alpha) + corrected * alpha
          output[index] = UInt16(blended.rounded())
        }
      }
    }
  }
}
