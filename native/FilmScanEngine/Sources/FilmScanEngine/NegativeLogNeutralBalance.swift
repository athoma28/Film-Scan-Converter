import Foundation

/// A neutral-axis prior in log10 scan transmittance, after dye unmixing.
/// Green remains the per-frame exposure anchor. Channel strengths blend the
/// roll prior with the existing content-derived endpoints; they are not WB gains.
public struct NegativeLogNeutralBalance: Codable, Equatable, Sendable {
  public var referenceRGB: [Double]
  public var scaleRGB: [Double]
  public var strengthRGB: [Double]

  public init(referenceRGB: [Double], scaleRGB: [Double], strengthRGB: [Double]) {
    self.referenceRGB = referenceRGB
    self.scaleRGB = scaleRGB
    self.strengthRGB = strengthRGB
  }

  func applying(to bounds: (floors: BGRChannelValues, ceils: BGRChannelValues))
    -> (floors: BGRChannelValues, ceils: BGRChannelValues)
  {
    guard referenceRGB.count == 3, scaleRGB.count == 3, strengthRGB.count == 3,
      referenceRGB.allSatisfy({ $0.isFinite }),
      scaleRGB.allSatisfy({ $0.isFinite && $0 > 0 }),
      strengthRGB.allSatisfy({ $0.isFinite })
    else { return bounds }
    func balanced(_ value: BGRChannelValues) -> BGRChannelValues {
      func channel(_ existing: Double, _ index: Int) -> Double {
        let target = (value.green - referenceRGB[1]) / scaleRGB[index] + referenceRGB[index]
        let strength = min(max(strengthRGB[index], 0), 1)
        return existing + strength * (target - existing)
      }
      return BGRChannelValues(
        blue: channel(value.blue, 2), green: value.green, red: channel(value.red, 0))
    }
    return (balanced(bounds.floors), balanced(bounds.ceils))
  }
}
