enum UInt16Histogram {
  /// The midpoint of the two central ranks, matching the sorted-sample median.
  static func median(_ counts: [Int], sampleCount: Int) -> Double {
    guard sampleCount > 0 else { return 0 }
    let lowerRank = (sampleCount - 1) / 2
    let upperRank = sampleCount / 2
    var cumulativeCount = 0
    var lowerValue: Int?
    for (value, count) in counts.enumerated() {
      cumulativeCount += count
      if lowerValue == nil, cumulativeCount > lowerRank { lowerValue = value }
      if cumulativeCount > upperRank {
        return (Double(lowerValue ?? value) + Double(value)) / 2
      }
    }
    return Double(lowerValue ?? 0)
  }
}
