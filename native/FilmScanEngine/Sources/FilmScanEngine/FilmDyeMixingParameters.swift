import Foundation

/// Neutral-preserving cross-channel correction for imperfect film-dye separation.
///
/// Each coefficient describes how much of a source record is mixed into a
/// destination record. Positive values blend the destination toward the source;
/// negative values subtract crossover. Expressing every term as a channel
/// difference makes every row of the equivalent 3x3 matrix sum to one, so a
/// neutral input remains neutral without relying on a compensating white balance.
public struct FilmDyeMixingParameters: Codable, Equatable, Hashable, Sendable {
  public static let coefficientRange = -0.5...0.5

  public var redFromGreen: Double
  public var redFromBlue: Double
  public var greenFromRed: Double
  public var greenFromBlue: Double
  public var blueFromRed: Double
  public var blueFromGreen: Double

  public init(
    redFromGreen: Double = 0,
    redFromBlue: Double = 0,
    greenFromRed: Double = 0,
    greenFromBlue: Double = 0,
    blueFromRed: Double = 0,
    blueFromGreen: Double = 0
  ) {
    self.redFromGreen = redFromGreen
    self.redFromBlue = redFromBlue
    self.greenFromRed = greenFromRed
    self.greenFromBlue = greenFromBlue
    self.blueFromRed = blueFromRed
    self.blueFromGreen = blueFromGreen
  }

  public static let neutral = FilmDyeMixingParameters()

  public var isNeutral: Bool {
    redFromGreen == 0 && redFromBlue == 0
      && greenFromRed == 0 && greenFromBlue == 0
      && blueFromRed == 0 && blueFromGreen == 0
  }

  public func clamped() -> FilmDyeMixingParameters {
    FilmDyeMixingParameters(
      redFromGreen: Self.clamp(redFromGreen),
      redFromBlue: Self.clamp(redFromBlue),
      greenFromRed: Self.clamp(greenFromRed),
      greenFromBlue: Self.clamp(greenFromBlue),
      blueFromRed: Self.clamp(blueFromRed),
      blueFromGreen: Self.clamp(blueFromGreen)
    )
  }

  private static func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, coefficientRange.lowerBound), coefficientRange.upperBound)
  }
}
