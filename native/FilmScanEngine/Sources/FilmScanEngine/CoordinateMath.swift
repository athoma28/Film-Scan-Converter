import Foundation

enum CoordinateMath {
  static func shrinkBox(
    box: [(x: Double, y: Double)],
    xPercent: Double,
    yPercent: Double
  ) -> [(x: Int, y: Int)] {
    precondition(box.count == 4, "shrinkBox requires exactly 4 corner points")

    let sortedX = box.map { _sortKey($0.x) }.sorted()
    let sortedY = box.map { _sortKey($0.y) }.sorted()

    let topleft = box.min { _sortKey($0.x + $0.y) < _sortKey($1.x + $1.y) }!

    var index = 0
    for (i, point) in box.enumerated() {
      if _sortKey(point.x) == _sortKey(topleft.x) || _sortKey(point.y) == _sortKey(topleft.y) {
        index = i
        break
      }
    }

    var ordered = [Double]()
    for i in 0..<4 {
      let p = box[(index + i) % 4]
      ordered.append(p.x)
      ordered.append(p.y)
    }

    let h = (sortedY[2] + sortedY[3] - sortedY[0] - sortedY[1]) / 2
    let w = (sortedX[2] + sortedX[3] - sortedX[0] - sortedX[1]) / 2
    let skew = (ordered[6] - ordered[0]) / w * 1.5
    let centreX = (ordered[0] + ordered[2] + ordered[4] + ordered[6]) / 4
    let centreY = (ordered[1] + ordered[3] + ordered[5] + ordered[7]) / 4
    let yOffsetAmount = yPercent / 100 * h
    let xOffsetAmount = xPercent / 100 * w

    var offset = [Double](repeating: 0, count: 8)
    for i in 0..<4 {
      if ordered[i * 2 + 1] < centreY {
        offset[i * 2 + 1] += Double(Int(yOffsetAmount))
      } else if ordered[i * 2 + 1] > centreY {
        offset[i * 2 + 1] -= Double(Int(yOffsetAmount))
      }
      if ordered[i * 2] < centreX {
        offset[i * 2] += Double(Int(xOffsetAmount))
      } else if ordered[i * 2] > centreX {
        offset[i * 2] -= Double(Int(xOffsetAmount))
      }
    }

    let intXOff = xOffsetAmount
    let intYOff = yOffsetAmount
    for i in 0..<4 {
      let px = i * 2
      let py = i * 2 + 1
      if offset[px] > 0 {
        offset[py] -= Double(Int(intXOff * skew))
      } else {
        offset[py] += Double(Int(intXOff * skew))
      }
      if offset[py] < 0 {
        offset[px] -= Double(Int(intYOff * skew))
      } else {
        offset[px] += Double(Int(intYOff * skew))
      }
    }

    var newBox = [(Double, Double)]()
    for i in 0..<4 {
      newBox.append((ordered[i * 2] + offset[i * 2], ordered[i * 2 + 1] + offset[i * 2 + 1]))
    }

    var rolled = [(Int, Int)]()
    for i in 0..<4 {
      let srcIndex = (i + 4 - index) % 4
      rolled.append((Int(newBox[srcIndex].0), Int(newBox[srcIndex].1)))
    }

    return rolled
  }

  private static func _sortKey(_ value: Double) -> Double {
    Double(Float(value))
  }
}
