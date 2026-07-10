import CLibRawShim
import CoreGraphics
import Foundation
import ImageIO

public struct RawDecodeResult: Sendable {
  public let image: UInt16Image
  public let colorDescription: String
  public let decoderVersion: String
  public let profile: RawDecodeProfile
  public let isoSpeed: Double
  public let processing: RawProcessingStages
  public let timings: RawDecodeTimings

  public init(
    image: UInt16Image,
    colorDescription: String,
    decoderVersion: String,
    profile: RawDecodeProfile = .rawPyCompatibility,
    isoSpeed: Double = 0,
    processing: RawProcessingStages = [],
    timings: RawDecodeTimings = .zero
  ) {
    self.image = image
    self.colorDescription = colorDescription
    self.decoderVersion = decoderVersion
    self.profile = profile
    self.isoSpeed = isoSpeed
    self.processing = processing
    self.timings = timings
  }
}

public struct RawDecodeTimings: Codable, Equatable, Sendable {
  public let openSeconds: Double
  public let unpackSeconds: Double
  public let demosaicSeconds: Double
  public let libRawPostprocessSeconds: Double
  public let processedImageSeconds: Double
  public let isoPolicySeconds: Double
  public let swiftCopySwizzleSeconds: Double

  public init(
    openSeconds: Double,
    unpackSeconds: Double,
    demosaicSeconds: Double,
    libRawPostprocessSeconds: Double,
    processedImageSeconds: Double,
    isoPolicySeconds: Double,
    swiftCopySwizzleSeconds: Double
  ) {
    self.openSeconds = openSeconds
    self.unpackSeconds = unpackSeconds
    self.demosaicSeconds = demosaicSeconds
    self.libRawPostprocessSeconds = libRawPostprocessSeconds
    self.processedImageSeconds = processedImageSeconds
    self.isoPolicySeconds = isoPolicySeconds
    self.swiftCopySwizzleSeconds = swiftCopySwizzleSeconds
  }

  public static let zero = RawDecodeTimings(
    openSeconds: 0,
    unpackSeconds: 0,
    demosaicSeconds: 0,
    libRawPostprocessSeconds: 0,
    processedImageSeconds: 0,
    isoPolicySeconds: 0,
    swiftCopySwizzleSeconds: 0
  )

  public var nativeDecodeSeconds: Double {
    openSeconds + unpackSeconds + demosaicSeconds + libRawPostprocessSeconds
      + processedImageSeconds + isoPolicySeconds
  }

  public var totalSeconds: Double {
    nativeDecodeSeconds + swiftCopySwizzleSeconds
  }
}

public struct NativeHeapStatistics: Codable, Equatable, Sendable {
  public let blocksInUse: UInt64
  public let sizeInUse: UInt64
  public let maxSizeInUse: UInt64
  public let sizeAllocated: UInt64

  public init(
    blocksInUse: UInt64,
    sizeInUse: UInt64,
    maxSizeInUse: UInt64,
    sizeAllocated: UInt64
  ) {
    self.blocksInUse = blocksInUse
    self.sizeInUse = sizeInUse
    self.maxSizeInUse = maxSizeInUse
    self.sizeAllocated = sizeAllocated
  }
}

public struct RawProcessingStages: OptionSet, Sendable, Equatable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let rcdDemosaic = Self(rawValue: UInt32(FSC_RAW_PROCESSING_RCD))
  public static let rec2020WorkingSpace = Self(rawValue: UInt32(FSC_RAW_PROCESSING_REC2020))
  public static let isoDenoise = Self(rawValue: UInt32(FSC_RAW_PROCESSING_ISO_DENOISE))
  public static let isoSharpen = Self(rawValue: UInt32(FSC_RAW_PROCESSING_ISO_SHARPEN))
  public static let xTransThreePass = Self(
    rawValue: UInt32(FSC_RAW_PROCESSING_XTRANS_THREE_PASS))
}

public enum RawDecodeProfile: UInt32, Sendable, Codable, Equatable {
  case rawPyCompatibility = 0
  case rawTherapeeCameraScan = 1

  var cValue: fsc_raw_decode_profile {
    fsc_raw_decode_profile(rawValue)
  }
}

public enum RawImageDecoder {
  /// Reports default-allocator state for sequential export diagnostics. The
  /// values distinguish still-live heap allocations from reserved allocator
  /// pages; they are not a replacement for an Instruments allocation trace.
  public static func defaultHeapStatistics() -> NativeHeapStatistics? {
    var statistics = fsc_heap_statistics()
    guard fsc_default_heap_statistics(&statistics) == 0 else {
      return nil
    }
    return NativeHeapStatistics(
      blocksInUse: UInt64(statistics.blocks_in_use),
      sizeInUse: UInt64(statistics.size_in_use),
      maxSizeInUse: UInt64(statistics.max_size_in_use),
      sizeAllocated: UInt64(statistics.size_allocated)
    )
  }

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
    let copyStart = ContinuousClock.now
    let pixels = [UInt16](unsafeUninitializedCapacity: pixelCount) { buffer, initializedCount in
      let bgr = UnsafeBufferPointer(start: sourcePixels, count: pixelCount)
      for i in stride(from: 0, to: pixelCount, by: 3) {
        buffer[i] = bgr[i + 2]
        buffer[i + 1] = bgr[i + 1]
        buffer[i + 2] = bgr[i]
      }
      initializedCount = pixelCount
    }
    let copySeconds = rawDecodeSeconds(copyStart.duration(to: .now))
    let colorDescription = withUnsafePointer(to: output.color_description) {
      $0.withMemoryRebound(to: CChar.self, capacity: 5) {
        String(cString: $0)
      }
    }
    let version = String(cString: fsc_libraw_version())
    let processing = RawProcessingStages(rawValue: output.processing_flags)
    DecodeLog.rawDecodeComplete(
      path: url.lastPathComponent,
      width: Int(output.width),
      height: Int(output.height),
      colorDescription: colorDescription,
      version: version,
      profile: profile,
      processing: processing
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
      profile: profile,
      isoSpeed: Double(output.iso_speed),
      processing: processing,
      timings: RawDecodeTimings(
        openSeconds: output.open_seconds,
        unpackSeconds: output.unpack_seconds,
        demosaicSeconds: output.demosaic_seconds,
        libRawPostprocessSeconds: output.libraw_postprocess_seconds,
        processedImageSeconds: output.processed_image_seconds,
        isoPolicySeconds: output.iso_policy_seconds,
        swiftCopySwizzleSeconds: copySeconds
      )
    )
  }

  public struct ThumbnailResult: Sendable {
    public let image: UInt16Image
    public let width: Int
    public let height: Int
  }

  public static func extractThumbnail(
    _ url: URL,
    maxDimension: Int? = nil
  ) throws -> ThumbnailResult {
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
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw RawImageDecoderError.decodeFailed("Could not decode embedded JPEG.")
    }
    let cgImage: CGImage?
    if let maxDimension {
      guard maxDimension > 0 else {
        throw RawImageDecoderError.decodeFailed("Thumbnail bound must be positive.")
      }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    } else {
      cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let cgImage else {
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
    components.withUnsafeBytes { (rbp: UnsafeRawBufferPointer) in
      let src16 = rbp.bindMemory(to: UInt16.self)
      pixels.withUnsafeMutableBufferPointer { dst in
        var si = 0
        var di = 0
        for _ in 0..<pixelCount {
          dst[di] = src16[si + 2]
          dst[di + 1] = src16[si + 1]
          dst[di + 2] = src16[si]
          si += 4
          di += 3
        }
      }
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

private func rawDecodeSeconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
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
