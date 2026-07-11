import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Contour detection")
struct ContourDetectionTests {

  @Test("findOptimalCrop returns a valid rotated rect for a synthetic tilted rectangle")
  func findOptimalCropTiltedRectangle() throws {
    let w = 200
    let h = 160
    var pixels = [UInt16](repeating: 0, count: w * h)
    for y in 40..<120 {
      for x in 50..<150 {
        pixels[y * w + x] = 255
      }
    }

    let threshold = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)
    let result = ContourDetection.findOptimalCrop(threshold: threshold, maxDimension: 2000)
    #expect(result != nil)

    guard let (_, rect, _) = result else { return }
    #expect(rect.centerX > 0)
    #expect(rect.centerY > 0)
    #expect(rect.width > 0)
    #expect(rect.height > 0)
    #expect(rect.angle >= 0)
  }

  @Test("findOptimalCrop scales coordinates correctly for large images")
  func findOptimalCropLargeImage() throws {
    let w = 3200
    let h = 2400
    let maxDim = 800
    var pixels = [UInt16](repeating: 0, count: w * h)
    let cx = 1600
    let cy = 1200
    let rw = 2000
    let rh = 1400
    for y in (cy - rh / 2)..<(cy + rh / 2) {
      for x in (cx - rw / 2)..<(cx + rw / 2) {
        guard x >= 0, x < w, y >= 0, y < h else { continue }
        pixels[y * w + x] = 255
      }
    }

    let threshold = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)
    let result = ContourDetection.findOptimalCrop(threshold: threshold, maxDimension: maxDim)
    #expect(result != nil)

    guard let (_, rect, contourPoints) = result else { return }
    #expect(rect.width > 0 && rect.height > 0)
    #expect(rect.centerX > 0 && rect.centerY > 0)
    #expect(contourPoints.map(\.x).max() ?? 0 > 2_000)
    #expect(contourPoints.map(\.y).max() ?? 0 > 1_500)
  }

  @Test("findOptimalCrop returns nil for empty threshold")
  func findOptimalCropEmptyThreshold() {
    let w = 100
    let h = 100
    let pixels = [UInt16](repeating: 0, count: w * h)
    let threshold = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)
    let result = ContourDetection.findOptimalCrop(threshold: threshold)
    #expect(result == nil)
  }

  @Test("convexHull returns the hull for a simple rectangle of points")
  func convexHullSimpleRectangle() {
    let points: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(0, 5),
      SIMD2(5, 1), SIMD2(7, 2), SIMD2(3, 3),
    ]
    let hull = ContourDetection.convexHull(points)
    #expect(hull.count >= 4)
    #expect(hull.count <= 6)
    let minX = hull.map(\.x).min()!
    let maxX = hull.map(\.x).max()!
    let minY = hull.map(\.y).min()!
    let maxY = hull.map(\.y).max()!
    #expect(minX == 0)
    #expect(maxX == 10)
    #expect(minY == 0)
    #expect(maxY == 5)
  }

  @Test("convexHull returns all points when all are extreme")
  func convexHullExtremePoints() {
    let points: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
    ]
    let hull = ContourDetection.convexHull(points)
    #expect(hull.count == 4)
  }

  @Test("convexHull handles collinear points")
  func convexHullCollinear() {
    let points: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(5, 0), SIMD2(10, 0), SIMD2(10, 5),
      SIMD2(10, 10), SIMD2(5, 10), SIMD2(0, 10), SIMD2(0, 5),
      SIMD2(2, 0), SIMD2(8, 0),
    ]
    let hull = ContourDetection.convexHull(points)
    #expect(hull.count == 4)
  }

  @Test("convexHull handles single point and two points")
  func convexHullSmallSets() {
    let one = ContourDetection.convexHull([SIMD2<Double>(1, 2)])
    #expect(one.count == 1)
    let two = ContourDetection.convexHull([SIMD2<Double>(0, 0), SIMD2<Double>(1, 1)])
    #expect(two.count == 2)
  }

  @Test("minAreaRect returns a valid rotated rect for a tilted rectangle point set")
  func minAreaRectTiltedRectangle() {
    var points: [SIMD2<Double>] = []
    let cx = 100.0
    let cy = 80.0
    let w = 60.0
    let h = 40.0
    let angle = 25.0 * .pi / 180.0
    let cosA = cos(angle)
    let sinA = sin(angle)
    for dx in stride(from: -w / 2, through: w / 2, by: 2) {
      for dy in stride(from: -h / 2, through: h / 2, by: 2) {
        let rx = cosA * dx - sinA * dy + cx
        let ry = sinA * dx + cosA * dy + cy
        points.append(SIMD2(rx, ry))
      }
    }

    let hull = ContourDetection.convexHull(points)
    let rect = ContourDetection.minAreaRect(hull)

    #expect(rect.width >= w * 0.9 && rect.width <= w * 1.1)
    #expect(rect.height >= h * 0.9 && rect.height <= h * 1.1)
    #expect(abs(rect.centerX - cx) < 5)
    #expect(abs(rect.centerY - cy) < 5)
  }

  @Test("minAreaRect handles a right triangle hull")
  func minAreaRectRightTriangle() {
    let points: [SIMD2<Double>] = [
      SIMD2(0, 0), SIMD2(100, 0), SIMD2(0, 50),
    ]
    let hull = ContourDetection.convexHull(points)
    let rect = ContourDetection.minAreaRect(hull)

    #expect(rect.width > 0)
    #expect(rect.height > 0)
    #expect(rect.width >= rect.height)
    #expect(rect.centerX > 0 && rect.centerX < 100)
    #expect(rect.centerY > 0 && rect.centerY < 50)
  }

  @Test("minAreaRect returns zero rect for fewer than 3 points")
  func minAreaRectDegenerateHull() {
    let twoPoints: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 10)]
    let rect = ContourDetection.minAreaRect(twoPoints)
    #expect(rect.width == 0)
    #expect(rect.height == 0)
  }

  @Test("RotatedRect boxPoints produces exactly 4 corner points")
  func boxPointsCount() {
    let rect = RotatedRect(centerX: 100, centerY: 80, width: 60, height: 40, angle: 25)
    let corners = rect.boxPoints
    #expect(corners.count == 4)
  }

  @Test("RotatedRect boxPoints corners form a rectangle with correct dimensions")
  func boxPointsDimensions() {
    let rect = RotatedRect(centerX: 100, centerY: 80, width: 60, height: 40, angle: 0)
    let corners = rect.boxPoints
    let xs = corners.map { Double($0.x) }
    let ys = corners.map { Double($0.y) }
    let dx = xs.max()! - xs.min()!
    let dy = ys.max()! - ys.min()!
    #expect(abs(dx - rect.width) < 1)
    #expect(abs(dy - rect.height) < 1)
  }

  @Test("RotatedRect boxPoints center matches input center")
  func boxPointsCenter() {
    let cx = 123.0
    let cy = 89.0
    let rect = RotatedRect(centerX: cx, centerY: cy, width: 60, height: 40, angle: 30)
    let corners = rect.boxPoints
    let avgX = corners.reduce(0.0) { $0 + Double($1.x) } / 4.0
    let avgY = corners.reduce(0.0) { $0 + Double($1.y) } / 4.0
    #expect(abs(avgX - cx) < 2)
    #expect(abs(avgY - cy) < 2)
  }

  @Test("RotatedRect boxPoints for a 90-degree rotated rectangle")
  func boxPoints90Degree() {
    let rect = RotatedRect(centerX: 100, centerY: 80, width: 60, height: 40, angle: 90)
    let corners = rect.boxPoints
    #expect(corners.count == 4)
    let xs = corners.map { Double($0.x) }
    let ys = corners.map { Double($0.y) }
    let xSpan = xs.max()! - xs.min()!
    let ySpan = ys.max()! - ys.min()!
    #expect(abs(xSpan - 40) < 3)
    #expect(abs(ySpan - 60) < 3)
  }

  @Test("normalizeToUnit converts pixel coordinates to unit range")
  func normalizeToUnitConversion() {
    let rect = RotatedRect(centerX: 240, centerY: 320, width: 200, height: 300, angle: 15)
    let normalized = ContourDetection.normalizeToUnit(rect, imageWidth: 480, imageHeight: 640)

    #expect(abs(normalized.centerX - 240.0 / 480.0) < 0.001)
    #expect(abs(normalized.centerY - 320.0 / 640.0) < 0.001)
    #expect(abs(normalized.width - 200.0 / 480.0) < 0.001)
    #expect(abs(normalized.height - 300.0 / 640.0) < 0.001)
    #expect(normalized.angle == rect.angle)
  }

  @Test("denormalize reverses normalizeToUnit")
  func denormalizeRoundTrip() {
    let original = RotatedRect(centerX: 300, centerY: 200, width: 150, height: 100, angle: 45)
    let normalized = ContourDetection.normalizeToUnit(original, imageWidth: 600, imageHeight: 400)
    let denormalized = ContourDetection.denormalize(normalized, imageWidth: 600, imageHeight: 400)

    #expect(abs(denormalized.centerX - original.centerX) < 0.001)
    #expect(abs(denormalized.centerY - original.centerY) < 0.001)
    #expect(abs(denormalized.width - original.width) < 0.001)
    #expect(abs(denormalized.height - original.height) < 0.001)
    #expect(denormalized.angle == original.angle)
  }

  @Test("Legacy transposed crop coordinates decode to the original pixel rectangle")
  func legacyTransposedCropCoordinates() {
    let legacy = RotatedRect(
      centerX: 300.0 / 400.0,
      centerY: 200.0 / 600.0,
      width: 150.0 / 400.0,
      height: 100.0 / 600.0,
      angle: 45
    )

    let decoded = ContourDetection.denormalize(
      legacy,
      imageWidth: 600,
      imageHeight: 400,
      coordinateSpace: .legacyTransposedAxes
    )

    #expect(decoded == RotatedRect(
      centerX: 300,
      centerY: 200,
      width: 150,
      height: 100,
      angle: 45
    ))
  }

  @Test("findOptimalCrop on threshold from a real image produces valid normalized rect")
  func findOptimalCropFromThreshold() throws {
    let fixture = try FixtureLoader.loadCase("threshold_d25_l100")
    let threshold = fixture.expected

    let result = ContourDetection.findOptimalCrop(threshold: threshold, maxDimension: 2000)
    #expect(result != nil, "Should find crop for non-empty threshold")

    guard let (_, rect, _) = result else { return }

    #expect(rect.centerX >= 0 && rect.centerX <= 2)
    #expect(rect.centerY >= 0 && rect.centerY <= 2)
    #expect(rect.width > 0)
    #expect(rect.height > 0)
    #expect(rect.angle >= 0 && rect.angle < 360)
  }

  @Test("findOptimalCrop negative-angle rectangle produces valid rect")
  func findOptimalCropNegativeAngle() {
    let w = 200
    let h = 200
    var pixels = [UInt16](repeating: 0, count: w * h)
    let angle = -15.0 * .pi / 180.0
    let cosA = cos(angle)
    let sinA = sin(angle)
    let cx = 100.0
    let cy = 100.0
    let rw = 80.0
    let rh = 50.0
    for dy in stride(from: -rh / 2, through: rh / 2, by: 1) {
      for dx in stride(from: -rw / 2, through: rw / 2, by: 1) {
        let rx = cosA * dx - sinA * dy + cx
        let ry = sinA * dx + cosA * dy + cy
        let ix = Int(rx.rounded())
        let iy = Int(ry.rounded())
        if ix >= 0, ix < w, iy >= 0, iy < h {
          pixels[iy * w + ix] = 255
        }
      }
    }

    let threshold = UInt16Image(width: w, height: h, channels: 1, pixels: pixels)
    let result = ContourDetection.findOptimalCrop(threshold: threshold)
    #expect(result != nil)
    guard let (_, rect, _) = result else { return }
    #expect(rect.width > 0 && rect.height > 0)
    #expect(rect.centerX > 0 && rect.centerY > 0)
  }
}
