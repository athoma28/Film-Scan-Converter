import CLibRawShim
import CoreGraphics
import Foundation
import ImageIO

public struct RawDecodeResult: Sendable {
  public let image: UInt16Image
  public let colorDescription: String
  public let decoderVersion: String
  public let profile: RawDecodeProfile

  public init(
    image: UInt16Image,
    colorDescription: String,
    decoderVersion: String,
    profile: RawDecodeProfile = .rawPyCompatibility
  ) {
    self.image = image
    self.colorDescription = colorDescription
    self.decoderVersion = decoderVersion
    self.profile = profile
  }
}

public enum RawDecodeProfile: UInt32, Sendable, Codable, Equatable {
  case rawPyCompatibility = 0
  case rawTherapeeCameraScan = 1

  var cValue: fsc_raw_decode_profile {
    fsc_raw_decode_profile(rawValue)
  }
}

public enum RawImageDecoder {
  public static func decode(
    _ url: URL,
    fullResolution: Bool = false,
    profile: RawDecodeProfile = .rawPyCompatibility
  ) throws -> RawDecodeResult {
    guard url.isFileURL,
      FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
    else {
      DecodeLog.rawDecodeFailed(path: url.lastPathComponent, error: "unsupportedFileType")
      throw RawImageDecoderError.unsupportedFileType
    }

    DecodeLog.rawDecodeStarted(path: url.lastPathComponent, fullResolution: fullResolution)

    var output = fsc_raw_direct()
    var errorBytes = [CChar](repeating: 0, count: 512)
    let code = url.withUnsafeFileSystemRepresentation { path in
      fsc_decode_raw_direct_with_profile(
        path,
        fullResolution ? 1 : 0,
        profile.cValue,
        &output,
        &errorBytes,
        errorBytes.count
      )
    }
    guard code == 0 else {
      let message = decodedCString(errorBytes)
      DecodeLog.rawDecodeFailed(path: url.lastPathComponent, error: message.isEmpty ? "Unknown LibRaw error." : message)
      throw RawImageDecoderError.decodeFailed(message.isEmpty ? "Unknown LibRaw error." : message)
    }
    defer {
      fsc_free_raw_direct(&output)
    }
    guard let sourcePixels = output.bgr_pixels,
      output.width > 0,
      output.height > 0,
      output.channels == 3,
      output.pixel_count == Int(output.width * output.height * output.channels)
    else {
      throw RawImageDecoderError.invalidOutput
    }

    let pixelCount = Int(output.pixel_count)
    let pixels = [UInt16](unsafeUninitializedCapacity: pixelCount) { buffer, initializedCount in
      let bgr = UnsafeBufferPointer(start: sourcePixels, count: pixelCount)
      for i in stride(from: 0, to: pixelCount, by: 3) {
        buffer[i] = bgr[i + 2]
        buffer[i + 1] = bgr[i + 1]
        buffer[i + 2] = bgr[i]
      }
      initializedCount = pixelCount
    }
    let colorDescription = withUnsafePointer(to: output.color_description) {
      $0.withMemoryRebound(to: CChar.self, capacity: 5) {
        String(cString: $0)
      }
    }
    let version = String(cString: fsc_libraw_version())
    DecodeLog.rawDecodeComplete(
      path: url.lastPathComponent,
      width: Int(output.width),
      height: Int(output.height),
      colorDescription: colorDescription,
      version: version
    )
    return RawDecodeResult(
      image: UInt16Image(
        width: Int(output.width),
        height: Int(output.height),
        channels: Int(output.channels),
        pixels: pixels
      ),
      colorDescription: colorDescription,
      decoderVersion: version,
      profile: profile
    )
  }

  public struct ThumbnailResult: Sendable {
    public let image: UInt16Image
    public let width: Int
    public let height: Int
  }

  public static func extractThumbnail(_ url: URL) throws -> ThumbnailResult {
    guard url.isFileURL,
      FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
    else {
      throw RawImageDecoderError.unsupportedFileType
    }

    var output = fsc_raw_thumbnail()
    var errorBytes = [CChar](repeating: 0, count: 512)
    let code = url.withUnsafeFileSystemRepresentation { path in
      fsc_extract_thumbnail(
        path,
        &output,
        &errorBytes,
        errorBytes.count
      )
    }
    guard code == 0 else {
      let message = RawImageDecoder.decodedCString(errorBytes)
      throw RawImageDecoderError.decodeFailed(message.isEmpty ? "No embedded preview." : message)
    }
    defer {
      fsc_free_thumbnail(&output)
    }
    guard let jpegData = output.data,
      output.data_size > 0,
      output.width > 0,
      output.height > 0
    else {
      throw RawImageDecoderError.invalidOutput
    }

    let data = Data(bytes: jpegData, count: Int(output.data_size))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw RawImageDecoderError.decodeFailed("Could not decode embedded JPEG.")
    }

    let width = cgImage.width
    let height = cgImage.height
    var components = [UInt16](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &components,
      width: width,
      height: height,
      bitsPerComponent: 16,
      bytesPerRow: width * 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    ) else {
      throw RawImageDecoderError.decodeFailed("Cannot create decode context.")
    }
    context.interpolationQuality = .none
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let pixelCount = width * height
    var pixels = [UInt16](repeating: 0, count: pixelCount * 3)
    for i in 0..<pixelCount {
      let src = i * 4
      let dst = i * 3
      pixels[dst] = components[src + 2]
      pixels[dst + 1] = components[src + 1]
      pixels[dst + 2] = components[src]
    }
    return ThumbnailResult(
      image: UInt16Image(width: width, height: height, channels: 3, pixels: pixels),
      width: width,
      height: height
    )
  }

  private static func decodedCString(_ bytes: [CChar]) -> String {
    let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: utf8, as: UTF8.self)
  }
}

public enum RawImageDecoderError: LocalizedError {
  case unsupportedFileType
  case decodeFailed(String)
  case invalidOutput

  public var errorDescription: String? {
    switch self {
    case .unsupportedFileType:
      "The file is not a supported RAW format."
    case .decodeFailed(let message):
      "LibRaw could not decode the image: \(message)"
    case .invalidOutput:
      "LibRaw returned an invalid 16-bit RGB image."
    }
  }
}
