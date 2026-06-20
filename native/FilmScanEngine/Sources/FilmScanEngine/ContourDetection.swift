import Foundation

public struct RotatedRect: Codable, Equatable, Sendable {
  public var centerX: Double
  public var centerY: Double
  public var width: Double
  public var height: Double
  public var angle: Double

  public init(centerX: Double, centerY: Double, width: Double, height: Double, angle: Double) {
    self.centerX = centerX
    self.centerY = centerY
    self.width = width
    self.height = height
    self.angle = angle
  }

  public var boxPoints: [(x: Float, y: Float)] {
    let angleRad = angle * .pi / 180.0
    let cosA = cos(angleRad)
    let sinA = sin(angleRad)
    let hw = width / 2
    let hh = height / 2
    let corners = [
      (hw, -hh),
      (hw, hh),
      (-hw, hh),
      (-hw, -hh),
    ]
    return corners.map { (dx, dy) in
      let rx = cosA * dx - sinA * dy + centerX
      let ry = sinA * dx + cosA * dy + centerY
      return (Float(rx), Float(ry))
    }
  }
}

public enum ContourDetection {

  public static func findOptimalCrop(
    threshold: UInt16Image,
    maxDimension: Int = 2000
  ) -> (threshold: UInt16Image, rect: RotatedRect, contourPoints: [SIMD2<Double>])? {
    precondition(threshold.channels == 1, "Threshold image must be single-channel")

    let working: UInt16Image
    let scale: Double
    let largestDim = max(threshold.width, threshold.height)
    if largestDim > maxDimension {
      scale = Double(maxDimension) / Double(largestDim)
      working = threshold.resizedToFit(maxDimension: maxDimension)
    } else {
      scale = 1.0
      working = threshold
    }

    let components = largestConnectedComponent(binary: working, foregroundValue: 255)

    let hull = convexHull(components.points)
    guard hull.count >= 3 else { return nil }

    let rect = minAreaRect(hull)

    let scaledRect: RotatedRect
    if scale < 1.0 {
      let invScale = 1.0 / scale
      scaledRect = RotatedRect(
        centerX: rect.centerX * invScale,
        centerY: rect.centerY * invScale,
        width: rect.width * invScale,
        height: rect.height * invScale,
        angle: rect.angle
      )
    } else {
      scaledRect = rect
    }

    let scaledHull: [SIMD2<Double>]
    if scale < 1.0 {
      let invScale = 1.0 / scale
      scaledHull = hull.map { SIMD2($0.x * invScale, $0.y * invScale) }
    } else {
      scaledHull = hull
    }

    let normalized = normalizeToUnit(scaledRect, imageWidth: threshold.width, imageHeight: threshold.height)
    return (threshold, normalized, scaledHull)
  }

  public static func normalizeToUnit(
    _ rect: RotatedRect,
    imageWidth: Int,
    imageHeight: Int
  ) -> RotatedRect {
    RotatedRect(
      centerX: rect.centerX / Double(imageHeight),
      centerY: rect.centerY / Double(imageWidth),
      width: rect.width / Double(imageHeight),
      height: rect.height / Double(imageWidth),
      angle: rect.angle
    )
  }

  public static func denormalize(
    _ rect: RotatedRect,
    imageWidth: Int,
    imageHeight: Int
  ) -> RotatedRect {
    RotatedRect(
      centerX: rect.centerX * Double(imageHeight),
      centerY: rect.centerY * Double(imageWidth),
      width: rect.width * Double(imageHeight),
      height: rect.height * Double(imageWidth),
      angle: rect.angle
    )
  }

  // MARK: - Connected Component Labeling

  private struct UnionFind {
    private var parent: [Int]
    fileprivate var sizes: [Int]

    init(count: Int) {
      parent = Array(0..<count)
      sizes = Array(repeating: 1, count: count)
    }

    mutating func find(_ x: Int) -> Int {
      var root = x
      while parent[root] != root {
        parent[root] = parent[parent[root]]
        root = parent[root]
      }
      return root
    }

    mutating func union(_ a: Int, _ b: Int) {
      let ra = find(a)
      let rb = find(b)
      guard ra != rb else { return }
      if sizes[ra] < sizes[rb] {
        parent[ra] = rb
        sizes[rb] += sizes[ra]
      } else {
        parent[rb] = ra
        sizes[ra] += sizes[rb]
      }
    }
  }

  private struct ComponentResult {
    let points: [SIMD2<Double>]
    let pixelCount: Int
  }

