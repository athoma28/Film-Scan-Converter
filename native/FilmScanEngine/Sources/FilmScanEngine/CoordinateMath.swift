import Foundation

enum CoordinateMath {
  private struct Point {
    let x: Double
    let y: Double
  }

  private struct Offset {
    var x = 0.0
    var y = 0.0
  }

  static func shrinkBox(
    box: [(x: Double, y: Double)],
    xPercent: Double,
    yPercent: Double
  ) -> [(x: Int, y: Int)] {
    precondition(box.count == 4, "shrinkBox requires exactly 4 corner points")

    let points = box.map { Point(x: $0.x, y: $0.y) }
    let sortedX = points.map(\.x).sorted()
    let sortedY = points.map(\.y).sorted()
    let referenceIndex = pythonCompatibleReferenceIndex(in: points)
    let ordered = rotateLeft(points, by: referenceIndex)

    let h = (sortedY[2] + sortedY[3] - sortedY[0] - sortedY[1]) / 2
    let w = (sortedX[2] + sortedX[3] - sortedX[0] - sortedX[1]) / 2
    let pythonSkewCompensation = (ordered[3].x - ordered[0].x) / w * 1.5
    let centreX = ordered.map(\.x).reduce(0, +) / 4
    let centreY = ordered.map(\.y).reduce(0, +) / 4
    let yOffsetAmount = yPercent / 100 * h
    let xOffsetAmount = xPercent / 100 * w

    var offsets = [Offset](repeating: Offset(), count: ordered.count)
    for index in ordered.indices {
      let point = ordered[index]
      if point.y < centreY {
        offsets[index].y += Double(Int(yOffsetAmount))
      } else if point.y > centreY {
        offsets[index].y -= Double(Int(yOffsetAmount))
      }
      if point.x < centreX {
        offsets[index].x += Double(Int(xOffsetAmount))
      } else if point.x > centreX {
        offsets[index].x -= Double(Int(xOffsetAmount))
      }
    }

    for index in offsets.indices {
      if offsets[index].x > 0 {
        offsets[index].y -= Double(Int(xOffsetAmount * pythonSkewCompensation))
      } else {
        offsets[index].y += Double(Int(xOffsetAmount * pythonSkewCompensation))
      }
      if offsets[index].y < 0 {
        offsets[index].x -= Double(Int(yOffsetAmount * pythonSkewCompensation))
      } else {
        offsets[index].x += Double(Int(yOffsetAmount * pythonSkewCompensation))
      }
    }

    let adjusted = zip(ordered, offsets).map { point, offset in
      Point(x: point.x + offset.x, y: point.y + offset.y)
    }

    return points.indices.map { index in
      let adjustedIndex = (index + points.count - referenceIndex) % points.count
      let point = adjusted[adjustedIndex]
      return (Int(point.x), Int(point.y))
    }
  }

  /// Matches NumPy's historical `where(box == topLeft)[0][0]` behavior,
  /// including its coordinate-wise match and Float tie-breaking. Keeping this
  /// compatibility in one named helper makes the rest of the geometry use
  /// ordinary points and Double-precision dimensions.
  private static func pythonCompatibleReferenceIndex(in points: [Point]) -> Int {
    let reference = points.min {
      Float($0.x + $0.y) < Float($1.x + $1.y)
    }!
    return points.firstIndex {
      $0.x == reference.x || $0.y == reference.y
    } ?? 0
  }

  private static func rotateLeft(_ points: [Point], by offset: Int) -> [Point] {
    points.indices.map { points[($0 + offset) % points.count] }
  }
}
