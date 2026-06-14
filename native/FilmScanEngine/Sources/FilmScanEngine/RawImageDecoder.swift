import CLibRawShim
import Foundation

public struct RawDecodeResult: Sendable {
  public let image: UInt16Image
  public let colorDescription: String
  public let decoderVersion: String

  public init(image: UInt16Image, colorDescription: String, decoderVersion: String) {
    self.image = image
    self.colorDescription = colorDescription
    self.decoderVersion = decoderVersion
  }
}

public enum RawImageDecoder {
  public static func decode(_ url: URL, fullResolution: Bool = false) throws -> RawDecodeResult {
    guard url.isFileURL,
      FileDropPolicy.rawExtensions.contains(url.pathExtension.lowercased())
    else {
      throw RawImageDecoderError.unsupportedFileType
    }

    var output = fsc_raw_image()
    var errorBytes = [CChar](repeating: 0, count: 512)
    let code = url.withUnsafeFileSystemRepresentation { path in
      fsc_decode_raw(
        path,
        fullResolution ? 1 : 0,
        &output,
        &errorBytes,
        errorBytes.count
      )
    }
    guard code == 0 else {
      let message = decodedCString(errorBytes)
      throw RawImageDecoderError.decodeFailed(message.isEmpty ? "Unknown LibRaw error." : message)
    }
    defer {
      fsc_free_raw_image(&output)
    }
    guard let sourcePixels = output.pixels,
      output.width > 0,
      output.height > 0,
      output.channels == 3,
      output.pixel_count == Int(output.width * output.height * output.channels)
    else {
      throw RawImageDecoderError.invalidOutput
    }

    let pixels = Array(UnsafeBufferPointer(start: sourcePixels, count: output.pixel_count))
    let colorDescription = withUnsafePointer(to: output.color_description) {
      $0.withMemoryRebound(to: CChar.self, capacity: 5) {
        String(cString: $0)
      }
    }
    return RawDecodeResult(
      image: UInt16Image(
        width: Int(output.width),
        height: Int(output.height),
        channels: Int(output.channels),
        pixels: pixels
      ),
      colorDescription: colorDescription,
      decoderVersion: String(cString: fsc_libraw_version())
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
