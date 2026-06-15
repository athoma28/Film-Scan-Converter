import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
  case tiff
  case jpeg
  case png
  case dng

  public var displayName: String {
    switch self {
    case .tiff: "TIFF"
    case .jpeg: "JPEG"
    case .png: "PNG"
    case .dng: "DNG"
    }
  }

  public var fileExtension: String {
    rawValue
  }

  public var utType: String {
    switch self {
    case .tiff: "public.tiff"
    case .jpeg: "public.jpeg"
    case .png: "public.png"
    case .dng: "com.adobe.raw-image"
    }
  }
}

public struct ExportParameters: Codable, Sendable {
  public var format: ExportFormat
  public var framePercent: Int
  public var aspectRatio: AspectRatio?
  public var destinationDirectory: URL?
  public var jpegQuality: Double
  public var tiffCompression: TiffCompression

  public init(
    format: ExportFormat = .tiff,
    framePercent: Int = 0,
    aspectRatio: AspectRatio? = nil,
    destinationDirectory: URL? = nil,
    jpegQuality: Double = 0.95,
    tiffCompression: TiffCompression = .none
  ) {
    self.format = format
    self.framePercent = framePercent
    self.aspectRatio = aspectRatio
    self.destinationDirectory = destinationDirectory
    self.jpegQuality = jpegQuality
    self.tiffCompression = tiffCompression
  }
}

public enum TiffCompression: String, Codable, CaseIterable, Sendable {
  case none
  case lzw

  public var displayName: String {
    switch self {
    case .none: "None"
    case .lzw: "LZW"
    }
  }
}
