import CoreGraphics
import Foundation
import ImageIO

public enum StandardImageDecoder {
  public static let supportedExtensions: Set<String> = [
    "png", "jpg", "jpeg", "bmp", "tiff", "tif",
  ]

  public static func decode(_ url: URL) throws -> UInt16Image {
    guard url.isFileURL,
      supportedExtensions.contains(url.pathExtension.lowercased())
    else {
      DecodeLog.standardImageFailed(
        path: url.lastPathComponent,
        error: "unsupportedFileType"
      )
      throw StandardImageDecoderError.unsupportedFileType
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source,
        0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      )
    else {
      DecodeLog.standardImageFailed(
        path: url.lastPathComponent,
        error: "unreadableImage"
      )
      throw StandardImageDecoderError.unreadableImage
    }
    guard image.width > 0, image.height > 0 else {
      DecodeLog.standardImageFailed(
        path: url.lastPathComponent,
        error: "emptyImage"
      )
      throw StandardImageDecoderError.emptyImage
    }

    let colorModelName: String
    if let model = image.colorSpace?.model {
      switch model {
      case .monochrome:
        colorModelName = "monochrome"
      case .rgb:
        colorModelName = "rgb"
      default:
        colorModelName = "\(model.rawValue)"
      }
    } else {
      colorModelName = "nil"
    }

    DecodeLog.standardImageStarted(
      path: url.lastPathComponent,
      ext: url.pathExtension,
      width: image.width,
      height: image.height,
      colorModel: colorModelName,
      bitsPerComponent: image.bitsPerComponent
    )

    switch image.colorSpace?.model {
    case .monochrome:
      return try decodeMonochrome(image)
    case .rgb:
      return try decodeRGB(image)
    default:
      DecodeLog.standardImageFailed(
        path: url.lastPathComponent,
        error: "unsupportedColorModel"
      )
      throw StandardImageDecoderError.unsupportedColorModel
    }
  }

  private static func decodeMonochrome(_ image: CGImage) throws -> UInt16Image {
    var components = [UInt16](repeating: 0, count: image.width * image.height)
    try draw(image, components: &components, colorSpace: CGColorSpaceCreateDeviceGray())
    return UInt16Image(
      width: image.width,
      height: image.height,
      channels: 1,
      pixels: pythonScaled(components, sourceBitsPerComponent: image.bitsPerComponent)
    )
  }

  private static func decodeRGB(_ image: CGImage) throws -> UInt16Image {
    guard
      image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst
        || image.alphaInfo == .noneSkipLast
    else {
      throw StandardImageDecoderError.alphaChannelNotSupported
    }

    var components = [UInt16](repeating: 0, count: image.width * image.height * 4)
    try draw(
      image,
      components: &components,
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(
        rawValue:
          CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
      )
    )

    let scaled = pythonScaled(components, sourceBitsPerComponent: image.bitsPerComponent)
    let pixelCount = image.width * image.height
    var pixels = [UInt16](repeating: 0, count: pixelCount * 3)
    for i in 0..<pixelCount {
      let src = i * 4
      let dst = i * 3
      pixels[dst] = scaled[src + 2]
      pixels[dst + 1] = scaled[src + 1]
      pixels[dst + 2] = scaled[src]
    }
    return UInt16Image(width: image.width, height: image.height, channels: 3, pixels: pixels)
  }

  private static func draw(
    _ image: CGImage,
    components: inout [UInt16],
    colorSpace: CGColorSpace,
    bitmapInfo: CGBitmapInfo = CGBitmapInfo(
      rawValue:
        CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    )
  ) throws {
    let componentCount = components.count / (image.width * image.height)
    let bytesPerRow = image.width * componentCount * MemoryLayout<UInt16>.size
    let created = components.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 16,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo.rawValue
        )
      else {
        return false
      }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard created else {
      throw StandardImageDecoderError.cannotCreateBitmapContext
    }
  }

  private static func pythonScaled(
    _ components: [UInt16],
    sourceBitsPerComponent: Int
  ) -> [UInt16] {
    guard sourceBitsPerComponent <= 8 else {
      return components
    }
    return components.map { UInt16($0 >> 8) * 256 }
  }
}

public enum StandardImageDecoderError: LocalizedError {
  case unsupportedFileType
  case unreadableImage
  case emptyImage
  case unsupportedColorModel
  case alphaChannelNotSupported
  case cannotCreateBitmapContext

  public var errorDescription: String? {
    switch self {
    case .unsupportedFileType:
      "The file is not a supported standard image format."
    case .unreadableImage:
      "ImageIO could not decode the image."
    case .emptyImage:
      "The decoded image has no pixels."
    case .unsupportedColorModel:
      "The image color model is not supported."
    case .alphaChannelNotSupported:
      "Images with alpha channels are not supported by the processing pipeline."
    case .cannotCreateBitmapContext:
      "Core Graphics could not create a 16-bit decoding buffer."
    }
  }
}
