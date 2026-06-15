import Foundation

public enum CaptureInputKind: String, Codable, Equatable, Sendable {
  case raw
  case tiff
  case jpeg
  case png
  case other
}

public enum CaptureWarning: String, Codable, Equatable, Sendable, CaseIterable {
  case eightBitSource
  case lossySource
  case lowClipped
  case highClipped
  case missingFlatField
  case markedNonlinear
}

public struct PerChannelDiagnostics: Codable, Equatable, Sendable {
  public let minimum: UInt16
  public let maximum: UInt16
  public let lowClippedFraction: Double
  public let highClippedFraction: Double

  public init(
    minimum: UInt16,
    maximum: UInt16,
    lowClippedFraction: Double,
    highClippedFraction: Double
  ) {
    self.minimum = minimum
    self.maximum = maximum
    self.lowClippedFraction = lowClippedFraction
    self.highClippedFraction = highClippedFraction
  }
}

public struct CaptureDiagnosticReport: Codable, Equatable, Sendable {
  public let sourceKind: CaptureInputKind
  public let bitDepth: Int
  public let width: Int
  public let height: Int
  public let channels: Int
  public let perChannel: [PerChannelDiagnostics]
  public let warnings: Set<CaptureWarning>

  public init(
    sourceKind: CaptureInputKind,
    bitDepth: Int,
    width: Int,
    height: Int,
    channels: Int,
    perChannel: [PerChannelDiagnostics],
    warnings: Set<CaptureWarning>
  ) {
    self.sourceKind = sourceKind
    self.bitDepth = bitDepth
    self.width = width
    self.height = height
    self.channels = channels
    self.perChannel = perChannel
    self.warnings = warnings
  }
}

public enum CaptureDiagnostics {
  private static let lowClipThreshold: UInt16 = 1
  private static let highClipThreshold: UInt16 = 65_534
  private static let clipWarningFraction = 0.001

  public static func generate(
    image: UInt16Image,
    sourceKind: CaptureInputKind,
    bitDepth: Int,
    missingFlatField: Bool = false,
    markedNonlinear: Bool = false
  ) -> CaptureDiagnosticReport {
    precondition(image.width > 0 && image.height > 0)
    precondition(bitDepth > 0 && bitDepth <= 16, "Bit depth must be in the range 1–16")

    var warnings = Set<CaptureWarning>()
    var perChannel = [PerChannelDiagnostics]()
    perChannel.reserveCapacity(image.channels)

    let channelCount = image.channels
    let pixelsPerChannel = image.width * image.height
    let pixelCount = image.pixels.count

    for channel in 0..<channelCount {
      var minVal: UInt16 = .max
      var maxVal: UInt16 = .min
      var lowClipped: Int = 0
      var highClipped: Int = 0

      for index in stride(from: channel, to: pixelCount, by: channelCount) {
        let value = image.pixels[index]
        if value < minVal { minVal = value }
        if value > maxVal { maxVal = value }
        if value <= lowClipThreshold { lowClipped += 1 }
        if value >= highClipThreshold { highClipped += 1 }
      }

      let lowFraction = Double(lowClipped) / Double(pixelsPerChannel)
      let highFraction = Double(highClipped) / Double(pixelsPerChannel)

      perChannel.append(
        PerChannelDiagnostics(
          minimum: minVal,
          maximum: maxVal,
          lowClippedFraction: lowFraction,
          highClippedFraction: highFraction
        ))

      if lowFraction >= clipWarningFraction {
        warnings.insert(.lowClipped)
      }
      if highFraction >= clipWarningFraction {
        warnings.insert(.highClipped)
      }
    }

    if bitDepth <= 8 {
      warnings.insert(.eightBitSource)
    }

    if sourceKind == .jpeg {
      warnings.insert(.lossySource)
    }

    if missingFlatField {
      warnings.insert(.missingFlatField)
    }

    if markedNonlinear {
      warnings.insert(.markedNonlinear)
    }

    return CaptureDiagnosticReport(
      sourceKind: sourceKind,
      bitDepth: bitDepth,
      width: image.width,
      height: image.height,
      channels: image.channels,
      perChannel: perChannel,
      warnings: warnings
    )
  }
}
