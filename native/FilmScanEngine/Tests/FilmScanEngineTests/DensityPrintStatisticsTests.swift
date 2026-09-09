import Testing

@testable import FilmScanEngine

@Suite("Density-print percentile reuse")
struct DensityPrintStatisticsTests {
  @Test("Sorted percentiles retain interpolation, clamping, and empty-input behavior")
  func percentileBoundaries() {
    #expect(DensityPrintProcessing.percentileOfSorted([], 50) == 0)
    for percent in [-10.0, 0, 0.01, 1, 30, 50, 98, 99, 99.99, 100, 110] {
      #expect(DensityPrintProcessing.percentileOfSorted([-3], percent) == -3)
    }
    let values = [-6.0, -4, -4, -1, 0]
    #expect(DensityPrintProcessing.percentileOfSorted(values, -1) == -6)
    #expect(DensityPrintProcessing.percentileOfSorted(values, 100) == 0)
    #expect(DensityPrintProcessing.percentileOfSorted(values, 101) == 0)
    #expect(DensityPrintProcessing.percentileOfSorted(values, 25) == -4)
    #expect(DensityPrintProcessing.percentileOfSorted(values, 50) == -4)
    #expect(DensityPrintProcessing.percentileOfSorted(values, 62.5) == -2.5)
  }

  @Test(
    "Shared channel statistics match independent percentile queries",
    arguments: [0, 1, 2, 17, 65_536])
  func independentChannelPercentiles(count: Int) {
    // Different channel ranges and repeated values expose channel/rank swaps.
    let samples = (0..<count).map { index in
      (
        blue: Double((index * 7) % 257) / 13 - 20,
        green: Double((index * 19) % 53) / 7 - 4,
        red: Double((index * 31) % 127) / 11 - 10
      )
    }
    let original = samples
    let statistics = DensityPrintProcessing.LogChannelStatistics(samples)
    func reference(_ percent: Double) -> BGRChannelValues {
      // Preserve the pre-reuse full-sort oracle independently of production
      // helpers so changing their interpolation cannot refresh this reference.
      func percentile(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * percent / 100
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let t = position - Double(lower)
        return sorted[lower] * (1 - t) + sorted[upper] * t
      }
      return BGRChannelValues(
        blue: percentile(samples.map(\.blue)),
        green: percentile(samples.map(\.green)),
        red: percentile(samples.map(\.red)))
    }
    #expect(statistics.lumaBounds.floors == reference(0.01))
    #expect(statistics.lumaBounds.ceils == reference(99.99))
    #expect(statistics.colorBounds.floors == reference(1))
    #expect(statistics.colorBounds.ceils == reference(99))
    #expect(statistics.shadowRefs == reference(98))
    #expect(samples.elementsEqual(original) { $0 == $1 })
  }
}
