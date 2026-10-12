import FilmScanEngine
import Foundation

/// Mask strokes share the healing brush's normalized, top-left source space.
/// Identification stays separate from repair: painting this mask changes no pixels.
enum DustMaskEditing {
  static func painting(
    _ mask: UInt16Image, points: [SIMD2<Double>], radius: Double, erasing: Bool
  ) -> UInt16Image {
    painting(mask, strokes: [.init(points: points, radius: radius)], erasing: erasing)
  }

  static func erasing(_ mask: UInt16Image, repairs: [DustRepairStroke]) -> UInt16Image {
    painting(mask, strokes: repairs, erasing: true)
  }

  /// A manual repair consumes only cells whose represented source pixel centers
  /// all lie in one renderer dab's positive feather footprint. A coarse mask
  /// cell remains marked when any represented pixel falls outside that dab.
  /// Finer masks, cancelled checks and excessive work preserve the original mask.
  static func consumingRepairFootprints(
    _ mask: UInt16Image, repairs: [DustRepairStroke], sourceWidth: Int, sourceHeight: Int
  ) -> UInt16Image {
    guard !Task.isCancelled, mask.channels == 1,
      mask.width <= DustRepair.maximumPlanningMaskDimension,
      mask.height <= DustRepair.maximumPlanningMaskDimension,
      mask.width <= sourceWidth, mask.height <= sourceHeight,
      sourceWidth <= Int.max / (mask.width * 2),
      sourceHeight <= Int.max / (mask.height * 2)
    else { return mask }
    let footprints = DustRepair.renderFootprints(
      strokes: repairs, imageWidth: sourceWidth, imageHeight: sourceHeight)
    guard !footprints.isEmpty else { return mask }

    // ceil(boundary * sourceSize / maskSize - 0.5), computed with integers
    // so a source pixel center exactly on a cell boundary belongs to its
    // right/bottom cell. Positive image dimensions make negative values > -1.
    func firstPixel(_ boundary: Int, sourceSize: Int, maskSize: Int) -> Int {
      let numerator = 2 * boundary * sourceSize - maskSize
      let denominator = 2 * maskSize
      return numerator <= 0 ? numerator / denominator : (numerator - 1) / denominator + 1
    }
    let xStarts = (0...mask.width).map {
      firstPixel($0, sourceSize: sourceWidth, maskSize: mask.width)
    }
    let yStarts = (0...mask.height).map {
      firstPixel($0, sourceSize: sourceHeight, maskSize: mask.height)
    }
    var pixels = mask.pixels
    var checked = 0
    let maximumChecks = 8_388_608
    let scaleX = Double(mask.width) / Double(sourceWidth)
    let scaleY = Double(mask.height) / Double(sourceHeight)
    for footprint in footprints {
      guard !Task.isCancelled else { return mask }
      let center = footprint.center
      let radius = footprint.radius
      let x0 = max(0, Int(floor((center.x - radius + 0.5) * scaleX)))
      let x1 = min(mask.width - 1, Int(floor((center.x + radius + 0.5) * scaleX)))
      let y0 = max(0, Int(floor((center.y - radius + 0.5) * scaleY)))
      let y1 = min(mask.height - 1, Int(floor((center.y + radius + 0.5) * scaleY)))
      guard x0 <= x1, y0 <= y1 else { continue }
      for y in y0...y1 {
        guard !Task.isCancelled else { return mask }
        for x in x0...x1 {
          checked += 1
          guard checked <= maximumChecks else { return mask }
          let index = y * mask.width + x
          guard pixels[index] != 0 else { continue }
          let firstX = max(0, xStarts[x])
          let lastX = min(sourceWidth - 1, xStarts[x + 1] - 1)
          let firstY = max(0, yStarts[y])
          let lastY = min(sourceHeight - 1, yStarts[y + 1] - 1)
          guard firstX <= lastX, firstY <= lastY else { continue }
          let dx = max(abs(Double(firstX) - center.x), abs(Double(lastX) - center.x))
          let dy = max(abs(Double(firstY) - center.y), abs(Double(lastY) - center.y))
          // This is exactly the renderer's strict positive-footprint test.
          if hypot(dx, dy) / radius < 1 { pixels[index] = 0 }
        }
      }
    }
    guard !Task.isCancelled else { return mask }
    return UInt16Image(width: mask.width, height: mask.height, channels: 1, pixels: pixels)
  }

