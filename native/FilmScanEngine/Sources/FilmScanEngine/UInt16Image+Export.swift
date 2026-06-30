import CoreGraphics
import Foundation
import ImageIO

extension UInt16Image {
  public enum ExportError: Error, LocalizedError {
    case unsupportedChannels
    case creationFailed
    case writeFailed(Error)
    case invalidDestination
    case destinationCreationFailed(URL, ExportFormat)
    case finalizationFailed(URL, ExportFormat)
    case commitFailed(URL, ExportFormat, Error)

    public var errorDescription: String? {
      switch self {
      case .unsupportedChannels:
        "The image channel layout is not supported for export."
      case .creationFailed:
        "The export image could not be created from the processed pixels."
      case .writeFailed(let error):
        "The exported image could not be written: \(error.localizedDescription)"
      case .invalidDestination:
        "The export destination is invalid."
      case .destinationCreationFailed(let url, let format):
        "Could not create the \(format.displayName) destination for \(url.lastPathComponent) at \(url.path)."
      case .finalizationFailed(let url, let format):
        "ImageIO could not finalize \(url.lastPathComponent) as \(format.displayName) at \(url.path)."
      case .commitFailed(let url, let format, let error):
        "Could not save \(url.lastPathComponent) as \(format.displayName) at \(url.path): \(error.localizedDescription)"
      }
    }
  }

  public func write(
    to url: URL,
    format: ExportFormat,
    parameters: ExportParameters
  ) throws {
    let directory = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    switch format {
    case .tiff:
      try writeTIFF(to: url, parameters: parameters)
    case .jpeg:
      try writeJPEG(to: url, parameters: parameters)
    case .png:
      try writePNG(to: url)
    case .dng:
      try writeDNG(to: url)
    }
  }

  private func writeJPEG(to url: URL, parameters: ExportParameters) throws {
    guard let cgImage = makeExportCGImage8() else {
      throw ExportError.creationFailed
    }

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.jpeg" as CFString, 1, nil
    ) else {
      throw ExportError.creationFailed
    }

    let options: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: parameters.jpegQuality
    ]
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ExportError.writeFailed(CocoaError(.fileWriteUnknown))
    }
  }

  private func writeTIFF(to url: URL, parameters: ExportParameters) throws {
    guard let cgImage = makeExportCGImage16() else {
      throw ExportError.creationFailed
    }

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.tiff" as CFString, 1, nil
    ) else {
      throw ExportError.creationFailed
    }

    var options: [CFString: Any] = [
      kCGImagePropertyTIFFCompression: tiffCompressionValue(parameters.tiffCompression)
    ]
    if let orientation = tiffOrientationValue(parameters: parameters) {
      options[kCGImagePropertyOrientation] = orientation
    }

    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ExportError.writeFailed(CocoaError(.fileWriteUnknown))
    }
  }

  private func writePNG(to url: URL) throws {
    guard channels >= 3 else {
      throw ExportError.unsupportedChannels
    }
    guard let cgImage = makeExportCGImage16() else {
      throw ExportError.creationFailed
    }

    let stagingURL = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
    )
    defer { try? FileManager.default.removeItem(at: stagingURL) }

    guard let destination = CGImageDestinationCreateWithURL(
      stagingURL as CFURL, "public.png" as CFString, 1, nil
    ) else {
      throw ExportError.destinationCreationFailed(url, .png)
    }

    CGImageDestinationAddImage(destination, cgImage, nil)

    guard CGImageDestinationFinalize(destination) else {
      throw ExportError.finalizationFailed(url, .png)
    }

    do {
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: stagingURL)
      } else {
        try FileManager.default.moveItem(at: stagingURL, to: url)
      }
    } catch {
      throw ExportError.commitFailed(url, .png, error)
    }
  }

  public func makeExportCGImage16() -> CGImage? {
    guard let components = rgba16Components() else {
      return nil
    }

    let data = components.withUnsafeBytes { Data($0) }
    guard let provider = CGDataProvider(data: data as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 16,
      bitsPerPixel: 64,
      bytesPerRow: width * 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: .byteOrder16Little.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  public func makeExportCGImage8() -> CGImage? {
    guard let bytes = rgba8Components() else {
      return nil
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  private func tiffCompressionValue(_ compression: TiffCompression) -> Int {
    switch compression {
    case .none: return 1
    case .lzw: return 5
    }
  }

  private func tiffOrientationValue(parameters: ExportParameters) -> Int? {
    1
  }
}
