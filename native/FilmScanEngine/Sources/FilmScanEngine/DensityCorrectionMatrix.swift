import Foundation

/// An affine BGR transform applied after film-base subtraction and before
/// per-channel density-curve inversion.
public struct DensityCorrectionMatrix: Codable, Equatable, Sendable {
  public var blueOutput: BGRChannelValues
  public var greenOutput: BGRChannelValues
  public var redOutput: BGRChannelValues
  public var offset: BGRChannelValues

  public init(
    blueOutput: BGRChannelValues = BGRChannelValues(blue: 1, green: 0, red: 0),
    greenOutput: BGRChannelValues = BGRChannelValues(blue: 0, green: 1, red: 0),
    redOutput: BGRChannelValues = BGRChannelValues(blue: 0, green: 0, red: 1),
    offset: BGRChannelValues = BGRChannelValues(blue: 0, green: 0, red: 0)
  ) {
    self.blueOutput = blueOutput
    self.greenOutput = greenOutput
    self.redOutput = redOutput
    self.offset = offset
  }

  public static let identity = DensityCorrectionMatrix()

  public var isFinite: Bool {
    Self.isFinite(blueOutput)
      && Self.isFinite(greenOutput)
      && Self.isFinite(redOutput)
      && Self.isFinite(offset)
  }

  public func applying(to input: BGRChannelValues) -> BGRChannelValues {
    BGRChannelValues(
      blue: dot(blueOutput, input) + offset.blue,
      green: dot(greenOutput, input) + offset.green,
      red: dot(redOutput, input) + offset.red
    )
  }

  private func dot(_ row: BGRChannelValues, _ input: BGRChannelValues) -> Double {
    row.blue * input.blue + row.green * input.green + row.red * input.red
  }

  private static func isFinite(_ value: BGRChannelValues) -> Bool {
    value.blue.isFinite && value.green.isFinite && value.red.isFinite
  }
}