  /// Automatic stamps extend beyond the identified component to feather the
  /// texture. Consume only that original component, preserving adjacent rejected
  /// candidates even when a successful stamp's feather overlaps them.
  static func consumingComponents(
    _ mask: UInt16Image, candidates: [MaskRepairCandidate]
  ) -> UInt16Image {
    guard mask.channels == 1, candidates.count <= 500 else { return mask }
    var pixels = mask.pixels
    for candidate in candidates {
      guard !Task.isCancelled else { return mask }
      let seed = candidate.maskSeed
      guard seed.x >= 0, seed.y >= 0, seed.x < mask.width, seed.y < mask.height else { continue }
      let first = seed.y * mask.width + seed.x
      guard pixels[first] != 0 else { continue }
      var queue = [first]
      var visited: Set<Int> = [first]
      var cursor = 0
      while cursor < queue.count && visited.count <= 4_096 {
        let index = queue[cursor]
        cursor += 1
        let x = index % mask.width
        let y = index / mask.width
        for dy in -1...1 {
          for dx in -1...1 where dx != 0 || dy != 0 {
            let nx = x + dx
            let ny = y + dy
            guard nx >= 0, ny >= 0, nx < mask.width, ny < mask.height else { continue }
            let neighbor = ny * mask.width + nx
            if mask.pixels[neighbor] != 0, visited.insert(neighbor).inserted {
              queue.append(neighbor)
            }
          }
        }
      }
      // Extraction never accepts more than 4096 pixels. Refuse mismatched or
      // stale seeds conservatively rather than partially clearing a large area.
      guard visited.count <= 4_096 else { continue }
      for index in queue { pixels[index] = 0 }
    }
    return UInt16Image(width: mask.width, height: mask.height, channels: 1, pixels: pixels)
  }

  private static func painting(
    _ mask: UInt16Image, strokes: [DustRepairStroke], erasing: Bool
  ) -> UInt16Image {
    guard mask.channels == 1, strokes.count <= DustRepair.maximumStrokeCount,
      strokes.allSatisfy({ stroke in
        stroke.radius.isFinite && stroke.radius > 0 && stroke.radius <= 0.1
          && !stroke.points.isEmpty && stroke.points.count <= DustRepair.maximumPointsPerStroke
          && stroke.points.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
          }
      })
    else { return mask }
    var pixels = mask.pixels
    let value: UInt16 = erasing ? 0 : .max
    func dab(_ point: SIMD2<Double>, radius r: Double) {
      let cx = point.x * Double(mask.width) - 0.5
      let cy = point.y * Double(mask.height) - 0.5
      let minX = max(0, Int(floor(cx - r)))
      let maxX = min(mask.width - 1, Int(ceil(cx + r)))
      let minY = max(0, Int(floor(cy - r)))
      let maxY = min(mask.height - 1, Int(ceil(cy + r)))
      guard minX <= maxX, minY <= maxY else { return }
      for y in minY...maxY {
        for x in minX...maxX {
          if pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2) <= r * r {
            pixels[y * mask.width + x] = value
          }
        }
      }
    }
    for stroke in strokes {
      let r = max(1, stroke.radius * Double(mask.width))
      dab(stroke.points[0], radius: r)
      for index in stroke.points.indices.dropFirst() {
        let previous = stroke.points[index - 1]
        let point = stroke.points[index]
        guard point != previous else { continue }
        let delta = point - previous
        let distance = hypot(delta.x * Double(mask.width), delta.y * Double(mask.height))
        let steps = max(1, Int(ceil(distance / max(1, r * 0.5))))
        for step in 1...steps {
          dab(previous + delta * (Double(step) / Double(steps)), radius: r)
        }
      }
    }
    return UInt16Image(width: mask.width, height: mask.height, channels: 1, pixels: pixels)
  }
}
