import CoreGraphics
import Foundation
import ImageIO

public struct ExportWriteMetrics: Codable, Equatable, Sendable {
  public let pixelPackingSeconds: Double
  public let encodingFinalizationSeconds: Double
  public let packedPixelBytes: Int
  public let outputBytes: Int

  public init(
    pixelPackingSeconds: Double,
    encodingFinalizationSeconds: Double,
    packedPixelBytes: Int,
    outputBytes: Int
  ) {
    self.pixelPackingSeconds = pixelPackingSeconds
    self.encodingFinalizationSeconds = encodingFinalizationSeconds
    self.packedPixelBytes = packedPixelBytes
    self.outputBytes = outputBytes
  }
}

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
    _ = try writeMeasured(to: url, format: format, parameters: parameters)
  }

  /// Writes through the production export path and returns coarse stage timings.
  /// The benchmark uses this API so it measures the same packing and writer work
  /// as an app export rather than a synthetic approximation.
  public func writeMeasured(
    to url: URL,
    format: ExportFormat,
    parameters: ExportParameters
  ) throws -> ExportWriteMetrics {
    let directory = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    switch format {
    case .tiff:
      return try writeTIFF(to: url, parameters: parameters)
    case .jpeg:
      return try writeJPEG(to: url, parameters: parameters)
    case .png:
      return try writePNG(to: url)
    case .dng:
      return try writeDNGMeasured(to: url)
    }
  }

  private func writeJPEG(
    to url: URL, parameters: ExportParameters
  ) throws -> ExportWriteMetrics {
    let packingStart = ContinuousClock.now
    guard let cgImage = makeExportCGImage8() else {
      throw ExportError.creationFailed
    }
    let packingSeconds = exportSeconds(packingStart.duration(to: .now))

    let writerStart = ContinuousClock.now
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
    return try exportMetrics(
      url: url,
      packingSeconds: packingSeconds,
      writerSeconds: exportSeconds(writerStart.duration(to: .now)),
      packedPixelBytes: width * height * 3
    )
  }

  private func writeTIFF(
    to url: URL, parameters: ExportParameters
  ) throws -> ExportWriteMetrics {
    let packingStart = ContinuousClock.now
    guard let cgImage = makeExportCGImageRGB16() else {
      throw ExportError.creationFailed
    }
    let packingSeconds = exportSeconds(packingStart.duration(to: .now))

    let writerStart = ContinuousClock.now
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.tiff" as CFString, 1, nil
    ) else {
      throw ExportError.creationFailed
    }

    let options: [CFString: Any] = [
      kCGImagePropertyTIFFCompression: tiffCompressionValue(parameters.tiffCompression),
      kCGImagePropertyOrientation: 1,
    ]

    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ExportError.writeFailed(CocoaError(.fileWriteUnknown))
    }
    return try exportMetrics(
      url: url,
      packingSeconds: packingSeconds,
      writerSeconds: exportSeconds(writerStart.duration(to: .now)),
      packedPixelBytes: width * height * 6
    )
  }

  private func writePNG(to url: URL) throws -> ExportWriteMetrics {
    guard channels >= 3 else {
      throw ExportError.unsupportedChannels
    }
    let packingStart = ContinuousClock.now
    guard let cgImage = makeExportCGImage16() else {
      throw ExportError.creationFailed
    }
    let packingSeconds = exportSeconds(packingStart.duration(to: .now))

    let writerStart = ContinuousClock.now
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
    return try exportMetrics(
      url: url,
      packingSeconds: packingSeconds,
      writerSeconds: exportSeconds(writerStart.duration(to: .now)),
      packedPixelBytes: width * height * 6
    )
  }

  private func exportMetrics(
    url: URL,
    packingSeconds: Double,
    writerSeconds: Double,
    packedPixelBytes: Int
  ) throws -> ExportWriteMetrics {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return ExportWriteMetrics(
      pixelPackingSeconds: packingSeconds,
      encodingFinalizationSeconds: writerSeconds,
      packedPixelBytes: packedPixelBytes,
      outputBytes: values.fileSize ?? 0
    )
  }

  public func makeExportCGImage16() -> CGImage? {
    guard let data = rgb16Data() else {
      return nil
    }

    guard let provider = CGDataProvider(data: data as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 16,
      bitsPerPixel: 48,
      bytesPerRow: width * 6,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: .byteOrder16Little,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  package func makeExportCGImageRGB16() -> CGImage? {
    guard let data = rgb16Data() else {
      return nil
    }

    guard let provider = CGDataProvider(data: data as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 16,
      bitsPerPixel: 48,
      bytesPerRow: width * 6,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: .byteOrder16Little,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  public func makeExportCGImage8() -> CGImage? {
    guard let data = rgb8Data() else {
      return nil
    }

    guard let provider = CGDataProvider(data: data as CFData) else {
      return nil
    }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 24,
      bytesPerRow: width * 3,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
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
}

private func exportSeconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