  private static func largestConnectedComponent(
    binary: UInt16Image,
    foregroundValue: UInt16
  ) -> ComponentResult {
    let w = binary.width
    let h = binary.height
    let pixelCount = w * h
    var uf = UnionFind(count: pixelCount + 1)

    for y in 0..<h {
      for x in 0..<w {
        let idx = y * w + x
        guard binary.pixels[idx] == foregroundValue else { continue }
        if x + 1 < w && binary.pixels[idx + 1] == foregroundValue {
          uf.union(idx, idx + 1)
        }
        if y + 1 < h && binary.pixels[idx + w] == foregroundValue {
          uf.union(idx, idx + w)
        }
      }
    }

    var componentRoots: [Int: Int] = [:]
    for y in 0..<h {
      for x in 0..<w {
        let idx = y * w + x
        guard binary.pixels[idx] == foregroundValue else { continue }
        let root = uf.find(idx)
        componentRoots[root] = uf.sizes[root]
      }
    }

    guard let largestRoot = componentRoots.max(by: { $0.value < $1.value })?.key else {
      return ComponentResult(points: [], pixelCount: 0)
    }

    var points: [SIMD2<Double>] = []
    points.reserveCapacity(uf.sizes[largestRoot])
    for y in 0..<h {
      for x in 0..<w {
        let idx = y * w + x
        guard binary.pixels[idx] == foregroundValue else { continue }
        if uf.find(idx) == largestRoot {
          points.append(SIMD2(Double(x), Double(y)))
        }
      }
    }

    return ComponentResult(points: points, pixelCount: uf.sizes[largestRoot])
  }

  // MARK: - Convex Hull (Andrew's Monotone Chain)

  public static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
    guard points.count > 2 else { return points }

    let sorted = points.sorted { a, b in
      if a.x == b.x { return a.y < b.y }
      return a.x < b.x
    }

    func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    var lower: [SIMD2<Double>] = []
    for p in sorted {
      while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
        lower.removeLast()
      }
      lower.append(p)
    }

    var upper: [SIMD2<Double>] = []
    for p in sorted.reversed() {
      while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
        upper.removeLast()
      }
      upper.append(p)
    }

    lower.removeLast()
    upper.removeLast()
    return lower + upper
  }

  // MARK: - Minimum Area Bounding Rectangle (Rotating Calipers)

  public static func minAreaRect(_ hull: [SIMD2<Double>]) -> RotatedRect {
    guard hull.count >= 3 else {
      return RotatedRect(centerX: 0, centerY: 0, width: 0, height: 0, angle: 0)
    }

    struct Edge {
      let start: SIMD2<Double>
      let dx: Double
      let dy: Double
      let length: Double
    }

    let n = hull.count
    var edges: [Edge] = []
    for i in 0..<n {
      let a = hull[i]
      let b = hull[(i + 1) % n]
      let dx = b.x - a.x
      let dy = b.y - a.y
      let len = sqrt(dx * dx + dy * dy)
      edges.append(Edge(start: a, dx: dx, dy: dy, length: len))
    }

    var minArea = Double.infinity
    var bestRect = RotatedRect(centerX: 0, centerY: 0, width: 0, height: 0, angle: 0)

    for edge in edges {
      guard edge.length > 0 else { continue }
      let ex = edge.dx / edge.length
      let ey = edge.dy / edge.length
      let ax = -ey
      let ay = ex

      var minProj = Double.infinity
      var maxProj = -Double.infinity
      var minPerp = Double.infinity
      var maxPerp = -Double.infinity
      for p in hull {
        let dx = p.x - edge.start.x
        let dy = p.y - edge.start.y
        let proj = dx * ex + dy * ey
        let perp = dx * ax + dy * ay
        if proj < minProj { minProj = proj }
        if proj > maxProj { maxProj = proj }
        if perp < minPerp { minPerp = perp }
        if perp > maxPerp { maxPerp = perp }
      }

      let w = maxProj - minProj
      let h = maxPerp - minPerp
      let area = w * h
      if area < minArea {
        minArea = area
        let cx = edge.start.x + ex * (minProj + maxProj) / 2 + ax * (minPerp + maxPerp) / 2
        let cy = edge.start.y + ey * (minProj + maxProj) / 2 + ay * (minPerp + maxPerp) / 2
        let angle = atan2(ey, ex) * 180.0 / .pi
        let correctedAngle = angle < 0 ? angle + 180 : angle
        bestRect = RotatedRect(
          centerX: cx,
          centerY: cy,
          width: w,
          height: h,
          angle: correctedAngle
        )
      }
    }

    if bestRect.width < bestRect.height {
      bestRect = RotatedRect(
        centerX: bestRect.centerX,
        centerY: bestRect.centerY,
        width: bestRect.height,
        height: bestRect.width,
        angle: bestRect.angle + 90
      )
    }

    return bestRect
  }
}
