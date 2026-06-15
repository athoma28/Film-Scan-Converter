import CoreGraphics
import Foundation
import ImageIO

extension UInt16Image {
  public enum ExportError: Error {
    case unsupportedChannels
    case creationFailed
    case writeFailed(Error)
    case invalidDestination
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
    guard channels >= 3,
      let cgImage = makeExportCGImage16()
    else {
      throw ExportError.creationFailed
    }

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil
    ) else {
      throw ExportError.creationFailed
    }

    CGImageDestinationAddImage(destination, cgImage, nil)

    guard CGImageDestinationFinalize(destination) else {
      throw ExportError.writeFailed(CocoaError(.fileWriteUnknown))
    }
  }

  public func makeExportCGImage16() -> CGImage? {
    guard channels == 1 || channels == 3 else {
      return nil
    }

    var components = [UInt16]()
    components.reserveCapacity(width * height * 4)
    for pixelIndex in 0..<(width * height) {
      if channels == 1 {
        let value = pixels[pixelIndex]
        components.append(contentsOf: [value, value, value, .max])
      } else {
        let componentIndex = pixelIndex * 3
        components.append(pixels[componentIndex + 2])
        components.append(pixels[componentIndex + 1])
        components.append(pixels[componentIndex])
        components.append(.max)
      }
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
    guard channels == 1 || channels == 3 else {
      return nil
    }

    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for pixelIndex in 0..<(width * height) {
      if channels == 1 {
        let value = UInt8(truncatingIfNeeded: pixels[pixelIndex] >> 8)
        bytes.append(contentsOf: [value, value, value, 255])
      } else {
        let componentIndex = pixelIndex * 3
        bytes.append(UInt8(truncatingIfNeeded: pixels[componentIndex + 2] >> 8))
        bytes.append(UInt8(truncatingIfNeeded: pixels[componentIndex + 1] >> 8))
        bytes.append(UInt8(truncatingIfNeeded: pixels[componentIndex] >> 8))
        bytes.append(255)
      }
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
